//
//  ShelfItemView.swift
//  boringNotch
//
//  Created by Alexander on 2025-09-24.
//

import SwiftUI
import AppKit
import Defaults

/// Panel border whose dashes close up into a solid line as `solidness` goes 0 -> 1.
/// `StrokeStyle`'s dash array is not animatable, so the shape returns the stroked outline
/// itself and interpolates the gap between dashes through `animatableData`.
///
/// The switcher and expander sit in breaks subtracted straight out of that outline. They used
/// to be erased with `destinationOut` overlays, which only ever worked under `ImageRenderer`:
/// the CoreAnimation layer path the app actually composites through drops the blend mode, so
/// the punch silently no-opped and the stroke stayed visible under the labels.
struct PanelBorder: Shape {
    var solidness: CGFloat
    var cornerRadius: CGFloat = 16
    var lineWidth: CGFloat = 3
    var dash: CGFloat = 10
    /// Break in the top edge, as an x range measured from the panel's leading edge
    var topGap: ClosedRange<CGFloat>?
    /// Width of the centred break in the bottom edge; zero leaves that edge unbroken
    var bottomGapWidth: CGFloat = 0

    var animatableData: CGFloat {
        get { solidness }
        set { solidness = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let gap = dash * (1 - min(max(solidness, 0), 1))
        // A zero-length gap is a solid line; drop the dash array entirely at that point
        let style = gap < 0.05
            ? StrokeStyle(lineWidth: lineWidth, lineCap: .round)
            : StrokeStyle(lineWidth: lineWidth, lineCap: .round, dash: [dash, gap])
        let edge = RoundedRectangle(cornerRadius: cornerRadius).path(in: rect)
        var outline = edge.strokedPath(style)
        // A dashed stroke stops wherever its own pattern happens to fall, which can be a whole
        // dash gap short of the cut. Rasterising the real path measured 9.75pt of clearance on
        // the left of the switcher against 6.06pt on the right, out of a cut that is symmetric
        // to 0.06pt — the cut was never the asymmetry, the dash phase was. The clearance the
        // design asks for only holds if the ink actually reaches the cut, so one dash of solid
        // stroke is pinned to each cut edge first. The solid panel needs none of this, and
        // skipping it there also skips the path ops.
        if gap >= 0.05 {
            let solid = edge.strokedPath(StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
            for cap in capRects(in: rect) {
                // The RECT has to be the receiver. `Path.intersection` is not commutative
                // here — a stroked outline carries two nested contours, and asking IT to
                // intersect the rect treats its whole interior as inside, which came back
                // as the full rect: measured at 8x as a square block over the corner arc,
                // drawing the terminating dash at nearly twice the line width.
                outline = outline.union(Path(cap).intersection(solid))
            }
        }
        for cut in cuts(in: rect) {
            outline = outline.subtracting(Path(cut))
        }
        return outline
    }

    /// The runs of stroke that flank each cut, one dash long so the dash that terminates at
    /// the label matches the rest of the pattern. Each run reaches a line width INTO the cut,
    /// so subtracting the cut afterwards leaves a clean face rather than an antialiased sliver.
    private func capRects(in rect: CGRect) -> [CGRect] {
        cuts(in: rect).flatMap { cut in
            [
                CGRect(x: cut.minX - dash, y: cut.minY, width: dash + lineWidth, height: cut.height),
                CGRect(x: cut.maxX - lineWidth, y: cut.minY, width: dash + lineWidth, height: cut.height),
            ]
        }
    }

    /// Straddles the edge by a full line width on each side, so the stroke terminates in a
    /// flat perpendicular face instead of the cut shaving only its inner half.
    private func cuts(in rect: CGRect) -> [CGRect] {
        var cuts: [CGRect] = []
        if let topGap, topGap.upperBound > topGap.lowerBound {
            cuts.append(
                CGRect(
                    x: rect.minX + topGap.lowerBound,
                    y: rect.minY - lineWidth,
                    width: topGap.upperBound - topGap.lowerBound,
                    height: lineWidth * 2
                )
            )
        }
        if bottomGapWidth > 0 {
            cuts.append(
                CGRect(
                    x: rect.midX - bottomGapWidth / 2,
                    y: rect.maxY - lineWidth,
                    width: bottomGapWidth,
                    height: lineWidth * 2
                )
            )
        }
        return cuts
    }
}

// Shared sizing for both panels, so switching between them never changes the row metrics
enum ShelfItemMetrics {
    static let spacing: CGFloat = 6
    static let cornerRadius: CGFloat = 10
    // Breathing room so strokes and shadows are not clipped by the scroll view
    static let verticalInset: CGFloat = 1

    /// Columns shown once the panel is expanded into a grid.
    static let gridColumns: Int = 4
    /// Rows shown once the panel is expanded into a grid.
    static let gridRows: Int = 3

    /// The tile side a single scrolling row takes from the height it is offered. This is what
    /// defines the tile size; the grid reuses it rather than deriving its own.
    static func rowTileSide(for size: CGSize) -> CGFloat {
        max(0, size.height - verticalInset * 2)
    }

    /// The grid keeps the collapsed tile size, so expanding only ever adds rows downwards.
    /// The only concession is a clamp so `gridColumns` columns still fit the width — without
    /// it the last column would be cut off. Deriving the size from the expanded height
    /// instead (height / rows) is what used to collapse 94pt tiles to 32pt.
    static func gridTileSide(pinned: CGFloat, width: CGFloat) -> CGFloat {
        let byWidth = (width - spacing * CGFloat(gridColumns - 1)) / CGFloat(gridColumns)
        guard pinned > 0 else { return max(0, byWidth) }
        return max(0, min(pinned, byWidth))
    }

    /// Extra island height needed to turn a single row of `tile` into `gridRows` rows.
    static func gridExpansion(forTile tile: CGFloat) -> CGFloat {
        CGFloat(gridRows - 1) * (tile + spacing)
    }

    static let panelPadding: CGFloat = 10

    /// Panel height that fits `rows` rows of `tile`. The panel needs this set explicitly:
    /// the island's extra height only reserves room in the window, it does not push a height
    /// down into the tab content, so without it the panel keeps its collapsed height and the
    /// rows have to shrink to fit.
    static func panelHeight(tile: CGFloat, rows: Int) -> CGFloat {
        tile * CGFloat(rows) + spacing * CGFloat(rows - 1) + verticalInset * 2 + panelPadding * 2
    }

    /// The drop zone keeps this height while the grid grows, otherwise its 1:1 aspect ratio
    /// would let it swallow half the panel's width.
    static func collapsedPanelHeight(tile: CGFloat) -> CGFloat {
        panelHeight(tile: tile, rows: 1)
    }

    /// The tile side a single row occupies inside a panel of `height`. Exact inverse of
    /// `panelHeight(tile:rows:)` at `rows == 1`, so deriving the collapsed tile from the
    /// panel's own height and then asking for `panelHeight` back is lossless.
    static func rowTileSide(forPanelHeight height: CGFloat) -> CGFloat {
        max(0, height - verticalInset * 2 - panelPadding * 2)
    }

    // A shelf tile carries a filename strip that a clipboard tile does not. Everything the
    // strip does not need belongs to the icon, so both panels read at the same visual weight.
    static let tilePadding: CGFloat = 6
    static let iconLabelSpacing: CGFloat = 3
    static let labelFontSize: CGFloat = 11
    static let labelLineCount: Int = 1

    static let labelHeight: CGFloat = {
        let font = NSFont.systemFont(ofSize: labelFontSize, weight: .medium)
        return ceil(font.ascender - font.descender + font.leading) * CGFloat(labelLineCount)
    }()

    static func iconSide(forTile side: CGFloat) -> CGFloat {
        max(0, side - tilePadding * 2 - labelHeight - iconLabelSpacing)
    }

    /// Requested at the largest icon a tall notch can produce, so a thumbnail is only ever
    /// downscaled. Asking for exactly the icon size would blur it on taller notches.
    static let thumbnailSide: CGFloat = iconSide(forTile: 120)
}

/// Backdrop shared by the hover action buttons in both panels. A blurred disc rather than a
/// flat tint, so the glyph stays legible over any tile content; the hairline and shadow keep
/// the edge separated where the blur and the content land at similar luminance.
struct HoverActionBackdrop: View {
    let tint: Color

    var body: some View {
        Circle()
            .fill(.regularMaterial)
            .overlay(Circle().fill(tint))
            .overlay(Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
    }
}

// The one scroller both the shelf and the clipboard history use. A single scrolling row
// while collapsed, the same tiles as a grid once the island is expanded.
struct ShelfItemStrip<Content: View>: View {
    let rows: Int
    /// The collapsed tile side, which the grid holds on to instead of re-deriving one
    let pinnedTileSide: CGFloat
    let scrollTargetID: AnyHashable?
    @ViewBuilder let content: (CGFloat) -> Content

    private var isGrid: Bool { rows > 1 }

    /// The tiles themselves, identical in both bisection branches so level 1 removes ONLY the
    /// ScrollView and nothing else.
    @ViewBuilder
    private func stack(tile: CGFloat) -> some View {
        Group {
            if isGrid {
                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(.fixed(tile), spacing: ShelfItemMetrics.spacing),
                        count: ShelfItemMetrics.gridColumns
                    ),
                    // Matches the collapsed row; the default centres the columns
                    // and leaves a wide empty gutter on both sides
                    alignment: .leading,
                    spacing: ShelfItemMetrics.spacing
                ) {
                    content(tile)
                }
            } else {
                HStack(spacing: ShelfItemMetrics.spacing) {
                    content(tile)
                }
            }
        }
        .padding(.vertical, ShelfItemMetrics.verticalInset)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The shipped scroller. Under BN_DIAG the bisection variants replace it.
    @ViewBuilder
    private func scroller(tile: CGFloat) -> some View {
#if BN_DIAG
        if ClipboardBisect.removes(9) {
            BisectExplicitPlacement(
                tile: tile,
                spacing: ShelfItemMetrics.spacing,
                columns: isGrid ? ShelfItemMetrics.gridColumns : 0
            ) { content(tile) }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if ClipboardBisect.removes(1) {
            stack(tile: tile)
        } else {
            ScrollView(isGrid ? .vertical : .horizontal) {
                stack(tile: tile)
            }
            .scrollIndicators(.never)
            .ownsScrolling(axis: isGrid ? .vertical : .horizontal)
        }
#else
        ScrollView(isGrid ? .vertical : .horizontal) {
            stack(tile: tile)
        }
        .scrollIndicators(.never)
        .ownsScrolling(axis: isGrid ? .vertical : .horizontal)
#endif
    }

    var body: some View {
        GeometryReader { geo in
            let tile = isGrid
                ? ShelfItemMetrics.gridTileSide(pinned: pinnedTileSide, width: geo.size.width)
                : ShelfItemMetrics.rowTileSide(for: geo.size)
            ScrollViewReader { proxy in
                scroller(tile: tile)
                // The row -> grid swap replaces the container outright — a horizontal HStack
                // becomes a vertical LazyVGrid — so there is nothing to interpolate between.
                // Animating it cross-fades two incompatible layouts, which is the "off and
                // buggy" look. Snapping the layout lets the panel's height animation carry
                // the motion and simply reveal the extra rows.
                .animation(nil, value: rows)
                // Carry the reading position across the layout change instead of jumping home
                .onChange(of: rows) { _, _ in
                    guard let scrollTargetID else { return }
                    withAnimation(.smooth(duration: 0.25)) {
                        proxy.scrollTo(scrollTargetID, anchor: isGrid ? .top : .leading)
                    }
                }
            }
        }
    }
}

struct ShelfView: View {
    @EnvironmentObject var vm: BoringViewModel
    @StateObject var tvm = ShelfStateViewModel.shared
    @StateObject var selection = ShelfSelectionModel.shared
    @StateObject private var quickLookService = QuickLookService()
    @ObservedObject private var routing = TabRoutingManager.shared
    @Default(.clipboardHistoryEnabled) private var clipboardHistoryEnabled: Bool
    @ObservedObject private var coordinator = BoringViewCoordinator.shared
    @ObservedObject private var clipboard = ClipboardManager.shared
    @Default(.shelfGridExpanded) private var gridExpanded: Bool
    @State private var switcherWidth: CGFloat = 0
    @State private var expanderWidth: CGFloat = 0
    @State private var collapsedTileSide: CGFloat = 0
    /// Last height the panel was OFFERED, recorded unconditionally. Separate from the
    /// interpretation below, for the reason spelled out in `commitCollapsedTile`.
    @State private var measuredPanelHeight: CGFloat = 0
    /// Suppresses collapsed-height sampling while a toggle is still animating
    @State private var gridTransitionActive = false
    /// False until the island has finished its initial sizing, so a restored grid snaps to
    /// size on appear while later changes animate
    @State private var islandSettled = false
    /// Lit while the pointer is on the grid expander, so the target can show its real extent
    @State private var expanderHovering = false
    // Chrome-free, so the row is short enough to sit centred on the stroke and still clear
    // the physical notch above it — only half of it rises into the 8pt gap under the header
    private let toggleHeight: CGFloat = 14
    private let toggleInset: CGFloat = 18
    private let borderLineWidth: CGFloat = 3
    // Breathing room between the label and the two cut ends of the stroke
    private let borderGapPadding: CGFloat = 6

    /// How far the grid expander reaches above and below the panel's bottom stroke.
    ///
    /// These are the whole hit box, because `.contentShape(Rectangle().inset(by: -5))` never
    /// widened it: measured with synthesized clicks, a Button's interactive region is its
    /// label's LAYOUT frame and a negative inset is ignored — an identical control with and
    /// without the modifier hit-tested over exactly the same 14pt. (The `Rectangle()` itself
    /// is not pointless: strip it entirely and the Button hit-tests the chevron's INK, about
    /// 5pt of it. So the shape matters and the inset does not.) The target can therefore only
    /// grow by growing the layout, which is what these do.
    ///
    /// The rise is unchanged. Going further up would put the control over the first row of
    /// tiles, which it already overlaps by 7pt of the panel's 10pt inner padding. The drop
    /// instead takes the 12pt of empty island that ContentView's `.padding(.bottom, 12)`
    /// leaves under the panel — measured, and the only thing that wants that ground is the
    /// island's own tap-to-open. The hit box now ends where the island does rather than 5pt
    /// short of it, which is what `hoverGraceBelowIsland` then extends.
    private let expanderRise: CGFloat = 7
    private let expanderDrop: CGFloat = 12
    private var expanderHeight: CGFloat { expanderRise + expanderDrop }

    private var activePanel: ShelfPanel {
        routing.activePanel
    }

    private var showsClipboardPanel: Bool {
        clipboardHistoryEnabled && activePanel == .clipboard
    }

    /// What is actually ON SCREEN, which on the clipboard side is not `items`: pinned entries
    /// keep their place in the history, so `items` stays a superset of the pinned page. Count
    /// the superset and the chevron gets offered on a pinned page of four with a history of
    /// forty, and expanding it shows two empty rows.
    private var visibleItemCount: Int {
        showsClipboardPanel ? clipboard.visibleItems.count : tvm.items.count
    }

    /// Expanding a near-empty panel into three rows would just show empty space. The
    /// collapsed-height term is a fail-safe: with no measured height there is no correct
    /// size to expand TO, so the chevron is simply not offered rather than expanding by
    /// `gridExpansion(forTile: 0)` = 12pt and squeezing three rows into one row's height.
    private var canExpandToGrid: Bool {
        visibleItemCount > ShelfItemMetrics.gridColumns && collapsedTileSide > 0
    }

    /// The preview owns the island while it is up, so the grid stands down
    private var isGridExpanded: Bool {
        gridExpanded && canExpandToGrid && coordinator.clipboardPreviewEntry == nil
    }

    private var rows: Int { isGridExpanded ? ShelfItemMetrics.gridRows : 1 }

    /// Square drop zone, pinned to the collapsed row height so the grid grows around it
    private var dropZoneHeight: CGFloat? {
        collapsedTileSide > 0 ? ShelfItemMetrics.collapsedPanelHeight(tile: collapsedTileSide) : nil
    }

    /// Height the panel needs for `gridRows` rows at the collapsed tile size. Nil while
    /// collapsed, so the panel is free to take the island's natural height — that is what
    /// measures `collapsedTileSide` in the first place.
    private var gridPanelHeight: CGFloat? {
        guard isGridExpanded, collapsedTileSide > 0 else { return nil }
        return ShelfItemMetrics.panelHeight(tile: collapsedTileSide, rows: ShelfItemMetrics.gridRows)
    }

    /// The break the switcher label sits in, or nil while there is no switcher to make room for
    private var switcherGap: ClosedRange<CGFloat>? {
        guard clipboardHistoryEnabled, switcherWidth > 0 else { return nil }
        let start = toggleInset - borderGapPadding
        return start...(start + switcherWidth + borderGapPadding * 2)
    }

    private var expanderGap: CGFloat {
        canExpandToGrid && expanderWidth > 0 ? expanderWidth + borderGapPadding * 2 : 0
    }

    /// One curve for the border, the panel swap and the grid expansion. Deliberately NOT
    /// `vm.animation` (`.spring(.bouncy(duration: 0.4))`): the transaction override on the
    /// panel replaces EVERY animation inside that subtree with it, so the bounce was
    /// overshooting a 200pt grid expansion — reported as "really really aggressive" — and
    /// making the panel swap read as sluggish even though its call site asks for 0.2s.
    private var panelAnimation: Animation { .smooth(duration: 0.3) }

    private var borderColor: Color {
        vm.dragDetectorTargeting && !showsClipboardPanel
            ? Color.notchHighlight.opacity(0.9)
            : Color.white.opacity(0.1)
    }

    var body: some View {
        // Top-aligned so the drop zone stays beside the panel's first row as the grid grows
        HStack(alignment: .top, spacing: 12) {
#if BN_DIAG
            if !ClipboardBisect.removes(3) {
                FileShareView()
                    .aspectRatio(1, contentMode: .fit)
                    .frame(maxHeight: dropZoneHeight, alignment: .top)
                    .environmentObject(vm)
            }
#else
            FileShareView()
                .aspectRatio(1, contentMode: .fit)
                .frame(maxHeight: dropZoneHeight, alignment: .top)
                .environmentObject(vm)
#endif
            panel
                // Grows the panel downwards only; the drop zone beside it stays pinned
                // #53 bisection level 5, second half: the panel's explicit height
                #if BN_DIAG
                .frame(height: ClipboardBisect.removes(5) ? nil : gridPanelHeight)
#else
                .frame(height: gridPanelHeight)
#endif
                // The collapsed tile side is DERIVED from the height the island actually
                // hands the panel, measured right here. It used to be published up out of
                // the strip through a `TileSideKey` preference, which arrived as 0 in the
                // running app — so `gridExpansion` asked for 12pt instead of 204pt and
                // `gridPanelHeight` stayed nil, leaving three rows to squeeze into one
                // row's height. A derived value cannot be zero.
                .background(
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear { recordPanelHeight(proxy.size) }
                            .onChange(of: proxy.size) { _, size in recordPanelHeight(size) }
                    }
                )
                .onDrop(of: [.fileURL, .url, .utf8PlainText, .plainText, .data],
                        isTargeted: $vm.dragDetectorTargeting) { providers in
                    guard !showsClipboardPanel else { return false }
                    return handleDrop(providers: providers)
                }
        }
        // `shelfGridExpanded` is PERSISTED, so the grid can come back up on launch — or when
        // the island reopens — without `toggleGrid()` ever running. `shelfGridExpansion`,
        // which is what actually sizes the window, was only ever written there, so the panel
        // would ask for three rows inside an island that never grew and overflow it.
        .onAppear {
            syncIslandExpansion(animated: false)
            // Anything after the initial settle is a change the user is WATCHING. The
            // measurement that flips `isGridExpanded` on a restored grid lands on the first
            // layout pass or two, so this window separates "arrive at the right size" from
            // "animate to a new one".
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(350))
                islandSettled = true
            }
        }
        .onChange(of: isGridExpanded) { _, _ in
            syncIslandExpansion(animated: islandSettled)
            // Collapsing lifts the guard that was blocking interpretation. If `sync` armed a
            // suppression window this no-ops and the retry at the end of that window does it.
            commitCollapsedTile()
        }
        // Leaving the shelf tab, or closing the island, must not leave it sized for a grid
        // that is no longer on screen.
        //
        // This hook is LATE by design of SwiftUI, not by accident: measured under a real run
        // loop, it does not fire until ~840ms after the tab switch, because the outgoing
        // branch of the tab's `_ConditionalContent` is held for that long — and an `onChange`
        // here never fires at all, since a view on its way out stops receiving its observed
        // object. So this can only ever be the backstop for an unmount no one else saw
        // (the island closing). #42 — the island staying 204pt too tall while Home is laid
        // out inside it — has to be handed back where the tab actually changes; see the
        // report. Animating it at least turns a 204pt single-frame snap into a shrink.
        .onDisappear {
            guard coordinator.shelfGridExpansion != 0 else { return }
            // Only when the island is STAYING open: a tab switch drops ~200pt out from under
            // a cursor still resting on the island, exactly as a chevron collapse does. On a
            // close the cover is pointless and would leave `closeGraceActive` armed for 800ms
            // into an island that has already gone.
            if vm.notchState == .open { vm.beginCloseGrace() }
            withAnimation(panelAnimation) {
                coordinator.shelfGridExpansion = 0
            }
        }
        // Losing the grid (items deleted, or a switch to a panel with too few) must hand the
        // island's extra height back, or it stays tall around an empty band
        .onChange(of: canExpandToGrid) { _, canExpand in
            guard !canExpand, coordinator.shelfGridExpansion != 0 else { return }
            // Same unrequested shrink as the chevron, so it needs the same cover
            vm.beginCloseGrace()
            suppressCollapsedSampling()
            withAnimation(panelAnimation) {
                coordinator.shelfGridExpansion = 0
            }
        }
        // Bind Quick Look to shelf selection
        .onChange(of: selection.selectedIDs) {
            updateQuickLookSelection()
        }
        .quickLookPresenter(using: quickLookService)
    }
    
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard !selection.isDragging else { return false }
        vm.dropEvent = true
        ShelfStateViewModel.shared.load(providers)
        return true
    }
    
    private func updateQuickLookSelection() {
        guard quickLookService.isQuickLookOpen && !selection.selectedIDs.isEmpty else { return }
        
        let selectedItems = selection.selectedItems(in: tvm.items)
        let urls: [URL] = selectedItems.compactMap { item in
            if let fileURL = item.fileURL {
                return fileURL
            }
            if case .link(let url) = item.kind {
                return url
            }
            return nil
        }
        
        if !urls.isEmpty {
            quickLookService.updateSelection(urls: urls)
        }
    }

    var panel: some View {
#if BN_DIAG
        diagnosticPanel
#else
        shippedPanel
#endif
    }

    /// The panel exactly as it ships — no #53 gates in this chain at all.
    private var shippedPanel: some View {
        PanelBorder(
            solidness: showsClipboardPanel ? 1 : 0,
            lineWidth: borderLineWidth,
            topGap: switcherGap,
            bottomGapWidth: expanderGap
        )
            .fill(borderColor)
            // Scoped to the BORDER alone, deliberately. Sitting after the content overlay it
            // reached every change inside the panel — including the cells `LazyVGrid`
            // materialises lazily as the user scrolls, so each newly loaded tile animated in
            // over 0.3s. Lazy materialisation is not a state change and must not animate.
            .transaction { transaction in
                transaction.animation = panelAnimation
            }
            .overlay {
                panelContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(ShelfItemMetrics.panelPadding)
            }
            .contentShape(Rectangle())
            // The panel's own padding reads as empty island surface, so pin from here too
            .onTapGesture(count: 2) {
                vm.togglePinned()
            }
            .onTapGesture {
                if !showsClipboardPanel { selection.clear() }
            }
            // Drawn on the stroke and outside the layout flow, so swapping panels cannot reflow it
            .overlay(alignment: .topLeading) {
                // With clipboard history off there is only one panel, so the switcher is pointless
                if clipboardHistoryEnabled {
                    panelToggle
                }
            }
            // Same treatment as the switcher, on the opposite edge
            .overlay(alignment: .bottom) {
                if canExpandToGrid {
                    gridExpander
                }
            }
    }

    /// The panel's contents, shared by both variants so a level cannot change them.
    @ViewBuilder
    private var panelContent: some View {
        if showsClipboardPanel {
            ClipboardHistoryView(rows: rows, pinnedTileSide: collapsedTileSide)
        } else {
            content
        }
    }

