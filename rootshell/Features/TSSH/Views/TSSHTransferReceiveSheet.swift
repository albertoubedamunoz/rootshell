//
//  TSSHTransferReceiveSheet.swift
//  rootshell
//
//  Sheet displayed on the receiving device when an Apple Continuity Handoff
//  offer for a tssh session arrives. Confirms with the user, drives the
//  TrzszTransferReceiver, and on success notifies the host MainView to
//  open a new tab via `.trzszTransfer(...)`.
//

import Combine
import SwiftUI

struct TrzszTransferReceiveSheet: View {
    let offer: TrzszTransferReceiver.Offer
    let onAcceptedTab: (UUID, String, String) -> Void  // ticketID, displayName, host
    let onDismiss: () -> Void

    @StateObject private var observable: ObservableReceiver
    @State private var isAccepting = false
    @Environment(\.sheetThemeColors) private var sheetThemeColors

    init(
        offer: TrzszTransferReceiver.Offer,
        onAcceptedTab: @escaping (UUID, String, String) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.offer = offer
        self.onAcceptedTab = onAcceptedTab
        self.onDismiss = onDismiss
        let receiver = TrzszTransferReceiver(offer: offer) { ticketID, payload in
            onAcceptedTab(ticketID, payload.displayName, payload.sshConfig.host)
        }
        _observable = StateObject(wrappedValue: ObservableReceiver(wrapped: receiver))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                if let bg = sheetThemeColors?.background {
                    bg.ignoresSafeArea()
                }
                VStack(spacing: 24) {
                    Spacer()
                    Image(systemName: statusIcon)
                        .font(.system(size: 64))
                        .foregroundStyle(statusTint)

                    Text(headline)
                        .font(.title2.weight(.semibold))
                        .multilineTextAlignment(.center)

                    if let detail {
                        Text(detail)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }

                    if isInProgress {
                        ProgressView()
                            .controlSize(.large)
                            .padding(.top, 8)
                    }

                    Spacer()

                    actionButtons
                }
                .padding()
            }
            .navigationTitle(String(localized: "Incoming Session"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if !observable.status.isTerminal {
                        Button(isAccepting ? String(localized: "Cancel") : String(localized: "Decline")) {
                            observable.wrapped.cancel()
                            onDismiss()
                        }
                    }
                }
            }
            .interactiveDismissDisabled(isInProgress)
            .onReceive(NotificationCenter.default.publisher(for: .trzszTransferShouldCancelForBackground)) { _ in
                // App is backgrounding — tear the transfer down so the
                // Continuity streams close before the watchdog hits.
                if !observable.status.isTerminal {
                    observable.wrapped.cancel()
                }
                onDismiss()
            }
            .onChange(of: observable.status) { _, newValue in
                if case .completed = newValue {
                    onDismiss()
                }
            }
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        switch observable.status {
        case .idle:
            Button {
                isAccepting = true
                observable.wrapped.accept(requestedCols: 80, requestedRows: 24)
            } label: {
                Text(String(localized: "Accept"))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal)

        case .completed, .failed, .cancelled:
            Button {
                onDismiss()
            } label: {
                Text(String(localized: "Close"))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal)

        default:
            EmptyView()
        }
    }

    private var isInProgress: Bool {
        switch observable.status {
        case .openingStreams, .negotiating, .awaitingAttach:
            return true
        default:
            return false
        }
    }

    private var statusIcon: String {
        switch observable.status {
        case .idle:
            return "ipad.and.arrow.forward"
        case .completed:
            return "checkmark.circle.fill"
        case .failed, .cancelled:
            return "xmark.octagon.fill"
        default:
            return "ipad.and.arrow.forward"
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
        case .idle:
            return String(localized: "Accept transfer of \(offer.displayName)?")
        case .openingStreams, .negotiating:
            return String(localized: "Connecting to \(offer.originDeviceName)…")
        case .awaitingAttach:
            return String(localized: "Attaching to \(offer.host)…")
        case .completed:
            return String(localized: "Connected")
        case .failed:
            return String(localized: "Transfer failed")
        case .cancelled:
            return String(localized: "Transfer cancelled")
        }
    }

    private var detail: String? {
        switch observable.status {
        case .idle:
            return String(localized: "From \(offer.originDeviceName). Recent scrollback will be transferred and the original tab will close once attached.")
        case .openingStreams:
            return String(localized: "Opening Continuity stream.")
        case .negotiating:
            return String(localized: "Exchanging encryption keys.")
        case .awaitingAttach:
            return String(localized: "Reattaching to the existing remote session.")
        case .completed:
            return String(localized: "The session is now running on this device.")
        case .failed(let message):
            return message
        case .cancelled:
            return nil
        }
    }
}

@MainActor
private final class ObservableReceiver: ObservableObject {
    let wrapped: TrzszTransferReceiver
    @Published var status: TrzszTransferReceiver.Status = .idle
    private var cancellables: Set<AnyCancellable> = []

    init(wrapped: TrzszTransferReceiver) {
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

private extension TrzszTransferReceiver.Status {
    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled: return true
        default: return false
        }
    }
}
