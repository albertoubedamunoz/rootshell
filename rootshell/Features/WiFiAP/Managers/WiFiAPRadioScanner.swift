import Citadel
import Foundation
import NIOCore
import NIOFoundationCompat
import os.log
import Combine

// MARK: - Scan Status

enum WiFiAPRadioScanStatus: Equatable, Sendable {
    case idle
    case scanning(progress: Int, total: Int)
    case success(radioCount: Int)
    case partialSuccess(radioCount: Int, failedAPs: [String], firstError: String)
    case error(String)

    var isScanning: Bool {
        if case .scanning = self { return true }
        return false
    }
}

// MARK: - WiFi AP Radio Scanner

/// Scans Ubiquiti APs via SSH to discover radio interfaces using `iwconfig`.
@MainActor
class WiFiAPRadioScanner: ObservableObject {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "WiFiAPRadioScanner")

    static let shared = WiFiAPRadioScanner()

    @Published private(set) var scanStatus: WiFiAPRadioScanStatus = .idle

    /// Serialized host-key prompt shown by WiFiAPAccountDetailView. Accepted
    /// keys persist to KnownHostsManager, so later scans are silent.
    let hostKeyPrompt = HostKeyPrompt()

    private init() {}

    // MARK: - Scan

    /// Scan all online APs for a given account via SSH
    func scanAllAPs(for accountID: UUID) async {
        let accountManager = WiFiAPAccountManager.shared
        let cacheManager = WiFiAPCacheManager.shared
        let radioCacheManager = WiFiAPRadioCacheManager.shared

        // Load credentials and validate SSH config
        guard let credentials = try? accountManager.getCredentials(for: accountID) else {
            scanStatus = .error("Could not load account credentials")
            return
        }

        guard let sshUsername = credentials.sshUsername, !sshUsername.isEmpty,
              let sshKeyID = credentials.sshKeyID else {
            scanStatus = .error("SSH username and key must be configured")
            return
        }

        // Get online wireless APs with IP addresses (filter out switches, gateways, etc.)
        let allAPs = cacheManager.accessPoints(for: accountID)
        let hasEnrichment = allAPs.contains(where: { $0.isWirelessAP != nil })
        let onlineAPs: [WiFiAccessPoint]

        if hasEnrichment {
            onlineAPs = allAPs.filter { $0.status == "online" && $0.ip != nil && $0.isWirelessAP == true }
        } else {
            // Enrichment hasn't run yet — need a fresh sync
            scanStatus = .error("Sync account first to identify wireless APs")
            return
        }

        guard !onlineAPs.isEmpty else {
            scanStatus = .error("No online wireless APs with IP addresses found")
            return
        }

        let totalAPs = onlineAPs.count
        scanStatus = .scanning(progress: 0, total: totalAPs)

        var allRadios: [WiFiAPRadio] = []
        var failedAPNames: [String] = []
        var firstError: String?
        var completedCount = 0

        // Scan APs concurrently
        await withTaskGroup(of: (String, Result<[WiFiAPRadio], Error>).self) { group in
            for ap in onlineAPs {
                group.addTask { @MainActor in
                    let result = await self.scanSingleAP(
                        ap: ap,
                        sshUsername: sshUsername,
                        sshKeyID: sshKeyID
                    )
                    return (ap.name, result)
                }
            }

            for await (apName, result) in group {
                completedCount += 1
                scanStatus = .scanning(progress: completedCount, total: totalAPs)

                switch result {
                case .success(let radios):
                    allRadios.append(contentsOf: radios)
                case .failure(let error):
                    failedAPNames.append(apName)
                    let errorDesc = error.localizedDescription
                    if firstError == nil {
                        firstError = "\(apName): \(errorDesc)"
                    }
                    Self.logger.error("Scan failed for \(apName): \(errorDesc)")
                }
            }
        }

        // Store results
        radioCacheManager.updateRadios(allRadios, for: accountID)

        let radioCount = allRadios.count
        if failedAPNames.isEmpty {
            scanStatus = .success(radioCount: radioCount)
        } else if radioCount == 0 && failedAPNames.count == totalAPs {
            scanStatus = .error(firstError ?? "All APs failed")
        } else {
            scanStatus = .partialSuccess(radioCount: radioCount, failedAPs: failedAPNames, firstError: firstError ?? "Unknown error")
        }

        Self.logger.info("Radio scan complete: \(radioCount) radios from \(totalAPs - failedAPNames.count)/\(totalAPs) APs")
    }

    // MARK: - Per-AP Scan

    private func scanSingleAP(
        ap: WiFiAccessPoint,
        sshUsername: String,
        sshKeyID: UUID
    ) async -> Result<[WiFiAPRadio], Error> {
        guard let ip = ap.ip else {
            return .failure(ScanError.noIPAddress)
        }

        let config = SSHConfig(
            host: ip,
            port: 22,
            username: sshUsername,
            authMethod: .key(sshKeyID)
        )

        do {
            // Known/CA keys pass silently; new or changed keys prompt the user
            // (one alert at a time across the concurrent AP scans).
            let (client, jumpClient) = try await SSHConnectionHelper.connect(
                config: config,
                onHostKeyValidation: hostKeyPrompt.validate
            )

            defer {
                Task {
                    try? await client.close()
                    if let jumpClient {
                        try? await jumpClient.close()
                    }
                }
            }

            // Execute iwconfig with timeout, tolerating stderr
            // (Citadel's executeCommand throws on any stderr output)
            let output: String = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask { @Sendable in
                    let streams = try await client.executeCommandStream("iwconfig 2>/dev/null")
                    var stdoutData = Data()
                    for try await event in streams {
                        switch event {
                        case .stdout(let buffer):
                            stdoutData.append(Data(buffer: buffer))
                        case .stderr, .exitStatus:
                            break
                        }
                    }
                    return String(data: stdoutData, encoding: .utf8) ?? ""
                }
                group.addTask { @Sendable in
                    try await Task.sleep(for: .seconds(10))
                    throw ScanError.commandTimeout
                }
                let result = try await group.next()!
                group.cancelAll()
                return result
            }

            let radios = IWConfigParser.parse(
                output,
                accessPointID: ap.id,
                accessPointMAC: ap.mac
            )

            let radioCount = radios.count
            Self.logger.debug("Scanned \(ap.name) (\(ip)): \(radioCount) radios")
            return .success(radios)

        } catch {
            Self.logger.warning("Failed to scan \(ap.name) (\(ip)): \(error)")
            return .failure(error)
        }
    }

    // MARK: - Errors

    private enum ScanError: LocalizedError {
        case noIPAddress
        case commandTimeout

        var errorDescription: String? {
            switch self {
            case .noIPAddress: return "AP has no IP address"
            case .commandTimeout: return "iwconfig timed out after 10s"
            }
        }
    }
}