#if BN_DIAG
    private var diagnosticPanel: some View {
        // #53 bisection level 2: the border shape itself, plus the switcher and grid-expander
        // overlays drawn on it. The CONTENT stays, so this removes the panel chrome and
        // nothing else.
        Group {
            if ClipboardBisect.removes(2) {
                Color.clear
            } else {
                PanelBorder(
                    solidness: showsClipboardPanel ? 1 : 0,
                    lineWidth: borderLineWidth,
                    topGap: switcherGap,
                    bottomGapWidth: expanderGap
                )
                    .fill(borderColor)
                    // Scoped to the BORDER alone, deliberately. Sitting after the content overlay it
                    // reached every change inside the panel — including the cells `LazyVGrid`
                    // materialises lazily as the user scrolls, so each newly loaded tile animated in
                    // over 0.3s. Lazy materialisation is not a state change and must not animate.
                    .transaction { transaction in
                        transaction.animation = panelAnimation
                    }
            }
        }
            .overlay {
                panelContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // #53 bisection level 5, first half: the panel's inner padding
                .padding(ClipboardBisect.removes(5) ? 0 : ShelfItemMetrics.panelPadding)
            }
            // #53 bisection level 4b
            .modifier(BisectableContentShape())
            // The panel's own padding reads as empty island surface, so pin from here too
            // #53 bisection level 4a
            .modifier(BisectablePanelTaps(vm: vm, selection: selection, showsClipboardPanel: showsClipboardPanel))
            // Drawn on the stroke and outside the layout flow, so swapping panels cannot reflow it
            .overlay(alignment: .topLeading) {
                // With clipboard history off there is only one panel, so the switcher is pointless
                if clipboardHistoryEnabled, !ClipboardBisect.removes(2) {
                    panelToggle
                }
            }
            // Same treatment as the switcher, on the opposite edge
            .overlay(alignment: .bottom) {
                if canExpandToGrid, !ClipboardBisect.removes(2) {
                    gridExpander
                }
            }
    }
