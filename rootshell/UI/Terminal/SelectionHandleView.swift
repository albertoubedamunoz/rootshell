//
//  SelectionHandleView.swift
//  rootshell
//
//  Lollipop-style visual handles for text selection boundaries.
//  Only used on touch devices (iOS/iPadOS), excluded from Mac Catalyst.
//  Dragging is handled by pan gestures attached to these handle views.
//

#if !targetEnvironment(macCatalyst)

import UIKit

extension Ghostty {

    enum SelectionHandlePosition {
        case start
        case end
    }

    /// A lollipop-style selection handle: circle + stem line. Visual only.
    class SelectionHandleView: UIView {

        static let circleDiameter: CGFloat = 14
        static let lineWidth: CGFloat = 2.5
        static let totalWidth: CGFloat = 22
        static let defaultStemHeight: CGFloat = 20

        let position: SelectionHandlePosition
        var stemHeight: CGFloat = SelectionHandleView.defaultStemHeight {
            didSet {
                guard oldValue != stemHeight else { return }
                invalidateIntrinsicContentSize()
                setNeedsLayout()
            }
        }

        private let stemLayer = CAShapeLayer()
        private let circleLayer = CAShapeLayer()

        init(position: SelectionHandlePosition) {
            self.position = position
            super.init(frame: CGRect(
                x: 0, y: 0,
                width: Self.totalWidth,
                height: Self.defaultStemHeight + Self.circleDiameter
            ))
            isUserInteractionEnabled = true
            backgroundColor = .clear
            setupLayers()
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) not supported")
        }

        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
            bounds.insetBy(dx: -26, dy: -26).contains(point)
        }

        override var intrinsicContentSize: CGSize {
            CGSize(width: Self.totalWidth, height: stemHeight + Self.circleDiameter)
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            updatePaths()
        }

        private func setupLayers() {
            let tint = UIColor.systemBlue
            stemLayer.strokeColor = tint.cgColor
            stemLayer.lineWidth = Self.lineWidth
            stemLayer.lineCap = .round
            layer.addSublayer(stemLayer)

            circleLayer.fillColor = tint.cgColor
            circleLayer.strokeColor = UIColor.white.withAlphaComponent(0.7).cgColor
            circleLayer.lineWidth = 1
            layer.addSublayer(circleLayer)

            updatePaths()
        }

        private func updatePaths() {
            let centerX = bounds.midX
            let circleX = (bounds.width - Self.circleDiameter) / 2
            let visualStemHeight = max(12, stemHeight)

            if position == .start {
                let circleRect = CGRect(
                    x: circleX,
                    y: 0,
                    width: Self.circleDiameter,
                    height: Self.circleDiameter
                )
                circleLayer.path = UIBezierPath(ovalIn: circleRect).cgPath

                let stemPath = UIBezierPath()
                stemPath.move(to: CGPoint(x: centerX, y: circleRect.maxY - 0.5))
                stemPath.addLine(to: CGPoint(x: centerX, y: circleRect.maxY + visualStemHeight))
                stemLayer.path = stemPath.cgPath
            } else {
                let circleRect = CGRect(
                    x: circleX,
                    y: visualStemHeight,
                    width: Self.circleDiameter,
                    height: Self.circleDiameter
                )
                circleLayer.path = UIBezierPath(ovalIn: circleRect).cgPath

                let stemPath = UIBezierPath()
                stemPath.move(to: CGPoint(x: centerX, y: 0))
                stemPath.addLine(to: CGPoint(x: centerX, y: circleRect.minY + 0.5))
                stemLayer.path = stemPath.cgPath
            }

        }
    }
}

#endif
