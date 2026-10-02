//
//  DirectInterfaceMonitor.swift
//  VPNTunnelExtension
//
//  Keeps Direct-mode sockets pinned to the physical interface. Without it the
//  provider's own upstream connections follow its default route back into the
//  tunnel and loop, so nothing reaches the internet.
//

import Foundation
import Network
@preconcurrency import VPNTunnel

nonisolated final class DirectInterfaceMonitor: @unchecked Sendable {
    static let shared = DirectInterfaceMonitor()

    private let queue = DispatchQueue(label: "VPNTunnel.directInterface")
    private var monitor: NWPathMonitor?

    /// Starts monitoring and returns the first physical interface index (0 if
    /// none appeared within a moment). Later path changes update Go directly.
    func start() async -> Int {
        stop()
        let monitor = NWPathMonitor(prohibitedInterfaceTypes: [.other, .loopback])
        queue.sync { self.monitor = monitor }
        return await withCheckedContinuation { continuation in
            var resumed = false // touched only on `queue`
            monitor.pathUpdateHandler = { path in
                let index = Self.physicalInterfaceIndex(path)
                VpntunnelSetDirectInterface(index)
                if !resumed {
                    resumed = true
                    continuation.resume(returning: index)
                }
            }
            monitor.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 1.5) {
                if !resumed {
                    resumed = true
                    continuation.resume(returning: 0)
                }
            }
        }
    }

    func stop() {
        queue.sync {
            monitor?.cancel()
            monitor = nil
        }
        VpntunnelSetDirectInterface(0)
    }

    private static func physicalInterfaceIndex(_ path: NWPath) -> Int {
        let physical: [NWInterface.InterfaceType] = [.wifi, .wiredEthernet, .cellular]
        return path.availableInterfaces.first { physical.contains($0.type) }?.index ?? 0
    }
}
