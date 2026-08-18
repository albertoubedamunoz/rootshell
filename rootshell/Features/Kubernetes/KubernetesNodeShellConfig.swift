//
//  KubernetesNodeShellConfig.swift
//  rootshell
//
//  Configuration and error types for Kubernetes node shell sessions
//

import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Type of debug pod for Kubernetes node shell access
nonisolated enum KubernetesDebugPodType: String, Codable, CaseIterable, Sendable {
    /// Full node access via nsenter (requires /bin/bash on host)
    case nodeShell = "nodeShell"
    /// Shell in debug container (for immutable distros like Talos)
    case containerShell = "containerShell"

    var displayName: String {
        switch self {
        case .nodeShell: return String(localized: "Node Shell", comment: "Kubernetes debug pod type: full node shell access")
        case .containerShell: return String(localized: "Container Shell", comment: "Kubernetes debug pod type: container shell access")
        }
    }

    var description: String {
        switch self {
        case .nodeShell: return String(localized: "Full host access via nsenter", comment: "Kubernetes debug pod type description: node shell")
        case .containerShell: return String(localized: "For immutable distros (Talos, Flatcar)", comment: "Kubernetes debug pod type description: container shell")
        }
    }

    var iconName: String {
        switch self {
        case .nodeShell: return "server.rack"
        case .containerShell: return "shippingbox"
        }
    }
}

/// Configuration for a Kubernetes node shell session
nonisolated struct KubernetesNodeShellConfig: Codable, Equatable, Sendable {
    /// Unique session identifier
    let sessionId: UUID

    /// The cluster to connect to (stored by ID for Codable)
    let clusterId: UUID

    /// Target Kubernetes node name
    let nodeName: String

    /// Device identifier for orphan tracking
    let deviceId: String

    /// Created timestamp
    let createdAt: Date

    /// Type of debug pod to create
    let podType: KubernetesDebugPodType

    /// Display name for UI
    var displayName: String {
        "Node: \(nodeName)"
    }

    /// Short session ID for pod naming (first 8 chars)
    var shortSessionId: String {
        String(sessionId.uuidString.prefix(8)).lowercased()
    }

    /// Pod name that will be created for this session
    var podName: String {
        "ghostty-node-shell-\(shortSessionId)"
    }

    init(
        sessionId: UUID = UUID(),
        clusterId: UUID,
        nodeName: String,
        deviceId: String? = nil,
        createdAt: Date = Date(),
        podType: KubernetesDebugPodType = .nodeShell
    ) {
        self.sessionId = sessionId
        self.clusterId = clusterId
        self.nodeName = nodeName
        self.createdAt = createdAt
        self.podType = podType

        self.deviceId = deviceId ?? Self.cachedDeviceID()
    }

    private static let deviceIDKey = "k8sNodeShellDeviceID"

    /// Stable per-install device identifier. `UIDevice.current.identifierForVendor`
    /// is @MainActor, but this config is `nonisolated` (Codable) and is built from
    /// off-main paths, so we persist a UUID-shaped id once instead.
    ///
    /// This is the single source of truth for the device id: it is annotated onto
    /// created pods (see `KubernetesDebugPodSpec`) and must match the value used by
    /// `KubernetesNodeShellManager.cleanupPodsFromThisDevice(in:)`.
    nonisolated static func cachedDeviceID() -> String { persistedDeviceID }

    /// Backed by a `static let` so the read/generate/persist runs exactly once
    /// (Swift guarantees thread-safe one-time initialization). This eliminates the
    /// concurrent first-call race where two callers could each miss UserDefaults,
    /// generate different ids, and leave only the last writer's id — which would
    /// strand pods annotated with the losing id at cleanup time.
    private nonisolated static let persistedDeviceID: String = {
        let defaults = UserDefaults.standard
        if let id = defaults.string(forKey: deviceIDKey) { return id }
        let generated = UUID().uuidString
        defaults.set(generated, forKey: deviceIDKey)
        return generated
    }()

    /// Creates a new config with the same cluster and node but a fresh session ID.
    /// Used when splitting a Kubernetes terminal to create a new independent session.
    func withNewSession() -> KubernetesNodeShellConfig {
        KubernetesNodeShellConfig(
            sessionId: UUID(),
            clusterId: clusterId,
            nodeName: nodeName,
            deviceId: deviceId,
            createdAt: Date(),
            podType: podType
        )
    }
}

/// Errors specific to Kubernetes node shell operations
enum KubernetesNodeShellError: LocalizedError, Equatable {
    /// Cluster not found in stored clusters
    case clusterNotFound

    /// Kubeconfig not found in Keychain
    case kubeconfigNotFound

    /// Failed to parse kubeconfig
    case kubeconfigParseError(String)

    /// Node not found in cluster
    case nodeNotFound(String)

