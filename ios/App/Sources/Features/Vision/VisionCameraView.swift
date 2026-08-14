import AVFoundation
import AVKit
import SwiftUI
import UIKit

/// Full-screen live camera preview with still capture (photo output).
struct VisionCameraView: UIViewControllerRepresentable {
    var onCapture: (UIImage) -> Void
    var onError: (String) -> Void
    /// Fired when the shutter is accepted (before the still finishes developing).
    var onShutter: (() -> Void)? = nil
    /// Bumps when the SwiftUI host wants a still (capture button).
    var captureTrigger: UUID?
    var isSessionActive: Bool = true
    /// Pause the preview connection so the last live frame freezes in place.
    var isPreviewFrozen: Bool = false
    /// Bumps when the host wants the lens zoom reset to 1× (retake, etc.).
    var zoomResetTrigger: UUID?
    /// Optional absolute zoom factor the host wants applied (e.g. tapping a
    /// 2× / Max chip). `setZoomFactor` clamps to the device's allowed range.
    var requestedZoomFactor: CGFloat?
    /// Reports the device's actual `videoZoomFactor` whenever it changes, so
    /// the chip row can track the user's pinch or a recent tap equally.
    var onZoomChanged: ((CGFloat) -> Void)? = nil
    /// Fired on the main queue whenever a fresh QR code is detected on the
    /// session. Repeated values for the same code in the same frame window
    /// are filtered by the controller.
    var onQRScanned: ((String) -> Void)? = nil
    /// Bumps when the host wants the QR-tracking memory cleared (so pointing
    /// at the *same* code can re-trigger after the user dismissed a card).
    var qrResetTrigger: UUID?

    func makeUIViewController(context _: Context) -> VisionCameraController {
        let vc = VisionCameraController()
        vc.onCapture = onCapture
        vc.onError = onError
        vc.onShutter = onShutter
        vc.onZoomChanged = onZoomChanged
        vc.onQRScanned = onQRScanned
        return vc
    }

    func updateUIViewController(_ uiViewController: VisionCameraController, context: Context) {
        uiViewController.onCapture = onCapture
        uiViewController.onError = onError
        uiViewController.onShutter = onShutter
        uiViewController.onZoomChanged = onZoomChanged
        uiViewController.onQRScanned = onQRScanned
        if captureTrigger != context.coordinator.lastTrigger {
            context.coordinator.lastTrigger = captureTrigger
            if captureTrigger != nil {
                uiViewController.capturePhoto()
            }
        }
        if let factor = requestedZoomFactor {
            uiViewController.setZoomFactor(factor, animated: true)
            context.coordinator.lastRequestedFactor = factor
        } else {
            // Cleared by the host (e.g. after consumption) — just nil the ref.
            context.coordinator.lastRequestedFactor = nil
        }
        if let trigger = zoomResetTrigger,
           trigger != context.coordinator.lastZoomResetTrigger
        {
            context.coordinator.lastZoomResetTrigger = trigger
            uiViewController.resetZoom(animated: false)
        }
        if let trigger = qrResetTrigger,
           trigger != context.coordinator.lastQRResetTrigger
        {
            context.coordinator.lastQRResetTrigger = trigger
            uiViewController.resetQRTracking()
        }
        uiViewController.setSessionRunning(isSessionActive)
        uiViewController.setPreviewFrozen(isPreviewFrozen)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var lastTrigger: UUID?
        var lastZoomResetTrigger: UUID?
        var lastRequestedFactor: CGFloat?
        var lastQRResetTrigger: UUID?
    }
}

// MARK: - Controller

