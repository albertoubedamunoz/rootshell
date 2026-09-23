#if !os(visionOS) && !targetEnvironment(macCatalyst)
import UIKit
import QuartzCore

/// One noninteractive bed per keyboard for the retro styles. Neon Grid's floor
/// scrolls only while typing coasts down; Circuit Board pulses are Core Animation.
@MainActor
final class TerminalTouchRetroBackdropView: UIView {
    private typealias Art = TerminalTouchRetroArtwork

    @MainActor
    private final class ClockTarget: NSObject {
        weak var owner: TerminalTouchRetroBackdropView?
        @objc func tick(_ link: CADisplayLink) {
            guard let owner else { link.invalidate(); return }
            owner.tick(link)
        }
    }
    private struct Prepared: Equatable {
        let size: CGSize
        let scale: CGFloat
        let rows: [CGRect]
        let design: Art.Design
        let accent: Art.RGB
        let dark: Bool
        let solid: Bool
        let highContrast: Bool
    }

    private let bed = UIImageView()
    private let visibleBandMask = CAShapeLayer()
    private let gridSpokes = CAShapeLayer()
    private let gridRungs = CAShapeLayer()
    private var pulses: [CALayer] = []
    private var nextPulse = 0
    private var prepared: Prepared?
    private var design = Art.Design.phosphor
    private var palette: TerminalTouchKeyboardPalette?
    private var rowBands: [CGRect] = []
    private var active = false
    private var link: CADisplayLink?
    private let clockTarget = ClockTarget()
    private var previousTick: CFTimeInterval?
    private var gridPhase = 0.0
    private var gridSpeed = 0.0

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        backgroundColor = .clear
        clipsToBounds = true
        layer.mask = visibleBandMask
        bed.isUserInteractionEnabled = false
        addSubview(bed)
        for shape in [gridSpokes, gridRungs] {
            shape.fillColor = UIColor.clear.cgColor
            shape.lineWidth = 1
            layer.addSublayer(shape)
        }
        clockTarget.owner = self
        registerForTraitChanges([UITraitDisplayScale.self, UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]) {
            (self: TerminalTouchRetroBackdropView, _: UITraitCollection) in self.setNeedsLayout()
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(design: TerminalTouchRetroArtwork.Design, palette: TerminalTouchKeyboardPalette?, rows: [CGRect], active: Bool) {
        self.design = design
        self.palette = palette
        rowBands = rows.filter { !$0.isEmpty && !$0.isNull && !$0.isInfinite }
        self.active = active
        if !active || !motionAllowed { stopClock() }
        setNeedsLayout()
    }

    private var highContrast: Bool {
        UIAccessibility.isDarkerSystemColorsEnabled || traitCollection.accessibilityContrast == .high
    }
    private var motionAllowed: Bool {
        active && window != nil && !isHidden && !UIAccessibility.isReduceMotionEnabled
            && !ProcessInfo.processInfo.isLowPowerModeEnabled && !highContrast
    }
    private var hierarchyVisible: Bool {
        var ancestor: UIView? = self
        while let view = ancestor {
            if view.isHidden || view.alpha < 0.01 { return false }
            ancestor = view.superview
        }
        return window?.windowScene?.activationState == .foregroundActive
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = max(1, traitCollection.displayScale)
        let accent: Art.RGB = switch design {
        case .phosphor: Art.phosphor(SettingsStore.shared.value(Settings.Keyboard.touchPhosphorColor),
                                     palette: palette, traits: traitCollection)
        case .circuitBoard: Art.RGB(0.86, 0.68, 0.30)
        case .neonGrid: Art.RGB(1.0, 0.22, 0.74)
        case .beigeBox: Art.RGB(0.36, 0.34, 0.31)
        }
        let next = Prepared(size: bounds.size, scale: scale, rows: rowBands, design: design, accent: accent,
                            dark: traitCollection.userInterfaceStyle == .dark,
                            solid: UIAccessibility.isReduceTransparencyEnabled, highContrast: highContrast)
        guard prepared != next, bounds.width > 1, bounds.height > 1 else { return }
        prepared = next
        stopClock()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let visible = UIBezierPath()
        for band in rowBands {
            let rect = band.intersection(bounds)
            if !rect.isNull && !rect.isEmpty { visible.append(UIBezierPath(rect: rect)) }
        }
        visibleBandMask.frame = bounds
        visibleBandMask.path = visible.cgPath
        bed.frame = bounds
        bed.image = Art.bed(size: bounds.size, scale: scale, design: design, accent: accent, rows: rowBands,
                            dark: next.dark, solid: next.solid, highContrast: next.highContrast)
        let neon = design == .neonGrid && !next.highContrast
        gridSpokes.isHidden = !neon; gridRungs.isHidden = !neon
        gridSpokes.frame = bounds; gridRungs.frame = bounds
        gridSpokes.strokeColor = Art.RGB(1.0, 0.30, 0.80).ui.withAlphaComponent(0.55).cgColor
        gridRungs.strokeColor = Art.RGB(1.0, 0.30, 0.80).ui.withAlphaComponent(0.55).cgColor
        gridSpokes.path = neon ? spokesPath() : nil
        gridRungs.path = neon ? rungsPath() : nil
        pulses.forEach { $0.removeFromSuperlayer() }; pulses.removeAll()
        if design == .circuitBoard && !next.highContrast {
            let dot = Art.pulse(scale: scale, color: accent)?.cgImage
            for _ in 0..<8 {
                let pulse = CALayer()
                pulse.bounds = CGRect(x: 0, y: 0, width: 14, height: 14)
                pulse.contents = dot; pulse.contentsScale = scale; pulse.opacity = 0
                layer.addSublayer(pulse); pulses.append(pulse)
            }
        }
        CATransaction.commit()
    }

    /// Contact, not successful input: never dispatches or delays a key.
    func strike(from source: TerminalTouchKeycap) {
        guard active, source.window === window, window != nil, bounds.width > 1, hierarchyVisible,
              !UIAccessibility.isReduceMotionEnabled, !ProcessInfo.processInfo.isLowPowerModeEnabled, !highContrast else { return }
        let rect = source.convert(source.bounds, to: self)
        guard bounds.intersects(rect), rect.midX.isFinite else { return }
        switch design {
        case .neonGrid:
            gridSpeed = min(5, gridSpeed + 1.4)
            startClock()
        case .circuitBoard:
            firePulse(from: rect)
        case .phosphor, .beigeBox:
            break
        }
    }

    func resetContactFeedback() {
        stopClock()
        pulses.forEach { $0.removeAllAnimations(); $0.opacity = 0 }
    }

    // MARK: Circuit Board

    private func firePulse(from rect: CGRect) {
        guard !pulses.isEmpty else { return }
        let band = rowBands.first { $0.minY <= rect.midY && rect.midY <= $0.maxY } ?? rowBands.last
        guard let band else { return }
        let bus = band.maxY - 1
        let exit: CGFloat = rect.midX < bounds.midX ? -8 : bounds.width + 8
        let path = UIBezierPath()
        path.move(to: CGPoint(x: rect.midX, y: min(bus, rect.maxY - 6)))
        path.addLine(to: CGPoint(x: rect.midX, y: bus))
        path.addLine(to: CGPoint(x: exit, y: bus))
        let distance = abs(bus - rect.maxY) + abs(exit - rect.midX)
        let pulse = pulses[nextPulse]
        nextPulse = (nextPulse + 1) % pulses.count
        let travel = CAKeyframeAnimation(keyPath: "position")
        travel.path = path.cgPath
        travel.calculationMode = .paced
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 1, 0]
        fade.keyTimes = [0, 0.08, 0.75, 1]
        let group = CAAnimationGroup()
        group.animations = [travel, fade]
        group.duration = min(0.5, max(0.18, distance / 700))
        group.timingFunction = CAMediaTimingFunction(name: .easeIn)
        pulse.removeAllAnimations()
        pulse.add(group, forKey: "retro.pulse")
    }

