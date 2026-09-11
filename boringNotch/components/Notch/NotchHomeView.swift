//
//  NotchHomeView.swift
//  boringNotch
//
//  Created by Hugo Persson on 2024-08-18.
//  Modified by Harsh Vardhan Goswami & Richard Kunkli & Mustafa Ramadan
//

import Combine
import Defaults
import SwiftUI

// MARK: - Music Player Components

struct MusicPlayerView: View {
    @EnvironmentObject var vm: BoringViewModel
    let albumArtNamespace: Namespace.ID
    /// Handed down rather than re-derived so the toolbar reflows in the same transaction that
    /// grows the mirror, instead of a runloop turn ahead of it on its own spring.
    var mirrorOpen: Bool = false

    var body: some View {
        HStack {
            AlbumArtView(vm: vm, albumArtNamespace: albumArtNamespace).padding(.all, 5)
            MusicControlsView(mirrorOpen: mirrorOpen).drawingGroup().compositingGroup()
        }
    }
}

struct AlbumArtView: View {
    @ObservedObject var musicManager = MusicManager.shared
    @ObservedObject var vm: BoringViewModel
    let albumArtNamespace: Namespace.ID

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if Defaults[.lightingEffect] {
                albumArtBackground
            }
            albumArtButton
        }
    }

    private var albumArtBackground: some View {
        Image(nsImage: musicManager.albumArt)
            .resizable()
            .clipped()
            .clipShape(
                RoundedRectangle(
                    cornerRadius: Defaults[.cornerRadiusScaling]
                        ? MusicPlayerImageSizes.cornerRadiusInset.opened
                        : MusicPlayerImageSizes.cornerRadiusInset.closed)
            )
            .aspectRatio(1, contentMode: .fit)
            .scaleEffect(x: 1.3, y: 1.4)
            .rotationEffect(.degrees(92))
            .blur(radius: 40)
            .opacity(musicManager.isPlaying ? 0.5 : 0)
    }

    private var albumArtButton: some View {
        ZStack {
            Button {
                musicManager.openMusicApp()
            } label: {
                ZStack(alignment:.bottomTrailing) {
                    albumArtImage
                    appIconOverlay
                }
            }
            .buttonStyle(PlainButtonStyle())
            .scaleEffect(musicManager.isPlaying ? 1 : 0.85)
            
            albumArtDarkOverlay
        }
    }

    private var albumArtDarkOverlay: some View {
        Rectangle()
            .aspectRatio(1, contentMode: .fit)
            .foregroundColor(Color.black)
            .opacity(musicManager.isPlaying ? 0 : 0.8)
            .blur(radius: 50)
    }
                

    private var albumArtImage: some View {
        Image(nsImage: musicManager.albumArt)
            .resizable()
            .aspectRatio(1, contentMode: .fit)
            .matchedGeometryEffect(id: "albumArt", in: albumArtNamespace)
            .clipped()
            .clipShape(
                RoundedRectangle(
                    cornerRadius: Defaults[.cornerRadiusScaling]
                        ? MusicPlayerImageSizes.cornerRadiusInset.opened
                        : MusicPlayerImageSizes.cornerRadiusInset.closed)
            )
    }

    @ViewBuilder
    private var appIconOverlay: some View {
        if vm.notchState == .open && !musicManager.usingAppIconForArtwork {
            AppIcon(for: musicManager.bundleIdentifier ?? "com.apple.Music")
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 30, height: 30)
                .offset(x: 10, y: 10)
                .transition(.scale.combined(with: .opacity))
                .zIndex(2)
        }
    }
}

struct MusicControlsView: View {
    var mirrorOpen: Bool = false
    @ObservedObject var musicManager = MusicManager.shared
    @Default(.showCalendar) private var showCalendar
    @State private var sliderValue: Double = 0
    @State private var dragging: Bool = false
    @State private var lastDragged: Date = .distantPast
    @Default(.musicControlSlots) private var slotConfig
    @Default(.musicControlSlotLimit) private var slotLimit
    @Default(.playerColorTinting) private var playerColorTinting

