//
//  TabRoutingManager.swift
//  boringNotch
//

import Defaults
import Foundation

/// Decides which tab — and which shelf panel — the notch shows when it opens.
///
/// Signals are ranked: a drop on the shelf outranks sustained shelf use, which outranks a
/// recent copy. Each one expires, and a panel is only ever chosen if it has something to
/// show, so an empty side always yields to the other.
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
    func routeOnOpen(current: NotchViews) -> NotchViews {
        let shelfHasItems = !ShelfStateViewModel.shared.isEmpty
        let clipboardHasItems = Defaults[.clipboardHistoryEnabled] && !ClipboardManager.shared.items.isEmpty

        guard Defaults[.autoTabRouting] else {
            return legacyRoute(current: current, shelfHasItems: shelfHasItems)
        }

        if let panel = signalledPanel(shelfHasItems: shelfHasItems, clipboardHasItems: clipboardHasItems) {
            apply(panel, automatic: true)
            return .shelf
        }

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
