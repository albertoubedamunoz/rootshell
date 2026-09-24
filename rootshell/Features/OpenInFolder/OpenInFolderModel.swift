//
//  OpenInFolderModel.swift
//  rootshell
//
//  State for the Open in Folder palette: the typed path, the candidates it
//  resolves to on the target, the highlighted folder's preview, and the
//  placement of the shell about to open.
//

import Foundation

@MainActor @Observable
final class OpenInFolderModel {
    struct Candidate: Identifiable, Hashable {
        enum Kind { case openPane, recent, folder }
        let id: String
        let kind: Kind
        /// Absolute, or `~user`-anchored until the host resolves it.
        let path: String
        let title: String
        let detail: String?
    }

    struct Section: Identifiable {
        let id: String
        let title: String
        let candidates: [Candidate]
    }

    struct PreviewInfo: Equatable {
        let path: String
        let folders: Int
        let files: Int
        let head: [DirectoryEntry]
        let hasGit: Bool
        let truncated: Bool
    }

    enum Preview: Equatable {
        case idle
        case loading(String)
        case loaded(PreviewInfo)
        case failed(String, String)
    }

    static let previewHeadCount = 12
    private static let typingDebounce: Duration = .milliseconds(100)
    private static let previewDebounce: Duration = .milliseconds(250)

    let target: OpenInFolderTarget
    /// Why the target cannot be browsed; typed paths still open.
    private(set) var unavailableReason: String?
    var query = ""
    /// The directory the current candidates were listed from.
    private(set) var listedDirectory: String?
    private(set) var sections: [Section] = []
    var selection: String?
    private(set) var preview: Preview = .idle
    private(set) var isListing = false
    var error: String?
    var placement: OpenInFolderPlacement
    var focusRequest = 1

    private let lister: (any DirectoryLister)?
    private let service = DirectoryListingService.shared
    private var recents: [String]
    private var listingGeneration = 0
    private var previewGeneration = 0
    private var listingTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var lastSplit: PathCompletion.Split?
    private var programmaticQuery: String?

    init(target: OpenInFolderTarget) {
        self.target = target
        switch target.lister {
        case .available(let lister):
            self.lister = lister
        case .unavailable(let reason):
            lister = nil
            switch reason {
            case .notConnectedYet:
                unavailableReason = String(localized: "Still connecting. Type a folder path to open it there.",
                                           comment: "Open in Folder status")
            case .unsupportedTarget:
                unavailableReason = String(localized: "This pane has no browsable filesystem.",
                                           comment: "Open in Folder status")
            }
        }
        recents = OpenInFolderRecentsStore.recents(for: target.targetKey)
        let saved = OpenInFolderRecentsStore.placement
        placement = target.availablePlacements.contains(saved) ? saved : .newTab
        queryChanged(immediate: true)
    }

    // MARK: Derived

    /// Home as far as we know it; `~` stands in until the host tells us.
    var home: String { lister?.homeDirectory ?? "~" }

    /// The pane's cwd, or home when unknown.
    var cwd: String { target.currentDirectory ?? home }

    var canBrowse: Bool { lister != nil && unavailableReason == nil }

    var allCandidates: [Candidate] { sections.flatMap(\.candidates) }

    var selectedCandidate: Candidate? {
        let all = allCandidates
        return all.first { $0.id == selection } ?? all.first
    }

    var supportHint: String? {
        guard case .onCreateOnly(let multiplexer) = target.support else { return nil }
        return String(localized: "Applies when the \(multiplexer) session is created, not when attaching.",
                      comment: "Open in Folder hint")
    }

    func display(_ path: String) -> String {
        home == "~" ? path : PathCompletion.displayPath(path, home: home)
    }

    // MARK: Listing

