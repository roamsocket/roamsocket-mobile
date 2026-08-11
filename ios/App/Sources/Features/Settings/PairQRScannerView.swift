import SwiftUI
import AVFoundation
import AnyProvCore

/// Scans the desktop pairing QR (`{"host":"http://…","code":"123456"}`).
struct PairQRScannerView: View {
    /// `(host, code)` — host may be empty when only a 6-digit code was scanned.
    var onScan: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var errorMessage: String?
    @State private var torchOn = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                QRScannerRepresentable(
                    onCode: handleRaw,
                    torchOn: torchOn,
                    onError: { errorMessage = $0 }
                )
                .ignoresSafeArea()

                VStack {
                    Spacer()
                    Text("Point at the QR on your desktop or terminal")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .background(.black.opacity(0.55), in: Capsule())
                        .padding(.bottom, 36)
                }

                // Viewfinder corners
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Color.white.opacity(0.85), lineWidth: 2)
                    .frame(width: 240, height: 240)
            }
            .navigationTitle("Scan QR")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        torchOn.toggle()
                    } label: {
                        Image(systemName: torchOn ? "flashlight.on.fill" : "flashlight.off.fill")
                    }
                }
            }
            .alert("Scanner", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func handleRaw(_ raw: String) {
        if let parsed = Self.parsePairPayload(raw) {
            onScan(parsed.host, parsed.code)
            dismiss()
            return
        }
        // Bare 6-digit code — fill code only
        let digits = raw.filter(\.isNumber)
        if digits.count == 6 {
            onScan("", digits)
            dismiss()
            return
        }
        errorMessage = "Not a pairing QR. Expected a code from the RoamSocket desktop."
    }

    /// Accepts JSON payload or URL-style `anyprov://pair?host=…&code=…`.
    static func parsePairPayload(_ raw: String) -> (host: String, code: String)? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = trimmed.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let host = (obj["host"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let code = (obj["code"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !code.isEmpty { return (host, code) }
        }
        if let url = URL(string: trimmed),
           let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            let host = comps.queryItems?.first(where: { $0.name == "host" })?.value ?? ""
            let code = comps.queryItems?.first(where: { $0.name == "code" })?.value ?? ""
            if !code.isEmpty { return (host, code) }
        }
        return nil
    }
}

// MARK: - AVFoundation bridge

private struct QRScannerRepresentable: UIViewControllerRepresentable {
    var onCode: (String) -> Void
    var torchOn: Bool
    var onError: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerViewController {
        let vc = ScannerViewController()
        vc.onCode = onCode
        vc.onError = onError
        return vc
    }

    func updateUIViewController(_ uiViewController: ScannerViewController, context: Context) {
        uiViewController.setTorch(torchOn)
    }
}

final class ScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    var onError: ((String) -> Void)?

    private let session = AVCaptureSession()
    private var preview: AVCaptureVideoPreviewLayer?
    private var didEmit = false
    private let sessionQueue = DispatchQueue(label: "com.anyprovcode.qr-scanner")

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        checkPermissionAndStart()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    func setTorch(_ on: Bool) {
        sessionQueue.async {
            guard let device = AVCaptureDevice.default(for: .video),
                  device.hasTorch else { return }
            do {
                try device.lockForConfiguration()
                device.torchMode = on ? .on : .off
                device.unlockForConfiguration()
            } catch {
                /* ignore */
            }
        }
    }

    private func checkPermissionAndStart() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted { self?.configureSession() }
                    else { self?.onError?("Camera access is required to scan the pairing QR.") }
                }
            }
        default:
            onError?("Camera access denied. Enable it in Settings for RoamSocket.")
        }
    }

    private func configureSession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            self.session.sessionPreset = .high

            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  self.session.canAddInput(input) else {
                DispatchQueue.main.async {
                    self.onError?("No camera available on this device.")
                }
                self.session.commitConfiguration()
                return
            }
            self.session.addInput(input)

            let output = AVCaptureMetadataOutput()
            guard self.session.canAddOutput(output) else {
                self.session.commitConfiguration()
                return
            }
            self.session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
            if output.availableMetadataObjectTypes.contains(.qr) {
                output.metadataObjectTypes = [.qr]
            }

            self.session.commitConfiguration()

            DispatchQueue.main.async {
                let layer = AVCaptureVideoPreviewLayer(session: self.session)
                layer.videoGravity = .resizeAspectFill
                layer.frame = self.view.bounds
                self.view.layer.insertSublayer(layer, at: 0)
                self.preview = layer
            }

            if !self.session.isRunning {
                self.session.startRunning()
            }
        }
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !didEmit,
              let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              obj.type == .qr,
              let value = obj.stringValue,
              !value.isEmpty
        else { return }
        didEmit = true
        // Haptic
        let gen = UINotificationFeedbackGenerator()
        gen.notificationOccurred(.success)
        onCode?(value)
        sessionQueue.async { [weak self] in
            self?.session.stopRunning()
        }
    }
}
