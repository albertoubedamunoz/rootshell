//
//  KubernetesDebugPodSpec.swift
//  rootshell
//
//  Builds privileged debug pod specifications for Kubernetes node shell access
//

import Foundation
import SwiftkubeModel

/// Builds debug pod specifications for node shell access
enum KubernetesDebugPodSpec {

    /// Build a debug pod specification for a node shell session
    /// - Parameters:
    ///   - config: The node shell configuration
    ///   - image: Container image (default: alpine:3.19)
    /// - Returns: A core.v1.Pod ready for creation
    static func build(
        config: KubernetesNodeShellConfig,
        image: String = KubernetesNodeShellConstants.defaultImage
    ) -> core.v1.Pod {
        let timestamp = ISO8601DateFormatter().string(from: config.createdAt)

        return core.v1.Pod(
            metadata: meta.v1.ObjectMeta(
                annotations: [
                    KubernetesNodeShellConstants.Annotations.createdAt: timestamp,
                    KubernetesNodeShellConstants.Annotations.deviceId: config.deviceId,
                    KubernetesNodeShellConstants.Annotations.clusterId: config.clusterId.uuidString,
                    KubernetesNodeShellConstants.Annotations.ttlSeconds: "\(KubernetesNodeShellConstants.defaultTTL)",
                    KubernetesNodeShellConstants.Annotations.purpose: KubernetesNodeShellConstants.Annotations.purposeValue,
                    KubernetesNodeShellConstants.Annotations.podType: config.podType.rawValue
                ],
                labels: [
                    KubernetesNodeShellConstants.Labels.appName: KubernetesNodeShellConstants.Labels.appNameValue,
                    KubernetesNodeShellConstants.Labels.appComponent: KubernetesNodeShellConstants.Labels.appComponentValue,
                    KubernetesNodeShellConstants.Labels.appManagedBy: KubernetesNodeShellConstants.Labels.appManagedByValue,
                    KubernetesNodeShellConstants.Labels.sessionId: config.sessionId.uuidString,
                    KubernetesNodeShellConstants.Labels.nodeName: config.nodeName
                ],
                name: config.podName,
                namespace: KubernetesNodeShellConstants.namespace
            ),
            spec: buildPodSpec(nodeName: config.nodeName, image: image, podType: config.podType)
        )
    }

    /// Build the PodSpec with privileged security settings
    private static func buildPodSpec(nodeName: String, image: String, podType: KubernetesDebugPodType) -> core.v1.PodSpec {
        core.v1.PodSpec(
            containers: [
                buildContainer(image: image, podType: podType)
            ],
            hostIPC: true,
            hostNetwork: true,
            hostPID: true,
            nodeName: nodeName,
            restartPolicy: "Never",
            terminationGracePeriodSeconds: 5,
            tolerations: [
                // Tolerate all taints to run on any node (including cordoned/tainted nodes)
                core.v1.Toleration(
                    operator: "Exists"
                )
            ],
            volumes: [
                // Mount host root filesystem for debugging
                core.v1.Volume(
                    hostPath: core.v1.HostPathVolumeSource(
                        path: "/",
                        type: "Directory"
                    ),
                    name: "host-root"
                )
            ]
        )
    }

    /// Build the container specification with appropriate command for pod type
    private static func buildContainer(image: String, podType: KubernetesDebugPodType) -> core.v1.Container {
        // Choose command based on pod type
        let command: [String]
        switch podType {
        case .nodeShell:
            // Use nsenter to enter all host namespaces via PID 1
            // This gives us a root shell on the actual node
            // Use bash with -l for login shell (sources /etc/profile, ~/.bash_profile)
            // to ensure proper PATH and environment setup
            command = [
                "nsenter",
                "--target", "1",
                "--mount",
                "--uts",
                "--ipc",
                "--net",
                "--pid",
                "--",
                "/bin/bash", "-l"
            ]
        case .containerShell:
            // Run shell directly in the debug container
            // For immutable distros like Talos that don't have /bin/bash on the host
            // Host filesystem is still accessible at /host
            command = ["/bin/sh"]
        }

        return core.v1.Container(
            command: command,
            image: image,
            imagePullPolicy: "IfNotPresent",
            name: KubernetesNodeShellConstants.containerName,
            resources: core.v1.ResourceRequirements(
                limits: [
                    "cpu": "500m",
                    "memory": "256Mi"
                ],
                requests: [
                    "cpu": "50m",
                    "memory": "64Mi"
                ]
            ),
            securityContext: core.v1.SecurityContext(
                privileged: true,
                runAsGroup: 0,
                runAsUser: 0
            ),
            stdin: true,
            stdinOnce: false,
            tty: true,
            volumeMounts: [
                core.v1.VolumeMount(
                    mountPath: "/host",
                    name: "host-root",
                    readOnly: false
                )
            ]
        )
    }

