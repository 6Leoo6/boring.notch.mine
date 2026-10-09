//
//  BoringViewModel.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 04/08/24.
//

import AVFoundation
import Combine
import Defaults
import SwiftUI

class BoringViewModel: NSObject, ObservableObject {
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @ObservedObject var detector = FullscreenMediaDetector.shared

    private var closeGraceTask: Task<Void, Never>?
    private var cameraTeardownTask: Task<Void, Never>?
    let animationLibrary: BoringAnimations = .init()
    let animation: Animation?

    @Published var contentType: ContentType = .normal
    @Published private(set) var notchState: NotchState = .closed

    @Published var dragDetectorTargeting: Bool = false
    @Published var generalDropTargeting: Bool = false
    @Published var dropZoneTargeting: Bool = false
    @Published var dropEvent: Bool = false
    @Published var anyDropZoneTargeting: Bool = false
    var cancellables: Set<AnyCancellable> = []
    
    @Published var hideOnClosed: Bool = true

    @Published var edgeAutoOpenActive: Bool = false
    @Published var isHoveringCalendar: Bool = false
    /// A modal the island must outlive — a confirmation alert, a live text edit.
    @Published var isModalDialogActive: Bool = false
    /// User-held pin. Session-only and per-window; deliberately not persisted.
    @Published var isPinned: Bool = false
    /// Grace window after something takes the cursor off the island.
    @Published var closeGraceActive: Bool = false

    @Published var screenUUID: String?

    @Published var notchSize: CGSize = getClosedNotchSize()
    @Published var closedNotchSize: CGSize = getClosedNotchSize()
    
    let webcamManager = WebcamManager.shared
    @Published var isCameraExpanded: Bool = false
    @Published var isRequestingAuthorization: Bool = false
    
    deinit {
        destroy()
    }

    func destroy() {
        closeGraceTask?.cancel()
        // `cameraTeardownTask` is deliberately NOT cancelled: it is what turns the camera off,
        // and it reaches the manager directly rather than through `self`. Cancelling it here
        // would leave the capture session — and the camera light — running.
        cancellables.forEach { $0.cancel() }
        cancellables.removeAll()
    }

    init(screenUUID: String? = nil) {
        animation = animationLibrary.animation

        super.init()
        
        self.screenUUID = screenUUID
        notchSize = getClosedNotchSize(screenUUID: screenUUID)
        closedNotchSize = notchSize

        Publishers.CombineLatest3($dropZoneTargeting, $dragDetectorTargeting, $generalDropTargeting)
            .map { shelf, drag, general in
                shelf || drag || general
            }
            .assign(to: \.anyDropZoneTargeting, on: self)
            .store(in: &cancellables)
        
        setupDetectorObserver()
    }
    
