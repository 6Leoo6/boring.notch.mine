//
//  TabRoutingManager.swift
//  boringNotch
//

import AppKit
import Defaults
import Foundation

/// Decides which tab — and which shelf panel — the notch shows when it opens.
///
/// Signals are ranked: a drop on the shelf outranks sustained shelf use, which outranks a
/// recent copy, which outranks music playing. Each of the first three expires, and a panel is
/// only ever chosen if it has something to show, so an empty side always yields to the other.
@MainActor
final class TabRoutingManager: ObservableObject {
    static let shared = TabRoutingManager()

    /// Panel the shelf tab shows. Routing and the switcher share this single source of truth.
    @Published private(set) var activePanel: ShelfPanel = Defaults[.lastShelfPanel]

    /// Switching away from an auto-routed panel this fast reads as a rejection.
    private static let rejectionWindow: TimeInterval = 3
    /// Shelf use decays by half every 12h, so the preference fades when the shelf goes unused.
    private static let useScoreHalfLife: TimeInterval = 12 * 3600
    private static let sustainedUseThreshold: Double = 3

    private var autoRoutedPanel: ShelfPanel?
    private var autoRoutedAt: Date = .distantPast

    private init() {}

    // MARK: - Signals

    func shelfDidReceiveItems() {
        Defaults[.shelfLastDropAt] = Date()
        recordShelfUse()
    }

    func shelfWasUsed() {
        recordShelfUse()
    }

    func clipboardDidCapture() {
        Defaults[.clipboardLastCopyAt] = Date()
    }

    // MARK: - Routing

    /// Tab to show for a notch that is opening. `current` is kept when the user has asked
    /// for the last tab to be remembered and nothing stronger applies.
    ///
    /// `trigger` gates the modifier override and nothing else — see `NotchOpenTrigger`.
    func routeOnOpen(current: NotchViews, trigger: NotchOpenTrigger = .system) -> NotchViews {
        let shelfHasItems = !ShelfStateViewModel.shared.isEmpty
        let clipboardHasItems = Defaults[.clipboardHistoryEnabled] && !ClipboardManager.shared.items.isEmpty

        // Ahead of every signal AND of the `autoTabRouting` switch: holding the key is the
        // most explicit statement of intent there is, so it cannot be outvoted by a recent
        // copy, a recent drop, or playback.
        if trigger == .pointer, let forced = heldModifierRoute() {
            switch forced {
            case .home:
                return .home
            case .shelf, .clipboard:
                // `automatic: false` — this is a manual pick, so switching away from it must
                // not retire the signal that would otherwise have routed here.
                apply(forced == .clipboard ? .clipboard : .shelf, automatic: false)
                return .shelf
            case .off:
                break
            }
        }

        guard Defaults[.autoTabRouting] else {
            return legacyRoute(current: current, shelfHasItems: shelfHasItems)
        }

        if let panel = signalledPanel(shelfHasItems: shelfHasItems, clipboardHasItems: clipboardHasItems) {
            apply(panel, automatic: true)
            return .shelf
        }

        // Playback puts the player on screen, and the player lives on home. Ranked LAST of the
        // signals on purpose: the three above are each a deliberate act with an expiry, while
        // playback is an ambient state that can hold for hours — so it decides the tab only
        // when nothing more specific does, and cannot hijack a routing the user just earned.
        if MusicManager.shared.isPlaying { return .home }

        // Nothing to show on either side — the shelf tab would just be an empty state.
        guard shelfHasItems || clipboardHasItems else { return .home }

        let remembered = rememberedPanel(shelfHasItems: shelfHasItems, clipboardHasItems: clipboardHasItems)

        if BoringViewCoordinator.shared.openLastTabByDefault {
            if current == .shelf { apply(remembered, automatic: true) }
            return current
        }

        guard Defaults[.openShelfByDefault], shelfHasItems else { return .home }
        apply(remembered, automatic: true)
        return .shelf
    }

    /// Called by the switcher. A manual pick is remembered; picking the shelf also counts as use.
    func selectPanel(_ panel: ShelfPanel) {
        noteRejectionIfNeeded(for: panel)
        Defaults[.lastShelfPanel] = panel
        if panel == .shelf { recordShelfUse() }
        apply(panel, automatic: false)
    }

    /// Forces the shelf panel forward, for a drag heading towards the notch.
    func prepareForDrop() {
        apply(.shelf, automatic: true)
    }

