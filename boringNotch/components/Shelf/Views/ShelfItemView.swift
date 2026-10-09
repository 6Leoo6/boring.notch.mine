//
//  ShelfItemView.swift
//  boringNotch
//
//  Created by Alexander on 2025-09-24.
//

import AppKit
import SwiftUI
import Defaults

import QuickLook

// MARK: - Delete confirmation

/// The shelf's removal flow, mirroring the clipboard's so the two panels behave alike (#16).
/// The alert is its own window, so the notch loses hover the instant it appears — hence the
/// close guard while it is up and the grace period once it goes.
///
/// The wording deliberately does NOT match the clipboard's. Removing a shelf item drops the
/// entry and nothing else — `ShelfActionService.remove` never touches the file — so borrowing
/// "removed from your history" would read as though we were deleting the user's document. The
/// verb is "Remove" for the same reason, and it matches the existing context-menu item.
struct ShelfDeleteConfirmation: ViewModifier {
    @Binding var isPresented: Bool
    /// How many items are going. The context menu removes the whole selection, so the dialog
    /// must not say "this item" when it is about to take five.
    let count: Int
    let onDelete: () -> Void
    @EnvironmentObject private var vm: BoringViewModel

    private var title: String {
        count > 1 ? "Remove \(count) items from shelf?" : "Remove from shelf?"
    }

    private var message: String {
        count > 1
            ? "These items will be removed from the shelf. The files themselves are not deleted."
            : "This item will be removed from the shelf. The file itself is not deleted."
    }

