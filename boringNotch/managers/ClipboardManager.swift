//
//  ClipboardManager.swift
//  boringNotch
//

import AppKit
import CryptoKit
import Defaults
import Foundation

struct ClipboardEntry: Identifiable {
    let id: UUID
    let content: ClipboardContent
    let timestamp: Date
    let sourceApp: String?
    /// A pin is a promise the entry survives forever, so it is exempt from every automatic
    /// eviction path. Declared `var` with a default so it stays out of the way of the
    /// memberwise initialiser's existing call sites.
    var isPinned: Bool = false

    enum ClipboardContent {
        case text(String)
        case image(NSImage)
        case fileURLs([URL])
    }

    /// Rebuilds the entry with only the named fields changed.
    ///
    /// Both places that rebuild an entry — a re-copy promoting it, and an edit rewriting its
    /// text — used to spell out every field. With `isPinned` defaulting to false, forgetting
    /// it there would silently UNPIN an entry the user asked to keep forever, and nothing
    /// would report it. Going through here makes that impossible.
    func replacing(content: ClipboardContent? = nil, timestamp: Date? = nil) -> ClipboardEntry {
        ClipboardEntry(
            id: id,
            content: content ?? self.content,
            timestamp: timestamp ?? self.timestamp,
            sourceApp: sourceApp,
            isPinned: isPinned
        )
    }
}

private let secondsPerDay: TimeInterval = 86_400

// MARK: - On-disk representation

private struct PersistedEntry: Codable, Sendable {
    let id: UUID
    let kind: Kind
    let timestamp: Date
    let sourceApp: String?
    // Added after the original on-disk format; decodes as nil for files written before it existed.
    let imageHash: String?
    // Same pattern as `imageHash`: optional, so a history file written before pinning
    // existed still decodes — every entry in it simply comes back unpinned.
    let isPinned: Bool?
    /// Security-scoped bookmarks for a file entry's URLs, in the same order.
    ///
    /// A plain file URL read off the pasteboard carries a sandbox extension that dies with
    /// the process, so after a relaunch the app has no right to the file and even
    /// `NSWorkspace.open` is refused (measured: "could not be launched because a
    /// miscellaneous error occurred"). A bookmark minted at capture time, while the
    /// extension is still live, restores that right on every later launch.
    let fileBookmarks: [Data]?

    enum Kind: Codable, Sendable {
        case text(String)
        case imageFilename(String)
        case fileURLs([URL])
    }
}

private enum ClipboardPaths {
    static var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("BoringNotch", isDirectory: true)
    }

    static var metadataFile: URL {
        supportDir.appendingPathComponent("clipboard_history.json")
    }

    static var imagesDir: URL {
        supportDir.appendingPathComponent("clipboard_images", isDirectory: true)
    }

    static func imageFilename(for id: UUID) -> String {
        "\(id.uuidString).png"
    }
}

// MARK: - Disk primitives

private enum ClipboardDisk {
    static func ensureDirectory(_ url: URL) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try? fm.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        // Clipboard history is user-private; re-apply in case the directory predates this.
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    /// An atomic write replaces the file, so the mode has to be re-applied after every save.
    static func restrictFile(_ url: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func writeMetadata(_ entries: [PersistedEntry]) {
        ensureDirectory(ClipboardPaths.supportDir)
        guard let data = try? JSONEncoder().encode(entries) else { return }
        do {
            try data.write(to: ClipboardPaths.metadataFile, options: .atomic)
            restrictFile(ClipboardPaths.metadataFile)
        } catch {
            return
        }
    }

    /// `source` is the raw pasteboard payload (TIFF or PNG); transcoding it here keeps the
    /// encode off the main actor and avoids handing a non-Sendable NSImage across domains.
    static func writeImage(_ source: Data, filename: String) {
        let url = ClipboardPaths.imagesDir.appendingPathComponent(filename)
        guard !FileManager.default.fileExists(atPath: url.path),
              let rep = NSBitmapImageRep(data: source),
              let png = rep.representation(using: .png, properties: [:])
        else { return }
        ensureDirectory(ClipboardPaths.supportDir)
        ensureDirectory(ClipboardPaths.imagesDir)
        try? png.write(to: url, options: .atomic)
        restrictFile(url)
    }

    static func deleteUnreferencedImages(keeping referenced: Set<String>) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: ClipboardPaths.imagesDir.path) else { return }
        for name in names where !referenced.contains(name) {
            try? fm.removeItem(at: ClipboardPaths.imagesDir.appendingPathComponent(name))
        }
    }
}

