//
//  MarqueeTextView.swift
//  boringNotch
//
//  Created by Richard Kunkli on 08/08/2024.
//

import SwiftUI

struct SizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

struct MeasureSizeModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.background(GeometryReader { geometry in
            Color.clear.preference(key: SizePreferenceKey.self, value: geometry.size)
        })
    }
}

struct MarqueeText: View {
    @Binding var text: String
    let font: Font
    let nsFont: NSFont.TextStyle
    let textColor: Color
    let backgroundColor: Color
    let minDuration: Double
    let frameWidth: CGFloat
    
    @State private var animate = false
    @State private var textSize: CGSize = .zero
    @State private var offset: CGFloat = 0
    
    init(_ text: Binding<String>, font: Font = .body, nsFont: NSFont.TextStyle = .body, textColor: Color = .primary, backgroundColor: Color = .clear, minDuration: Double = 3.0, frameWidth: CGFloat = 200) {
        _text = text
        self.font = font
        self.nsFont = nsFont
        self.textColor = textColor
        self.backgroundColor = backgroundColor
        self.minDuration = minDuration
        self.frameWidth = frameWidth
    }
    
    private var needsScrolling: Bool {
        textSize.width > frameWidth
    }

    /// Distance between the two copies, and therefore also the distance the first copy has to
    /// travel before the second one lands exactly where it started. Named because the measure,
    /// the scroll offset and the loop all have to agree on it.
    private static let gap: CGFloat = 20

    var body: some View {
        // No `GeometryReader` here. It read nothing — and because a `GeometryReader` reports
        // a 10pt ideal width to a parent that proposes nothing (`.fixedSize()`, as the music
        // peek does), it made this view claim ~10pt of width no matter what `frameWidth` said.
        // A centring parent then centred that 10pt stub and drew the title from its leading
        // edge, i.e. starting at the middle of the block and running off the end.
        ZStack(alignment: .leading) {
            HStack(spacing: Self.gap) {
                Text(text)
                Text(text)
                    .opacity(needsScrolling ? 1 : 0)
            }
            .id(text)
            .font(font)
            .foregroundColor(textColor)
            .fixedSize(horizontal: true, vertical: false)
            .offset(x: self.animate ? offset : 0)
            .animation(
                self.animate ?
                    .linear(duration: Double((textSize.width + Self.gap) / 30))
                    .delay(minDuration)
                    .repeatForever(autoreverses: false) : .none,
                value: self.animate
            )
            .background(backgroundColor)
            .modifier(MeasureSizeModifier())
            .onPreferenceChange(SizePreferenceKey.self) { size in
                // `size` spans BOTH copies plus the gap, so halving it alone overstates one
                // copy by half a gap — which made `needsScrolling` true for any title that fit
                // with less than 10pt to spare, and scrolled text that had nowhere to go.
                self.textSize = CGSize(
                    width: max((size.width - Self.gap) / 2, 0),
                    height: NSFont.preferredFont(forTextStyle: nsFont).pointSize
                )
                self.animate = false
                self.offset = 0
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.01){
                    if needsScrolling {
                        self.animate = true
                        self.offset = -(textSize.width + Self.gap)
                    }
                }
            }
        }
        .frame(width: frameWidth, alignment: .leading)
        .clipped()
        .frame(height: textSize.height * 1.3)
    }
}