    /// Re-resolves the typed text. Programmatic edits (Tab, parent, row taps)
    /// pass `immediate`; keystrokes debounce so a burst costs one round trip.
    func queryChanged(immediate: Bool = false) {
        if !immediate, programmaticQuery == query {
            programmaticQuery = nil
            return
        }
        listingTask?.cancel()
        listingGeneration &+= 1
        let generation = listingGeneration
        error = nil
        selectionIsExplicit = false
        let split = PathCompletion.split(query, cwd: cwd, home: home)
        lastSplit = split
        guard let lister, unavailableReason == nil else {
            rebuildSections(listing: nil, split: split)
            return
        }
        guard let directoryTarget = DirectoryTarget.resolve(split.directory, baseDirectory: nil) else {
            rebuildSections(listing: nil, split: split)
            error = String(localized: "That path can't be listed.", comment: "Open in Folder error")
            return
        }
        // Whatever the cache has shows now; the host answer replaces it.
        if let cached = service.cached(directoryTarget, using: lister) {
            rebuildSections(listing: cached, split: split)
        } else if listedDirectory != split.directory {
            rebuildSections(listing: nil, split: split)
        }
        listingTask = Task { [weak self] in
            if !immediate {
                try? await Task.sleep(for: Self.typingDebounce)
            }
            guard let self, !Task.isCancelled, self.listingGeneration == generation else { return }
            self.isListing = true
            defer { if self.listingGeneration == generation { self.isListing = false } }
            do {
                for try await snapshot in self.service.listing(directoryTarget, using: lister) {
                    guard !Task.isCancelled, self.listingGeneration == generation else { return }
                    self.rebuildSections(listing: snapshot.result, split: split)
                    if !snapshot.isStale {
                        let preferred = self.sections.flatMap(\.candidates)
                            .filter { $0.kind == .folder }
                            .map { ($0.path as NSString).lastPathComponent }
                        self.service.scanAhead(from: snapshot.result, preferred: preferred, using: lister)
                    }
                }
            } catch {
                guard self.listingGeneration == generation else { return }
                if self.sections.isEmpty || self.listedDirectory != split.directory {
                    self.error = String(localized: "Couldn't list folders on \(self.target.displayName).",
                                        comment: "Open in Folder error")
                }
            }
        }
    }

    private func rebuildSections(listing: DirectoryListingResult?, split: PathCompletion.Split) {
        let directory = listing?.resolvedPath ?? split.directory
        listedDirectory = directory
        var sections: [Section] = []
        let filesystemOnly = Self.isPathLike(query)

        if !filesystemOnly {
            let seeds = target.seedDirectories.filter { Self.matches(split.prefix, path: $0) }
            if !seeds.isEmpty {
                sections.append(Section(
                    id: "open",
                    title: String(localized: "Open on this target", comment: "Open in Folder section"),
                    candidates: seeds.map { candidate(kind: .openPane, path: $0) }
                ))
            }
            let seen = Set(seeds)
            let cwdNormalized = target.currentDirectory
            let recent = recents.filter { $0 != cwdNormalized && !seen.contains($0) && Self.matches(split.prefix, path: $0) }
            if !recent.isEmpty {
                sections.append(Section(
                    id: "recent",
                    title: String(localized: "Recent", comment: "Open in Folder section"),
                    candidates: recent.prefix(8).map { candidate(kind: .recent, path: $0) }
                ))
            }
        }

        if let listing {
            if let listingError = listing.error {
                error = Self.message(for: listingError, directory: display(directory))
            } else {
                let names = PathCompletion.rankedFolders(listing.directories.map(\.name), prefix: split.prefix)
                sections.append(Section(
                    id: "folders",
                    title: String(localized: "Folders in \(display(directory))", comment: "Open in Folder section"),
                    candidates: names.map { name in
                        Candidate(id: "folder|\(PathCompletion.join(directory, name))", kind: .folder,
                                  path: PathCompletion.join(directory, name), title: name, detail: nil)
                    }
                ))
            }
        }

        self.sections = sections
        let ids = allCandidates.map(\.id)
        if let selection, ids.contains(selection) {
            // Keep the highlight through a refresh.
        } else {
            selection = ids.first
        }
        selectionChanged()
    }

    private func candidate(kind: Candidate.Kind, path: String) -> Candidate {
        Candidate(id: "\(kind)|\(path)", kind: kind, path: path,
                  title: (path as NSString).lastPathComponent, detail: display(path))
    }

    /// Text with a slash, `~`, or a dot component is a path, not a search.
    nonisolated static func isPathLike(_ query: String) -> Bool {
        query.contains("/") || query.hasPrefix("~") || query == "." || query == ".."
    }

