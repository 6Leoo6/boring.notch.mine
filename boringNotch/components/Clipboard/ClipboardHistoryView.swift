//
//  ClipboardHistoryView.swift
//  boringNotch
//

import AppKit
import Defaults
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Relative time helper

private let monthDayFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "MMM d"
    return f
}()

private func relativeTime(from date: Date, now: Date = Date()) -> String {
    let secs = max(0, Int(now.timeIntervalSince(date)))
    switch secs {
    case ..<60:     return "now"
    case ..<3600:   return "\(secs / 60)m"
    case ..<86400:  return "\(secs / 3600)h"
    case ..<604800: return "\(secs / 86400)d"
    default:        return monthDayFormatter.string(from: date)
    }
}

// MARK: - File icon

// Shared by the history tiles and the preview panel; scoped to the Clipboard component.
enum ClipboardFileIcon {
    static func image(for url: URL) -> NSImage {
        if url.isFileURL {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSImage(systemSymbolName: "globe", accessibilityDescription: nil) ?? NSImage()
    }
}

// MARK: - Delete confirmation

/// The one delete flow for clipboard entries, shared by the history tile and the expanded
/// preview.
///
/// The alert is an `_NSAlertPanel` ATTACHED TO THE NOTCH WINDOW AS A SHEET — not a free
/// window of its own, which is what an earlier version of this comment claimed. The
/// distinction matters: a sheet's attachment is what repositions its parent window (#34, fixed
/// window-side with `window(_:willPositionSheet:using:)`), so do not reason about this alert
/// as if it were independent of the island. What it does have in common with a separate window
/// is that the notch loses hover the instant it appears — hence the close guard while it is up
/// and the grace period once it goes.
struct ClipboardDeleteConfirmation: ViewModifier {
    @Binding var isPresented: Bool
    let onDelete: () -> Void
    @EnvironmentObject private var vm: BoringViewModel

    func body(content: Content) -> some View {
        content
            .alert("Delete item?", isPresented: $isPresented) {
                Button("Delete", role: .destructive) { onDelete() }
                Button("Delete, don't ask again", role: .destructive) {
                    Defaults[.clipboardDeleteConfirmEnabled] = false
                    onDelete()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This item will be removed from your clipboard history.")
            }
            .onChange(of: isPresented) { _, presented in
                vm.isModalDialogActive = presented
                if !presented { vm.beginCloseGrace() }
            }
            // A tile that vanishes mid-dialog must not strand the island open forever
            .onDisappear {
                if isPresented { vm.isModalDialogActive = false }
            }
    }
}

extension View {
    func clipboardDeleteConfirmation(
        isPresented: Binding<Bool>,
        onDelete: @escaping () -> Void
    ) -> some View {
        modifier(ClipboardDeleteConfirmation(isPresented: isPresented, onDelete: onDelete))
    }
}

/// Sends a delete through the confirmation alert, or straight through when the user has
/// turned confirmations off.
@MainActor
func requestClipboardDelete(confirm: Binding<Bool>, onDelete: () -> Void) {
    if Defaults[.clipboardDeleteConfirmEnabled] {
        confirm.wrappedValue = true
    } else {
        onDelete()
    }
}

/// The one owner of clipboard hover state: which tile the pointer is in, and whether its
/// action icons have been revealed yet.
///
/// Two things are deliberate here.
///
/// One stored id, so two tiles lit at once is structurally impossible rather than dependent
/// on every code path being right.
///
/// The state lives HERE and not in the tiles, because a tile's `@State` does not survive the
/// list diff that a copy, delete or reorder produces — the hovered tile's view can be rebuilt
/// between the pointer arriving and the reveal firing, which silently dropped the reveal.
///
/// What decides ownership is `onHover` alone. It follows the drawn presentation, which a
/// `GeometryProxy.frame(in: .global)` read does not: during an animated re-layout the read
/// already reports the FINAL frame while the tile is still drawn at its old position. Testing
/// the cursor against that read is what handed hover to the neighbour toward the start of the
/// row every time the strip re-laid out.

#if BN_DIAG
/// #53 layer bisection. Inert unless `BN_BISECT=<n>` is set, exactly like the hover
/// instrumentation, and removed with it.
///
/// Each level strips one more layer between the tile and the window, cumulatively, so that a
/// single binary can be measured at every level without a rebuild. Level 0 is the unmodified
/// app and is the control: if it does not reproduce the displacement, the run is measuring
/// nothing and nothing below it can be trusted.
///
/// `describe()` is deliberately loud about which layers a level ACTUALLY removes and which it
/// does not. A level that silently failed to remove what it claims would point the search at
/// the wrong layer, which is worse than not running it.
enum ClipboardBisect {
    /// `BN_BISECT=<n>` strips layers 1...n cumulatively. `BN_BISECT=4a` strips 1...3 plus only
    /// ONE part of layer 4, because layer 4 bundles three unrelated things and a bundled result
    /// would not say which of them mattered. Numbering for 0-8 is unchanged, so a sweep already
    /// run against a plain integer stays comparable.
    private static let raw = ProcessInfo.processInfo.environment["BN_BISECT"] ?? "0"
    static let level: Int = Int(raw.prefix(while: \.isNumber)) ?? 0
    private static let variant: Character? = raw.last.flatMap {
        $0.isLetter ? Character($0.lowercased()) : nil
    }

    /// `BN_BISECT=p` (or `0p`) swaps every clipboard tile for a blank placeholder: a fixed
    /// `tileSize` square that changes colour on hover, and nothing else — no Button, no
    /// `.onDrag`, no overlays, no content branches, no badges.
    ///
    /// It answers one question: does a bare square also get a hover region wider than its own
    /// frame? If it does, the fault is in how a tile is framed at its root and is independent
    /// of everything the real tile carries. If it does not, something in the real tile's
    /// modifier chain inflates it, and that chain can be bisected the same way the layout was.
    static var placeholderTile: Bool { variant == "p" }

    /// `BN_TILE=<n>` — a SECOND, independent ladder that strips the real tile's own modifier
    /// chain, cumulatively. Separate from `BN_BISECT` so the two compose and neither has to be
    /// renumbered when the other grows.
    ///   1  .onDrag
    ///   2  + both .overlay blocks (action row, "Click to copy" capsule)
    ///   3  + the Button / .buttonStyle(.plain) wrapper
    ///   4  + .contextMenu
    /// Nothing here touches the tile's frame or `tileSize`: the placeholder proved the
    /// environment and the framing are innocent, so the only variable per level is the one
    /// modifier named.
    static let tileLevel: Int = Int(ProcessInfo.processInfo.environment["BN_TILE"] ?? "") ?? 0

    static func removesTile(_ layer: Int) -> Bool { tileLevel >= layer }

    /// `BN_PAD=<n>` adds n inert `.onHover` regions to EVERY tile, changing nothing about its
    /// framing, drawing or behaviour.
    ///
    /// This is the falsifiable test of the budget reading. If a fixed resource is consumed per
    /// tile and per hover region, then ADDING regions must consume it faster and REDUCE the
    /// number of tiles served — the mirror image of removing modifiers increasing it. Nothing
    /// else we have considered predicts that adding an inert modifier makes the fault appear
    /// EARLIER. If the correct-tile count does not fall, the budget is not measured in hover
    /// regions and probably is not a budget.
    static let padCount: Int = Int(ProcessInfo.processInfo.environment["BN_PAD"] ?? "") ?? 0

