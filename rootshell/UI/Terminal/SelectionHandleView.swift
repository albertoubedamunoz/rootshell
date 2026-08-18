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

    class SelectionMagnifierView: UIView {

        static let contentSize = CGSize(width: 132, height: 88)
        static let sourceSize = CGSize(width: 72, height: 48)
        static let verticalOffset: CGFloat = 92
        static let horizontalOffset: CGFloat = 54

        private let blurView = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
        private let contentClipView = UIView()
        private let focusRing = UIView()
        private var snapshotView: UIView?

        override init(frame: CGRect) {
            super.init(frame: CGRect(origin: .zero, size: Self.contentSize))
            isUserInteractionEnabled = false
            backgroundColor = .clear
            alpha = 0

            layer.cornerRadius = 18
            layer.cornerCurve = .continuous
            layer.borderWidth = 1
            layer.borderColor = UIColor.white.withAlphaComponent(0.35).cgColor
            layer.shadowColor = UIColor.black.cgColor
            layer.shadowOpacity = 0.22
            layer.shadowRadius = 12
            layer.shadowOffset = CGSize(width: 0, height: 8)
            layer.masksToBounds = false

            blurView.frame = bounds
            blurView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            blurView.layer.cornerRadius = 18
            blurView.layer.cornerCurve = .continuous
            blurView.clipsToBounds = true
            addSubview(blurView)

            contentClipView.frame = bounds.insetBy(dx: 6, dy: 6)
            contentClipView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            contentClipView.clipsToBounds = true
            blurView.contentView.addSubview(contentClipView)

            focusRing.frame = CGRect(
                x: bounds.midX - 14,
                y: bounds.midY - 14,
                width: 28,
                height: 28
            )
            focusRing.autoresizingMask = [
                .flexibleLeftMargin, .flexibleRightMargin,
                .flexibleTopMargin, .flexibleBottomMargin
            ]
            focusRing.layer.cornerRadius = 14
            focusRing.layer.borderWidth = 1.5
            focusRing.layer.borderColor = UIColor.systemBlue.withAlphaComponent(0.9).cgColor
            focusRing.backgroundColor = UIColor.clear
            blurView.contentView.addSubview(focusRing)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) not supported")
        }

        func refreshSnapshot(from sourceView: UIView, around point: CGPoint) {
            snapshotView?.removeFromSuperview()

            let sourceRect = CGRect(
                x: point.x - Self.sourceSize.width / 2,
                y: point.y - Self.sourceSize.height / 2,
                width: Self.sourceSize.width,
                height: Self.sourceSize.height
            ).intersection(sourceView.bounds)

            guard !sourceRect.isNull,
                  sourceRect.width > 4,
                  sourceRect.height > 4,
                  let snapshot = sourceView.resizableSnapshotView(
                    from: sourceRect,
                    afterScreenUpdates: false,
                    withCapInsets: .zero
                  ) else {
                return
            }

            let scaleX = contentClipView.bounds.width / sourceRect.width
            let scaleY = contentClipView.bounds.height / sourceRect.height
            let scale = max(scaleX, scaleY)
            let scaledSize = CGSize(width: sourceRect.width * scale, height: sourceRect.height * scale)
            snapshot.frame = CGRect(
                x: (contentClipView.bounds.width - scaledSize.width) / 2,
                y: (contentClipView.bounds.height - scaledSize.height) / 2,
                width: scaledSize.width,
                height: scaledSize.height
            )

            contentClipView.addSubview(snapshot)
            snapshotView = snapshot
        }
    }
}

#endif
