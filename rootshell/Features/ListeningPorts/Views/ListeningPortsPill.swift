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
    /// Diameter of the collapsed globe button, in points.
    static let globeSize: CGFloat = 39

    @ObservedObject var terminal: Ghostty.TerminalView
    let onOpen: (PortPreview) -> Void
    /// Width the pill may occupy inside the terminal column. The chip row is
    /// clamped to this, so a narrow pane scrolls instead of overflowing.
    let maxWidth: CGFloat

    @State private var expanded = false
    @State private var hovering = false
    @State private var collapseTask: Task<Void, Never>?
    @State private var busyPort: UInt16?
    /// Remote port -> local port, read back from the connection's forwards.
    @State private var localPorts: [UInt16: UInt16] = [:]
    @State private var errorMessage: String?
    /// Natural width of the chip row, measured so the scroller can be sized
    /// to the content when it fits and clamped when it does not.
    @State private var chipsWidth: CGFloat = 0

    private static let collapseDelay: Duration = .seconds(3)

    var body: some View {
        if !terminal.remotePorts.isEmpty {
            HStack(spacing: 4) {
                globeButton

                if expanded {
                    // The chips stay on one line. When the pane is too narrow
                    // for them — an iPhone in portrait leaves room for a few —
                    // the row scrolls sideways instead of pushing the globe
                    // offscreen or clipping the last ports.
                    portScroller
                }
            }
            .padding(.horizontal, expanded ? 8 : 0)
            .frame(height: 39)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
            .padding(.leading, 12)
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
            .onAppear(perform: refreshLocalPorts)
            .onChange(of: terminal.remotePorts) { _, _ in refreshLocalPorts() }
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
                // The ports went away; the next ones start collapsed.
                collapseTask?.cancel()
                collapseTask = nil
                expanded = false
            }
        }
    }

    /// The chip row, scrolled sideways when the pane cannot show every port.
    private var portScroller: some View {
        ScrollView(.horizontal) {
            portRow
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: PortRowWidthKey.self, value: proxy.size.width)
                    }
                )
        }
        .scrollIndicators(.hidden)
        .scrollDisabled(!isChipRowScrollable)
        .frame(width: chipRowWidth)
        // A small overlay scroll view; UIKit 26 would blur its edges.
        .modifier(ScrollEdgeEffectHiddenModifier())
        .onPreferenceChange(PortRowWidthKey.self) { width in
            guard abs(width - chipsWidth) > 0.5 else { return }
            chipsWidth = width
        }
    }

    /// Room left for chips once the globe and the pill's padding are paid for.
    private var chipSpace: CGFloat {
        max(0, maxWidth - Self.globeSize - 16 - 4)
    }

    /// nil until the row has been measured, so the first pass keeps its ideal size.
    private var chipRowWidth: CGFloat? {
        guard chipsWidth > 0 else { return nil }
        return min(chipsWidth, chipSpace)
    }

    private var isChipRowScrollable: Bool { chipsWidth > chipSpace + 0.5 }

    private var portRow: some View {
        HStack(spacing: 4) {
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
                .frame(width: Self.globeSize, height: Self.globeSize)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .frame(width: Self.globeSize, height: Self.globeSize)
        .accessibilityLabel("Remote Ports")
    }

    private func chip(for port: RemotePort) -> some View {
        let local = localPorts[port.number]
        let isActive = local != nil
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
            if isActive {
                Button(role: .destructive) {
                    Task {
                        await terminal.remotePortForwarder.stop(remotePort: port.number)
                        refreshLocalPorts()
                    }
                } label: {
                    Label("Stop Forward", systemImage: "xmark.circle")
                }
            }
        }
    }

    private func refreshLocalPorts() {
        var ports: [UInt16: UInt16] = [:]
        for port in terminal.remotePorts {
            ports[port.number] = terminal.remotePortForwarder.localPort(for: port.number)
        }
        if ports != localPorts { localPorts = ports }
    }

    private func expand() {
        collapseTask?.cancel()
        collapseTask = nil
        refreshLocalPorts()
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
            defer {
                busyPort = nil
                refreshLocalPorts()
            }
            do {
                let localPort = try await terminal.remotePortForwarder.forward(port)
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
            defer {
                busyPort = nil
                refreshLocalPorts()
            }
            do {
                let localPort = try await terminal.remotePortForwarder.forward(port)
                UIPasteboard.general.string = "http://127.0.0.1:\(localPort)/"
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// Natural width of the chip row, so the scroller can clamp itself to the pane.
private struct PortRowWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
