#if !CHINA_BUILD
//
//  AIAgentWindowView.swift
//  rootshell
//
//  Content view for the dedicated AI Agent window
//  Note: This is a simple wrapper. The actual implementation is in AIAgentWindowController.swift
//  which provides proper keyboard shortcut handling for Mac Catalyst.
//

import SwiftUI

/// Legacy wrapper view for AI Agent window content
/// The window now uses AIAgentWindowControllerRepresentable for keyboard handling
/// This view can still be used directly but won't have keyboard shortcuts on Mac Catalyst
struct AIAgentWindowView: View {
    var body: some View {
        AIAgentWindowContentView()
    }
}

// MARK: - Preview

#Preview {
    AIAgentWindowView()
}
#endif
