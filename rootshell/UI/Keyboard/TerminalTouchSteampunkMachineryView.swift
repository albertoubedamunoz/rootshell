#if !os(visionOS) && !targetEnvironment(macCatalyst)
import UIKit
import QuartzCore

/// One retained, noninteractive machine per visible keyboard, never per key.
/// The clock exists only while there is contact or a short, bounded coast-down.
@MainActor
final class TerminalTouchSteampunkMachineryView: UIView {
    private typealias Art = TerminalTouchSteampunkArtwork
    private typealias Mechanics = TerminalTouchSteampunkMechanics

    @MainActor
    private final class ClockTarget: NSObject {
        weak var owner: TerminalTouchSteampunkMachineryView?
        @objc func tick(_ link: CADisplayLink) {
            guard let owner else { link.invalidate(); return }
            owner.tick(link)
        }
    }
    private struct Rotor {
        let layer: CALayer
        let teeth: Int
        let reversed: Bool
        let offset: Double
    }
    @MainActor
    private final class BankLayers {
        let root = CALayer()
        var rotors: [Rotor] = []
        let stitches = CAShapeLayer()
        let rod = CAShapeLayer()
        let rodHighlight = CAShapeLayer()
        let needle = CAShapeLayer()
        let oil = CALayer()
        var crank = CGPoint.zero
        var throwRadius: CGFloat = 0
    }
    private struct Prepared: Equatable {
        let size: CGSize
        let scale: CGFloat
        let rows: [CGRect]
        let material: Art.Material
        let solid: Bool
    }
    private struct Contact {
        let position: Double
        let strength: Double
    }
    private struct Pulse {
        let layer: CALayer
        var life = 0.0
    }

