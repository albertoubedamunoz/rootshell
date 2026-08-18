#if !CHINA_BUILD
import SwiftUI
import UIKit

/// Centralized font definitions for AI Agent chat.
///
/// Uses AIAgentFontManager for user-configurable text size that works
/// consistently across iOS, iPadOS, and Mac Catalyst.
///
/// ## Usage
/// ```swift
/// // SwiftUI
/// Text("Hello").font(AIAgentFonts.body)
///
/// // UIKit (AttributedString)
/// let font = AIAgentFonts.uiCodeBody
/// ```
enum AIAgentFonts {
    // MARK: - Manager Reference

    /// Shortcut to the font manager
    @MainActor
    private static var manager: AIAgentFontManager { AIAgentFontManager.shared }

    // MARK: - SwiftUI Fonts

    /// Body text in chat messages
    static var body: Font { .body }

    /// Monospaced body for code/commands - uses manager's text size
    @MainActor
    static var codeBody: Font {
        .system(size: manager.textSize, weight: .regular, design: .monospaced)
    }

    /// Callout text (slightly larger than caption)
    static var callout: Font { .callout }

    /// Small labels and badges
    static var caption: Font { .caption }

    /// Very small text
    static var caption2: Font { .caption2 }

    /// Button labels
    static var button: Font { .body.weight(.semibold) }

    /// Secondary button labels
    static var buttonSecondary: Font { .body.weight(.medium) }

    /// Icons in avatar circles (scales with caption)
    static var avatarIcon: Font { .caption.weight(.medium) }

    /// Small badge icons
    static var badgeIcon: Font { .caption2.weight(.semibold) }

    /// Selection control icons (radio buttons, checkboxes)
    static var selectionIcon: Font { .title3 }

    // MARK: - UIKit Fonts (for AttributedString/UITextView)

    /// Monospaced body font using manager's text size
    @MainActor
    static var uiCodeBody: UIFont {
        manager.monospacedFont(weight: .regular)
    }

    /// Monospaced bold body font using manager's text size
    @MainActor
    static var uiCodeBodyBold: UIFont {
        manager.monospacedFont(weight: .bold)
    }

    /// Scaled header fonts for markdown
    @MainActor
    static func uiHeader(level: Int) -> UIFont {
        manager.headerFont(level: level)
    }

    /// Italic monospaced font using manager's text size
    @MainActor
    static var uiCodeBodyItalic: UIFont {
        let baseFont = manager.monospacedFont(weight: .regular)
        if let italicDescriptor = baseFont.fontDescriptor.withSymbolicTraits(.traitItalic) {
            return UIFont(descriptor: italicDescriptor, size: baseFont.pointSize)
        }
        return baseFont
    }

    /// Bold italic monospaced font using manager's text size
    @MainActor
    static var uiCodeBodyBoldItalic: UIFont {
        let baseFont = manager.monospacedFont(weight: .bold)
        if let italicDescriptor = baseFont.fontDescriptor.withSymbolicTraits([.traitBold, .traitItalic]) {
            return UIFont(descriptor: italicDescriptor, size: baseFont.pointSize)
        }
        return baseFont
    }
}
#endif
