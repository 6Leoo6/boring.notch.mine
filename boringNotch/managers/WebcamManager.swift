//
//  WebcamManager.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 19/08/24.
//
import AVFoundation
import SwiftUI

class WebcamManager: NSObject, ObservableObject {
    static let shared = WebcamManager()
    
    @Published var previewLayer: AVCaptureVideoPreviewLayer?
    
    private var captureSession: AVCaptureSession?
    /// Kept so a still can be pulled from the running session. The session is built with this
    /// output and a nil delegate, so no frames are delivered until something asks for one.
    private var videoOutput: AVCaptureVideoDataOutput?
    private var frameGrabber: FrameGrabber?
    private let frameQueue = DispatchQueue(label: "BoringNotch.WebcamManager.FrameQueue", qos: .userInitiated)
    @Published var isSessionRunning: Bool = false
    
    @Published var authorizationStatus: AVAuthorizationStatus = .notDetermined
    
    @Published var cameraAvailable: Bool = false

    private let sessionQueue = DispatchQueue(label: "BoringNotch.WebcamManager.SessionQueue", qos: .userInitiated)
    
    // only accessed on sessionQueue
    private var isSettingUp: Bool = false
    private var setupGeneration: Int = 0
    
    // MARK: - Constants
    
    enum WebcamError: Error, LocalizedError {
        case deviceUnavailable
        case accessDenied
        case configurationFailed(String)
        
        var errorDescription: String? {
            switch self {
            case .deviceUnavailable:
                return "No camera devices available"
            case .accessDenied:
                return "Camera access denied"
            case .configurationFailed(let message):
                return "Camera configuration failed: \(message)"
            }
        }
    }
    
    // MARK: - Properties
    
    private override init() {
        super.init()
        // Resolve the real status up front. `checkAndRequestVideoAuthorization()` is the only
        // thing that refreshes this cache, and every one of its callers sits inside a
        // `case .notDetermined:` — so the cache is self-gating, and without this line the
        // first click of every launch is spent resolving it instead of opening the mirror.
        // This overload only reads; it never prompts.
        authorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
        NotificationCenter.default.addObserver(self, selector: #selector(deviceWasDisconnected), name: .AVCaptureDeviceWasDisconnected, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(deviceWasConnected), name: .AVCaptureDeviceWasConnected, object: nil)
        checkCameraAvailability()
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        
        if let session = captureSession {
            if session.isRunning {
                session.stopRunning()
            }
        }
        captureSession = nil
            
        previewLayer = nil
    }

    // MARK: - Camera Management
    
    /// Checks current authorization status and requests access if needed
    func checkAndRequestVideoAuthorization() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        DispatchQueue.main.async {
            self.authorizationStatus = status
        }
        
        switch status {
        case .authorized:
            checkCameraAvailability() // Check availability if authorized
        case .notDetermined:
            requestVideoAccess()
        case .denied, .restricted:
            NSLog("Camera access denied or restricted")
        @unknown default:
            NSLog("Unknown authorization status")
        }
    }
    
