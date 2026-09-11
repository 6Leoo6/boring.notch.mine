//
//  FlashlightManager.swift
//  boringNotch
//

import AppKit
import Defaults
import SwiftUI

/// The lit pane. Never key, never main: a flashlight that ate the user's keystrokes while they
/// were on a call would be worse than no flashlight, so key status is refused outright rather
/// than borrowed the way the notch borrows it for text editing.
final class FlashlightPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class FlashlightManager: ObservableObject {
    static let shared = FlashlightManager()

    /// Warm rather than `#FFFFFF`. Pure white at full output is a blue-heavy cast (6504K) that
    /// reads as clinical on skin; #FFEBD6 measures ~5200K. It costs 14.5% of the luminance of
    /// pure white (relative luminance 0.855 vs 1.0) — a cheap price for a kinder light.
    static let warmWhite = Color(red: 1.0, green: 235.0 / 255.0, blue: 214.0 / 255.0)

    @Published private(set) var isOn: Bool = false

    /// Position on the size/brightness continuum: 0 is the smallest pane under the notch, 1 is
    /// the whole screen. Size IS the brightness control — a bigger lit area throws more light —
    /// so this is one value, not two.
    @Published var size: Double = Defaults[.flashlightPanelSize] {
        didSet {
            guard size != oldValue else { return }
            applyFrame()
        }
    }

    /// Written on drag-end rather than in `size.didSet`: the slider emits a value every frame,
    /// and persisting each one would be a `UserDefaults` write per frame for no benefit.
    func persistSize() {
        Defaults[.flashlightPanelSize] = size
    }

    private var panel: FlashlightPanel?
    private var activeScreenUUID: String?
    private var activeNotchHeight: CGFloat = 32
    private var escMonitor: Any?
    private var capturedBrightness: Float?
    private var didAttemptLaunchRestore = false

    private init() {}

    // MARK: - Geometry

    /// The continuum, anchored top-centre on the notch: the pane's top edge travels from the
    /// notch's lower lip up to the screen's top edge as it grows, so the light reads as
    /// spreading from where the camera is rather than blooming from the middle of the display.
    ///
    /// Pure and static so it can be measured without a running app.
    static func paneFrame(size t: Double, screen: CGRect, notchHeight: CGFloat) -> CGRect {
        let t = CGFloat(min(max(t, 0), 1))
        let minWidth = min(max(screen.width * 0.32, 420), screen.width)
        let minHeight = min(260, screen.height)

        let width = minWidth + (screen.width - minWidth) * t
        let height = minHeight + (screen.height - minHeight) * t
        let top = (screen.maxY - notchHeight) + notchHeight * t

        return CGRect(x: screen.midX - width / 2, y: top - height, width: width, height: height)
    }

    /// Distance from the pane's top edge down to the control cluster. Resolves to a constant
    /// 12pt below the notch's lower lip at every size, so the slider never slides under the
    /// notch as the pane grows past it.
    var clusterTopInset: CGFloat { activeNotchHeight * CGFloat(size) + 12 }

    // MARK: - Lifecycle

    func toggle(screenUUID: String?) {
        if isOn {
            turnOff()
        } else {
            turnOn(screenUUID: screenUUID)
        }
    }

    func turnOn(screenUUID uuid: String?) {
        #if DEBUG
        NSLog("[flashlight] turnOn(uuid=%@) isOn=%@", uuid ?? "nil", String(describing: isOn))
        #endif
        guard !isOn else { return }
        guard let screen = targetScreen(uuid) else {
            #if DEBUG
            NSLog("[flashlight] turnOn bailed: no target screen")
            #endif
            return
        }

        // Stand the launch repair down for the rest of the session. Any value parked by an
        // earlier crash is adopted by `captureAndBoostBrightness` as the true baseline, so
        // letting the repair also fire would pull the display down while we are lit.
        didAttemptLaunchRestore = true

        activeScreenUUID = uuid
        activeNotchHeight = getClosedNotchSize(screenUUID: uuid).height

        let panel = panel ?? makePanel()
        self.panel = panel
        panel.setFrame(
            Self.paneFrame(size: size, screen: screen.frame, notchHeight: activeNotchHeight),
            display: false
        )
        panel.orderFrontRegardless()

        isOn = true
        installEscMonitor()
        captureAndBoostBrightness()

        #if DEBUG
        schedulePanelAudits()
        #endif
    }

    func turnOff() {
        #if DEBUG
        NSLog(
            "[flashlight] turnOff(isOn=%@) called from:\n%@",
            String(describing: isOn),
            Thread.callStackSymbols.prefix(16).joined(separator: "\n")
        )
        #endif
        guard isOn else { return }
        isOn = false
        removeEscMonitor()
        panel?.orderOut(nil)
        restoreBrightness()
    }

