//
//  MMDBDatabaseManager.swift
//  rootshell
//
//  Manages imported local MMDB databases and merges lookup results.
//

import Foundation
import Observation
import OSLog

struct MMDBDatabaseDescriptor: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    let originalFileName: String
    let storedFileName: String
    let databaseType: String
    let ipVersion: Int
    let importedAt: Date
}

struct MMDBImportReport: Sendable {
    let importedCount: Int
    let failures: [String]

    var hasFailures: Bool {
        !failures.isEmpty
    }
}

@MainActor
@Observable
final class MMDBDatabaseManager {
    static let shared = MMDBDatabaseManager()

    private nonisolated static let logger = Logger(subsystem: "com.kk2.rootshell", category: "mmdb-manager")
    private static let manifestFileName = "mmdb_databases.json"

    private struct LoadedDatabase: Sendable {
        let descriptor: MMDBDatabaseDescriptor
        let reader: MMDBReader
    }

    private(set) var databases: [MMDBDatabaseDescriptor] = []
    private(set) var loadedDatabaseCount: Int = 0
    private(set) var isLoading: Bool = false
    private(set) var lastErrorMessage: String?

    private var loadedDatabases: [LoadedDatabase] = []

    private init() {
        loadManifest()
        Task {
            await reload()
        }
    }

    var hasDatabases: Bool {
        !databases.isEmpty
    }

    func priority(for id: UUID) -> Int? {
        databases.firstIndex { $0.id == id }
    }

    func importFiles(from urls: [URL]) throws -> MMDBImportReport {
        guard !urls.isEmpty else {
            return MMDBImportReport(importedCount: 0, failures: [])
        }

        try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)

        var failures: [String] = []
        var importedCount = 0

        for url in urls {
            let accessing = url.startAccessingSecurityScopedResource()
            do {
                let reader: MMDBReader
                let descriptor: MMDBDatabaseDescriptor
                (reader, descriptor) = try importSingleFile(from: url)
                if accessing {
                    url.stopAccessingSecurityScopedResource()
                }
                appendDatabase(descriptor: descriptor, reader: reader)
                importedCount += 1
            } catch {
                if accessing {
                    url.stopAccessingSecurityScopedResource()
                }
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }

        saveManifest()
        updateStateAfterMutation()

        if importedCount > 0 {
            GeoResolver.shared.clearCache()
        }

        if importedCount == 0, let firstFailure = failures.first {
            throw MMDBImportError.failed(firstFailure)
        }

        return MMDBImportReport(importedCount: importedCount, failures: failures)
    }

    func reload() async {
        isLoading = true
        defer { isLoading = false }

        let descriptors = databases
        let directory = storageDirectory
        let result = await Task.detached(priority: .utility) {
            Self.loadReaders(for: descriptors, from: directory)
        }.value

        loadedDatabases = result.loaded
        loadedDatabaseCount = result.loaded.count
        lastErrorMessage = result.errors.isEmpty ? nil : result.errors.joined(separator: "\n")

        if !result.errors.isEmpty {
            Self.logger.warning("MMDB reload finished with \(result.errors.count) error(s)")
        }

        GeoResolver.shared.clearCache()
    }

    func removeDatabase(id: UUID) {
        guard let descriptor = databases.first(where: { $0.id == id }) else { return }
        let url = storageDirectory.appendingPathComponent(descriptor.storedFileName)
        try? FileManager.default.removeItem(at: url)

        databases.removeAll { $0.id == id }
        loadedDatabases.removeAll { $0.descriptor.id == id }
        saveManifest()
        updateStateAfterMutation()
        GeoResolver.shared.clearCache()
    }

    func moveDatabase(from source: IndexSet, to destination: Int) {
        databases = Self.moveItems(in: databases, from: source, to: destination)
        let orderedIDs = databases.map(\.id)
        loadedDatabases.sort { lhs, rhs in
            guard let lhsIndex = orderedIDs.firstIndex(of: lhs.descriptor.id),
                  let rhsIndex = orderedIDs.firstIndex(of: rhs.descriptor.id) else {
                return false
            }
            return lhsIndex < rhsIndex
        }
        saveManifest()
        GeoResolver.shared.clearCache()
    }

    func moveDatabase(id: UUID, by delta: Int) {
        guard let sourceIndex = databases.firstIndex(where: { $0.id == id }) else { return }
        let destinationIndex = min(max(sourceIndex + delta, 0), databases.count - 1)
        guard destinationIndex != sourceIndex else { return }

        let destinationOffset = destinationIndex > sourceIndex ? destinationIndex + 1 : destinationIndex
        moveDatabase(from: IndexSet(integer: sourceIndex), to: destinationOffset)
    }

    func clearAll() {
        for descriptor in databases {
            let url = storageDirectory.appendingPathComponent(descriptor.storedFileName)
            try? FileManager.default.removeItem(at: url)
        }

        databases.removeAll()
        loadedDatabases.removeAll()
        saveManifest()
        updateStateAfterMutation()
        lastErrorMessage = nil
        GeoResolver.shared.clearCache()
    }