    func body(content: Content) -> some View {
        content
            .alert(title, isPresented: $isPresented) {
                Button("Remove", role: .destructive) { onDelete() }
                Button("Remove, don't ask again", role: .destructive) {
                    Defaults[.shelfDeleteConfirmEnabled] = false
                    onDelete()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(message)
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
    func shelfDeleteConfirmation(
        isPresented: Binding<Bool>,
        count: Int,
        onDelete: @escaping () -> Void
    ) -> some View {
        modifier(ShelfDeleteConfirmation(isPresented: isPresented, count: count, onDelete: onDelete))
    }
}

/// The tile's corner controls. Hit testing for all three runs through the sibling `NSView`
/// rather than SwiftUI buttons: the AppKit view is a real subview and wins the hit test for
/// anything drawn over it, so a `Button` in an overlay would never reliably receive the click.
fileprivate enum TileAction: Hashable, CaseIterable {
    case copy
    case open
    case delete
}

fileprivate struct TileActionZone {
    let action: TileAction
    let rect: CGRect
}

struct ShelfItemView: View {
    let item: ShelfItem
    let tileSize: CGFloat
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject var selection = ShelfSelectionModel.shared
    @StateObject private var viewModel: ShelfItemViewModel
    @EnvironmentObject private var quickLookService: QuickLookService
    @State private var showStack = false
    @State private var cachedPreviewImage: NSImage?
    @State private var debouncedDropTarget = false
    @State private var isPressed = false
    @State private var isHovering = false
    @State private var hoveredAction: TileAction?
    @State private var launchPop = false
    @State private var showCopied = false
    /// Items awaiting confirmation, for whichever path asked. Kept separate from the
    /// presentation flag: dismissing the alert clears the flag, and reading the items back out
    /// of a binding that has just been cleared would remove nothing.
    @State private var pendingRemoval: [ShelfItem] = []
    @State private var showRemovalConfirm = false
    @ObservedObject private var shelf = ShelfStateViewModel.shared

    // Corner controls: bare arrow for open, discs for the two actions #24 asked for
    private let actionGlyph: CGFloat = 9
    /// The clipboard tile's inset, so the two panels' corner controls line up (#29c)
    private let actionInset: CGFloat = 5
    /// A 9pt glyph is far too small a target on its own
    private let actionHitSlop: CGFloat = 3
    /// Same rule as the clipboard tile, so both panels scale their controls together
    private var actionBox: CGFloat { max(17, tileSize * 0.20) }

    /// The house spring, tightened for a tile this small. `NotchHomeView.mirrorSpring` is the
    /// same family; Pow is listed in the conventions but is not actually linked anywhere.
    private static let pressSpring = Animation.interactiveSpring(response: 0.22, dampingFraction: 0.72, blendDuration: 0)

    private var isLaunching: Bool { shelf.launchingIDs.contains(item.id) }

    /// Open stays in the top-right corner it has always been in — deliberately NOT swapped
    /// for the clipboard's top-right trash, because the two share a hit box and a mis-aimed
    /// click would delete instead of open. Delete goes to the far corner instead.
    private func actionRect(_ action: TileAction) -> CGRect {
        let box = actionBox
        let far = tileSize - actionInset - box
        switch action {
        case .copy:   return CGRect(x: actionInset, y: actionInset, width: box, height: box)
        case .open:   return CGRect(x: far, y: actionInset, width: box, height: box)
        case .delete: return CGRect(x: far, y: far, width: box, height: box)
        }
    }

    private var actionZones: [TileActionZone] {
        TileAction.allCases.map {
            TileActionZone(action: $0, rect: actionRect($0).insetBy(dx: -actionHitSlop, dy: -actionHitSlop))
        }
    }

    private var isSelected: Bool { viewModel.isSelected }
    private var shouldHideDuringDrag: Bool { selection.isDragging && selection.isSelected(item.id) && false }
    
    init(item: ShelfItem, tileSize: CGFloat) {
        self.item = item
        self.tileSize = tileSize
        _viewModel = StateObject(wrappedValue: ShelfItemViewModel(item: item))
    }

    var body: some View {
        ZStack {
            if !shouldHideDuringDrag {
                VStack(alignment: .center, spacing: ShelfItemMetrics.iconLabelSpacing) {
                    iconView
                    textView
                }
                .padding(ShelfItemMetrics.tilePadding)
                .frame(width: tileSize, height: tileSize)
                .background(backgroundView)
                .contentShape(Rectangle())
                // Acknowledges the click the instant it lands. Only the visual scales — the
                // hit target is the sibling NSView below, so the press cannot move the
                // thing being pressed out from under the cursor.
                .scaleEffect(isPressed ? 0.96 : 1)
                // Straight down on the press so it is felt as contact, springing back on
                // release so it lands in the same motion vocabulary as the rest of the notch
                .animation(isPressed ? .easeOut(duration: 0.07) : Self.pressSpring, value: isPressed)
                .animation(.easeInOut(duration: 0.1), value: debouncedDropTarget)
                .animation(.easeInOut(duration: 0.1), value: isSelected)

                DraggableClickHandler(
                    item: item,
                    viewModel: viewModel,
                    cachedPreviewImage: $cachedPreviewImage,
                    dragPreviewContent: {
                        DragPreviewView(thumbnail: viewModel.thumbnail ?? item.icon, displayName: item.displayName)
                    },
                    onRightClick: viewModel.handleRightClick,
                    onClick: { event, nsview in
                        viewModel.handleClick(event: event, view: nsview)
                    },
                    onPressChanged: { pressed in
                        isPressed = pressed
                    },
                    actionZones: actionZones,
                    onActionRequested: { action in
                        switch action {
                        case .open: viewModel.openSelf()
                        case .copy: copySelf()
                        case .delete: requestRemoval([item])
                        }
                    },
                    onHoverChanged: { tileHover, action in
                        // Guarded because mouseMoved fires continuously; without this every
                        // pointer movement over the tile would open an animation transaction
                        guard tileHover != isHovering || action != hoveredAction else { return }
                        withAnimation(.easeInOut(duration: 0.12)) {
                            isHovering = tileHover
                            hoveredAction = action
                        }
                    },
                    toolTip: item.displayName
                )
            } else {
                Color.clear
                    .frame(width: tileSize, height: tileSize)
            }
        }
        // Corner controls. Positioned by the SAME rects the hit zones are built from, so the
        // glyph a user aims at and the zone that answers can never drift apart. Hit testing is
        // off because the sibling NSView owns the click.
        .overlay(alignment: .topLeading) {
            if isHovering && !isLaunching && !showCopied {
                ZStack(alignment: .topLeading) {
                    ForEach(TileAction.allCases, id: \.self) { action in
                        let rect = actionRect(action)
                        actionGlyph(action)
                            .frame(width: actionBox, height: actionBox)
                            .offset(x: rect.minX, y: rect.minY)
                    }
                }
                .frame(width: tileSize, height: tileSize, alignment: .topLeading)
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        // Confirms the copy landed. Nothing else about a copy is visible, and it reuses the
        // clipboard tile's confirmation shape rather than inventing a second one.
        .overlay {
            if showCopied {
                ZStack {
                    RoundedRectangle(cornerRadius: ShelfItemMetrics.cornerRadius, style: .continuous)
                        .fill(.black.opacity(0.45))
                    Image(systemName: "checkmark")
                        .font(.headline)
                        .foregroundStyle(.white)
                }
                .frame(width: tileSize, height: tileSize)
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: showCopied)
        // L2 launch cue: honest about an indeterminate wait, and the same
        // centre-on-a-scrim shape the clipboard uses to confirm a copy
        .overlay {
            if isLaunching {
                ZStack {
                    RoundedRectangle(cornerRadius: ShelfItemMetrics.cornerRadius, style: .continuous)
                        .fill(.black.opacity(0.45))
                    LaunchSpinner()
                }
                .frame(width: tileSize, height: tileSize)
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: isLaunching)
        // The press says "click received"; this says "it is opening". Without it the only
        // signal is the scrim fading in, which reads as the tile going quiet rather than
        // committing. Deliberately small — 3.5% on a 68pt tile is ~1pt per side, so it
        // cannot collide with its neighbours in the grid.
        .scaleEffect(launchPop ? 1.035 : 1)
        .animation(Self.pressSpring, value: launchPop)
        .onChange(of: isLaunching) { _, launching in
            guard launching else { return }
            launchPop = true
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(150))
                launchPop = false
            }
        }
        .onChange(of: viewModel.isDropTargeted) { _, targeted in
            vm.dragDetectorTargeting = targeted
            // Debounce drop target state changes
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(50))
                debouncedDropTarget = targeted
            }
        }
        .onAppear {
            Task { 
                await viewModel.loadThumbnail()
                // Pre-render drag preview once on appear
                if cachedPreviewImage == nil {
                    cachedPreviewImage = await renderDragPreview()
                }
            }
            viewModel.onQuickLookRequest = { urls in
                quickLookService.show(urls: urls, selectFirst: true)
            }
        }
        .onChange(of: viewModel.thumbnail) { _, _ in
            // Invalidate cached preview when thumbnail changes
            Task {
                cachedPreviewImage = await renderDragPreview()
            }
        }
        .quickLookPresenter(using: quickLookService)
        // One confirmation for both removal paths — the corner trash and the context menu —
        // so `shelfDeleteConfirmEnabled` means what its name says on every route.
        .onChange(of: viewModel.removalRequestID) { _, _ in
            requestRemoval(viewModel.removalRequestItems)
        }
        .shelfDeleteConfirmation(isPresented: $showRemovalConfirm, count: pendingRemoval.count) {
            performPendingRemoval()
        }
    }

    // MARK: - Actions

    private func requestRemoval(_ items: [ShelfItem]) {
        guard !items.isEmpty else { return }
        guard Defaults[.shelfDeleteConfirmEnabled] else {
            items.forEach { ShelfActionService.remove($0) }
            return
        }
        pendingRemoval = items
        showRemovalConfirm = true
    }

    private func performPendingRemoval() {
        let items = pendingRemoval
        pendingRemoval = []
        items.forEach { ShelfActionService.remove($0) }
    }

    private func copySelf() {
        viewModel.copySelfWithoutRecording()
        showCopied = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            showCopied = false
        }
    }

    // MARK: - View Components

    @ViewBuilder
    private func actionGlyph(_ action: TileAction) -> some View {
        let hovered = hoveredAction == action
        switch action {
        case .open:
            // Backdrop-free at rest so it reads as a hint across the tile rather than a third
            // control; it brightens and gains a faint disc once the pointer is actually on it
            Image(systemName: "arrow.up.forward")
                .font(.system(size: actionGlyph, weight: .semibold))
                .foregroundStyle(Color.notchHighlight.opacity(hovered ? 1 : 0.75))
                .frame(width: actionBox, height: actionBox)
                .background(Circle().fill(Color.white.opacity(hovered ? 0.14 : 0)))
        case .copy:
            Image(systemName: "doc.on.doc")
                .font(.system(size: actionGlyph - 1, weight: .semibold))
                .foregroundStyle(.white.opacity(hovered ? 1 : 0.85))
                .frame(width: actionBox, height: actionBox)
                .background(HoverActionBackdrop(tint: Color.white.opacity(hovered ? 0.18 : 0.10)))
        case .delete:
            Image(systemName: "trash")
                .font(.system(size: actionGlyph - 1, weight: .semibold))
                .foregroundStyle(.red.opacity(hovered ? 1 : 0.9))
                .frame(width: actionBox, height: actionBox)
                .background(HoverActionBackdrop(tint: Color.red.opacity(hovered ? 0.42 : 0.30)))
        }
    }

    private var iconSide: CGFloat { ShelfItemMetrics.iconSide(forTile: tileSize) }

    private var iconView: some View {
        Image(nsImage: viewModel.thumbnail ?? item.icon)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: iconSide, height: iconSide)
            .clipShape(RoundedRectangle(cornerRadius: ShelfItemMetrics.cornerRadius))
            .shadow(color: .black.opacity(0.15), radius: 3, x: 0, y: 2)
    }

    private var textView: some View {
        Text(item.displayName)
            .font(.system(size: ShelfItemMetrics.labelFontSize, weight: .medium))
            .foregroundStyle(.primary)
            .lineLimit(ShelfItemMetrics.labelLineCount)
            .truncationMode(.middle)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: ShelfItemMetrics.labelHeight, maxHeight: ShelfItemMetrics.labelHeight, alignment: .top)
    }

