//
//  ScreenCaptureManager.swift
//  boringNotch
//

import AVFoundation
import AppKit
import CoreGraphics
import CoreMedia
import Defaults
import Foundation
import ScreenCaptureKit

/// Screenshots and screen recordings, captured IN PROCESS through ScreenCaptureKit.
///
/// The obvious implementation — spawn Apple's own `/usr/sbin/screencapture` — was written
/// first and does not work here, and the reason is worth keeping because nothing about it is
/// visible from a shell. **This app is sandboxed, and a sandboxed process may not exec that
/// binary at all**: the kernel refuses the lookup outright, logging
/// `Sandbox: boringNotch deny(1) mach-lookup com.apple.security.syspolicy.exec`. Not a TCC
/// prompt, not a path problem, and nothing the code can catch — `Process.run()` reports no
/// error. Every shell test of the tool passes, because a shell is not sandboxed; the app then
/// silently captures nothing. Verifying a capture mechanism anywhere but INSIDE the app proves
/// nothing about it.
///
/// So the pieces the tool would have given us are rebuilt: `RegionSelectionController` draws
/// the selection, `SCScreenshotManager` takes the still, and `SCStream` feeding an
/// `AVAssetWriter` records. `openSystemCaptureUI()` is the one exception and still works,
/// because LaunchServices is not an exec.
@MainActor
final class ScreenCaptureManager: ObservableObject {
    static let shared = ScreenCaptureManager()

    @Published private(set) var isRecording: Bool = false

    /// Seconds elapsed in the current recording, 0 when not recording.
    @Published private(set) var recordingSeconds: Int = 0

    /// True while the drag-out-a-region overlay is up, before recording has begun. Distinct
    /// from `isRecording` so the UI can show "choosing an area" rather than a 0-second timer.
    @Published private(set) var isSelectingRegion: Bool = false

    /// Where the last capture went. A file URL for recordings; nil for a screenshot that went
    /// straight to the pasteboard and never became a file.
    @Published private(set) var lastCaptureURL: URL?

    /// Set when a capture lands on the pasteboard, so the UI can say "Copied" rather than
    /// leaving the user wondering whether anything happened.
    @Published private(set) var lastCaptureWasCopied: Bool = false

    /// Mirrors the Screen Recording TCC grant. False is an ordinary state, not an error: the
    /// buttons stay visible and explain themselves rather than vanishing.
    @Published private(set) var permissionGranted: Bool = true

    /// Human-readable reason the last attempt did not do what was asked. Nil after a success.
    @Published private(set) var lastError: String?

    /// How long copied recordings are kept before being swept. They live inside this app's
    /// container purely so the pasteboard has a real file to point at, so they are cache, not
    /// documents — but a paste can happen well after the recording, so the window is generous.
    private static let copiedRecordingLifetime: TimeInterval = 7 * 24 * 60 * 60
    private static let copiedRecordingLimit = 20

    private enum CaptureKind {
        case still
        case recording
    }

    private var recordingSession: RecordingSession?
    private var recordingStagingDirectory: URL?
    private var tickTask: Task<Void, Never>?
    private var terminationObserver: NSObjectProtocol?

