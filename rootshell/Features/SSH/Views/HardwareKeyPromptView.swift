//
//  HardwareKeyPromptView.swift
//  rootshell
//
//  Overlay shown over the terminal while a YubiKey PIV signing operation is in
//  flight, so the user knows when to insert or touch their key instead of the
//  app silently waiting. Driven by HardwareKeyActivityCoordinator.
//
//  Modeled on ReconnectionOverlayView (same dimmed ZStack + glass card +
//  symbolEffect vocabulary, and the shared overlayCardBackground() modifier).
//
//  Apple FIDO2 is never routed here — iOS shows its own system sheet for that.
//
//  Copyright (c) 2026 Kit Knox / Rootshell LLC
//

import SwiftUI

struct HardwareKeyPromptView: View {
    let activity: HardwareKeyActivityCoordinator.Activity
    /// Abort the in-flight operation (cancel a pending connect / tear down a
    /// blocking sign) and clear the overlay.
    let onCancel: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // The system NFC sheet owns the screen during NFC; render nothing so we
        // don't stack a dimmed overlay on top of it.
        if case .nfcPresented = activity.phase {
            EmptyView()
        } else {
            overlay
        }
    }

    private var overlay: some View {
        ZStack {
            // Part transitions fire when the presentation site's conditional
            // inserts/removes this subtree: the scrim fades while the card
            // spring-scales in and out.
            Color.black.opacity(0.6)
                .ignoresSafeArea()
                .transition(.opacity)

            VStack(spacing: 20) {
                icon

                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                    .contentTransition(.opacity)

                if !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 280)
                        .contentTransition(.opacity)
                }

                buttons
            }
            .padding(24)
            .overlayCardBackground()
            .padding(.horizontal, 40)
            .transition(
                reduceMotion
                    ? .opacity
                    : .scale(scale: 0.94).combined(with: .opacity)
            )
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .onChange(of: activity.phase) { _, newPhase in
            // Announce the touch prompt for VoiceOver users who can't see the
            // pulsing symbol.
            if case .touchRequired = newPhase {
                AccessibilityNotification.Announcement(
                    String(localized: "Touch your YubiKey now", comment: "VoiceOver: hardware key touch prompt")
                ).post()
            }
        }
    }

    // MARK: - Icon

    @ViewBuilder
    private var icon: some View {
        switch activity.phase {
        case .waitingForDevice(let transport):
            switch transport {
            case .usbc, .lightning:
                YubiKeyInsertIllustration()
                    .transition(iconTransition)
            case .nfc:
                // Never rendered (the system NFC sheet owns the screen), kept
                // for exhaustiveness.
                Image(systemName: transport.iconName)
                    .font(.system(size: 48))
                    .foregroundStyle(.orange)
                    .symbolEffect(.breathe, isActive: !reduceMotion)
                    .transition(iconTransition)
            }
        case .touchRequired:
            YubiKeyTouchIllustration()
                .transition(iconTransition)
        case .working:
            ProgressView()
                .scaleEffect(1.5)
                .transition(iconTransition)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.red)
                .symbolEffect(.pulse, isActive: !reduceMotion)
                .transition(iconTransition)
        case .nfcPresented:
            EmptyView()
        }
    }

    /// Phase-to-phase morph for the icon area, driven by the presentation
    /// site's animation on the activity value.
    private var iconTransition: AnyTransition {
        reduceMotion ? .opacity : .scale(scale: 0.6).combined(with: .opacity)
    }

    // MARK: - Copy

    private var title: String {
        switch activity.phase {
        case .waitingForDevice:
            return String(localized: "Insert your YubiKey", comment: "Hardware key overlay: wired key not yet inserted")
        case .touchRequired:
            return String(localized: "Touch your YubiKey", comment: "Hardware key overlay: waiting for physical touch")
        case .working:
            return String(localized: "Communicating with YubiKey…", comment: "Hardware key overlay: signing in progress")
        case .failed:
            return String(localized: "YubiKey Error", comment: "Hardware key overlay: operation failed")
        case .nfcPresented:
            return ""
        }
    }

    private var detail: String {
        switch activity.phase {
        case .waitingForDevice(let transport):
            switch transport {
            case .usbc:
                return String(localized: "Connect your YubiKey to the USB-C port.", comment: "Hardware key overlay: USB-C insert hint")
            case .lightning:
                return String(localized: "Connect your YubiKey to the Lightning port.", comment: "Hardware key overlay: Lightning insert hint")
            case .nfc:
                return ""
            }
        case .touchRequired:
            return String(localized: "Tap the metal contact on your YubiKey when it blinks.", comment: "Hardware key overlay: touch hint")
        case .failed(let message):
            return message
        case .working, .nfcPresented:
            return ""
        }
    }

    // MARK: - Buttons

    @ViewBuilder
    private var buttons: some View {
        switch activity.phase {
        case .failed:
            Button(role: .cancel, action: onCancel) {
                Label(String(localized: "Dismiss", comment: "Hardware key overlay: dismiss button"), systemImage: "xmark")
                    .frame(minWidth: 120)
            }
            .buttonStyle(.bordered)
        case .waitingForDevice, .touchRequired, .working:
            Button(role: .cancel, action: onCancel) {
                Label(String(localized: "Cancel", comment: "Hardware key overlay: cancel button"), systemImage: "xmark")
                    .frame(minWidth: 120)
            }
            .buttonStyle(.bordered)
        case .nfcPresented:
            EmptyView()
        }
    }

    // MARK: - Accessibility

    private var accessibilityLabel: String {
        switch activity.phase {
        case .waitingForDevice:
            return title + ". " + detail
        case .touchRequired:
            return title
        case .working:
            return title
        case .failed(let message):
            return title + ". " + message
        case .nfcPresented:
            return ""
        }
    }
}

#Preview("Insert (USB-C)") {
    HardwareKeyPromptView(
        activity: .init(phase: .waitingForDevice(transport: .usbc)),
        onCancel: {}
    )
}

#Preview("Insert (Lightning)") {
    HardwareKeyPromptView(
        activity: .init(phase: .waitingForDevice(transport: .lightning)),
        onCancel: {}
    )
}

#Preview("Touch") {
    HardwareKeyPromptView(
        activity: .init(phase: .touchRequired),
        onCancel: {}
    )
}

#Preview("Failed") {
    HardwareKeyPromptView(
        activity: .init(phase: .failed("The key was removed during signing.")),
        onCancel: {}
    )
}

// Steps through insert, touch, and dismissal on a loop, using the same
// persistent-container + animation(value:) structure as the presentation site
// so entrance, exit, and phase morphs are all visible in the canvas.
#Preview("Live walkthrough") {
    @Previewable @State var phase: HardwareKeyActivityCoordinator.Phase?
    ZStack {
        if let phase {
            HardwareKeyPromptView(activity: .init(phase: phase), onCancel: {})
        }
    }
    .animation(.spring(response: 0.38, dampingFraction: 0.8), value: phase)
    .task {
        let steps: [HardwareKeyActivityCoordinator.Phase?] = [
            .waitingForDevice(transport: .usbc),
            .touchRequired,
            nil,
        ]
        while !Task.isCancelled {
            for step in steps {
                try? await Task.sleep(for: .seconds(3))
                if Task.isCancelled { return }
                phase = step
            }
        }
    }
}