    /// Requests access to the camera
    private func requestVideoAccess() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            DispatchQueue.main.async {
                self?.authorizationStatus = granted ? .authorized : .denied
                if granted {
                    self?.checkCameraAvailability() // Check availability if access granted
                }
            }
        }
    }
    
    /// Checks if any camera devices are available and sets up capture session if needed
    func checkCameraAvailability() {
        let availableDevices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external, .builtInWideAngleCamera],
            mediaType: .video,
            position: .unspecified
        ).devices
        
        let hasAvailableDevices = !availableDevices.isEmpty
        
        DispatchQueue.main.async {
            self.cameraAvailable = hasAvailableDevices
        }
    }
    
    /// Sets up the capture session with a completion handler
    private func setupCaptureSession(completion: @escaping (Bool) -> Void) {
        sessionQueue.async { [weak self] in
            guard let self = self else { 
                completion(false)
                return 
            }
            
            // Clean up any existing session before creating a new one
            self.cleanupExistingSession()
            
            let session = AVCaptureSession()
            
            do {
                // Get available devices and prefer external camera if available
                let discoverySession = AVCaptureDevice.DiscoverySession(
                    deviceTypes: [.external, .builtInWideAngleCamera],
                    mediaType: .video,
                    position: .unspecified
                )
                
                guard let videoDevice = discoverySession.devices.first else {
                    NSLog("No video devices available")
                    DispatchQueue.main.async {
                        self.isSessionRunning = false
                    }
                    completion(false)
                    return
                }
                
                NSLog("Using camera: \(videoDevice.localizedName)")
                
                // Lock device for configuration
                try videoDevice.lockForConfiguration()
                defer { videoDevice.unlockForConfiguration() }
                
                let videoInput = try AVCaptureDeviceInput(device: videoDevice)
                guard session.canAddInput(videoInput) else {
                    throw NSError(domain: "BoringNotch.WebcamManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Cannot add video input"])
                }
                
                session.beginConfiguration()
                session.sessionPreset = .high
                session.addInput(videoInput)
                
                let videoOutput = AVCaptureVideoDataOutput()
                videoOutput.setSampleBufferDelegate(nil, queue: nil)
                if session.canAddOutput(videoOutput) {
                    session.addOutput(videoOutput)
                    self.videoOutput = videoOutput
                }
                session.commitConfiguration()
                
                self.captureSession = session
                
                // Create and set up preview layer on main thread
                DispatchQueue.main.async {
                    self.cameraAvailable = true
                    let previewLayer = AVCaptureVideoPreviewLayer(session: session)
                    previewLayer.videoGravity = .resizeAspectFill
                    self.previewLayer = previewLayer
                    
                    // Setup is complete, let the caller know
                    completion(true)
                }
                
                NSLog("Capture session setup completed successfully")
            } catch {
                NSLog("Failed to setup capture session: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.isSessionRunning = false
                    self.previewLayer = nil
                }
                completion(false)
            }
        }
    }
    
    // MARK: - Stills

    /// The next frame from the running session, or nil.
    ///
    /// A delegate is attached only for the length of this call and detached the moment a frame
    /// arrives. That is the whole point: the session is otherwise built with a nil delegate, so
    /// the mirror costs nothing per frame at rest, and a still costs one frame's work. Holding
    /// the newest frame permanently would mean decoding and retaining 30 frames a second for a
    /// button nobody may press.
    ///
    /// Bounded rather than trusting: a session that is running but starved (device grabbed by
    /// another app mid-call) would otherwise leave the continuation suspended forever and the
    /// shutter stuck.
    func nextFrame(timeout: TimeInterval = 1.0) async -> CGImage? {
        guard isSessionRunning, let output = videoOutput else { return nil }

        return await withCheckedContinuation { continuation in
            let grabber = FrameGrabber { [weak self] image in
                output.setSampleBufferDelegate(nil, queue: nil)
                self?.frameGrabber = nil
                continuation.resume(returning: image)
            }
            frameGrabber = grabber
            output.setSampleBufferDelegate(grabber, queue: frameQueue)

            frameQueue.asyncAfter(deadline: .now() + timeout) {
                grabber.expire()
            }
        }
    }

    private func cleanupExistingSession() {
        guard let existingSession = captureSession else { return }
        if existingSession.isRunning {
            existingSession.stopRunning()
        }
        captureSession = nil
        DispatchQueue.main.async {
            self.previewLayer = nil
        }
    }

    @objc private func deviceWasDisconnected(notification: Notification) {
        NSLog("Camera device was disconnected")
        stopSession()
        DispatchQueue.main.async {
            self.cameraAvailable = false
        }
    }

    @objc private func deviceWasConnected(notification: Notification) {
        NSLog("Camera device was connected")
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            self.checkCameraAvailability()
        }
    }

    private func updateSessionState() {
        let isRunning = self.captureSession?.isRunning ?? false
        DispatchQueue.main.async {
            self.isSessionRunning = isRunning
        }
    }
    
    func startSession() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            guard !self.isSettingUp else { return }

            if self.captureSession == nil {
                self.isSettingUp = true
                let generation = self.setupGeneration
                self.setupCaptureSession { success in
                    self.sessionQueue.async { [weak self] in
                        guard let self = self else { return }
                        self.isSettingUp = false
                        guard success && self.setupGeneration == generation else { return }
                        guard let session = self.captureSession, !session.isRunning else { return }
                        session.startRunning()
                        self.updateSessionState()
                        NSLog("Capture session started successfully")
                    }
                }
            } else if let session = self.captureSession, !session.isRunning {
                session.startRunning()
                self.updateSessionState()
            }
        }
    }

    func stopSession() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            self.isSettingUp = false
            self.setupGeneration += 1
            DispatchQueue.main.async {
                self.isSessionRunning = false
            }
            self.cleanupExistingSession()
            NSLog("Capture session stopped and cleaned up")
        }
    }
}

/// Delivers exactly one frame to its handler and then nothing, however many arrive.
///
/// The once-only flag is not defensiveness: `AVCaptureVideoDataOutput` keeps delivering on its
/// queue until the delegate is detached, and detaching happens in the handler — so a second
/// frame can already be in flight. Resuming a continuation twice traps.
private final class FrameGrabber: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let handler: (CGImage?) -> Void
    private let lock = NSLock()
    private var delivered = false
    private let context = CIContext(options: [.useSoftwareRenderer: false])

    init(handler: @escaping (CGImage?) -> Void) {
        self.handler = handler
        super.init()
    }

    /// The timeout path: reports failure if no frame ever came.
    func expire() {
        deliver(nil)
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        deliver(context.createCGImage(image, from: image.extent))
    }

    private func deliver(_ image: CGImage?) {
        lock.lock()
        let alreadyDelivered = delivered
        delivered = true
        lock.unlock()
        guard !alreadyDelivered else { return }
        handler(image)
    }
}
