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
/// - `transferStarted / Progress / Completed / Failed`: a chunked transfer that reports as it
///   goes. Nothing calls these yet; they wait for the hub's transfer events (docs/TRANSFER.md
///   in the hub repo). DEBUG builds drive them with `previewTransfer` (bridge op
///   `debug.hub_peek`).
@MainActor
final class HubActivity: ObservableObject {
    static let shared = HubActivity()

    struct Item: Equatable {
        enum Phase: Equatable { case receiving, arrived, failed }

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
    /// A transfer stays up while it reports; this long without a report and the peek goes.
    static let stallDuration: TimeInterval = 8

    private var lastKeepAlive: Date = .distantPast
    private var iconTask: Task<Void, Never>?

    private init() {}

    private var enabled: Bool { Defaults[.showHubArrivals] }

    // MARK: - Arrivals (shelf.put)

    func arrived(_ shelfItem: ShelfItem, from: String?, fromKind: String?) {
        guard enabled else { return }
        var isFile = false
        if case .file = shelfItem.kind { isFile = true }
        item = Item(
            id: shelfItem.id.uuidString,
            name: shelfItem.displayName,
            from: Self.clean(from),
            fromKind: Self.clean(fromKind)?.lowercased(),
            phase: .arrived,
            isFile: isFile
        )
        loadIcon(for: shelfItem)
        present(for: Self.arrivalDuration)
    }

    // MARK: - Transfers (hub transfer events, not wired yet)

    func transferStarted(id: String, name: String, size: Int64, from: String?, fromKind: String? = nil) {
        guard enabled else { return }
        iconTask?.cancel()
        icon = nil
        item = Item(
            id: id, name: name, from: Self.clean(from), fromKind: Self.clean(fromKind)?.lowercased(),
            phase: .receiving, receivedBytes: 0, size: max(0, size)
        )
        present(for: Self.stallDuration)
    }

    func transferProgress(id: String, receivedBytes: Int64, size: Int64? = nil) {
        guard var current = item, current.id == id, current.phase == .receiving else { return }
        current.receivedBytes = max(current.receivedBytes, receivedBytes)
        if let size, size > 0 { current.size = size }
        withAnimation(.linear(duration: 0.25)) { item = current }
        // Re-arm the hide timer, but not on every chunk: each re-show is an animated state change.
        if Date().timeIntervalSince(lastKeepAlive) > 1 {
            present(for: Self.stallDuration)
        }
    }

    /// `shelfItem` is what the transfer became on the shelf, for its thumbnail.
    func transferCompleted(id: String, shelfItem: ShelfItem? = nil) {
        guard var current = item, current.id == id else { return }
        current.phase = .arrived
        if current.size > 0 { current.receivedBytes = current.size }
        withAnimation(.smooth) { item = current }
        if let shelfItem { loadIcon(for: shelfItem) }
        present(for: Self.arrivalDuration)
    }

    func transferFailed(id: String) {
        guard var current = item, current.id == id else { return }
        current.phase = .failed
        withAnimation(.smooth) { item = current }
        present(for: Self.arrivalDuration)
    }

    // MARK: - Presentation

    private func present(for duration: TimeInterval) {
        lastKeepAlive = Date()
        BoringViewCoordinator.shared.toggleSneakPeek(status: true, type: .hub, duration: duration)
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
