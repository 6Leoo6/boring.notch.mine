//
//  ClipboardPreviewPanel.swift
//  boringNotch
//

import AppKit
import SwiftUI

struct ClipboardPreviewPanel: View {
    let entry: ClipboardEntry
    let onDismiss: () -> Void
    @State private var didCopy = false

    var body: some View {
        // No background — the black island surface is the background.
        // A 0.5pt separator is drawn by the caller above this panel.
        ZStack(alignment: .topTrailing) {
            contentView
                .padding(.leading, 10)
                .padding(.trailing, 56)
                .padding(.vertical, 8)

            HStack(spacing: 6) {
                Button {
                    ClipboardManager.shared.copy(entry)
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { didCopy = true }
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        withAnimation(.easeOut(duration: 0.25)) { didCopy = false }
                    }
                } label: {
                    Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                        .font(.caption2)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.white.opacity(0.13)))
                        .foregroundStyle(didCopy ? Color.green : Color.white.opacity(0.75))
                        .animation(.spring(response: 0.3), value: didCopy)
                }
                .buttonStyle(.plain)

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.caption2)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.white.opacity(0.13)))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
            .padding(8)
        }
    }

    @ViewBuilder
    private var contentView: some View {
        switch entry.content {
        case .text(let str):
            ScrollView {
                Text(str)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.88))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .image(let img):
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .fileURLs(let urls) where urls.isEmpty:
            Text("No files")
                .font(.caption)
                .foregroundStyle(.gray)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .fileURLs(let urls):
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(urls, id: \.absoluteString) { url in
                        HStack(spacing: 6) {
                            Image(nsImage: ClipboardFileIcon.image(for: url))
                                .resizable()
                                .interpolation(.high)
                                .frame(width: 16, height: 16)
                            Text(url.lastPathComponent)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.85))
                                .lineLimit(1)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