#endif

    private var gridExpander: some View {
        Button(action: toggleGrid) {
            Image(systemName: isGridExpanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(expanderHovering ? Color.white : Color.gray)
                .frame(height: expanderHeight)
                .padding(.horizontal, 14)
                // At rest the target is a 10pt glyph in a box twice its height and four times
                // its width, so nothing on screen says where it ends — which is the half of
                // the complaint that a bigger INVISIBLE hit box cannot answer. The backdrop
                // shows the real extent as soon as the pointer is on it, in the same
                // capsule-on-hover vocabulary `HoverButton` already uses.
                .background {
                    Capsule().fill(expanderHovering ? Color.gray.opacity(0.2) : .clear)
                }
                .background {
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear { setExpanderWidth(proxy.size.width) }
                            .onChange(of: proxy.size.width) { _, width in setExpanderWidth(width) }
                    }
                }
                // Loses the `.inset(by: -5)`, which measured as inert. The `Rectangle()` stays:
                // without it the Button hit-tests the chevron's ink instead of its frame.
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { expanderHovering = $0 }
        .animation(.easeOut(duration: 0.15), value: expanderHovering)
        // Bottom edge of the control to the bottom edge of the island. `.overlay(alignment:
        // .bottom)` puts it flush with the panel's stroke; the offset carries it down by the
        // island's own bottom padding, leaving `expanderRise` of it above the stroke.
        .offset(y: expanderDrop)
    }

    private func toggleGrid() {
        let expanding = !isGridExpanded
        let extra = expanding ? ShelfItemMetrics.gridExpansion(forTile: collapsedTileSide) : 0
        // Grow the window first; the island then animates inside a window that is no longer
        // changing size underneath it
        if expanding { coordinator.prepareIslandExpansion(extra) }
        // Collapsing drops the island ~200pt out from under the cursor, so the hover-exit
        // that follows must not be read as the user having left
        if !expanding { vm.beginCloseGrace() }
        suppressCollapsedSampling()
        DispatchQueue.main.async {
            withAnimation(panelAnimation) {
                gridExpanded = expanding
                coordinator.shelfGridExpansion = extra
            }
        }
    }

    private func setSwitcherWidth(_ width: CGFloat) {
        guard abs(switcherWidth - width) > 0.5 else { return }
        switcherWidth = width
    }

    private func setExpanderWidth(_ width: CGFloat) {
        guard abs(expanderWidth - width) > 0.5 else { return }
        expanderWidth = width
    }

    /// Brings the island's extra height in line with whether the grid is actually showing.
    /// Deliberately unanimated: this runs on appear and on state restored from disk, where
    /// the right behaviour is to already BE the correct size, not to grow into it.
    private func syncIslandExpansion(animated: Bool) {
        let needed = isGridExpanded
            ? ShelfItemMetrics.gridExpansion(forTile: collapsedTileSide)
            : 0
        guard abs(coordinator.shelfGridExpansion - needed) > 0.5 else { return }
        // Grow the window a runloop turn BEFORE the animated change, exactly as `toggleGrid`
        // does. Without the gap the island lurches as content is laid out inside a window
        // that already grew underneath it.
        if needed > 0 { coordinator.prepareIslandExpansion(needed) }
        guard animated else {
            coordinator.shelfGridExpansion = needed
            return
        }
        // Same reason as `toggleGrid`: the panel's height is about to animate, and a height
        // caught mid-flight is not the collapsed one
        suppressCollapsedSampling()
        DispatchQueue.main.async {
            withAnimation(panelAnimation) {
                coordinator.shelfGridExpansion = needed
            }
        }
    }

    /// Holds off INTERPRETING the panel's height while it is changing between the collapsed
    /// and grid sizes. Belt-and-braces as things stand — the read is final-only, so there is
    /// no intermediate height to catch — but it costs nothing and still earns its keep if the
    /// read ever becomes per-frame.
    ///
    /// It must retry on the way out. This window used to gate the READ, and the read fires
    /// once per distinct size and never again, so a report landing inside the window was not
    /// deferred, it was LOST: `proxy.size` never changes back, so nothing re-triggers it.
    private func suppressCollapsedSampling() {
        gridTransitionActive = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            gridTransitionActive = false
            commitCollapsedTile()
        }
    }

    /// Observation. Deliberately unguarded: the height the panel is offered is a fact, and
    /// the read that delivers it gets exactly one chance to do so.
    private func recordPanelHeight(_ size: CGSize) {
        guard abs(size.height - measuredPanelHeight) > 0.5 else { return }
        measuredPanelHeight = size.height
        commitCollapsedTile()
    }

    /// Interpretation, retryable. Split from the observation above because every guard here
    /// used to gate the READ, and `onChange(of: proxy.size)` fires once per distinct size and
    /// then never again — measured: an animated height change from 322 to 118 reported `118`
    /// once, at 8ms, and nothing further. A guard standing at that instant therefore threw the
    /// value away permanently rather than postponing it. Whatever was last observed is kept,
    /// so whenever a guard drops, the answer can simply be worked out again.
    private func commitCollapsedTile() {
        guard !isGridExpanded, !gridTransitionActive, measuredPanelHeight > 0 else { return }
        // Take the COLLAPSED height, not just the offered one. The panel takes the island's
        // natural height whenever it is not asking for a grid, so if the island is tall for a
        // reason of its own — a grid height still booked while the panel has not decided to
        // show one — the offered height is a grid's, and reading it as a row's would latch a
        // ~300pt tile. Subtracting what is already booked leaves a row's height in every case,
        // and is a no-op in the ordinary one, where nothing is booked.
        let collapsedHeight = measuredPanelHeight - max(0, coordinator.shelfGridExpansion)
        let side = ShelfItemMetrics.rowTileSide(forPanelHeight: collapsedHeight)
        guard side > 0, abs(side - collapsedTileSide) > 0.5 else { return }
        collapsedTileSide = side
    }

    private var panelToggle: some View {
        HStack(spacing: 12) {
            panelButton("Shelf", icon: "tray.fill", panel: .shelf)
            panelButton("Clipboard", icon: "doc.on.clipboard", panel: .clipboard)
        }
        // Deliberately SHORTER than what it contains, now that the buttons carry padding: the
        // 24pt of button centres itself in this 14pt frame and overflows it symmetrically, so
        // the row below still measures the stroke's own height and the offset below still
        // lands the labels centred on the stroke. Sizing this to the content instead would
        // push the whole switcher down by half the padding.
        .frame(height: toggleHeight)
        // Written straight into `@State` rather than published through a `PreferenceKey`.
        // That transport is the one that delivered `collapsedTileSide` as 0.0 in the running
        // app, and a zero here silently returns nil from `switcherGap`, leaving the label
        // sitting on an unbroken stroke. This overlay belongs to the same view that owns the
        // state, so there is no reason to route the value through a preference at all.
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { setSwitcherWidth(proxy.size.width) }
                    .onChange(of: proxy.size.width) { _, width in setSwitcherWidth(width) }
            }
        }
        .offset(x: toggleInset, y: -toggleHeight / 2)
    }

    @ViewBuilder
    private func panelButton(_ label: String, icon: String, panel: ShelfPanel) -> some View {
        let isActive = activePanel == panel
        Button {
            withAnimation(.smooth(duration: 0.2)) { routing.selectPanel(panel) }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon).imageScale(.small)
                // The bold copy reserves the width, so changing weight cannot resize the gap
                Text(label)
                    .fontWeight(.semibold)
                    .opacity(0)
                    .overlay {
                        Text(label).fontWeight(isActive ? .semibold : .medium)
                    }
            }
            .font(.caption)
            .foregroundStyle(isActive ? Color.white : Color.gray)
            // No pill to aim at, so the target has to be grown in the LAYOUT — there is no
            // way to widen it without touching the layout, which is what the line here used
            // to claim. A Button's interactive region is its label's layout frame, and a
            // NEGATIVE `contentShape` inset is ignored: measured twice over, once by
            // hit-testing (the same control with and without `.inset(by: -5)` hit-tested the
            // identical 14pt band) and once by layout (adding or removing it moved the
            // measured switcher width by 0.000pt). It was buying nothing.
            //
            // The `Rectangle()` is NOT dead weight, so do not follow that reasoning one step
            // further and delete the whole modifier: strip it and the Button falls back to
            // hit-testing the label's INK, which for a bare glyph measured about 5pt. Shape
            // load-bearing, inset inert.
            //
            // This padding is what widens `switcherWidth`, which feeds `switcherGap` and so
            // the cut in the top border: 128.50 -> 148.50pt, accepted by the user along with
            // the label gap growing 12 -> 22pt.
            .padding(5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    var content: some View {
        Group {
            if tvm.isEmpty {
                NotchEmptyState(icon: "tray.and.arrow.down", message: "Drop files here")
            } else {
                ShelfItemStrip(rows: rows, pinnedTileSide: collapsedTileSide, scrollTargetID: tvm.items.first?.id) { side in
                    ForEach(tvm.items) { item in
                        ShelfItemView(item: item, tileSize: side)
                            .environmentObject(quickLookService)
                            .id(item.id)
                    }
                }
                // Named explicitly, since the panel no longer supplies an ambient animation:
                // a real change to the item list still animates, lazy loading still does not
                .animation(.smooth(duration: 0.25), value: tvm.items.map(\.id))
                .onDrop(of: [.fileURL, .url, .utf8PlainText, .plainText, .data], isTargeted: $vm.dragDetectorTargeting) { providers in
                    handleDrop(providers: providers)
                }
            }
        }
        .onAppear {
            ShelfStateViewModel.shared.cleanupInvalidItems()
        }
    }
}