    private var backgroundView: some View {
        RoundedRectangle(cornerRadius: ShelfItemMetrics.cornerRadius, style: .continuous)
            .fill(backgroundColor)
            .overlay(
                RoundedRectangle(cornerRadius: ShelfItemMetrics.cornerRadius, style: .continuous)
                    .strokeBorder(
                        strokeColor,
                        lineWidth: strokeWidth
                    )
            )
    }

    private var backgroundColor: Color {
        if debouncedDropTarget {
            return Color.notchHighlight.opacity(0.25)
        } else if isSelected {
            return Color.notchHighlight.opacity(0.15)
        } else if isPressed {
            return Color.white.opacity(0.08)
        } else {
            return Color.clear
        }
    }

    private var strokeColor: Color {
        if debouncedDropTarget {
            return Color.notchHighlight.opacity(0.9)
        } else if isSelected {
            return Color.notchHighlight.opacity(0.8)
        } else {
            return Color.clear
        }
    }

    private var strokeWidth: CGFloat {
        if debouncedDropTarget {
            return 3
        } else if isSelected {
            return 2
        } else {
            return 1
        }
    }
    
    // MARK: - Drag Preview Rendering
    
    @MainActor
    private func renderDragPreview() async -> NSImage {
        let content = DragPreviewView(thumbnail: viewModel.thumbnail ?? item.icon, displayName: item.displayName)
        let renderer = ImageRenderer(content: content)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2.0
        return renderer.nsImage ?? (viewModel.thumbnail ?? item.icon)
    }

    
}

