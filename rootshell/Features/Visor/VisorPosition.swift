//
//  VisorPosition.swift
//  rootshell
//
//  Geometry helpers for the visor window. Ported from upstream Ghostty's
//  QuickTerminalPosition.swift / QuickTerminalSize.swift but uses CGRect
//  directly so we don't have to import AppKit (Catalyst can't).
//

#if STANDALONE && targetEnvironment(macCatalyst)

import CoreGraphics
import Foundation

extension VisorPosition {

    /// Parse a size spec like `"30%"` or `"400px"`. Returns nil if empty/malformed.
    static func parseSize(_ raw: String) -> SizeSpec? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if let pctRange = trimmed.range(of: "%", options: .backwards),
           let value = Double(trimmed[..<pctRange.lowerBound]) {
            return .percentage(value)
        }
        if let pxRange = trimmed.range(of: "px", options: [.backwards, .caseInsensitive]),
           let value = Double(trimmed[..<pxRange.lowerBound]) {
            return .pixels(value)
        }
        if let value = Double(trimmed) {
            return .pixels(value)
        }
        return nil
    }

    enum SizeSpec: Equatable {
        case percentage(Double)
        case pixels(Double)

        func toPixels(parent: CGFloat) -> CGFloat {
            switch self {
            case .percentage(let pct): return parent * CGFloat(pct) / 100.0
            case .pixels(let px): return CGFloat(px)
            }
        }
    }

    /// Compute the desired frame size given a visible screen rect and the
    /// user's primary/secondary size strings.
    func configuredFrameSize(visibleFrame: CGRect, primary: String, secondary: String) -> CGSize {
        let primarySpec = Self.parseSize(primary)
        let secondarySpec = Self.parseSize(secondary)
        let dims = visibleFrame.size

        switch self {
        case .left, .right:
            return CGSize(
                width: primarySpec?.toPixels(parent: dims.width) ?? 400,
                height: secondarySpec?.toPixels(parent: dims.height) ?? dims.height
            )
        case .top, .bottom:
            return CGSize(
                width: secondarySpec?.toPixels(parent: dims.width) ?? dims.width,
                height: primarySpec?.toPixels(parent: dims.height) ?? 400
            )
        case .center:
            if dims.width >= dims.height {
                return CGSize(
                    width: primarySpec?.toPixels(parent: dims.width) ?? 800,
                    height: secondarySpec?.toPixels(parent: dims.height) ?? 400
                )
            } else {
                return CGSize(
                    width: secondarySpec?.toPixels(parent: dims.width) ?? 400,
                    height: primarySpec?.toPixels(parent: dims.height) ?? 800
                )
            }
        }
    }

    /// Off-screen origin used as the start (show) or end (hide) of the slide animation.
    func initialOrigin(forSize size: CGSize, visibleFrame: CGRect) -> CGPoint {
        switch self {
        case .top:
            return CGPoint(
                x: (visibleFrame.minX + (visibleFrame.width - size.width) / 2).rounded(),
                y: visibleFrame.maxY)
        case .bottom:
            return CGPoint(
                x: (visibleFrame.minX + (visibleFrame.width - size.width) / 2).rounded(),
                y: visibleFrame.minY - size.height)
        case .left:
            return CGPoint(
                x: visibleFrame.minX - size.width,
                y: (visibleFrame.minY + (visibleFrame.height - size.height) / 2).rounded())
        case .right:
            return CGPoint(
                x: visibleFrame.maxX,
                y: (visibleFrame.minY + (visibleFrame.height - size.height) / 2).rounded())
        case .center:
            return CGPoint(
                x: (visibleFrame.minX + (visibleFrame.width - size.width) / 2).rounded(),
                y: (visibleFrame.minY + (visibleFrame.height - size.height) / 2).rounded())
        }
    }

    /// Final on-screen origin once the visor is fully visible.
    func finalOrigin(forSize size: CGSize, visibleFrame: CGRect) -> CGPoint {
        switch self {
        case .top:
            return CGPoint(
                x: (visibleFrame.minX + (visibleFrame.width - size.width) / 2).rounded(),
                y: visibleFrame.maxY - size.height)
        case .bottom:
            return CGPoint(
                x: (visibleFrame.minX + (visibleFrame.width - size.width) / 2).rounded(),
                y: visibleFrame.minY)
        case .left:
            return CGPoint(
                x: visibleFrame.minX,
                y: (visibleFrame.minY + (visibleFrame.height - size.height) / 2).rounded())
        case .right:
            return CGPoint(
                x: visibleFrame.maxX - size.width,
                y: (visibleFrame.minY + (visibleFrame.height - size.height) / 2).rounded())
        case .center:
            return CGPoint(
                x: (visibleFrame.minX + (visibleFrame.width - size.width) / 2).rounded(),
                y: (visibleFrame.minY + (visibleFrame.height - size.height) / 2).rounded())
        }
    }
}

#endif