    nonisolated static func matches(_ prefix: String, path: String) -> Bool {
        guard !prefix.isEmpty else { return true }
        let name = (path as NSString).lastPathComponent
        return PathCompletion.rank(prefix, against: name) != nil || path.lowercased().contains(prefix.lowercased())
    }

    private static func message(for error: DirectoryListingError, directory: String) -> String {
        switch error {
        case .notFound:
            return String(localized: "No folder named \(directory).", comment: "Open in Folder error")
        case .notDirectory:
            return String(localized: "\(directory) is not a folder.", comment: "Open in Folder error")
        case .permissionDenied:
            return String(localized: "You don't have permission to read \(directory).", comment: "Open in Folder error")
        case .unsupportedPath:
            return String(localized: "That path can't be listed.", comment: "Open in Folder error")
        case .malformedResponse:
            return String(localized: "The host returned an unexpected reply.", comment: "Open in Folder error")
        }
    }

    // MARK: Navigation

    /// True once the user arrowed to or clicked a row; the default highlight
    /// on a fresh listing defers to the typed path on Return, a chosen one wins.
    private(set) var selectionIsExplicit = false

    func move(_ offset: Int) {
        let ids = allCandidates.map(\.id)
        let next = QuickSettingsInput.movedID(ids, current: selection, offset: offset)
        selectionIsExplicit = true
        if next != selection {
            selection = next
            selectionChanged()
        }
    }

    func select(_ candidate: Candidate) {
        selectionIsExplicit = true
        selection = candidate.id
        selectionChanged()
    }

    /// Tab, shell style with menu completion: a unique prefix match completes
    /// outright, otherwise the highlighted folder is accepted. Each accepted
    /// folder ends in `/` and lists its children, so Tab chains downward.
    func tabComplete() {
        let split = lastSplit ?? PathCompletion.split(query, cwd: cwd, home: home)
        let folders = allCandidates.filter { $0.kind == .folder }
        if !split.prefix.isEmpty {
            let exact = folders.filter { PathCompletion.rank(split.prefix, against: $0.title).map { $0 >= .prefix } ?? false }
            if exact.count == 1 {
                accept(exact[0], listedIn: split.directory)
                return
            }
        }
        if let selected = selectedCandidate {
            accept(selected, listedIn: split.directory)
        } else if folders.count == 1 {
            accept(folders[0], listedIn: split.directory)
        }
    }

    private func accept(_ candidate: Candidate, listedIn directory: String) {
        switch candidate.kind {
        case .folder:
            setQuery(PathCompletion.completedText(
                directory: directory, name: candidate.title, originalText: query, cwd: cwd, home: home
            ))
        case .openPane, .recent:
            setQuery(display(candidate.path) + "/")
        }
    }

    /// Shift+Tab: list the parent of the directory being listed.
    func goToParent() {
        let split = lastSplit ?? PathCompletion.split(query, cwd: cwd, home: home)
        let parent = PathCompletion.parent(of: split.directory)
        if parent.hasPrefix("~") {
            setQuery(parent + "/")
        } else if parent == "/" {
            setQuery("/")
        } else {
            setQuery(display(parent) + "/")
        }
    }

    /// A programmatic edit lists at once; the view's debounced reaction to
    /// the same text is skipped. The field keeps focus and the caret lands at
    /// the end, so typing continues the path instead of replacing it.
    private func setQuery(_ text: String) {
        query = text
        programmaticQuery = text
        queryChanged(immediate: true)
    }

    // MARK: Preview

    func selectionChanged() {
        previewTask?.cancel()
        previewGeneration &+= 1
        let generation = previewGeneration
        guard let candidate = selectedCandidate else {
            preview = .idle
            return
        }
        guard let lister, unavailableReason == nil,
              let directoryTarget = DirectoryTarget.resolve(candidate.path, baseDirectory: nil)
        else {
            preview = .idle
            return
        }
        if let cached = service.cached(directoryTarget, using: lister) {
            preview = Self.previewState(for: cached, path: candidate.path, display: display(candidate.path))
            return
        }
        // Only a resting highlight costs a round trip; arrowing through never does.
        preview = .loading(display(candidate.path))
        previewTask = Task { [weak self] in
            try? await Task.sleep(for: Self.previewDebounce)
            guard let self, !Task.isCancelled, self.previewGeneration == generation else { return }
            do {
                for try await snapshot in self.service.listing(directoryTarget, using: lister) {
                    guard !Task.isCancelled, self.previewGeneration == generation else { return }
                    self.preview = Self.previewState(for: snapshot.result, path: candidate.path,
                                                     display: self.display(candidate.path))
                }
            } catch {
                guard self.previewGeneration == generation else { return }
                self.preview = .failed(self.display(candidate.path),
                                       String(localized: "Preview unavailable", comment: "Open in Folder preview"))
            }
        }
    }

