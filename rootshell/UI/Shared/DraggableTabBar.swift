//
//  DraggableTabBar.swift
//  rootshell
//
//  Placeholder for potential future tab bar drag handling.
//  Window drag blocking is now handled at the AppKit level via
//  WindowAccessor's DragBlockerView which overrides mouseDownCanMoveWindow.
//

import SwiftUI

#if targetEnvironment(macCatalyst)

extension View {
    /// Placeholder modifier - drag blocking is now handled by WindowAccessor
    func blockWindowDrag(when enabled: Bool) -> some View {
        self  // Pass through unchanged - AppKit DragBlockerView handles this
    }
}

#endif