    private static let tileLayers: [Int: String] = [
        1: ".onDrag",
        2: "both .overlay blocks",
        3: "Button / .buttonStyle(.plain) wrapper",
        4: ".contextMenu",
    ]

    /// True when `layer` and everything inside it should be stripped.
    static func removes(_ layer: Int) -> Bool { level >= layer }

    /// True when only ONE tile should be rendered. `BN_BISECT=0s` is the sharp form: the
    /// UNMODIFIED app with a single tile. If one tile alone hover-tests correctly while the
    /// same app with siblings does not, the fault needs a sibling and is positional rather
    /// than intrinsic to the tile. Also implied by level 10.
    static var singleTile: Bool { variant == "s" || level >= 10 }

    /// Layer 4's parts: `a` tap gestures, `b` contentShape, `c` onDrop. All three at plain
    /// level 4 or above; exactly one when a variant letter is given.
    static func removes4(_ part: Character) -> Bool {
        if level > 4 { return true }
        if level == 4 { return variant == nil || variant == part }
        return false
    }

    private static let layers: [Int: (String, Bool)] = [
        1: ("ScrollView inside ShelfItemStrip", true),
        2: ("PanelBorder / panel toggle / grid expander", true),
        3: ("FileShareView drop zone", true),
        4: ("panel 4a tap gestures / 4b contentShape / 4c onDrop", true),
        5: ("ShelfView panel padding & height frame", true),
        6: ("ContentView .compositingGroup()", true),
        7: ("ContentView .scaleEffect", true),
        8: ("ContentView background / clipShape", true),
        9: ("HStack / LazyVGrid child positioning (explicit Layout instead)", true),
        10: ("all but one tile", true),
    ]

    /// Logged once so a sweep can never be attributed to a level that did not run.
    /// Idempotent via Swift's lazy static initialisation.
    static func announce() { _ = announced }

    /// Announced even when only the tile ladder is in use.
    static var anyLevelSet: Bool {
        level > 0 || tileLevel > 0 || placeholderTile || singleTile || padCount > 0
    }

    private static let announced: Bool = {
        guard anyLevelSet else { return true }
        let applied = layers.keys.sorted().filter { $0 <= level && layers[$0]!.1 }
            .map { "\($0) \(layers[$0]!.0)" }
        let missing = layers.keys.sorted().filter { $0 <= level && !layers[$0]!.1 }
            .map { "\($0) \(layers[$0]!.0)" }
        NSLog("[BN_BISECT] level %@", raw)
        if level == 4, let v = variant { NSLog("[BN_BISECT] layer 4: ONLY part %@", String(v)) }
        if singleTile { NSLog("[BN_BISECT] single tile only") }
        if placeholderTile { NSLog("[BN_BISECT] PLACEHOLDER tiles (blank square + hover colour)") }
        if padCount > 0 { NSLog("[BN_PAD] +%d inert .onHover regions per tile", padCount) }
        if tileLevel > 0 {
            let removed = tileLayers.keys.sorted().filter { $0 <= tileLevel }
                .map { "\($0) \(tileLayers[$0]!)" }
            NSLog("[BN_TILE] level %d REMOVED: %@", tileLevel, removed.joined(separator: " | "))
        }
        NSLog("[BN_BISECT] REMOVED: %@", applied.isEmpty ? "nothing" : applied.joined(separator: " | "))
        if !missing.isEmpty {
            NSLog("[BN_BISECT] NOT IMPLEMENTED, still present: %@", missing.joined(separator: " | "))
            NSLog("[BN_BISECT] this level is INCOMPLETE — do not read a result from it")
        }
        return true
    }()
}
#endif

/// True while the pointer is inside one of the notch windows. Deliberately coarse: it asks
/// AppKit about real window frames, never about SwiftUI layout, so it stays correct while the
/// island animates. Picking the window by which one contains the cursor keeps it right with
/// `showOnAllDisplays`.
@MainActor
func cursorIsOverNotchWindow() -> Bool {
    let screenPoint = NSEvent.mouseLocation
    return NSApp.windows.contains {
        $0 is BoringNotchSkyLightWindow && $0.frame.contains(screenPoint)
    }
}

/// Diagnostics channel for #53, and nothing else.
///
/// This used to be the single arbiter of clipboard hover: one `ownerID` for the whole strip,
/// a shared reveal flag behind a 220ms task, a 200ms watchdog poll, enter/exit guards to
/// survive out-of-order events, and a cursor push/pop stack balanced across tiles. All of it
/// is gone. Hover now lives on the tile that the cursor is actually over — see
/// `ClipboardEntryTile` — which is both simpler and, measured, correct across the list diff
/// the singleton was built to survive.
///
/// What remains is only the `BN_HOVER_DEBUG` instrumentation, which is inert unless that
/// variable is set and comes out with the rest of the #53 diagnostics.
@MainActor
final class ClipboardHoverOwner: ObservableObject {
    static let shared = ClipboardHoverOwner()

    @Published private(set) var ownerID: UUID?
    /// False for the reveal delay after entering, so brushing across the row does not flash
    /// icons on every tile it crosses.
    @Published private(set) var actionsVisible = false

    private var revealTask: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var cursorPushed = false

    private let revealDelay: Duration = .milliseconds(220)

#if BN_DIAG
    /// Diagnostic for #53. Inert unless `BN_HOVER_DEBUG` is set in the environment, so it
    /// costs one already-evaluated `static let` per hand-off in a normal run and changes no
    /// behaviour at all.
    ///
    /// Records the cursor's x IN WINDOW COORDINATES at the moment a tile takes hover. That is
    /// the hit-region boundary, measured with no layout read anywhere — deliberately, because
    /// `frame(in: .global)` is the oracle that caused #33 and cannot be trusted here. Pair the
    /// logged hand-off positions with a single screenshot of the strip: the drawn tile edges
    /// come from the screenshot, the hit-region edges come from this, and the difference is
    /// the displacement in points. It is the harness's own method applied to the real app,
    /// which is the one place I cannot otherwise measure.
    private static let handoffLogging = ProcessInfo.processInfo.environment["BN_HOVER_DEBUG"] != nil

    /// Deliberately NOT `print`. The running app's stdout and stderr are both `/dev/null`
    /// (verified with `lsof` against the live process), so a `print` here reaches nobody and
    /// an empty log would read as "hover never fired" — a false negative that would waste the
    /// measurement. `NSLog` reaches the unified log whatever the launch method, and the file
    /// copy is there so the result survives log filtering and is trivial to diff.
    private static let handoffLog: URL? = {
        guard handoffLogging else { return nil }
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("bn-hover.log")
        if let url {
            // APPENDS, with a session marker. The first version truncated on launch, which
            // silently destroyed a completed sweep the moment the app was relaunched for the
            // next one — the only reason it was noticed is that two reads of "the log" turned
            // out to be different datasets. Sessions are separated by the marker instead.
            if !FileManager.default.fileExists(atPath: url.path) {
                try? Data().write(to: url)
            }
            let marker = "=== BN_HOVER session start \(Date()) ===\n"
            if let handle = try? FileHandle(forWritingTo: url), let data = marker.data(using: .utf8) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            }
            NSLog("[BN_HOVER] appending hand-offs to %@", url.path)
        }
        return url
    }()

