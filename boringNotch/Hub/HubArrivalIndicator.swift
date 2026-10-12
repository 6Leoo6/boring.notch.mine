//
//  HubArrivalIndicator.swift
//  boringNotch
//

import Defaults
import SwiftUI

/// A glance that something was just copied to this Mac from another device: a small icon in
/// the closed island's right-hand slot, where the music visualizer sits, for a couple of seconds.
///
/// While music plays the icon stands in for the bars, then the bars come back. Without music
/// the island widens to show the slot on its own and narrows again, the way the music live
/// activity comes and goes. It never opens the notch or takes focus.
///
/// Fed by `clipboard.add` from a hub client (source app `mcp.hub-*`). Files have their own,
/// richer indicator (`HubActivity`'s peek with name, sender and progress), so they don't come
/// here. Another arrival while the icon is up restarts the timer; nothing stacks.
@MainActor
final class HubArrivalIndicator: ObservableObject {
    static let shared = HubArrivalIndicator()

    /// The clipboard glyph from the hub icon set (`mac/brand/HubIcons.xcassets` in the hub
    /// repo). Not the sender's device glyph: the peek already uses those for files, and
    /// "copied" is what this has to say at 15 pt.
    static let imageName = "hub.clipboard"

    /// Long enough to notice from the corner of the eye, short enough not to hide the bars
    /// for long.
    static let duration: TimeInterval = 2.5

    @Published private(set) var isShowing = false

    private var hideTask: Task<Void, Never>?

    private init() {}

    func show() {
        guard Defaults[.showHubArrivalIcon] else { return }
        hideTask?.cancel()
        if !isShowing {
            withAnimation(.smooth) { isShowing = true }
        }
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.duration))
            guard !Task.isCancelled, let self else { return }
            withAnimation(.smooth) { self.isShowing = false }
        }
    }

    /// `clipboard.add` callers that are another device: the hub helper sends `hub-<device>`.
    static func isFromAnotherDevice(client: String) -> Bool {
        client.hasPrefix("hub-")
    }
}

/// The icon itself, sized to the slot the visualizer bars use.
struct HubArrivalIcon: View {
    var body: some View {
        Image(HubArrivalIndicator.imageName)
            .renderingMode(.template)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 15, height: 15)
            .foregroundStyle(.white.opacity(0.9))
            .transition(.scale(scale: 0.5).combined(with: .opacity))
            .accessibilityLabel("Copied from another device")
    }
}
