import SwiftUI

extension View {
    /// Shared glass surface for floating pickers. Glass supplies its own
    /// elevation; the manual shadow belongs only to the pre-26 fallback.
    @ViewBuilder
    func floatingHUDPanelBackground() -> some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        #if os(visionOS)
        self.background(.regularMaterial, in: shape)
        #else
        if #available(iOS 26.0, macOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
                .shadow(color: .black.opacity(0.25), radius: 20, x: 0, y: 10)
        }
        #endif
    }
}
