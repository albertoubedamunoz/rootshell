//
//  PortForwardConfig.swift
//  rootshell
//
//  Configuration for SSH port forwarding per connection
//
//  Copyright (c) 2025 Kit Knox / Rootshell LLC
//

import Foundation

/// Configuration for SSH port forwarding on a specific connection
nonisolated struct PortForwardConfig: Codable, Hashable, Sendable {
    /// Individual port forward rule
    nonisolated struct PortForward: Codable, Hashable, Sendable, Identifiable {
        let id: UUID

        /// Direction of the port forward
        nonisolated enum Direction: String, Codable, CaseIterable, Sendable {
            case local = "local"     // -L: listen locally, forward to remote
            case remote = "remote"   // -R: remote listens, forward to local
            case dynamic = "dynamic" // -D: SOCKS5 proxy

            var displayName: String {
                switch self {
                case .local: return String(localized: "Local (-L)", comment: "Port forward direction: local")
                case .remote: return String(localized: "Remote (-R)", comment: "Port forward direction: remote")
                case .dynamic: return String(localized: "Dynamic (-D)", comment: "Port forward direction: dynamic")
                }
            }

            var shortName: String {
                switch self {
                case .local: return "L"
                case .remote: return "R"
                case .dynamic: return "D"
                }
            }

            var description: String {
                switch self {
                case .local:
                    return String(localized: "Local port forwards to remote host through SSH", comment: "Port forward direction description: local")
                case .remote:
                    return String(localized: "Remote port forwards to local service", comment: "Port forward direction description: remote")
                case .dynamic:
                    return String(localized: "SOCKS5 proxy for dynamic port forwarding", comment: "Port forward direction description: dynamic")
                }
            }
        }

        var direction: Direction
        var bindAddress: String  // Local address for -L, remote address for -R
        var bindPort: Int        // Port to listen on
        var targetHost: String   // Host to connect to
        var targetPort: Int      // Port to connect to
        var enabled: Bool = true // Can be disabled without removal

        init(
            id: UUID = UUID(),
            direction: Direction,
            bindAddress: String = "",
            bindPort: Int,
            targetHost: String,
            targetPort: Int,
            enabled: Bool = true
        ) {
            self.id = id
            self.direction = direction
            self.bindAddress = bindAddress
            self.bindPort = bindPort
            self.targetHost = targetHost
            self.targetPort = targetPort
            self.enabled = enabled
        }

        /// Display string like "L 8080:localhost:80", "R 3000:192.168.1.5:3000", or "D 1080"
        var displayString: String {
            let prefix = direction.shortName
            if direction == .dynamic {
                if bindAddress.isEmpty || bindAddress == "localhost" || bindAddress == "127.0.0.1" {
                    return "\(prefix) \(bindPort)"
                }
                return "\(prefix) \(bindAddress):\(bindPort)"
            }
            if bindAddress.isEmpty || bindAddress == "localhost" || bindAddress == "127.0.0.1" {
                return "\(prefix) \(bindPort):\(targetHost):\(targetPort)"
            }
            return "\(prefix) \(bindAddress):\(bindPort):\(targetHost):\(targetPort)"
        }

        /// Full specification string for command line (without -L/-R/-D prefix)
        var specString: String {
            if direction == .dynamic {
                if bindAddress.isEmpty {
                    return "\(bindPort)"
                }
                return "\(bindAddress):\(bindPort)"
            }
            if bindAddress.isEmpty {
                return "\(bindPort):\(targetHost):\(targetPort)"
            }
            return "\(bindAddress):\(bindPort):\(targetHost):\(targetPort)"
        }

        /// Parse from SSH command format:
        /// - Local/Remote: "[bind_address:]port:host:hostport"
        /// - Dynamic: "[bind_address:]port"
        /// Returns nil if parsing fails
        static func parse(_ spec: String, direction: Direction) -> PortForward? {
            let components = spec.split(separator: ":", omittingEmptySubsequences: false).map(String.init)

            if direction == .dynamic {
                switch components.count {
                case 1:
                    // port
                    guard let bindPort = Int(components[0]),
                          bindPort > 0, bindPort <= 65535 else {
                        return nil
                    }
                    return PortForward(
                        direction: direction,
                        bindAddress: "",
                        bindPort: bindPort,
                        targetHost: "",
                        targetPort: 0
                    )
                case 2:
                    // bind_address:port
                    guard let bindPort = Int(components[1]),
                          bindPort > 0, bindPort <= 65535 else {
                        return nil
                    }
                    return PortForward(
                        direction: direction,
                        bindAddress: components[0],
                        bindPort: bindPort,
                        targetHost: "",
                        targetPort: 0
                    )
                default:
                    return nil
                }
            }

            switch components.count {
            case 3:
                // port:host:hostport
                guard let bindPort = Int(components[0]),
                      let targetPort = Int(components[2]),
                      bindPort > 0, bindPort <= 65535,
                      targetPort > 0, targetPort <= 65535,
                      !components[1].isEmpty else {
                    return nil
                }
                return PortForward(
                    direction: direction,
                    bindAddress: "",
                    bindPort: bindPort,
                    targetHost: components[1],
                    targetPort: targetPort
                )

            case 4:
                // bind_address:port:host:hostport
                guard let bindPort = Int(components[1]),
                      let targetPort = Int(components[3]),
                      bindPort > 0, bindPort <= 65535,
                      targetPort > 0, targetPort <= 65535,
                      !components[2].isEmpty else {
                    return nil
                }
                return PortForward(
                    direction: direction,
                    bindAddress: components[0],
                    bindPort: bindPort,
                    targetHost: components[2],
                    targetPort: targetPort
                )

            default:
                return nil
            }
        }

        /// Validate port numbers
        var isValid: Bool {
            guard bindPort > 0, bindPort <= 65535 else { return false }
            if direction == .dynamic {
                return true // Only bind port needed for dynamic
            }
            return targetPort > 0 && targetPort <= 65535 && !targetHost.isEmpty
        }
    }

    /// List of configured port forwards
    var forwards: [PortForward]

    /// Default configuration with no forwards
    static let none = PortForwardConfig(forwards: [])

    /// Whether any forwards are configured and enabled
    var hasActiveForwards: Bool {
        forwards.contains { $0.enabled }
    }

    /// Get only enabled local forwards
    var localForwards: [PortForward] {
        forwards.filter { $0.direction == .local && $0.enabled }
    }

    /// Get only enabled remote forwards
    var remoteForwards: [PortForward] {
        forwards.filter { $0.direction == .remote && $0.enabled }
    }

    /// Get only enabled dynamic forwards
    var dynamicForwards: [PortForward] {
        forwards.filter { $0.direction == .dynamic && $0.enabled }
    }

    /// Summary string for display (e.g., "2 local, 1 remote, 1 dynamic")
    var summaryString: String? {
        let localCount = localForwards.count
        let remoteCount = remoteForwards.count
        let dynamicCount = dynamicForwards.count

        if localCount == 0 && remoteCount == 0 && dynamicCount == 0 {
            return nil
        }

        var parts: [String] = []
        if localCount > 0 {
            parts.append("\(localCount) local")
        }
        if remoteCount > 0 {
            parts.append("\(remoteCount) remote")
        }
        if dynamicCount > 0 {
            parts.append("\(dynamicCount) dynamic")
        }
        return parts.joined(separator: ", ")
    }
}
