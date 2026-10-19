//
//  ListeningPortsPill.swift
//  rootshell
//
//  Bottom-right remote-port control. Collapsed it is a single globe; hovering
//  (or tapping on touch devices) reveals the ports, and a click opens the
//  page in a new app tab. After the pointer leaves, the ports stay for three
//  seconds and then collapse back to the globe.
//

import SwiftUI
import UIKit

struct PortPreview: Identifiable {
    let id = UUID()
    let remotePort: UInt16
    let url: URL
    /// The terminal's effective font size when the page was opened. The web
    /// view zooms against a 16 pt baseline so text matches the terminal.
    let fontSize: Double
}

struct ListeningPortsPill: View {
    @ObservedObject var terminal: Ghostty.TerminalView
    let onOpen: (PortPreview) -> Void

    @State private var expanded = false
    @State private var hovering = false
    @State private var collapseTask: Task<Void, Never>?
    @State private var busyPort: UInt16?
    @State private var activePorts: Set<UInt16> = []
    @State private var errorMessage: String?

    private static let collapseDelay: Duration = .seconds(3)

    var body: some View {
        if !terminal.remotePorts.isEmpty {
            HStack(spacing: 4) {
                globeButton

                if expanded {
                    ForEach(terminal.remotePorts) { port in
                        chip(for: port)
                    }
                    if let busyPort {
                        ProgressView()
                            .controlSize(.mini)
                            .padding(.horizontal, 4)
                            .accessibilityLabel("Opening port \(busyPort)")
                    }
                }
            }
            .padding(.horizontal, expanded ? 8 : 0)
            .frame(height: 39)
            .fixedSize(horizontal: true, vertical: false)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
            .padding(.trailing, 12)
            .padding(.bottom, 10)
            .onHover { inside in
                hovering = inside
                if inside {
                    expand()
                } else {
                    scheduleCollapse()
                }
            }
            .onChange(of: terminal.remotePorts.isEmpty) { _, empty in
                if empty {
                    collapseTask?.cancel()
                    expanded = false
                }
            }
            .alert(
                "Could Not Open Port",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .animation(.easeInOut(duration: 0.16), value: expanded)
            .onDisappear {
                collapseTask?.cancel()
                collapseTask = nil
            }
        }
    }

    private var globeButton: some View {
        Button {
            if expanded {
                collapse()
            } else {
                // Touch: keep the ports open until the globe is tapped again
                // or a port is chosen. Only a pointer leaving schedules the
                // three-second collapse.
                expand()
            }
        } label: {
            Image(systemName: "globe")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 39, height: 39)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .frame(width: 39, height: 39)
        .accessibilityLabel("Remote Ports")
    }

    private func chip(for port: RemotePort) -> some View {
        let local = terminal.remotePortForwarder.localPort(for: port.number)
        let isActive = activePorts.contains(port.number) || local != nil
        return Button {
            open(port)
        } label: {
            HStack(spacing: 2) {
                Text(port.display)
                if let local, local != port.number {
                    Text("→\(local)")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 14, weight: isActive ? .semibold : .regular, design: .monospaced))
            .foregroundStyle(isActive ? Color.accentColor : Color.primary)
            .padding(.horizontal, 7)
            .frame(height: 27)
            .background(
                (isActive ? Color.accentColor : Color.primary).opacity(isActive ? 0.16 : 0.10),
                in: Capsule()
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(busyPort != nil)
        .accessibilityLabel(port.address)
        .contextMenu {
            Button {
                copyLocalURL(port)
            } label: {
                Label("Copy Local URL", systemImage: "doc.on.doc")
            }
            if isActive, terminal.remotePortForwarder.canStop(remotePort: port.number) {
                Button(role: .destructive) {
                    Task {
                        await terminal.remotePortForwarder.stop(remotePort: port.number)
                        activePorts.remove(port.number)
                    }
                } label: {
                    Label("Stop Forward", systemImage: "xmark.circle")
                }
            }
        }
    }

    private func expand() {
        collapseTask?.cancel()
        collapseTask = nil
        expanded = true
    }

    private func collapse() {
        collapseTask?.cancel()
        collapseTask = nil
        expanded = false
    }

    private func scheduleCollapse() {
        collapseTask?.cancel()
        collapseTask = Task { @MainActor in
            try? await Task.sleep(for: Self.collapseDelay)
            guard !Task.isCancelled else { return }
            expanded = false
            collapseTask = nil
        }
    }

    private func open(_ port: RemotePort) {
        guard busyPort == nil else { return }
        busyPort = port.number
        Task {
            defer { busyPort = nil }
            do {
                let localPort = try await terminal.remotePortForwarder.forward(port)
                activePorts.insert(port.number)
                collapse()
                guard let url = URL(string: "http://127.0.0.1:\(localPort)/") else { return }
                let fontSize = terminal.fontSizeOverride ?? FontManager.shared.currentFontSize
                onOpen(PortPreview(remotePort: port.number, url: url, fontSize: fontSize))
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func copyLocalURL(_ port: RemotePort) {
        guard busyPort == nil else { return }
        busyPort = port.number
        Task {
            defer { busyPort = nil }
            do {
                let localPort = try await terminal.remotePortForwarder.forward(port)
                activePorts.insert(port.number)
                UIPasteboard.general.string = "http://127.0.0.1:\(localPort)/"
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