/// Indeterminate spinner for the launch cue. Hand-drawn rather than a `ProgressView`:
/// macOS's circular `ProgressView` is an `NSProgressIndicator` under the hood and ignores
/// `.tint`, so it rendered plain white instead of picking up the notch highlight.
private struct LaunchSpinner: View {
    @State private var spinning = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.72)
            .stroke(Color.notchHighlight, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            .frame(width: 22, height: 22)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: spinning)
            // Bounded by the cue's own lifetime, so the repeat cannot outlive the tile
            .onAppear { spinning = true }
    }
}

// MARK: - Draggable Click Handler with NSDraggingSource
private struct DraggableClickHandler<Content: View>: NSViewRepresentable {
    let item: ShelfItem
    let viewModel: ShelfItemViewModel
    @Binding var cachedPreviewImage: NSImage?
    @ViewBuilder let dragPreviewContent: () -> Content
    let onRightClick: (NSEvent, NSView) -> Void
    let onClick: (NSEvent, NSView) -> Void
    let onPressChanged: (Bool) -> Void
    /// Corner control hit boxes, in the tile's own top-left-origin coordinates
    let actionZones: [TileActionZone]
    let onActionRequested: (TileAction) -> Void
    /// (pointer is over the tile, the corner control it is over)
    let onHoverChanged: (Bool, TileAction?) -> Void
    let toolTip: String
    