    // MARK: - Modifier override

    /// The tab the currently held modifiers ask for, or nil for "no override".
    ///
    /// Read from `NSEvent.modifierFlags` — the live keyboard state — rather than from an
    /// event, because the open this gates is a hover: there is no click or key press to carry
    /// flags, only a key the user is holding while the pointer sits on the island.
    ///
    /// A route to a tab that is switched off is dropped rather than honoured, so the override
    /// can never open a panel the user has disabled or a clipboard that is not recording.
    private func heldModifierRoute() -> ModifierRoute? {
        let flags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Command wins when both are down. Arbitrary, but it has to be one of them, and the
        // alternative — treating the combination as its own binding — is a third setting for
        // a gesture nobody asked for.
        let route: ModifierRoute
        if flags.contains(.command) {
            route = Defaults[.commandHoverRoute]
        } else if flags.contains(.option) {
            route = Defaults[.optionHoverRoute]
        } else {
            return nil
        }

        switch route {
        case .off:
            return nil
        case .home:
            return .home
        case .shelf:
            return Defaults[.boringShelf] ? .shelf : nil
        case .clipboard:
            return Defaults[.boringShelf] && Defaults[.clipboardHistoryEnabled] ? .clipboard : nil
        }
    }

    // MARK: - Signal evaluation

    private func signalledPanel(shelfHasItems: Bool, clipboardHasItems: Bool) -> ShelfPanel? {
        let dropWindow = TimeInterval(Defaults[.shelfDropBoostMinutes]) * 60
        if shelfHasItems, isLive(Defaults[.shelfLastDropAt], within: dropWindow) { return .shelf }
        if shelfHasItems, decayedUseScore() >= Self.sustainedUseThreshold { return .shelf }

        let copyWindow = TimeInterval(Defaults[.clipboardCopyBoostSeconds])
        if clipboardHasItems, isLive(Defaults[.clipboardLastCopyAt], within: copyWindow) { return .clipboard }

        return nil
    }

    private func rememberedPanel(shelfHasItems: Bool, clipboardHasItems: Bool) -> ShelfPanel {
        switch Defaults[.lastShelfPanel] {
        case .shelf:
            return shelfHasItems || !clipboardHasItems ? .shelf : .clipboard
        case .clipboard:
            return clipboardHasItems || !shelfHasItems ? .clipboard : .shelf
        }
    }

    private func legacyRoute(current: NotchViews, shelfHasItems: Bool) -> NotchViews {
        if shelfHasItems && Defaults[.openShelfByDefault] { return .shelf }
        return BoringViewCoordinator.shared.openLastTabByDefault ? current : .home
    }

    private func isLive(_ timestamp: Date, within window: TimeInterval) -> Bool {
        let elapsed = Date().timeIntervalSince(timestamp)
        return elapsed >= 0 && elapsed <= window
    }

    // MARK: - Use score

    private func recordShelfUse() {
        Defaults[.shelfUseScore] = decayedUseScore() + 1
        Defaults[.shelfUseScoreAt] = Date()
    }

    private func decayedUseScore() -> Double {
        let elapsed = Date().timeIntervalSince(Defaults[.shelfUseScoreAt])
        guard elapsed > 0 else { return Defaults[.shelfUseScore] }
        return Defaults[.shelfUseScore] * pow(0.5, elapsed / Self.useScoreHalfLife)
    }

    // MARK: - Rejection

    private func apply(_ panel: ShelfPanel, automatic: Bool) {
        autoRoutedPanel = automatic ? panel : nil
        autoRoutedAt = automatic ? Date() : .distantPast
        activePanel = panel
    }

    /// An auto-route the user immediately overrides retires the signal behind it, so the
    /// notch stops routing there for the rest of that signal's window.
    private func noteRejectionIfNeeded(for panel: ShelfPanel) {
        guard let routed = autoRoutedPanel,
              routed != panel,
              Date().timeIntervalSince(autoRoutedAt) <= Self.rejectionWindow
        else { return }

        switch routed {
        case .shelf:
            Defaults[.shelfLastDropAt] = .distantPast
            Defaults[.shelfUseScore] = decayedUseScore() / 2
            Defaults[.shelfUseScoreAt] = Date()
        case .clipboard:
            Defaults[.clipboardLastCopyAt] = .distantPast
        }
    }
}