/// Serializes every clipboard write so two rapid copies cannot interleave on the JSON file.
private actor ClipboardStore {
    static let shared = ClipboardStore()

    private var lastWrittenRevision: Int = 0

    func writeImage(_ data: Data, filename: String) {
        ClipboardDisk.writeImage(data, filename: filename)
    }

    /// Actors do not guarantee FIFO resumption, so a stale snapshot could otherwise land
    /// after a newer one; the revision counter drops anything already superseded.
    func save(_ entries: [PersistedEntry], revision: Int, referencedImages: Set<String>) {
        guard revision > lastWrittenRevision else { return }
        lastWrittenRevision = revision
        ClipboardDisk.writeMetadata(entries)
        ClipboardDisk.deleteUnreferencedImages(keeping: referencedImages)
    }
}

// MARK: - Manager

@MainActor
final class ClipboardManager: ObservableObject {
    static let shared = ClipboardManager()

    @Published private(set) var items: [ClipboardEntry] = []

    /// Which collection the clipboard panel is showing.
    ///
    /// View state, but it lives here rather than in the panel for two reasons. A `@State` in
    /// `ClipboardHistoryView` does not survive the island closing (the same teardown that
    /// reset `rowHeight` in #41), so the page would silently reset while the panel looked
    /// unchanged. And `ShelfView` sizes the grid from the count of what the panel is SHOWING;
    /// with the flag here that count is readable from outside, which a private `@State` is
    /// not. `BoringViewCoordinator` would be the more natural home, but it is outside this
    /// lane's files.
    @Published var showsPinnedOnly = false

    private var lastChangeCount: Int = 0
    private var pollingTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var saveRevision: Int = 0
    private var imageHashes: [UUID: String] = [:]
    /// Bookmarks for file entries, index-aligned with the entry's URLs. Written only when a
    /// bookmark was minted for EVERY url in the entry, so the alignment cannot drift; an
    /// entry with any non-file url (a copied web link) gets none and needs none.
    private var fileBookmarks: [UUID: [Data]] = [:]
    /// File entries captured in THIS launch. Their urls came off the pasteboard, which is
    /// what granted the sandbox extension that makes them openable — a right that dies with
    /// the process and cannot be reconstructed on the next launch.
    private var pasteboardScopedIDs: Set<UUID> = []

    private let saveDebounce: Duration = .milliseconds(250)

    /// Pinned entries keep their place in the history rather than moving to a list of their
    /// own. Pinning is a promise about LIFETIME, not a filing action: the entry is still the
    /// thing the user copied at that moment, and moving it out would make the main list lie
    /// about what was copied. It also means `items` stays the superset of everything on
    /// screen, which is what lets the panel switch pages without any list outside this
    /// manager needing to know.
    var pinnedItems: [ClipboardEntry] { items.filter(\.isPinned) }

    /// What the panel is showing right now.
    var visibleItems: [ClipboardEntry] { showsPinnedOnly ? pinnedItems : items }

    private var maxEntries: Int { Defaults[.clipboardMaxEntries] }
    private var maxHistoryAge: TimeInterval { TimeInterval(Defaults[.clipboardHistoryDays]) * secondsPerDay }

    private init() {
        lastChangeCount = NSPasteboard.general.changeCount
        loadHistory()
        observeTermination()
    }

    // MARK: - Polling

    private var pollInterval: TimeInterval {
        let battery = BatteryStatusViewModel.shared
        if battery.isInLowPowerMode { return 2.5 }
        if battery.isCharging { return 0.5 }
        return 1.0
    }

