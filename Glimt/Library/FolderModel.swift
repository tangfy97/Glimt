import Foundation
import QuartzCore

/// The open folder: everything in it, plus the sorted and filtered view that the grid and
/// the viewer both show. Watches the folder so changes made elsewhere appear on their own.
@MainActor
final class FolderModel {
    enum SortKey: String, CaseIterable {
        case name, modified, created, added, kind, size
    }

    enum KindFilter: String, CaseIterable {
        case all, images, videos
    }

    enum Change {
        case reloaded
        case renamed(from: URL, to: URL)
    }

    private(set) var folder: URL?
    private(set) var isLoading = false
    private(set) var all: [Item] = []
    /// Visible subfolders, then visible media, each sorted.
    private(set) var folders: [Item] = []
    private(set) var media: [Item] = []
    private(set) var lastScanMilliseconds: Double = 0

    var sortKey = Preferences.sortKey {
        didSet { Preferences.sortKey = sortKey; resort() }
    }
    var ascending = Preferences.sortAscending {
        didSet { Preferences.sortAscending = ascending; resort() }
    }
    var searchText = "" {
        didSet { if searchText != oldValue { refilter() } }
    }
    var kindFilter = KindFilter.all {
        didSet { refilter() }
    }
    var tagFilter: String? {
        didSet { refilter() }
    }
    /// Every image and video below the folder instead of just its direct contents.
    var includesSubfolders = Preferences.includesSubfolders {
        didSet {
            guard includesSubfolders != oldValue else { return }
            Preferences.includesSubfolders = includesSubfolders
            isLoading = true
            resort()
            Task { await refresh() }
        }
    }
    var isFiltered: Bool { !searchText.isEmpty || kindFilter != .all || tagFilter != nil }

    private var sorted: [Item] = []
    private var observers: [UUID: (Change) -> Void] = [:]
    private var watcher: DispatchSourceFileSystemObject?
    private var scanGeneration = 0
    private var refreshScheduled = false

    // MARK: - Observation

    @discardableResult
    func observe(_ handler: @escaping (Change) -> Void) -> UUID {
        let id = UUID()
        observers[id] = handler
        return id
    }

    private func notify(_ change: Change) {
        for observer in observers.values { observer(change) }
    }

    // MARK: - Loading

    func load(_ folder: URL) async {
        // Resolve once (e.g. /var → /private/var) so every item URL compares by plain path.
        let folder = folder.resolvingSymlinksInPath()
        self.folder = folder
        all = []
        isLoading = true
        resort()
        watch(folder)
        await refresh()
    }

    func refresh() async {
        guard let folder else { return }
        scanGeneration += 1
        let generation = scanGeneration
        let started = CACurrentMediaTime()
        var items = await FolderScanner.items(in: folder, recursive: includesSubfolders)
        guard generation == scanGeneration, folder == self.folder else { return }
        lastScanMilliseconds = (CACurrentMediaTime() - started) * 1000
        // Keep the tags we already know until the tag pass below has fresh ones.
        let knownTags = Dictionary(all.lazy.filter { !$0.tags.isEmpty }.map { ($0.url, $0.tags) }, uniquingKeysWith: { a, _ in a })
        if !knownTags.isEmpty {
            for index in items.indices { items[index].tags = knownTags[items[index].url] ?? [] }
        }
        let wasLoading = isLoading
        isLoading = false
        if items != all || wasLoading {
            all = items
            resort()
        }

        Task { await loadTags(generation: generation) }
    }

    private func loadTags(generation: Int) async {
        let tags = await FolderScanner.tags(for: all.map(\.url))
        guard generation == scanGeneration else { return }
        var changed = false
        for index in all.indices {
            let fresh = tags[all[index].url] ?? []
            if all[index].tags != fresh {
                all[index].tags = fresh
                changed = true
            }
        }
        if changed { resort() }
    }