    func makeNSView(context: Context) -> DraggableClickView {
        let view = DraggableClickView()
        view.item = item
        view.viewModel = viewModel
        view.dragPreviewImage = cachedPreviewImage ?? renderDragPreview()
        apply(to: view)
        return view
    }
    
    func updateNSView(_ nsView: DraggableClickView, context: Context) {
        nsView.item = item
        nsView.viewModel = viewModel
        // Only update preview if cached version is available
        if let cached = cachedPreviewImage {
            nsView.dragPreviewImage = cached
        }
        apply(to: nsView)
    }

    private func apply(to view: DraggableClickView) {
        view.onRightClick = onRightClick
        view.onClick = onClick
        view.onPressChanged = onPressChanged
        view.actionZones = actionZones
        view.onActionRequested = onActionRequested
        view.onHoverChanged = onHoverChanged
        // Set on the NSView rather than with `.help()`: this view sits on top of the tile,
        // so a SwiftUI tooltip underneath it would never be reached.
        view.toolTip = toolTip
    }
    
    private func renderDragPreview() -> NSImage {
        let content = dragPreviewContent()
        let renderer = ImageRenderer(content: content)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2.0
        
        if let nsImage = renderer.nsImage {
            return nsImage
        }
        
        // Fallback to icon if rendering fails
        return viewModel.thumbnail ?? item.icon
    }
    
    final class DraggableClickView: NSView, NSDraggingSource {
        var item: ShelfItem!
        weak var viewModel: ShelfItemViewModel?
        var dragPreviewImage: NSImage?
        var onRightClick: ((NSEvent, NSView) -> Void)?
        var onClick: ((NSEvent, NSView) -> Void)?
        var onPressChanged: ((Bool) -> Void)?
        var onActionRequested: ((TileAction) -> Void)?
        var onHoverChanged: ((Bool, TileAction?) -> Void)?
        var actionZones: [TileActionZone] = []

        private func action(at point: CGPoint) -> TileAction? {
            actionZones.first { $0.rect.contains(point) }?.action
        }

