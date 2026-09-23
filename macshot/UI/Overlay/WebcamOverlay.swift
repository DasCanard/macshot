import Cocoa
import AVFoundation

// MARK: - Configuration enums

enum WebcamPosition: String {
    case bottomRight, bottomLeft, topRight, topLeft
}

enum WebcamSize: String {
    case small, medium, large, xlarge

    static let defaultsKey = "webcamSizePoints"
    static let minPoints: CGFloat = 80
    static let maxPoints: CGFloat = 480
    static let defaultPoints: CGFloat = 120

    var points: CGFloat {
        switch self {
        case .small: return 80
        case .medium: return 120
        case .large: return 160
        case .xlarge: return 220
        }
    }

    /// Read the continuous size, falling back to the legacy named presets.
    static var savedPoints: CGFloat {
        if let value = UserDefaults.standard.object(forKey: defaultsKey) as? NSNumber {
            return min(max(CGFloat(value.doubleValue), minPoints), maxPoints)
        }
        let legacy = WebcamSize(
            rawValue: UserDefaults.standard.string(forKey: "webcamSize") ?? "medium")
            ?? .medium
        return legacy.points
    }

    static func save(points: CGFloat) {
        let clamped = min(max(points.rounded(), minPoints), maxPoints)
        UserDefaults.standard.set(Double(clamped), forKey: defaultsKey)
    }
}

enum WebcamShape: String {
    case circle, roundedRect
}

// MARK: - WebcamOverlay

/// Floating webcam preview bubble for screen recording.
/// Positioned at `.statusBar + 1` so ScreenCaptureKit automatically captures it.
class WebcamOverlay: NSPanel {

    private let containerView = WebcamContainerView()
    private var captureSession: AVCaptureSession?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var spinner: NSProgressIndicator?

    private var frameOutput: AVCaptureVideoDataOutput?
    private var frameDelegate: WebcamFrameDelegate?
    private let frameQueue = DispatchQueue(label: "macshot.webcam-frames", qos: .userInitiated)
    /// Starting, stopping and reconfiguring the session are serialized here:
    /// `startRunning()` must never run between begin/commitConfiguration.
    private let sessionQueue = DispatchQueue(label: "macshot.webcam-session", qos: .userInitiated)

    private var currentSize: CGFloat = WebcamSize.defaultPoints
    private var currentShape: WebcamShape = .circle