    private let bed = UIImageView()
    private let visibleBandMask = CAShapeLayer()
    private var banks: [BankLayers] = []
    private var pulses: [Pulse] = []
    private var nextPulse = 0
    private var contacts: [ObjectIdentifier: Contact] = [:]
    private var drive = Mechanics.Drive()
    private var prepared: Prepared?
    private var palette: TerminalTouchKeyboardPalette?
    private var rowBands: [CGRect] = []
    private var active = false
    private var link: CADisplayLink?
    private let clockTarget = ClockTarget()
    private var previousTick: CFTimeInterval?

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
        clockTarget.owner = self
        registerForTraitChanges([UITraitDisplayScale.self, UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]) {
            (self: TerminalTouchSteampunkMachineryView, _: UITraitCollection) in
            self.setNeedsLayout()
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(palette: TerminalTouchKeyboardPalette?, rows: [CGRect], active: Bool) {
        if self.palette != palette || rowBands != rows { setNeedsLayout() }
        self.palette = palette
        rowBands = rows.filter { !$0.isEmpty && !$0.isNull && !$0.isInfinite }
        self.active = active
        if !active { resetContactFeedback() }
        else if !motionAllowed { stopClock() }
        else if !contacts.isEmpty || drive.isMoving { startClock() }
        // Accessibility changes can arrive without a trait or geometry change.
        setNeedsLayout()
    }

    private var motionAllowed: Bool {
        active && window != nil && !isHidden && !UIAccessibility.isReduceMotionEnabled
            && !ProcessInfo.processInfo.isLowPowerModeEnabled
            && !UIAccessibility.isDarkerSystemColorsEnabled && traitCollection.accessibilityContrast != .high
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
        let material = Art.Material(palette: palette, traits: traitCollection)
        let next = Prepared(size: bounds.size, scale: scale, rows: rowBands, material: material,
                            solid: UIAccessibility.isReduceTransparencyEnabled)
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
        bed.image = Art.bed(size: bounds.size, scale: scale, material: material, rows: rowBands, solid: next.solid)
        bed.backgroundColor = bed.image == nil ? material.steel.ui : .clear
        banks.forEach { $0.root.removeFromSuperlayer() }; banks.removeAll()
        pulses.forEach { $0.layer.removeFromSuperlayer() }; pulses.removeAll()
        // In toolbar-only mode use the toolbar's actual band; no hidden QWERTY geometry.
        let top = rowBands.first?.maxY ?? min(bounds.height * 0.45, 24)
        let bottom = rowBands.count > 1 ? (rowBands.last?.minY ?? top) : top
        let radius = min(24, max(10, (rowBands.first?.height ?? 40) * 0.48))
        for position: CGFloat in [0.17, 0.5, 0.83] {
            let bank = buildBank(x: bounds.width * position, top: top, bottom: max(top, bottom), radius: radius, scale: scale)
            bank.root.opacity = material.highContrast ? 0.35 : 1
            banks.append(bank); layer.addSublayer(bank.root)
        }
        let glow = Art.glow(scale: scale)?.cgImage
        for _ in 0..<8 {
            let light = CALayer()
            light.contents = glow; light.contentsScale = scale; light.opacity = 0
            layer.addSublayer(light); pulses.append(Pulse(layer: light))
        }
        render()
        CATransaction.commit()
        if motionAllowed, !contacts.isEmpty { startClock() }
    }

    private func buildBank(x: CGFloat, top: CGFloat, bottom: CGFloat, radius: CGFloat, scale: CGFloat) -> BankLayers {
        let bank = BankLayers()
        bank.root.frame = bounds
        bank.crank = CGPoint(x: x, y: bottom)
        bank.throwRadius = radius * 0.28
        let pulley: CGFloat = max(3, radius * 0.25)
        if bottom - top > pulley * 2 {
            let beltPath = UIBezierPath(roundedRect: CGRect(x: x - pulley, y: top - pulley, width: pulley * 2, height: bottom - top + pulley * 2), cornerRadius: pulley)
            let backing = CAShapeLayer(); backing.path = beltPath.cgPath; backing.fillColor = UIColor.clear.cgColor
            backing.strokeColor = UIColor.black.withAlphaComponent(0.8).cgColor; backing.lineWidth = 5
            bank.root.addSublayer(backing)
            let leather = CAShapeLayer(); leather.path = beltPath.cgPath; leather.fillColor = UIColor.clear.cgColor
            leather.strokeColor = Art.RGB(0.30, 0.15, 0.07).ui.cgColor; leather.lineWidth = 3.3
            bank.root.addSublayer(leather)
            bank.stitches.path = beltPath.cgPath; bank.stitches.fillColor = UIColor.clear.cgColor
            bank.stitches.strokeColor = Art.RGB(0.82, 0.65, 0.37).ui.cgColor
            bank.stitches.lineWidth = 0.7; bank.stitches.lineDashPattern = [1, 2]
            bank.root.addSublayer(bank.stitches)
        }
        // Identical tooth module and common tooth phase keep the idlers meshed.
        let module = radius / 12.8
        for (index, y) in (bottom - top > radius ? [top, bottom] : [top]).enumerated() {
            let gear = rotor(radius: radius, teeth: 24, copper: index == 1, scale: scale,
                             at: CGPoint(x: x, y: y))
            bank.root.addSublayer(gear)
            bank.rotors.append(Rotor(layer: gear, teeth: 24, reversed: false, offset: 0))
            let idler = rotor(radius: module * 8.8, teeth: 16, copper: index == 0, scale: scale,
                              at: CGPoint(x: x + module * 20, y: y))
            bank.root.addSublayer(idler)
            bank.rotors.append(Rotor(layer: idler, teeth: 16, reversed: true, offset: .pi / 16))
        }
        let sleeve = CALayer()
        sleeve.frame = CGRect(x: x + radius * 0.85, y: bottom - 3, width: radius * 0.88, height: 6)
        sleeve.backgroundColor = Art.RGB(0.28, 0.19, 0.11).ui.cgColor
        sleeve.borderWidth = 0.8; sleeve.borderColor = Art.RGB(0.78, 0.59, 0.33).ui.cgColor; sleeve.cornerRadius = 1.5
        bank.root.addSublayer(sleeve)
        for shape in [bank.rod, bank.rodHighlight] {
            shape.fillColor = UIColor.clear.cgColor; shape.lineCap = .round
            bank.root.addSublayer(shape)
        }
        bank.rod.strokeColor = Art.RGB(0.38, 0.38, 0.34).ui.cgColor; bank.rod.lineWidth = 3
        bank.rodHighlight.strokeColor = Art.RGB(0.87, 0.85, 0.70).ui.cgColor; bank.rodHighlight.lineWidth = 0.7
        let diameter: CGFloat = min(19, radius)
        let gaugeCenter = CGPoint(x: x - radius * 1.30, y: top)
        let gauge = CALayer()
        gauge.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter); gauge.position = gaugeCenter
        gauge.contents = Art.gauge(diameter: diameter, scale: scale)?.cgImage; gauge.contentsScale = scale
        bank.root.addSublayer(gauge)
        bank.needle.position = gaugeCenter
        let needle = UIBezierPath(); needle.move(to: .zero); needle.addLine(to: CGPoint(x: 0, y: -diameter * 0.27))
        bank.needle.path = needle.cgPath; bank.needle.strokeColor = Art.RGB(0.48, 0.12, 0.035).ui.cgColor
        bank.needle.lineWidth = 0.9; bank.needle.lineCap = .round; bank.root.addSublayer(bank.needle)
        let sightGlass = CALayer()
        sightGlass.frame = CGRect(x: gaugeCenter.x - diameter * 0.7, y: top - 7, width: 3, height: 14)
        sightGlass.cornerRadius = 1.5; sightGlass.borderWidth = 0.6
        sightGlass.borderColor = Art.RGB(0.63, 0.48, 0.25).ui.cgColor
        sightGlass.backgroundColor = Art.RGB(0.055, 0.045, 0.025).ui.cgColor
        bank.root.addSublayer(sightGlass)
        bank.oil.anchorPoint = CGPoint(x: 0.5, y: 1)
        bank.oil.position = CGPoint(x: 1.5, y: 12.5)
        bank.oil.bounds = CGRect(x: 0, y: 0, width: 1.2, height: 5)
        bank.oil.backgroundColor = Art.RGB(0.94, 0.58, 0.14).ui.cgColor
        sightGlass.addSublayer(bank.oil)
        return bank
    }