    /// Node is cordoned/unschedulable
    case nodeUnschedulable(String)

    /// Insufficient RBAC permissions
    case insufficientRBAC(String)

    /// Failed to create debug pod
    case podCreationFailed(String)

    /// Pod failed to start within timeout
    case podStartTimeout

    /// Pod entered failed state
    case podFailed(String)

    /// Failed to connect exec WebSocket
    case execConnectionFailed(String)

    /// WebSocket connection closed unexpectedly
    case execConnectionClosed(String?)

    /// Resource quota exceeded in namespace
    case quotaExceeded

    /// Authentication failed
    case authenticationFailed(String)

    /// Unsupported authentication method (e.g., exec credential plugin)
    case unsupportedAuthMethod(String)

    /// Network error
    case networkError(String)

    /// Pod cleanup failed (non-fatal, logged as warning)
    case podCleanupFailed(String)

    var errorDescription: String? {
        switch self {
        case .clusterNotFound:
            return String(localized: "Kubernetes cluster not found", comment: "Kubernetes node shell error")
        case .kubeconfigNotFound:
            return String(localized: "Kubeconfig not found in Keychain", comment: "Kubernetes node shell error")
        case .kubeconfigParseError(let detail):
            return String(localized: "Failed to parse kubeconfig: \(detail)", comment: "Kubernetes node shell error")
        case .nodeNotFound(let name):
            return String(localized: "Node '\(name)' not found in cluster", comment: "Kubernetes node shell error")
        case .nodeUnschedulable(let name):
            return String(localized: "Node '\(name)' is unschedulable (cordoned)", comment: "Kubernetes node shell error")
        case .insufficientRBAC(let detail):
            return String(localized: "Insufficient permissions: \(detail)", comment: "Kubernetes node shell error")
        case .podCreationFailed(let detail):
            return String(localized: "Failed to create debug pod: \(detail)", comment: "Kubernetes node shell error")
        case .podStartTimeout:
            return String(localized: "Debug pod failed to start within timeout", comment: "Kubernetes node shell error")
        case .podFailed(let detail):
            return String(localized: "Debug pod failed: \(detail)", comment: "Kubernetes node shell error")
        case .execConnectionFailed(let detail):
            return String(localized: "Failed to connect to debug pod: \(detail)", comment: "Kubernetes node shell error")
        case .execConnectionClosed(let reason):
            if let reason = reason {
                return String(localized: "Connection closed: \(reason)", comment: "Kubernetes node shell error")
            }
            return String(localized: "Connection closed unexpectedly", comment: "Kubernetes node shell error")
        case .quotaExceeded:
            return String(localized: "Resource quota exceeded in kube-system namespace", comment: "Kubernetes node shell error")
        case .authenticationFailed(let detail):
            return String(localized: "Authentication failed: \(detail)", comment: "Kubernetes node shell error")
        case .unsupportedAuthMethod(let method):
            return String(localized: "Unsupported authentication method: \(method). iOS does not support exec credential plugins.", comment: "Kubernetes node shell error")
        case .networkError(let detail):
            return String(localized: "Network error: \(detail)", comment: "Kubernetes node shell error")
        case .podCleanupFailed(let detail):
            return String(localized: "Failed to cleanup debug pod: \(detail)", comment: "Kubernetes node shell error")
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .clusterNotFound, .kubeconfigNotFound:
            return String(localized: "Import the cluster kubeconfig in Settings > Kubernetes", comment: "Kubernetes node shell recovery suggestion")
        case .insufficientRBAC:
            return "Ensure your kubeconfig user has permissions to create pods and exec in kube-system namespace"
        case .unsupportedAuthMethod:
            return "Use a kubeconfig with bearer token or client certificate authentication instead"
        case .nodeUnschedulable:
            return "The node may be under maintenance. Try a different node."
        case .quotaExceeded:
            return "Contact your cluster administrator to increase the resource quota"
        default:
            return nil
        }
    }
}

/// State machine for node shell session lifecycle
enum KubernetesNodeShellState: Equatable, Sendable {
    /// Initial state before starting
    case initial

    /// Loading kubeconfig and creating client
    case initializing

    /// Verifying node exists and is schedulable
    case verifyingNode

    /// Creating debug pod on node
    case creatingPod

    /// Waiting for pod to reach Running state
    case waitingForPod(startTime: Date)

    /// Connecting exec WebSocket
    case connecting

    /// Session is running and ready for input
    case running

    /// Session disconnected, may reconnect
    case disconnected(reason: DisconnectReason)

    /// Cleaning up debug pod
    case cleaningUp

    /// Session terminated (cannot restart)
    case terminated

    /// Session failed with error
    case failed(KubernetesNodeShellError)

    /// Reasons for disconnection
    enum DisconnectReason: Equatable, Sendable {
        case userClosed
        case sessionEnded
        case connectionLost
        case podTerminated
    }

