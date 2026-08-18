//
//  WindowSizeManager.swift
//  rootshell
//
//  Tracks and persists the last focused window size for new window creation
//

import Foundation
import Combine

#if targetEnvironment(macCatalyst)

/// Manages window size and position persistence for Mac Catalyst.
/// New windows open with the geometry of the last focused window.
@MainActor
class WindowSizeManager: ObservableObject {
    static let shared = WindowSizeManager()

    private static let windowWidthKey = "lastWindowWidth"
    private static let windowHeightKey = "lastWindowHeight"
    private static let windowOriginXKey = "lastWindowOriginX"
    private static let windowOriginYKey = "lastWindowOriginY"
    private static let hasOriginKey = "lastWindowHasOrigin"

    private static let defaultWidth: CGFloat = 800
    private static let defaultHeight: CGFloat = 600
    private static let minWidth: CGFloat = 400
    private static let minHeight: CGFloat = 300

    @Published private(set) var lastWindowSize: CGSize
    @Published private(set) var lastWindowOrigin: CGPoint?

    /// Publisher that emits when a new window should be sized
    let windowSizeForNewWindow = PassthroughSubject<CGSize, Never>()

    private init() {
        let savedWidth = UserDefaults.standard.double(forKey: Self.windowWidthKey)
        let savedHeight = UserDefaults.standard.double(forKey: Self.windowHeightKey)

        if savedWidth >= Self.minWidth && savedHeight >= Self.minHeight {
            self.lastWindowSize = CGSize(width: savedWidth, height: savedHeight)
        } else {
            self.lastWindowSize = CGSize(width: Self.defaultWidth, height: Self.defaultHeight)
        }

        if UserDefaults.standard.bool(forKey: Self.hasOriginKey) {
            let x = UserDefaults.standard.double(forKey: Self.windowOriginXKey)
            let y = UserDefaults.standard.double(forKey: Self.windowOriginYKey)
            self.lastWindowOrigin = CGPoint(x: x, y: y)
        } else {
            self.lastWindowOrigin = nil
        }
    }

    /// Persist the full frame (size and origin) for the focused window.
    func updateWindowFrame(_ frame: CGRect) {
        let size = frame.size
        guard size.width >= Self.minWidth && size.height >= Self.minHeight else { return }

        if size != lastWindowSize {
            lastWindowSize = size
            UserDefaults.standard.set(size.width, forKey: Self.windowWidthKey)
            UserDefaults.standard.set(size.height, forKey: Self.windowHeightKey)
        }

        let origin = frame.origin
        if origin != lastWindowOrigin {
            lastWindowOrigin = origin
            UserDefaults.standard.set(origin.x, forKey: Self.windowOriginXKey)
            UserDefaults.standard.set(origin.y, forKey: Self.windowOriginYKey)
            UserDefaults.standard.set(true, forKey: Self.hasOriginKey)
        }
    }

    /// Stored size and (optional) origin for a new window.
    func frameForNewWindow() -> (origin: CGPoint?, size: CGSize) {
        return (lastWindowOrigin, lastWindowSize)
    }

    /// Stored size for a new window. Kept for callers that only need size.
    func sizeForNewWindow() -> CGSize {
        return lastWindowSize
    }
}

#endif