    // MARK: - Window

    private func makePanel() -> FlashlightPanel {
        let panel = FlashlightPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        // One level BELOW the notch's `.mainMenu + 3`, so the mirror stays visible and
        // clickable on top of the light. Seeing yourself while lit is the point of the feature.
        panel.level = .mainMenu + 2
        panel.collectionBehavior = [.fullScreenAuxiliary, .stationary, .canJoinAllSpaces, .ignoresCycle]
        panel.sharingType = Defaults[.hideFromScreenRecording] ? .none : .readWrite
        panel.contentView = NSHostingView(rootView: FlashlightView())
        return panel
    }

    /// The pane opens on the screen whose notch was clicked. The anchor geometry is defined
    /// against that notch, and the mirror the user is watching themselves in belongs to that
    /// window — opening the light anywhere else would separate the two.
    private func targetScreen(_ uuid: String?) -> NSScreen? {
        if let uuid, let screen = NSScreen.screen(withUUID: uuid) { return screen }
        if let screen = NSScreen.screen(withUUID: BoringViewCoordinator.shared.selectedScreenUUID) {
            return screen
        }
        return NSScreen.main
    }

    /// Resized instantly rather than through `animator()`. A live slider must track the cursor,
    /// and this project has already measured `animator().setFrame` as worse than an instant
    /// resize: it overshoots, snaps back and drifts the top edge — which here is the anchor.
    private func applyFrame() {
        guard let panel, isOn, let screen = targetScreen(activeScreenUUID) else { return }
        panel.setFrame(
            Self.paneFrame(size: size, screen: screen.frame, notchHeight: activeNotchHeight),
            display: true
        )
    }

    // MARK: - Escape