    /// Coalesces bursts of file-system events (and our own operations) into one rescan.
    func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refreshScheduled = false
                Task { await self.refresh() }
            }
        }
    }

    private func watch(_ folder: URL) {
        watcher?.cancel()
        watcher = nil
        let descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scheduleRefresh() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        watcher = source
    }

    // MARK: - Optimistic edits (the rescan that follows confirms them)

    func remove(_ urls: Set<URL>) {
        let paths = Set(urls.map { Self.path($0) })
        let before = all.count
        all.removeAll { paths.contains($0.url.path) }
        if all.count != before { resort() }
    }

    func rename(from old: URL, to new: URL) {
        guard let index = index(of: old) else { return }
        let item = all[index]
        let renamed = item.url.deletingLastPathComponent().appendingPathComponent(new.lastPathComponent)
        all[index] = item.renamed(to: renamed)
        resort(change: .renamed(from: item.url, to: renamed))
    }

    func setTags(_ tags: [String], for url: URL) {
        guard let index = index(of: url) else { return }
        all[index].tags = tags
        resort()
    }

    func item(for url: URL) -> Item? {
        index(of: url).map { all[$0] }
    }

    /// Every subfolder of the open folder, unfiltered, in name order (for the folder columns).
    var subfolderURLs: [URL] {
        all.filter { $0.kind == .folder }.map(\.url)
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Whether `url` is one of the files currently listed.
    func contains(_ url: URL) -> Bool {
        index(of: url) != nil
    }

    /// Files listed next to `url` with the same base name (RAW+JPEG pairs, Live Photo movies).
    func siblings(of url: URL) -> [URL] {
        let parent = Self.path(url.deletingLastPathComponent())
        let base = url.deletingPathExtension().lastPathComponent.lowercased()
        let path = Self.path(url)
        return all.lazy.filter {
            $0.isMedia && $0.url.path != path
                && $0.url.deletingPathExtension().lastPathComponent.lowercased() == base
                && $0.url.deletingLastPathComponent().path == parent
        }.map(\.url)
    }

    private func index(of url: URL) -> Int? {
        let path = Self.path(url)
        return all.firstIndex { $0.url.path == path }
    }

    /// Resolves symlinks in the parent only, so it also works for files that don't exist yet.
    private static func path(_ url: URL) -> String {
        url.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(url.lastPathComponent).path
    }

    // MARK: - Sorting and filtering

    private func resort(change: Change = .reloaded) {
        let key = sortKey
        let ascending = ascending
        sorted = all.sorted { a, b in
            let order: ComparisonResult
            switch key {
            case .name: order = .orderedSame
            case .modified: order = compare(a.modified, b.modified)
            case .created: order = compare(a.created, b.created)
            case .added: order = compare(a.added, b.added)
            case .kind: order = a.type == b.type ? .orderedSame : (a.type < b.type ? .orderedAscending : .orderedDescending)
            case .size: order = compare(a.fileSize, b.fileSize)
            }
            let resolved = order != .orderedSame ? order : a.name.localizedStandardCompare(b.name)
            return ascending ? resolved == .orderedAscending : resolved == .orderedDescending
        }
        refilter(change: change)
    }

    private func refilter(change: Change = .reloaded) {
        let text = searchText.trimmingCharacters(in: .whitespaces)
        let matches: (Item) -> Bool = { item in
            text.isEmpty || item.name.localizedStandardContains(text)
        }
        folders = sorted.filter { $0.kind == .folder && matches($0) }
        media = sorted.filter { item in
            guard item.isMedia, matches(item) else { return false }
            switch kindFilter {
            case .all: break
            case .images: if item.kind != .image { return false }
            case .videos: if item.kind != .video { return false }
            }
            if let tagFilter, !item.tags.contains(tagFilter) { return false }
            return true
        }
        notify(change)
    }

    private func compare<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
        a < b ? .orderedAscending : (a > b ? .orderedDescending : .orderedSame)
    }
}