    /// Human-readable description for UI
    var statusDescription: String {
        switch self {
        case .initial:
            return String(localized: "Ready to connect", comment: "Kubernetes node shell status")
        case .initializing:
            return String(localized: "Initializing...", comment: "Kubernetes node shell status")
        case .verifyingNode:
            return String(localized: "Verifying node...", comment: "Kubernetes node shell status")
        case .creatingPod:
            return String(localized: "Creating debug pod...", comment: "Kubernetes node shell status")
        case .waitingForPod:
            return String(localized: "Waiting for pod to start...", comment: "Kubernetes node shell status")
        case .connecting:
            return String(localized: "Connecting...", comment: "Kubernetes node shell status")
        case .running:
            return String(localized: "Connected", comment: "Kubernetes node shell status")
        case .disconnected(let reason):
            switch reason {
            case .userClosed:
                return String(localized: "Disconnected", comment: "Kubernetes node shell status")
            case .sessionEnded:
                return String(localized: "Session ended", comment: "Kubernetes node shell status")
            case .connectionLost:
                return String(localized: "Connection lost", comment: "Kubernetes node shell status")
            case .podTerminated:
                return String(localized: "Pod terminated", comment: "Kubernetes node shell status")
            }
        case .cleaningUp:
            return String(localized: "Cleaning up...", comment: "Kubernetes node shell status")
        case .terminated:
            return String(localized: "Terminated", comment: "Kubernetes node shell status")
        case .failed(let error):
            return error.localizedDescription
        }
    }

    /// Whether the session can be restarted
    var canRestart: Bool {
        switch self {
        case .disconnected, .failed, .terminated:
            return true
        default:
            return false
        }
    }

    /// Whether the session is in a terminal state
    var isTerminal: Bool {
        switch self {
        case .terminated, .failed:
            return true
        default:
            return false
        }
    }

    /// Color style for spinner animation based on current state
    var spinnerColorStyle: SpinnerAnimator.ColorStyle {
        switch self {
        case .initializing, .verifyingNode, .connecting:
            return .connecting
        case .creatingPod, .waitingForPod, .cleaningUp:
            return .provisioning
        case .running:
            return .success
        case .failed:
            return .error
        default:
            return .connecting
        }
    }

    /// Joke category for Kubernetes connections
    var jokeCategory: ConnectionJokeCategory {
        return .kubernetes
    }
}

/// Information about an orphaned debug pod
struct OrphanedPodInfo: Identifiable, Equatable, Sendable {
    /// Pod name (used as ID)
    let id: String

    /// Node the pod was scheduled on
    let nodeName: String

    /// Cluster UUID
    let clusterId: UUID

    /// When the pod was created
    let createdAt: Date

    /// Age of the pod in seconds
    var age: TimeInterval {
        Date().timeIntervalSince(createdAt)
    }

    /// Session ID from labels
    let sessionId: String

    /// Device ID from annotations
    let deviceId: String

    /// Human-readable age string
    var ageDescription: String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter.string(from: age) ?? "\(Int(age))s"
    }
}

/// Constants for pod labels and annotations
enum KubernetesNodeShellConstants {
    /// Namespace for debug pods
    static let namespace = "kube-system"

    /// Container name in debug pod
    static let containerName = "shell"

    /// Default image for debug pod
    static let defaultImage = "alpine:3.19"

    /// Default timeout for pod to start (seconds)
    static let podStartTimeout: TimeInterval = 60

    /// Default TTL for orphan detection (seconds)
    static let defaultTTL: Int = 3600

    /// Standard Kubernetes labels
    enum Labels {
        static let appName = "app.kubernetes.io/name"
        static let appComponent = "app.kubernetes.io/component"
        static let appManagedBy = "app.kubernetes.io/managed-by"

        // Custom labels
        static let sessionId = "ghostty.io/session-id"
        static let nodeName = "ghostty.io/node-name"

        // Label values
        static let appNameValue = "ghostty-node-shell"
        static let appComponentValue = "debug-pod"
        static let appManagedByValue = "ghostty-ios"
    }

    /// Custom annotations
    enum Annotations {
        static let createdAt = "ghostty.io/created-at"
        static let deviceId = "ghostty.io/device-id"
        static let clusterId = "ghostty.io/cluster-id"
        static let ttlSeconds = "ghostty.io/ttl-seconds"
        static let purpose = "ghostty.io/purpose"
        static let podType = "ghostty.io/pod-type"

        // Annotation values
        static let purposeValue = "Interactive node debug shell"
    }

    /// Label selector for listing ghostty debug pods
    static var labelSelector: String {
        "\(Labels.appManagedBy)=\(Labels.appManagedByValue),\(Labels.appName)=\(Labels.appNameValue)"
    }
}
