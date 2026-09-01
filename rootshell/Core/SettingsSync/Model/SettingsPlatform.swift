//
//  SettingsPlatform.swift
//  rootshell
//
//  Process-constant platform facts needed by registry defaults from
//  nonisolated static initializers, where UIDevice is off limits.
//

import UIKit

nonisolated enum SettingsPlatform {
    /// Set once at launch, before any registry key is touched.
    nonisolated(unsafe) private(set) static var isPhone = false

    #if targetEnvironment(macCatalyst)
    static let isCatalyst = true
    #else
    static let isCatalyst = false
    #endif

    @MainActor
    static func configure() {
        isPhone = UIDevice.current.userInterfaceIdiom == .phone
    }
}
