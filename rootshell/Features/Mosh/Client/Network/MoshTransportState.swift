//
//  MoshSyncableState.swift
//  rootshell
//
//  Protocol for syncable state used by outbound/inbound synchronizers
//

import Foundation

protocol MoshSyncableState: AnyObject, Equatable {
    func encodeDelta(since existing: Self) -> Data
    func encodeSnapshot() -> Data
    func applyDelta(_ payload: Data)
    func pruneAcknowledged(_ baseline: Self?)
    func hasCellDifferences(from other: Self) -> Bool
    func resetParser()
    func copy() -> Self
}
