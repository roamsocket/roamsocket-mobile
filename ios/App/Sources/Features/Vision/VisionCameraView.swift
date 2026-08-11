import SwiftUI
import AVFoundation
import AVKit
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

    func makeUIViewController(context: Context) -> VisionCameraController {
        let vc = VisionCameraController()
        vc.onCapture = onCapture
        vc.onError = onError
        vc.onShutter = onShutter
        return vc
    }

    func updateUIViewController(_ uiViewController: VisionCameraController, context: Context) {
        uiViewController.onCapture = onCapture
        uiViewController.onError = onError
        uiViewController.onShutter = onShutter
        if captureTrigger != context.coordinator.lastTrigger {
            context.coordinator.lastTrigger = captureTrigger
            if captureTrigger != nil {
                uiViewController.capturePhoto()
            }
        }
        uiViewController.setSessionRunning(isSessionActive)
        uiViewController.setPreviewFrozen(isPreviewFrozen)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var lastTrigger: UUID?
    }
}

// MARK: - Controller

final class VisionCameraController: UIViewController, AVCapturePhotoCaptureDelegate {
    var onCapture: ((UIImage) -> Void)?
    var onError: ((String) -> Void)?
    var onShutter: (() -> Void)?

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.anyprovcode.vision.camera")
    private var preview: AVCaptureVideoPreviewLayer?
    private let photoOutput = AVCapturePhotoOutput()
    private var isConfigured = false
    private var wantsRunning = true
    private var wantsPreviewFrozen = false
    /// True while a still is in flight (blocks double-shutter).
    private var isCapturingPhoto = false
    /// Hardware Camera Control / volume-button shutter (iOS 17.2+).
    private var captureEventInteraction: AnyObject?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        installHardwareCaptureButtons()
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
                if !self.session.isRunning { self.session.startRunning() }
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
        if wasFrozen && !frozen {
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
           connection.videoRotationAngle != portraitAngle {
            connection.videoRotationAngle = portraitAngle
        }
        applyPreviewFrozen()
    }

    // MARK: - AVCapturePhotoCaptureDelegate

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        willCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings
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
        _ output: AVCapturePhotoOutput,
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