    private static var lastSlot = -1
    private static var lastX = Double.nan

    /// True only under `BN_HOVER_DEBUG`, so the tiles can skip the geometry probe entirely
    /// in a normal run.
    static var handoffLoggingEnabled: Bool { handoffLogging }

    /// Where each tile is DRAWN, recorded by the tiles themselves.
    ///
    /// This exists because comparing a hover sweep against a screenshot taken at a different
    /// moment compares two different layouts, and the residuals in the first real-app run —
    /// hit pitches of 104 and 108 against a uniform drawn pitch of 101, which no layout can
    /// produce — look exactly like that. Logging both from the SAME instant removes the
    /// cross-time risk completely.
    ///
    /// `frame(in: .global)` is the oracle #33 forbids DURING an animated re-layout. It is
    /// read here only at hand-off, and only its x extent is used; a hand-off happens under a
    /// settled strip, which is the case #33's own data found reliable (17/17 settled samples
    /// agreed). It is a diagnostic, never a decision input — nothing in the app's behaviour
    /// reads it.
    private static var drawnFrames: [UUID: CGRect] = [:]

    static func recordDrawnFrame(_ id: UUID, _ rect: CGRect) {
        guard handoffLogging else { return }
        drawnFrames[id] = rect
    }

    /// Read back, so a harness can check this reported frame against the tile's DRAWN pixels
    /// and establish what `frame(in: .global)` actually reports under an ancestor transform.
    static func drawnFrame(_ id: UUID) -> CGRect? { drawnFrames[id] }

    /// Set by `ContentView` under `BN_HOVER_DEBUG` so the island's root transform appears on
    /// the same line as a hand-off. Measured, not assumed: `frame(in: .global)` DOES include an
    /// ancestor `.scaleEffect` (harness, ancestor scale 1.2: reported frames 114pt wide against
    /// a 95pt tile, matching the drawn pixels to 0.3pt), so the reported frame is the real
    /// on-screen position and its agreement with a screenshot says nothing about the scale
    /// either way. The only way to know the scale is to print it.
    static var islandDiagnostics = "-"

    static func forgetDrawnFrame(_ id: UUID) {
        guard handoffLogging else { return }
        drawnFrames[id] = nil
    }

    /// Logs EVERY hover edge, in or out, from the tile itself — before any of the owner's
    /// guards.
    ///
    /// Diagnostic only: the last tile to report hover-in that has not since reported
    /// hover-out. Nothing in the app reads it — hover decisions belong to the tiles now, and
    /// reintroducing a shared "who is hovered" that views consult would rebuild the singleton
    /// this change removed. It exists so a harness, and the log, can observe the outcome.
    private(set) static var lastHoveredID: UUID?

    /// Every hover edge, in and out, logged from the tile before it updates any state.
    static func logHoverEdge(_ id: UUID, _ hovering: Bool) {
        guard handoffLogging else { return }
        let screen = NSEvent.mouseLocation
        let window = NSApp.windows.first {
            $0 is BoringNotchSkyLightWindow && $0.frame.contains(screen)
        }
        let x = window.map { Double($0.convertPoint(fromScreen: screen).x) } ?? .nan
        let slot = ClipboardManager.shared.visibleItems.firstIndex { $0.id == id } ?? -1
        let f = drawnFrames[id]
        let lo = f.map { Double($0.minX) } ?? .nan
        let hi = f.map { Double($0.maxX) } ?? .nan
        let inside = f.map { Double($0.minX) <= x && x < Double($0.maxX) } ?? false

        // THREE independent readings of "where is the pointer", because `NSEvent.mouseLocation`
        // is not the right one and may have been lying to us all along.
        //
        // It returns the cursor's position *now*, when this closure runs — not the position of
        // the event that caused the hover change. A driver posting `.mouseMoved` faster than
        // the window server consumes them makes those two diverge, and the divergence is
        // (queue lag) x (sweep speed), which at 1pt/30ms is tens of points. That would
        // reproduce every anomaly in the data — a ~40pt offset, in this direction, with
        // non-constant spacings as the lag drifts, and none of it visible to a harness that
        // measures against the position it commanded rather than one it reads back.
        //
        //   evX     - `NSApp.currentEvent.locationInWindow`, the event actually being
        //             processed. This is the ground truth for what triggered the dispatch.
        //   streamX - `window.mouseLocationOutsideOfEventStream`, AppKit's own cached position.
        if hovering { lastHoveredID = id } else if lastHoveredID == id { lastHoveredID = nil }
        let ev = NSApp.currentEvent
        let evX: Double = (ev?.window === window && ev != nil) ? Double(ev!.locationInWindow.x) : .nan
        let streamX: Double = window.map { Double($0.mouseLocationOutsideOfEventStream.x) } ?? .nan
        emit(String(
            format: "[BN_EDGE] slot %2d %@  x %8.2f  evX %8.2f  streamX %8.2f  drawn %8.2f..%8.2f  cursorInsideDrawn %@  evType %@",
            slot, hovering ? "IN " : "OUT", x, evX, streamX, lo, hi,
            inside ? "YES" : "NO ",
            ev.map { String(describing: $0.type) } ?? "none"
        ))
    }

#endif
    func enter(_ id: UUID) {
        guard ownerID != id else { return }
        ownerID = id
        actionsVisible = false
        pushCursor(true)
        revealTask?.cancel()
        revealTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: self?.revealDelay ?? .milliseconds(220))
            guard !Task.isCancelled, let self, self.ownerID == id else { return }
            self.actionsVisible = true
        }
        startWatchdog()
    }

    /// Ignored unless `id` still holds hover: SwiftUI can deliver the new tile's enter before
    /// the old tile's exit, and the late exit must not cancel the new owner.
    func exit(_ id: UUID) {
        guard ownerID == id else { return }
        clear()
    }

    private func clear() {
        revealTask?.cancel()
        revealTask = nil
        watchdog?.cancel()
        watchdog = nil
        pushCursor(false)
        if ownerID != nil { ownerID = nil }
        if actionsVisible { actionsVisible = false }
    }

    /// The island is a non-activating panel and its tiles can be torn down mid-hover, so an
    /// exit event is not guaranteed. Only the window-level test is safe to run here — the
    /// cursor may sit still inside the same tile for minutes, and any per-tile geometry check
    /// would need the layout reads that caused the bug. Runs only while a tile is lit.
    private func startWatchdog() {
        watchdog?.cancel()
        watchdog = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled, let self, self.ownerID != nil else { return }
                guard !cursorIsOverNotchWindow() else { continue }
                self.clear()
                return
            }
        }
    }

    /// A pointing hand says "this whole surface is the button" without drawing anything. Kept
    /// with the owner so the push/pop stack cannot go out of balance when a tile view is
    /// rebuilt while it is hovered.
    private func pushCursor(_ push: Bool) {
        if push, !cursorPushed {
            NSCursor.pointingHand.push()
            cursorPushed = true
        } else if !push, cursorPushed {
            NSCursor.pop()
            cursorPushed = false
        }
    }

