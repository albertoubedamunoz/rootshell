import SwiftUI

/// Poll only while presented and foregrounded. Keep native controller/surface
/// references out of the Sendable sheet payload and resolve them per refresh.
struct TmuxConnectionInfoSections: View {
    let request: TmuxConnectionInfo
    @Environment(\.scenePhase) private var scenePhase
    @State private var snapshot: TmuxConnectionSnapshot?
    @State private var errorMessage: String?
    @State private var isRefreshing = false
    @State private var ended = false
    @State private var refreshRevision = 0
    @State private var resolvedControllerID: UUID?

    private struct RefreshKey: Hashable {
        let active: Bool
        let revision: Int
        let ended: Bool
    }

    var body: some View {
        Group {
            statusSection
            if let snapshot {
                serverSection(snapshot.server)
                sessionSection(snapshot.session)
                clientSection(snapshot.client, counters: snapshot.counters)
                if request.windowID != nil { tabSection(snapshot) }
            }
        }
    }

    // Attach lifecycle work to one stable section, not to the group of sections.
    private var statusSection: some View {
        Section("tmux Control Mode") {
            if snapshot == nil && errorMessage == nil {
                ProgressView("Loading tmux information…")
                    .themedRow()
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .themedRow()
            }
            if let snapshot {
                HStack {
                    Text(errorMessage == nil ? "Updated" : "Last Updated · Stale")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(snapshot.updatedAt, style: .time)
                }
                .themedRow()
            }
            if errorMessage != nil && !ended {
                Button("Retry") { refreshRevision += 1 }
                    .disabled(isRefreshing)
                    .themedRow()
            }
        }
        .task(id: RefreshKey(active: scenePhase == .active, revision: refreshRevision, ended: ended)) {
            guard scenePhase == .active, !ended else { return }
            while !Task.isCancelled && !ended {
                await refresh()
                do { try await Task.sleep(for: .seconds(5)) }
                catch { return }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .tmuxAttachedSessionDidChange)) { note in
            guard note.object as? UUID == request.gatewayID else { return }
            snapshot = nil
            errorMessage = nil
            refreshRevision += 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .tmuxControlModeDidEnd)) { note in
            guard note.object as? UUID == request.gatewayID else { return }
            ended = true
            errorMessage = TmuxCommandError.gatewayEnded.localizedDescription
        }
    }

    @MainActor
    private func refresh() async {
        // A canceled query may still be draining its command reply. Do not
        // enqueue a second refresh until it returns (or its timeout fires).
        guard !isRefreshing, !ended, !Task.isCancelled else { return }
        guard let controller = TmuxWindowRegistry.gatewayView(ownerTerminalUUID: request.gatewayID)?.tmuxController else {
            errorMessage = TmuxConnectionInfoError.unavailable.localizedDescription
            if resolvedControllerID != nil || request.controllerID != nil { ended = true }
            return
        }
        let expectedID = request.controllerID ?? resolvedControllerID
        guard !controller.didEnd, !controller.isDetaching, !controller.ownerSurfaceFreed,
              expectedID == nil || expectedID == controller.connectionInfoID else {
            ended = true
            errorMessage = TmuxCommandError.gatewayEnded.localizedDescription
            return
        }
        resolvedControllerID = controller.connectionInfoID
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let result = try await controller.connectionSnapshot(for: request)
            try Task.checkCancellation()
            guard !ended,
                  TmuxWindowRegistry.gatewayView(ownerTerminalUUID: request.gatewayID)?.tmuxController === controller else { return }
            snapshot = result
            errorMessage = nil
        } catch is CancellationError {
            // Dismissal, backgrounding, or a newer refresh invalidated this result.
        } catch {
            guard !Task.isCancelled, !ended else { return }
            errorMessage = error.localizedDescription
            if controller.didEnd || controller.isDetaching || controller.ownerSurfaceFreed { ended = true }
        }
    }

    private func serverSection(_ server: TmuxConnectionSnapshot.Server) -> some View {
        Section("tmux Server") {
            row("Version", server.version)
            row("Host", server.host)
            row("PID", server.pid.map { String($0) })
            row("Socket", server.socketPath)
            ageRow("Uptime", since: server.startedAt)
        }
    }

    private func sessionSection(_ session: TmuxConnectionSnapshot.Session) -> some View {
        Section("tmux Session") {
            row("Name", session.name)
            row("Session ID", "$\(session.id)")
            ageRow("Age", since: session.createdAt)
            row("Windows", session.windows.map { String($0) })
            row("Panes", session.panes.map { String($0) })
            row("Attached Clients", session.attachedClients.map { String($0) })
        }
    }

    private func clientSection(_ client: TmuxConnectionSnapshot.Client,
                               counters: TmuxConnectionSnapshot.Counters?) -> some View {
        Section {
            row("Client", client.name)
            ageRow("Connected", since: client.createdAt)
            row("Flags", client.flags)
            row("Control Bytes Received", counters?.receivedBytes.map { PerfFormat.bytes($0) })
            row("Output Events", counters.map { $0.outputEvents.formatted() })
            row("Notifications", counters.map { $0.notifications.formatted() })
        } header: {
            Text("tmux Control Client")
        } footer: {
            Text("Received bytes count the gateway’s control stream, including protocol messages. Counters restart when the control viewer is recreated. These are not network transport byte counts.")
        }
    }

    private func tabSection(_ snapshot: TmuxConnectionSnapshot) -> some View {
        Section("This tmux Tab") {
            row("Window ID", request.windowID.map { "@\($0)" })
            row("Window", snapshot.window?.name)
            row("Index", snapshot.window?.index.map { String($0) })
            row("Panes", snapshot.window?.panes.map { String($0) })
            row("Window Size", dimensions(snapshot.window?.width, snapshot.window?.height))
            if let paneID = request.paneID {
                row("Pane ID", "%\(paneID)")
                row("Pane Size", dimensions(snapshot.pane?.width, snapshot.pane?.height))
            }
            if snapshot.window == nil {
                Text("This window is no longer in the attached session.")
                    .foregroundStyle(.secondary)
                    .themedRow()
            }
        }
    }

    private func dimensions(_ width: Int?, _ height: Int?) -> String? {
        guard let width, let height else { return nil }
        return "\(width) × \(height)"
    }

    private func ageRow(_ label: String, since date: Date?) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            row(label, date.map { ConnectionInfoSheet.formatDuration(from: $0, to: context.date) })
        }
        .themedRow()
    }

    private func row(_ label: String, _ value: String?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value ?? "—")
                .font(.system(.body, design: .monospaced))
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .themedRow()
    }
}
