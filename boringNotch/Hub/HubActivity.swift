//
//  HubActivity.swift
//  boringNotch
//

import AppKit
import Defaults
import SwiftUI

/// What the hub peek shows: one thing arriving from another device, either still on its way
/// (a transfer with a progress line) or already on the shelf.
///
/// The peek itself is the notch's own sneak peek (`SneakContentType.hub`), the same mechanism
/// and the same slot under the island as the "now playing" peek, so an arrival looks like a
/// track change does. This model only holds the content; `BoringViewCoordinator` decides when
/// the peek is up.
///
/// Two ways in:
/// - `arrived(_:from:fromKind:)`: an item put on the shelf through the agent bridge
///   (`shelf.put`, which is how the hub helper delivers what another device sends).
/// - `handle(_:type:)`: the hub's `transfer` events (docs/TRANSFER.md in the hub repo), which
///   the helper hands to the notch with `events.push` while it receives a file in chunks:
///   started and progress show the line, completed turns it into the arrival, failed says so
///   (a cancel just hides it). DEBUG builds can also fake one with `previewTransfer`
///   (bridge op `debug.hub_peek`).
///
/// A finished transfer reaches the notch twice: the helper's commit forwards one `shelf.put`,
/// then pushes `transfer.completed` (whose `item` is that shelf item). The first one to arrive
/// turns the progress peek into the arrival; the second only fills in what is missing.
@MainActor
final class HubActivity: ObservableObject {
    static let shared = HubActivity()

    struct Item: Equatable {
        enum Phase: Equatable { case receiving, arrived, failed }

        /// The transfer id while a transfer is shown, else the shelf item's id.
        var id: String
        var name: String
        /// The sender's device name ("Tower", "Pixel 8"), when the caller said.
        var from: String?
        /// The sender's device kind (tower, mac, phone, server, windows), for its glyph.
        var fromKind: String?
        var phase: Phase
        var receivedBytes: Int64 = 0
        /// 0 when the size is unknown: the line then runs indeterminate.
        var size: Int64 = 0
        var isFile: Bool = true
        /// The receiver has had no chunk for a while (the helper says so after 30 s).
        var stalled: Bool = false
        /// The shelf item this became, once known.
        var shelfID: String?

        var fraction: Double? {
            guard size > 0 else { return nil }
            return min(1, max(0, Double(receivedBytes) / Double(size)))
        }
    }

    @Published private(set) var item: Item?
    /// File icon or Quick Look thumbnail of what arrived; nil shows the sender's glyph.
    @Published private(set) var icon: NSImage?

    /// How long a finished arrival stays up. Longer than the 1.5s HUD default: it is
    /// something to read (a name and a sender), not a level to glance at.
    static let arrivalDuration: TimeInterval = 4
    /// A transfer stays up while it reports. The helper reports at least every chunk (1 MiB)
    /// and says `stalled` after 30 s without one, so a little more than that before the peek
    /// gives up on a transfer that went quiet.
    static let receivingDuration: TimeInterval = 35
    /// How long "stalled" stays up; the next chunk brings the line back.
    static let stalledDuration: TimeInterval = 6
    /// "Didn't arrive" is brief: there is nothing to do about it from here.
    static let failureDuration: TimeInterval = 3

    private var lastKeepAlive: Date = .distantPast
    private var iconTask: Task<Void, Never>?
    /// Transfers that completed, failed or were cancelled lately: a late or reordered push
    /// for one of them must not bring its progress line back.
    private var finishedTransfers: [String] = []
    /// Shelf items that already had their arrival peek, so a transfer's `completed` after its
    /// `shelf.put` doesn't show a second one.
    private var announcedShelfIDs: [String] = []
    private static let memory = 32

    private init() {}

    private var enabled: Bool { Defaults[.showHubArrivals] }

    // MARK: - Arrivals (shelf.put)

    func arrived(_ shelfItem: ShelfItem, from: String?, fromKind: String?) {
        guard enabled else { return }
        let shelfID = shelfItem.id.uuidString
        Self.remember(shelfID, in: &announcedShelfIDs)
        var isFile = false
        if case .file = shelfItem.kind { isFile = true }

        // The shelf.put a finished transfer becomes: same peek, now as the arrival.
        if isFile, var current = item, current.phase == .receiving, !finishedTransfers.contains(current.id),
           current.name == shelfItem.displayName || (current.fraction ?? 0) >= 1 {
            current.phase = .arrived
            current.stalled = false
            current.shelfID = shelfID
            if current.size > 0 { current.receivedBytes = current.size }
            current.from = current.from ?? Self.clean(from)
            current.fromKind = current.fromKind ?? Self.clean(fromKind)?.lowercased()
            withAnimation(.smooth) { item = current }
            loadIcon(for: shelfItem)
            present(for: Self.arrivalDuration)
            return
        }

        item = Item(
            id: shelfID,
            name: shelfItem.displayName,
            from: Self.clean(from),
            fromKind: Self.clean(fromKind)?.lowercased(),
            phase: .arrived,
            isFile: isFile,
            shelfID: shelfID
        )
        loadIcon(for: shelfItem)
        present(for: Self.arrivalDuration)
    }

