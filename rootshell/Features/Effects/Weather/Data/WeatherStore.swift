// WeatherStore.swift
// rootshell

#if !CHINA_BUILD
import Foundation
import CoreLocation
import os

/// One fetch loop for every Live Weather surface (windows, sidebar, keyboard).
/// It runs only while a visible, foreground view holds it, so the app never
/// fetches in the background or while the effect is off.
@MainActor
@Observable
final class WeatherStore {
    static let shared = WeatherStore()

    enum Status: Equatable {
        case idle
        case fetching
        case updated
        case retrying(Date)
    }

    private(set) var snapshot: WeatherSnapshot?
    private(set) var status: Status = .idle
    private(set) var locationStatus: WeatherLocationStatus = .estimated
    private(set) var locality: String?
    private(set) var manualRefreshAt = Date.distantPast
    private(set) var deviceCoordinate: WeatherCoordinate?
    /// What a visible, live (not demo) Live Weather view is showing; nil when none is.
    private(set) var activeSelection: WeatherLocationSelection?
    /// The Show in Tab Sidebar setting, reported by the visible view.
    var showsInSidebar = true

    @ObservationIgnored private var state: WeatherDiskState
    @ObservationIgnored private let resolver = WeatherLocationResolver()
    @ObservationIgnored private var consumers = 0
    @ObservationIgnored private var selection = WeatherLocationSelection.device
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var permissionWatch: Task<Void, Never>?

    private init() {
        state = WeatherDiskCache.load() ?? WeatherDiskState()
        snapshot = state.snapshot
        deviceCoordinate = state.deviceCoordinate
        manualRefreshAt = state.policy.manualAvailableAt(now: Date())
    }

    /// Where to draw the sky for a selection, without waiting for a fetch.
    func coordinate(for selection: WeatherLocationSelection) -> WeatherCoordinate {
        switch selection {
        case .city(let city): return WeatherCoordinate(latitude: city.latitude, longitude: city.longitude)
        case .device: return deviceCoordinate ?? resolver.bestGuess
        }
    }

    /// The cached weather, if it describes this selection's location.
    func snapshot(for selection: WeatherLocationSelection) -> WeatherSnapshot? {
        guard let snapshot else { return nil }
        let wanted = coordinate(for: selection)
        return abs(snapshot.coordinate.latitude - wanted.latitude) < 0.25
            && abs(WeatherSkyGeometry.wrap180(snapshot.coordinate.longitude - wanted.longitude)) < 0.25 ? snapshot : nil
    }

    var activeSnapshot: WeatherSnapshot? { activeSelection.flatMap { snapshot(for: $0) } }
    var sidebarSnapshot: WeatherSnapshot? { showsInSidebar ? activeSnapshot : nil }

    var activePlaceName: String? {
        guard let activeSelection else { return nil }
        if case .city(let city) = activeSelection { return city.name }
        return activeSnapshot?.placeName ?? locality
    }