#if BN_DIAG
    private static func emit(_ line: String) {
        NSLog("%@", line)
        if let url = handoffLog, let data = (line + "\n").data(using: .utf8),
           let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }

#endif
}

// MARK: - Drag-out file backing

/// PNG files backing image drags, one per entry, written ahead of time.
///
/// An image drag has to put a real FILE on the pasteboard: raw image data lands in apps that
/// accept images, but Finder turns it into a picture clipping rather than a file. The app's
/// own history store is not usable for this — a Finder drop of a file URL can MOVE the file,
/// which would take the history entry's image with it — so a drag gets a throwaway copy in
/// the temp directory instead.
///
/// Prepared on hover rather than at drag time because `onDrag` must return its provider
/// synchronously, and PNG-encoding a screenshot on the main thread there is a visible stall.
@MainActor
final class ClipboardDragFileStore {
    static let shared = ClipboardDragFileStore()

    private var files: [UUID: URL] = [:]
    private var inFlight: Set<UUID> = []

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return f
    }()

    func url(for id: UUID) -> URL? { files[id] }

    func prepare(_ entry: ClipboardEntry) {
        guard case .image(let image) = entry.content,
              files[entry.id] == nil,
              !inFlight.contains(entry.id),
              let tiff = image.tiffRepresentation
        else { return }

        inFlight.insert(entry.id)
        let name = "Clipboard \(Self.stampFormatter.string(from: entry.timestamp)).png"
        let id = entry.id
        Task {
            // Only `Data` crosses the boundary, so the NSImage stays on the main actor
            let png = await Task.detached(priority: .utility) {
                NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
            }.value
            defer { inFlight.remove(id) }
            guard let png,
                  let url = await TemporaryFileStorageService.shared.createTempFile(
                      for: .data(png, suggestedName: name)
                  )
            else { return }
            files[id] = url
        }
    }

    func discard(_ id: UUID) {
        guard let url = files.removeValue(forKey: id) else { return }
        TemporaryFileStorageService.shared.removeTemporaryFileIfNeeded(at: url)
    }
}

// MARK: - History view

struct ClipboardHistoryView: View {
    @ObservedObject var manager = ClipboardManager.shared
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    let rows: Int
    let pinnedTileSide: CGFloat

    /// The pinned collection is a FILTER over the same list, not a second store — see
    /// `ClipboardManager.pinnedItems` for why the entry stays in the history when pinned.
    private var displayed: [ClipboardEntry] {
        let items = manager.visibleItems
#if BN_DIAG
        return ClipboardBisect.singleTile ? Array(items.prefix(1)) : items
#else
        return items
#endif
    }

