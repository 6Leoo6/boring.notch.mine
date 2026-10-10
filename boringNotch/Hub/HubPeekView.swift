//
//  HubPeekView.swift
//  boringNotch
//

import AppKit
import SwiftUI

/// The peek that drops below the closed island when something arrives from another device,
/// in the slot and the type pairing of `MusicPeekView`: 11 semibold white over 9 at half white,
/// no container of its own (the island's black body is the ground). One addition the music
/// peek doesn't need: a leading icon, because "what arrived" is the point and the strip above
/// carries no artwork for it. While a transfer runs, a 2pt line under the text shows its
/// progress; it fills and goes when the transfer lands, and dims while the transfer is stalled.
struct HubPeekView: View {
    @ObservedObject var activity = HubActivity.shared
    var onTap: () -> Void = {}

    /// Same cap as the music peek's text column, for the same reason: past it the peek stops
    /// reading as something the island emitted.
    private static let maxTextColumn: CGFloat = 170
    private static let iconSide: CGFloat = 22
    private static let iconGap: CGFloat = 7

    private static let titleFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
    private static let subtitleFont = NSFont.systemFont(ofSize: 9, weight: .regular)

    var body: some View {
        if let item = activity.item {
            let column = textColumn(for: item)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: Self.iconGap) {
                    icon(for: item)
                        .frame(width: Self.iconSide, height: Self.iconSide)
                    VStack(alignment: .leading, spacing: 0) {
                        MarqueeText(
                            .constant(item.name),
                            font: .system(size: 11, weight: .semibold),
                            nsFont: .caption1,
                            textColor: .white,
                            minDuration: 4,
                            frameWidth: min(max(Self.width(of: item.name, font: Self.titleFont), 24), Self.maxTextColumn)
                        )
                        Text(subtitle(for: item))
                            .font(.system(size: 9))
                            .monospacedDigit()
                            .foregroundStyle(item.phase == .failed ? .white.opacity(0.75) : .white.opacity(0.5))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: Self.maxTextColumn, alignment: .leading)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                if item.phase == .receiving {
                    ProgressLine(fraction: item.fraction)
                        .frame(width: Self.iconSide + Self.iconGap + column, height: 2)
                        .opacity(item.stalled ? 0.4 : 1)
                        .animation(.smooth, value: item.stalled)
                        .transition(.opacity)
                }
            }
            .padding(.vertical, 1)
            .fixedSize()
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
            .animation(.smooth, value: item.phase)
        }
    }

    // MARK: - Pieces

    @ViewBuilder
    private func icon(for item: HubActivity.Item) -> some View {
        if let image = activity.icon {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        } else {
            Image(Self.glyph(for: item))
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .padding(2)
                .foregroundStyle(.white.opacity(0.8))
        }
    }

    /// The sender's device glyph from the hub icon set; the shelf glyph when the kind is unknown.
    static func glyph(for item: HubActivity.Item) -> String {
        switch item.fromKind {
        case "tower", "mac", "phone", "server", "windows": return "hub." + item.fromKind!
        default: return "hub.shelf"
        }
    }

    private func subtitle(for item: HubActivity.Item) -> String {
        let from = item.from.map { "from \($0)" }
        switch item.phase {
        case .receiving:
            let amount: String
            if let fraction = item.fraction {
                amount = "\(Int((fraction * 100).rounded(.down)))%"
            } else {
                amount = ByteCountFormatter.string(fromByteCount: item.receivedBytes, countStyle: .file)
            }
            return [from, item.stalled ? "stalled at \(amount)" : amount].compactMap { $0 }.joined(separator: " · ")
        case .arrived:
            return from ?? "On your shelf"
        case .failed:
            return item.from.map { "Didn't arrive from \($0)" } ?? "Didn't arrive"
        }
    }

    private func textColumn(for item: HubActivity.Item) -> CGFloat {
        let title = Self.width(of: item.name, font: Self.titleFont)
        // While receiving, measure the widest the subtitle will get ("100%"), so the line
        // under it keeps one length instead of twitching with every digit.
        var widest = item
        if widest.phase == .receiving, widest.size > 0 { widest.receivedBytes = widest.size }
        let sub = Self.width(of: subtitle(for: widest), font: Self.subtitleFont)
        return min(max(title, sub, 24), Self.maxTextColumn)
    }

    private static func width(of string: String, font: NSFont) -> CGFloat {
        guard !string.isEmpty else { return 0 }
        return (string as NSString).size(withAttributes: [.font: font]).width.rounded(.up)
    }
}

/// A thin capsule track with a fill for `fraction`; nil runs an indeterminate sweep.
struct ProgressLine: View {
    var fraction: Double?

    @State private var sweep = false

    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.15))
                if let fraction {
                    Capsule()
                        .fill(.white.opacity(0.85))
                        .frame(width: max(2, w * fraction))
                        .animation(.linear(duration: 0.25), value: fraction)
                } else {
                    Capsule()
                        .fill(.white.opacity(0.85))
                        .frame(width: w * 0.3)
                        .offset(x: sweep ? w * 0.7 : 0)
                        .onAppear {
                            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                                sweep = true
                            }
                        }
                }
            }
        }
        .clipShape(Capsule())
    }
}
