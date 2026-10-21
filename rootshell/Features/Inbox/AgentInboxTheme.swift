import SwiftUI
import UIKit

/// Surfaces for the inbox, taken from the app's own "配置" screen.
///
/// Sampled from the running app: page `#1A1A28`, cards `#2B2B41`, with the
/// theme's accent. The app's chrome *is* the terminal theme tint — reaching for
/// `.systemGroupedBackground` instead produced black-on-black rows that belonged
/// to no app at all.
extension SheetThemeColors {
    /// The app can run a dark terminal theme while the system is in light mode.
    /// Semantic colours resolve against the *system* scheme, so they have to be
    /// told which world they are in or `.primary` comes out black on the tint.
    var isDarkSurface: Bool {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor(background).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return 0.299 * Double(red) + 0.587 * Double(green) + 0.114 * Double(blue) < 0.5
    }

    /// Page: the sheet background the app already uses.
    var pageFill: Color { background }

    /// Cards: one value step up from the page, like the "暂无配置" card.
    ///
    /// A white overlay washes the tint out — the app's card keeps the page's hue
    /// and saturation and only raises brightness (#1A1A28 → #2B2B41), so the step
    /// is taken in HSB rather than by compositing white.
    var cardFill: Color {
        brightnessAdjusted(by: isDarkSurface ? 0.095 : -0.045)
    }

    private func brightnessAdjusted(by step: CGFloat) -> Color {
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        UIColor(background).getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return Color(hue: Double(hue),
                     saturation: Double(saturation),
                     brightness: Double(min(max(brightness + step, 0), 1)),
                     opacity: Double(alpha))
    }

    /// Hairline, as the app separates rows.
    var cardStroke: Color {
        isDarkSurface ? Color.white.opacity(0.10) : Color.black.opacity(0.08)
    }

    /// Filter bar and chips sit between page and card.
    var controlFill: Color {
        isDarkSurface ? Color.white.opacity(0.06) : Color.black.opacity(0.05)
    }

    /// The raised segment inside the filter bar.
    var selectedControlFill: Color {
        isDarkSurface ? Color.white.opacity(0.16) : Color.white
    }

    /// Theme accent, falling back to the app accent.
    var inboxAccent: Color { accentColor ?? .accentColor }
}

extension View {
    /// Page fill for the inbox: the app's own sheet background, edge to edge.
    func agentInboxPage(_ theme: SheetThemeColors?) -> some View {
        background((theme?.pageFill ?? Color(uiColor: .systemGroupedBackground)).ignoresSafeArea())
    }
}
