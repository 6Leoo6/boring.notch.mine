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

    enum ClipboardContent {
        case text(String)
        case image(NSImage)
        case fileURLs([URL])
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

    private var lastChangeCount: Int = 0
    private var pollingTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var saveRevision: Int = 0
    private var imageHashes: [UUID: String] = [:]

    private let saveDebounce: Duration = .milliseconds(250)

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
            addEntry(.init(id: .init(), content: .fileURLs(urls), timestamp: Date(), sourceApp: sourceApp))
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
        if let imageSource {
            let filename = ClipboardPaths.imageFilename(for: entry.id)
            Task { await ClipboardStore.shared.writeImage(imageSource, filename: filename) }
        }
        enforceLimits()
    }

    /// Re-copying an image already in the history moves it back to the front instead of
    /// writing a second identical PNG.
    private func promote(_ entry: ClipboardEntry) {
        guard let index = items.firstIndex(where: { $0.id == entry.id }), index != 0 else { return }
        let refreshed = ClipboardEntry(
            id: entry.id,
            content: entry.content,
            timestamp: Date(),
            sourceApp: entry.sourceApp
        )
        items.remove(at: index)
        items.insert(refreshed, at: 0)
        persist()
    }

    // MARK: - Public API

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

    func remove(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items.remove(at: index)
        imageHashes[id] = nil
        if BoringViewCoordinator.shared.clipboardPreviewEntry?.id == id {
            BoringViewCoordinator.shared.clipboardPreviewEntry = nil
        }
        persist()
    }

    func clear() {
        items.removeAll()
        imageHashes.removeAll()
        BoringViewCoordinator.shared.clipboardPreviewEntry = nil
        persist()
    }

    func enforceLimits() {
        let cutoff = Date().addingTimeInterval(-maxHistoryAge)
        var kept = items.filter { $0.timestamp > cutoff }
        if kept.count > maxEntries {
            kept = Array(kept.prefix(maxEntries))
        }
        if kept.count != items.count {
            let survivors = Set(kept.map(\.id))
            imageHashes = imageHashes.filter { survivors.contains($0.key) }
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
        for entry in persisted where entry.timestamp > cutoff {
            guard let restored = restoreEntry(entry) else { continue }
            items.append(restored)
            if let hash = entry.imageHash {
                imageHashes[restored.id] = hash
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
            sourceApp: persisted.sourceApp
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
            imageHash: imageHashes[entry.id]
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
