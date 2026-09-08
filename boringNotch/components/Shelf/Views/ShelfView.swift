//
//  ShelfItemView.swift
//  boringNotch
//
//  Created by Alexander on 2025-09-24.
//

import SwiftUI
import AppKit
import Defaults

private enum ShelfPanel {
    case files, clipboard
}

struct ShelfView: View {
    @EnvironmentObject var vm: BoringViewModel
    @StateObject var tvm = ShelfStateViewModel.shared
    @StateObject var selection = ShelfSelectionModel.shared
    @StateObject private var quickLookService = QuickLookService()
    @State private var activePanel: ShelfPanel = .files
    @Default(.clipboardHistoryEnabled) private var clipboardHistoryEnabled: Bool
    private let spacing: CGFloat = 8

    private var showsClipboardPanel: Bool {
        clipboardHistoryEnabled && activePanel == .clipboard
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
        RoundedRectangle(cornerRadius: 16)
            .stroke(
                vm.dragDetectorTargeting && !showsClipboardPanel
                    ? Color.accentColor.opacity(0.9)
                    : Color.white.opacity(0.1),
                style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [10])
            )
            .overlay {
                VStack(spacing: 5) {
                    // With clipboard history off there is only one panel, so the switcher is pointless
                    if clipboardHistoryEnabled {
                        panelToggle
                    }
                    Group {
                        if showsClipboardPanel {
                            ClipboardHistoryView()
                        } else {
                            content
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .padding(10)
            }
            .transaction { transaction in
                transaction.animation = vm.animation
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if !showsClipboardPanel { selection.clear() }
            }
    }

    private var panelToggle: some View {
        HStack(spacing: 2) {
            panelButton("Files", icon: "tray.fill", panel: .files)
            panelButton("Clipboard", icon: "doc.on.clipboard", panel: .clipboard)
        }
        .padding(3)
        .background(Capsule().fill(Color.white.opacity(0.06)))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func panelButton(_ label: String, icon: String, panel: ShelfPanel) -> some View {
        Button {
            withAnimation(.smooth(duration: 0.2)) { activePanel = panel }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon).imageScale(.small)
                Text(label).font(.caption).fontWeight(.medium)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(activePanel == panel ? Color.white.opacity(0.15) : Color.clear))
            .foregroundStyle(activePanel == panel ? Color.white : Color.gray)
        }
        .buttonStyle(.plain)
    }

    var content: some View {
        Group {
            if tvm.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "tray.and.arrow.down")
                        .symbolVariant(.fill)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.white, .gray)
                        .imageScale(.large)
                    
                    Text("Drop files here")
                        .foregroundStyle(.gray)
                        .font(.system(.title3, design: .rounded))
                        .fontWeight(.medium)
                }
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: spacing) {
                        ForEach(tvm.items) { item in
                            ShelfItemView(item: item)
                                .environmentObject(quickLookService)
                        }
                    }
                }
                .padding(-spacing)
                .scrollIndicators(.never)
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