    /// Get the exec command for a given pod type
    /// - Parameter podType: The type of debug pod
    /// - Returns: Command arguments for exec
    static func execCommand(for podType: KubernetesDebugPodType) -> [String] {
        switch podType {
        case .nodeShell:
            // bash login shell starting in root's home
            // Uses 'cd' (no args) to go to $HOME, then execs into a login shell
            return ["/bin/bash", "-c", "cd && exec /bin/bash -l"]
        case .containerShell:
            // Simple shell in the container
            return ["/bin/sh"]
        }
    }

    /// Default command for node shell exec (legacy, uses nodeShell type)
    nonisolated static let defaultExecCommand: [String] = ["/bin/bash", "-c", "cd && exec /bin/bash -l"]

    /// Generate the exec URL for connecting to the pod
    /// - Parameters:
    ///   - serverURL: The Kubernetes API server URL
    ///   - podName: Name of the pod
    ///   - podType: Type of debug pod (determines default command)
    ///   - command: Command arguments to execute (defaults based on podType)
    /// - Returns: The WebSocket URL for exec connection
    static func execURL(
        serverURL: URL,
        podName: String,
        podType: KubernetesDebugPodType = .nodeShell,
        command: [String]? = nil
    ) -> URL? {
        let execCommand = command ?? Self.execCommand(for: podType)
        // Build the exec URL path
        let path = "/api/v1/namespaces/\(KubernetesNodeShellConstants.namespace)/pods/\(podName)/exec"

        // Build query parameters
        var components = URLComponents()
        components.scheme = serverURL.scheme == "http" ? "ws" : "wss"
        components.host = serverURL.host
        components.port = serverURL.port
        components.path = path

        // Kubernetes exec API requires repeated 'command' params for each argument
        // e.g., ?command=/bin/bash&command=-l for "/bin/bash -l"
        var queryItems: [URLQueryItem] = execCommand.map { URLQueryItem(name: "command", value: $0) }
        queryItems.append(contentsOf: [
            URLQueryItem(name: "stdin", value: "true"),
            URLQueryItem(name: "stdout", value: "true"),
            URLQueryItem(name: "stderr", value: "true"),
            URLQueryItem(name: "tty", value: "true"),
            URLQueryItem(name: "container", value: KubernetesNodeShellConstants.containerName)
        ])
        components.queryItems = queryItems

        return components.url
    }

    /// Parse pod status to determine if pod is ready for exec
    /// - Parameter pod: The pod to check
    /// - Returns: Tuple of (isReady, phase, message)
    static func checkPodStatus(_ pod: core.v1.Pod) -> (isReady: Bool, phase: String, message: String?) {
        guard let status = pod.status else {
            return (false, "Unknown", "No status available")
        }

        let phase = status.phase ?? "Unknown"

        switch phase {
        case "Running":
            // Check container status
            if let containerStatuses = status.containerStatuses,
               let shellStatus = containerStatuses.first(where: { $0.name == KubernetesNodeShellConstants.containerName }) {
                if shellStatus.ready == true {
                    return (true, phase, nil)
                } else if let waiting = shellStatus.state?.waiting {
                    return (false, phase, "Waiting: \(waiting.reason ?? "unknown")")
                } else if let terminated = shellStatus.state?.terminated {
                    return (false, "Terminated", "Exit code: \(terminated.exitCode)")
                }
            }
            return (true, phase, nil)

        case "Pending":
            // Check why we're pending
            if let conditions = status.conditions {
                for condition in conditions {
                    if condition.status == "False" {
                        return (false, phase, "\(condition.type): \(condition.message ?? condition.reason ?? "")")
                    }
                }
            }
            return (false, phase, "Waiting to be scheduled")

        case "Failed":
            return (false, phase, status.message ?? "Pod failed")

        case "Succeeded":
            return (false, phase, "Container has exited")

        default:
            return (false, phase, "Unknown phase: \(phase)")
        }
    }

    /// Extract pod creation error from Kubernetes API response
    /// - Parameter error: The SwiftkubeClient error
    /// - Returns: A user-friendly error description
    static func parseCreationError(_ error: Error) -> KubernetesNodeShellError {
        let errorString = error.localizedDescription.lowercased()

        // Check for common error patterns
        if errorString.contains("forbidden") || errorString.contains("403") {
            return .insufficientRBAC(error.localizedDescription)
        } else if errorString.contains("quota") || errorString.contains("exceeded") {
            return .quotaExceeded
        } else if errorString.contains("unauthorized") || errorString.contains("401") {
            return .authenticationFailed(error.localizedDescription)
        } else if errorString.contains("timeout") {
            return .networkError("Connection timeout")
        } else if errorString.contains("connection") || errorString.contains("network") {
            return .networkError(error.localizedDescription)
        }

        return .podCreationFailed(error.localizedDescription)
    }
}
