//
//  QuickShareService.swift
//  boringNotch
//
//  Created by Alexander on 2025-09-24.
//  Hub send (hub D-178): the share surfaces' targets are the online hub devices.
//
//  Was the AirDrop / Quick Share provider list. Now the drop zone, the shelf item's Share
//  menu and Settings list the hub devices from the helper's `peer.list`, and sending goes
//  through the helper: files with `transfer.send {device, path}` (progress from
//  `transfer.sends`, HubSendCore.swift), text and links with `peer.call shelf.put`.
//
//  The helper runs in its own sandbox and reads only ~/.config/boringnotch/, so a file is
//  staged there first: an APFS clone (instant, no extra space) when it is on the same
//  volume, a copy after a free-space check when it is not, a zip for a folder. Staged files
//  go when their send is done (kept for Retry when it failed) and at launch.
//
//  "More…" is the old System Share Menu (NSSharingServicePicker), the last entry.
//

import AppKit
import Defaults
import Foundation

@MainActor
final class HubSendService: ObservableObject {
    static let shared = HubSendService()

    /// Every device from the last `peer.list` (Settings shows the file-taking ones).
    @Published private(set) var devices: [HubSendDevice] = []
    /// Online devices that take files, in `peer.list` order.
    @Published private(set) var targets: [HubSendDevice] = []
    /// Set when the device list couldn't be read: "The hub helper isn't running".
    @Published private(set) var problem: String?
    /// Running batches, and the last finished one (the drop zone shows the newest).
    @Published private(set) var batches: [HubSendBatch] = []
    @Published var isPickerOpen = false

    private var refreshTask: Task<Void, Never>?
    private var refreshUsers = 0
    private var runners: [UUID: HubSendRunner] = [:]
    private var sharingLifecycle: SharingLifecycleDelegate?
    private var sharingAccessingURLs: [URL] = []

    static let refreshInterval: Duration = .seconds(5)

    private init() {
        Self.sweepOutbox()
        Task { await refresh() }
    }

    // MARK: - Devices

    var defaultDevice: HubSendDevice? {
        HubSendTargets.defaultDevice(targets: targets, lastUsed: Defaults[.hubSendDevice])
    }

    func label(for device: HubSendDevice) -> String {
        HubSendTargets.label(for: device, among: devices)
    }