        /// Matches SwiftUI's top-left origin, so `openZone` needs no coordinate flip
        override var isFlipped: Bool { true }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in trackingAreas { removeTrackingArea(area) }
            addTrackingArea(
                NSTrackingArea(
                    rect: .zero,
                    options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                    owner: self,
                    userInfo: nil
                )
            )
            // Expanding the grid, or scrolling it, moves the tile out from under a stationary
            // cursor. AppKit only re-tests tracking areas against real mouse events, so
            // neither the tile the pointer left nor the one it now sits on is told: the corner
            // icons stay lit on a tile the pointer is no longer over, and never appear on the
            // one it is. Re-deriving hover from the pointer's actual position on every geometry
            // change is what keeps them with the cursor. Deferred a turn because this runs
            // inside a layout pass, and the report drives SwiftUI state.
            DispatchQueue.main.async { [weak self] in self?.syncHoverFromPointer() }
        }

        override func mouseEntered(with event: NSEvent) { reportHover(event) }
        override func mouseMoved(with event: NSEvent) { reportHover(event) }
        override func mouseExited(with event: NSEvent) { report(tileHover: false, action: nil) }

        private func reportHover(_ event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            report(tileHover: true, action: action(at: point))
        }

        private func syncHoverFromPointer() {
            guard let window, window.isVisible else {
                report(tileHover: false, action: nil)
                return
            }
            let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            guard visibleRect.contains(point) else {
                report(tileHover: false, action: nil)
                return
            }
            report(tileHover: true, action: action(at: point))
        }

        /// `updateTrackingAreas` fires on every scroll frame, so the last report is remembered
        /// here rather than waking the SwiftUI side to be discarded there.
        private var lastTileHover = false
        private var lastAction: TileAction?

        private func report(tileHover: Bool, action: TileAction?) {
            guard tileHover != lastTileHover || action != lastAction else { return }
            lastTileHover = tileHover
            lastAction = action
            onHoverChanged?(tileHover, action)
        }

        private var mouseDownEvent: NSEvent?
        private let dragThreshold: CGFloat = 3.0
        private var draggedURLs: [URL] = []
        private var draggedItems: [ShelfItem] = []
        /// The selection as it stood before the mouse-down, so a drag can hand it back.
        /// Nil when the mouse-down was itself a selection gesture and must be left alone.
        private var selectionBeforeClick: Set<UUID>?
        
        override func rightMouseDown(with event: NSEvent) {
            onRightClick?(event, self)
        }
        
        override func mouseDown(with event: NSEvent) {
            // Each corner control is its own control. Returning before any of the below is
            // what keeps it from selecting the tile, from triggering the tile's press
            // feedback, and — because `mouseDownEvent` stays nil — from arming drag
            // tracking at all.
            if let action = action(at: convert(event.locationInWindow, from: nil)) {
                mouseDownEvent = nil
                onActionRequested?(action)
                return
            }
            mouseDownEvent = event
            onPressChanged?(true)
            // Recorded before the click selects anything, so a drag that only selected the
            // tile in order to carry it can put the selection back the way it found it.
            // Shift/command/control clicks ARE selection gestures, so those stick.
            let modifiers = event.modifierFlags.intersection([.shift, .command, .control])
            selectionBeforeClick = modifiers.isEmpty ? ShelfSelectionModel.shared.selectedIDs : nil
            onClick?(event, self)
        }
        
        override func mouseUp(with event: NSEvent) {
            mouseDownEvent = nil
            onPressChanged?(false)
            super.mouseUp(with: event)
        }
        
        override func mouseDragged(with event: NSEvent) {
            guard let mouseDownEvent = mouseDownEvent else {
                super.mouseDragged(with: event)
                return
            }
            
            let dragDistance = hypot(
                event.locationInWindow.x - mouseDownEvent.locationInWindow.x,
                event.locationInWindow.y - mouseDownEvent.locationInWindow.y
            )
            
            if dragDistance > dragThreshold {
                startDragSession(with: event)
                self.mouseDownEvent = nil
            } else {
                super.mouseDragged(with: event)
            }
        }
        