    private static func previewState(for listing: DirectoryListingResult, path: String, display: String) -> Preview {
        if let error = listing.error {
            return .failed(display, message(for: error, directory: display))
        }
        let sorted = listing.entries.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        let folders = listing.entries.filter(\.isDirectory).count
        return .loaded(PreviewInfo(
            path: display,
            folders: folders,
            files: listing.entries.count - folders,
            head: Array(sorted.prefix(previewHeadCount)),
            hasGit: listing.entries.contains { $0.name == ".git" && $0.isDirectory },
            truncated: listing.truncated
        ))
    }

    // MARK: Placement

    func setPlacement(index: Int) {
        let available = target.availablePlacements
        guard available.indices.contains(index) else { return }
        placement = available[index]
    }

    // MARK: Submit

    /// The absolute directory to open, or nil after setting `error`. An
    /// explicit `candidate` (a clicked row) wins over whatever the field says.
    func resolveSubmission(candidate explicit: Candidate? = nil) async -> String? {
        error = nil
        if let explicit {
            return await resolve(explicit)
        }
        if selectionIsExplicit, let candidate = selectedCandidate {
            return await resolve(candidate)
        }
        if query.isEmpty, let current = target.currentDirectory {
            return current
        }
        if let candidate = selectedCandidate, !PathCompletion.endsWithSeparator(query) || query.isEmpty {
            return await resolve(candidate)
        }
        return await validate(query.isEmpty ? "~" : query)
    }

    private func resolve(_ candidate: Candidate) async -> String? {
        if candidate.kind == .folder, candidate.path.hasPrefix("/") { return candidate.path }
        return await validate(candidate.path)
    }

    /// Confirms a typed or remembered path exists on the target and returns
    /// its absolute form. Without a lister the typed path is trusted as-is.
    private func validate(_ typed: String) async -> String? {
        let base = target.currentDirectory
        guard let directoryTarget = DirectoryTarget.resolve(typed, baseDirectory: base) else {
            error = String(localized: "That path can't be opened.", comment: "Open in Folder error")
            return nil
        }
        guard let lister, unavailableReason == nil else {
            // No way to ask the host: only an absolute path can be trusted.
            if case .absolute(let path) = directoryTarget { return path }
            if case .absolute(let path) = DirectoryListingService.canonical(directoryTarget, home: home == "~" ? nil : home) {
                return path
            }
            error = String(localized: "Type an absolute path; the folder can't be checked on this pane.",
                           comment: "Open in Folder error")
            return nil
        }
        do {
            var resolved: String?
            var listingError: DirectoryListingError?
            for try await snapshot in service.listing(directoryTarget, using: lister) {
                resolved = snapshot.result.resolvedPath
                listingError = snapshot.result.error
                if !snapshot.isStale { break }
            }
            if let listingError {
                error = Self.message(for: listingError, directory: typed)
                return nil
            }
            guard let resolved, resolved.hasPrefix("/") else {
                error = String(localized: "The host did not confirm that folder.", comment: "Open in Folder error")
                return nil
            }
            return resolved
        } catch {
            self.error = String(localized: "Couldn't reach \(target.displayName) to check that folder.",
                                comment: "Open in Folder error")
            return nil
        }
    }

    func rememberOpened(_ directory: String) {
        recents.removeAll { $0 == directory }
        recents.insert(directory, at: 0)
    }

    /// The in-flight Return/click, so dismissal can cancel it: a slow remote
    /// validation must never open a pane after the palette has gone.
    var submissionTask: Task<Void, Never>?
    private(set) var isEnded = false

    func end() {
        isEnded = true
        submissionTask?.cancel()
        listingTask?.cancel()
        previewTask?.cancel()
        lister?.end()
    }
}
