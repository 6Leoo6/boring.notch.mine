//
//  HubScreenCapture.swift
//  boringNotch
//
//  hubcast S2 (hub docs/SCREEN.md, D-153): this app captures a display or a window with
//  ScreenCaptureKit, encodes it with VideoToolbox (H.264, real time, no reordering) and hands
//  the access units to the embedded hub helper over a loopback TCP connection
//  (`HubScreenLink`). The helper does the WebRTC to the viewer on another device; the capture
//  lives here because this app holds the Screen Recording permission.
//
//  The helper drives it through the agent bridge: `screen.capture.sources`,
//  `screen.capture.start {session, source, width, height, fps, bitrate_kbps, profile,
//  ingest_port, ingest_token}` and `screen.capture.stop {session}`.
//

import AppKit
import CoreMedia
import CoreVideo
import Foundation
import Network
import ScreenCaptureKit
import VideoToolbox

final class HubScreenCapture: @unchecked Sendable {
    static let shared = HubScreenCapture()

    struct Failure: Error {
        let message: String
        let code: String?
        init(_ message: String, code: String? = nil) {
            self.message = message
            self.code = code
        }
    }

    static let maxSessions = 3
    static let permissionHint = "Allow Screen Recording for boringNotch: System Settings > Privacy & Security > Screen & System Audio Recording, then restart the notch"

    private let lock = NSLock()
    private var sessions: [String: HubScreenSession] = [:]

    // MARK: - Sources

    func sources() async throws -> HubRPC.ScreenSourcesResult {
        let screens = await MainActor.run { Self.screenInfo() }
        guard CGPreflightScreenCaptureAccess() else {
            await MainActor.run { _ = CGRequestScreenCaptureAccess() }
            let sources = screens.map { s in
                HubRPC.ScreenSource(height: Int64(s.pixelHeight), id: HubScreenLink.SourceID.display(s.id).string, kind: .monitor,
                                    name: s.name, refreshHz: s.refreshHz, streamable: false, why: Self.permissionHint, width: Int64(s.pixelWidth))
            }
            return HubRPC.ScreenSourcesResult(capture: "notch", codecs: ["h264"], sources: sources)
        }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        } catch {
            throw Failure("Screen capture is not available: \(error.localizedDescription)", code: "unavailable")
        }

