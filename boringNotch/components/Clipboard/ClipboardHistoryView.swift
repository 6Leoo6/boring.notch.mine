//
//  ClipboardHistoryView.swift
//  boringNotch
//

import AppKit
import Defaults
import SwiftUI

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

// MARK: - History view

struct ClipboardHistoryView: View {
    @ObservedObject var manager = ClipboardManager.shared
    @ObservedObject var coordinator = BoringViewCoordinator.shared

    var body: some View {
        Group {
            if manager.items.isEmpty {
                emptyState
            } else {
                TimelineView(.everyMinute) { context in
                    itemsRow(now: context.date)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 5) {
            Image(systemName: "clipboard")
                .imageScale(.large)
                .foregroundStyle(.gray.opacity(0.45))
            Text("Nothing copied yet")
                .font(.caption)
                .foregroundStyle(.gray.opacity(0.45))
        }
    }

    // MARK: - Items row

    private func itemsRow(now: Date) -> some View {
        GeometryReader { geo in
            let tileSize = geo.size.height
            HStack(spacing: 6) {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(manager.items) { entry in
                            ClipboardEntryTile(
                                entry: entry,
                                tileSize: tileSize,
                                timeLabel: relativeTime(from: entry.timestamp, now: now),
                                listVersion: manager.items.count
                            ) {
                                manager.copy(entry)
                            } onPreview: {
                                withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                                    coordinator.clipboardPreviewEntry = entry
                                }
                            } onDelete: {
                                withAnimation(.smooth) {
                                    manager.remove(id: entry.id)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 1)
                }
                .scrollIndicators(.never)

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
                .help("Clear clipboard history")
            }
        }
    }
}

// MARK: - Entry tile

private struct ClipboardEntryTile: View {
    let entry: ClipboardEntry
    let tileSize: CGFloat
    let timeLabel: String
    let listVersion: Int
    let onTap: () -> Void
    let onPreview: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false
    @State private var showHoverActions = false
    @State private var isCopied = false
    @State private var showDeleteConfirm = false
    @State private var hoverDelayTask: Task<Void, Never>?

    private var buttonSize: CGFloat { max(17, tileSize * 0.20) }

    var body: some View {
        Button(action: handleTap) {
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

                // Copied checkmark overlay
                if isCopied {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(.black.opacity(0.5))
                        .frame(width: tileSize, height: tileSize)
                    Image(systemName: "checkmark")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .transition(.scale.combined(with: .opacity))
                }
            }
        }
        .buttonStyle(.plain)
        // Action buttons sit in an overlay so they intercept their own taps
        // without the outer Button capturing them first
        .overlay {
            if showHoverActions && !isCopied {
                ZStack(alignment: .top) {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(.black.opacity(0.55))
                        .allowsHitTesting(false)

                    HStack(spacing: max(5, tileSize * 0.07)) {
                        // Preview / expand
                        Button(action: onPreview) {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 8))
                                .frame(width: buttonSize, height: buttonSize)
                                .background(Circle().fill(Color.white.opacity(0.18)))
                                .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                        .help("Preview")

                        // Delete
                        Button {
                            if Defaults[.clipboardDeleteConfirmEnabled] {
                                showDeleteConfirm = true
                            } else {
                                onDelete()
                            }
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 8))
                                .frame(width: buttonSize, height: buttonSize)
                                .background(Circle().fill(Color.red.opacity(0.28)))
                                .foregroundStyle(.red.opacity(0.9))
                        }
                        .buttonStyle(.plain)
                        .help("Delete")
                    }
                    .padding(.top, 5)
                }
                .frame(width: tileSize, height: tileSize)
                .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .top)))
            }
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) { isHovering = hovering }
            hoverDelayTask?.cancel()
            if hovering {
                // 220ms delay before buttons appear, reducing accidental taps
                hoverDelayTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(220))
                    guard !Task.isCancelled, isHovering else { return }
                    withAnimation(.easeInOut(duration: 0.12)) { showHoverActions = true }
                }
            } else {
                withAnimation(.easeInOut(duration: 0.1)) { showHoverActions = false }
            }
        }
        // When the list changes (item prepended/removed), tiles shift position but
        // onHover won't fire because the cursor didn't move. Reset hover state so
        // actions can't appear on a tile that has slid out from under the cursor.
        .onChange(of: listVersion) { _, _ in
            hoverDelayTask?.cancel()
            isHovering = false
            withAnimation(.easeInOut(duration: 0.1)) { showHoverActions = false }
        }
        .contextMenu {
            Button(role: .destructive) {
                if Defaults[.clipboardDeleteConfirmEnabled] {
                    showDeleteConfirm = true
                } else {
                    onDelete()
                }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .alert("Delete item?", isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) { onDelete() }
            Button("Delete, don't ask again", role: .destructive) {
                Defaults[.clipboardDeleteConfirmEnabled] = false
                onDelete()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This item will be removed from your clipboard history.")
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
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.07))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.1), lineWidth: 1))
            Text(String(text.prefix(300)))
                .font(.system(size: 8))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(5)
                .multilineTextAlignment(.leading)
                .padding(6)
        }
    }

    private func imageTile(_ image: NSImage) -> some View {
        Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: tileSize, height: tileSize)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.1), lineWidth: 1))
    }

    private func fileTile(_ urls: [URL]) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.07))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.1), lineWidth: 1))
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
    ClipboardHistoryView()
        .frame(width: 420, height: 90)
        .padding(12)
        .background(Color.black)
        .preferredColorScheme(.dark)
}
