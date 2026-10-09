//
//  ProgramStatusRecords.swift
//  rootshell
//
//  The per-pane records of the OSC 7501 program status protocol. The terminal
//  keeps none, so the embedder applies the specification's rules here: one
//  record per id, a report replaces its record, `clear` removes an id and the
//  records beneath it, and a new prompt ends work that was still live.
//

import Foundation

struct ProgramStatusRecords {
    struct Record: Equatable {
        var state: Ghostty.Action.ProgramStatus.State
        var kind: Ghostty.Action.ProgramStatus.Kind
        var progress: UInt8?
        var app: String
        var title: String
        var msg: String
        var updated: UInt64
    }

    /// The specification asks terminals to keep at least 64 records and
    /// evict the least recently updated past their limit.
    static let maxRecords = 64

    private(set) var records: [String: Record] = [:]
    private var clock: UInt64 = 0

    mutating func apply(_ report: Ghostty.Action.ProgramStatus) {
        if report.state == .clear {
            if report.id.isEmpty {
                records.removeAll()
            } else {
                let prefix = report.id + "/"
                records = records.filter { $0.key != report.id && !$0.key.hasPrefix(prefix) }
            }
            return
        }

        clock &+= 1
        records[report.id] = Record(
            state: report.state,
            kind: report.kind,
            progress: report.progress,
            app: report.app,
            title: report.title,
            msg: report.msg,
            updated: clock)
        if records.count > Self.maxRecords,
           let oldest = records.min(by: { $0.value.updated < $1.value.updated })?.key {
            records[oldest] = nil
        }
    }

    /// A new prompt or the program exiting ends working, blocked and idle
    /// records, so a program killed before its `clear` doesn't keep the pane.
    /// Finished results stay until the program replaces or clears them.
    mutating func dropUnfinished() {
        records = records.filter { $0.value.state == .done || $0.value.state == .error }
    }

    /// The record that speaks for the pane: the most urgent, then the newest.
    var summary: Record? {
        records.values.max { a, b in
            (Self.priority(a.state), a.updated) < (Self.priority(b.state), b.updated)
        }
    }

    private static func priority(_ state: Ghostty.Action.ProgramStatus.State) -> Int {
        switch state {
        case .blocked: return 5
        case .error: return 4
        case .done: return 3
        case .working: return 2
        case .idle: return 1
        case .clear: return 0
        }
    }
}

extension ProgramStatusRecords.Record {
    var attentionStatus: AgentAttentionStatus {
        switch state {
        case .blocked: return .blocked
        case .error: return .failed
        case .done: return .done
        case .working: return .working
        case .idle, .clear: return .idle
        }
    }
}