    func resolve(ip: String) async -> GeoInfo? {
        let readers = loadedDatabases
        guard !readers.isEmpty else { return nil }

        return await Task.detached(priority: .userInitiated) {
            Self.resolve(ip: ip, databases: readers)
        }.value
    }

    private func importSingleFile(from url: URL) throws -> (MMDBReader, MMDBDatabaseDescriptor) {
        let storedFileName = UUID().uuidString + ".mmdb"
        let destinationURL = storageDirectory.appendingPathComponent(storedFileName)

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }

        do {
            try FileManager.default.copyItem(at: url, to: destinationURL)
            let reader = try MMDBReader(url: destinationURL)
            let descriptor = MMDBDatabaseDescriptor(
                id: UUID(),
                originalFileName: url.lastPathComponent,
                storedFileName: storedFileName,
                databaseType: reader.metadata.databaseType,
                ipVersion: reader.metadata.ipVersion,
                importedAt: Date()
            )
            return (reader, descriptor)
        } catch {
            try? FileManager.default.removeItem(at: destinationURL)
            throw error
        }
    }

    private func appendDatabase(descriptor: MMDBDatabaseDescriptor, reader: MMDBReader) {
        databases.append(descriptor)
        loadedDatabases.append(LoadedDatabase(descriptor: descriptor, reader: reader))
    }

    private func updateStateAfterMutation() {
        loadedDatabaseCount = loadedDatabases.count
        if loadedDatabaseCount > 0 {
            lastErrorMessage = nil
        }
    }

    private func loadManifest() {
        guard let data = try? Data(contentsOf: manifestURL),
              let decoded = try? JSONDecoder().decode([MMDBDatabaseDescriptor].self, from: data) else {
            databases = []
            return
        }
        databases = decoded
    }

    private func saveManifest() {
        try? FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(databases) else { return }
        try? data.write(to: manifestURL, options: .atomic)
    }

    private var storageDirectory: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent(".ghostty/mmdb", isDirectory: true)
    }

    private var manifestURL: URL {
        storageDirectory.appendingPathComponent(Self.manifestFileName)
    }

    private nonisolated static func loadReaders(for descriptors: [MMDBDatabaseDescriptor], from directory: URL) -> (loaded: [LoadedDatabase], errors: [String]) {
        var loaded: [LoadedDatabase] = []
        var errors: [String] = []

        for descriptor in descriptors {
            let url = directory.appendingPathComponent(descriptor.storedFileName)
            do {
                let reader = try MMDBReader(url: url)
                loaded.append(LoadedDatabase(descriptor: descriptor, reader: reader))
            } catch {
                errors.append("\(descriptor.originalFileName): \(error.localizedDescription)")
            }
        }

        return (loaded, errors)
    }

    private nonisolated static func moveItems<T>(in array: [T], from source: IndexSet, to destination: Int) -> [T] {
        var reordered = array
        let movingItems = source.sorted().map { reordered[$0] }

        for index in source.sorted(by: >) {
            reordered.remove(at: index)
        }

        let insertionIndex = min(max(destination, 0), reordered.count)
        reordered.insert(contentsOf: movingItems, at: insertionIndex)
        return reordered
    }

    private nonisolated static func resolve(ip: String, databases: [LoadedDatabase]) -> GeoInfo? {
        var network: String?
        var asNumber: String?
        var asName: String?
        var asDomain: String?
        var countryCode: String?
        var countryName: String?
        var cityName: String?
        var continentCode: String?
        var continentName: String?

        for database in databases {
            guard let result = try? database.reader.lookup(ipString: ip),
                  let map = result.value.mapValue else {
                continue
            }

            let extractor = MMDBFieldExtractor(root: map)

            if network == nil, !result.network.isEmpty {
                network = result.network
            }

            if asNumber == nil, let extracted = extractor.asNumber {
                asNumber = extracted
            }
            if asName == nil, let extracted = extractor.asName {
                asName = extracted
            }
            if asDomain == nil, let extracted = extractor.asDomain {
                asDomain = extracted
            }
            if countryCode == nil, let extracted = extractor.countryCode {
                countryCode = extracted
            }
            if countryName == nil, let extracted = extractor.countryName(countryCode: countryCode) {
                countryName = extracted
            }
            if cityName == nil, let extracted = extractor.cityName {
                cityName = extracted
            }
            if continentCode == nil, let extracted = extractor.continentCode {
                continentCode = extracted
            }
            if continentName == nil, let extracted = extractor.continentName(continentCode: continentCode) {
                continentName = extracted
            }

            if network != nil,
               asNumber != nil,
               asName != nil,
               asDomain != nil,
               cityName != nil,
               countryCode != nil,
               countryName != nil,
               continentCode != nil,
               continentName != nil {
                break
            }
        }

        let resolvedASNumber = asNumber ?? "?"
        let resolvedCountryCode = countryCode ?? ""
        let resolvedNetwork = network ?? ""

        let hasUsefulData = resolvedASNumber != "?"
            || !resolvedCountryCode.isEmpty
            || !resolvedNetwork.isEmpty
            || asName != nil
            || asDomain != nil
            || cityName != nil
            || countryName != nil
            || continentCode != nil
            || continentName != nil

        guard hasUsefulData else { return nil }

        let resolvedCountryName = countryName ?? localizedCountryName(for: resolvedCountryCode)
        let resolvedContinentName = continentName ?? continentNameForCode(continentCode)

        return GeoInfo(
            asNumber: resolvedASNumber,
            asName: asName,
            asDomain: asDomain,
            network: resolvedNetwork,
            cityName: cityName,
            countryCode: resolvedCountryCode,
            countryName: resolvedCountryName,
            continentCode: continentCode,
            continentName: resolvedContinentName,
            rir: "",
            allocationDate: "",
            provider: .mmdb
        )
    }

    fileprivate nonisolated static func localizedCountryName(for countryCode: String) -> String? {
        guard countryCode.count == 2 else { return nil }
        return Locale(identifier: "en_US_POSIX").localizedString(forRegionCode: countryCode)
    }

    fileprivate nonisolated static func continentNameForCode(_ code: String?) -> String? {
        switch code?.uppercased() {
        case "AF": "Africa"
        case "AN": "Antarctica"
        case "AS": "Asia"
        case "EU": "Europe"
        case "NA": "North America"
        case "OC": "Oceania"
        case "SA": "South America"
        default: nil
        }
    }
}

