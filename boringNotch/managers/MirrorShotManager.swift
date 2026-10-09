//
//  MirrorShotManager.swift
//  boringNotch
//

import AppKit
import AVFoundation
import CoreImage
import Defaults
import KeyboardShortcuts

/// Takes a still of the user from the mirror and copies it, framed exactly as the mirror
/// frames it.
///
/// "Exactly" is the requirement, not an aspiration: the mirror shows a CENTRE-CROPPED SQUARE of
/// a 16:9 sensor (`videoGravity = .resizeAspectFill` inside a square frame), MIRRORED left to
/// right (`.scaleEffect(x: -1)`), with its corners rounded. A shot that skipped any of the
/// three would hand back a picture the user never saw — the full sensor width they cannot see,
/// or their face flipped the other way round from the one they were just looking at.
@MainActor
final class MirrorShotManager: ObservableObject {
    static let shared = MirrorShotManager()

    /// Drives the shutter flash. Separate from `justCopied` because the flash has to land on
    /// the press, before the frame has even arrived, while the confirmation can only be honest
    /// once the pasteboard has it.
    @Published private(set) var shutterFlash = false
    @Published private(set) var justCopied = false
    @Published private(set) var isCapturing = false
    @Published private(set) var lastError: String?

    /// Corner radius as a FRACTION of the mirror's side, set by the view.
    ///
    /// The view owns this because only it knows what it drew: the radius depends on
    /// `mirrorShape`, on `cornerRadiusScaling`, and on the side the mirror was laid out at,
    /// which is derived from a measured row height. A fraction rather than points, so the shot
    /// can be composed at sensor resolution instead of at the 90-odd points on screen.
    var cornerRadiusFraction: CGFloat = 0.14

    /// True while Space is bound. Read by the view for its hint.
    @Published private(set) var spaceArmed = false

    private var flashTask: Task<Void, Never>?
    private var copiedTask: Task<Void, Never>?
    private var idleReleaseTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?

    /// How long Space stays bound after the pointer last MOVED over the mirror.
    ///
    /// This exists because hovering is not the same as intending to take a shot. A pointer
    /// left parked at the top of the screen holds the island hover-open, holds the mirror
    /// hovered, and would hold Space bound indefinitely — so typing in any other app would
    /// silently lose its spaces. Nobody would connect that to a mirror they are not looking
    /// at. Movement is the signal that the mirror is actually being used, so the binding
    /// follows movement and lapses without it; the shutter glyph keeps working regardless, and
    /// any pointer movement over the mirror re-arms within one event.
    private static let idleRelease: Duration = .seconds(5)

    private init() {}

    // MARK: - Space

    /// Binds and unbinds Space, which is the only honest way to offer it.
    ///
    /// The notch is a non-activating panel: it never becomes key, so it never receives a
    /// `keyDown` and a local monitor would see nothing. The alternatives were worse. A GLOBAL
    /// `NSEvent` monitor cannot consume the event, so every shot would also press space in
    /// whatever app was frontmost — scrolling a page, pausing a video. Making the panel key
    /// would take focus from the user's app, which this whole window class exists to avoid.
    ///
    /// A Carbon hotkey (what `KeyboardShortcuts` registers) consumes the key and needs no
    /// privacy permission — but it is GLOBAL, so binding Space permanently would swallow the
    /// spacebar system-wide. Hence arming.
    ///
    /// Called on pointer MOVEMENT over the mirror, not merely on entering it, and every call
    /// restarts the idle release — so the binding tracks USE rather than presence. It is
    /// dropped by four independent things: the pointer leaving, the pointer going still, the
    /// watchdog finding the cursor off the notch entirely, and every route that retires the
    /// mirror. Any one of them is enough to give the spacebar back.
    func armSpace(_ armed: Bool) {
        guard Defaults[.mirrorShotSpaceShortcut] else {
            if spaceArmed { release() }
            return
        }

        guard armed else {
            if spaceArmed { release() }
            return
        }

        if !spaceArmed {
            KeyboardShortcuts.enable(.mirrorShot)
            spaceArmed = true
            startWatchdog()
        }
        scheduleIdleRelease()
    }

