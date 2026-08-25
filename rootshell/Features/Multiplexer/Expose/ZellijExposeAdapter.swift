//
//  ZellijExposeAdapter.swift
//  rootshell
//
//  zellij ≥ 0.45: `list-tabs --json` + `list-panes --json` for the tree and
//  geometry, `dump-screen --pane-id N --ansi` for content (reads any pane
//  without moving focus). Older releases lack all three and report
//  unsupported, which drops the exposé back to app tabs.
//

import Foundation

nonisolated struct ZellijExposeAdapter: MultiplexerExposeAdapter {
    let type = MultiplexerType.zellij

    private func zj(_ session: String?) -> String {
        session.map { "zellij -s \(MuxScript.dq($0)) action" } ?? "zellij action"
    }

    /// Same gate as ZellijSessionDiscovery: major > 0 or minor ≥ 45.
    private let versionGate =
        "command -v zellij >/dev/null 2>&1 || echo \(MuxScript.dq(MuxScript.unsupportedMarker))"
        + "; _zv=$(zellij --version 2>/dev/null | grep -oE \"[0-9]+\\.[0-9]+\" | head -1); _zmaj=${_zv%%.*}; _zmin=${_zv#*.}"
        + "; if [ \"${_zmaj:-0}\" -eq 0 ] 2>/dev/null && [ \"${_zmin:-0}\" -lt 45 ] 2>/dev/null; then echo \(MuxScript.dq(MuxScript.unsupportedMarker)); fi"

    func resolveSessionScript(nonce: String) -> String {
        // `--short` also lists exited sessions, which are not attachable and
        // would make a single live session look ambiguous.
        MuxScript.wrap(
            "echo \(MuxScript.dq(MuxScript.topology(nonce)))"
            + "; zellij list-sessions --no-formatting 2>/dev/null | grep -v EXITED | cut -d \" \" -f1",
            nonce: nonce
        )
    }

    func tickScript(session: String?, request: MuxTickRequest, nonce: String) -> String {
        var body = versionGate
        body += "; echo \(MuxScript.dq(MuxScript.topology(nonce)))"
        body += "; \(zj(session)) list-tabs --json 2>/dev/null; echo; echo \"::MX_PANES::\""
        body += "; \(zj(session)) list-panes --json 2>/dev/null; echo"
        for paneID in request.fetch {
            body += "; \(MuxScript.paneMarker(nonce: nonce, id: paneID))"
            body += "; \(zj(session)) dump-screen --pane-id \(MuxScript.dq(paneID)) --ansi 2>/dev/null; echo"
        }
        return MuxScript.wrap(body, nonce: nonce)
    }

    func parseTick(output: String, nonce: String) -> MuxTickResult? {
        let sections = MuxScript.sections(of: output, nonce: nonce)
        guard sections.found, !sections.unsupported else { return nil }
        let halves = sections.topology.components(separatedBy: "::MX_PANES::")
        guard halves.count == 2,
              let tabInfos = MuxScript.json(halves[0]) as? [[String: Any]],
              let paneInfos = MuxScript.json(halves[1]) as? [[String: Any]] else { return nil }

        var panesByTab: [Int: [[String: Any]]] = [:]
        for pane in paneInfos {
            guard let tabID = pane.mxInt("tab_id") else { continue }
            panesByTab[tabID, default: []].append(pane)
        }

        var cursors: [String: MuxCursor] = [:]
        var tabs: [MuxTab] = []
        for info in tabInfos.sorted(by: { ($0.mxInt("position") ?? 0) < ($1.mxInt("position") ?? 0) }) {
            guard let tabID = info.mxInt("tab_id") else { continue }
            let cols = info.mxInt("display_area_columns") ?? info.mxInt("viewport_columns") ?? 0
            let rows = info.mxInt("display_area_rows") ?? info.mxInt("viewport_rows") ?? 0
            var panes: [MuxPane] = []
            let members = (panesByTab[tabID] ?? [])
                .filter { !$0.mxBool("is_suppressed") && $0.mxBool("is_selectable") }
                // Tiled first so floating panes draw on top.
                .sorted { !$0.mxBool("is_floating") && $1.mxBool("is_floating") }
            for pane in members {
                guard let number = pane.mxInt("id") else { continue }
                let isPlugin = pane.mxBool("is_plugin")
                let id = isPlugin ? "plugin_\(number)" : "terminal_\(number)"
                let rect = MuxCellRect(
                    x: pane.mxInt("pane_content_x") ?? pane.mxInt("pane_x") ?? 0,
                    y: pane.mxInt("pane_content_y") ?? pane.mxInt("pane_y") ?? 0,
                    width: pane.mxInt("pane_content_columns") ?? pane.mxInt("pane_columns") ?? 0,
                    height: pane.mxInt("pane_content_rows") ?? pane.mxInt("pane_rows") ?? 0
                )
                if let coords = pane["cursor_coordinates_in_pane"] as? [Any], coords.count == 2,
                   let x = (coords[0] as? NSNumber)?.intValue, let y = (coords[1] as? NSNumber)?.intValue {
                    cursors[id] = MuxCursor(x: x, y: y, visible: true)
                } else {
                    cursors[id] = MuxCursor(x: 0, y: 0, visible: false)
                }
                panes.append(MuxPane(
                    id: id, rect: rect, isActive: pane.mxBool("is_focused"),
                    isPreviewable: !isPlugin, title: pane.mxString("title")
                ))
            }
            tabs.append(MuxTab(
                id: String(tabID),
                index: tabs.count,
                title: info.mxString("name") ?? "Tab \(tabs.count + 1)",
                isActive: info.mxBool("active"),
                cols: cols,
                rows: rows,
                panes: panes,
                badge: info.mxBool("has_bell_notification") ? "!" : nil
            ))
        }

        var frames: [String: MuxPaneFrame] = [:]
        for section in sections.panes {
            frames[section.id] = MuxPaneFrame(
                ansi: section.body,
                cursor: cursors[section.id],
                revision: MuxExposeIdentity.contentRevision(section.body)
            )
        }
        return MuxTickResult(
            snapshot: MuxExposeSnapshot(tabs: tabs, activeTabID: tabs.first(where: \.isActive)?.id),
            frames: frames,
            unchanged: [],
            truncated: sections.truncated
        )
    }

    func focusScript(session: String?, tabID: String) -> String {
        MuxScript.wrap("\(zj(session)) go-to-tab-by-id \(MuxScript.dq(tabID))", nonce: "focus")
    }
}
