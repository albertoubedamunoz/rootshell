//
//  FileListSelection.swift
//  rootshell
//
//  Cursor and multi-selection over a list of paths, shared by keyboard,
//  pointer and touch. Tracks paths, not indexes, so it survives a refresh.
//

import Foundation

nonisolated struct FileListSelection: Equatable, Sendable {
    enum ClickModifier: Sendable {
        case none
        /// ⌘-click: toggle one item.
        case toggle
        /// ⇧-click: extend from the anchor.
        case range
    }

    private(set) var selected: Set<String> = []
    private(set) var cursor: String?
    private var anchor: String?

    var isEmpty: Bool { selected.isEmpty }
    var count: Int { selected.count }

    func contains(_ path: String) -> Bool { selected.contains(path) }

    /// The selection, or the cursor item when nothing is selected.
    func effectivePaths(in paths: [String]) -> [String] {
        if !selected.isEmpty { return paths.filter(selected.contains) }
        return cursor.map { [$0] } ?? []
    }

    /// Moves the cursor; with `extending`, grows or shrinks a range from the anchor.
    mutating func moveCursor(by delta: Int, in paths: [String], extending: Bool) {
        guard !paths.isEmpty else { return }
        let current = cursor.flatMap(paths.firstIndex(of:))
        let next: Int
        if let current {
            next = min(max(current + delta, 0), paths.count - 1)
        } else {
            next = delta >= 0 ? 0 : paths.count - 1
        }
        if extending {
            if anchor == nil { anchor = cursor ?? paths[next] }
            cursor = paths[next]
            selectRange(in: paths)
        } else {
            cursor = paths[next]
            anchor = cursor
        }
    }

    mutating func setCursor(_ path: String?) {
        cursor = path
        anchor = path
    }

    /// Space / checkmark: flips the cursor item.
    mutating func toggleCursor() {
        guard let cursor else { return }
        toggle(cursor)
    }

    mutating func toggle(_ path: String) {
        if selected.contains(path) { selected.remove(path) } else { selected.insert(path) }
        cursor = path
        anchor = path
    }

    mutating func click(_ path: String, in paths: [String], modifier: ClickModifier) {
        switch modifier {
        case .none:
            selected = [path]
            cursor = path
            anchor = path
        case .toggle:
            toggle(path)
        case .range:
            if anchor == nil { anchor = cursor ?? path }
            cursor = path
            selectRange(in: paths)
        }
    }

    mutating func selectAll(_ paths: [String]) {
        selected = Set(paths)
    }

    mutating func clear() {
        selected = []
        anchor = cursor
    }

    /// Drops paths that no longer exist and keeps the cursor on a visible row.
    mutating func reconcile(with paths: [String]) {
        let visible = Set(paths)
        selected.formIntersection(visible)
        if let current = cursor, !visible.contains(current) { cursor = paths.first }
        if let current = anchor, !visible.contains(current) { anchor = cursor }
    }

    private mutating func selectRange(in paths: [String]) {
        guard let anchor, let cursor,
              let start = paths.firstIndex(of: anchor),
              let end = paths.firstIndex(of: cursor) else { return }
        selected = Set(paths[min(start, end)...max(start, end)])
    }
}