    /// Keeps the fetch loop alive until the calling task is cancelled.
    func hold(_ selection: WeatherLocationSelection) async {
        consumers += 1
        if activeSelection != selection { activeSelection = selection }
        if selection != self.selection || loop == nil {
            self.selection = selection
            restart()
        }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3600))
        }
        consumers -= 1
        if consumers == 0 {
            activeSelection = nil
            loop?.cancel()
            loop = nil
            if status == .fetching { status = .idle }
        }
    }

    func requestLocationPermission() {
        guard resolver.authorizationStatus == .notDetermined else { return }
        resolver.requestPermissionIfNeeded()
        permissionWatch?.cancel()
        permissionWatch = Task { [weak self] in
            for _ in 0..<120 {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                if self.resolver.authorizationStatus != .notDetermined {
                    if self.consumers > 0 { self.restart() }
                    return
                }
            }
        }
    }

    func refreshNow() {
        guard state.policy.requestManualRefresh(now: Date()) else { return }
        publishPolicy()
        if consumers > 0 {
            restart()
        } else {
            let selection = selection
            Task { [weak self] in
                guard let self else { return }
                let resolved = await self.resolver.resolve(selection)
                guard resolved.precise else { return }
                await self.fetch(resolved.coordinate)
            }
        }
    }

    // MARK: Loop

    private func restart() {
        loop?.cancel()
        loop = Task { [weak self] in await self?.run() }
    }

    private func run() async {
        while !Task.isCancelled {
            let selection = selection
            let resolved = await resolver.resolve(selection)
            guard !Task.isCancelled else { return }
            locationStatus = resolved.status
            guard resolved.precise else {
                // Wait for permission or a fix rather than fetch a guessed place.
                try? await Task.sleep(for: .seconds(15 * 60))
                continue
            }
            var coordinate = resolved.coordinate
            if case .device = selection {
                // Coarse fixes wander; keep the previous cell unless we moved.
                if let previous = state.deviceCoordinate, abs(previous.latitude - coordinate.latitude) < 0.03,
                   abs(WeatherSkyGeometry.wrap180(previous.longitude - coordinate.longitude)) < 0.03 {
                    coordinate = previous
                }
                state.deviceCoordinate = coordinate
                if deviceCoordinate != coordinate { deviceCoordinate = coordinate }
                locality = resolver.locality
            } else {
                locality = nil
            }
            if state.policyCoordinate != coordinate {
                state.policyCoordinate = coordinate
                state.policy.invalidateLocation()
                publishPolicy()
            }
            let now = Date()
            let due = state.policy.nextDue(now: now)
            if due <= now {
                await fetch(coordinate)
                continue
            }
            // In the US, the nearest station corrects "now" between forecasts.
            let observationDue = snapshot?.coordinate == coordinate
                ? WeatherSourceRouter.observationDue(coordinate, state: state.sources) : nil
            if let observationDue, observationDue <= now {
                await observe(coordinate)
                continue
            }
            if let retry = state.policy.retryAfter, retry > now { status = .retrying(retry) }
            // Wake periodically to follow the device location.
            let wake = min(due, observationDue ?? .distantFuture).timeIntervalSince(now)
            try? await Task.sleep(for: .seconds(min(wake, 15 * 60)))
        }
    }

    /// One station request; the forecast keeps its own schedule.
    private func observe(_ coordinate: WeatherCoordinate) async {
        var sources = state.sources
        let report = await WeatherSourceRouter.observe(coordinate, state: &sources, now: Date())
        state.sources = sources
        guard !Task.isCancelled else { return }
        if let report, var next = snapshot, next.coordinate == coordinate, next.observation != report.sample {
            next.observation = report.sample
            next.observationStation = report.station
            snapshot = next
            state.snapshot = next
        }
        let stateToSave = state
        Task { await WeatherDiskCache.shared.save(stateToSave) }
    }

    private func fetch(_ coordinate: WeatherCoordinate) async {
        let now = Date()
        let previous = snapshot
        var sources = state.sources
        status = .fetching
        state.policy.recordStarted(now: now)
        do {
            let outcome = try await WeatherSourceRouter.fetch(coordinate, previous: previous, state: &sources, now: now)
            state.sources = sources
            switch outcome {
            case .updated(let next):
                let changed = previous.map {
                    $0.coordinate != next.coordinate || $0.current.kind != next.current.kind
                        || abs($0.current.cloudCover - next.current.cloudCover) > 0.2
                } ?? true
                snapshot = next
                state.snapshot = next
                state.policy.recordSuccess(now: now, expiresAt: next.expiresAt, changed: changed, jitter: .random(in: 0..<1))
            case .notModified(let expires):
                state.policy.recordSuccess(now: now, expiresAt: expires, changed: false, jitter: .random(in: 0..<1))
            }
            status = .updated
        } catch {
            state.sources = sources
            if Task.isCancelled {
                status = .idle
            } else if case WeatherFetchError.rateLimited(let retry) = error {
                state.policy.recordRateLimited(retryAfterSeconds: retry, now: now)
                status = .retrying(state.policy.nextDue(now: now))
            } else {
                state.policy.recordFailure(now: now)
                status = .retrying(state.policy.nextDue(now: now))
                Ghostty.logger.info("Live Weather fetch failed: \(String(describing: error), privacy: .public)")
            }
        }
        publishPolicy()
        let snapshotToSave = state
        Task { await WeatherDiskCache.shared.save(snapshotToSave) }
    }

    private func publishPolicy() {
        manualRefreshAt = state.policy.manualAvailableAt(now: Date())
    }
}
#endif
