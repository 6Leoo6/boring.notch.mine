//
//  MusicPeekView.swift
//  boringNotch
//

import AppKit
import SwiftUI

/// The "now playing" peek that drops below the closed island when a track changes.
///
/// Replaces a bare `music.note` glyph and a line of grey marquee text, which had no artwork,
/// no hierarchy and no ground of its own, plus a `GeometryReader` inside an `HStack` — which
/// has no intrinsic height and was what threw the alignment off.
///
/// Bare by choice, from a rendered comparison: no container, no artwork, no meter — just the
/// two lines. Everything else on offer was redundant against its own surroundings. The peek is
/// drawn INSIDE the island's black body (not over the wallpaper, which a first pass assumed —
/// its black capsule and drop shadow both landed on black and vanished), and the closed strip
/// immediately above already carries artwork on the left and a meter on the right. So a chip
/// added a surface the island already provides, and artwork added a second copy of a picture
/// two points higher up.
///
/// What is left has to carry the hierarchy on type alone, which is why the sizes are not
/// arbitrary: 11 semibold against 9 at half white is the same title/subtitle pairing the
/// shelf tiles and the clipboard preview use, so the peek reads as part of the app rather
/// than as loose text.
struct MusicPeekView: View {
    @ObservedObject var musicManager = MusicManager.shared

    /// Widest the text column is allowed to get before the title starts scrolling.
    ///
    /// The peek sits under a 183pt notch on a 640pt window, so it can afford to be wider than
    /// the notch — but not by much: past this it stops reading as something the island emitted
    /// and starts reading as a banner. An album title like "Everything In Its Right Place
    /// (Remastered)" is 210pt at this size, so the cap is what keeps the pill from doubling in
    /// width on one unlucky track.
    private static let maxTextColumn: CGFloat = 170

    private static let titleFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
    private static let artistFont = NSFont.systemFont(ofSize: 9, weight: .regular)

    /// Measured rather than laid out, because `MarqueeText` needs its frame width UP FRONT —
    /// it scrolls whatever does not fit, so handing it a full-width frame would make every
    /// title scroll and handing it a hugging frame is impossible without a layout pass. The
    /// string's drawn width answers it in one call, with no second pass and no flicker.
    ///
    /// The title's OWN width, not the wider of the two lines: a shared column would left-align
    /// the shorter line inside it, which is what stops two centred lines from looking centred.
    private var titleColumn: CGFloat {
        min(max(Self.width(of: musicManager.songTitle, font: Self.titleFont), 24), Self.maxTextColumn)
    }

    private static func width(of string: String, font: NSFont) -> CGFloat {
        guard !string.isEmpty else { return 0 }
        return (string as NSString)
            .size(withAttributes: [.font: font])
            .width
            .rounded(.up)
    }

    var body: some View {
        VStack(alignment: .center, spacing: 0) {
            MarqueeText(
                .constant(musicManager.songTitle),
                font: .system(size: 11, weight: .semibold),
                nsFont: .caption1,
                textColor: .white,
                minDuration: 4,
                frameWidth: titleColumn
            )
            Text(musicManager.artistName)
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(1)
                .truncationMode(.tail)
                // No fixed frame: the artist hugs its own text so the two lines centre on
                // each other rather than on a column one of them does not fill.
                .frame(maxWidth: Self.maxTextColumn)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.vertical, 1)
        .fixedSize()
    }
}