    var body: some View {
        Group {
            // Nothing captured at all. Pins are a subset of the history, so there is nothing
            // to switch to either and the whole-panel empty state is the honest answer.
            if manager.items.isEmpty {
                emptyState
            } else {
                TimelineView(.everyMinute) { context in
                    itemsRow(now: context.date, rows: rows)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        NotchEmptyState(icon: "clipboard", message: "Nothing copied yet")
    }

    /// Only reachable by unpinning the last pinned entry while looking at the collection —
    /// the pin button will not open an empty page. The control column stays alongside it, so
    /// this is never a dead end.
    private var pinnedEmptyState: some View {
        NotchEmptyState(icon: "pin", message: "No pinned items")
    }

    // MARK: - Items row

    private func itemsRow(now: Date, rows: Int) -> some View {
        // Top-aligned so the control column stays beside the first row as the grid grows
        // downwards
        HStack(alignment: .top, spacing: ShelfItemMetrics.spacing) {
            // The strip and the empty state share this slot. It is given the full frame so
            // the `_ConditionalContent` swap cannot collapse the slot mid-crossfade, which is
            // what shifted the layout on the panel switch in #4.
            Group {
                if displayed.isEmpty {
                    pinnedEmptyState
                } else {
                    ShelfItemStrip(rows: rows, pinnedTileSide: pinnedTileSide, scrollTargetID: displayed.first?.id) { tileSize in
                        ForEach(displayed) { entry in
                            tile(for: entry, tileSize: tileSize, now: now)
                        }
                    }
                    // Keyed on what is on SCREEN, not on the whole history: an insert or a
                    // delete WITHIN a page is a diff of this list, so the entries either side
                    // of it stay put and only the difference animates.
                    .animation(.smooth(duration: 0.25), value: displayed.map(\.id))
                    // A page switch is a REPLACEMENT of the contents, not a reorder of them,
                    // and giving it its own identity is what stops it being treated as one.
                    //
                    // Without this, the two pages share entry identities, so every pinned
                    // entry FLIES from its history position to its pinned position. Measured
                    // in drawn pixels: a pin sitting at history position 6 travelled 500.0pt
                    // in ~370ms, peaking at 117pt between consecutive frames (~3500pt/s),
                    // with an 8pt wobble at the end from the page switch and the line above
                    // both driving the same change. That is the "too aggressive" slide.
                    //
                    // With it, the page flip is one transaction owned by `togglePage()`: the
                    // old page fades out, the new one fades in where it belongs, and nothing
                    // travels. The value-keyed animation above keeps its job unchanged, since
                    // a fresh page starts with no previous value to diff against.
                    .id(manager.showsPinnedOnly)
                    .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            controlColumn
        }
    }

    @ViewBuilder
    private func tile(for entry: ClipboardEntry, tileSize: CGFloat, now: Date) -> some View {
#if BN_DIAG
        if ClipboardBisect.placeholderTile {
            ClipboardPlaceholderTile(entry: entry, tileSize: tileSize)
        } else {
            realTile(for: entry, tileSize: tileSize, now: now)
        }
#else
        realTile(for: entry, tileSize: tileSize, now: now)
#endif
    }

    private func realTile(for entry: ClipboardEntry, tileSize: CGFloat, now: Date) -> some View {
        ClipboardEntryTile(
            entry: entry,
            tileSize: tileSize,
            timeLabel: relativeTime(from: entry.timestamp, now: now),
            canOpen: manager.canOpenFiles(entry),
            onPinnedPage: manager.showsPinnedOnly
        ) {
            manager.copy(entry)
        } onPreview: {
            coordinator.prepareIslandExpansion(clipboardPreviewHeight)
            // Next turn, so the window has already grown and the island animates
            // inside a window that is no longer changing size underneath it
            DispatchQueue.main.async {
                withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                    coordinator.clipboardPreviewEntry = entry
                }
            }
        } onOpen: {
            manager.openFiles(entry)
        } onTogglePin: {
            togglePin(entry)
        } onDelete: {
            withAnimation(.smooth) {
                manager.remove(id: entry.id)
            }
        }
    }

    /// Clear-all on top, the pinned-collection switch under it, as asked for in #47.
    private var controlColumn: some View {
        VStack(spacing: 6) {
            Button {
                withAnimation(.smooth(duration: 0.2)) { manager.clear() }
            } label: {
                Image(systemName: "trash")
                    .imageScale(.small)
                    .foregroundStyle(.gray)
                    .padding(6)
                    .background(Circle().fill(Color.white.opacity(0.07)))
            }
            .buttonStyle(.plain)
            // Dimmed rather than hidden on the pinned page: hiding it would move the pin
            // button up under the cursor, and clearing from a page whose every entry is
            // exempt would look like the button did nothing. Same capability-honest
            // treatment as the unsupported like button in #15.
            .disabled(manager.showsPinnedOnly)
            .opacity(manager.showsPinnedOnly ? 0.35 : 1)
            .help(clearHelp)

            Button(action: togglePage) {
                Image(systemName: manager.showsPinnedOnly ? "pin.fill" : "pin")
                    .imageScale(.small)
                    // Dark glyph ON the chip when selected, rather than a tinted glyph on a
                    // faint tinted disc. Inverting figure and ground is what makes it read as
                    // "selected" at a glance, and it is the half that does not depend on the
                    // artwork at all.
                    .foregroundStyle(manager.showsPinnedOnly ? Color.black.opacity(0.82) : .gray)
                    .contentTransition(.symbolEffect)
                    .padding(6)
                    .background(
                        Circle().fill(
                            manager.showsPinnedOnly
                                ? pinSelectedTint.opacity(0.92)
                                : Color.white.opacity(0.07)
                        )
                    )
            }
            .buttonStyle(.plain)
            // Opening an empty collection is a dead end, so it is only offered once
            // something is pinned. Never disabled while the collection is open, or unpinning
            // the last entry would trap the user on that page.
            .disabled(!manager.showsPinnedOnly && manager.pinnedItems.isEmpty)
            .opacity(!manager.showsPinnedOnly && manager.pinnedItems.isEmpty ? 0.35 : 1)
            .help(pinPageHelp)
        }
    }

    /// The "on" colour for the page switch — #10's ACTIVATED accent, not `notchHighlight`.
    ///
    /// `notchHighlight` is built on `playerTint`, which normalises luminance to 0.6 as a
    /// CEILING, so it tracks how dark the album art is. That is right for a tint and wrong
    /// for a selected state. Measured as drawn over the black island: the shipped chip
    /// (`notchHighlight` at 0.20) landed between 0.0866 and 0.1437 against an unselected disc
    /// of 0.0895 — and on a dark red cover it came out at 0.0866, i.e. DIMMER THAN
    /// UNSELECTED, a negative selected signal. `playerAccent` drives luminance to 0.85 by
    /// construction instead, so the chip is 0.7253-0.7957 whatever the artwork: a worst case
    /// of +0.6358 against unselected where the shipped worst case is -0.0029.
    ///
    /// The fallback is floored too. `playerAccent` hands back the plain accent for artwork
    /// with no usable hue (near-black, near-white, greyscale, no artwork), and the raw accent
    /// is dark enough to put the dark glyph in trouble; `ensureMinimumBrightness` is the same
    /// helper `playerTint` uses internally, so this is not a second tint.
    ///
    /// Reads `avgColor` without observing it, exactly as `notchHighlight` does — the control
    /// repaints whenever the manager publishes, which covers every page switch.
    private var pinSelectedTint: Color {
        let floor = Color.effectiveAccent.ensureMinimumBrightness(factor: 0.85)
        guard Defaults[.playerColorTinting] else { return floor }
        return .playerAccent(from: MusicManager.shared.avgColor, fallback: floor)
    }

    private var clearHelp: String {
        manager.showsPinnedOnly
            ? "Switch back to the history to clear it"
            : "Clear clipboard history (pinned items are kept)"
    }

    private var pinPageHelp: String {
        if manager.showsPinnedOnly { return "Back to clipboard history" }
        let count = manager.pinnedItems.count
        return count == 0 ? "No pinned items yet" : "Pinned items (\(count))"
    }

    private func togglePage() {
        withAnimation(.smooth(duration: 0.25)) {
            manager.showsPinnedOnly.toggle()
        }
    }

    /// One route for both the corner control and the context menu, so the haptic and the
    /// animation cannot differ between them.
    private func togglePin(_ entry: ClipboardEntry) {
        // `entry` is a value snapshot taken before the toggle, so this is the state the
        // toggle is moving TO. Spelled out because reading `entry.isPinned` after the call
        // looks like the post-toggle state and is not.
        let didPin = !entry.isPinned
        withAnimation(.smooth(duration: 0.22)) {
            manager.togglePin(id: entry.id)
        }
        guard Defaults[.enableHaptics] else { return }
        // A single beat either way. The double beat #40 built is reserved for locking the
        // whole island — a tile pin is a smaller act and should not borrow its weight.
        NSHapticFeedbackManager.defaultPerformer.perform(
            didPin ? .levelChange : .alignment,
            performanceTime: .now
        )
    }
}

#if BN_DIAG
/// #53 bisection: the simplest tile that can exist.
///
/// A fixed square, a fill that changes on hover, and `.onHover`. Deliberately NOT a `Button`,
/// with no `.onDrag`, no overlays, no badges and no content branches — so that measuring its
/// hover region against its own frame isolates the framing itself from everything the real
/// tile carries.
private struct ClipboardPlaceholderTile: View {
    let entry: ClipboardEntry
    let tileSize: CGFloat

    @State private var hovering = false

    var body: some View {
        Rectangle()
            .fill(hovering ? Color.white.opacity(0.55) : Color.white.opacity(0.14))
            .frame(width: tileSize, height: tileSize)
            // Same drawn-frame recorder the real tile carries, so the hand-off log reports
            // this tile's frame on the same line as the cursor position.
            .background {
                if ClipboardHoverOwner.handoffLoggingEnabled {
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear { ClipboardHoverOwner.recordDrawnFrame(entry.id, proxy.frame(in: .global)) }
                            .onChange(of: proxy.frame(in: .global)) { _, f in
                                ClipboardHoverOwner.recordDrawnFrame(entry.id, f)
                            }
                    }
                }
            }
            .onHover { h in
                ClipboardHoverOwner.logHoverEdge(entry.id, h)
                hovering = h
            }
            .onDisappear { ClipboardHoverOwner.forgetDrawnFrame(entry.id) }
    }
}
#endif

// MARK: - Entry tile

private struct ClipboardEntryTile: View {
    let entry: ClipboardEntry
    let tileSize: CGFloat
    let timeLabel: String
    /// False for a file entry this app can no longer hand to another app — see
    /// `ClipboardManager.canOpenFiles`. Such a tile keeps the preview control instead of
    /// getting an open arrow that could not do anything.
    let canOpen: Bool
    /// True while the pinned collection is the page on screen. Suppresses the RESTING pin
    /// badge only: on that page every entry is pinned by definition, so a badge on every
    /// tile carries no information. The hover pin/unpin control is untouched — unpinning
    /// from here is the only route back for an entry, and #47 deliberately keeps the page
    /// reachable-out-of for exactly that reason.
    let onPinnedPage: Bool
    let onTap: () -> Void
    let onPreview: () -> Void
    let onOpen: () -> Void
    let onTogglePin: () -> Void
    let onDelete: () -> Void

    @State private var isCopied = false
    @State private var showDeleteConfirm = false
    @ObservedObject private var hoverOwner = ClipboardHoverOwner.shared

    /// REVERTED to the shared owner, twice now, and the second revert is the informative one.
    ///
    /// Per-tile hover is the simpler and more honest design, and the singleton's founding
    /// premise really is false — see the note on `ClipboardHoverOwner`. But BOTH per-tile
    /// variants, including one that stored no `Task` in `@State`, moved the reveal to
    /// `.task(id:)` and cut per-edge state mutations from three to one, made tiles drop and
    /// reacquire hover with the pointer standing still inside their own frame: 8 such events
    /// across one sweep, every one reading `cursorInsideDrawn YES`, where the singleton
    /// produced clean single OUT/IN pairs and nothing in between. The flap tracks the
    /// per-tile architecture itself rather than how its state is stored, and it does not
    /// reproduce in the harness, so it cannot be iterated on safely here.
    ///
    /// Do not re-attempt this without a reproduction of the flap outside the running app.
    private var isHovering: Bool { hoverOwner.ownerID == entry.id }
    private var showsActions: Bool { isHovering && hoverOwner.actionsVisible }

    private var buttonSize: CGFloat { max(17, tileSize * 0.20) }
    // Clears the tile's rounded corners without pushing the buttons toward the middle
    private var hoverActionInset: CGFloat { 5 }

    /// A file entry's useful action is opening it, not reading its path (#48). Only offered
    /// when the open can actually succeed; otherwise the preview — the list of filenames —
    /// is still worth something and is not a dead control.
    ///
    /// The rule is that a control which is PRESENT BUT BROKEN is worse than the older, less
    /// useful one it would replace. An entry captured before this app recorded bookmarks has
    /// no right to its own files after a relaunch (see `ClipboardManager.canOpenFiles`), so
    /// it keeps the preview rather than gaining an arrow that silently does nothing.
    private var offersOpen: Bool {
        if case .fileURLs = entry.content { return canOpen }
        return false
    }

    /// The tile's own content, identical whether or not the `Button` wraps it, so t3 removes
    /// the wrapper and nothing else.
    @ViewBuilder
    private var label: some View {
            ZStack {
                tileContent
                    .frame(width: tileSize, height: tileSize)

                // Timestamp badge — fades out on hover
                Text(timeLabel)
                    .font(.system(size: 7, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.black.opacity(0.45)))
                    .padding(4)
                    .frame(width: tileSize, height: tileSize, alignment: .bottomTrailing)
                    .opacity(isHovering ? 0 : 1)
                    .animation(.easeInOut(duration: 0.15), value: isHovering)

                // Pin state at rest, in the slot the hover pin toggle occupies. One
                // affordance in two states rather than two glyphs in two corners: at 94pt
                // (the shipped tile) a bottom-left pin overlaps #31's "Click to copy"
                // capsule by 4.15pt — measured, 54.70pt capsule against a 23.80pt corner —
                // while the top centre clears both neighbours at 94pt and at 70pt.
                //
                // Deliberately NOT the top-right corner, which was considered for #54. The
                // badge and the hover controls genuinely cannot coexist — the badge is fully
                // faded at 150ms and the controls do not begin appearing until the 220ms
                // reveal delay — so overlap is not the objection. The objection is that the
                // top-right hover slot is the TRASH: a persistent marker meaning "this one is
                // kept forever" would sit exactly where the control that destroys it appears,
                // and a user aiming at the marker they last saw would land on delete. #29c
                // separated open from delete for that reason; putting the pin badge there
                // reintroduces the same mis-aim against a destructive control. The top centre
                // is the pin TOGGLE's own slot, so aiming at the badge lands on the control
                // that does what the badge is about.
                Image(systemName: "pin.fill")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Color.notchHighlight)
                    // Reads as a solid badge rather than a tint over the tile. At 0.45 the
                    // capsule let a bright image through and left a 7pt mid-blue glyph with
                    // almost no contrast behind it; 0.78 plus a tinted hairline gives the
                    // glyph its own ground on any tile content.
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(.black.opacity(0.78))
                            .overlay(Capsule().strokeBorder(Color.notchHighlight.opacity(0.35), lineWidth: 0.5))
                    )
                    .padding(4)
                    .frame(width: tileSize, height: tileSize, alignment: .top)
                    .opacity(entry.isPinned && !isHovering && !onPinnedPage ? 1 : 0)
                    .animation(.easeInOut(duration: 0.15), value: isHovering)
                    .animation(.easeInOut(duration: 0.15), value: entry.isPinned)
                    .allowsHitTesting(false)

                // Copied checkmark overlay
                if isCopied {
                    RoundedRectangle(cornerRadius: ShelfItemMetrics.cornerRadius)
                        .fill(.black.opacity(0.5))
                        .frame(width: tileSize, height: tileSize)
                    Image(systemName: "checkmark")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            // Structural, not belt-and-braces: `imageTile` fixes the one content type that
            // overhangs today, this makes it impossible for any of them to do it again. A
            // tile is interactive over its own square and nothing else, whatever it draws.
            .contentShape(Rectangle())
    }

    @ViewBuilder
    private var dragPreview: some View {
        tileContent
            .frame(width: tileSize, height: tileSize)
            .clipShape(RoundedRectangle(cornerRadius: ShelfItemMetrics.cornerRadius))
    }

    @ViewBuilder
    private var hoverControlsOverlay: some View {
            ZStack {
                if showsActions && !isCopied {
                    ZStack(alignment: .top) {
                        RoundedRectangle(cornerRadius: ShelfItemMetrics.cornerRadius)
                            .fill(.black.opacity(0.55))
                            .allowsHitTesting(false)

                        HStack(spacing: 0) {
                            // Open (files) or preview — top-left corner, the far corner from
                            // delete. The shelf puts open and delete in opposite corners so a
                            // mis-aimed click cannot destroy instead of launch; the same
                            // reasoning keeps the pin in the middle, where the nearest
                            // control is 13.8pt away at a 94pt tile.
                            if offersOpen {
                                Button(action: onOpen) {
                                    // Bare arrow, no disc — the shelf's vocabulary for "this
                                    // leaves the app", deliberately distinct from the
                                    // disc-backed actions
                                    Image(systemName: "arrow.up.forward")
                                        .font(.system(size: 9, weight: .semibold))
                                        .frame(width: buttonSize, height: buttonSize)
                                        .foregroundStyle(Color.notchHighlight.opacity(0.85))
                                        // The other two controls get their target from the
                                        // disc behind them; this one has no disc, and the
                                        // shelf's own note is that a 9pt glyph is far too
                                        // small a target on its own
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help("Open")
                            } else {
                                Button(action: onPreview) {
                                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                                        .font(.system(size: 8))
                                        .frame(width: buttonSize, height: buttonSize)
                                        .background(HoverActionBackdrop(tint: Color.white.opacity(0.10)))
                                        .foregroundStyle(.white)
                                }
                                .buttonStyle(.plain)
                                .help("Preview")
                            }

                            Spacer(minLength: 0)

                            // Pin / unpin — top centre, the same slot the resting pin badge
                            // occupies, so the indicator and the control are one thing
                            Button(action: onTogglePin) {
                                Image(systemName: entry.isPinned ? "pin.fill" : "pin")
                                    .font(.system(size: 8))
                                    .contentTransition(.symbolEffect)
                                    .frame(width: buttonSize, height: buttonSize)
                                    .background(
                                        HoverActionBackdrop(
                                            tint: entry.isPinned
                                                ? Color.notchHighlight.opacity(0.30)
                                                : Color.white.opacity(0.10)
                                        )
                                    )
                                    .foregroundStyle(entry.isPinned ? Color.notchHighlight : .white)
                            }
                            .buttonStyle(.plain)
                            .help(entry.isPinned ? "Unpin" : "Pin")

                            Spacer(minLength: 0)

                            // Delete — top-right corner
                            Button {
                                requestClipboardDelete(confirm: $showDeleteConfirm, onDelete: onDelete)
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 8))
                                    .frame(width: buttonSize, height: buttonSize)
                                    .background(HoverActionBackdrop(tint: Color.red.opacity(0.30)))
                                    .foregroundStyle(.red.opacity(0.9))
                            }
                            .buttonStyle(.plain)
                            .help("Delete")
                        }
                        .padding(hoverActionInset)
                    }
                    .frame(width: tileSize, height: tileSize)
                    .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .top)))
                }
            }
            .animation(.easeInOut(duration: 0.12), value: showsActions)
    }

    @ViewBuilder
    private var copyHintOverlay: some View {
            Text("Click to copy")
                .font(.system(size: 7, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(Capsule().fill(.black.opacity(0.45)))
                .padding(4)
                .opacity(showsActions && !isCopied ? 1 : 0)
                .animation(.easeInOut(duration: 0.12), value: showsActions)
                .allowsHitTesting(false)
    }

    @ViewBuilder
    private var tileContextMenu: some View {

            Button(action: onTogglePin) {
                Label(entry.isPinned ? "Unpin" : "Pin", systemImage: entry.isPinned ? "pin.slash" : "pin")
            }
            // The only route to a file entry's preview once its corner control is the open
            // arrow, and the filename list is the one thing a multi-file entry's preview is
            // genuinely useful for
            Button(action: onPreview) {
                Label("Preview", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            if offersOpen {
                Button(action: onOpen) {
                    Label("Open", systemImage: "arrow.up.forward")
                }
            }
            Divider()
            Button(role: .destructive) {
                requestClipboardDelete(confirm: $showDeleteConfirm, onDelete: onDelete)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        
    }

    var body: some View {
#if BN_DIAG
        diagnosticBody
#else
        shippedBody
#endif
    }

    /// The tile exactly as it ships. No #53 scaffolding of any kind in this chain — a default
    /// build compiles only this, so there is no gate to be set wrong and no extra layer in the
    /// view tree.
    private var shippedBody: some View {
        Button(action: handleTap) { label }
            .buttonStyle(.plain)
            // Applied before the hover overlays so a press that starts on a corner icon
            // belongs to that icon, not to the drag
            .onDrag(dragProvider) { dragPreview }
            .overlay { hoverControlsOverlay }
            .overlay(alignment: .bottom) { copyHintOverlay }
            .onHover { hovering in
                if hovering {
                    hoverOwner.enter(entry.id)
                    // A drag can only start from a hovered tile, so this is the last moment
                    // before one that is free
                    ClipboardDragFileStore.shared.prepare(entry)
                } else {
                    hoverOwner.exit(entry.id)
                }
            }
            .onDisappear { hoverOwner.exit(entry.id) }
            .contextMenu { tileContextMenu }
            .clipboardDeleteConfirmation(isPresented: $showDeleteConfirm, onDelete: onDelete)
    }

#if BN_DIAG
    /// The instrumented tile: bisect gates, the drawn-frame recorder and the hover-edge log.
    private var diagnosticBody: some View {        Group {
            if ClipboardBisect.removesTile(3) {
                label
            } else {
                Button(action: handleTap) { label }
                    .buttonStyle(.plain)
            }
        }
        // Applied before the hover overlays so a press that starts on a corner icon belongs
        // to that icon, not to the drag
        .modifier(BisectableDrag(provider: dragProvider) { dragPreview })
        .modifier(BisectableOverlay(alignment: .center) { hoverControlsOverlay })
        // #53 tile ladder t2 (second of two overlays)
        // "Click to copy" takes the badge slot the timestamp vacates on hover, so the hint
        // costs no new moving part. Driven by opacity rather than inserted into the hover
        // overlay above, which carries a scale transition that would make it travel.
        .modifier(BisectableOverlay(alignment: .bottom) { copyHintOverlay })
        // Diagnostic only, and only under BN_HOVER_DEBUG: records where this tile is DRAWN so
        // the hand-off log can carry the cursor position and the tile's drawn extent on one
        // line, from one instant. Nothing in the app's behaviour reads it — this is emphatically
        // NOT the geometry veto that caused #33, which fed hover decisions.
        .onHover { hovering in
            ClipboardHoverOwner.logHoverEdge(entry.id, hovering)
            if hovering {
                hoverOwner.enter(entry.id)
                // A drag can only start from a hovered tile, so this is the last moment
                // before one that is free
                ClipboardDragFileStore.shared.prepare(entry)
            } else {
                hoverOwner.exit(entry.id)
            }
        }
        .background {
            if ClipboardHoverOwner.handoffLoggingEnabled {
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { ClipboardHoverOwner.recordDrawnFrame(entry.id, proxy.frame(in: .global)) }
                        .onChange(of: proxy.frame(in: .global)) { _, f in
                            ClipboardHoverOwner.recordDrawnFrame(entry.id, f)
                        }
                }
            }
        }
        // A tile deleted or reordered out from under a hovered cursor must not leave the
        // owner pointing at a tile that no longer exists
        // A tile torn down while hovered takes its own state with it; the only thing that
        // outlives it is the cursor push, so that has to be unwound here.
        // A tile torn down while hovered takes its own state with it; the cursor push is the
        // only thing that outlives it, so that has to be unwound here.
        .onDisappear {
            hoverOwner.exit(entry.id)
            ClipboardHoverOwner.forgetDrawnFrame(entry.id)
        }
        // #53 tile ladder t4
        .modifier(BisectableContextMenu { tileContextMenu })
        .clipboardDeleteConfirmation(isPresented: $showDeleteConfirm, onDelete: onDelete)
        .modifier(BisectHoverPadding())
    }
#endif

    /// What leaves the island when the tile is dragged. One provider, so a multi-file entry
    /// can only offer its first URL — the same limitation the shelf's drag has.
    private func dragProvider() -> NSItemProvider {
        switch entry.content {
        case .text(let str):
            return NSItemProvider(object: str as NSString)

        case .fileURLs(let urls):
            guard let first = urls.first else { return NSItemProvider() }
            return NSItemProvider(object: first as NSURL)

        case .image(let image):
            if let url = ClipboardDragFileStore.shared.url(for: entry.id) {
                return NSItemProvider(object: url as NSURL)
            }
            // The file was not ready in time. Image data still drags into anything that
            // accepts an image; only Finder needs the file.
            let provider = NSItemProvider()
            if let tiff = image.tiffRepresentation {
                provider.registerDataRepresentation(
                    forTypeIdentifier: UTType.tiff.identifier,
                    visibility: .all
                ) { completion in
                    completion(tiff, nil)
                    return nil
                }
            }
            return provider
        }
    }

    private func handleTap() {
        onTap()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { isCopied = true }
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            withAnimation(.easeOut(duration: 0.25)) { isCopied = false }
        }
    }

    @ViewBuilder
    private var tileContent: some View {
        switch entry.content {
        case .text(let str):   textTile(str)
        case .image(let img):  imageTile(img)
        case .fileURLs(let u): fileTile(u)
        }
    }

    private func textTile(_ text: String) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: ShelfItemMetrics.cornerRadius)
                .fill(Color.white.opacity(0.07))
                .overlay(RoundedRectangle(cornerRadius: ShelfItemMetrics.cornerRadius).stroke(Color.white.opacity(0.1), lineWidth: 1))
            Text(String(text.prefix(300)))
                .font(.system(size: 8))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(5)
                .multilineTextAlignment(.leading)
                .padding(6)
        }
    }

    /// `#53`. `.fill` sizes the image to COVER the tile, so a non-square capture is LAID OUT
    /// wider than `tileSize` — a 1.95:1 screenshot in a 95pt tile is 185pt wide — and hangs
    /// half the excess over each side of its own frame. `.clipShape` hides that overhang; it
    /// does not take it out of hit testing, and `.frame` never did. So the tile answered
    /// hover across the image's width, not its own, and in the strip the neighbour drawn
    /// AFTER it won the overlap: hover jumped to the next tile at an edge with nothing drawn
    /// on it.
    ///
    /// This is what #53's measurements were describing without naming it. The hit partition
    /// was gapless with unequal cells (edges 171/227/331/439) against a gapped, equal drawing
    /// (tiles at 171/272/373/474, 95pt, 6pt gaps) — and each hit edge lands exactly half an
    /// overhang left of the tile it belongs to: 272-227 = 45, 373-331 = 42, 474-439 = 35, the
    /// same 45/42/35pt displacements logged in the live app. They differ per tile because
    /// each entry is a different aspect ratio, which is why no constant offset and no ~5%
    /// scale ever fitted. Slot 0's left edge agreed to +0.00 because an overhang reaches into
    /// its neighbour PART WAY IN — 45pt short of tile 1, not at tile 0's own left edge, which
    /// nothing overlaps. The first tile is exact in every run for that reason alone.
    ///
    /// `.contentShape` pins the interactive region back to the drawn square. Measured in an
    /// isolated harness — a row of 95pt tiles, 6pt spacing, alternating plain tiles with 1.95:1
    /// and 1.74:1 images, sweeping the real cursor 1pt at a time. Without it the hit partition
    /// is gapless and unequal (spans 56/146/66/161) and each image tile takes hover 45 / 35pt
    /// before it is drawn; with it, four 95pt spans separated by exact 6pt gaps, every tile
    /// starting on its own drawn edge. This is also the ingredient the old harness lacked: it
    /// tiled colour blocks, and a square image cannot overhang.
    private func imageTile(_ image: NSImage) -> some View {
        Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: tileSize, height: tileSize)
            .clipShape(RoundedRectangle(cornerRadius: ShelfItemMetrics.cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: ShelfItemMetrics.cornerRadius).stroke(Color.white.opacity(0.1), lineWidth: 1))
            .contentShape(Rectangle())
    }

    private func fileTile(_ urls: [URL]) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: ShelfItemMetrics.cornerRadius)
                .fill(Color.white.opacity(0.07))
                .overlay(RoundedRectangle(cornerRadius: ShelfItemMetrics.cornerRadius).stroke(Color.white.opacity(0.1), lineWidth: 1))
            // A persisted entry can decode back with no URLs, so never index blindly
            if let first = urls.first {
                VStack(spacing: 3) {
                    Image(nsImage: ClipboardFileIcon.image(for: first))
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 28, height: 28)
                    Text(first.lastPathComponent)
                        .font(.system(size: 7))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                    if urls.count > 1 {
                        Text("+\(urls.count - 1)")
                            .font(.system(size: 6))
                            .foregroundStyle(.gray)
                    }
                }
                .padding(5)
            } else {
                emptyFileTile
            }
        }
    }

    private var emptyFileTile: some View {
        VStack(spacing: 3) {
            Image(systemName: "questionmark.folder")
                .imageScale(.large)
                .foregroundStyle(.gray.opacity(0.5))
            Text("No files")
                .font(.system(size: 7))
                .foregroundStyle(.gray)
        }
        .padding(5)
    }
}

