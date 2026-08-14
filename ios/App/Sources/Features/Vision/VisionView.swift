import AnyProvCore
import SwiftUI
import UIKit

/// Full-screen Vision mode: live camera, capture, minimizable analysis.
struct VisionView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel = VisionViewModel()
    @ObservedObject private var promptStore = VisionPromptStore.shared

    @State private var captureTrigger: UUID?
    @State private var cameraError: String?
    @State private var showProviderSettings = false
    @State private var showSavePresetAlert = false
    @State private var newPresetTitle = ""
    @State private var keyboardHeight: CGFloat = 0
    /// Bumps when a new still is frozen so pinch-zoom resets.
    @State private var captureZoomResetID = UUID()
    /// Bumps when the lens needs to snap back to 1× (retake / new shot).
    @State private var cameraZoomResetID = UUID()
    /// Live camera zoom factor the chip row reads from.
    @State private var currentZoomFactor: CGFloat = 1
    /// One-shot absolute factor the chip row wants the camera to settle on.
    /// Cleared as soon as the controller consumes it.
    @State private var pendingZoomFactor: CGFloat? = nil
    @FocusState private var promptFieldFocused: Bool

    /// Retake + shutter row height (not including home-indicator inset). Used to
    /// lift the collapsed pill above the capture button.
    private let shutterStackClearance: CGFloat = 110

    private var keyboardVisible: Bool {
        keyboardHeight > 20
    }

    /// Live Text / Photos-style select-and-copy is "auto" once the still is
    /// final. While the capture is still developing (`capturing` / `analyzing`)
    /// the JPEG isn't stable yet, so we hold off — once an analysis result
    /// (or a follow-up turn) is on screen, the overlay turns on automatically.
    private var liveTextAvailable: Bool {
        switch viewModel.phase {
        case .live, .capturing: return false
        case .analyzing, .result, .failed: return true
        }
    }

    var body: some View {
        GeometryReader { geo in
            let layout = LayoutValues(
                size: geo.size,
                safeAreaInsets: geo.safeAreaInsets,
                shutterStackClearance: shutterStackClearance,
                hasFrozenCapture: viewModel.hasFrozenCapture,
                sheetMode: viewModel.sheetMode,
                keyboardHeight: keyboardHeight,
                keyboardVisible: keyboardVisible
            )
            let horizontalInset = max(16, min(20, geo.size.width * 0.045))
            let bottomSafe = layout.bottomSafe
            let topSafe = layout.topSafe
            let chromeBlockHeight = layout.chromeBlockHeight
            let topChromeClearance = layout.topChromeClearance
            let bottomPad: CGFloat = layout.bottomPad
            let sheetOccupied = estimatedSheetOccupiedHeight(
                totalHeight: geo.size.height,
                topChromeClearance: topChromeClearance,
                chromeBlockHeight: chromeBlockHeight,
                bottomSafe: bottomSafe
            )
            // Leave a permanent photo peek above the card (must match sheet detents
            // so the grabber and first answer lines are never covered).
            let imageBandHeight = max(
                VisionAnalysisSheet.minImageBandHeight,
                geo.size.height - topChromeClearance - sheetOccupied - VisionAnalysisSheet.imageSheetGap
            )

            ZStack {
                Color.black
                    .ignoresSafeArea()

                // Results card at the bottom (Google Lens–style overlay).
                VisionAnalysisSheet(
                    viewModel: viewModel,
                    modelDisplayName: modelLabel,
                    shutterClearance: chromeBlockHeight,
                    bottomSafeInset: bottomSafe,
                    topChromeClearance: topChromeClearance,
                    onRetake: performRetake
                )
                .frame(width: geo.size.width, height: geo.size.height)
                .zIndex(1)

                // Still after the sensor photo lands (analyzing / result). While the
                // still is still developing we keep the live layer mounted and freeze
                // its last frame instead — so capture does not tear down the session.
                if let image = viewModel.capturedImage, !viewModel.showsCameraSession {
                    VisionFrozenStillOverlay(
                        image: image,
                        resetID: captureZoomResetID,
                        totalSize: geo.size,
                        topChromeClearance: topChromeClearance,
                        imageBandHeight: imageBandHeight,
                        liveTextEnabled: liveTextAvailable,
                        onSingleTap: { viewModel.setSheetMinimized() },
                        onCropCommitted: { rect in
                            viewModel.applyCropAndReanalyze(normalizedRect: rect)
                        }
                    )
                    .frame(width: geo.size.width, height: geo.size.height)
                    .zIndex(1.5)
                }

                // QR-code card (live + result). Floats above the analysis
                // sheet without touching the still or the capture chrome.
                if let qr = viewModel.scannedQR {
                    let cardBottomInset: CGFloat = {
                        // If the analysis card is on screen, sit just above its
                        // top edge so the card doesn't cover the first lines of
                        // the answer. Otherwise (no capture yet, live camera
                        // only) sit above the chrome.
                        switch viewModel.sheetMode {
                        case .full, .expanded, .minimized: return sheetOccupied + 14
                        case .hidden: return chromeBlockHeight + 14
                        }
                    }()
                    qrCard(
                        payload: qr,
                        bottomInset: cardBottomInset
                    )
                    .frame(maxWidth: min(geo.size.width - 28, 480))
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(1.6)
                }

                // Chrome + live camera. Camera fills only the middle band so it
                // never draws under Close/model or the prompt/shutter stack.
                VisionCameraAndChromeStack(
                    viewModel: viewModel,
                    horizontalInset: horizontalInset,
                    topSafe: topSafe,
                    bottomPad: bottomPad,
                    totalWidth: geo.size.width,
                    totalHeight: geo.size.height,
                    cameraLayer: AnyView(cameraLayer),
                    topBar: AnyView(topBar),
                    bottomControls: AnyView(bottomControls),
                    onPromptDismiss: { promptFieldFocused = false }
                )
                .zIndex(2)
                .animation(.easeOut(duration: 0.22), value: keyboardHeight)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
        .background(Color.black.ignoresSafeArea())
        .statusBarHidden(false)
        .preferredColorScheme(.dark)
        // Capture-prompt keyboard accessory (must not be stolen by the analysis sheet).
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                if promptFieldFocused {
                    Button("Done") {
                        promptFieldFocused = false
                    }
                    Spacer()
                    Button {
                        fireShutter()
                    } label: {
                        Label("Take photo", systemImage: "camera.fill")
                    }
                    .fontWeight(.semibold)
                    .disabled(!viewModel.canCapture || viewModel.isThinking)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            updateKeyboardHeight(from: note)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardHeight = 0
        }
        .onAppear {
            viewModel.bind(state: state)
            // Always re-list so a just-downloaded on-device Vision model appears
            // even when cloud / Apple Intelligence models already filled the catalog.
            Task {
                await state.refreshModels()
                viewModel.bind(state: state)
            }
        }
        .onChange(of: state.allModels.map(\.id)) { _, _ in
            // Prefer auto-selecting a Vision model once downloads land.
            if viewModel.selectedModel == nil
                || (viewModel.selectedModel.map { !state.modelSupportsVision($0) } ?? false)
            {
                viewModel.bind(state: state)
            }
        }
        .sheet(isPresented: $viewModel.showModelPicker) {
            VisionModelPickerSheet(viewModel: viewModel)
                .environmentObject(state)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showProviderSettings) {
            AppSettingsView()
                .environmentObject(state)
        }
        .sheet(isPresented: $viewModel.showPromptLibrary) {
            VisionPromptLibrarySheet(viewModel: viewModel, promptStore: promptStore)
        }
        .sheet(isPresented: $viewModel.showReanalyzePrompt) {
            VisionReanalyzePromptSheet(viewModel: viewModel, promptStore: promptStore)
        }
        .alert("Save prompt preset", isPresented: $showSavePresetAlert) {
            TextField("Name", text: $newPresetTitle)
            Button("Save") {
                let title = newPresetTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { return }
                _ = viewModel.saveCapturePromptAsPreset(title: title)
                newPresetTitle = ""
            }
            Button("Cancel", role: .cancel) {
                newPresetTitle = ""
            }
        } message: {
            Text("Save the current capture prompt so you can reuse it on later shots.")
        }
        .alert("Camera", isPresented: Binding(
            get: { cameraError != nil },
            set: {
                if !$0 {
                    cameraError = nil
                }
            }
        )) {
            Button("OK", role: .cancel) { cameraError = nil }
        } message: {
            Text(cameraError ?? "")
        }
    }

    // MARK: - Layers

    /// Live viewfinder (and briefly frozen preview while the still develops).
    /// Final stills use `VisionZoomableImageView` in the band above the results
    /// card (Lens-style). Unmounting the session once the still lands frees
    /// GPU/RAM for on-device VLMs.
    private var cameraLayer: some View {
        VisionCameraView(
            onCapture: { image in
                captureZoomResetID = UUID()
                viewModel.analyze(image: image)
            },
            onError: { message in
                if viewModel.phase == .capturing {
                    viewModel.abortCapture(message: message)
                }
                cameraError = message
            },
            onShutter: {
                // Hardware shutter / capture accepted — freeze + analyzing card now.
                viewModel.beginCapture()
            },
            captureTrigger: captureTrigger,
            isSessionActive: viewModel.showsCameraSession,
            isPreviewFrozen: viewModel.freezesCameraPreview,
            zoomResetTrigger: cameraZoomResetID,
            requestedZoomFactor: pendingZoomFactor,
            onZoomChanged: { factor in
                currentZoomFactor = factor
            },
            onQRScanned: { raw in
                viewModel.registerScannedQR(raw)
            },
            qrResetTrigger: viewModel.qrRescanRequest
        )
        .onChange(of: pendingZoomFactor) { _, newValue in
            // Clear the one-shot so the representable doesn't re-send it next
            // update pass while still letting the chip's "selected" mirror
            // currentZoomFactor above.
            guard newValue != nil else { return }
            DispatchQueue.main.async {
                pendingZoomFactor = nil
            }
        }
    }

    /// Approximate bottom card footprint so the photo can sit in the remaining band.
    /// Mirrors `VisionAnalysisSheet` detent fractions (not pixel-perfect during drag).
    private func estimatedSheetOccupiedHeight(
        totalHeight: CGFloat,
        topChromeClearance: CGFloat,
        chromeBlockHeight: CGFloat,
        bottomSafe: CGFloat
    ) -> CGFloat {
        // Same photo-band reservation as `VisionAnalysisSheet.detentHeights`.
        let maxByPhoto = max(
            280,
            totalHeight
                - topChromeClearance
                - VisionAnalysisSheet.minImageBandHeight
                - VisionAnalysisSheet.imageSheetGap
        )
        switch viewModel.sheetMode {
        case .hidden:
            return 0
        case .minimized:
            // Pill + lift above Retake chrome.
            return VisionAnalysisSheet.minimizedCardHeight + chromeBlockHeight + 14
        case .expanded:
            if viewModel.isThinking && !viewModel.isReplying {
                return min(min(totalHeight * 0.46, 220) + bottomSafe * 0.5, maxByPhoto)
            }
            return min(max(260, totalHeight * 0.46) + bottomSafe, maxByPhoto)
        case .full:
            if viewModel.isThinking && !viewModel.isReplying {
                return min(min(totalHeight * 0.88, 300) + bottomSafe, maxByPhoto)
            }
            return min(max(300, totalHeight * 0.88), maxByPhoto)
        }
    }

    /// QR card wrapper: applies the bottom inset (above the analysis sheet or
    /// above the chrome when no capture is in flight) and the auto-expire
    /// timer. Extracted so SwiftUI's type-checker doesn't blow up trying to
    /// resolve the still-overlay ZStack + this card simultaneously.
    private func qrCard(
        payload: VisionViewModel.ScannedQR,
        bottomInset: CGFloat
    ) -> some View {
        VisionQRScanCard(
            payload: payload,
            onUse: {
                viewModel.consumeScannedQR(pasteIntoCapturePrompt: true)
                viewModel.requestQRRescan()
            },
            onCopy: { /* flash logic lives in the card itself */ },
            onOpenURL: payload.url.map { url in
                {
                    UIApplication.shared.open(url, options: [:]) { _ in }
                    viewModel.dismissScannedQR()
                    viewModel.requestQRRescan()
                }
            },
            onDismiss: {
                viewModel.dismissScannedQR()
                viewModel.requestQRRescan()
            }
        )
        .padding(.bottom, bottomInset)
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: .bottom
        )
        .task(id: payload.id) {
            // Auto-expire — fires when the card mounts. Re-fires when a fresh
            // QR is detected (different `payload.id`), so the timer never
            // outlives the visible card.
            try? await Task.sleep(nanoseconds: UInt64(VisionViewModel.qrCardVisibleDuration * 1_000_000_000))
            if !Task.isCancelled, viewModel.scannedQR?.id == payload.id {
                viewModel.dismissScannedQR()
                viewModel.requestQRRescan()
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                // After a capture, back returns to the live camera — not text chat.
                if viewModel.hasFrozenCapture {
                    performRetake()
                } else {
                    dismiss()
                }
            } label: {
                Image(systemName: viewModel.hasFrozenCapture ? "chevron.left" : "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Color.black.opacity(0.45), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                viewModel.hasFrozenCapture ? "Back to camera" : "Close Vision"
            )

            Spacer(minLength: 0)

            Button {
                viewModel.showModelPicker = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "eye.fill")
                        .font(.system(size: 12, weight: .semibold))
                    Text(modelLabel)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.black.opacity(0.45), in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Vision model")
        }
    }

    private var bottomControls: some View {
        // Live: optional prompt + presets + shutter. After capture: Retake only.
        VStack(spacing: 14) {
            if viewModel.visionModels(from: state).isEmpty {
                emptyVisionModelsHint
            }

            if viewModel.hasFrozenCapture {
                // When the analysis card is open (medium/full), Retake lives on the
                // sheet header. Keep a bottom Retake only for the minimized pill state
                // so a second shot stays one tap away without fighting the card.
                if viewModel.sheetMode == .minimized || viewModel.sheetMode == .hidden {
                    HStack(alignment: .center, spacing: 16) {
                        Button {
                            performRetake()
                        } label: {
                            Label("Retake", systemImage: "camera.fill")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                                .background(Color.black.opacity(0.5), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(viewModel.isThinking)
                        .opacity(viewModel.isThinking ? 0.45 : 1)
                        .accessibilityLabel("Retake photo")

                        Spacer(minLength: 0)
                    }
                }
            } else {
                capturePromptPanel

                HStack(alignment: .center, spacing: 20) {
                    // Keep shutter centered; side slots reserved for balance.
                    Color.clear.frame(width: 72, height: 1)
                    captureButton
                    Color.clear.frame(width: 72, height: 1)
                }
                .padding(.bottom, 4)

                if !promptFieldFocused {
                    zoomChipRow
                }
            }
        }
    }

    /// 1× / 2× / Max chips in the iOS Camera-app style. Tap a chip → smooth
    /// ramp to the device's clamped factor. The "active" chip mirrors
    /// `currentZoomFactor`, which the controller republishes on every pinch /
    /// chip change.
    private var zoomChipRow: some View {
        HStack(spacing: 10) {
            ForEach(Array(zoomPresets.enumerated()), id: \.offset) { _, preset in
                let active = isZoomActive(preset)
                Button {
                    setZoom(preset.factor)
                } label: {
                    Text(preset.label)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(active ? Theme.background : .white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(
                            active ? Color.white : Color.black.opacity(0.45),
                            in: Capsule()
                        )
                        .overlay {
                            Capsule().stroke(
                                active ? Color.clear : Color.white.opacity(0.14),
                                lineWidth: 1
                            )
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(preset.label) zoom")
                .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
            }
        }
        .animation(.easeOut(duration: 0.18), value: currentZoomFactor)
    }

    /// Pinch-friendly presets: 1× stays exactly on the wide angle, 2× lands
    /// on the lens (when present) or the closest legal factor, Max pushes to
    /// the practical 5× ceiling.
    private var zoomPresets: [ZoomPreset] {
        [.init(label: ".5", factor: 0.5),
         .init(label: "1×", factor: 1),
         .init(label: "2×", factor: 2),
         .init(label: "Max", factor: 5)]
    }

    private func isZoomActive(_ preset: ZoomPreset) -> Bool {
        abs(currentZoomFactor - preset.factor) < 0.08
    }

    private func setZoom(_ factor: CGFloat) {
        pendingZoomFactor = factor
        currentZoomFactor = factor
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// Optional task prompt + saved presets above the shutter (live camera only).
    private var capturePromptPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Free vertical space for the shutter while typing.
            if !promptFieldFocused {
                presetChipsRow
            }

            HStack(alignment: .bottom, spacing: 8) {
                TextField(
                    "Optional prompt for this shot…",
                    text: $viewModel.capturePrompt,
                    axis: .vertical
                )
                .lineLimit(1 ... 3)
                .font(.system(size: 15))
                .foregroundStyle(.white)
                .tint(Theme.accent)
                .focused($promptFieldFocused)
                .onChange(of: viewModel.capturePrompt) { _, _ in
                    viewModel.capturePromptEdited()
                }
                // Multi-line fields ignore submit for Return — keyboard Done handles dismiss.

                if promptFieldFocused {
                    // Dismiss keyboard without capturing.
                    Button {
                        promptFieldFocused = false
                    } label: {
                        Image(systemName: "keyboard.chevron.compact.down")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                            .frame(width: 36, height: 36)
                            .background(Color.white.opacity(0.14), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss keyboard")

                    // Primary action while typing: take the photo (keeps prompt).
                    Button {
                        fireShutter()
                    } label: {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.background)
                            .frame(width: 40, height: 40)
                            .background(Theme.accent, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!viewModel.canCapture || viewModel.isThinking)
                    .opacity(viewModel.canCapture && !viewModel.isThinking ? 1 : 0.45)
                    .accessibilityLabel("Take photo")
                } else {
                    if viewModel.canSaveCapturePromptAsPreset {
                        Button {
                            newPresetTitle = suggestedPresetTitle
                            showSavePresetAlert = true
                        } label: {
                            Image(systemName: "bookmark.fill")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Theme.accent)
                                .frame(width: 36, height: 36)
                                .background(Color.white.opacity(0.12), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Save prompt as preset")
                    }

                    if viewModel.hasCustomCapturePrompt {
                        Button {
                            viewModel.clearCapturePrompt()
                            promptFieldFocused = false
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.85))
                                .frame(width: 36, height: 36)
                                .background(Color.white.opacity(0.12), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear prompt")
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(
                        promptFieldFocused ? Theme.accent.opacity(0.55) : Color.white.opacity(0.12),
                        lineWidth: 1
                    )
            }
        }
    }

    private var presetChipsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(promptStore.presets) { preset in
                    presetChip(preset)
                }

                Button {
                    viewModel.showPromptLibrary = true
                } label: {
                    Label("Manage", systemImage: "slider.horizontal.3")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.45), in: Capsule())
                        .overlay {
                            Capsule().stroke(Color.white.opacity(0.14), lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Manage prompt presets")
            }
            // Extra inset so edge fades don’t crop the first/last chips.
            .padding(.horizontal, 14)
        }
        // Soft transparent taper so chips dissolve into the camera at both ends.
        .mask {
            HStack(spacing: 0) {
                LinearGradient(
                    colors: [.clear, .black],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: 22)
                Rectangle().fill(.black)
                LinearGradient(
                    colors: [.black, .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: 22)
            }
        }
    }

    private func presetChip(_ preset: VisionPromptPreset) -> some View {
        let selected = viewModel.selectedPresetID == preset.id
        return Button {
            viewModel.selectPreset(preset)
            promptFieldFocused = false
        } label: {
            Text(preset.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(selected ? Theme.background : .white)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    selected ? Theme.accent : Color.black.opacity(0.45),
                    in: Capsule()
                )
                .overlay {
                    Capsule()
                        .stroke(
                            selected ? Color.clear : Color.white.opacity(0.14),
                            lineWidth: 1
                        )
                }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityLabel("\(preset.title) prompt")
    }

    private var suggestedPresetTitle: String {
        let text = viewModel.trimmedCapturePrompt
        let firstLine = text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? text
        if firstLine.count <= 28 {
            return firstLine
        }
        return String(firstLine.prefix(28)).trimmingCharacters(in: .whitespaces) + "…"
    }

    private var captureButton: some View {
        let compact = promptFieldFocused && keyboardVisible
        let outer: CGFloat = compact ? 64 : 78
        let inner: CGFloat = compact ? 52 : 64
        return Button {
            fireShutter()
        } label: {
            ZStack {
                Circle()
                    .strokeBorder(Color.white.opacity(0.95), lineWidth: 4)
                    .frame(width: outer, height: outer)
                Circle()
                    .fill(Color.white)
                    .frame(width: inner, height: inner)
                    .overlay {
                        if viewModel.isThinking {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .tint(Theme.inkOnAccent)
                                .scaleEffect(1.15)
                        } else if compact {
                            // Make “this shoots the photo” obvious while typing.
                            Image(systemName: "camera.fill")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(Color.black.opacity(0.75))
                        }
                    }
            }
            .shadow(color: Color(hex: 0x6AA9FF).opacity(viewModel.isThinking ? 0.65 : 0.25), radius: viewModel.isThinking ? 18 : 8)
        }
        .buttonStyle(.plain)
        .disabled(!viewModel.canCapture || viewModel.isThinking)
        .accessibilityLabel(viewModel.isThinking ? "Analyzing" : "Take photo")
    }

    /// Capture still + dismiss prompt keyboard.
    private func fireShutter() {
        guard viewModel.canCapture else { return }
        if viewModel.visionModels(from: state).isEmpty {
            promptFieldFocused = false
            viewModel.showModelPicker = true
            return
        }
        promptFieldFocused = false
        // Freeze preview + open analyzing UI on the same tap — do not wait for
        // the processed still (that lands in onCapture → analyze).
        viewModel.beginCapture()
        captureTrigger = UUID()
    }

    private func updateKeyboardHeight(from note: Notification) {
        guard
            let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
        else { return }
        let screenH = UIScreen.main.bounds.height
        keyboardHeight = max(0, screenH - frame.origin.y)
    }

    private var emptyVisionModelsHint: some View {
        Button {
            // Opens the Vision model sheet, which has download + API key shortcuts.
            viewModel.showModelPicker = true
        } label: {
            Text("Download a Vision model or add an API key")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.black.opacity(0.5), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var modelLabel: String {
        if let model = viewModel.selectedModel {
            return state.displayName(for: model)
        }
        return "Select model"
    }

    /// Shared retake path for bottom chrome and the analysis sheet.
    private func performRetake() {
        // Clear the trigger first: retake remounts a fresh camera whose
        // coordinator has no last-trigger, so a stale UUID would re-fire.
        captureTrigger = nil
        promptFieldFocused = false
        captureZoomResetID = UUID()
        // Snap the live viewfinder back to 1× so the next shot isn't silently
        // framed at 3× from the previous one.
        cameraZoomResetID = UUID()
        currentZoomFactor = 1
        pendingZoomFactor = nil
        viewModel.retake()
    }
}

// MARK: - Vision model picker

/// Zoom preset label / factor shown in the live viewfinder chip row.
struct ZoomPreset: Equatable {
    let label: String
    let factor: CGFloat
}

/// Frozen still after capture. Owns the zoom/pan/crop photo + Live Text
/// overlay band above the analysis card. Extracted from `body` so type
/// inference stays under the compiler's timeout.
private struct VisionFrozenStillOverlay: View {
    let image: UIImage
    let resetID: UUID
    let totalSize: CGSize
    let topChromeClearance: CGFloat
    let imageBandHeight: CGFloat
    var liveTextEnabled: Bool
    var onSingleTap: () -> Void
    var onCropCommitted: (CGRect) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: topChromeClearance)
                .allowsHitTesting(false)
            VisionZoomableImageView(
                image: image,
                resetID: resetID,
                onSingleTap: onSingleTap,
                onCropCommitted: onCropCommitted,
                liveTextEnabled: liveTextEnabled
            )
            .frame(width: totalSize.width, height: imageBandHeight)
            .animation(
                .interactiveSpring(response: 0.32, dampingFraction: 0.86),
                value: imageBandHeight
            )
            Spacer(minLength: 0)
                .allowsHitTesting(false)
        }
    }
}

/// Pre-computed layout values for the Vision body. Extracted from a single
/// `GeometryReader` so Swift's type-checker can resolve the dense chain.
private struct LayoutValues {
    let size: CGSize
    let safeAreaInsets: EdgeInsets
    let shutterStackClearance: CGFloat
    let hasFrozenCapture: Bool
    let sheetMode: VisionViewModel.SheetMode
    let keyboardHeight: CGFloat
    let keyboardVisible: Bool

    var bottomSafe: CGFloat {
        safeAreaInsets.bottom
    }

    var topSafe: CGFloat {
        max(safeAreaInsets.top, 54)
    }

    var chromeBlockHeight: CGFloat {
        let base: CGFloat = {
            if !hasFrozenCapture {
                return shutterStackClearance
            }
            switch sheetMode {
            case .minimized: return 56
            case .expanded, .full: return 8
            case .hidden: return 52
            }
        }()
        return base + max(bottomSafe, 8)
    }

    var topChromeClearance: CGFloat {
        topSafe + 6 + 44 + 10
    }

    var bottomPad: CGFloat {
        if keyboardVisible, !hasFrozenCapture {
            return max(keyboardHeight, bottomSafe) + 8
        }
        return max(bottomSafe, 8) + 10
    }
}

/// Live-camera + top bar + bottom chrome stack. Extracted from `body` so
/// Swift's type-checker can chew on each chunk in isolation — the inner view
/// graph is dense enough that splitting is the only way to stay under the
/// default timeout.
private struct VisionCameraAndChromeStack: View {
    @ObservedObject var viewModel: VisionViewModel
    var horizontalInset: CGFloat
    var topSafe: CGFloat
    var bottomPad: CGFloat
    var totalWidth: CGFloat
    var totalHeight: CGFloat
    var cameraLayer: AnyView
    var topBar: AnyView
    var bottomControls: AnyView
    var onPromptDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            topBar
                .padding(.horizontal, horizontalInset)

            if viewModel.showsCameraSession {
                cameraLayer
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
                    .padding(.bottom, 10)
                    .contentShape(Rectangle())
                    .onTapGesture { onPromptDismiss() }
                    .accessibilityLabel(
                        viewModel.freezesCameraPreview
                            ? "Frozen photo preview"
                            : "Camera preview"
                    )
            } else {
                Spacer(minLength: 0)
                    .allowsHitTesting(false)
            }

            bottomControls
                .padding(.horizontal, horizontalInset)
        }
        .padding(.top, topSafe + 6)
        .padding(.bottom, bottomPad)
        .frame(width: totalWidth, height: totalHeight)
    }
}

private struct VisionModelPickerSheet: View {
    @ObservedObject var viewModel: VisionViewModel
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var showLocalMetal = false
    @State private var showProviderSettings = false
    @State private var expandedVisionProviders: Set<ProviderID> = []
    @State private var expandedVisionOrgs: Set<String> = []

    private var models: [AIModel] {
        viewModel.visionModels(from: state)
    }

    private var grouped: [(ProviderID, [AIModel])] {
        let map = Dictionary(grouping: models, by: \.provider)
        return map.keys.sorted { $0.rawValue < $1.rawValue }.map { id in
            (id, map[id] ?? [])
        }
    }

    private func visionOrg(_ model: AIModel) -> String {
        model.organization
            ?? model.modelID.split(separator: "/", maxSplits: 1).first.map(String.init)
            ?? "Other"
    }

    /// OpenRouter's vision catalog is huge — nest it as submenus, one per
    /// vendor / organization tag (e.g. OpenAI, Anthropic, Meta).
    @ViewBuilder
    private func openRouterSection(models: [AIModel]) -> some View {
        let groups = Dictionary(grouping: models, by: visionOrg)
            .map { (org: $0.key, models: $0.value) }
            .sorted { $0.org.localizedCaseInsensitiveCompare($1.org) == .orderedAscending }
        ForEach(groups, id: \.org) { group in
            DisclosureGroup(isExpanded: visionExpandedBinding(for: group.org)) {
                ForEach(group.models) { model in
                    visionModelRow(model)
                }
            } label: {
                openRouterSubmenuLabel(
                    title: AIModel.prettifiedDisplayName(for: group.org),
                    detail: "\(group.models.count)"
                )
            }
            .tint(Theme.textSecondary)
            .listRowBackground(Theme.surface)
        }
    }

    private func openRouterSubmenuLabel(title: String, detail: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
            Text(detail)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textTertiary)
            Spacer(minLength: 0)
        }
    }

    private func visionProviderBinding(for provider: ProviderID) -> Binding<Bool> {
        Binding(
            get: { expandedVisionProviders.contains(provider) },
            set: { expanded in
                if expanded {
                    expandedVisionProviders.insert(provider)
                } else {
                    expandedVisionProviders.remove(provider)
                }
            }
        )
    }

    private func visionExpandedBinding(for org: String) -> Binding<Bool> {
        Binding(
            get: { expandedVisionOrgs.contains(org) },
            set: { expanded in
                if expanded {
                    expandedVisionOrgs.insert(org)
                } else {
                    expandedVisionOrgs.remove(org)
                }
            }
        )
    }

    private func visionModelRow(_ model: AIModel) -> some View {
        Button {
            viewModel.selectedModel = model
            dismiss()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(state.displayName(for: model))
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        Text("Vision")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.yellow)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.yellow.opacity(0.18), in: Capsule())
                    }
                    Text(model.modelID)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer()
                if viewModel.selectedModel?.id == model.id {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.accent)
                }
            }
        }
        .listRowBackground(Theme.surface)
    }

    var body: some View {
        SheetScaffold(title: "Vision model", trailing: nil, onClose: { dismiss() }) {
            if models.isEmpty {
                emptyVisionModels
            } else {
                List {
                    if viewModel.supportsWebTools {
                        Section {
                            Toggle(isOn: webSearchBinding) {
                                Label {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Web search")
                                            .font(.system(size: 16, weight: .medium))
                                            .foregroundStyle(Theme.textPrimary)
                                        Text(webSearchFooter)
                                            .font(.system(size: 12))
                                            .foregroundStyle(Theme.textTertiary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                } icon: {
                                    Image(systemName: "globe")
                                        .foregroundStyle(Theme.accent)
                                }
                            }
                            .tint(Theme.selection)
                            .listRowBackground(Theme.surface)

                            Toggle(isOn: researchBinding) {
                                Label {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Research")
                                            .font(.system(size: 16, weight: .medium))
                                            .foregroundStyle(Theme.textPrimary)
                                        Text(researchFooter)
                                            .font(.system(size: 12))
                                            .foregroundStyle(Theme.textTertiary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                } icon: {
                                    Image(systemName: "magnifyingglass")
                                        .foregroundStyle(Theme.accent)
                                }
                            }
                            .tint(Theme.selection)
                            .listRowBackground(Theme.surface)
                        } header: {
                            Text("Tools")
                                .foregroundStyle(Theme.textSecondary)
                        } footer: {
                            Text("Client-side web tools work with any vision model. On capture, search uses terms from the photo — never the system prompt. Follow-ups search the question text.")
                                .foregroundStyle(Theme.textTertiary)
                        }
                    }

                    ForEach(grouped, id: \.0) { provider, list in
                        Section {
                            DisclosureGroup(isExpanded: visionProviderBinding(for: provider)) {
                                if provider == .openrouter {
                                    openRouterSection(models: list)
                                } else {
                                    ForEach(list) { model in
                                        visionModelRow(model)
                                    }
                                }
                            } label: {
                                openRouterSubmenuLabel(
                                    title: provider.displayName,
                                    detail: "\(list.count) model\(list.count == 1 ? "" : "s")"
                                )
                            }
                            .tint(Theme.textSecondary)
                            .listRowBackground(Theme.surface)
                        }
                    }

                    Section {
                        downloadModelsRow
                        addAPIKeyRow
                    } footer: {
                        Text("Need another model? Download an on-device VLM or add a cloud API key.")
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
        }
        .background(Theme.background)
        .sheet(isPresented: $showLocalMetal, onDismiss: {
            Task {
                await state.refreshModels()
                viewModel.bind(state: state)
            }
        }) {
            LocalMetalSettingsView()
                .environmentObject(state)
        }
        .sheet(isPresented: $showProviderSettings, onDismiss: {
            Task {
                await state.refreshModels()
                viewModel.bind(state: state)
            }
        }) {
            AppSettingsView()
                .environmentObject(state)
        }
        .onChange(of: state.allModels.map(\.id)) { _, _ in
            viewModel.bind(state: state)
        }
        .task {
            if let selected = viewModel.selectedModel {
                expandedVisionProviders.insert(selected.provider)
                if selected.provider == .openrouter {
                    expandedVisionOrgs.insert(visionOrg(selected))
                }
            }
        }
    }

    private var emptyVisionModels: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 12)

            Image(systemName: "eye.slash")
                .font(.system(size: 40, weight: .medium))
                .foregroundStyle(Theme.textTertiary)
                .symbolRenderingMode(.hierarchical)

            VStack(spacing: 8) {
                Text("No vision models")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Download an on-device Vision model, or add an API key for OpenAI, Anthropic, OpenRouter, or xAI. Custom providers can be marked Supports vision in Settings.")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 8)

            VStack(spacing: 12) {
                Button {
                    showLocalMetal = true
                } label: {
                    Label("Download on-device models", systemImage: "arrow.down.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .foregroundStyle(Theme.background)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens on-device Metal model downloads")

                Button {
                    showProviderSettings = true
                } label: {
                    Label("Add API key in Settings", systemImage: "key.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .foregroundStyle(Theme.textPrimary)
                        .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Theme.separator.opacity(0.8), lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 4)

            Spacer(minLength: 12)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var webSearchBinding: Binding<Bool> {
        Binding(
            get: { viewModel.webSearchEnabled || viewModel.researchEnabled },
            set: { viewModel.setWebSearchEnabled($0) }
        )
    }

    private var researchBinding: Binding<Bool> {
        Binding(
            get: { viewModel.researchEnabled },
            set: { viewModel.setResearchEnabled($0) }
        )
    }

    private var webSearchFooter: String {
        if viewModel.researchEnabled {
            return "On — required for Research"
        }
        if viewModel.webSearchEnabled {
            return "On — searches photo content + follow-ups (not the system prompt)"
        }
        return "Off — model answers from the photo only"
    }

    private var researchFooter: String {
        if viewModel.researchEnabled {
            return "On — multi-query search + Wikipedia"
        }
        return "Deeper multi-query search with Wikipedia extracts"
    }

    private var downloadModelsRow: some View {
        Button {
            showLocalMetal = true
        } label: {
            Label("Download on-device models", systemImage: "arrow.down.circle")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Theme.accent)
        }
        .listRowBackground(Theme.surface)
    }

    private var addAPIKeyRow: some View {
        Button {
            showProviderSettings = true
        } label: {
            Label("Add API key…", systemImage: "key")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
        }
        .listRowBackground(Theme.surface)
    }
}

// MARK: - Re-analyze with a different prompt

/// Change the task/system prompt and re-run analysis on the frozen still
/// (optional crop is preserved). Web search still keys off photo content.
private struct VisionReanalyzePromptSheet: View {
    @ObservedObject var viewModel: VisionViewModel
    @ObservedObject var promptStore: VisionPromptStore
    @Environment(\.dismiss) private var dismiss
    @FocusState private var promptFocused: Bool

    var body: some View {
        SheetScaffold(
            title: "Re-analyze",
            trailing: AnyView(
                Button {
                    viewModel.reanalyzeWithCurrentPrompt()
                } label: {
                    Text("Run")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .frame(height: 44)
                }
                .buttonStyle(.plain)
                .disabled(!viewModel.canReanalyze)
                .accessibilityLabel("Re-analyze with this prompt")
            ),
            onClose: { dismiss() }
        ) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Same photo, new instructions. Web search still uses terms from the image — not this prompt.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Task prompt")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)
                        TextField(
                            "Empty = general analysis",
                            text: $viewModel.capturePrompt,
                            axis: .vertical
                        )
                        .lineLimit(3 ... 10)
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.textPrimary)
                        .tint(Theme.accent)
                        .focused($promptFocused)
                        .padding(12)
                        .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .onChange(of: viewModel.capturePrompt) { _, _ in
                            viewModel.capturePromptEdited()
                        }
                    }

                    if !promptStore.presets.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Presets")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.textSecondary)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(promptStore.presets) { preset in
                                        Button {
                                            viewModel.selectPreset(preset)
                                        } label: {
                                            Text(preset.title)
                                                .font(.system(size: 13, weight: .medium))
                                                .foregroundStyle(
                                                    viewModel.selectedPresetID == preset.id
                                                        ? Theme.background
                                                        : Theme.textPrimary
                                                )
                                                .padding(.horizontal, 12)
                                                .padding(.vertical, 8)
                                                .background(
                                                    viewModel.selectedPresetID == preset.id
                                                        ? Theme.accent
                                                        : Theme.surfaceElevated,
                                                    in: Capsule()
                                                )
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }

                    Button {
                        promptFocused = false
                        viewModel.reanalyzeWithCurrentPrompt()
                    } label: {
                        Text("Re-analyze photo")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Theme.background)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(!viewModel.canReanalyze)
                    .opacity(viewModel.canReanalyze ? 1 : 0.45)
                    .padding(.top, 4)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
        }
        .background(Theme.background)
        .presentationDetents([.medium, .large])
        .onAppear {
            // Small delay so the sheet presentation finishes before focus.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                promptFocused = true
            }
        }
    }
}

// MARK: - Prompt library

private struct VisionPromptLibrarySheet: View {
    @ObservedObject var viewModel: VisionViewModel
    @ObservedObject var promptStore: VisionPromptStore
    @Environment(\.dismiss) private var dismiss

    @State private var editing: VisionPromptPreset?
    @State private var draftTitle = ""
    @State private var draftPrompt = ""
    @State private var showEditor = false
    @State private var isCreating = false

    var body: some View {
        SheetScaffold(
            title: "Prompt presets",
            trailing: AnyView(
                Button {
                    isCreating = true
                    draftTitle = ""
                    draftPrompt = viewModel.trimmedCapturePrompt
                    editing = nil
                    showEditor = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("New preset")
            ),
            onClose: { dismiss() }
        ) {
            List {
                Section {
                    ForEach(promptStore.presets) { preset in
                        Button {
                            viewModel.selectPreset(preset)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 8) {
                                    Text(preset.title)
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundStyle(Theme.textPrimary)
                                    if preset.isBuiltIn {
                                        Text("Built-in")
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundStyle(Theme.textTertiary)
                                            .padding(.horizontal, 7)
                                            .padding(.vertical, 3)
                                            .background(Theme.surfaceElevated, in: Capsule())
                                    }
                                    if viewModel.selectedPresetID == preset.id {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(Theme.accent)
                                    }
                                    Spacer(minLength: 0)
                                }
                                Text(presetPreview(preset))
                                    .font(.system(size: 13))
                                    .foregroundStyle(Theme.textSecondary)
                                    .lineLimit(2)
                            }
                            .padding(.vertical, 4)
                        }
                        .listRowBackground(Theme.surface)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button {
                                isCreating = false
                                editing = preset
                                draftTitle = preset.title
                                draftPrompt = preset.prompt
                                showEditor = true
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            .tint(Theme.accent)

                            if !preset.isBuiltIn || preset.id != VisionPromptStore.defaultPresetID {
                                Button(role: .destructive) {
                                    viewModel.deletePreset(id: preset.id)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                } header: {
                    Text("Tap to use · swipe to edit")
                        .foregroundStyle(Theme.textSecondary)
                } footer: {
                    Text("Empty prompt uses a general photo analysis. Saved presets stay on this device.")
                        .foregroundStyle(Theme.textTertiary)
                }

                Section {
                    Button {
                        promptStore.restoreBuiltIns()
                    } label: {
                        Label("Restore built-in presets", systemImage: "arrow.counterclockwise")
                            .foregroundStyle(Theme.accent)
                    }
                    .listRowBackground(Theme.surface)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        }
        .background(Theme.background)
        .sheet(isPresented: $showEditor) {
            VisionPromptEditorSheet(
                title: isCreating ? "New preset" : "Edit preset",
                draftTitle: $draftTitle,
                draftPrompt: $draftPrompt,
                onCancel: { showEditor = false },
                onSave: {
                    let name = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                    let body = draftPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty else { return }
                    if isCreating {
                        let created = promptStore.add(title: name, prompt: body)
                        viewModel.selectPreset(created)
                    } else if var preset = editing {
                        preset.title = name
                        preset.prompt = body
                        viewModel.updatePreset(preset)
                    }
                    showEditor = false
                }
            )
            .presentationDetents([.medium, .large])
        }
    }

    private func presetPreview(_ preset: VisionPromptPreset) -> String {
        let p = preset.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.isEmpty {
            return "Default general analysis"
        }
        return p.replacingOccurrences(of: "\n", with: " ")
    }
}

private struct VisionPromptEditorSheet: View {
    var title: String
    @Binding var draftTitle: String
    @Binding var draftPrompt: String
    var onCancel: () -> Void
    var onSave: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("e.g. Receipt scan", text: $draftTitle)
                }
                Section("Prompt") {
                    TextField(
                        "Instructions for the vision model…",
                        text: $draftPrompt,
                        axis: .vertical
                    )
                    .lineLimit(4 ... 12)
                }
                Section {
                    Text("Leave the prompt empty for the built-in general analysis.")
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: onSave)
                        .disabled(draftTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