    init(screen: NSScreen) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true)

        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        // 258: above the capture overlay window (level 257) so the setup preview is
        // visible before recording starts. After recording starts the overlay is gone
        // and ScreenCaptureKit captures the panel regardless of level.
        level = NSWindow.Level(258)
        ignoresMouseEvents = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        containerView.wantsLayer = true
        containerView.frame = contentView!.bounds
        containerView.autoresizingMask = [.width, .height]
        containerView.panel = self
        contentView!.addSubview(containerView)
    }

    // MARK: - Public API

    func configure(position: WebcamPosition, size: CGFloat, shape: WebcamShape, recordingRect: NSRect) {
        let padding: CGFloat = 12
        let maximumFittingSize = max(1, min(recordingRect.width, recordingRect.height) - padding * 2)
        currentSize = min(
            min(max(size, WebcamSize.minPoints), WebcamSize.maxPoints),
            maximumFittingSize)
        currentShape = shape

        let s = currentSize

        var origin: NSPoint
        switch position {
        case .bottomRight:
            origin = NSPoint(x: recordingRect.maxX - s - padding, y: recordingRect.minY + padding)
        case .bottomLeft:
            origin = NSPoint(x: recordingRect.minX + padding, y: recordingRect.minY + padding)
        case .topRight:
            origin = NSPoint(x: recordingRect.maxX - s - padding, y: recordingRect.maxY - s - padding)
        case .topLeft:
            origin = NSPoint(x: recordingRect.minX + padding, y: recordingRect.maxY - s - padding)
        }

        setFrame(NSRect(x: origin.x, y: origin.y, width: s, height: s), display: true)
        applyShapeMask()
        previewLayer?.frame = containerView.bounds
    }

    func startPreview(deviceUID: String?) {
        stopPreview()

        let session = AVCaptureSession()
        session.sessionPreset = .medium

        let device: AVCaptureDevice?
        if let uid = deviceUID, let d = AVCaptureDevice(uniqueID: uid) {
            device = d
        } else {
            device = AVCaptureDevice.default(for: .video)
        }
        guard let camera = device,
              let input = try? AVCaptureDeviceInput(device: camera),
              session.canAddInput(input) else { return }
        session.addInput(input)

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = containerView.bounds
        containerView.layer?.addSublayer(preview)
        previewLayer = preview
        captureSession = session

        applyShapeMask()
        showSpinner()

        // Start camera off the main thread to avoid blocking UI
        sessionQueue.async { [weak self] in
            session.startRunning()
            // Give the preview layer a moment to receive the first frame
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.hideSpinner()
            }
        }
    }

    func stopPreview() {
        stopFrameTap()
        let session = captureSession
        captureSession = nil
        previewLayer?.removeFromSuperlayer()
        previewLayer = nil
        hideSpinner()
        // Stop off the main thread to avoid blocking UI
        if let session = session {
            sessionQueue.async {
                session.stopRunning()
            }
        }
    }

    private func showSpinner() {
        guard spinner == nil else { return }
        let s = NSProgressIndicator()
        s.style = .spinning
        s.controlSize = .small
        s.isIndeterminate = true
        s.sizeToFit()
        s.frame.origin = NSPoint(
            x: (containerView.bounds.width - s.frame.width) / 2,
            y: (containerView.bounds.height - s.frame.height) / 2)
        s.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        containerView.addSubview(s)
        s.startAnimation(nil)
        spinner = s
    }

    private func hideSpinner() {
        spinner?.stopAnimation(nil)
        spinner?.removeFromSuperview()
        spinner = nil
    }

    func setDraggable(_ draggable: Bool) {
        ignoresMouseEvents = !draggable
    }

    // MARK: - Frame tap (separate camera recording)

    /// Taps camera frames for recording at up to 720p. Times are converted
    /// from the capture session's clock to the host clock the screen uses.
    func startFrameTap(_ handler: @escaping @Sendable (CMSampleBuffer, Double) -> Void) -> Bool {
        guard let session = captureSession, frameOutput == nil else { return false }
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        let delegate = WebcamFrameDelegate { [weak session] sample in
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            let clock = session?.synchronizationClock ?? CMClockGetHostTimeClock()
            let host = CMSyncConvertTime(pts, from: clock, to: CMClockGetHostTimeClock())
            guard host.isNumeric else { return }
            handler(sample, host.seconds)
        }
        let queue = frameQueue
        let added: Bool = sessionQueue.sync {
            session.beginConfiguration()
            defer { session.commitConfiguration() }
            if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }
            guard session.canAddOutput(output) else { return false }
            session.addOutput(output)
            output.setSampleBufferDelegate(delegate, queue: queue)
            return true
        }
        guard added else { return false }
        frameOutput = output
        frameDelegate = delegate
        return true
    }

    func stopFrameTap() {
        guard let output = frameOutput, let session = captureSession else {
            frameOutput = nil
            frameDelegate = nil
            return
        }
        output.setSampleBufferDelegate(nil, queue: nil)
        sessionQueue.async {
            session.beginConfiguration()
            session.removeOutput(output)
            session.commitConfiguration()
        }
        frameOutput = nil
        frameDelegate = nil
    }

    // MARK: - Static helpers

    static var availableCameras: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .externalUnknown],
            mediaType: .video, position: .unspecified).devices
    }

    // MARK: - Shape masking

    private func applyShapeMask() {
        guard let layer = containerView.layer else { return }
        let bounds = containerView.bounds

        // Remove old sublayers except preview
        layer.sublayers?.removeAll { $0 !== previewLayer }

        let path: CGPath
        switch currentShape {
        case .circle:
            path = CGPath(ellipseIn: bounds, transform: nil)
        case .roundedRect:
            let radius = currentSize / 5
            path = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
        }

        // Clip mask
        let mask = CAShapeLayer()
        mask.path = path
        layer.mask = mask

        // Border stroke
        let border = CAShapeLayer()
        border.path = path
        border.fillColor = nil
        border.strokeColor = NSColor.white.withAlphaComponent(0.5).cgColor
        border.lineWidth = 2
        layer.addSublayer(border)
    }
}

// MARK: - Draggable content view

private class WebcamContainerView: NSView {
    weak var panel: NSPanel?
    private var dragOrigin: NSPoint = .zero

    override func mouseDown(with event: NSEvent) {
        dragOrigin = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard let panel = panel else { return }
        let current = event.locationInWindow
        let dx = current.x - dragOrigin.x
        let dy = current.y - dragOrigin.y
        var origin = panel.frame.origin
        origin.x += dx
        origin.y += dy
        panel.setFrameOrigin(origin)
    }
}


extension WebcamOverlay: RecordingCameraSource {}

private final class WebcamFrameDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let handler: (CMSampleBuffer) -> Void
    init(_ handler: @escaping (CMSampleBuffer) -> Void) { self.handler = handler }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        handler(sampleBuffer)
    }
}