// MARK: - Preview

#Preview {
    ClipboardHistoryView(rows: 1, pinnedTileSide: 0)
        .frame(width: 420, height: 90)
        .padding(12)
        .background(Color.black)
        .preferredColorScheme(.dark)
}

#if BN_DIAG
/// #53 tile ladder t1: the tile's `.onDrag`. Prime suspect — it is the only modifier in the
/// chain that installs its own AppKit-level drag tracking, and a drag source registering a
/// region larger than the view it decorates would produce exactly a trailing-side overhang
/// with an exact leading edge, which is the measured asymmetry.
private struct BisectableDrag<Preview: View>: ViewModifier {
    let provider: () -> NSItemProvider
    @ViewBuilder let preview: () -> Preview

    func body(content: Content) -> some View {
        if ClipboardBisect.removesTile(1) {
            content
        } else {
            content.onDrag(provider, preview: preview)
        }
    }
}

/// #53 tile ladder t2: an `.overlay`, omitted entirely rather than given empty content, so the
/// level removes the modifier and not merely what it draws.
private struct BisectableOverlay<Overlay: View>: ViewModifier {
    let alignment: Alignment
    @ViewBuilder let overlayContent: () -> Overlay

    func body(content: Content) -> some View {
        if ClipboardBisect.removesTile(2) {
            content
        } else {
            content.overlay(alignment: alignment) { overlayContent() }
        }
    }
}

/// #53 tile ladder t4: the tile's `.contextMenu`.
private struct BisectableContextMenu<Menu: View>: ViewModifier {
    @ViewBuilder let menu: () -> Menu

    func body(content: Content) -> some View {
        if ClipboardBisect.removesTile(4) {
            content
        } else {
            content.contextMenu { menu() }
        }
    }
}

/// #53: adds `BN_PAD` inert hover regions to a tile. They change no state and draw nothing;
/// their only effect is to exist.
private struct BisectHoverPadding: ViewModifier {
    func body(content: Content) -> some View {
        var view = AnyView(content)
        for _ in 0 ..< ClipboardBisect.padCount {
            view = AnyView(view.onHover { _ in })
        }
        return view
    }
}

#endif
