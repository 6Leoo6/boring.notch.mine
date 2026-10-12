//
//  HubArrivalIndicator.swift
//  boringNotch
//

import Defaults
import SwiftUI

/// A glance that something just arrived from another device: a small icon in the closed
/// island's right-hand slot, where the music visualizer sits, for a couple of seconds.
///
/// While music plays the icon stands in for the bars, then the bars come back. Without music
/// the island widens to show the slot on its own and narrows again, the way the music live
/// activity comes and goes. It never opens the notch or takes focus.
///
/// Two kinds, one look: `clipboard` for an entry another device added through the agent
/// bridge (`clipboard.add` from a hub client, source app `mcp.hub-*`), `file` for something
/// that landed on the shelf from another device (`shelf.put` or a completed transfer).
/// Another arrival while one is on show replaces the icon and restarts the timer; nothing
/// stacks.
@MainActor
final class HubArrivalIndicator: ObservableObject {
    static let shared = HubArrivalIndicator()

    enum Kind: Equatable {
        case clipboard
        case file

        /// From the hub icon set (`mac/brand/HubIcons.xcassets` in the hub repo).
        var imageName: String {
            switch self {
            case .clipboard: return "hub.clipboard"
            case .file: return "hub.shelf"
            }
        }
    }

    /// What is on show, or nil when the slot belongs to whatever normally sits there.
    @Published private(set) var kind: Kind?

    /// Long enough to notice from the corner of the eye, short enough not to hide the bars
    /// for long.
    static let duration: TimeInterval = 2.5

    private var hideTask: Task<Void, Never>?

    private init() {}

    func show(_ kind: Kind) {
        guard Defaults[.showHubArrivalIcon] else { return }
        hideTask?.cancel()
        if self.kind != kind {
            withAnimation(.smooth) { self.kind = kind }
        }
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.duration))
            guard !Task.isCancelled, let self else { return }
            withAnimation(.smooth) { self.kind = nil }
        }
    }

    /// `clipboard.add` callers that are another device: the hub helper sends `hub-<device>`.
    static func isFromAnotherDevice(client: String) -> Bool {
        client.hasPrefix("hub-")
    }
}

/// The icon itself, sized to the slot the visualizer bars use.
struct HubArrivalIcon: View {
    let kind: HubArrivalIndicator.Kind

    var body: some View {
        Image(kind.imageName)
            .renderingMode(.template)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 15, height: 15)
            .foregroundStyle(.white.opacity(0.9))
            .id(kind)
            .transition(.scale(scale: 0.5).combined(with: .opacity))
            .accessibilityLabel(kind == .clipboard ? "Copied from another device" : "File arrived from another device")
    }
}