    private func release() {
        idleReleaseTask?.cancel()
        idleReleaseTask = nil
        watchdogTask?.cancel()
        watchdogTask = nil
        KeyboardShortcuts.disable(.mirrorShot)
        spaceArmed = false
    }

    private func scheduleIdleRelease() {
        idleReleaseTask?.cancel()
        idleReleaseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.idleRelease)
            guard !Task.isCancelled else { return }
            self?.release()
        }
    }

    /// Belt and braces against a hover-exit that never arrives.
    ///
    /// This app has already been bitten twice by trusting hover EVENTS — a pending exit is
    /// cancelled whenever the island resizes under the cursor, leaving the cache stuck on
    /// "inside" (see `ContentView.cursorHasLeftIsland`). A stuck hover cache normally costs a
    /// highlight; here it would cost the user their spacebar, so the binding is also checked
    /// against something no event can desynchronise: whether the pointer is over a notch
    /// window at all, asked of AppKit's real window frames.
    private func startWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, let self, self.spaceArmed else { return }
                if !cursorIsOverNotchWindow() {
                    self.release()
                    return
                }
            }
        }
    }

    // MARK: - Taking the shot

    func takeShot() {
        guard !isCapturing else { return }
        isCapturing = true
        lastError = nil

        // Ahead of the capture, deliberately. The flash is chrome drawn over the mirror, never
        // part of the frame, so nothing is gained by waiting for the sensor — and a shutter
        // that fires a frame later than the press feels broken rather than instant.
        flash()

        Task { @MainActor in
            defer { isCapturing = false }

            guard let frame = await WebcamManager.shared.nextFrame() else {
                lastError = "The camera did not hand back a frame."
                return
            }
            guard let shot = compose(frame) else {
                lastError = "The shot could not be composed."
                return
            }
            guard let png = Self.pngData(from: shot) else {
                lastError = "The shot could not be encoded."
                return
            }

            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setData(png, forType: .png)
            confirm()
        }
    }

    /// Centre-square crop, mirrored, corners rounded — the mirror's three transforms, in the
    /// order the mirror applies them.
    private func compose(_ frame: CGImage) -> CGImage? {
        let side = min(frame.width, frame.height)
        let crop = CGRect(
            x: (frame.width - side) / 2,
            y: (frame.height - side) / 2,
            width: side,
            height: side
        )
        guard let cropped = frame.cropping(to: crop) else { return nil }

        guard let context = CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            // Alpha, so the rounded corners come out transparent rather than black. A shot
            // pasted onto anything other than a dark background would otherwise arrive with
            // four black wedges.
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        let bounds = CGRect(x: 0, y: 0, width: side, height: side)
        // The mirror is mirrored, so the shot is too: what the user is composing is the image
        // in front of them, not the sensor's view of them.
        context.translateBy(x: CGFloat(side), y: 0)
        context.scaleBy(x: -1, y: 1)

        let radius = min(CGFloat(side) * max(cornerRadiusFraction, 0), CGFloat(side) / 2)
        if radius > 0.5 {
            context.addPath(CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.clip()
        }
        context.draw(cropped, in: bounds)
        return context.makeImage()
    }

    private static func pngData(from image: CGImage) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = NSSize(width: image.width, height: image.height)
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: - Feedback

    private func flash() {
        flashTask?.cancel()
        shutterFlash = true
        if Defaults[.enableHaptics] {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        flashTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(70))
            guard !Task.isCancelled else { return }
            self?.shutterFlash = false
        }
    }

    private func confirm() {
        copiedTask?.cancel()
        justCopied = true
        copiedTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1100))
            guard !Task.isCancelled else { return }
            self?.justCopied = false
        }
    }
}
