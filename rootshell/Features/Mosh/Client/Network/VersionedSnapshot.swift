//
//  VersionedSnapshot.swift
//  rootshell
//

import Foundation

/// A state snapshot tagged with a protocol version number and capture time.
/// Used by both the outbound synchronizer and inbound assembler to track
/// versioned state history.
struct VersionedSnapshot<State: MoshSyncableState> {
    var capturedAt: UInt64
    var version: UInt64
    var state: State
}
