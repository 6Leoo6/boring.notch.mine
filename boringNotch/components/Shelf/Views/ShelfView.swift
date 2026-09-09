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
struct PanelBorder: Shape {
    var solidness: CGFloat
    var cornerRadius: CGFloat = 16
    var lineWidth: CGFloat = 3
    var dash: CGFloat = 10

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
        return RoundedRectangle(cornerRadius: cornerRadius)
            .path(in: rect)
            .strokedPath(style)
    }
}

private struct SwitcherWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

// Shared sizing for both panels, so switching between them never changes the row metrics
enum ShelfItemMetrics {
    static let spacing: CGFloat = 6
    static let cornerRadius: CGFloat = 10
    // Breathing room so strokes and shadows are not clipped by the scroll view
    static let verticalInset: CGFloat = 1

    static func tileSide(for height: CGFloat) -> CGFloat {
        max(0, height - verticalInset * 2)
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

// The one horizontal scroller both the shelf and the clipboard history use. Hands its
// children the square tile side derived from the available height.
struct ShelfItemStrip<Content: View>: View {
    @ViewBuilder let content: (CGFloat) -> Content

    var body: some View {
        GeometryReader { geo in
            ScrollView(.horizontal) {
                HStack(spacing: ShelfItemMetrics.spacing) {
                    content(ShelfItemMetrics.tileSide(for: geo.size.height))
                }
                .padding(.vertical, ShelfItemMetrics.verticalInset)
            }
            .scrollIndicators(.never)
            .ownsHorizontalScrolling()
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
    @State private var switcherWidth: CGFloat = 0
    // Chrome-free, so the row is short enough to sit centred on the stroke and still clear
    // the physical notch above it — only half of it rises into the 8pt gap under the header
    private let toggleHeight: CGFloat = 14
    private let toggleInset: CGFloat = 18
    private let borderLineWidth: CGFloat = 3
    // Breathing room between the label and the two cut ends of the stroke
    private let borderGapPadding: CGFloat = 6

    private var activePanel: ShelfPanel {
        routing.activePanel
    }

    private var showsClipboardPanel: Bool {
        clipboardHistoryEnabled && activePanel == .clipboard
    }

    private var borderColor: Color {
        vm.dragDetectorTargeting && !showsClipboardPanel
            ? Color.accentColor.opacity(0.9)
            : Color.white.opacity(0.1)
    }

    var body: some View {
        HStack(spacing: 12) {
            FileShareView()
                .aspectRatio(1, contentMode: .fit)
                .environmentObject(vm)
            panel
                .onDrop(of: [.fileURL, .url, .utf8PlainText, .plainText, .data], isTargeted: $vm.dragDetectorTargeting) { providers in
                    guard !showsClipboardPanel else { return false }
                    return handleDrop(providers: providers)
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
        PanelBorder(solidness: showsClipboardPanel ? 1 : 0, lineWidth: borderLineWidth)
            .fill(borderColor)
            // Cut the switcher out of the stroke so the label sits in a real gap in the line
            // rather than a chip painted over it
            .overlay(alignment: .topLeading) {
                if clipboardHistoryEnabled, switcherWidth > 0 {
                    // Square-ended, so the stroke terminates in a flat perpendicular face at
                    // each side of the label. A capsule would taper the cut into a curve.
                    Rectangle()
                        .fill(.black)
                        .frame(width: switcherWidth + borderGapPadding * 2, height: borderLineWidth * 2)
                        .offset(x: toggleInset - borderGapPadding, y: -borderLineWidth)
                        .blendMode(.destinationOut)
                }
            }
            .compositingGroup()
            .overlay {
                Group {
                    if showsClipboardPanel {
                        ClipboardHistoryView()
                    } else {
                        content
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(10)
            }
            .transaction { transaction in
                transaction.animation = vm.animation
            }
            .contentShape(Rectangle())
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
            .onPreferenceChange(SwitcherWidthKey.self) { switcherWidth = $0 }
    }

    private var panelToggle: some View {
        HStack(spacing: 12) {
            panelButton("Shelf", icon: "tray.fill", panel: .shelf)
            panelButton("Clipboard", icon: "doc.on.clipboard", panel: .clipboard)
        }
        .frame(height: toggleHeight)
        .background {
            GeometryReader { geo in
                Color.clear.preference(key: SwitcherWidthKey.self, value: geo.size.width)
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
            // No pill to aim at, so widen the hit target without touching the layout
            .contentShape(Rectangle().inset(by: -5))
        }
        .buttonStyle(.plain)
    }

    var content: some View {
        Group {
            if tvm.isEmpty {
                NotchEmptyState(icon: "tray.and.arrow.down", message: "Drop files here")
            } else {
                ShelfItemStrip { side in
                    ForEach(tvm.items) { item in
                        ShelfItemView(item: item, tileSize: side)
                            .environmentObject(quickLookService)
                    }
                }
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