    private func rotor(radius: CGFloat, teeth: Int, copper: Bool, scale: CGFloat, at point: CGPoint) -> CALayer {
        let rotor = CALayer()
        let extent = ceil(radius + 4)
        rotor.bounds = CGRect(x: 0, y: 0, width: extent * 2, height: extent * 2)
        rotor.position = point; rotor.contentsScale = scale
        rotor.contents = Art.gear(radius: radius, teeth: teeth, scale: scale, copper: copper)?.cgImage
        return rotor
    }

    /// Contact rather than successful input: a cancelled swipe never schedules a
    /// success effect, and this code cannot dispatch or delay a terminal command.
    func setContact(_ source: TerminalTouchKeycap, pressed: Bool, strength: Double = 1) {
        let id = ObjectIdentifier(source)
        if !pressed { contacts[id] = nil; return }
        guard active, source.window === window, window != nil, !source.isHidden,
              contacts[id] == nil, contacts.count < 16, bounds.width > 1 else { return }
        let rect = source.convert(source.bounds, to: self)
        guard bounds.intersects(rect), rect.midX.isFinite else { return }
        let position = Double(min(1, max(0, rect.midX / bounds.width)))
        contacts[id] = Contact(position: position, strength: strength)
        guard motionAllowed, hierarchyVisible else { return }
        drive.strike(at: position, strength: strength)
        if !pulses.isEmpty {
            let index = nextPulse % pulses.count; nextPulse = (index + 1) % pulses.count
            pulses[index].life = 0.24
            CATransaction.begin(); CATransaction.setDisableActions(true)
            pulses[index].layer.bounds = CGRect(x: 0, y: 0, width: min(90, max(38, rect.width * 1.25)), height: 24)
            pulses[index].layer.position = CGPoint(x: rect.midX, y: rect.maxY - 2)
            pulses[index].layer.opacity = 0.65
            CATransaction.commit()
        }
        startClock()
    }

