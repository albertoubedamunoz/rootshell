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

    var body: some View {
        // Glow/breathe via a repeat-forever animation on opacity + scale only.
        // The previous TimelineView ticked the view graph 12×/s and animated
        // blur radius, which rebuilds a CAFilter and forces a full CA commit
        // every tick. A fixed blur with animated opacity reads the same and
        // needs no per-frame main-thread work.
        ZStack {
            RoundedRectangle(cornerRadius: 144 * 0.2237, style: .continuous)
                .fill(glowColor)
                .frame(width: 144, height: 144)
                .blur(radius: 24)
                .opacity(breathing ? 0.45 : 0.25)

            Image(iconManager.selectedVariant.previewAssetName)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 144, height: 144)
                .scaleEffect(breathing ? 1.012 : 1.0)
        }
        .onAppear {
            // Matches the old 5s sine period: 2.5s per direction, eased.
            withAnimation(.easeInOut(duration: 2.5).repeatForever(autoreverses: true)) {
                breathing = true
            }
        }
        .onTapGesture(perform: onTap)
        .onLongPressGesture(minimumDuration: 3, perform: onLongPress)
    }
}