final class VisionCameraController: UIViewController, AVCapturePhotoCaptureDelegate, AVCaptureMetadataOutputObjectsDelegate {
    var onCapture: ((UIImage) -> Void)?
    var onError: ((String) -> Void)?
    var onShutter: (() -> Void)?
    /// Reports the actual `videoZoomFactor` back to SwiftUI whenever it changes
    /// (pinch or chip tap). Called on the main queue.
    var onZoomChanged: ((CGFloat) -> Void)?
    /// Reports a fresh QR code payload whenever one is detected on the live
    /// preview. Called on the main queue. Detections are deduplicated by the
    /// `AVCaptureMetadataOutput` queue naturally; we forward a single stable
    /// value at a time.
    var onQRScanned: ((String) -> Void)?

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.anyprovcode.vision.camera")
    private var preview: AVCaptureVideoPreviewLayer?
    private let photoOutput = AVCapturePhotoOutput()
    private let metadataOutput = AVCaptureMetadataOutput()
    private var isConfigured = false
    private var wantsRunning = true
    private var wantsPreviewFrozen = false
    /// True while a still is in flight (blocks double-shutter).
    private var isCapturingPhoto = false
    /// Hardware Camera Control / volume-button shutter (iOS 17.2+).
    private var captureEventInteraction: AnyObject?
    /// Pinch-to-zoom gesture attached to `view`. Drives `setZoomFactor` while
    /// the user is actively pinching so the camera follows their fingers.
    private var pinchGesture: UIPinchGestureRecognizer?
    /// Cached active video device for zoom reads / writes.
    private weak var activeDevice: AVCaptureDevice?
    /// Last QR value we forwarded up — used to suppress identical repeats
    /// that the OS sends every few frames while the code stays in view.
    private var lastForwardedQR: String?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        installHardwareCaptureButtons()
        installPinchZoomGesture()
        requestAndConfigure()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
        applyPreviewOrientation()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        setSessionRunning(wantsRunning)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        setSessionRunning(false)
    }

    func setSessionRunning(_ running: Bool) {
        wantsRunning = running
        sessionQueue.async { [weak self] in
            guard let self, self.isConfigured else { return }
            if running {
                if !self.session.isRunning {
                    self.session.startRunning()
                }
            } else if self.session.isRunning {
                self.session.stopRunning()
            }
        }
    }

    /// Freezes the last live frame by disabling the preview connection.
    func setPreviewFrozen(_ frozen: Bool) {
        let wasFrozen = wantsPreviewFrozen
        wantsPreviewFrozen = frozen
        applyPreviewFrozen()
        // Retake unfreezes while a prior still may still be developing — clear the
        // in-flight lock so the next shutter is not stuck waiting on that JPEG.
        if wasFrozen, !frozen {
            sessionQueue.async { [weak self] in
                self?.isCapturingPhoto = false
            }
        }
    }

    private func applyPreviewFrozen() {
        // Disabling the preview connection holds the last composited frame.
        preview?.connection?.isEnabled = !wantsPreviewFrozen
    }

    func capturePhoto() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard !self.isCapturingPhoto else {
                // Host may already have opened the analyzing card — surface the
                // failure so it can abort instead of hanging on "Analyzing…".
                DispatchQueue.main.async {
                    self.onError?("Capture already in progress.")
                }
                return
            }
            guard self.isConfigured, self.session.isRunning else {
                DispatchQueue.main.async {
                    self.onError?("Camera is not ready yet.")
                }
                return
            }
            self.isCapturingPhoto = true
            // Notify host on main *before* the still finishes developing so
            // freeze + analyzing UI can appear on shutter, not on JPEG ready.
            DispatchQueue.main.async {
                self.onShutter?()
            }
            let settings = AVCapturePhotoSettings()
            settings.flashMode = .off
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    // MARK: - Hardware shutter (Camera Control / volume)

    /// iPhone 16 Camera Control + volume buttons fire capture while Vision is open.
    private func installHardwareCaptureButtons() {
        if #available(iOS 17.2, *) {
            let interaction = AVCaptureEventInteraction(
                primary: { [weak self] event in
                    self?.handleHardwareCaptureEvent(event)
                },
                secondary: { [weak self] event in
                    self?.handleHardwareCaptureEvent(event)
                }
            )
            interaction.isEnabled = true
            view.addInteraction(interaction)
            captureEventInteraction = interaction
        }
    }

    @available(iOS 17.2, *)
    private func handleHardwareCaptureEvent(_ event: AVCaptureEvent) {
        // Fire once on press end so light-press / hold doesn’t multi-shoot.
        guard event.phase == .ended else { return }
        guard wantsRunning, !wantsPreviewFrozen, !isCapturingPhoto else { return }
        capturePhoto()
    }

    // MARK: - Pinch zoom

    /// Pinch gesture recognizer wired straight to `videoZoomFactor`. We use
    /// UIPinchGestureRecognizer instead of SwiftUI's `MagnifyGesture` because
    /// it's connected directly to the preview UIView (no race with the SwiftUI
    /// SwiftUI overlay layer for the shutter / prompt chips).
    private func installPinchZoomGesture() {
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.delegate = self
        view.addGestureRecognizer(pinch)
        pinchGesture = pinch
    }

    @objc private func handlePinch(_ gr: UIPinchGestureRecognizer) {
        // Block while frozen / mid-capture so the deviceless zoom doesn't
        // fight the still-developing preview path.
        guard !wantsPreviewFrozen, !isCapturingPhoto else { return }
        sessionQueue.async { [weak self] in
            guard let self, let device = self.activeDevice else { return }
            DispatchQueue.main.async {
                let base = device.videoZoomFactor
                let candidate = base * gr.scale
                let clamped = self.clampedZoom(candidate, on: device)
                gr.scale = 1 // reset reference so each event is incremental
                self.applyZoom(clamped, on: device)
            }
        }
    }

    /// Snap back to the device's true 1× wide angle. Used on retake so the next
    /// shot isn't accidentally framed at 2×.
    func resetZoom(animated: Bool) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.activeDevice else { return }
            let target = self.clampedZoom(device.minAvailableVideoZoomFactor, on: device)
            DispatchQueue.main.async {
                self.applyZoom(target, on: device, animated: animated)
            }
        }
    }

    /// Host can ask for an absolute target (chip tap). Clamped + ramped so the
    /// transition feels like the stock Camera app.
    func setZoomFactor(_ factor: CGFloat, animated: Bool = true) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.activeDevice else { return }
            let target = self.clampedZoom(factor, on: device)
            DispatchQueue.main.async {
                self.applyZoom(target, on: device, animated: animated)
            }
        }
    }

    private func applyZoom(_ factor: CGFloat, on device: AVCaptureDevice, animated: Bool = false) {
        do {
            try device.lockForConfiguration()
            if animated {
                device.ramp(toVideoZoomFactor: factor, withRate: 4)
            } else {
                device.videoZoomFactor = factor
            }
            device.unlockForConfiguration()
        } catch {
            // Non-fatal — pinch still works against `videoZoomFactor` directly.
        }
        // `ramp` is async, so the snapshot immediately after may not reflect the
        // final value. Send what we asked for, then re-publish after the ramp
        // would naturally settle. ~300ms matches `ramp` at rate=4 for typical
        // distances.
        onZoomChanged?(factor)
        if animated {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(320)) { [weak self] in
                self?.publishCurrentZoom()
            }
        }
    }

    /// Periodically re-publishes the device's current factor so the chip row
    /// settles on the value the user actually landed on after a ramp.
    private func publishCurrentZoom() {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.activeDevice else { return }
            let snapshot = device.videoZoomFactor
            DispatchQueue.main.async {
                self.onZoomChanged?(snapshot)
            }
        }
    }

    private func clampedZoom(_ factor: CGFloat, on device: AVCaptureDevice) -> CGFloat {
        // iOS clamps at ~device.activeFormat.videoMaxZoomFactor (often 8–10×)
        // for non-locked sessions. We never push beyond 5× — beyond that, the
        // image quality collapses because the OS is cropping pixels, not
        // switching lenses. Match Apple Camera's behavior.
        let maxPractical: CGFloat = 5
        let lo = max(device.minAvailableVideoZoomFactor, 1)
        let hi = min(device.activeFormat.videoMaxZoomFactor, maxPractical)
        return min(max(factor, lo), hi)
    }

    // MARK: - Setup

    private func requestAndConfigure() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.configureSession()
                    } else {
                        self?.onError?("Camera access is required for Vision. Enable it in Settings.")
                    }
                }
            }
        case .denied, .restricted:
            onError?("Camera access denied. Enable it in Settings for RoamSocket.")
        @unknown default:
            onError?("Camera is unavailable.")
        }
    }

    private func configureSession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            self.session.sessionPreset = .photo

            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
                ?? AVCaptureDevice.default(for: .video),
                let input = try? AVCaptureDeviceInput(device: device),
                self.session.canAddInput(input)
            else {
                self.session.commitConfiguration()
                DispatchQueue.main.async {
                    self.onError?("No camera available on this device.")
                }
                return
            }
            self.session.addInput(input)

            // Stay at true 1× wide FOV — dual/triple cameras sometimes report a
            // virtual zoom > 1 as the default, which reads as “zoomed in”.
            do {
                try device.lockForConfiguration()
                let minZoom = device.minAvailableVideoZoomFactor
                if device.videoZoomFactor != minZoom {
                    device.videoZoomFactor = minZoom
                }
                device.unlockForConfiguration()
            } catch {
                // Non-fatal — continue with the system default.
            }
            self.activeDevice = device

            guard self.session.canAddOutput(self.photoOutput) else {
                self.session.commitConfiguration()
                DispatchQueue.main.async {
                    self.onError?("Could not configure the camera for photos.")
                }
                return
            }
            self.session.addOutput(self.photoOutput)
            // iOS 17+: videoOrientation is deprecated; portrait ≈ 90°.
            if let connection = self.photoOutput.connection(with: .video) {
                let portraitAngle: CGFloat = 90
                if connection.isVideoRotationAngleSupported(portraitAngle) {
                    connection.videoRotationAngle = portraitAngle
                }
            }

            // QR / barcode scanner on the same session so we don't open a
            // second camera authorization prompt. Forward each fresh value
            // exactly once; the metadata queue debounces duplicates.
            if self.session.canAddOutput(self.metadataOutput) {
                self.session.addOutput(self.metadataOutput)
                self.metadataOutput.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
                let supported = self.metadataOutput.availableMetadataObjectTypes
                // QR is the only one Vision mode currently surfaces; barcode
                // friends (PDF417 / Data Matrix / Aztec) can come later.
                let requested: [AVMetadataObject.ObjectType] = [.qr]
                self.metadataOutput.metadataObjectTypes = requested.filter { supported.contains($0) }
            }

            self.session.commitConfiguration()
            self.isConfigured = true

            DispatchQueue.main.async {
                let layer = AVCaptureVideoPreviewLayer(session: self.session)
                // Preview is laid out in a dedicated band between chrome (not
                // full-screen), so aspect-fill covers that band without drawing
                // under Close / prompt / shutter. Zoom is still locked to 1×.
                layer.videoGravity = .resizeAspectFill
                layer.frame = self.view.bounds
                layer.masksToBounds = true
                self.view.layer.insertSublayer(layer, at: 0)
                self.preview = layer
                self.applyPreviewOrientation()
                self.applyPreviewFrozen()
            }

            if self.wantsRunning {
                self.session.startRunning()
            }
        }
    }

    /// Keep the preview upright in portrait (matches photo output).
    private func applyPreviewOrientation() {
        guard let connection = preview?.connection else { return }
        let portraitAngle: CGFloat = 90
        if connection.isVideoRotationAngleSupported(portraitAngle),
           connection.videoRotationAngle != portraitAngle
        {
            connection.videoRotationAngle = portraitAngle
        }
        applyPreviewFrozen()
    }

    // MARK: - AVCapturePhotoCaptureDelegate

    func photoOutput(
        _: AVCapturePhotoOutput,
        willCapturePhotoFor _: AVCaptureResolvedPhotoSettings
    ) {
        // System shutter moment — ensure preview stays frozen if the host already
        // asked for it (or freeze here as a fallback for hardware paths).
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if !self.wantsPreviewFrozen {
                self.wantsPreviewFrozen = true
                self.applyPreviewFrozen()
            }
        }
    }

    func photoOutput(
        _: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        if let error {
            DispatchQueue.main.async {
                self.isCapturingPhoto = false
                self.onError?(error.localizedDescription)
            }
            return
        }
        guard let data = photo.fileDataRepresentation() else {
            DispatchQueue.main.async {
                self.isCapturingPhoto = false
                self.onError?("Could not read the captured photo.")
            }
            return
        }
        // Decode straight to the display resolution with ImageIO — never hold a
        // full 12 MP bitmap. On-device VLMs (Gemma, Qwen-VL, …) already keep
        // multi-GB weights in Metal, so a full-size decode + orientation redraw
        // on shutter is what tips the app over the memory ceiling (jetsam kill).
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let image = Self.downsampledImage(from: data, maxDimension: 1440)
                ?? Self.decodedFallback(data)
            DispatchQueue.main.async {
                self.isCapturingPhoto = false
                guard let image else {
                    self.onError?("Could not read the captured photo.")
                    return
                }
                self.onCapture?(image)
            }
        }
    }

    /// Downsample photo data straight to the target pixel size. ImageIO decodes
    /// the file once at the target resolution and bakes EXIF orientation in, so
    /// the result is already `.up` and needs no redraw.
    private static func downsampledImage(from data: Data, maxDimension: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(Int(maxDimension), 1),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cgImage, scale: 1, orientation: .up)
    }

    /// Last-resort decode when ImageIO thumbnailing fails (exotic formats).
    private static func decodedFallback(_ data: Data) -> UIImage? {
        guard let image = UIImage(data: data) else { return nil }
        return image.fixedOrientation()
    }

    // MARK: - AVCaptureMetadataOutputObjectsDelegate

    func metadataOutput(
        _: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from _: AVCaptureConnection
    ) {
        guard let first = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              first.type == .qr,
              let value = first.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else { return }
        // iOS fires this delegate for every frame that sees the code, so
        // filter repeated values to avoid spamming the SwiftUI overlay.
        if value == lastForwardedQR {
            return
        }
        lastForwardedQR = value
        onQRScanned?(value)
    }

    /// Forget the last QR so the *same* code can be re-surfaced later (e.g.
    /// after the user dismisses the card and points at the same code again).
    func resetQRTracking() {
        lastForwardedQR = nil
    }
}

// MARK: - UIImage orientation

private extension UIImage {
    /// Normalize EXIF orientation so JPEG encode matches what the user saw.
    func fixedOrientation() -> UIImage {
        guard imageOrientation != .up else { return self }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = scale
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

// MARK: - Gesture coordination

extension VisionCameraController: UIGestureRecognizerDelegate {
    /// Pinch shares the view with the shutter Button and the SwiftUI chip
    /// row. Let it fire alongside any single-pointer gesture so the user can
    /// pinch + pan, but suppress it when AVCaptureEventInteraction is mid-
    /// capture-event (Camera Control button).
    func gestureRecognizer(
        _: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith _: UIGestureRecognizer
    ) -> Bool {
        // Allow pinch to compose with the SwiftUI overlay's own gestures.
        // SwiftUI hands us UIKit gestures via `SimultaneousGesture` chains.
        true
    }
}
