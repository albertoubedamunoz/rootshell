//
//  SetAppIconIntent.swift
//  rootshell
//
//  Shortcuts action that switches the rootshell app icon.
//

import AppIntents

struct SetAppIconIntent: AppIntent {
    static var title: LocalizedStringResource = "Change App Icon"
    static var description: IntentDescription = "Changes the rootshell app icon."
    // The icon swap has to happen from the host app's UIApplication; running
    // this in a backgrounded AppIntents extension silently no-ops. Foregrounding
    // the app guarantees `AppIconManager`'s `didBecomeActive` reconciliation
    // path applies the change.
    static var openAppWhenRun = true

    @Parameter(title: "App Icon", description: "The icon variant to switch to.")
    var variant: AppIconManager.AppIconVariant

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard AppIconManager.isSupported else {
            throw IntentError.unsupported
        }

        AppIconManager.shared.selectedVariant = variant

        let name = variant.displayName
        return .result(dialog: IntentDialog("Changed app icon to \(name)."))
    }

    enum IntentError: Swift.Error, CustomLocalizedStringResourceConvertible {
        case unsupported

        var localizedStringResource: LocalizedStringResource {
            switch self {
            case .unsupported:
                return "App icons aren't supported on this device."
            }
        }
    }
}