    func start() {
        guard Defaults[.clipboardHistoryEnabled] else { return }
        guard pollingTask == nil else { return }
        // Whatever sat on the pasteboard while the feature was off is not ours to record.
        lastChangeCount = NSPasteboard.general.changeCount
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                try? await Task.sleep(for: .seconds(self.pollInterval))
                guard !Task.isCancelled else { return }
                self.checkClipboard()
            }
        }
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    func setEnabled(_ on: Bool) {
        if on {
            start()
        } else {
            stop()
        }
    }

    private func checkClipboard() {
        guard Defaults[.clipboardHistoryEnabled] else {
            stop()
            return
        }

        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount

        guard !isExcluded(pb) else { return }

        let sourceApp = pb.pasteboardItems?.first?
            .string(forType: .init("com.apple.pboard.source-app-bundle-id"))

        if let text = pb.string(forType: .string),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            if case .text(let last) = items.first?.content, last == text { return }
            addEntry(.init(id: .init(), content: .text(text), timestamp: Date(), sourceApp: sourceApp))
        } else if let data = pb.data(forType: .tiff) ?? pb.data(forType: .init("public.png")),
                  let image = NSImage(data: data)
        {
            let hash = Self.hash(of: data)
            if let duplicate = items.first(where: { imageHashes[$0.id] == hash }) {
                promote(duplicate)
                return
            }
            let entry = ClipboardEntry(id: .init(), content: .image(image), timestamp: Date(), sourceApp: sourceApp)
            imageHashes[entry.id] = hash
            addEntry(entry, imageSource: data)
        } else if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
                  !urls.isEmpty
        {
            let entry = ClipboardEntry(id: .init(), content: .fileURLs(urls), timestamp: Date(), sourceApp: sourceApp)
            // Minted HERE, in the same turn the urls are read, because reading them off the
            // pasteboard is what grants the sandbox extension a bookmark needs to exist.
            pasteboardScopedIDs.insert(entry.id)
            let bookmarks = Self.securityScopedBookmarks(for: urls)
            if !bookmarks.isEmpty { fileBookmarks[entry.id] = bookmarks }
            addEntry(entry)
        }
    }

    /// `pb.types` only reports the types of the *first* pasteboard item, so a concealed item
    /// sitting behind a plain-text item would otherwise be recorded in cleartext.
    private func isExcluded(_ pb: NSPasteboard) -> Bool {
        let excluded: Set<NSPasteboard.PasteboardType> = [
            .init("org.nspasteboard.ConcealedType"),
            .init("org.nspasteboard.TransientType"),
            .init("org.nspasteboard.AutoGeneratedType"),
        ]
        var types = Set(pb.types ?? [])
        for item in pb.pasteboardItems ?? [] {
            types.formUnion(item.types)
        }
        return !types.isDisjoint(with: excluded)
    }

    private func addEntry(_ entry: ClipboardEntry, imageSource: Data? = nil) {
        items.insert(entry, at: 0)
        didCapture()
        if let imageSource {
            let filename = ClipboardPaths.imageFilename(for: entry.id)
            Task { await ClipboardStore.shared.writeImage(imageSource, filename: filename) }
        }
        enforceLimits()
    }

    /// One place for everything a new capture implies.
    ///
    /// The page reset is here because `clipboardDidCapture()` can route the notch to the
    /// clipboard panel: landing on the pinned collection, which by definition does not
    /// contain what was just copied, would read as capture being broken. A capture is the
    /// one moment the user is being shown something they did not ask to see, so it is also
    /// the one moment the page may be changed under them.
    private func didCapture() {
        showsPinnedOnly = false
        TabRoutingManager.shared.clipboardDidCapture()
    }

    /// Re-copying an image already in the history moves it back to the front instead of
    /// writing a second identical PNG.
    private func promote(_ entry: ClipboardEntry) {
        guard let index = items.firstIndex(where: { $0.id == entry.id }), index != 0 else { return }
        let refreshed = entry.replacing(timestamp: Date())
        items.remove(at: index)
        items.insert(refreshed, at: 0)
        didCapture()
        persist()
    }

    // MARK: - Public API

    /// Puts objects on the system pasteboard without recording them in history.
    ///
    /// The pasteboard's change count is claimed here, so the poller sees the write as
    /// already handled. Unlike marking the write transient, this keeps the content a
    /// normal clipboard entry for every other app — only this app's history skips it.
    func copyWithoutRecording(_ objects: [NSPasteboardWriting]) {
        guard !objects.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(objects)
        lastChangeCount = pb.changeCount
    }

    func copy(_ entry: ClipboardEntry) {
        let pb = NSPasteboard.general
        pb.clearContents()
        switch entry.content {
        case .text(let str):    pb.setString(str, forType: .string)
        case .image(let img):   pb.writeObjects([img])
        case .fileURLs(let u):  pb.writeObjects(u as [NSURL])
        }
        lastChangeCount = pb.changeCount
    }

    /// Replaces a stored text entry's content in place, keeping its id, timestamp, source app
    /// and position — an edit is a correction, not a new copy, and promoting it would reorder
    /// tiles under a live cursor.
    ///
    /// Also refreshes the previewed entry when ids match: the preview panel holds `entry` as a
    /// value snapshot, so without this it would keep comparing a saved draft against the old
    /// text and report itself as still edited.
    func updateText(_ text: String, for id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }),
              case .text = items[index].content
        else { return }

        let updated = items[index].replacing(content: .text(text))
        items[index] = updated

        if BoringViewCoordinator.shared.clipboardPreviewEntry?.id == id {
            BoringViewCoordinator.shared.clipboardPreviewEntry = updated
        }
        persist()
    }

    /// Pins or unpins in place: same id, same timestamp, same position in the list.
    ///
    /// Deliberately not a promote. Pinning is not a copy, and reordering the strip under the
    /// cursor that just clicked a corner control is the reason `updateText` holds its
    /// position too.
    func togglePin(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].isPinned.toggle()

        // The preview panel holds its entry as a value snapshot, so without this it would
        // keep showing the pre-toggle pin state — the same staleness `updateText` fixes.
        if BoringViewCoordinator.shared.clipboardPreviewEntry?.id == id {
            BoringViewCoordinator.shared.clipboardPreviewEntry = items[index]
        }

        // An unpin can drop the entry straight out of a history it only survived because it
        // was pinned, which is correct: the exemption is gone the moment the promise is.
        if items[index].isPinned {
            persist()
        } else {
            enforceLimits()
        }
    }

    /// Whether this app still holds the right to hand the entry's files to another app.
    ///
    /// Answered from what was recorded at capture time, never by touching the filesystem: a
    /// `isReadableFile` probe per tile would stat on every body evaluation and can block for
    /// seconds on a disconnected volume. Entries written before bookmarks were captured
    /// answer false after a relaunch, which is the truth — see `PersistedEntry.fileBookmarks`.
    ///
    /// A false answer WITHHOLDS the open control; it does not dim it. #48 replaced the
    /// preview on file tiles because a path is not worth reading, but an arrow that cannot
    /// open anything is worse than the preview it replaced — so those tiles keep the
    /// preview, which still works without any rights to the file. Do not "finish" this by
    /// showing a disabled arrow instead.
    func canOpenFiles(_ entry: ClipboardEntry) -> Bool {
        guard case .fileURLs(let urls) = entry.content, let first = urls.first else { return false }
        // A copied web link is not a sandboxed resource; opening it needs no rights at all.
        guard first.isFileURL else { return true }
        return fileBookmarks[entry.id] != nil || pasteboardScopedIDs.contains(entry.id)
    }

    /// Hands the entry's files to their default apps.
    ///
    /// Bookmarks first, because they are the only route that survives a relaunch. The plain
    /// urls are the fallback for entries captured before bookmarks were recorded, and work
    /// only inside the launch that copied them.
    ///
    /// Access is held until LaunchServices has finished with the url, which is what vends the
    /// receiving app its own extension — verified with a sandboxed receiver that read the
    /// file it was handed.
    func openFiles(_ entry: ClipboardEntry) {
        guard case .fileURLs(let urls) = entry.content, !urls.isEmpty else { return }

        var targets: [URL] = []
        var accessed: [URL] = []
        if let bookmarks = fileBookmarks[entry.id], bookmarks.count == urls.count {
            for data in bookmarks {
                var stale = false
                guard let url = try? URL(
                    resolvingBookmarkData: data,
                    options: [.withSecurityScope],
                    relativeTo: nil,
                    bookmarkDataIsStale: &stale
                ) else { continue }
                // Only a RESOLVED bookmark is security-scoped. Measured: the same call on a
                // url read straight off the pasteboard returns false, because a pasteboard
                // url is not a security-scoped url at all — it carries a plain sandbox
                // extension instead. So the shelf's `.filter { $0.startAccessing... }`
                // idiom must never be applied to a clipboard url: it would discard every
                // one of them. Hence `targets` collects the url either way and only
                // `accessed` — what actually has to be released — is filtered.
                if url.startAccessingSecurityScopedResource() { accessed.append(url) }
                targets.append(url)
            }
        }
        if targets.isEmpty { targets = urls }

        let configuration = NSWorkspace.OpenConfiguration()
        Task {
            for url in targets {
                _ = try? await NSWorkspace.shared.open(url, configuration: configuration)
            }
            for url in accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }
    }

    /// All-or-nothing, so the returned array is always index-aligned with `urls`. A single
    /// non-file url (a copied web link) or a single failure yields none, and `openFiles`
    /// falls back to the plain urls.
    ///
    /// The asymmetry this rests on is surprising enough to be worth stating: a pasteboard
    /// url reports itself as NOT security-scoped (`startAccessingSecurityScopedResource()`
    /// is false), yet `bookmarkData(options: [.withSecurityScope])` on that same url
    /// succeeds, and the bookmark resolves in a later process with `stale == false`. That is
    /// the only reason a right which otherwise dies with the process can be made permanent.
    /// It only works while the extension is live, which is why this is called in the same
    /// turn the urls are read and not later.
    private static func securityScopedBookmarks(for urls: [URL]) -> [Data] {
        guard urls.allSatisfy(\.isFileURL) else { return [] }
        var bookmarks: [Data] = []
        for url in urls {
            guard let data = try? url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) else { return [] }
            bookmarks.append(data)
        }
        return bookmarks
    }

    func remove(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items.remove(at: index)
        imageHashes[id] = nil
        fileBookmarks[id] = nil
        pasteboardScopedIDs.remove(id)
        ClipboardDragFileStore.shared.discard(id)
        ClipboardDraftStore.shared.clear(id)
        if BoringViewCoordinator.shared.clipboardPreviewEntry?.id == id {
            BoringViewCoordinator.shared.clipboardPreviewEntry = nil
        }
        persist()
    }

    /// Clears the history but KEEPS pinned entries.
    ///
    /// "Forever persistent" has to mean something, and a single button that silently defeats
    /// it would make the pin worthless. Unpinning is the way to make a pinned entry
    /// clearable, which is exactly what the pinned page is for. The button's tooltip says so.
    func clear() {
        let kept = pinnedItems
        let keptIDs = Set(kept.map(\.id))
        for entry in items where !keptIDs.contains(entry.id) {
            ClipboardDragFileStore.shared.discard(entry.id)
            ClipboardDraftStore.shared.clear(entry.id)
        }
        items = kept
        imageHashes = imageHashes.filter { keptIDs.contains($0.key) }
        fileBookmarks = fileBookmarks.filter { keptIDs.contains($0.key) }
        pasteboardScopedIDs = pasteboardScopedIDs.intersection(keptIDs)
        if let previewed = BoringViewCoordinator.shared.clipboardPreviewEntry,
           !keptIDs.contains(previewed.id)
        {
            BoringViewCoordinator.shared.clipboardPreviewEntry = nil
        }
        persist()
    }

    /// The one eviction path. Pinned entries are exempt from BOTH limits, and — just as
    /// important — they do not spend the count budget: the cap is applied to unpinned entries
    /// only. Charging pins against `clipboardMaxEntries` would mean pinning 50 things quietly
    /// deletes all recent history, which is the opposite of what a pin is for.
    ///
    /// Reduces to the previous behaviour exactly when nothing is pinned: `items` is
    /// newest-first, so taking the first `maxEntries` survivors is the old `prefix`.
    func enforceLimits() {
        let cutoff = Date().addingTimeInterval(-maxHistoryAge)
        var unpinnedKept = 0
        var kept: [ClipboardEntry] = []
        for entry in items {
            if entry.isPinned {
                kept.append(entry)
                continue
            }
            guard entry.timestamp > cutoff, unpinnedKept < maxEntries else { continue }
            unpinnedKept += 1
            kept.append(entry)
        }
        if kept.count != items.count {
            let survivors = Set(kept.map(\.id))
            imageHashes = imageHashes.filter { survivors.contains($0.key) }
            fileBookmarks = fileBookmarks.filter { survivors.contains($0.key) }
            pasteboardScopedIDs = pasteboardScopedIDs.intersection(survivors)
            for dropped in items where !survivors.contains(dropped.id) {
                ClipboardDragFileStore.shared.discard(dropped.id)
                ClipboardDraftStore.shared.clear(dropped.id)
            }
            if let previewed = BoringViewCoordinator.shared.clipboardPreviewEntry,
               !survivors.contains(previewed.id)
            {
                BoringViewCoordinator.shared.clipboardPreviewEntry = nil
            }
            items = kept
        }
        persist()
    }

    func pruneOldEntries() {
        enforceLimits()
    }

    // MARK: - Load

    private func loadHistory() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: ClipboardPaths.metadataFile.path),
              let data = try? Data(contentsOf: ClipboardPaths.metadataFile),
              let persisted = try? JSONDecoder().decode([PersistedEntry].self, from: data)
        else {
            // No readable metadata means every image file on disk is orphaned.
            persist()
            return
        }

        let cutoff = Date().addingTimeInterval(-maxHistoryAge)
        // The age cutoff is applied here as well as in `enforceLimits`, so the exemption has
        // to be repeated: without it a pinned entry older than `clipboardHistoryDays` would
        // be dropped on load and the pin would only look permanent until the next launch.
        for entry in persisted where entry.timestamp > cutoff || entry.isPinned == true {
            guard let restored = restoreEntry(entry) else { continue }
            items.append(restored)
            if let hash = entry.imageHash {
                imageHashes[restored.id] = hash
            }
            if let bookmarks = entry.fileBookmarks, !bookmarks.isEmpty {
                fileBookmarks[restored.id] = bookmarks
            }
        }

        // Rewrites metadata without the entries that failed to restore and sweeps every
        // image file the survivors no longer reference.
        enforceLimits()
    }

    private func restoreEntry(_ persisted: PersistedEntry) -> ClipboardEntry? {
        let content: ClipboardEntry.ClipboardContent
        switch persisted.kind {
        case .text(let str):
            content = .text(str)
        case .imageFilename(let name):
            let url = ClipboardPaths.imagesDir.appendingPathComponent(name)
            guard let img = NSImage(contentsOf: url) else { return nil }
            content = .image(img)
        case .fileURLs(let urls):
            // Capture never produces an empty list, but a truncated or hand-edited
            // history file can; dropping it here keeps it out of the rewritten metadata.
            guard !urls.isEmpty else { return nil }
            content = .fileURLs(urls)
        }
        return ClipboardEntry(
            id: persisted.id,
            content: content,
            timestamp: persisted.timestamp,
            sourceApp: persisted.sourceApp,
            isPinned: persisted.isPinned ?? false
        )
    }

    // MARK: - Save

    private func persist() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.saveDebounce)
            guard !Task.isCancelled else { return }
            await self.flush()
        }
    }

    private func flush() async {
        saveRevision += 1
        let revision = saveRevision
        let snapshot = items.map { persistedEntry(for: $0) }
        await ClipboardStore.shared.save(
            snapshot,
            revision: revision,
            referencedImages: Self.referencedImageNames(in: snapshot)
        )
    }

    /// A quit inside the debounce window would otherwise drop the most recent copy.
    private func flushSynchronously() {
        saveTask?.cancel()
        ClipboardDisk.writeMetadata(items.map { persistedEntry(for: $0) })
    }

    private func observeTermination() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.flushSynchronously()
            }
        }
    }

    private func persistedEntry(for entry: ClipboardEntry) -> PersistedEntry {
        let kind: PersistedEntry.Kind
        switch entry.content {
        case .text(let str):    kind = .text(str)
        case .image:            kind = .imageFilename(ClipboardPaths.imageFilename(for: entry.id))
        case .fileURLs(let u):  kind = .fileURLs(u)
        }
        return PersistedEntry(
            id: entry.id,
            kind: kind,
            timestamp: entry.timestamp,
            sourceApp: entry.sourceApp,
            imageHash: imageHashes[entry.id],
            isPinned: entry.isPinned,
            fileBookmarks: fileBookmarks[entry.id]
        )
    }

    private static func referencedImageNames(in entries: [PersistedEntry]) -> Set<String> {
        var names = Set<String>()
        for entry in entries {
            if case .imageFilename(let name) = entry.kind { names.insert(name) }
        }
        return names
    }

    private static func hash(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