    private func setupDetectorObserver() {
        // Publisher for the user’s fullscreen detection setting
        let enabledPublisher = Defaults
            .publisher(.hideNotchOption)
            .map(\.newValue)
            .map { $0 != .never }
            .removeDuplicates()

        // Publisher for the current screen UUID (non-nil, distinct)
        let screenPublisher = $screenUUID
            .compactMap { $0 }
            .removeDuplicates()

        // Publisher for fullscreen status dictionary
        let fullscreenStatusPublisher = detector.$fullscreenStatus
            .removeDuplicates()

        // Combine all three: screen UUID, fullscreen status, and enabled setting
        Publishers.CombineLatest3(screenPublisher, fullscreenStatusPublisher, enabledPublisher)
            .map { screenUUID, fullscreenStatus, enabled in
                let isFullscreen = fullscreenStatus[screenUUID] ?? false
                return enabled && isFullscreen
            }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] shouldHide in
                withAnimation(.smooth) {
                    self?.hideOnClosed = shouldHide
                }
            }
            .store(in: &cancellables)
    }

    // Computed property for effective notch height
    var effectiveClosedNotchHeight: CGFloat {
        let currentScreen = screenUUID.flatMap { NSScreen.screen(withUUID: $0) }
        let noNotchAndFullscreen = hideOnClosed && (currentScreen?.safeAreaInsets.top ?? 0 <= 0 || currentScreen == nil)
        return noNotchAndFullscreen ? 0 : closedNotchSize.height
    }

    var chinHeight: CGFloat {
        if !Defaults[.hideTitleBar] {
            return 0
        }

        guard let currentScreen = screenUUID.flatMap({ NSScreen.screen(withUUID: $0) }) else {
            return 0
        }

        if notchState == .open { return 0 }

        let menuBarHeight = currentScreen.frame.maxY - currentScreen.visibleFrame.maxY
        let currentHeight = effectiveClosedNotchHeight

        if currentHeight == 0 { return 0 }

        return max(0, menuBarHeight - currentHeight)
    }

    func toggleCameraPreview() {
        if isRequestingAuthorization {
            return
        }

        switch webcamManager.authorizationStatus {
        case .authorized:
            if isCameraExpanded {
                isCameraExpanded = false
                scheduleCameraTeardown()
            } else if webcamManager.cameraAvailable {
                openCameraPreview()
            } else {
                recheckCameraThenOpen()
            }

        case .denied, .restricted:
            DispatchQueue.main.async {
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)

                let alert = NSAlert()
                alert.messageText = "Camera Access Required"
                alert.informativeText = "Please allow camera access in System Settings."
                alert.addButton(withTitle: "Open Settings")
                alert.addButton(withTitle: "Cancel")

                if alert.runModal() == .alertFirstButtonReturn {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                        NSWorkspace.shared.open(url)
                    }
                }

                NSApp.setActivationPolicy(.accessory)
                NSApp.deactivate()
            }

        case .notDetermined:
            requestCameraAccessThenOpen()

        default:
            break
        }
    }

    private func openCameraPreview() {
        webcamManager.startSession()
        isCameraExpanded = true
        coordinator.currentView = .home
    }

    /// The mirror was clicked while authorised but with no camera on record. That used to be an
    /// `else if` with no `else`: the method returned having changed nothing, shown nothing and
    /// logged nothing, which is indistinguishable from a dead button — the exact shape of #43.
    ///
    /// `cameraAvailable` is a CACHE. The manager resolves it from a `DiscoverySession` at init
    /// and then only from device connect/disconnect notifications, so a sleep/wake cycle that
    /// dropped the camera and never announced its return leaves it stuck `false` with a
    /// perfectly working camera attached. Re-resolving it first is therefore not defensive
    /// padding — it is the likely fix, and it makes the button work rather than merely
    /// explaining itself. Only if there is genuinely no capture device do we say so.
    ///
    /// Note this branch does NOT mean "camera busy": a device held exclusively by another app
    /// still appears in a `DiscoverySession`, so that case keeps `cameraAvailable` true and
    /// fails later inside `setupCaptureSession`. The message says what the state actually is.
    private func recheckCameraThenOpen() {
        // Reusing the in-flight guard from the top of `toggleCameraPreview()` so a second click
        // cannot stack a second re-check. Nothing outside this type reads it.
        isRequestingAuthorization = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.webcamManager.checkCameraAvailability()
            let available = await self.awaitCameraAvailability()
            self.isRequestingAuthorization = false

            guard available else {
                NSLog("Mirror unavailable: camera authorised but no capture device discovered")
                self.reportNoCameraDevice()
                return
            }
            guard !self.isCameraExpanded else { return }
            self.openCameraPreview()
        }
    }

    /// The manager publishes `cameraAvailable` from inside a dispatch hop, so a caller that has
    /// just asked it to re-resolve cannot read the answer on the same turn. Bounded, because a
    /// Mac with no camera never sets it at all and this must not spin.
    private func awaitCameraAvailability() async -> Bool {
        for _ in 0 ..< 20 {
            if webcamManager.cameraAvailable { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return webcamManager.cameraAvailable
    }

    /// Same mechanism as the `.denied` branch rather than a new one: an `NSAlert` plus the
    /// activation dance, which the non-activating notch panel needs or the modal sits behind
    /// whatever is frontmost. Deliberately no "Open Settings" button — no setting fixes a
    /// camera that is not there. Rare by construction: the re-check above has already failed,
    /// so on a Mac with a built-in camera this only fires when something is genuinely wrong.
    private func reportNoCameraDevice() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "No Camera Found"
        alert.informativeText = "boring.notch could not find a camera to mirror. If one is connected, it may not have been detected after a sleep or a reconnect."
        alert.addButton(withTitle: "OK")
        alert.runModal()

        NSApp.setActivationPolicy(.accessory)
        NSApp.deactivate()
    }

    /// Tears the capture session down once the mirror has finished closing.
    ///
    /// `stopSession()` is asynchronous on both ends — it hops to the session queue and then
    /// bounces `previewLayer = nil` back to main — so the video vanishes a few frames INTO the
    /// shrink, and what the user sees close is an empty box. Calling it before or after
    /// `isCameraExpanded = false` makes no difference for that reason; only waiting does.
    /// 450ms is what `AppDelegate.setIslandExpansion` already uses to let a SwiftUI spring
    /// settle, and it clears `mirrorSpring` (`interactiveSpring(response: 0.34)`) with room over.
    private func scheduleCameraTeardown() {
        cameraTeardownTask?.cancel()
        cameraTeardownTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            // Reopened during the wait: the session it would tear down is the one now on screen.
            // A dead view model cannot have the mirror open, so that case still tears down.
            guard self?.isCameraExpanded != true else { return }
            WebcamManager.shared.stopSession()
        }
    }

    /// First-ever camera click: prompt, then open the mirror if it was granted.
    ///
    /// The old shape fired the request and dropped the result, so a granted prompt left the
    /// mirror shut and cost the user a second click — and it cleared `isRequestingAuthorization`
    /// on a blind 2s timer, which is both too early to cover a prompt the user leaves sitting
    /// and too late once they have answered.
    ///
    /// The wait is on `AVCaptureDevice.requestAccess` rather than on the manager, because the
    /// manager exposes no completion — it assigns `authorizationStatus` from inside its own
    /// dispatch hop, so there is nothing a caller can await. This overload suspends until the
    /// user actually answers, however long that takes, and never prompts twice. The manager is
    /// then handed the refresh so it stays the one owner of the cached status and of
    /// `cameraAvailable`; with the status now resolved it takes its `.authorized` path and does
    /// not re-prompt.
    private func requestCameraAccessThenOpen() {
        isRequestingAuthorization = true
        Task { @MainActor [weak self] in
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            guard let self else { return }

            self.webcamManager.checkAndRequestVideoAuthorization()
            self.isRequestingAuthorization = false

            guard granted else { return }
            guard await self.awaitCameraAvailability(), !self.isCameraExpanded else { return }
            self.toggleCameraPreview()
        }
    }


    /// Slack below the island's bottom edge, so a near-miss on a control that sits ON that
    /// edge is not read as the user having walked away.
    ///
    /// Measured against a replica of ContentView's chain, with synthesized clicks: the shelf
    /// panel's bottom stroke sits exactly 12pt above the island's edge, and the grid expander
    /// is centred on that stroke — so the bottom of its hit box lands within a few points of
    /// where the island ends. One pointer movement therefore both misses a 9pt chevron and
    /// arms `scheduleAutoClose()`, which is the reported "it closes when I try to click it".
    ///
    /// 12pt mirrors that same padding: the pointer keeps as much forgiving ground below the
    /// island's edge as the island keeps below the stroke the control sits on. It also stays
    /// inside `shadowPadding` (20pt), the band this app's own window already occupies under
    /// the island, so the grace never claims ground that was not ours. Deliberately small —
    /// this rect decides the auto-close, and a generous one leaves the island hanging open
    /// with the cursor visibly clear of it, which is both worse and much harder to notice.
    private let hoverGraceBelowIsland: CGFloat = 12

    /// Whether the pointer is over the island as it is currently drawn, expansion included, so
    /// a clipboard preview or an open shelf grid counts as island rather than as ground the
    /// user has left. Nil when there is no screen to measure against, so a caller can fall back
    /// to its own hover state rather than act on a guess.
    func isMouseHovering(position: NSPoint = NSEvent.mouseLocation) -> Bool? {
        guard let frame = getScreenFrame(screenUUID) else { return nil }

        let islandHeight = notchSize.height + (notchState == .open ? coordinator.islandExpansion : 0)
        // The grace is bottom-only, and only while open: closed, the island is a ~32pt strip
        // and nothing reads this — every consumer sits behind a `notchState == .open` guard.
        let grace = notchState == .open ? hoverGraceBelowIsland : 0
        let baseY = frame.maxY - islandHeight - grace
        let baseX = frame.midX - notchSize.width / 2

        // Bounded at the top as well as the bottom: a screen stacked above this one shares the
        // x range, and an unbounded test would read a cursor up there as still on the island —
        // which, now that this decides the auto-close, would hold the island open for good.
        // The sides are unpadded for the same reason in miniature: the island spans the full
        // window width, so slack there buys nothing the control needs.
        return position.y >= baseY && position.y <= frame.maxY
            && position.x >= baseX && position.x <= baseX + notchSize.width
    }

    /// Everything that should hold the island open against the auto-close timers. An explicit
    /// close still goes through: a pin the user cannot escape would be a trap.
    var blocksAutoClose: Bool { isPinned || isModalDialogActive }

    func togglePinned() {
        isPinned.toggle()
    }

    /// Keeps the auto-close timers off for a moment after a dialog or preview has taken the
    /// cursor away, so the user can get back to the island.
    func beginCloseGrace() {
        closeGraceTask?.cancel()
        closeGraceActive = true
        closeGraceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            self?.closeGraceActive = false
        }
    }

    /// `trigger` says whether the pointer started this open, which is the only case where a
    /// held modifier may pick the tab — see `NotchOpenTrigger`.
    func open(trigger: NotchOpenTrigger = .system) {
        let wasClosed = notchState == .closed

        self.notchSize = openNotchSize
        self.notchState = .open

        // Route only on a real closed -> open transition. `open()` is also called while
        // already open (a tap on the island routes through doOpen), and re-routing there
        // would change the tab under the user mid-interaction.
        // Doing this here (not in close()) prevents a race where close() resets
        // the tab right after the user has just switched it.
        if wasClosed {
            coordinator.currentView = TabRoutingManager.shared.routeOnOpen(
                current: coordinator.currentView,
                trigger: trigger
            )
        }

        MusicManager.shared.forceUpdate()
    }

    func close() {
        // Do not close while a share picker or sharing service is active
        if SharingStateManager.shared.preventNotchClose {
            return
        }
        self.notchSize = getClosedNotchSize(screenUUID: self.screenUUID)
        self.closedNotchSize = self.notchSize
        self.notchState = .closed
        self.isModalDialogActive = false
        self.isPinned = false
        self.coordinator.sneakPeek.show = false
        self.edgeAutoOpenActive = false
    }

    func closeHello() {
        Task { @MainActor in
            withAnimation(animationLibrary.animation) {
                coordinator.helloAnimationRunning = false
                close()
            }
        }
    }
}