    private init() {
        permissionGranted = CGPreflightScreenCaptureAccess()
        pruneCopiedRecordings()
        // An `AVAssetWriter` that never gets `finishWriting()` leaves a file with no moov
        // atom — an unplayable stub. Quitting mid-recording is a normal way to stop, so the
        // movie is finalised on the way out rather than abandoned.
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                ScreenCaptureManager.shared.finishForTermination()
            }
        }
    }

    /// False only when the OS cannot do this at all. ScreenCaptureKit ships with every system
    /// this app runs on (deployment target 14.0), so this is constant — it stays in the API
    /// because permission is a SEPARATE question the UI must not conflate with capability:
    /// a denied grant is recoverable and must leave the controls on screen to explain
    /// themselves, see `permissionGranted`.
    var canCapture: Bool { true }

    // MARK: - Stills

    /// Interactive area/window selection, the ⇧⌘4 gesture. Escape cancels it and is not an
    /// error — the tool simply exits without writing anything.
    func takeScreenshot() {
        capture(interactive: true)
    }

    /// The whole screen, no selection, the ⇧⌘3 gesture.
    func takeFullScreenshot() {
        capture(interactive: false)
    }

    private func capture(interactive: Bool) {
        guard Defaults[.screenCaptureEnabled], canCapture, ensurePermission() else { return }

        guard interactive else {
            Task { await captureStill(region: nil) }
            return
        }

        guard !isSelectingRegion else { return }
        isSelectingRegion = true
        RegionSelectionController.shared.begin { [weak self] rect in
            guard let self else { return }
            self.isSelectingRegion = false
            // Escape. A cancelled selection is an ordinary outcome, not a failure to report.
            guard let rect else { return }
            Task { @MainActor in
                // Let the overlay's windows leave the screen before the shutter, or the
                // dimming is captured along with the region.
                try? await Task.sleep(for: .milliseconds(120))
                await self.captureStill(region: rect)
            }
        }
    }

    /// `region` is in AppKit screen coordinates (bottom-left origin); nil captures the whole
    /// display under the pointer.
    private func captureStill(region: CGRect?) async {
        guard let target = Self.target(for: region) else {
            lastError = "Could not work out which display to capture."
            return
        }

        do {
            let filter = try await Self.contentFilter(for: target.display)
            let configuration = Self.configuration(for: target, showsCursor: Defaults[.screenCaptureIncludeCursor])
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
            deliverStill(image)
        } catch {
            refreshPermissionState()
            lastError = permissionGranted
                ? "The screenshot failed: \(error.localizedDescription)"
                : Self.permissionMessage
            NSLog("[capture] still FAILED: %@", String(describing: error))
        }
    }

    private func deliverStill(_ image: CGImage) {
        guard let png = Self.pngData(from: image) else {
            lastError = "The screenshot could not be encoded."
            return
        }

        if Defaults[.screenCaptureToClipboard] {
            // Straight to the pasteboard, no file anywhere: nothing to save, nothing to clean
            // up, nothing left on the Desktop. `ClipboardManager` reads `public.png`, so the
            // shot also lands in this app's own history — which is the end-to-end proof that
            // the copy happened.
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setData(png, forType: .png)
            lastCaptureURL = nil
            lastCaptureWasCopied = true
            lastError = nil
            playShutterIfWanted()
            return
        }

        guard let staging = makeStagingDirectory() else {
            lastError = "Could not create a working folder for the screenshot."
            return
        }
        let file = staging.appendingPathComponent(Self.captureName(prefix: "Screenshot", extension: "png"))
        do {
            try png.write(to: file)
            lastCaptureWasCopied = false
            lastError = nil
            playShutterIfWanted()
            deliver(stagingDirectory: staging, kind: .still)
        } catch {
            removeStagingDirectory(staging)
            lastError = "The screenshot could not be written: \(error.localizedDescription)"
        }
    }

    /// The tool used to make this noise for us. It is not decoration: without a file appearing
    /// on the Desktop, the sound is the only confirmation a copied screenshot ever happened.
    private func playShutterIfWanted() {
        guard Defaults[.screenCapturePlaySound] else { return }
        NSSound(named: "Grab")?.play()
    }

    // MARK: - Recording

    /// Drag out the region to record, then record it.
    ///
    /// The selection is ours rather than the system's because `screencapture` refuses the
    /// combination outright — `screencapture -v -i` exits with "video not valid with -i", and
    /// `-J video` does not change that. The only region-aware recording flag is `-R x,y,w,h`,
    /// so the rectangle has to be obtained first and handed over.
    func startRecording() {
        NSLog("[screencapture] startRecording requested")
        guard Defaults[.screenCaptureEnabled], canCapture, !isRecording, !isSelectingRegion,
              ensurePermission() else {
            NSLog("[screencapture] startRecording aborted: enabled=%@ canCapture=%@ permission=%@",
                  String(describing: Defaults[.screenCaptureEnabled]),
                  String(describing: canCapture),
                  String(describing: permissionGranted))
            return
        }

        isSelectingRegion = true
        RegionSelectionController.shared.begin { [weak self] rect in
            guard let self else { return }
            self.isSelectingRegion = false
            guard let rect else { return }
            // Let the overlay's windows actually leave the screen before the recorder starts,
            // otherwise the dimming is still composited into the opening frames.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(150))
                self.beginRecording(region: rect)
            }
        }
    }

    /// The whole screen, no selection. Not part of the notch's default flow — `startRecording`
    /// is — but kept available for a deliberate "record everything" affordance.
    func startFullScreenRecording() {
        guard Defaults[.screenCaptureEnabled], canCapture, !isRecording, ensurePermission() else { return }
        beginRecording(region: nil)
    }

    /// `region` is in AppKit screen coordinates (bottom-left origin); nil records everything.
    private func beginRecording(region: CGRect?) {
        guard !isRecording else { return }
        guard let target = Self.target(for: region) else {
            lastError = "Could not work out which display to record."
            return
        }
        guard let staging = makeStagingDirectory() else {
            lastError = "Could not create a working folder for the recording."
            return
        }

        let file = staging.appendingPathComponent(Self.captureName(prefix: "Screen Recording", extension: "mov"))
        let showsCursor = Defaults[.screenCaptureIncludeCursor]

        Task { @MainActor in
            do {
                let filter = try await Self.contentFilter(for: target.display)
                var configuration = Self.configuration(for: target, showsCursor: showsCursor)
                // 60fps is what the system recorder gives; `queueDepth` above 3 is what keeps
                // frames from being dropped when the writer stalls on a slow disk.
                configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
                configuration.queueDepth = 6
                configuration.pixelFormat = kCVPixelFormatType_32BGRA

                let session = try RecordingSession(
                    filter: filter,
                    configuration: configuration,
                    outputURL: file,
                    pixelSize: target.pixelSize
                )
                try await session.start()

                self.recordingSession = session
                self.recordingStagingDirectory = staging
                self.isRecording = true
                self.recordingSeconds = 0
                self.lastError = nil
                self.startTicking()
            } catch {
                self.removeStagingDirectory(staging)
                self.refreshPermissionState()
                self.lastError = self.permissionGranted
                    ? "The recording could not be started: \(error.localizedDescription)"
                    : Self.permissionMessage
                NSLog("[capture] recording start FAILED: %@", String(describing: error))
            }
        }
    }

    /// Ends the recording and finalises the movie.
    ///
    /// The order matters and is not interchangeable: the stream stops first so no sample can
    /// arrive after the writer is told to finish, then the writer is finished, and only then
    /// does the file exist as something playable. Tearing down in the other order leaves a
    /// movie with no moov atom, which AVFoundation refuses to open at all — the same failure
    /// the old implementation hit by sending SIGTERM instead of SIGINT.
    func stopRecording() {
        guard isRecording, let session = recordingSession else { return }
        let staging = recordingStagingDirectory
        finishRecordingState()

        Task { @MainActor in
            let url = await session.finish()
            guard let staging else { return }
            if url == nil {
                self.removeStagingDirectory(staging)
                self.lastError = "The recording could not be saved."
                return
            }
            self.deliver(stagingDirectory: staging, kind: .recording)
        }
    }

    func toggleRecording() {
        if isRecording || isSelectingRegion {
            if isSelectingRegion { RegionSelectionController.shared.cancel() }
            if isRecording { stopRecording() }
        } else {
            startRecording()
        }
    }

    /// Quitting mid-recording still has to produce a playable file, and the app is going away
    /// the moment this returns — so this is the one place that blocks, bounded by the writer's
    /// own teardown rather than by a timeout we invented.
    private func finishForTermination() {
        guard isRecording, let session = recordingSession else { return }
        let staging = recordingStagingDirectory
        finishRecordingState()

        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            _ = await session.finish()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 5)

        if let staging {
            deliver(stagingDirectory: staging, kind: .recording)
        }
    }

    private func startTicking() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                guard let self, self.isRecording else { return }
                self.recordingSeconds += 1
            }
        }
    }

    private func finishRecordingState() {
        tickTask?.cancel()
        tickTask = nil
        isRecording = false
        recordingSeconds = 0
        recordingSession = nil
        recordingStagingDirectory = nil
    }

    // MARK: - System UI

    /// The ⇧⌘5 toolbar.
    ///
    /// Deliberately Screenshot.app rather than `screencapture -i -U`, which can also draw that
    /// toolbar: launched as its own app it runs outside this app's sandbox, so every control in
    /// it — including "Save to Desktop" — actually works. Spawned as our child it would inherit
    /// our container and silently fail to write wherever the user chose.
    func openSystemCaptureUI() {
        let url = URL(fileURLWithPath: "/System/Applications/Utilities/Screenshot.app")
        let configuration = NSWorkspace.OpenConfiguration()
        // Screenshot.app has to come forward to show its toolbar. This activates *it*, never
        // us — the notch window is still a non-activating panel and keeps its focus rules.
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { [weak self] _, error in
            guard let error else { return }
            Task { @MainActor in
                self?.lastError = "Could not open the Screenshot app: \(error.localizedDescription)"
            }
        }
    }

    func revealLastCapture() {
        guard let lastCaptureURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([lastCaptureURL])
    }

    // MARK: - Permission

    /// Screen Recording is TCC-gated and the grant belongs to *this* app, not to the Apple
    /// binary we spawn: a child inherits our responsible process, so the system attributes the
    /// capture to boring.notch. Without the grant `screencapture` still succeeds, but produces
    /// a picture of the desktop wallpaper with every window missing — a silent wrong answer,
    /// which is why this is checked up front rather than inferred from an exit code.
    @discardableResult
    private func ensurePermission() -> Bool {
        if CGPreflightScreenCaptureAccess() {
            permissionGranted = true
            lastError = nil
            return true
        }
        permissionGranted = false
        // Registers this app in Privacy & Security › Screen Recording and shows the prompt.
        // It returns the current (still false) answer immediately instead of blocking until
        // the user decides, so there is nothing to await and nothing that can hang.
        _ = CGRequestScreenCaptureAccess()
        // Screen Recording is granted per-app and only takes effect on a fresh launch, so the
        // message has to say "restart" — granting it while the app runs changes nothing.
        lastError = "boring.notch needs Screen Recording permission. Grant it in System Settings › Privacy & Security › Screen Recording, then restart boring.notch."
        NSLog("[screencapture] BLOCKED: Screen Recording permission not granted (CGPreflightScreenCaptureAccess == false); no capture attempted")
        return false
    }

    // MARK: - Aiming the capture

    /// One display, the rectangle to take from it, and the pixel size that rectangle should be
    /// captured at.
    private struct CaptureTarget {
        let display: NSScreen
        /// In the display's own points, TOP-left origin — what `SCStreamConfiguration.sourceRect`
        /// wants, and the opposite of the bottom-left origin AppKit hands us.
        let sourceRect: CGRect
        let pixelSize: CGSize
    }

    /// Maps a global AppKit rect onto the display that holds it.
    ///
    /// Two conversions, both easy to get silently wrong. The ORIGIN flips: AppKit's y grows
    /// upward from the bottom of the primary display, `sourceRect`'s grows downward from the
    /// top of the capture display — so a rect near the top of the screen becomes a rect near
    /// the top of the capture, and getting it wrong mirrors the capture vertically without
    /// ever erroring. And the rect is RELATIVE to its own display, so on a second monitor the
    /// display's own origin has to come out of it.
    private static func target(for region: CGRect?) -> CaptureTarget? {
        guard let screen = displayContaining(region) else { return nil }
        let scale = screen.backingScaleFactor

        guard let region else {
            let full = CGRect(origin: .zero, size: screen.frame.size)
            return CaptureTarget(
                display: screen,
                sourceRect: full,
                pixelSize: CGSize(width: full.width * scale, height: full.height * scale)
            )
        }

        let clipped = region.intersection(screen.frame)
        guard clipped.width >= 1, clipped.height >= 1 else { return nil }

        let local = CGRect(
            x: (clipped.minX - screen.frame.minX).rounded(),
            y: (screen.frame.maxY - clipped.maxY).rounded(),
            width: clipped.width.rounded(),
            height: clipped.height.rounded()
        )
        return CaptureTarget(
            display: screen,
            sourceRect: local,
            pixelSize: CGSize(width: local.width * scale, height: local.height * scale)
        )
    }

    private static func displayContaining(_ region: CGRect?) -> NSScreen? {
        guard let region else {
            let pointer = NSEvent.mouseLocation
            return NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        }
        // The screen holding the most of the selection, so a drag that strays a few points
        // over a bezel still records the display the user was working on.
        return NSScreen.screens.max {
            $0.frame.intersection(region).area < $1.frame.intersection(region).area
        } ?? NSScreen.main
    }

    /// Everything on the display except this app.
    ///
    /// Excluding ourselves is deliberate: the island is open and under the pointer whenever
    /// these controls are clicked, so without this every capture of the top of the screen
    /// would have the notch UI composited into it — including the recording overlay's own
    /// chrome. The system's capture UI hides itself for the same reason.
    private static func contentFilter(for screen: NSScreen) async throws -> SCContentFilter {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let displayID = screen.displayID
        guard let display = content.displays.first(where: { $0.displayID == displayID })
            ?? content.displays.first
        else {
            throw CaptureError.noDisplay
        }
        let own = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        return SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
    }

    private static func configuration(for target: CaptureTarget, showsCursor: Bool) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = target.sourceRect
        // Pixels, not points: without this the capture comes back at point resolution and a
        // retina screenshot is half the size it should be.
        configuration.width = Int(target.pixelSize.width)
        configuration.height = Int(target.pixelSize.height)
        configuration.showsCursor = showsCursor
        configuration.capturesAudio = false
        configuration.scalesToFit = false
        return configuration
    }

    private static func pngData(from image: CGImage) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = NSSize(width: image.width, height: image.height)
        return rep.representation(using: .png, properties: [:])
    }

    private enum CaptureError: Error {
        case noDisplay
        case writerSetupFailed
    }

    private static let permissionMessage =
        "boring.notch needs Screen Recording permission. Grant it in System Settings › Privacy & Security › Screen Recording, then restart boring.notch."

    // MARK: - Where captures land

    /// What happens to whatever the capture produced: copied, or saved.
    ///
    /// A still never reaches here when copying — `deliverStill` puts the image itself on the
    /// pasteboard and writes no file at all. A recording always produces a file, because a
    /// movie cannot live on the pasteboard the way an image can, so "copied" means the file
    /// stays inside this app's container and the pasteboard points at it.
    private func deliver(stagingDirectory: URL, kind: CaptureKind) {
        let fileManager = FileManager.default
        guard let produced = try? fileManager.contentsOfDirectory(
            at: stagingDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ), !produced.isEmpty else {
            // Cancelled, or nothing was written. Not an error to announce.
            removeStagingDirectory(stagingDirectory)
            return
        }

        guard Defaults[.screenCaptureToClipboard], kind == .recording, let movie = produced.first else {
            lastCaptureURL = relocate(produced, from: stagingDirectory)
            lastCaptureWasCopied = false
            return
        }

        let directory = Self.copiedRecordingsDirectory
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let kept = uniqueDestination(for: movie.lastPathComponent, in: directory)

        var destination = movie
        do {
            try fileManager.moveItem(at: movie, to: kept)
            destination = kept
            removeStagingDirectory(stagingDirectory)
        } catch {
            // Leave it where it is rather than lose it; the pasteboard can point at staging
            // just as well as at the tidy folder.
            NSLog("[capture] could not move recording into place: %@", String(describing: error))
        }

        copyToPasteboard(fileURL: destination)
        lastCaptureURL = destination
        lastCaptureWasCopied = true
        lastError = nil
        pruneCopiedRecordings()
    }

    /// Both representations are deliberate. `public.file-url` is what a paste target needs to
    /// receive the movie as a file (Finder, Mail, Messages, Slack). The plain string is what
    /// makes the copy *observable*: `NSPasteboard.writeObjects([url as NSURL])` alone puts no
    /// `.string` on the pasteboard (measured), so this app's own clipboard history — which
    /// reads `.string` and `public.png` — would skip the entry entirely and a "copied"
    /// recording would leave no trace anywhere.
    private func copyToPasteboard(fileURL url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .fileURL)
        item.setString(url.path, forType: .string)
        pasteboard.writeObjects([item])
    }

    /// Copied recordings are cache with a long tail: they exist only so a paste can find them,
    /// but a paste may come minutes or days later. Swept by age AND by count, because a screen
    /// recording is tens of megabytes a minute and either bound alone can be defeated.
    private func pruneCopiedRecordings() {
        let fileManager = FileManager.default
        let directory = Self.copiedRecordingsDirectory
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let dated = files.map { url -> (URL, Date) in
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return (url, modified)
        }.sorted { $0.1 > $1.1 }

        let cutoff = Date().addingTimeInterval(-Self.copiedRecordingLifetime)
        for (index, entry) in dated.enumerated() where index >= Self.copiedRecordingLimit || entry.1 < cutoff {
            try? fileManager.removeItem(at: entry.0)
        }
    }


    /// Captures are written into this app's container first and moved afterwards, never
    /// straight to the user's folder.
    ///
    /// The sandbox is the reason. A child process inherits our container, and inside it
    /// `Desktop`, `Pictures` and `Movies` are symlinks back to the real home folders that the
    /// sandbox then refuses to write through (measured: `NSCocoaErrorDomain` 513, for the
    /// parent and the child alike). Handing `screencapture -v` a path it cannot write would
    /// mean discovering the failure only after the user had recorded for ten minutes. Staging
    /// somewhere always-writable makes the capture itself unconditional, and reduces the
    /// permission question to a cheap file move that can fail harmlessly afterwards.
    private static var captureRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("BoringNotch", isDirectory: true)
            .appendingPathComponent("ScreenCaptures", isDirectory: true)
    }

    /// Resting place for recordings that were copied rather than saved.
    static var copiedRecordingsDirectory: URL {
        captureRoot.appendingPathComponent("Recordings", isDirectory: true)
    }

    /// One directory per capture: a multi-display shot makes `screencapture` write one file
    /// per screen off a single filename, and a private directory is what makes "everything
    /// this run produced" answerable without guessing at the suffixes it chose.
    private func makeStagingDirectory() -> URL? {
        let directory = Self.captureRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        } catch {
            return nil
        }
    }

    private func removeStagingDirectory(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }

    private static func captureName(prefix: String, extension ext: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "\(prefix) \(formatter.string(from: Date())).\(ext)"
    }

    private struct DestinationAccess {
        let url: URL
        let scoped: Bool

        func release() {
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
    }

    /// The bookmark is what makes a chosen folder survive a relaunch. A plain path string is
    /// kept alongside it for display, but on its own it grants nothing under the sandbox.
    private func openDestination() -> DestinationAccess? {
        if let data = Defaults[.screenCaptureSaveBookmark] {
            var isStale = false
            if let url = try? URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ), url.startAccessingSecurityScopedResource() {
                return DestinationAccess(url: url, scoped: true)
            }
        }
        let path = Defaults[.screenCaptureSaveLocation]
        guard !path.isEmpty else { return nil }
        return DestinationAccess(url: URL(fileURLWithPath: path, isDirectory: true), scoped: false)
    }

    /// Moves everything the tool produced out of staging. Returns where the user should be
    /// pointed — the nominated folder when the move worked, the staging copy when it did not.
    /// Anything that cannot be moved is deliberately left on disk rather than deleted: a
    /// capture the user cannot reach is a nuisance, one that was silently thrown away is data
    /// loss.
    @discardableResult
    private func relocate(_ produced: [URL], from stagingDirectory: URL) -> URL? {
        let fileManager = FileManager.default
        guard let destination = openDestination() else { return produced.first }
        defer { destination.release() }

        try? fileManager.createDirectory(at: destination.url, withIntermediateDirectories: true)

        var landed: URL?
        var moved = 0
        for file in produced {
            let target = uniqueDestination(for: file.lastPathComponent, in: destination.url)
            do {
                try fileManager.moveItem(at: file, to: target)
                landed = landed ?? target
                moved += 1
            } catch {
                landed = landed ?? file
                lastError = "Saved inside boring.notch — \(destination.url.lastPathComponent) is not writable. Choose the folder again in Settings › Screen capture to grant access."
            }
        }

        if moved == produced.count {
            lastError = nil
            removeStagingDirectory(stagingDirectory)
        }
        return landed
    }

    private func uniqueDestination(for name: String, in directory: URL) -> URL {
        let fileManager = FileManager.default
        var candidate = directory.appendingPathComponent(name)
        guard fileManager.fileExists(atPath: candidate.path) else { return candidate }

        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var index = 2
        repeat {
            let attempt = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            candidate = directory.appendingPathComponent(attempt)
            index += 1
        } while fileManager.fileExists(atPath: candidate.path)
        return candidate
    }

    // MARK: - Settings support

    /// Grants the sandbox access that a typed path cannot: the panel is the only way this app
    /// can be handed a folder outside its container, and the bookmark is what keeps it.
    func chooseSaveLocation() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose where screenshots and recordings are saved."
        let current = Defaults[.screenCaptureSaveLocation]
        if !current.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: current, isDirectory: true)
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }
        Defaults[.screenCaptureSaveLocation] = url.path
        Defaults[.screenCaptureSaveBookmark] = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        lastError = nil
    }

    func refreshPermissionState() {
        permissionGranted = CGPreflightScreenCaptureAccess()
    }

    func revealCopiedRecordings() {
        let directory = Self.copiedRecordingsDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([directory])
    }
}