private struct MMDBFieldExtractor {
    let root: [String: MMDBValue]

    nonisolated var asNumber: String? {
        if let number = unsignedInteger(at: [["autonomous_system_number"], ["traits", "autonomous_system_number"], ["asn"], ["traits", "asn"]]) {
            return "AS\(number)"
        }
        if let raw = string(at: [["autonomous_system_number"], ["asn"], ["traits", "asn"]]) {
            if raw.uppercased().hasPrefix("AS") {
                return raw.uppercased()
            }
            if let numeric = UInt64(raw) {
                return "AS\(numeric)"
            }
        }
        return nil
    }

    nonisolated var asName: String? {
        string(at: [
            ["autonomous_system_organization"],
            ["traits", "autonomous_system_organization"],
            ["as_name"],
            ["traits", "as_name"],
            ["organization"],
            ["org"]
        ])
    }

    nonisolated var asDomain: String? {
        string(at: [["as_domain"], ["traits", "as_domain"], ["domain"], ["traits", "domain"]])
    }

    nonisolated var countryCode: String? {
        if let isoCode = normalizedCountryCode(string(at: [["country", "iso_code"], ["registered_country", "iso_code"], ["country_code"]])) {
            return isoCode
        }

        if let fallback = normalizedCountryCode(string(at: [["country"], ["registered_country"]])) {
            return fallback
        }

        return nil
    }

    nonisolated var continentCode: String? {
        if let code = normalizedContinentCode(string(at: [["continent", "code"], ["continent_code"]])) {
            return code
        }

        if let fallback = normalizedContinentCode(string(at: [["continent"]])) {
            return fallback
        }

        return nil
    }

    nonisolated var cityName: String? {
        localizedName(at: ["city", "names"]) ?? string(at: [["city_name"], ["city", "name"]])
    }

    nonisolated func countryName(countryCode: String?) -> String? {
        localizedName(at: ["country", "names"]) ?? localizedName(at: ["registered_country", "names"]) ?? string(at: [["country_name"], ["country", "name"]]) ?? countryCode.flatMap { MMDBDatabaseManager.localizedCountryName(for: $0) }
    }

    nonisolated func continentName(continentCode: String?) -> String? {
        localizedName(at: ["continent", "names"]) ?? string(at: [["continent_name"], ["continent", "name"]]) ?? continentCode.flatMap { MMDBDatabaseManager.continentNameForCode($0) }
    }

    private nonisolated func string(at paths: [[String]]) -> String? {
        for path in paths {
            if let value = value(at: path)?.stringValue?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private nonisolated func unsignedInteger(at paths: [[String]]) -> UInt64? {
        for path in paths {
            if let value = value(at: path)?.unsignedIntegerValue {
                return value
            }
        }
        return nil
    }

    private nonisolated func localizedName(at path: [String]) -> String? {
        guard let names = value(at: path)?.mapValue else { return nil }
        if let english = names["en"]?.stringValue?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines), !english.isEmpty {
            return english
        }

        for value in names.values {
            if let string = value.stringValue?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines), !string.isEmpty {
                return string
            }
        }
        return nil
    }

    private nonisolated func value(at path: [String]) -> MMDBValue? {
        var current: MMDBValue = .map(root)
        for component in path {
            guard let map = current.mapValue, let next = map[component] else {
                return nil
            }
            current = next
        }
        return current
    }

    private nonisolated func normalizedCountryCode(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).uppercased()
        guard normalized.count == 2, normalized.allSatisfy({ $0.isASCII && $0.isLetter }) else {
            return nil
        }
        return normalized
    }

    private nonisolated func normalizedContinentCode(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).uppercased()
        guard normalized.count == 2 else { return nil }
        return normalized
    }
}

enum MMDBImportError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let message):
            return message
        }
    }
}
