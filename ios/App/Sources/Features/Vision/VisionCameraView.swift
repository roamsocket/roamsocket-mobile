import SwiftUI
import AVFoundation
import UIKit

/// Full-screen live camera preview with still capture (photo output).
struct VisionCameraView: UIViewControllerRepresentable {
    var onCapture: (UIImage) -> Void
    var onError: (String) -> Void
    /// Bumps when the SwiftUI host wants a still (capture button).
    var captureTrigger: UUID?
    var isSessionActive: Bool = true

    func makeUIViewController(context: Context) -> VisionCameraController {
        let vc = VisionCameraController()
        vc.onCapture = onCapture
        vc.onError = onError
        return vc
    }

    func updateUIViewController(_ uiViewController: VisionCameraController, context: Context) {
        uiViewController.onCapture = onCapture
        uiViewController.onError = onError
        if captureTrigger != context.coordinator.lastTrigger {
            context.coordinator.lastTrigger = captureTrigger
            if captureTrigger != nil {
                uiViewController.capturePhoto()
            }
        }
        uiViewController.setSessionRunning(isSessionActive)
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

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.anyprovcode.vision.camera")
    private var preview: AVCaptureVideoPreviewLayer?
    private let photoOutput = AVCapturePhotoOutput()
    private var isConfigured = false
    private var wantsRunning = true

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        requestAndConfigure()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
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

    func capturePhoto() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard self.isConfigured, self.session.isRunning else {
                DispatchQueue.main.async {
                    self.onError?("Camera is not ready yet.")
                }
                return
            }
            let settings = AVCapturePhotoSettings()
            settings.flashMode = .off
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
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
            onError?("Camera access denied. Enable it in Settings for CodeSocket.")
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
                layer.videoGravity = .resizeAspectFill
                layer.frame = self.view.bounds
                self.view.layer.insertSublayer(layer, at: 0)
                self.preview = layer
            }

            if self.wantsRunning {
                self.session.startRunning()
            }
        }
    }

    // MARK: - AVCapturePhotoCaptureDelegate

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        if let error {
            DispatchQueue.main.async {
                self.onError?(error.localizedDescription)
            }
            return
        }
        guard let data = photo.fileDataRepresentation(),
              let image = UIImage(data: data)
        else {
            DispatchQueue.main.async {
                self.onError?("Could not read the captured photo.")
            }
            return
        }
        let fixed = image.fixedOrientation()
        DispatchQueue.main.async {
            self.onCapture?(fixed)
        }
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
