//
//  SettingsPlatform.swift
//  rootshell
//
//  Process-constant platform facts needed by registry defaults from
//  nonisolated static initializers, where UIDevice is off limits.
//

import UIKit

nonisolated enum SettingsPlatform {
    #if targetEnvironment(macCatalyst)
    static let isCatalyst = true
    static let isPhone = false
    #else
    static let isCatalyst = false
    /// Resolved on first use. The registry is always first built on the main
    /// thread during app init, so no launch-order hook is needed.
    static let isPhone: Bool = {
        guard Thread.isMainThread else {
            assertionFailure("Registry built off the main thread before the idiom was known")
            return false
        }
        return MainActor.assumeIsolated { UIDevice.current.userInterfaceIdiom == .phone }
    }()
    #endif
}