    // MARK: - Transfer events (events.push from the hub helper)

    /// One `transfer`-topic event. Unknown types are ignored, so a newer helper can add some.
    func handle(_ event: HubRPC.TransferEvent, type: String) {
        let from = event.fromName ?? (event.from.isEmpty ? nil : event.from)
        switch HubRPC.EventType(rawValue: type) {
        case .transferStarted:
            transferStarted(id: event.transferId, name: event.name, size: event.size,
                            receivedBytes: event.receivedBytes, from: from, fromKind: event.fromKind)
        case .transferProgress:
            transferProgress(id: event.transferId, receivedBytes: event.receivedBytes, size: event.size,
                             stalled: event.stalled ?? false, name: event.name, from: from, fromKind: event.fromKind)
        case .transferCompleted:
            transferCompleted(id: event.transferId, shelfID: event.item?.id, name: event.name,
                              size: event.size, from: from, fromKind: event.fromKind)
        case .transferFailed:
            transferFailed(id: event.transferId, cancelled: event.code == .cancelled)
        case nil:
            break
        }
    }

    func transferStarted(id: String, name: String, size: Int64, receivedBytes: Int64 = 0,
                         from: String?, fromKind: String? = nil) {
        // A begin for a finished id is a new transfer (the sender started over).
        finishedTransfers.removeAll { $0 == id }
        guard enabled else { return }
        if var current = item, current.id == id, current.phase == .receiving {
            // Resumed (or a repeated begin): keep the line where it was.
            current.name = name
            if size > 0 { current.size = size }
            current.receivedBytes = max(current.receivedBytes, receivedBytes)
            current.stalled = false
            withAnimation(.smooth) { item = current }
        } else {
            iconTask?.cancel()
            icon = nil
            item = Item(
                id: id, name: name, from: Self.clean(from), fromKind: Self.clean(fromKind)?.lowercased(),
                phase: .receiving, receivedBytes: max(0, receivedBytes), size: max(0, size)
            )
        }
        present(for: Self.receivingDuration)
    }

    func transferProgress(id: String, receivedBytes: Int64, size: Int64? = nil, stalled: Bool = false,
                          name: String? = nil, from: String? = nil, fromKind: String? = nil) {
        guard enabled, !finishedTransfers.contains(id) else { return }
        guard var current = item, current.id == id else {
            // Any event can start the line (the notch may have missed `started`), unless
            // another transfer is on show and still reporting.
            if let name, !isShowingOtherTransfer(than: id) {
                transferStarted(id: id, name: name, size: size ?? 0, receivedBytes: receivedBytes,
                                from: from, fromKind: fromKind)
                if stalled { transferProgress(id: id, receivedBytes: receivedBytes, stalled: true) }
            }
            return
        }
        guard current.phase == .receiving else { return }
        let wasStalled = current.stalled
        current.receivedBytes = max(current.receivedBytes, receivedBytes)
        if let size, size > 0 { current.size = size }
        current.stalled = stalled
        withAnimation(.linear(duration: 0.25)) { item = current }
        if stalled {
            if !wasStalled { present(for: Self.stalledDuration) }
        } else if wasStalled || Date().timeIntervalSince(lastKeepAlive) > 1 {
            // Re-arm the hide timer, but not on every chunk: each re-show is an animated state change.
            present(for: Self.receivingDuration)
        }
    }