    /// Local only, deliberately. A never-key panel cannot receive `keyDown`, and the global
    /// monitor that would catch Esc regardless needs Input Monitoring — a privacy permission
    /// this feature should not take unilaterally. So Esc works while boring.notch is the active
    /// app, and the always-reliable dismissals are the glyph, clicking the pane, and the mirror
    /// or notch closing.
    private func installEscMonitor() {
        guard escMonitor == nil else { return }
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            Task { @MainActor in self?.turnOff() }
            return nil
        }
    }

    private func removeEscMonitor() {
        guard let escMonitor else { return }
        NSEvent.removeMonitor(escMonitor)
        self.escMonitor = nil
    }

    // MARK: - Display brightness

    /// What to do with a parked brightness value at launch. Pure and static: the crash path is
    /// the one path that never runs in normal use, so it is the one that has to be testable
    /// without a display attached.
    enum BrightnessRepair: Equatable {
        /// Nothing parked.
        case none
        /// Parked, but the display is no longer where we stranded it — the user has already
        /// changed it themselves, and honouring the slot would stomp a deliberate choice.
        case decline
        case restore(Double)
    }

    static func repairDecision(saved: Double, current: Double) -> BrightnessRepair {
        // `>= 0` rather than `!= -1`: this is a Double round-tripped through UserDefaults, and
        // 0 is a brightness someone could legitimately have been sitting at.
        guard saved >= 0 else { return .none }
        guard current > 0.98 else { return .decline }
        return .restore(saved)
    }

    private func captureAndBoostBrightness() {
        guard Defaults[.flashlightRaisesBrightness] else { return }
        Task { @MainActor in
            let parked = Defaults[.flashlightRestoreBrightness]
            let original: Double
            if parked >= 0 {
                // A previous run crashed while lit and the display is still where it left it.
                // That parked value is the real pre-flashlight brightness — the level we are
                // sitting at now is the damage, not the baseline.
                original = parked
            } else {
                // Read authoritatively rather than from `BrightnessManager.rawBrightness`,
                // which is populated by an async refresh and can still be 0 early on. Parking
                // a stale 0 would restore the user to a black screen.
                guard let current = await XPCHelperClient.shared.currentScreenBrightness() else { return }
                original = Double(current)
            }

            // The user may have dismissed the light while that read was in flight.
            guard isOn else { return }

            // Sentinel BEFORE the drive, always. A crash in the gap between raising brightness
            // and recording the old value strands the display with no record of what to put
            // back — the precise failure this key exists to prevent.
            Defaults[.flashlightRestoreBrightness] = original
            capturedBrightness = Float(original)
            BrightnessManager.shared.setAbsolute(value: 1.0)
        }
    }

    private func restoreBrightness() {
        guard let captured = capturedBrightness else { return }
        capturedBrightness = nil
        Task { @MainActor in
            // Cleared only once the set has actually been confirmed. `setAbsolute` completes
            // asynchronously, so clearing on the call would leave a window where a crash
            // strands the display with the record already gone. If it fails, the slot is left
            // set on purpose so the next launch can still repair it.
            let ok = await XPCHelperClient.shared.setScreenBrightness(captured)
            if ok {
                Defaults[.flashlightRestoreBrightness] = -1
                BrightnessManager.shared.refresh()
            }
        }
    }

    /// Called at launch. Display brightness is a system setting that outlives this process, so
    /// the repair has to survive the process that broke it.
    ///
    /// Deliberately NOT gated behind a preference, unlike `SleepManager.restoreOnLaunch()`:
    /// that one resurrects a feature the user chose, whereas a display stranded at maximum is
    /// only ever damage. A mitigation you can forget to arm is not a mitigation.
    func restoreOnLaunch() {
        Task { @MainActor in
            // The XPC helper is frequently not up yet at launch, and a single attempt that
            // finds it missing would leave the display stranded until the user happened to
            // open the flashlight again — a whole session at maximum brightness. Retry on a
            // short backoff instead. Bounded at ~16s: if the helper has not arrived by then it
            // is not arriving this session, and the next launch tries again.
            for delayMilliseconds in [0, 500, 1500, 4000, 10000] {
                if delayMilliseconds > 0 {
                    try? await Task.sleep(for: .milliseconds(delayMilliseconds))
                }
                if await repairStrandedBrightness() { return }
            }
        }
    }

    /// Returns whether the question is settled — repaired, declined, or nothing parked. `false`
    /// means only that the helper could not be reached, so it is worth asking again.
    @discardableResult
    private func repairStrandedBrightness() async -> Bool {
        // Also true once the flashlight has been used this session: `turnOn` adopts any parked
        // value as its baseline, so the repair has nothing left to do and must not fire and
        // pull brightness down while the light is on.
        guard !didAttemptLaunchRestore else { return true }

        let saved = Defaults[.flashlightRestoreBrightness]
        if saved < 0 {
            didAttemptLaunchRestore = true
            return true
        }

        // No reading means the XPC helper is not up yet. Leave the slot alone and stay
        // un-attempted so a later call can still repair it — clearing it here would throw away
        // the only record of the original brightness.
        guard let current = await XPCHelperClient.shared.currentScreenBrightness() else {
            return false
        }
        didAttemptLaunchRestore = true

        switch Self.repairDecision(saved: saved, current: Double(current)) {
        case .none:
            return true
        case .decline:
            Defaults[.flashlightRestoreBrightness] = -1
            return true
        case .restore(let value):
            if await XPCHelperClient.shared.setScreenBrightness(Float(value)) {
                Defaults[.flashlightRestoreBrightness] = -1
                BrightnessManager.shared.refresh()
            }
            return true
        }
    }

    // MARK: - Diagnostics

    #if DEBUG
    /// Temporary, for "the pane does not open". The window path has been cleared by standalone
    /// probe: an identical `FlashlightPanel` built the same way — `contentRect: .zero`,
    /// `setFrame(display: false)`, `orderFrontRegardless()`, with the notch's max-level
    /// `CGSSpace` present — composites `#FFEBD6` onto this display, confirmed against a
    /// ScreenCaptureKit capture of the region. So the panel is not failing to draw; something
    /// is ordering it out. This reads the WindowServer's own view of the panel at intervals
    /// after it is shown, and records the caller of every dismissal.
    private func auditPanel(_ stage: String) {
        guard let panel else {
            NSLog("[flashlight] audit %@: panel is nil", stage)
            return
        }

        var server = "no server entry"
        if let entries = CGWindowListCopyWindowInfo(
            [.optionIncludingWindow], CGWindowID(panel.windowNumber)
        ) as? [[String: Any]], let entry = entries.first {
            let onscreen = entry[kCGWindowIsOnscreen as String] as? Bool
            let alpha = entry[kCGWindowAlpha as String] as? Double ?? -1
            let layer = entry[kCGWindowLayer as String] as? Int ?? -1
            let bounds = entry[kCGWindowBounds as String] as? [String: Any] ?? [:]
            server = "onscreen=\(onscreen.map(String.init(describing:)) ?? "absent")"
                + " alpha=\(alpha) layer=\(layer) bounds=\(bounds)"
        }

        NSLog(
            "[flashlight] audit %@: isOn=%@ isVisible=%@ frame=%@ content=%@ %@",
            stage,
            String(describing: isOn),
            String(describing: panel.isVisible),
            NSStringFromRect(panel.frame),
            NSStringFromRect(panel.contentView?.frame ?? .zero),
            server
        )
    }

    private func schedulePanelAudits() {
        auditPanel("orderFront")
        Task { @MainActor [weak self] in
            for delayMilliseconds in [200, 800, 2000] {
                try? await Task.sleep(for: .milliseconds(delayMilliseconds))
                self?.auditPanel("+\(delayMilliseconds)ms")
            }
        }
    }
    #endif
}
