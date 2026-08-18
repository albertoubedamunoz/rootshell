//
//  MoshInputEventStream.swift
//  rootshell
//

import Foundation

enum MoshInputEvent: Equatable, Sendable {
    case keystroke(UInt8)
    case resize(width: Int, height: Int)
}

final class MoshInputEventStream: MoshSyncableState, Equatable {
    private var events: [MoshInputEvent] = []

    func append(keystroke byte: UInt8) {
        events.append(.keystroke(byte))
    }

    func append(resize width: Int, height: Int) {
        events.append(.resize(width: width, height: height))
    }

    var isEmpty: Bool { events.isEmpty }
    var count: Int { events.count }

    func pruneAcknowledged(_ baseline: MoshInputEventStream?) {
        guard let baseline = baseline else { return }
        if self === baseline {
            events.removeAll()
            return
        }
        for event in baseline.events {
            precondition(!events.isEmpty)
            precondition(event == events.first!)
            events.removeFirst()
        }
    }

    func encodeDelta(since existing: MoshInputEventStream) -> Data {
        var myIndex = 0
        for event in existing.events {
            precondition(myIndex < events.count)
            precondition(event == events[myIndex])
            myIndex += 1
        }

        var message = UserMessage()
        var keystrokeBuffer = Data()

        func flushKeystroke() {
            guard !keystrokeBuffer.isEmpty else { return }
            message.instructions.append(.keystroke(keystrokeBuffer))
            keystrokeBuffer.removeAll(keepingCapacity: true)
        }

        while myIndex < events.count {
            switch events[myIndex] {
            case .keystroke(let byte):
                keystrokeBuffer.append(byte)
            case .resize(let width, let height):
                flushKeystroke()
                message.instructions.append(.resize(width: UInt32(width), height: UInt32(height)))
            }
            myIndex += 1
        }

        flushKeystroke()
        return (try? message.serialize()) ?? Data()
    }

    func encodeSnapshot() -> Data {
        let empty = MoshInputEventStream()
        return encodeDelta(since: empty)
    }

    func applyDelta(_ payload: Data) {
        guard let msg = try? UserMessage.deserialize(payload) else { return }
        for instruction in msg.instructions {
            switch instruction {
            case .keystroke(let data):
                for byte in data {
                    events.append(.keystroke(byte))
                }
            case .resize(let width, let height):
                events.append(.resize(width: Int(width), height: Int(height)))
            }
        }
    }

    func resetParser() {
        // No parser state to reset for user stream
    }

    func hasCellDifferences(from other: MoshInputEventStream) -> Bool {
        return false
    }

    func copy() -> MoshInputEventStream {
        let copy = MoshInputEventStream()
        copy.events = events
        return copy
    }

    static func == (lhs: MoshInputEventStream, rhs: MoshInputEventStream) -> Bool {
        lhs.events == rhs.events
    }
}