// MARK: - Recording session

/// One recording: an `SCStream` feeding an `AVAssetWriter`.
///
/// Deliberately NOT `@MainActor`. ScreenCaptureKit delivers frames on its own queue at 60fps,
/// and hopping every one of them to the main actor would put the encoder behind the island's
/// own animations. All writer state is confined to `queue` instead, which is also the queue
/// the frames arrive on, so there is one owner and no lock.
private final class RecordingSession: NSObject, SCStreamOutput, @unchecked Sendable {
    private let stream: SCStream
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let outputURL: URL
    private let queue = DispatchQueue(label: "com.boringnotch.recording", qos: .userInitiated)

    private var sessionStarted = false
    private var finished = false

    init(filter: SCContentFilter, configuration: SCStreamConfiguration, outputURL: URL, pixelSize: CGSize) throws {
        self.outputURL = outputURL
        writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(pixelSize.width),
                AVVideoHeightKey: Int(pixelSize.height)
            ]
        )
        // Frames arrive at wall-clock rate and cannot be re-requested, so the input must be
        // told to expect that rather than assume it can pull faster than real time.
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw RecordingSessionError.writerRejectedInput }
        writer.add(input)
        stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        super.init()
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
    }

    func start() async throws {
        guard writer.startWriting() else {
            throw writer.error ?? RecordingSessionError.writerRejectedInput
        }
        try await stream.startCapture()
    }

    /// Returns the finished movie, or nil if nothing recordable ever arrived.
    ///
    /// The stream is stopped BEFORE the writer is finished, so no frame can land after
    /// `markAsFinished()`. The reverse order is what produces a file with no moov atom —
    /// present on disk, refused by every player.
    func finish() async -> URL? {
        try? await stream.stopCapture()
        return await withCheckedContinuation { continuation in
            queue.async {
                guard !self.finished else {
                    continuation.resume(returning: nil)
                    return
                }
                self.finished = true
                guard self.sessionStarted else {
                    // Not one complete frame arrived: cancel rather than finish, which leaves
                    // no stub file to be mistaken for a recording.
                    self.writer.cancelWriting()
                    continuation.resume(returning: nil)
                    return
                }
                self.input.markAsFinished()
                self.writer.finishWriting {
                    continuation.resume(returning: self.writer.status == .completed ? self.outputURL : nil)
                }
            }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, !finished, sampleBuffer.isValid else { return }

        // ScreenCaptureKit emits frames for idle and blanked states too, carrying no pixels.
        // Appending one starts the movie with a frame that has nothing in it, so the status
        // attachment decides what counts.
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]],
            let rawStatus = attachments.first?[.status] as? Int,
            SCFrameStatus(rawValue: rawStatus) == .complete
        else { return }

        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if !sessionStarted {
            // The session starts at the FIRST real frame, not at zero: starting earlier pads
            // the movie with the gap between `startWriting()` and the stream warming up.
            writer.startSession(atSourceTime: timestamp)
            sessionStarted = true
        }
        guard input.isReadyForMoreMediaData else { return }
        input.append(sampleBuffer)
    }
}

