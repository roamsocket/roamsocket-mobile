import SwiftUI
import AnyProvCore

/// Full-screen Vision mode: live camera, edge glow, capture, minimizable analysis.
struct VisionView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel = VisionViewModel()

    @State private var captureTrigger: UUID?
    @State private var cameraError: String?
    @State private var showProviderSettings = false

    var body: some View {
        ZStack {
            // Camera (or frozen capture) fills the screen.
            cameraLayer
                .ignoresSafeArea()

            VisionGlowOverlay(isThinking: viewModel.isThinking)

            // Analysis popover sits above the white capture button, under chrome
            // so Close / model picker stay tappable and never get clipped.
            VisionAnalysisSheet(
                viewModel: viewModel,
                modelDisplayName: modelLabel
            )
            .padding(.bottom, 110)
            .zIndex(1)

            // Chrome over the live feed + sheet. Spacer must not steal hits so
            // the analysis sheet can still drag / scroll underneath.
            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                    .allowsHitTesting(false)
                bottomControls
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 28)
            .zIndex(2)
        }
        .background(Color.black.ignoresSafeArea())
        .statusBarHidden(false)
        .preferredColorScheme(.dark)
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
        .alert("Camera", isPresented: Binding(
            get: { cameraError != nil },
            set: { if !$0 { cameraError = nil } }
        )) {
            Button("OK", role: .cancel) { cameraError = nil }
        } message: {
            Text(cameraError ?? "")
        }
    }

    // MARK: - Layers

    @ViewBuilder
    private var cameraLayer: some View {
        ZStack {
            if let image = viewModel.capturedImage {
                // Frozen capture. The live camera and its AVCaptureSession are fully
                // unmounted here — not just paused — so their buffers are released
                // instead of competing with the on-device VLM for GPU + RAM. Leaving
                // the camera hot during Metal inference is a common crash source.
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            } else {
                VisionCameraView(
                    onCapture: { image in
                        viewModel.analyze(image: image)
                    },
                    onError: { cameraError = $0 },
                    captureTrigger: captureTrigger,
                    isSessionActive: true
                )
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Color.black.opacity(0.45), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close Vision")

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
        // White shutter stays centered at the bottom; spinner while the model thinks.
        VStack(spacing: 16) {
            if viewModel.visionModels(from: state).isEmpty {
                emptyVisionModelsHint
            }

            HStack(alignment: .center, spacing: 28) {
                if viewModel.capturedImage != nil {
                    Button {
                        // Clear the trigger first: retake remounts a fresh camera
                        // whose coordinator has no last-trigger, so a stale UUID here
                        // would fire an immediate, unwanted re-capture.
                        captureTrigger = nil
                        viewModel.retake()
                    } label: {
                        Text("Retake")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(Color.black.opacity(0.45), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.isThinking)
                    .opacity(viewModel.isThinking ? 0.45 : 1)
                    .frame(width: 88, alignment: .leading)
                } else {
                    Color.clear.frame(width: 88, height: 1)
                }

                captureButton

                Color.clear.frame(width: 88, height: 1)
            }
        }
    }

    private var captureButton: some View {
        Button {
            guard viewModel.canCapture else { return }
            if viewModel.visionModels(from: state).isEmpty {
                showProviderSettings = true
                return
            }
            // Keep the freeze-frame until a new photo arrives.
            captureTrigger = UUID()
        } label: {
            ZStack {
                Circle()
                    .strokeBorder(Color.white.opacity(0.95), lineWidth: 4)
                    .frame(width: 78, height: 78)
                Circle()
                    .fill(Color.white)
                    .frame(width: 64, height: 64)
                    .overlay {
                        if viewModel.isThinking {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .tint(Theme.inkOnAccent)
                                .scaleEffect(1.15)
                        }
                    }
            }
            .shadow(color: Color(hex: 0x6AA9FF).opacity(viewModel.isThinking ? 0.65 : 0.25), radius: viewModel.isThinking ? 18 : 8)
        }
        .buttonStyle(.plain)
        .disabled(!viewModel.canCapture || viewModel.isThinking)
        .accessibilityLabel(viewModel.isThinking ? "Analyzing" : "Capture")
    }

    private var emptyVisionModelsHint: some View {
        Button {
            showProviderSettings = true
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
}

// MARK: - Vision model picker

private struct VisionModelPickerSheet: View {
    @ObservedObject var viewModel: VisionViewModel
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    private var models: [AIModel] {
        viewModel.visionModels(from: state)
    }

    private var grouped: [(ProviderID, [AIModel])] {
        let map = Dictionary(grouping: models, by: \.provider)
        return map.keys.sorted { $0.rawValue < $1.rawValue }.map { id in
            (id, map[id] ?? [])
        }
    }

    var body: some View {
        SheetScaffold(title: "Vision model", trailing: nil, onClose: { dismiss() }) {
            if models.isEmpty {
                ContentUnavailableView(
                    "No vision models",
                    systemImage: "eye.slash",
                    description: Text("Download an on-device Vision model (Settings → On-device), add an API key for OpenAI / Anthropic / OpenRouter / xAI, or mark a custom provider as Supports vision.")
                )
                .foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(grouped, id: \.0) { provider, list in
                        Section {
                            ForEach(list) { model in
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
                        } header: {
                            Text(provider.displayName)
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
        }
        .background(Theme.background)
    }
}