    /// `shelfID` is the shelf item the transfer became (the event's `item.id`).
    func transferCompleted(id: String, shelfID: String? = nil, name: String? = nil, size: Int64 = 0,
                           from: String? = nil, fromKind: String? = nil) {
        Self.remember(id, in: &finishedTransfers)
        // Its shelf.put came first and already showed the arrival.
        if let shelfID, announcedShelfIDs.contains(shelfID) { return }
        guard enabled else { return }
        let shelfItem = shelfID.flatMap { raw in
            ShelfStateViewModel.shared.items.first { $0.id.uuidString == raw }
        }
        if let shelfID { Self.remember(shelfID, in: &announcedShelfIDs) }
        var current: Item
        if let shown = item, shown.id == id {
            current = shown
        } else if let name {
            current = Item(id: id, name: name, from: Self.clean(from), fromKind: Self.clean(fromKind)?.lowercased(),
                           phase: .receiving, size: max(0, size))
            iconTask?.cancel()
            icon = nil
        } else {
            return
        }
        guard current.phase != .arrived else { return }
        current.phase = .arrived
        current.stalled = false
        current.shelfID = shelfID
        if current.size > 0 { current.receivedBytes = current.size }
        withAnimation(.smooth) { item = current }
        if let shelfItem { loadIcon(for: shelfItem) }
        present(for: Self.arrivalDuration)
    }

    /// A cancel only takes the line away; anything else says it didn't arrive, briefly.
    func transferFailed(id: String, cancelled: Bool = false) {
        Self.remember(id, in: &finishedTransfers)
        guard var current = item, current.id == id, current.phase == .receiving else { return }
        if cancelled || !enabled {
            hide()
            return
        }
        current.phase = .failed
        current.stalled = false
        withAnimation(.smooth) { item = current }
        present(for: Self.failureDuration)
    }

    // MARK: - Presentation

    private func present(for duration: TimeInterval) {
        lastKeepAlive = Date()
        BoringViewCoordinator.shared.toggleSneakPeek(status: true, type: .hub, duration: duration)
    }

    /// Takes the peek down if it is ours (never another peek that replaced it).
    private func hide() {
        let coordinator = BoringViewCoordinator.shared
        if coordinator.sneakPeek.show && coordinator.sneakPeek.type == .hub {
            coordinator.toggleSneakPeek(status: false, type: .hub)
        }
    }

    private func isShowingOtherTransfer(than id: String) -> Bool {
        guard let current = item, current.id != id, current.phase == .receiving else { return false }
        let coordinator = BoringViewCoordinator.shared
        return coordinator.sneakPeek.show && coordinator.sneakPeek.type == .hub
            && Date().timeIntervalSince(lastKeepAlive) < Self.receivingDuration
    }

    private static func remember(_ id: String, in list: inout [String]) {
        list.removeAll { $0 == id }
        list.append(id)
        if list.count > memory { list.removeFirst(list.count - memory) }
    }

    private func loadIcon(for shelfItem: ShelfItem) {
        iconTask?.cancel()
        icon = nil
        guard case .file = shelfItem.kind,
              let url = ShelfStateViewModel.shared.resolveFileURL(for: shelfItem)
        else { return }
        icon = NSWorkspace.shared.icon(forFile: url.path)
        let id = shelfItem.id.uuidString
        iconTask = Task { [weak self] in
            let side = CGSize(width: 64, height: 64)
            guard let thumb = await ThumbnailService.shared.thumbnail(for: url, size: side),
                  !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.item?.id == id else { return }
                self.icon = thumb
            }
        }
    }

    private static func clean(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    // MARK: - Preview (DEBUG)

    #if DEBUG
    private var previewTask: Task<Void, Never>?

    /// Drives the transfer UI with fake progress: `seconds` from 0 to `size`, in uneven steps
    /// like a real link, then completes (or fails at 60% when `fail`).
    func previewTransfer(name: String, size: Int64, seconds: Double, from: String?, fromKind: String?, fail: Bool) {
        previewTask?.cancel()
        let id = "preview-" + UUID().uuidString
        transferStarted(id: id, name: name, size: size, from: from, fromKind: fromKind)
        previewTask = Task { [weak self] in
            let steps = max(4, Int(seconds * 8))
            var received: Int64 = 0
            for step in 1...steps {
                try? await Task.sleep(for: .seconds(seconds / Double(steps)))
                guard !Task.isCancelled, let self else { return }
                // Uneven chunks: a real transfer stalls and bursts.
                let target = Int64(Double(size) * Double(step) / Double(steps))
                let jitter = Int64(Double(size) * 0.02 * Double.random(in: -1...1))
                received = min(size, max(received, target + jitter))
                if fail && Double(received) >= Double(size) * 0.6 {
                    self.transferFailed(id: id)
                    return
                }
                self.transferProgress(id: id, receivedBytes: received)
            }
            guard !Task.isCancelled, let self else { return }
            self.transferProgress(id: id, receivedBytes: size)
            try? await Task.sleep(for: .milliseconds(300))
            self.transferCompleted(id: id)
        }
    }
    #endif
}
