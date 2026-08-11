import SwiftUI
import UIKit
import AnyProvCore

/// Full-screen Study scan flow: camera → vision analysis → editable
/// flashcards → save into the session deck.
struct StudyScanView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel = StudyViewModel()

    @State private var captureTrigger: UUID?
    @State private var cameraError: String?
    @State private var showProviderSettings = false
    @State private var showLocalMetal = false
    @State private var showDiscardConfirm = false
    @State private var showExitConfirm = false

    private let bottomSafePadding: CGFloat = 14

    var body: some View {
        content
            .statusBarHidden(false)
            .preferredColorScheme(.dark)
            .onAppear {
                viewModel.bind(state: state)
                Task {
                    await state.refreshModels()
                    viewModel.bind(state: state)
                }
            }
            .onChange(of: state.allModels.map(\.id)) { _, _ in
                if viewModel.selectedModel == nil
                    || (viewModel.selectedModel.map { !state.modelSupportsVision($0) } ?? false)
                {
                    viewModel.bind(state: state)
                }
            }
            .sheet(isPresented: $viewModel.showModelPicker) {
                StudyModelPickerSheet(viewModel: viewModel)
                    .environmentObject(state)
                    .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showProviderSettings) {
                AppSettingsView()
                    .environmentObject(state)
            }
            .sheet(isPresented: $showLocalMetal) {
                LocalMetalSettingsView()
                    .environmentObject(state)
            }
            .alert("Discard unsaved cards?", isPresented: $showDiscardConfirm) {
                Button("Discard & scan next", role: .destructive) {
                    viewModel.startNextScan()
                }
                Button("Keep editing", role: .cancel) {}
            } message: {
                Text(discardMessage)
            }
            .alert("Discard unsaved cards?", isPresented: $showExitConfirm) {
                Button("Discard & exit", role: .destructive) {
                    dismiss()
                }
                Button("Keep editing", role: .cancel) {}
            } message: {
                Text(discardMessage)
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

    @ViewBuilder
    private var content: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            if viewModel.phase == .review {
                reviewView
            } else if viewModel.isFailed {
                failedView
            } else {
                cameraChrome
            }
        }
    }

    // MARK: - Close handling

    private var discardMessage: String {
        let suffix = viewModel.unsavedCount == 1 ? "" : "s"
        return "You have \(viewModel.unsavedCount) unsaved card\(suffix). They won't be added to the deck."
    }

    private func handleClose() {
        if viewModel.phase == .review && viewModel.hasUnsavedCards {
            showExitConfirm = true
        } else {
            dismiss()
        }
    }

    private func handleNextQuestions() {
        if viewModel.hasUnsavedCards {
            showDiscardConfirm = true
        } else {
            viewModel.startNextScan()
        }
    }

    // MARK: - Camera chrome (live / capturing / analyzing)

    @ViewBuilder
    private var cameraChrome: some View {
        VStack(spacing: 0) {
            topBar
            cameraArea
            bottomControls
        }
        .padding(.top, 12)
        .padding(.bottom, bottomSafePadding)
    }

    @ViewBuilder
    private var cameraArea: some View {
        if viewModel.showsCameraSession {
            cameraLayer
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 10)
                .overlay {
                    if viewModel.isThinking {
                        analyzingOverlay(image: nil)
                    }
                }
        } else if let image = viewModel.capturedImage, viewModel.isThinking {
            // Still landed but analysis is still running.
            analyzingOverlay(image: image)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 10)
        } else {
            Spacer(minLength: 0)
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button(action: handleClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Color.black.opacity(0.45), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close Study")

            Spacer(minLength: 0)

            Button {
                viewModel.showModelPicker = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "graduationcap.fill")
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
            .accessibilityLabel("Study model")
        }
        .padding(.horizontal, 16)
    }

    private var cameraLayer: some View {
        VisionCameraView(
            onCapture: { image in
                captureTrigger = nil
                viewModel.analyze(image: image)
            },
            onError: { message in
                cameraError = message
            },
            onShutter: {
                viewModel.beginCapture()
            },
            captureTrigger: captureTrigger,
            isSessionActive: viewModel.showsCameraSession,
            isPreviewFrozen: viewModel.freezesCameraPreview
        )
    }

    private func analyzingOverlay(image: UIImage? = nil) -> some View {
        ZStack {
            Color.black.opacity(0.35)
            VStack(spacing: 16) {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 220, maxHeight: 280)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Color.white.opacity(0.2), lineWidth: 1)
                        }
                }
                ProgressView()
                    .controlSize(.large)
                    .tint(Theme.accent)
                Text("Reading questions…")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white)
            }
            .padding(24)
            .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .allowsHitTesting(false)
    }

    private var bottomControls: some View {
        VStack(spacing: 14) {
            if viewModel.visionModels(from: state).isEmpty {
                emptyVisionModelsHint
            }

            if viewModel.hasFrozenCapture {
                HStack(spacing: 16) {
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
            } else {
                HStack(alignment: .center, spacing: 20) {
                    Color.clear.frame(width: 72, height: 1)
                    captureButton
                    Color.clear.frame(width: 72, height: 1)
                }
            }
        }
    }

    private var captureButton: some View {
        Button {
            fireShutter()
        } label: {
            ZStack {
                Circle()
                    .strokeBorder(Color.white.opacity(0.95), lineWidth: 4)
                    .frame(width: 78, height: 78)
                Circle()
                    .fill(Color.white)
                    .frame(width: 64, height: 64)
            }
            .shadow(color: Theme.accent.opacity(0.3), radius: 10)
        }
        .buttonStyle(.plain)
        .disabled(!viewModel.canCapture || viewModel.isThinking)
        .accessibilityLabel("Scan questions")
    }

    private func fireShutter() {
        guard viewModel.canCapture else { return }
        if viewModel.visionModels(from: state).isEmpty {
            viewModel.showModelPicker = true
            return
        }
        viewModel.beginCapture()
        captureTrigger = UUID()
    }

    private func performRetake() {
        captureTrigger = nil
        viewModel.startNextScan()
    }

    private var emptyVisionModelsHint: some View {
        Button {
            viewModel.showModelPicker = true
        } label: {
            Text("Add a Vision model to scan")
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

    // MARK: - Review (flashcards)

    private var reviewView: some View {
        VStack(spacing: 0) {
            reviewHeader
            if viewModel.cards.isEmpty {
                emptyReviewState
            } else {
                ScrollView {
                    LazyVStack(spacing: 14) {
                        ForEach(Array(viewModel.cards.enumerated()), id: \.element.id) { index, card in
                            StudyFlashcardCardView(
                                index: index + 1,
                                question: textBinding(for: card.id, keyPath: \.question),
                                answer: textBinding(for: card.id, keyPath: \.answer),
                                reasoning: textBinding(for: card.id, keyPath: \.reasoning),
                                saveState: saveState(for: card),
                                onEdit: {
                                    viewModel.cardEdited(id: card.id)
                                },
                                onSave: {
                                    viewModel.saveCard(id: card.id)
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 12)
                }
                .scrollDismissesKeyboard(.interactively)
            }

            reviewBottomBar
        }
        .background(Theme.background)
    }

    private var emptyReviewState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 40, weight: .medium))
                .foregroundStyle(Theme.textTertiary)
            Text("No questions found")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("The model couldn't pick out any questions from this photo. Try a closer shot, or scan the next page.")
                .font(.system(size: 14))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func textBinding(
        for id: UUID,
        keyPath: WritableKeyPath<StudyFlashcardDraft, String>
    ) -> Binding<String> {
        Binding(
            get: {
                viewModel.cards.first(where: { $0.id == id })?[keyPath: keyPath] ?? ""
            },
            set: { newValue in
                guard let idx = viewModel.cards.firstIndex(where: { $0.id == id }) else { return }
                viewModel.cards[idx][keyPath: keyPath] = newValue
            }
        )
    }

    private func saveState(for card: StudyFlashcardDraft) -> StudyCardSaveState {
        if card.isSaved && card.isDirty { return .dirty }
        if card.isSaved { return .saved }
        return .unsaved
    }

    private var reviewHeader: some View {
        HStack(alignment: .center, spacing: 10) {
            Button(action: handleClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 40, height: 40)
                    .background(Theme.surfaceElevated, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close Study")

            VStack(alignment: .leading, spacing: 2) {
                Text("Question cards")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                    Text(
                        viewModel.cards.isEmpty
                            ? "No questions found"
                            : "\(viewModel.savedCount) of \(viewModel.cards.count) saved"
                    )
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                }
            }

            Spacer(minLength: 0)

            if viewModel.savedCount == viewModel.cards.count, !viewModel.cards.isEmpty {
                Label("All saved", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .background(Theme.background)
    }

    private var reviewBottomBar: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Theme.separator.opacity(0.7))
                .frame(height: 1)

            HStack(spacing: 12) {
                Button {
                    viewModel.saveAllCards()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "tray.and.arrow.down.fill")
                            .font(.system(size: 14, weight: .semibold))
                        Text(viewModel.hasUnsavedCards ? "Save all" : "All saved")
                            .font(.system(size: 15, weight: .semibold))
                        if viewModel.hasUnsavedCards {
                            Text("\(viewModel.unsavedCount)")
                                .font(.system(size: 13, weight: .bold).monospacedDigit())
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Theme.inkOnAccent.opacity(0.18), in: Capsule())
                        }
                    }
                    .foregroundStyle(viewModel.canSaveAll ? Theme.background : Theme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        viewModel.canSaveAll ? Theme.accent : Theme.surfaceElevated,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
                .disabled(!viewModel.canSaveAll)
                .accessibilityLabel(viewModel.canSaveAll ? "Save all cards" : "All cards saved")

                Button {
                    handleNextQuestions()
                } label: {
                    HStack(spacing: 8) {
                        Text("Next questions")
                            .font(.system(size: 15, weight: .semibold))
                        Image(systemName: "arrow.right")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundStyle(Theme.textPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Theme.separator.opacity(0.8), lineWidth: 1)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Scan the next page of questions")
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, max(bottomSafePadding, 4))
            .background(Theme.background)
        }
    }

    // MARK: - Failed

    private var failedView: some View {
        VStack(spacing: 20) {
            topBar

            Spacer()

            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 40, weight: .medium))
                    .foregroundStyle(Color.orange)
                Text("Couldn't read the questions")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                Text(viewModel.errorMessage ?? "")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.75))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 32)

                HStack(spacing: 12) {
                    Button {
                        performRetake()
                    } label: {
                        Label("Retake", systemImage: "camera.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 12)
                            .background(Color.white.opacity(0.14), in: Capsule())
                    }
                    .buttonStyle(.plain)

                    Button {
                        viewModel.retryAnalysis()
                    } label: {
                        Label("Try again", systemImage: "arrow.clockwise")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.background)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 12)
                            .background(Theme.accent, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(!viewModel.canRetry)
                }
                .padding(.top, 4)
            }

            Spacer()
            Spacer()
        }
        .padding(.top, 12)
        .padding(.bottom, bottomSafePadding)
        .background(Color.black.ignoresSafeArea())
    }
}

// MARK: - Study model picker

private struct StudyModelPickerSheet: View {
    @ObservedObject var viewModel: StudyViewModel
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var showLocalMetal = false
    @State private var showProviderSettings = false

    private var models: [AIModel] {
        viewModel.visionModels(from: state)
    }

    var body: some View {
        SheetScaffold(title: "Study model", trailing: nil, onClose: { dismiss() }) {
            if models.isEmpty {
                emptyModels
            } else {
                List {
                    Section {
                        ForEach(models) { model in
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
                        Text("Vision models")
                            .foregroundStyle(Theme.textSecondary)
                    }

                    Section {
                        Button {
                            showLocalMetal = true
                        } label: {
                            Label("Download on-device models", systemImage: "arrow.down.circle")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(Theme.accent)
                        }
                        .listRowBackground(Theme.surface)

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
    }

    private var emptyModels: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 12)

            Image(systemName: "graduationcap")
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
}