        var out: [HubRPC.ScreenSource] = []
        let byID = Dictionary(screens.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let displays = content.displays.sorted { a, b in
            (byID[a.displayID]?.isMain == true ? 0 : 1, a.displayID) < (byID[b.displayID]?.isMain == true ? 0 : 1, b.displayID)
        }
        for d in displays {
            let info = byID[d.displayID]
            out.append(HubRPC.ScreenSource(
                height: Int64(info?.pixelHeight ?? d.height), id: HubScreenLink.SourceID.display(d.displayID).string, kind: .monitor,
                name: info?.name ?? "Display \(d.displayID)", refreshHz: info?.refreshHz, streamable: true,
                width: Int64(info?.pixelWidth ?? d.width)))
        }

        let ownBundle = Bundle.main.bundleIdentifier
        let frontPID = await MainActor.run { NSWorkspace.shared.frontmostApplication?.processIdentifier }
        var focusedGiven = false
        var windows = 0
        for w in content.windows {
            guard windows < 80, w.windowLayer == 0, w.isOnScreen, w.frame.width >= 64, w.frame.height >= 48,
                  let app = w.owningApplication, app.bundleIdentifier != ownBundle
            else { continue }
            let appName = app.applicationName.isEmpty ? app.bundleIdentifier : app.applicationName
            let title = (w.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let center = CGPoint(x: w.frame.midX, y: w.frame.midY)
            let screen = screens.first { $0.frame.contains(center) } ?? screens.first
            let scale = screen?.scale ?? 2
            var focused: Bool?
            if !focusedGiven, let frontPID, app.processID == frontPID {
                focused = true
                focusedGiven = true
            }
            out.append(HubRPC.ScreenSource(
                app: appName, focused: focused, height: Int64((w.frame.height * scale).rounded()),
                id: HubScreenLink.SourceID.window(w.windowID).string, kind: .window, monitor: screen?.name,
                name: title.isEmpty ? appName : title, streamable: true, width: Int64((w.frame.width * scale).rounded())))
            windows += 1
        }
        return HubRPC.ScreenSourcesResult(capture: "notch", codecs: ["h264"], sources: out)
    }

    struct ScreenInfo: Sendable {
        let id: CGDirectDisplayID
        let name: String
        /// Global coordinates with the origin at the top left (ScreenCaptureKit's), not AppKit's.
        let frame: CGRect
        let scale: CGFloat
        let pixelWidth: Int
        let pixelHeight: Int
        let refreshHz: Double?
        let isMain: Bool
    }

    @MainActor
    static func screenInfo() -> [ScreenInfo] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let id = CGDirectDisplayID(number.uint32Value)
            let mode = CGDisplayCopyDisplayMode(id)
            let scale = screen.backingScaleFactor
            var hz = mode?.refreshRate ?? 0
            if hz <= 0 { hz = Double(screen.maximumFramesPerSecond) }
            return ScreenInfo(
                id: id, name: screen.localizedName, frame: CGDisplayBounds(id), scale: scale,
                pixelWidth: mode?.pixelWidth ?? Int(screen.frame.width * scale),
                pixelHeight: mode?.pixelHeight ?? Int(screen.frame.height * scale),
                refreshHz: hz > 0 ? hz : nil, isMain: CGDisplayIsMain(id) != 0)
        }
    }

    // MARK: - Start / stop

    func start(_ p: HubRPC.ScreenCaptureStartParams) async throws -> HubRPC.ScreenCaptureStartResult {
        guard !p.session.isEmpty, p.session.count <= 128 else { throw Failure("session must be 1 to 128 characters", code: "invalid_params") }
        guard !p.ingestToken.isEmpty, p.ingestToken.count <= 512 else { throw Failure("ingest_token must not be empty", code: "invalid_params") }
        guard (1...65535).contains(p.ingestPort) else { throw Failure("ingest_port must be a TCP port", code: "invalid_params") }
        guard let source = HubScreenLink.SourceID(p.source) else { throw Failure("No screen source \(p.source)", code: "not_found") }
        guard CGPreflightScreenCaptureAccess() else {
            await MainActor.run { _ = CGRequestScreenCaptureAccess() }
            throw Failure(Self.permissionHint, code: "unavailable")
        }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        } catch {
            throw Failure("Screen capture is not available: \(error.localizedDescription)", code: "unavailable")
        }
        let filter: SCContentFilter
        switch source {
        case .display(let id):
            guard let d = content.displays.first(where: { $0.displayID == id }) else { throw Failure("No screen source \(p.source)", code: "not_found") }
            filter = SCContentFilter(display: d, excludingWindows: [])
        case .window(let id):
            guard let w = content.windows.first(where: { $0.windowID == id }) else { throw Failure("No screen source \(p.source) (the window is gone)", code: "not_found") }
            filter = SCContentFilter(desktopIndependentWindow: w)
        }

        let fps = min(max(Int(p.fps ?? 60), 1), 120)
        let session = HubScreenSession(
            id: p.session, filter: filter, box: (Int(p.width ?? 0), Int(p.height ?? 0)), fps: fps,
            kbps: Int(p.bitrateKbps ?? 0), profile: p.profile?.rawValue ?? "high",
            port: UInt16(p.ingestPort), token: p.ingestToken, owner: self)

        try register(session)
        session.begin()
        return HubRPC.ScreenCaptureStartResult(accepted: true)
    }

    private func register(_ session: HubScreenSession) throws {
        lock.lock()
        defer { lock.unlock() }
        if sessions[session.id] != nil { throw Failure("session \(session.id) is already capturing", code: "invalid_params") }
        if sessions.count >= Self.maxSessions { throw Failure("already capturing \(Self.maxSessions) streams", code: "unavailable") }
        sessions[session.id] = session
    }

    func stop(_ id: String) -> HubRPC.ScreenStopResult {
        lock.lock()
        let session = sessions.removeValue(forKey: id)
        lock.unlock()
        guard let session else { return HubRPC.ScreenStopResult(stopped: false) }
        let stats = session.end(reason: nil, sendEnd: true)
        return HubRPC.ScreenStopResult(bytes: stats.bytes, frames: stats.frames, seconds: stats.seconds, stopped: true)
    }

    fileprivate func ended(_ session: HubScreenSession) {
        lock.lock()
        if sessions[session.id] === session { sessions.removeValue(forKey: session.id) }
        lock.unlock()
    }
}