    /// Keeps the list fresh while someone shows it (the shelf, Settings). Balanced by `endRefreshing`.
    func beginRefreshing() {
        refreshUsers += 1
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: Self.refreshInterval)
            }
        }
    }

    func endRefreshing() {
        refreshUsers = max(0, refreshUsers - 1)
        if refreshUsers == 0 {
            refreshTask?.cancel()
            refreshTask = nil
        }
    }

    func refresh() async {
        do {
            let data = try await HubHelperClient.call("peer.list", timeout: 5)
            let all = HubSendTargets.parse(peerList: data)
            devices = all
            targets = HubSendTargets.targets(all)
            problem = nil
        } catch let failure as HubHelperClient.Failure {
            switch failure.kind {
            case .noHelper: problem = "This build has no hub helper"
            case .helperDown: problem = "The hub helper isn't running"
            case .rpc: problem = failure.message
            }
            targets = []
        } catch {
            problem = "The hub helper isn't answering"
            targets = []
        }
    }

    // MARK: - Progress for the views

    var latestBatch: HubSendBatch? { batches.last }

    /// The running entry for a shelf tile's ring.
    func runningEntry(forShelfItem id: UUID) -> HubSendEntry? {
        for batch in batches.reversed() {
            if let entry = batch.entries.first(where: { $0.shelfItemID == id && !$0.state.finished }) {
                return entry
            }
        }
        return nil
    }

    // MARK: - Sending

    /// One thing to send, as the shelf or a drop hands it over.
    enum Item {
        case file(URL, shelfItemID: UUID?)
        case text(String, shelfItemID: UUID?)
        case link(URL, shelfItemID: UUID?)
    }

    /// Sends to `device` (the default device when nil). Files are staged first.
    func send(_ items: [Item], to device: HubSendDevice? = nil) {
        guard let device = device ?? defaultDevice, !items.isEmpty else { return }
        Defaults[.hubSendDevice] = device.id
        let label = label(for: device)
        // A placeholder while files are staged, so the zone answers at once.
        var placeholder = HubSendBatch(deviceID: device.id, deviceLabel: label, entries: [])
        placeholder.entries = items.map { item in
            switch item {
            case .file(let url, let shelfID):
                return HubSendEntry(name: url.lastPathComponent, payload: .file(path: "", size: 0), shelfItemID: shelfID)
            case .text(let text, let shelfID):
                return HubSendEntry(name: "Text", payload: .text(text), shelfItemID: shelfID)
            case .link(let url, let shelfID):
                return HubSendEntry(name: url.absoluteString, payload: .link(url.absoluteString), shelfItemID: shelfID)
            }
        }
        upsert(placeholder)

        Task {
            var batch = placeholder
            for (i, item) in items.enumerated() {
                guard case .file(let url, _) = item else { continue }
                switch await Self.stage(url) {
                case .success(let staged):
                    batch.entries[i].name = staged.name
                    batch.entries[i].payload = .file(path: staged.path, size: staged.size)
                case .failure(let why):
                    batch.entries[i].state = .failed(why.message)
                }
            }
            upsert(batch)
            run(batch)
        }
    }

    func cancel(_ batchID: UUID) {
        guard let batch = batches.first(where: { $0.id == batchID }), let runner = runners[batchID] else { return }
        Task { await runner.cancel(batch) }
    }

    func retry(_ batchID: UUID) {
        guard let batch = batches.first(where: { $0.id == batchID }), batch.canRetry else { return }
        let again = batch.retryBatch()
        batches.removeAll { $0.id == batchID }
        upsert(again)
        run(again)
    }

    func dismiss(_ batchID: UUID) {
        guard let batch = batches.first(where: { $0.id == batchID }), batch.finished else { return }
        Self.removeStaged(batch.entries)
        batches.removeAll { $0.id == batchID }
    }

    private func run(_ batch: HubSendBatch) {
        let runner = HubSendRunner(call: Self.helperCall)
        runners[batch.id] = runner
        Task {
            let done = await runner.run(batch) { [weak self] updated in
                await MainActor.run { self?.upsert(updated) }
            }
            runners[batch.id] = nil
            upsert(done)
            Self.removeStaged(done.entries.filter { $0.state.finished && !Self.isFailed($0.state) })
            // Keep the running batches and this result; older results go.
            let keep = batches.filter { !$0.finished || $0.id == done.id }
            for old in batches where !keep.contains(where: { $0.id == old.id }) {
                Self.removeStaged(old.entries)
            }
            batches = keep
        }
    }

    private func upsert(_ batch: HubSendBatch) {
        if let i = batches.firstIndex(where: { $0.id == batch.id }) {
            batches[i] = batch
        } else {
            batches.append(batch)
        }
    }

    private static func isFailed(_ state: HubSendEntryState) -> Bool {
        if case .failed = state { return true }
        return false
    }

    /// The helper's /rpc, with its failures in HubSendCore's terms.
    nonisolated static let helperCall: HubSendCall = { op, args in
        do {
            return try await HubHelperClient.call(op, args: args, timeout: 15)
        } catch let failure as HubHelperClient.Failure {
            switch failure.kind {
            case .noHelper, .helperDown: throw HubSendCallError(kind: .helperDown, message: failure.message)
            case .rpc(let code): throw HubSendCallError(kind: .rpc(code), message: failure.message)
            }
        }
    }

    // MARK: - Shelf and drops

    /// The shelf's items as send items (files resolved through their bookmarks).
    func items(for shelfItems: [ShelfItem]) -> [Item] {
        shelfItems.compactMap { item in
            switch item.kind {
            case .file:
                guard let url = ShelfStateViewModel.shared.resolveAndUpdateBookmark(for: item) else { return nil }
                return .file(url, shelfItemID: item.id)
            case .text(let string):
                return .text(string, shelfItemID: item.id)
            case .link(let url):
                return .link(url, shelfItemID: item.id)
            }
        }
    }

    /// What a drop onto the zone carries: web links, text, or files (a shelf item's file
    /// resolved through its bookmark, so its tile gets the ring).
    func items(from providers: [NSItemProvider]) async -> [Item] {
        var result: [Item] = []
        let shelf = ShelfStateViewModel.shared.items
        for provider in providers {
            if let webURL = await provider.extractURL() {
                result.append(.link(webURL, shelfItemID: nil))
            } else if let text = await provider.extractText() {
                result.append(.text(text, shelfItemID: nil))
            } else if let fileURL = await provider.extractItem() {
                let path = fileURL.standardizedFileURL.path
                let match = shelf.first { item in
                    guard case .file = item.kind else { return false }
                    return ShelfStateViewModel.shared.resolveAndUpdateBookmark(for: item)?.standardizedFileURL.path == path
                }
                if let match, let resolved = ShelfStateViewModel.shared.resolveAndUpdateBookmark(for: match) {
                    result.append(.file(resolved, shelfItemID: match.id))
                } else {
                    result.append(.file(fileURL, shelfItemID: nil))
                }
            }
        }
        return result
    }

    /// Choose files in an open panel, then hand them to `then`.
    func chooseFiles(title: String, then: @escaping ([URL]) -> Void) {
        guard !isPickerOpen else { return }
        isPickerOpen = true
        SharingStateManager.shared.beginInteraction()
        defer {
            isPickerOpen = false
            SharingStateManager.shared.endInteraction()
        }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.title = title
        if panel.runModal() == .OK, !panel.urls.isEmpty {
            then(panel.urls)
        }
    }

    // MARK: - More… (the System Share Menu)

    func showSystemShareMenu(_ items: [Any], from view: NSView?) {
        guard !items.isEmpty else { return }
        let fileURLs = items.compactMap { $0 as? URL }.filter(\.isFileURL)
        stopSharingAccessingURLs()
        sharingAccessingURLs = fileURLs.filter { $0.startAccessingSecurityScopedResource() }

        let delegate = SharingStateManager.shared.makeDelegate { [weak self] in
            self?.sharingLifecycle = nil
            self?.stopSharingAccessingURLs()
        }
        sharingLifecycle = delegate
        // The guard is raised only once the picker is actually going on screen.
        guard let view else {
            delegate.abandon()
            sharingLifecycle = nil
            stopSharingAccessingURLs()
            return
        }
        let picker = NSSharingServicePicker(items: items)
        picker.delegate = delegate
        delegate.markPickerBegan()
        picker.show(relativeTo: .zero, of: view, preferredEdge: .minY)
    }

    /// Send items as the system share sheet wants them.
    static func shareObjects(_ items: [Item]) -> [Any] {
        items.map { item -> Any in
            switch item {
            case .file(let url, _): return url
            case .text(let text, _): return text
            case .link(let url, _): return url
            }
        }
    }

    private func stopSharingAccessingURLs() {
        for url in sharingAccessingURLs { url.stopAccessingSecurityScopedResource() }
        sharingAccessingURLs.removeAll()
    }

    // MARK: - Staging (where the helper can read)

    struct Staged: Sendable {
        let path: String
        let name: String
        let size: Int64
    }

    struct StageFailure: Error {
        let message: String
    }

    /// ~/.config/boringnotch/outbox (the real home, not the container): the helper's
    /// sandbox reads ~/.config/boringnotch/.
    nonisolated static var outboxURL: URL? {
        guard let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir else { return nil }
        return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
            .appendingPathComponent(".config/boringnotch/outbox", isDirectory: true)
    }

    /// Kept free on the volume when a file has to be copied rather than cloned.
    nonisolated static let freeSpaceMargin: Int64 = 1 << 30

    nonisolated static func stage(_ url: URL) async -> Result<Staged, StageFailure> {
        await Task.detached(priority: .userInitiated) { () -> Result<Staged, StageFailure> in
            guard let outbox = outboxURL else { return .failure(StageFailure(message: "no home folder")) }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let fm = FileManager.default
            let dir = outbox.appendingPathComponent(UUID().uuidString, isDirectory: true)
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            } catch {
                return .failure(StageFailure(message: "couldn't prepare the file (\(error.localizedDescription))"))
            }

            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
                try? fm.removeItem(at: dir)
                return .failure(StageFailure(message: "\(url.lastPathComponent) is gone"))
            }

            if isDir.boolValue {
                guard let zip = await TemporaryFileStorageService.shared.createZip(from: [url]) else {
                    try? fm.removeItem(at: dir)
                    return .failure(StageFailure(message: "couldn't zip \(url.lastPathComponent)"))
                }
                let dest = dir.appendingPathComponent(zip.lastPathComponent)
                do {
                    try fm.moveItem(at: zip, to: dest)
                    try? fm.removeItem(at: zip.deletingLastPathComponent())
                } catch {
                    try? fm.removeItem(at: dir)
                    return .failure(StageFailure(message: "couldn't prepare \(zip.lastPathComponent)"))
                }
                return .success(Staged(path: dest.path, name: dest.lastPathComponent, size: fileSize(dest)))
            }

            let dest = dir.appendingPathComponent(url.lastPathComponent)
            let size = fileSize(url)
            // clonefile: instant and free on the same APFS volume.
            if clonefile(url.path, dest.path, 0) != 0 {
                let free = (try? outbox.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                    .volumeAvailableCapacityForImportantUsage ?? 0
                if free > 0, size + freeSpaceMargin > free {
                    try? fm.removeItem(at: dir)
                    return .failure(StageFailure(message: "not enough free space on this Mac to prepare \(HubSendFormat.size(size))"))
                }
                do {
                    try fm.copyItem(at: url, to: dest)
                } catch {
                    try? fm.removeItem(at: dir)
                    return .failure(StageFailure(message: "couldn't read \(url.lastPathComponent)"))
                }
            }
            return .success(Staged(path: dest.path, name: dest.lastPathComponent, size: fileSize(dest)))
        }.value
    }

    nonisolated private static func fileSize(_ url: URL) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// Deletes the staging folders of these entries.
    nonisolated static func removeStaged(_ entries: [HubSendEntry]) {
        guard let outbox = outboxURL else { return }
        for entry in entries {
            guard case .file(let path, _) = entry.payload, !path.isEmpty else { continue }
            let folder = URL(fileURLWithPath: path).deletingLastPathComponent()
            guard folder.deletingLastPathComponent().standardizedFileURL.path == outbox.standardizedFileURL.path else { continue }
            try? FileManager.default.removeItem(at: folder)
        }
    }

    /// Leftovers from an earlier launch.
    nonisolated static func sweepOutbox() {
        guard let outbox = outboxURL else { return }
        try? FileManager.default.removeItem(at: outbox)
    }
}