    // MARK: Neon Grid

    private var horizon: CGFloat { Art.neonHorizon(rows: rowBands, height: bounds.height) }

    private func spokesPath() -> CGPath {
        let path = UIBezierPath()
        let vanishing = CGPoint(x: bounds.midX, y: horizon)
        let spacing = max(24, bounds.width / 9)
        for index in -12...12 {
            path.move(to: vanishing)
            path.addLine(to: CGPoint(x: bounds.midX + CGFloat(index) * spacing * 2.2, y: bounds.maxY))
        }
        return path.cgPath
    }

    /// Rungs sit at depths z = k + 1 - phase and project to horizon + floor / z.
    private func rungsPath() -> CGPath {
        let path = UIBezierPath()
        let floor = bounds.maxY - horizon
        guard floor > 1 else { return path.cgPath }
        for k in 0..<16 {
            let z = Double(k) + 1 - gridPhase
            guard z > 0.35 else { continue }
            let y = horizon + floor * CGFloat(0.55 / z)
            guard y <= bounds.maxY else { continue }
            path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: bounds.width, y: y))
        }
        return path.cgPath
    }

    private func startClock() {
        guard link == nil, motionAllowed, hierarchyVisible else { return }
        previousTick = nil
        let clock = CADisplayLink(target: clockTarget, selector: #selector(ClockTarget.tick(_:)))
        clock.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        clock.add(to: .main, forMode: .common)
        link = clock
    }

    private func stopClock() {
        link?.invalidate(); link = nil; previousTick = nil
        gridSpeed = 0
    }

    private func tick(_ link: CADisplayLink) {
        guard motionAllowed, hierarchyVisible else { stopClock(); return }
        let dt = previousTick.map { min(1.0 / 15.0, max(0, link.timestamp - $0)) } ?? 0
        previousTick = link.timestamp
        gridPhase = (gridPhase + gridSpeed * dt).truncatingRemainder(dividingBy: 1)
        gridSpeed *= exp(-2.6 * dt)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        gridRungs.path = rungsPath()
        CATransaction.commit()
        if gridSpeed < 0.02 { stopClock() }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { resetContactFeedback() } else { setNeedsLayout() }
    }
}
#endif