private enum RecordingSessionError: Error {
    case writerRejectedInput
}

private extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            ?? CGMainDisplayID()
    }
}

private extension CGRect {
    var area: CGFloat { width * height }
}

// MARK: - Region selection

/// Drag-to-select overlay used to pick the rectangle for a recording.
///
/// This exists only because `screencapture` will not do it: `-i` covers stills, but the tool
/// rejects `-v -i` outright, leaving `-R x,y,w,h` as the only way to record part of the screen.
@MainActor
final class RegionSelectionController {
    static let shared = RegionSelectionController()

    private var panels: [RegionSelectionPanel] = []
    private var completion: ((CGRect?) -> Void)?
    private var escapeMonitor: Any?

    private init() {}

    var isSelecting: Bool { !panels.isEmpty }

    func begin(completion: @escaping (CGRect?) -> Void) {
        guard panels.isEmpty else { return }
        self.completion = completion

        // One panel per screen so a region can be dragged out on any display.
        for screen in NSScreen.screens {
            let panel = RegionSelectionPanel(screen: screen)
            panel.onFinish = { [weak self] rect in
                self?.finish(with: rect)
            }
            panel.orderFrontRegardless()
            panels.append(panel)
        }

        // Local only, like the flashlight's: a global Esc would need Input Monitoring, a
        // privacy permission this feature should not take unilaterally. Right-click and a
        // click without a drag also cancel, so there is always a mouse-only way out.
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            Task { @MainActor in self?.finish(with: nil) }
            return nil
        }
    }

    func cancel() {
        guard isSelecting else { return }
        finish(with: nil)
    }

    private func finish(with rect: CGRect?) {
        guard let completion else { return }
        self.completion = nil

        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }
        for panel in panels { panel.orderOut(nil) }
        panels.removeAll()

        // A stray click produces a degenerate rectangle; treat anything too small to record as
        // a cancellation rather than starting a 3-pixel recording.
        if let rect, rect.width >= 8, rect.height >= 8 {
            completion(rect)
        } else {
            completion(nil)
        }
    }
}