    private static let fallbackWhite = Color.white
    private static let fallbackActive = Color.red

    private var musicTint: Color {
        guard playerColorTinting else { return Self.fallbackWhite }
        return .playerTint(from: musicManager.avgColor, fallback: Self.fallbackWhite)
    }

    private var musicAccent: Color {
        guard playerColorTinting else { return Self.fallbackActive }
        return .playerAccent(from: musicManager.avgColor, fallback: Self.fallbackActive)
    }

    var body: some View {
        VStack(alignment: .leading) {
            songInfoAndSlider
            slotToolbar
        }
        .buttonStyle(PlainButtonStyle())
    }

    private var songInfoAndSlider: some View {
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: 4) {
                songInfo(width: geo.size.width)
                musicSlider
            }
        }
        .padding(.top, 10)
        .padding(.leading, 5)
    }

    private func songInfo(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            MarqueeText(
                $musicManager.songTitle, font: .headline, nsFont: .headline, textColor: musicTint,
                frameWidth: width)
            MarqueeText(
                $musicManager.artistName,
                font: .headline,
                nsFont: .headline,
                textColor: playerColorTinting
                    ? .playerTint(from: musicManager.avgColor, fallback: .gray) : .gray,
                frameWidth: width
            )
            .fontWeight(.medium)
            if Defaults[.enableLyrics] {
                TimelineView(.animation(minimumInterval: 0.25)) { timeline in
                    let currentElapsed: Double = {
                        guard musicManager.isPlaying else { return musicManager.elapsedTime }
                        let delta = timeline.date.timeIntervalSince(musicManager.timestampDate)
                        let progressed = musicManager.elapsedTime + (delta * musicManager.playbackRate)
                        return min(max(progressed, 0), musicManager.songDuration)
                    }()
                    let line: String = {
                        if musicManager.isFetchingLyrics { return "Loading lyrics…" }
                        if !musicManager.syncedLyrics.isEmpty {
                            return musicManager.lyricLine(at: currentElapsed)
                        }
                        let trimmed = musicManager.currentLyrics.trimmingCharacters(in: .whitespacesAndNewlines)
                        return trimmed.isEmpty ? "No lyrics found" : trimmed.replacingOccurrences(of: "\n", with: " ")
                    }()
                    let isPersian = line.unicodeScalars.contains { scalar in
                        let v = scalar.value
                        return v >= 0x0600 && v <= 0x06FF
                    }
                    MarqueeText(
                        .constant(line),
                        font: .subheadline,
                        nsFont: .subheadline,
                        textColor: musicManager.isFetchingLyrics ? .gray.opacity(0.7) : .gray,
                        frameWidth: width
                    )
                    .font(isPersian ? .custom("Vazirmatn-Regular", size: NSFont.preferredFont(forTextStyle: .subheadline).pointSize) : .subheadline)
                    .lineLimit(1)
                    .opacity(musicManager.isPlaying ? 1 : 0)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    private var musicSlider: some View {
        TimelineView(.animation(minimumInterval: musicManager.playbackRate > 0 ? 0.1 : nil)) { timeline in
            MusicSliderView(
                sliderValue: $sliderValue,
                duration: $musicManager.songDuration,
                lastDragged: $lastDragged,
                color: musicManager.avgColor,
                dragging: $dragging,
                currentDate: timeline.date,
                timestampDate: musicManager.timestampDate,
                elapsedTime: musicManager.elapsedTime,
                playbackRate: musicManager.playbackRate,
                isPlaying: musicManager.isPlaying
            ) { newValue in
                MusicManager.shared.seek(to: newValue)
            }
            .padding(.top, 5)
            .frame(height: 36)
        }
    }

    /// Identified by position in the FULL slot list, so dropping the edges removes ids 0 and
    /// n-1 outright. Keying on the filtered offset instead would renumber the survivors and
    /// SwiftUI would cross-fade one icon into another rather than retiring the edges.
    private struct SlotEntry: Identifiable {
        let id: Int
        let slot: MusicControlButton
    }

    private var slotToolbar: some View {
        HStack(spacing: 6) {
            ForEach(activeSlots) { entry in
                slotView(for: entry.slot)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        // Shares the mirror's curve so the edge slots retire as part of the same motion
        // instead of popping out from under it.
        .animation(NotchHomeView.mirrorSpring, value: shouldHideEdges)
    }

    // If calendar and camera are both visible alongside music, hide the edge slots
    private var shouldHideEdges: Bool {
        mirrorOpen && showCalendar
    }

    private var activeSlots: [SlotEntry] {
        let sanitizedLimit = min(
            max(slotLimit, MusicControlButton.minSlotCount),
            MusicControlButton.maxSlotCount
        )
        let padded = slotConfig.padded(to: sanitizedLimit, filler: .none)
        let result = padded.prefix(sanitizedLimit).enumerated().map {
            SlotEntry(id: $0.offset, slot: $0.element)
        }
        if shouldHideEdges && result.count >= 5 {
            return Array(result.dropFirst().dropLast())
        }

        return result
    }

    @ViewBuilder
    private func slotView(for slot: MusicControlButton) -> some View {
        switch slot {
        case .shuffle:
            HoverButton(icon: "shuffle", iconColor: musicManager.isShuffled ? musicAccent : musicTint, scale: .medium) {
                MusicManager.shared.toggleShuffle()
            }
        case .previous:
            HoverButton(icon: "backward.fill", iconColor: musicTint, scale: .medium) {
                MusicManager.shared.previousTrack()
            }
        case .playPause:
            HoverButton(icon: musicManager.isPlaying ? "pause.fill" : "play.fill", iconColor: musicTint, scale: .large) {
                MusicManager.shared.togglePlay()
            }
        case .next:
            HoverButton(icon: "forward.fill", iconColor: musicTint, scale: .medium) {
                MusicManager.shared.nextTrack()
            }
        case .repeatMode:
            HoverButton(icon: repeatIcon, iconColor: repeatIconColor, scale: .medium) {
                MusicManager.shared.toggleRepeat()
            }
        case .volume:
            VolumeControlView(tint: musicTint)
        case .favorite:
            FavoriteControlButton(tint: musicTint, activeTint: musicAccent)
        case .goBackward:
            HoverButton(icon: "gobackward.15", iconColor: musicTint, scale: .medium) {
                MusicManager.shared.skip(seconds: -15)
            }
        case .goForward:
            HoverButton(icon: "goforward.15", iconColor: musicTint, scale: .medium) {
                MusicManager.shared.skip(seconds: 15)
            }
        case .none:
            Color.clear.frame(height: 1)
        }
    }

    private var repeatIcon: String {
        switch musicManager.repeatMode {
        case .off:
            return "repeat"
        case .all:
            return "repeat"
        case .one:
            return "repeat.1"
        }
    }

    private var repeatIconColor: Color {
        switch musicManager.repeatMode {
        case .off:
            return musicTint
        case .all, .one:
            return musicAccent
        }
    }
}

struct FavoriteControlButton: View {
    @ObservedObject var musicManager = MusicManager.shared
    var tint: Color = .primary
    var activeTint: Color = .red

    private static let unsupportedOpacity: Double = 0.35

    var body: some View {
        HoverButton(icon: iconName, iconColor: iconColor, scale: .medium) {
            MusicManager.shared.toggleFavoriteTrack()
        }
        .disabled(!musicManager.canFavoriteTrack)
        .opacity(musicManager.canFavoriteTrack ? 1 : Self.unsupportedOpacity)
        .help(helpText)
    }

    private var iconName: String {
        musicManager.isFavoriteTrack ? "heart.fill" : "heart"
    }

    // Steps outside the album-art palette entirely, so "unsupported" cannot be read
    // as either the tinted-inactive or the accent-active state.
    private var iconColor: Color {
        guard musicManager.canFavoriteTrack else { return .gray }
        return musicManager.isFavoriteTrack ? activeTint : tint
    }

    private var helpText: String {
        guard musicManager.canFavoriteTrack else {
            return "The current media player doesn't support liking tracks"
        }
        return musicManager.isFavoriteTrack ? "Remove from favorites" : "Add to favorites"
    }
}

private extension Array where Element == MusicControlButton {
    func padded(to length: Int, filler: MusicControlButton) -> [MusicControlButton] {
        if count >= length { return self }
        return self + Array(repeating: filler, count: length - count)
    }
}

// MARK: - Volume Control View

struct VolumeControlView: View {
    @ObservedObject var musicManager = MusicManager.shared
    var tint: Color = .white
    @State private var volumeSliderValue: Double = 0.5
    @State private var dragging: Bool = false
    @State private var showVolumeSlider: Bool = false
    @State private var lastVolumeUpdateTime: Date = Date.distantPast
    private let volumeUpdateThrottle: TimeInterval = 0.1
    
    var body: some View {
        HStack(spacing: 4) {
            Button(action: {
                if musicManager.volumeControlSupported {
                    withAnimation(.easeInOut(duration: 0.12)) {
                        showVolumeSlider.toggle()
                    }
                }
            }) {
                Image(systemName: volumeIcon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(musicManager.volumeControlSupported ? tint : .gray)
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(!musicManager.volumeControlSupported)
            .frame(width: 24)

            if showVolumeSlider && musicManager.volumeControlSupported {
                CustomSlider(
                    value: $volumeSliderValue,
                    range: 0.0...1.0,
                    color: .white,
                    dragging: $dragging,
                    lastDragged: .constant(Date.distantPast),
                    onValueChange: { newValue in
                        MusicManager.shared.setVolume(to: newValue)
                    },
                    onDragChange: { newValue in
                        let now = Date()
                        if now.timeIntervalSince(lastVolumeUpdateTime) > volumeUpdateThrottle {
                            MusicManager.shared.setVolume(to: newValue)
                            lastVolumeUpdateTime = now
                        }
                    }
                )
                .frame(width: 48, height: 8)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .clipped()
        .onReceive(musicManager.$volume) { volume in
            if !dragging {
                volumeSliderValue = volume
            }
        }
        .onReceive(musicManager.$volumeControlSupported) { supported in
            if !supported {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showVolumeSlider = false
                }
            }
        }
        .onChange(of: showVolumeSlider) { _, isShowing in
            if isShowing {
                // Sync volume from app when slider appears
                Task {
                    await MusicManager.shared.syncVolumeFromActiveApp()
                }
            }
        }
        .onDisappear {
            // volumeUpdateTask?.cancel() // No longer needed
        }
    }
    
    
    private var volumeIcon: String {
        if !musicManager.volumeControlSupported {
            return "speaker.slash"
        } else if volumeSliderValue == 0 {
            return "speaker.slash.fill"
        } else if volumeSliderValue < 0.33 {
            return "speaker.1.fill"
        } else if volumeSliderValue < 0.66 {
            return "speaker.2.fill"
        } else {
            return "speaker.3.fill"
        }
    }
}

// MARK: - Main View

struct NotchHomeView: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject var webcamManager = WebcamManager.shared
    @ObservedObject var batteryModel = BatteryStatusViewModel.shared
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @ObservedObject var flashlight = FlashlightManager.shared
    let albumArtNamespace: Namespace.ID

    // Read through the wrapper, not `Defaults[...]`: a bare subscript registers no SwiftUI
    // dependency, so toggling either of these in Settings left the row waiting for some
    // unrelated publisher to invalidate it before it noticed — which is a pop-in, not a push.
    @Default(.showMirror) private var showMirror
    @Default(.showCalendar) private var showCalendar

    @State private var mirrorMounted = false
    @State private var mirrorOpen = false
    @State private var rowHeight: CGFloat = 0
    /// A measurement that landed while the spring was in flight, applied once it settles.
    @State private var deferredRowHeight: CGFloat = 0
    @State private var mirrorInFlight = false
    @State private var mirrorHovering = false
    @State private var mirrorUnmountTask: Task<Void, Never>?

    var body: some View {
        Group {
            if !coordinator.firstLaunch {
                mainContent
            }
        }
    }

    static let mirrorSpring = Animation.interactiveSpring(response: 0.34, dampingFraction: 0.78, blendDuration: 0)
    /// Long enough for the spring above to have visually settled before the slot unmounts.
    private static let mirrorCollapse: Duration = .milliseconds(460)

    private var shouldShowCamera: Bool {
        showMirror && webcamManager.cameraAvailable && vm.isCameraExpanded
    }

    private var widgetGap: CGFloat { (mirrorOpen && showCalendar) ? 10 : 15 }

    private var mirrorSide: CGFloat { rowHeight > 0 ? rowHeight : 120 }

    private var mainContent: some View {
        // Spacing sits on the children rather than on the HStack: a mounted-but-collapsed
        // mirror would still be given a gap of its own and would shift its neighbours while
        // it is supposed to be closed.
        HStack(alignment: .top, spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                MusicPlayerView(albumArtNamespace: albumArtNamespace, mirrorOpen: mirrorOpen)

                if showCalendar {
                    CalendarView()
                        .frame(width: 155)
                        .onHover { isHovering in
                            vm.isHoveringCalendar = isHovering
                        }
                        .environmentObject(vm)
                        .padding(.leading, widgetGap)
                        .transition(.opacity)
                }
            }
            // Measured without the mirror in it. Measuring the whole row instead would let
            // the mirror — which is square and sized FROM this height — feed its own size back.
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: RowHeightKey.self, value: proxy.size.height)
                }
            )

            if mirrorMounted {
                CameraPreviewView(webcamManager: webcamManager)
                    .frame(width: mirrorSide, height: mirrorSide)
                    // Sits INSIDE the animated slot, so the glyph is carried by the push
                    // rather than being laid out against it.
                    .overlay(alignment: .topTrailing) { flashlightToggle }
                    .onHover { hovering in
                        mirrorHovering = hovering
                    }
                    .padding(.leading, widgetGap)
                    // The gap is carried INSIDE the animated slot, so the mirror and the
                    // space it occupies are one object: its growth is what pushes the
                    // neighbours, rather than a gap opening and the mirror landing in it.
                    .frame(width: mirrorOpen ? mirrorSide + widgetGap : 0, alignment: .leading)
                    // Deliberately NOT cross-faded on `mirrorOpen`. A zero-width clipped slot
                    // already hides it completely, so the fade was doing no hiding work — only
                    // making the mirror translucent for the whole push, so the calendar showed
                    // through the thing that is supposed to be shoving it. Opaque reads solid.
                    .opacity(vm.notchState == .closed ? 0 : 1)
                    .blur(radius: vm.notchState == .closed ? 20 : 0)
                    .clipped()
            }
        }
        .animation(Self.mirrorSpring, value: mirrorOpen)
        // The mirror is sized FROM the measured row height, so a re-measurement resizes it.
        // Carrying that on the same curve is what stops a corrected measurement from yanking
        // the mirror — and everything left of it — to a new position in one frame.
        .animation(Self.mirrorSpring, value: mirrorSide)
        .onPreferenceChange(RowHeightKey.self) { height in
            adoptRowHeight(height)
        }
        .onAppear { syncMirror(animated: false) }
        // The light is anchored on the mirror and only makes sense while you can see yourself
        // in it, so every route that retires the mirror retires the light too. Each of these
        // also restores display brightness, which is the reason they are explicit rather than
        // left to `onDisappear`: the notch can close while this view is still mounted.
        .onChange(of: shouldShowCamera) { _, shown in
            syncMirror(animated: true)
            if !shown { flashlight.turnOff() }
        }
        .onChange(of: vm.notchState) { _, state in
            if state == .closed { flashlight.turnOff() }
        }
        .onDisappear {
            mirrorUnmountTask?.cancel()
            flashlight.turnOff()
        }
        .blur(radius: vm.notchState == .closed ? 30 : 0)
    }

    /// How much of the glyph is showing. Drives COLOUR alpha, never the subtree's `.opacity`.
    private var glyphReveal: Double { (mirrorHovering || flashlight.isOn) ? 1 : 0 }

    /// Revealed on mirror hover. 5pt corner inset, matching the convention #29c set for tile
    /// corner controls.
    ///
    /// The reveal fades the glyph's four colours rather than wrapping it in `.opacity`, because
    /// **`.opacity(0)` prunes a view from hit-testing outright** — it does not merely hide it.
    /// Measured with synthesised `leftMouseDown`/`Up` over a real `NSHostingView`: the identical
    /// control fires everywhere inside its box at `.opacity(1)` and NOWHERE at `.opacity(0)`,
    /// and `0.001` is no better, so there is no "nearly invisible but still live" setting. That
    /// made the glyph decorative for as long as `mirrorHovering` was false — and hover state is
    /// the one input here already known to go stale: a resize under a stationary cursor emits
    /// its own `onHover(false)`, and AppKit will not re-test a tracking area without a real
    /// mouse event. Fading colours instead makes the hit region independent of the reveal;
    /// measured identical, 32x32, at both alphas.
    ///
    /// The `.padding(5)` sits INSIDE the label, with `.contentShape(Rectangle())` next to it, so
    /// the Button hit-tests its label's layout frame instead of the glyph's ink. Same 5pt inset
    /// as before and the parent is still untouched — but the live target is the whole 32x32 box
    /// rather than the 22x22 circle, measured 16 firing points against 9.
    @ViewBuilder
    private var flashlightToggle: some View {
        Button {
            #if DEBUG
            NSLog("[flashlight] glyph action fired (hovering=%@)", String(describing: mirrorHovering))
            #endif
            flashlight.toggle(screenUUID: vm.screenUUID)
        } label: {
            Image(systemName: flashlight.isOn ? "flashlight.on.fill" : "flashlight.off.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle((flashlight.isOn ? Color.black : Color.white).opacity(glyphReveal))
                .frame(width: 22, height: 22)
                .background(
                    Circle().fill(
                        (flashlight.isOn ? Color.white : Color.black.opacity(0.55))
                            .opacity(glyphReveal)
                    )
                )
                .overlay(Circle().stroke(.white.opacity(0.18 * glyphReveal), lineWidth: 0.5))
                .padding(5)
                .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .animation(.easeOut(duration: 0.14), value: mirrorHovering)
        .animation(.easeOut(duration: 0.14), value: flashlight.isOn)
        .help(flashlight.isOn ? "Turn off the flashlight" : "Light up your face")
    }

    /// Mounts the mirror at zero width before growing it, and keeps it mounted until the
    /// collapse has finished — unmounting on the toggle would delete the thing being animated.
    private func syncMirror(animated: Bool) {
        mirrorUnmountTask?.cancel()
        guard animated else {
            mirrorMounted = shouldShowCamera
            mirrorOpen = shouldShowCamera
            mirrorInFlight = false
            return
        }

        if shouldShowCamera {
            mirrorMounted = true
            // Growing in the same turn as the mount would land at full width immediately
            // and skip the push entirely.
            DispatchQueue.main.async { mirrorOpen = true }
        } else {
            mirrorOpen = false
        }

        armMirrorSettle()
    }

    /// One task covers the whole flight, in both directions. Closing also has to outlast it
    /// before unmounting, and either direction has to outlast it before the row is allowed to
    /// resize the mirror again.
    private func armMirrorSettle() {
        mirrorInFlight = true
        mirrorUnmountTask?.cancel()
        mirrorUnmountTask = Task { @MainActor in
            try? await Task.sleep(for: Self.mirrorCollapse)
            guard !Task.isCancelled else { return }
            mirrorInFlight = false
            if !shouldShowCamera { mirrorMounted = false }
            if deferredRowHeight > 0 {
                let height = deferredRowHeight
                deferredRowHeight = 0
                adoptRowHeight(height)
            }
        }
    }

    /// The row is measured while it is being squeezed by the very slot this height sizes, so
    /// the loop the geometry reader was meant to break is only half broken: excluding the
    /// mirror keeps its width out of the measurement, but not its effect on the neighbours it
    /// is compressing. Adopting a height mid-flight moves the spring's target while it flies,
    /// which lands as a jump; adopting one back-to-back lets that half-loop ring. So a height
    /// is taken only at rest, and taking one re-arms the settle — at most one correction per
    /// period, which converges instead of oscillating.
    private func adoptRowHeight(_ height: CGFloat) {
        guard height > 0, abs(height - rowHeight) > 1 else { return }
        guard !mirrorInFlight else {
            deferredRowHeight = height
            return
        }
        rowHeight = height
        if mirrorOpen { armMirrorSettle() }
    }
}

private struct RowHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct MusicSliderView: View {
    @Binding var sliderValue: Double
    @Binding var duration: Double
    @Binding var lastDragged: Date
    var color: NSColor
    @Binding var dragging: Bool
    let currentDate: Date
    let timestampDate: Date
    let elapsedTime: Double
    let playbackRate: Double
    let isPlaying: Bool
    var onValueChange: (Double) -> Void
    @Default(.playerColorTinting) private var playerColorTinting
    @Default(.sliderColor) private var sliderColor


    var body: some View {
        VStack {
            CustomSlider(
                value: $sliderValue,
                range: 0...duration,
                color: sliderFill,
                dragging: $dragging,
                lastDragged: $lastDragged,
                onValueChange: onValueChange
            )
            .frame(height: 10, alignment: .center)

            HStack {
                Text(timeString(from: sliderValue))
                Spacer()
                Text(timeString(from: duration))
            }
            .fontWeight(.medium)
            .foregroundColor(
                playerColorTinting
                    ? .playerTint(from: color, fallback: .gray) : .gray
            )
            .font(.caption)
        }
        .onChange(of: currentDate) {
           guard !dragging, timestampDate.timeIntervalSince(lastDragged) > -1 else { return }
            sliderValue = MusicManager.shared.estimatedPlaybackPosition(at: currentDate)
        }
    }

    private var sliderFill: Color {
        guard playerColorTinting else { return .white }
        switch sliderColor {
        case .albumArt:
            return .playerTint(from: color, fallback: .white, factor: 0.8)
        case .accent:
            return .effectiveAccent
        case .white:
            return .white
        }
    }

    func timeString(from seconds: Double) -> String {
        let totalMinutes = Int(seconds) / 60
        let remainingSeconds = Int(seconds) % 60
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
        } else {
            return String(format: "%d:%02d", minutes, remainingSeconds)
        }
    }
}

struct CustomSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var color: Color = .white
    @Binding var dragging: Bool
    @Binding var lastDragged: Date
    var onValueChange: ((Double) -> Void)?
    var onDragChange: ((Double) -> Void)?

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = CGFloat(dragging ? 9 : 5)
            let rangeSpan = range.upperBound - range.lowerBound

            let progress = rangeSpan == .zero ? 0 : (value - range.lowerBound) / rangeSpan
            let filledTrackWidth = min(max(progress, 0), 1) * width

            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(.gray.opacity(0.3))
                    .frame(height: height)

                Rectangle()
                    .fill(color)
                    .frame(width: filledTrackWidth, height: height)
            }
            .cornerRadius(height / 2)
            .frame(height: 10)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        withAnimation {
                            dragging = true
                        }
                        let newValue = range.lowerBound + Double(gesture.location.x / width) * rangeSpan
                        value = min(max(newValue, range.lowerBound), range.upperBound)
                        onDragChange?(value)
                    }
                    .onEnded { _ in
                        onValueChange?(value)
                        dragging = false
                        lastDragged = Date()
                    }
            )
            .animation(.spring(response: 0.35, dampingFraction: 0.7), value: dragging)
        }
    }
}
