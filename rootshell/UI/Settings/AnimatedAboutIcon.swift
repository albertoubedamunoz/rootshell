import SwiftUI
import UIKit

struct AnimatedAboutIcon: View {
    @Environment(\.sheetThemeColors) private var sheetThemeColors
    @ObservedObject private var iconManager = AppIconManager.shared

    var onTap: () -> Void
    var onLongPress: () -> Void

    @State private var breathing = false

    private var glowColor: Color {
        sheetThemeColors?.accentColor ?? Color(red: 0.35, green: 0.75, blue: 0.30)
    }

    private var breathingAnimation: Animation {
        .easeInOut(duration: 2.5).repeatForever(autoreverses: true)
    }

    var body: some View {
        // Scope the repeating animation to the visual effects. Animating the
        // entire onAppear transaction can also repeat an in-flight position
        // change while the settings container settles into its safe area.
        ZStack {
            RoundedRectangle(cornerRadius: 144 * 0.2237, style: .continuous)
                .fill(glowColor)
                .frame(width: 144, height: 144)
                .blur(radius: 24)
                .animation(breathingAnimation) { glow in
                    glow.opacity(breathing ? 0.45 : 0.25)
                }

            Image(iconManager.selectedVariant.previewAssetName)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 144, height: 144)
                .animation(breathingAnimation) { icon in
                    icon.scaleEffect(breathing ? 1.012 : 1.0)
                }
        }
        .frame(width: 144, height: 144)
        .onAppear {
            breathing = true
        }
        .onTapGesture(perform: onTap)
        .onLongPressGesture(minimumDuration: 3, perform: onLongPress)
    }
}