    func resetContactFeedback() {
        contacts.removeAll(keepingCapacity: true)
        stopClock()
    }

    private func startClock() {
        guard link == nil, motionAllowed, hierarchyVisible, !banks.isEmpty else { return }
        drive.rebaseClock(); previousTick = nil
        let clock = CADisplayLink(target: clockTarget, selector: #selector(ClockTarget.tick(_:)))
        // Keep keyboard input ahead of ornamental animation. No 120 Hz full-view redraws.
        clock.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        clock.add(to: .main, forMode: .common)
        link = clock
    }

    private func stopClock() {
        link?.invalidate(); link = nil; previousTick = nil; drive.stop()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for index in pulses.indices { pulses[index].life = 0; pulses[index].layer.opacity = 0 }
        render()
        CATransaction.commit()
    }

    private func tick(_ link: CADisplayLink) {
        guard motionAllowed, hierarchyVisible else { resetContactFeedback(); return }
        let time = link.timestamp
        let dt = previousTick.map { min(1.0 / 15.0, max(0, time - $0)) } ?? 0
        previousTick = time
        var held = [Double](repeating: 0, count: Mechanics.bankCount)
        for contact in contacts.values {
            for (index, weight) in Mechanics.Drive.weights(at: contact.position).enumerated() {
                held[index] += weight * contact.strength
            }
        }
        drive.advance(to: time, held: held)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for index in pulses.indices {
            pulses[index].life = max(0, pulses[index].life - dt)
            pulses[index].layer.opacity = Float(pulses[index].life / 0.24) * 0.65
        }
        render()
        CATransaction.commit()
        if contacts.isEmpty && !drive.isMoving && pulses.allSatisfy({ $0.life == 0 }) { stopClock() }
    }

    private func render() {
        for (index, bank) in banks.enumerated() {
            let state = drive.banks[index]
            for rotor in bank.rotors {
                let angle = state.angle(teeth: rotor.teeth, reversed: rotor.reversed) + rotor.offset
                rotor.layer.transform = CATransform3DMakeRotation(CGFloat(angle), 0, 0, 1)
            }
            // 48 tooth phases * 1.5 points = 24 complete three-point stitches.
            // Wrapping the phase therefore cannot pop either the gears or belt.
            bank.stitches.lineDashPhase = CGFloat(-state.phase * 1.5)
            let angle = state.angle(teeth: 24)
            let endpoint = CGPoint(x: bank.crank.x + cos(CGFloat(angle)) * bank.throwRadius,
                                   y: bank.crank.y + sin(CGFloat(angle)) * bank.throwRadius)
            let rod = UIBezierPath(); rod.move(to: endpoint)
            rod.addLine(to: CGPoint(x: bank.crank.x + bank.throwRadius * 5 + cos(CGFloat(angle)) * bank.throwRadius * 0.45, y: bank.crank.y))
            bank.rod.path = rod.cgPath; bank.rodHighlight.path = rod.cgPath
            bank.needle.transform = CATransform3DMakeRotation(CGFloat(-0.75 * .pi + state.pressure * 1.5 * .pi), 0, 0, 1)
            bank.oil.bounds.size.height = CGFloat(4 + state.pressure * 7)
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { resetContactFeedback() } else { setNeedsLayout() }
    }
}
#endif