/// Never key, never main. The notch must not steal focus, and a selection overlay that
/// activated the app would pull the user out of whatever they were about to record.
final class RegionSelectionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    var onFinish: ((CGRect?) -> Void)? {
        get { view.onFinish }
        set { view.onFinish = newValue }
    }

    private let view = RegionSelectionView()

    init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = false
        // Above the flashlight (+2) and below the notch itself (+3) would hide the selection
        // behind the notch; the overlay has to sit above everything it is being used to frame.
        level = .mainMenu + 4
        collectionBehavior = [.fullScreenAuxiliary, .stationary, .canJoinAllSpaces, .ignoresCycle]
        // Never composited into the recording it is being used to set up.
        sharingType = .none
        setFrame(screen.frame, display: false)
        contentView = view
    }
}

private final class RegionSelectionView: NSView {
    var onFinish: ((CGRect?) -> Void)?

    private var anchor: NSPoint?
    private var selection: NSRect = .zero

    override var acceptsFirstResponder: Bool { true }
    // Without this the first click is swallowed as an activation click and the drag is lost.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        anchor = convert(event.locationInWindow, from: nil)
        selection = .zero
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let anchor else { return }
        let point = convert(event.locationInWindow, from: nil)
        selection = NSRect(
            x: min(anchor.x, point.x),
            y: min(anchor.y, point.y),
            width: abs(point.x - anchor.x),
            height: abs(point.y - anchor.y)
        )
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            anchor = nil
            selection = .zero
        }
        guard let window, selection.width >= 1, selection.height >= 1 else {
            onFinish?(nil)
            return
        }
        onFinish?(window.convertToScreen(convert(selection, to: nil)))
    }

    override func rightMouseDown(with event: NSEvent) {
        onFinish?(nil)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current else { return }
        NSColor.black.withAlphaComponent(0.28).setFill()
        bounds.fill()

        guard selection.width > 0, selection.height > 0 else { return }
        // Punch the selection out of the dimming so the user sees exactly what will be
        // recorded, rather than a tinted approximation of it.
        context.cgContext.setBlendMode(.clear)
        selection.fill()
        context.cgContext.setBlendMode(.normal)

        NSColor.white.withAlphaComponent(0.9).setStroke()
        let border = NSBezierPath(rect: selection.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        border.stroke()
    }
}