#if BN_DIAG
/// #53 bisection level 4b: the panel's `contentShape`.
private struct BisectableContentShape: ViewModifier {
    func body(content: Content) -> some View {
        if ClipboardBisect.removes4("b") {
            content
        } else {
            content.contentShape(Rectangle())
        }
    }
}

/// #53 bisection level 4a: the panel's two tap gestures.
private struct BisectablePanelTaps: ViewModifier {
    let vm: BoringViewModel
    let selection: ShelfSelectionModel
    let showsClipboardPanel: Bool

    func body(content: Content) -> some View {
        if ClipboardBisect.removes4("a") {
            content
        } else {
            content
                .onTapGesture(count: 2) {
                    vm.togglePinned()
                }
                .onTapGesture {
                    if !showsClipboardPanel { selection.clear() }
                }
        }
    }
}

#endif

#if BN_DIAG
/// #53 bisection level 9. Places each tile at an origin computed directly from its index,
/// with no stack container deciding where children go.
///
/// A `Layout` rather than a `ZStack` of `.offset`s because `ShelfItemStrip` receives its tiles
/// as an opaque `@ViewBuilder` closure and cannot index into them at the call site; `Layout`
/// hands them over as `Subviews`, which is the only place the index exists. Each child is
/// placed and proposed exactly `tile` square, so nothing is inferred from a sibling.
private struct BisectExplicitPlacement: Layout {
    let tile: CGFloat
    let spacing: CGFloat
    /// 0 for a single row; otherwise the column count of the grid.
    let columns: Int

    private func origin(_ index: Int) -> CGPoint {
        let pitch = tile + spacing
        guard columns > 0 else { return CGPoint(x: CGFloat(index) * pitch, y: 0) }
        return CGPoint(x: CGFloat(index % columns) * pitch,
                       y: CGFloat(index / columns) * pitch)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let last = origin(subviews.count - 1)
        return CGSize(width: last.x + tile, height: last.y + tile)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for index in subviews.indices {
            let o = origin(index)
            subviews[index].place(
                at: CGPoint(x: bounds.minX + o.x, y: bounds.minY + o.y),
                proposal: ProposedViewSize(width: tile, height: tile)
            )
        }
    }
}

#endif
