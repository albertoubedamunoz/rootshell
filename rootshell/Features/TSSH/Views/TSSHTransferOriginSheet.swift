//
//  TSSHTransferOriginSheet.swift
//  rootshell
//
//  Sheet displayed on the originating device while a "Transfer to Nearby
//  Device" offer is advertising or in-flight. Drives the
//  TrzszTransferOriginator's NSUserActivity lifetime through its
//  presentation lifecycle.
//

import Combine
import SwiftUI

struct TrzszTransferOriginSheet: View {
    let originator: TrzszTransferOriginator
    let displayName: String
    let onDismiss: () -> Void

    @StateObject private var observable: ObservableOriginator
    @Environment(\.sheetThemeColors) private var sheetThemeColors

    init(
        originator: TrzszTransferOriginator,
        displayName: String,
        onDismiss: @escaping () -> Void
    ) {
        self.originator = originator
        self.displayName = displayName
        self.onDismiss = onDismiss
        _observable = StateObject(wrappedValue: ObservableOriginator(wrapped: originator))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                if let bg = sheetThemeColors?.background {
                    bg.ignoresSafeArea()
                }
                VStack(spacing: 0) {
                    ScrollView {
                        VStack(spacing: 24) {
                            statusIcon
                                .font(.system(size: 60))
                                .foregroundStyle(statusTint)

                            Text(headline)
                                .font(.title2.weight(.semibold))
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)

                            if let detail {
                                Text(detail)
                                    .font(.body)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(.horizontal)
                            }

                            if isInProgress {
                                ProgressView()
                                    .controlSize(.large)
                                    .padding(.top, 8)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                    }

                    if let primaryLabel {
                        Button {
                            onDismiss()
                        } label: {
                            Text(primaryLabel)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .padding(.horizontal)
                        .padding(.bottom)
                    }
                }
                .padding(.horizontal)
            }
            .navigationTitle(String(localized: "Transfer Session"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if !originator.isTerminalStatus {
                        Button(String(localized: "Cancel")) {
                            originator.cancel()
                            onDismiss()
                        }
                    }
                }
            }
            .onAppear {
                originator.start()
            }
            .onDisappear {
                originator.cancel()
            }
            .interactiveDismissDisabled(isInProgress)
        }
    }

    private var isInProgress: Bool {
        switch observable.status {
        case .advertising, .negotiating, .sendingPayload, .waitingForAck:
            return true
        default:
            return false
        }
    }

    private var statusIcon: Image {
        switch observable.status {
        case .completed:
            return Image(systemName: "checkmark.circle.fill")
        case .failed, .cancelled:
            return Image(systemName: "xmark.octagon.fill")
        default:
            return Image(systemName: "ipad.and.arrow.forward")
        }
    }

    private var statusTint: Color {
        switch observable.status {
        case .completed: return .green
        case .failed: return .red
        case .cancelled: return .secondary
        default: return .accentColor
        }
    }

    private var headline: String {
        switch observable.status {
        case .advertising:
            return String(localized: "Looking for nearby device…")
        case .negotiating:
            return String(localized: "Connecting…")
        case .sendingPayload, .waitingForAck:
            return String(localized: "Transferring \(displayName)…")
        case .completed(let peer):
            return String(localized: "Sent to \(peer)")
        case .failed:
            return String(localized: "Transfer failed")
        case .cancelled:
            return String(localized: "Transfer cancelled")
        }
    }

    private var detail: String? {
        switch observable.status {
        case .advertising:
            return String(localized: "Open rootshell on another iPhone, iPad, Mac, or Vision Pro signed in to the same iCloud account, then tap the Handoff banner.\n\nOn Mac and iPad the banner appears at the right end of the Dock. On iPhone, swipe up from the bottom edge and pause to open the App Switcher. The banner is at the bottom of the screen.")
        case .negotiating:
            return String(localized: "Exchanging encryption keys.")
        case .sendingPayload:
            return String(localized: "Encrypting and sending session data.")
        case .waitingForAck:
            return String(localized: "Waiting for the other device to attach.")
        case .completed:
            return String(localized: "This tab will close automatically.")
        case .failed(let message):
            return message
        case .cancelled:
            return nil
        }
    }

    private var primaryLabel: String? {
        switch observable.status {
        case .completed: return String(localized: "Done")
        case .failed: return String(localized: "Close")
        case .cancelled: return String(localized: "Close")
        default: return nil
        }
    }
}

/// Bridges the originator's `@Published status` into a SwiftUI-observable
/// object. The originator itself isn't an ObservableObject because it's a
/// long-lived coordinator that may outlive the sheet.
@MainActor
private final class ObservableOriginator: ObservableObject {
    @Published var status: TrzszTransferOriginator.Status = .advertising
    private let wrapped: TrzszTransferOriginator
    private var cancellables: Set<AnyCancellable> = []

    init(wrapped: TrzszTransferOriginator) {
        self.wrapped = wrapped
        self.status = wrapped.status
        wrapped.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] new in
                self?.status = new
            }
            .store(in: &cancellables)
    }
}