        private func startDragSession(with event: NSEvent) {
            // Once the drag session owns the event loop no mouseUp arrives here, so the
            // press has to be released now or the tile stays visibly pressed for the
            // whole drag
            onPressChanged?(false)
            // Prepare dragging items
            let selectedItems = ShelfSelectionModel.shared.selectedItems(in: ShelfStateViewModel.shared.items)
            let itemsToDrag: [ShelfItem]

            if selectedItems.count > 1 && selectedItems.contains(where: { $0.id == item.id }) {
                itemsToDrag = selectedItems
            } else {
                itemsToDrag = [item]
            }

            // Store items being dragged for auto-remove feature
            draggedItems = itemsToDrag

            // Create dragging items for AppKit
            var draggingItems: [NSDraggingItem] = []

            for dragItem in itemsToDrag {
                if let pasteboardItem = createPasteboardItem(for: dragItem) {
                    let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)

                    // Use the drag preview image
                    let image = dragPreviewImage ?? dragItem.icon
                    let imageFrame = NSRect(
                        x: 0,
                        y: 0,
                        width: image.size.width,
                        height: image.size.height
                    )
                    draggingItem.setDraggingFrame(imageFrame, contents: image)

                    draggingItems.append(draggingItem)
                }
            }

            guard !draggingItems.isEmpty else { return }

            beginDraggingSession(with: draggingItems, event: event, source: self)
        }
        
        private func createPasteboardItem(for item: ShelfItem) -> NSPasteboardItem? {
            let pasteboardItem = NSPasteboardItem()

            switch item.kind {
            case .file:
                guard let url = ShelfStateViewModel.shared.resolveAndUpdateBookmark(for: item) else {
                    pasteboardItem.setString(item.displayName, forType: .string)
                    return pasteboardItem
                }
                
                // Start accessing security-scoped resource and keep it active during drag
                if url.startAccessingSecurityScopedResource() {
                    draggedURLs.append(url)
                    NSLog("🔐 Started security-scoped access for drag: \(url.path)")
                }
                
                pasteboardItem.setString(url.absoluteString, forType: .fileURL)
                pasteboardItem.setString(url.path, forType: .string)
                return pasteboardItem

            case .text(let string):
                pasteboardItem.setString(string, forType: .string)
                return pasteboardItem

            case .link(let url):
                pasteboardItem.setString(url.absoluteString, forType: .URL)
                pasteboardItem.setString(url.absoluteString, forType: .string)
                return pasteboardItem
            }
        }
        
        // MARK: - NSDraggingSource
        
        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            // When copyOnDrag is enabled, only allow copy operations
            if Defaults[.copyOnDrag] {
                return [.copy]
            }
            
            switch context {
            case .outsideApplication:
                return [.copy, .move]
            case .withinApplication:
                return [.copy, .move, .generic]
            @unknown default:
                return [.copy]
            }
        }
        
        func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
            ShelfSelectionModel.shared.beginDrag()
        }
        
        
        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            ShelfSelectionModel.shared.endDrag()

            // Stop accessing security-scoped resources after drag completes
            for url in draggedURLs {
                url.stopAccessingSecurityScopedResource()
                NSLog("🔐 Stopped security-scoped access after drag: \(url.path)")
            }
            draggedURLs.removeAll()

            // Auto-remove items from shelf if enabled and drag succeeded
            if Defaults[.autoRemoveShelfItems] && !operation.isEmpty {
                for item in draggedItems {
                    ShelfStateViewModel.shared.remove(item)
                }
            }
            draggedItems.removeAll()

            // Dragging is not a selection gesture. Restoring rather than clearing keeps a
            // deliberate multi-selection through its own drag, while a drag that started on
            // an unselected tile leaves nothing behind — that tile used to keep a selection
            // border until the user clicked the island's empty surface. Runs after the
            // auto-remove above so anything just removed is pruned out.
            if let previous = selectionBeforeClick {
                ShelfSelectionModel.shared.restore(previous)
            }
            selectionBeforeClick = nil
        }
        
        func ignoreModifierKeys(for session: NSDraggingSession) -> Bool {
            return false
        }
    }
}
