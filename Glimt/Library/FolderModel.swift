import Foundation
import QuartzCore

/// The open folder: everything in it, plus the sorted and filtered view that the grid and
/// the viewer both show. Watches the folder so changes made elsewhere appear on their own.
@MainActor
final class FolderModel {
    enum SortKey: String, CaseIterable {
        case name, modified, created, size
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
        var items = await FolderScanner.items(in: folder)
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
        all[index] = Item(url: renamed, kind: item.kind, fileSize: item.fileSize, modified: item.modified, created: item.created, tags: item.tags)
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

    /// Whether `url` lives directly in the open folder.
    func contains(folderOf url: URL) -> Bool {
        guard let folder else { return false }
        return Self.path(url.deletingLastPathComponent()) == folder.path
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