/// One capture: SCStream -> VTCompressionSession -> the helper's ingest socket. Everything
/// mutable lives on `queue`.
final class HubScreenSession: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let id: String
    private let filter: SCContentFilter
    private let box: (Int, Int)
    private let fps: Int
    private var kbps: Int
    private let profile: String
    private let port: UInt16
    private let token: String
    private weak var owner: HubScreenCapture?

    private let queue: DispatchQueue
    private var connection: NWConnection?
    private var stream: SCStream?
    private var encoder: VTCompressionSession?
    private var lines = HubScreenLink.LineReader()
    private var sourceSize = (width: 0, height: 0)
    private var outSize = (width: 0, height: 0)
    private var lastBuffer: CVPixelBuffer?
    private var lastEncode: CFTimeInterval = 0
    private var forceKey = true
    private var inFlightBytes = 0
    private var refresh: DispatchSourceTimer?
    private var connectTimeout: DispatchWorkItem?
    private var ended = false
    private var started = Date()
    private var frames: Int64 = 0
    private var bytes: Int64 = 0

    /// Above this much unsent video, delta frames are dropped and the next frame is an IDR.
    private static let maxInFlight = 6 << 20
    /// ScreenCaptureKit only delivers a frame when something changed; the link wants a picture
    /// at least this often (docs/SCREEN.md: >= 1 fps for static content).
    private static let repeatInterval: CFTimeInterval = 0.5

    init(id: String, filter: SCContentFilter, box: (Int, Int), fps: Int, kbps: Int, profile: String,
         port: UInt16, token: String, owner: HubScreenCapture) {
        self.id = id
        self.filter = filter
        self.box = box
        self.fps = fps
        self.kbps = kbps
        self.profile = profile
        self.port = port
        self.token = token
        self.owner = owner
        self.queue = DispatchQueue(label: "boringNotch.hubcast.\(id)", qos: .userInteractive)
    }

    // MARK: Lifecycle

    func begin() {
        queue.async { self.connect() }
    }

    private func connect() {
        guard let port = NWEndpoint.Port(rawValue: self.port) else { return finish("bad ingest port") }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let c = NWConnection(host: .ipv4(.loopback), port: port, using: NWParameters(tls: nil, tcp: tcp))
        connection = c
        c.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.connectTimeout?.cancel()
                self.connected()
            case .failed(let error):
                self.finish("ingest connection failed: \(error.localizedDescription)", sendError: false)
            case .waiting(let error):
                self.finish("ingest connection refused: \(error.localizedDescription)", sendError: false)
            default: break
            }
        }
        let timeout = DispatchWorkItem { [weak self] in self?.finish("ingest connection timed out", sendError: false) }
        connectTimeout = timeout
        queue.asyncAfter(deadline: .now() + 8, execute: timeout)
        c.start(queue: queue)
    }

    private func connected() {
        guard !ended, let connection else { return }
        connection.send(content: HubScreenLink.helloLine(session: id, token: token), completion: .contentProcessed { _ in })
        receive()
        Task { await self.startCapture() }
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                for control in self.lines.append(data) { self.handle(control) }
            }
            if complete || error != nil {
                self.finish(nil, sendError: false)
                return
            }
            if !self.ended { self.receive() }
        }
    }

    private func startCapture() async {
        let info = SCShareableContent.info(for: filter)
        let scale = CGFloat(info.pointPixelScale)
        let size = (width: Int((info.contentRect.width * scale).rounded()), height: Int((info.contentRect.height * scale).rounded()))
        let out = HubScreenLink.fit(width: size.width, height: size.height, boxWidth: box.0, boxHeight: box.1)

        let config = configuration(width: out.width, height: out.height)
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        } catch {
            queue.async { self.finish("capture setup failed: \(error.localizedDescription)") }
            return
        }

        let ready: Bool = queue.sync {
            guard !self.ended else { return false }
            self.sourceSize = size
            self.outSize = out
            if self.kbps <= 0 { self.kbps = HubScreenLink.defaultKbps(width: out.width, height: out.height, fps: self.fps) }
            if let failure = self.makeEncoder() {
                self.finish(failure)
                return false
            }
            self.stream = stream
            self.sendInfo()
            return true
        }
        guard ready else { return }

        do {
            try await stream.startCapture()
        } catch {
            queue.async {
                let denied = (error as NSError).code == SCStreamError.userDeclined.rawValue
                self.finish(denied ? HubScreenCapture.permissionHint : "capture failed: \(error.localizedDescription)")
            }
            return
        }
        queue.async { self.startRefresh() }
    }

    private func configuration(width: Int, height: Int) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.showsCursor = true
        config.queueDepth = 3
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.colorSpaceName = CGColorSpace.sRGB
        config.scalesToFit = true
        config.preservesAspectRatio = true
        config.capturesAudio = false
        return config
    }

    private func startRefresh() {
        guard !ended else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        timer.setEventHandler { [weak self] in
            guard let self, !self.ended, let buffer = self.lastBuffer else { return }
            if CACurrentMediaTime() - self.lastEncode >= Self.repeatInterval { self.encode(buffer) }
        }
        timer.resume()
        refresh = timer
    }

    /// Stops everything once. `reason` non-nil: something failed, and the helper hears why.
    private func finish(_ reason: String?, sendError: Bool = true) {
        _ = shutdown(reason: reason, sendError: sendError, sendEnd: false)
    }

    struct Stats {
        let frames: Int64
        let bytes: Int64
        let seconds: Double
    }

    /// From `screen.capture.stop` (any thread): stop, tell the helper the stream ended.
    func end(reason: String?, sendEnd: Bool) -> Stats {
        queue.sync { shutdown(reason: reason, sendError: true, sendEnd: sendEnd) }
    }

    private func shutdown(reason: String?, sendError: Bool, sendEnd: Bool) -> Stats {
        let stats = Stats(frames: frames, bytes: bytes, seconds: Date().timeIntervalSince(started))
        guard !ended else { return stats }
        ended = true
        connectTimeout?.cancel()
        refresh?.cancel()
        refresh = nil
        lastBuffer = nil
        if let stream {
            self.stream = nil
            Task { try? await stream.stopCapture() }
        }
        if let encoder {
            self.encoder = nil
            VTCompressionSessionInvalidate(encoder)
        }
        if let connection {
            self.connection = nil
            var last: Data?
            if let reason, sendError {
                last = HubScreenLink.frame(.error, payload: HubScreenLink.errorPayload(reason))
            } else if sendEnd {
                last = HubScreenLink.frame(.end)
            }
            if let last, connection.state == .ready {
                connection.send(content: last, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
            } else {
                connection.cancel()
            }
        }
        if let reason { NSLog("hubcast: session %@ ended: %@", id, reason) }
        owner?.ended(self)
        return stats
    }

    // MARK: Control

    private func handle(_ control: HubScreenLink.Control) {
        guard !ended else { return }
        switch control {
        case .keyframe:
            forceKey = true
            if let lastBuffer { encode(lastBuffer) }
        case .bitrate(let kbps):
            self.kbps = min(kbps, 200_000)
            if let encoder { applyBitrate(encoder) }
        case .size(let w, let h):
            resize(box: (min(w, 8192), min(h, 8192)))
        case .stop:
            finish(nil, sendError: false)
        }
    }

    private func resize(box: (Int, Int)) {
        let out = HubScreenLink.fit(width: sourceSize.width, height: sourceSize.height, boxWidth: box.0, boxHeight: box.1)
        guard out != outSize, let stream else { return }
        outSize = out
        // Frames of the old size until the stream catches up are scaled by VideoToolbox.
        if let failure = makeEncoder() { return finish(failure) }
        sendInfo()
        let config = configuration(width: out.width, height: out.height)
        Task {
            do {
                try await stream.updateConfiguration(config)
            } catch {
                self.queue.async { self.finish("capture resize failed: \(error.localizedDescription)") }
            }
        }
    }

    // MARK: Encoder

    /// (Re)creates the VideoToolbox session at `outSize`. Returns why it failed, or nil.
    private func makeEncoder() -> String? {
        if let encoder {
            self.encoder = nil
            VTCompressionSessionInvalidate(encoder)
        }
        let lowLatency = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true] as CFDictionary
        var created: VTCompressionSession?
        var status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(outSize.width), height: Int32(outSize.height), codecType: kCMVideoCodecType_H264,
            encoderSpecification: lowLatency, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &created)
        if status != noErr || created == nil {
            status = VTCompressionSessionCreate(
                allocator: nil, width: Int32(outSize.width), height: Int32(outSize.height), codecType: kCMVideoCodecType_H264,
                encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
                outputCallback: nil, refcon: nil, compressionSessionOut: &created)
        }
        guard status == noErr, let session = created else { return "H.264 encoder unavailable (\(status))" }

        func set(_ key: CFString, _ value: CFTypeRef) -> OSStatus { VTSessionSetProperty(session, key: key, value: value) }
        _ = set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        _ = set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        _ = set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 4 as CFNumber)
        _ = set(kVTCompressionPropertyKey_ExpectedFrameRate, fps as CFNumber)
        // Low-latency rate control takes the constrained profiles; High as asked for in the
        // SDP is satisfied by Constrained High (High without B-frames).
        let profiles: [CFString]
        switch profile {
        case "constrained-baseline": profiles = [kVTProfileLevel_H264_ConstrainedBaseline_AutoLevel, kVTProfileLevel_H264_Baseline_AutoLevel]
        case "main": profiles = [kVTProfileLevel_H264_Main_AutoLevel, kVTProfileLevel_H264_ConstrainedBaseline_AutoLevel]
        default: profiles = [kVTProfileLevel_H264_ConstrainedHigh_AutoLevel, kVTProfileLevel_H264_High_AutoLevel]
        }
        if !profiles.contains(where: { set(kVTCompressionPropertyKey_ProfileLevel, $0) == noErr }) {
            NSLog("hubcast: no H.264 profile accepted for %@; encoder default", profile)
        }
        applyBitrate(session)
        VTCompressionSessionPrepareToEncodeFrames(session)
        encoder = session
        forceKey = true
        return nil
    }

    private func applyBitrate(_ session: VTCompressionSession) {
        let bps = kbps * 1000
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bps as CFNumber)
        // Bytes per one-second window: 1.5x the average leaves room for a keyframe.
        let limits = [Int(Double(bps) / 8 * 1.5) as CFNumber, 1 as CFNumber] as CFArray
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: limits)
    }

    private func sendInfo() {
        let payload = HubScreenLink.infoPayload(profile: profile, width: outSize.width, height: outSize.height, fps: fps)
        if let frame = HubScreenLink.frame(.info, payload: payload) { send(frame) }
    }

    // MARK: Capture output

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, !ended, sampleBuffer.isValid else { return }
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: raw) == .complete,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }
        lastBuffer = buffer
        encode(buffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async {
            let code = (error as NSError).code
            let message: String
            if code == SCStreamError.userDeclined.rawValue {
                message = HubScreenCapture.permissionHint
            } else if code == SCStreamError.noWindowList.rawValue || code == SCStreamError.attemptToStartStreamState.rawValue {
                message = "capture stopped: \(error.localizedDescription)"
            } else {
                message = "capture stopped (the window or display went away?): \(error.localizedDescription)"
            }
            self.finish(message)
        }
    }

    private func encode(_ buffer: CVPixelBuffer) {
        guard let encoder, !ended else { return }
        let key = forceKey
        forceKey = false
        lastEncode = CACurrentMediaTime()
        let pts = CMClockGetTime(CMClockGetHostTimeClock())
        let properties = key ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        let status = VTCompressionSessionEncodeFrame(
            encoder, imageBuffer: buffer, presentationTimeStamp: pts, duration: .invalid,
            frameProperties: properties, infoFlagsOut: nil
        ) { [weak self] status, _, sample in
            guard let self else { return }
            guard status == noErr, let sample else {
                self.queue.async { self.forceKey = true }
                return
            }
            let out = Self.annexB(sample)
            self.queue.async { self.deliver(out) }
        }
        if status != noErr {
            forceKey = true
            if status == kVTInvalidSessionErr { finish("encoder stopped (\(status))") }
        }
    }

    private struct Encoded {
        let data: Data
        let key: Bool
        let pts: UInt64
    }

    private static func annexB(_ sample: CMSampleBuffer) -> Encoded? {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return nil }
        let length = CMBlockBufferGetDataLength(block)
        var avcc = Data(count: length)
        let copied = avcc.withUnsafeMutableBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: base)
        }
        guard copied == kCMBlockBufferNoErr else { return nil }

        var key = true
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]],
           let first = attachments.first, let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool {
            key = !notSync
        }

        var lengthSize: Int32 = 4
        var parameterSets: [Data] = []
        if let format = CMSampleBufferGetFormatDescription(sample) {
            var count = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                parameterSetCountOut: &count, nalUnitHeaderLengthOut: &lengthSize)
            if key {
                for i in 0..<count {
                    var pointer: UnsafePointer<UInt8>?
                    var size = 0
                    if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                        format, parameterSetIndex: i, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                        parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let pointer {
                        parameterSets.append(Data(bytes: pointer, count: size))
                    }
                }
            }
        }
        guard let data = HubScreenLink.annexB(avcc: avcc, lengthSize: Int(lengthSize), parameterSets: parameterSets) else { return nil }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        let micros = pts.isValid ? UInt64(max(0, CMTimeGetSeconds(pts) * 1_000_000)) : UInt64(CACurrentMediaTime() * 1_000_000)
        return Encoded(data: data, key: key, pts: micros)
    }

    private func deliver(_ encoded: Encoded?) {
        guard !ended else { return }
        guard let encoded else {
            forceKey = true
            return
        }
        if !encoded.key && (inFlightBytes > Self.maxInFlight || forceKey) {
            // Behind (or waiting for a keyframe after a drop): a delta frame now would only
            // add delay or decode against a missing reference.
            forceKey = true
            return
        }
        guard let frame = HubScreenLink.frame(.video, keyframe: encoded.key, ptsMicros: encoded.pts, payload: encoded.data) else {
            forceKey = true
            return
        }
        frames += 1
        bytes += Int64(encoded.data.count)
        send(frame)
    }

    private func send(_ data: Data) {
        guard let connection else { return }
        inFlightBytes += data.count
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.queue.async {
                self.inFlightBytes -= data.count
                if let error { self.finish("ingest connection lost: \(error.localizedDescription)", sendError: false) }
            }
        })
    }
}
