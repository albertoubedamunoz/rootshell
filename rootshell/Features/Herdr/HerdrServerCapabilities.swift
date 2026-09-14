//
//  HerdrServerCapabilities.swift
//  rootshell
//
//  What the running herdr server advertised in `control.open`. Every
//  behaviour split in control mode keys off these, never off the version
//  string: the feature list wins over the stream protocol number.
//
//  Copyright (c) 2026 Kit Knox / Rootshell LLC
//

import Foundation

nonisolated struct HerdrServerCapabilities: Equatable, Sendable {

    enum Feature: String, CaseIterable {
        case sharedAttach = "shared_attach"
        case geometryOwnership = "geometry_ownership"
        case geometryController = "geometry_controller"
        case controlList = "control_list"
        case clientIdentity = "client_identity"
        case queryAuthority = "query_authority"
        case eventDrain = "event_drain"
        case eventGap = "event_gap"
        /// `terminal.input` accepts `auto` for a terminal's own replies.
        case autoInput = "auto_input"
    }

    /// `terminal_control_stream`; 0 when the server has no control stream.
    let streamProtocol: Int
    let features: Set<String>
    let serverPid: Int?
    let liveHandoff: Bool

    static let none = HerdrServerCapabilities(streamProtocol: 0, features: [], serverPid: nil, liveHandoff: false)

    init(streamProtocol: Int, features: Set<String>, serverPid: Int?, liveHandoff: Bool) {
        self.streamProtocol = streamProtocol
        self.features = features
        self.serverPid = serverPid
        self.liveHandoff = liveHandoff
    }

    init(_ raw: HerdrControl.Capabilities?) {
        streamProtocol = raw?.terminal_control_stream ?? 0
        features = Set(raw?.control_features ?? [])
        serverPid = raw?.server_pid
        liveHandoff = raw?.live_handoff ?? false
    }

    var hasControlStream: Bool { streamProtocol >= HerdrControl.requiredStreamProtocol }

    func supports(_ feature: Feature) -> Bool {
        streamProtocol >= HerdrControl.preferredStreamProtocol && features.contains(feature.rawValue)
    }

    /// Several clients on one tab, with the server tracking who sizes it.
    var supportsSharedViewing: Bool {
        supports(.sharedAttach) && supports(.geometryOwnership) && supports(.geometryController)
    }

    var sortedFeatures: [String] { features.sorted() }
}
