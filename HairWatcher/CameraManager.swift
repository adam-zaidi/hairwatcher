import AVFoundation
import CoreMedia

/// Owns the AVCaptureSession and forwards `CMSampleBuffer`s to a consumer at a
/// throttled rate.
///
/// **Pause / resume:** User pause calls `stopRunning()` so the macOS camera
/// indicator (green dot) turns off. Resume calls `startRunning()` again.
/// State transitions are serialized on `sessionQueue` with a short cooldown
/// before restart. This avoids macOS AVFoundation races where immediate
/// stop->start can crash inside Obj-C with "collection mutated while enumerated".
///
/// **Threading:** Session configure / start / stop on `sessionQueue`. The
/// `AVCaptureVideoDataOutput` delegate runs on `processingQueue`. The
/// `isProcessingEnabled` flag is guarded by `processingLock` because it is
/// written from `sessionQueue` and read from `processingQueue`.
final class CameraManager: NSObject, ObservableObject {
    /// Reports configuration failures (e.g. no camera input could be added).
    var onConfigurationError: ((String) -> Void)?

    private typealias FrameConsumer = (CMSampleBuffer) -> Void

    /// The only raw-frame consumer. Set once during app startup, then frozen.
    /// Privacy invariant: this must point to `HairTouchDetector.process` only.
    private var frameConsumer: FrameConsumer?
    private var frameConsumerFrozen = false

    private let session = AVCaptureSession()
    private var videoOutput: AVCaptureVideoDataOutput?
    private var videoInput: AVCaptureDeviceInput?
    private let sessionQueue = DispatchQueue(
        label: "com.hairwatcher.session",
        qos: .userInitiated
    )
    private let processingQueue = DispatchQueue(
        label: "com.hairwatcher.processing",
        qos: .utility
    )

    /// True pixel dimensions of the camera's active format. Published so the
    /// SwiftUI debug preview can lock its container to the same aspect ratio
    /// the AVCaptureVideoPreviewLayer is rendering at.
    @Published private(set) var captureSize: CGSize = CGSize(width: 480, height: 360)

    private let targetFPS: Double = 6.0
    private var lastEmittedAt: TimeInterval = 0
    private var configured = false
    private var desiredRunning = false
    private var lastStopAt: TimeInterval = 0
    private let minimumRestartDelay: TimeInterval = 0.35

    private let processingLock = NSLock()
    private var isProcessingEnabled = false

    var isRunning: Bool { session.isRunning }

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sessionRuntimeError(_:)),
            name: .AVCaptureSessionRuntimeError,
            object: session
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Start capture and forward throttled frames to `onSampleBuffer`.
    func start() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.desiredRunning = true
            self.setProcessingEnabled(false)
            self.applyDesiredState()
        }
    }

    /// Allows the debug preview to render the live session only when explicitly
    /// enabled by the user. No frames are exposed through this API.
    func attachPreview(to layer: AVCaptureVideoPreviewLayer) {
        layer.session = session
    }

    func detachPreview(from layer: AVCaptureVideoPreviewLayer) {
        if layer.session === session {
            layer.session = nil
        }
    }

    /// Set the one allowed raw-frame consumer before capture starts.
    /// Attempts to replace it later are ignored to avoid accidental fan-out.
    func setFrameConsumer(_ consumer: @escaping (CMSampleBuffer) -> Void) {
        guard !frameConsumerFrozen else {
            assertionFailure("Frame consumer is frozen and cannot be replaced.")
            return
        }
        frameConsumer = consumer
        frameConsumerFrozen = true
    }

    /// Stop capture asynchronously (good for sleep / lock where ordering with
    /// UI is loose).
    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.desiredRunning = false
            // Turn off frame delivery immediately while stop work runs.
            self.setProcessingEnabled(false)
            self.applyDesiredState()
        }
    }

    /// Legacy entrypoint kept for call-site compatibility.
    /// It no longer blocks the caller to avoid UI stalls.
    func stopSynchronously() {
        stop()
    }

    /// Same as `stop()` — kept as a named alias for call sites that read better
    /// as “release hardware” (terminate, sleep, lock).
    func releaseCamera() {
        stop()
    }

    private func stopCaptureSession() {
        setProcessingEnabled(false)
        if session.isRunning {
            session.stopRunning()
            lastStopAt = CFAbsoluteTimeGetCurrent()
        }
        // Tear the graph down completely so resume starts from a clean state.
        // This avoids AVFoundation internal mutation crashes on some macOS builds
        // when repeatedly stopping/starting the same configured graph.
        session.beginConfiguration()
        if let output = videoOutput {
            output.setSampleBufferDelegate(nil, queue: nil)
            if session.outputs.contains(where: { $0 === output }) {
                session.removeOutput(output)
            }
        }
        if let input = videoInput, session.inputs.contains(where: { $0 === input }) {
            session.removeInput(input)
        }
        session.commitConfiguration()
        videoOutput = nil
        videoInput = nil
        configured = false
    }

    private func applyDesiredState() {
        if desiredRunning {
            if !configured {
                configureSession()
            }
            if !session.isRunning {
                // AVFoundation on macOS is fragile with immediate restart after stop.
                let elapsed = CFAbsoluteTimeGetCurrent() - lastStopAt
                if elapsed < minimumRestartDelay {
                    Thread.sleep(forTimeInterval: minimumRestartDelay - elapsed)
                }
                // Desired state may have changed while we slept.
                guard desiredRunning else {
                    setProcessingEnabled(false)
                    return
                }
                session.startRunning()
                lastEmittedAt = 0
            }
            setProcessingEnabled(true)
        } else {
            stopCaptureSession()
        }
    }

    private func setProcessingEnabled(_ enabled: Bool) {
        processingLock.lock()
        isProcessingEnabled = enabled
        processingLock.unlock()
    }

    private func processingEnabled() -> Bool {
        processingLock.lock()
        let v = isProcessingEnabled
        processingLock.unlock()
        return v
    }

    @objc private func sessionRuntimeError(_ notification: Notification) {
        guard let error = notification.userInfo?[AVCaptureSessionErrorKey] as? Error else { return }
        NSLog("HairWatcher: AVCaptureSession runtime error: %@", String(describing: error))
    }

    private func configureSession() {
        session.beginConfiguration()
        defer {
            session.commitConfiguration()
            configured = true
        }

        if session.canSetSessionPreset(.medium) {
            session.sessionPreset = .medium
        }

        guard let device = AVCaptureDevice.default(for: .video) else {
            onConfigurationError?("No video capture device is available.")
            return
        }
        guard let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            onConfigurationError?("Could not add the camera as a session input.")
            return
        }
        session.addInput(input)
        videoInput = input

        let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        if dims.width > 0 && dims.height > 0 {
            let size = CGSize(width: CGFloat(dims.width), height: CGFloat(dims.height))
            DispatchQueue.main.async { [weak self] in
                self?.captureSize = size
            }
        }

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: processingQueue)

        if session.canAddOutput(output) {
            session.addOutput(output)
            videoOutput = output
        } else {
            onConfigurationError?("Could not add the video output to the session.")
        }
    }
}

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard processingEnabled() else { return }
        let now = CFAbsoluteTimeGetCurrent()
        let minInterval = 1.0 / targetFPS
        if now - lastEmittedAt < minInterval { return }
        lastEmittedAt = now
        // Privacy invariant: do not store, encode, log, or transmit this buffer.
        // It is handed directly to the detector and is valid only for this
        // delegate call.
        frameConsumer?(sampleBuffer)
    }
}
