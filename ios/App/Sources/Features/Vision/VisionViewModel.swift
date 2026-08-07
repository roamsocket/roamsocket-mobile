import Foundation
import UIKit
import AnyProvCore

/// Drives capture → multimodal analysis for Vision mode.
@MainActor
final class VisionViewModel: ObservableObject {
    enum Phase: Equatable {
        case live
        case capturing
        case analyzing
        case result
        case failed(String)
    }

    /// How the analysis popover is presented over the camera.
    enum SheetMode: Equatable {
        case hidden
        case minimized
        case expanded
    }

    @Published var phase: Phase = .live
    @Published var sheetMode: SheetMode = .hidden
    @Published var capturedImage: UIImage?
    @Published var analysisText: String = ""
    @Published var selectedModel: AIModel?
    @Published var showModelPicker = false
    @Published var errorMessage: String?

    private let catalog: ModelCatalog
    private weak var state: AppState?
    private var analysisTask: Task<Void, Never>?

    var isThinking: Bool {
        if case .analyzing = phase { return true }
        return false
    }

    var canCapture: Bool {
        switch phase {
        case .live, .result, .failed: return true
        case .capturing, .analyzing: return false
        }
    }

    init(catalog: ModelCatalog = ModelCatalog()) {
        self.catalog = catalog
    }

    func bind(state: AppState) {
        self.state = state
        // Keep selection vision-capable: replace text-only picks when a VLM is available.
        let preferred = VisionCapability.preferredVisionModel(
            from: state.allModels,
            current: selectedModel ?? state.selectedModel,
            isVision: { state.modelSupportsVision($0) }
        )
        if let preferred {
            let currentIsVision = selectedModel.map { state.modelSupportsVision($0) } ?? false
            let currentStillListed = selectedModel.map { current in
                state.allModels.contains(where: { $0.id == current.id })
            } ?? false
            if selectedModel == nil || !currentIsVision || !currentStillListed {
                selectedModel = preferred
            }
        } else if let current = selectedModel,
                  !state.allModels.contains(where: { $0.id == current.id }) {
            selectedModel = nil
        }
    }

    func visionModels(from state: AppState) -> [AIModel] {
        state.allModels.filter { state.modelSupportsVision($0) }
    }

    /// Encode a captured frame and run the selected vision model.
    func analyze(image: UIImage) {
        analysisTask?.cancel()
        // Downscale immediately so the full sensor buffer is not retained
        // alongside the VLM weights for the whole generation.
        let forDisplay = Self.displayImage(from: image)
        let forModel = Self.scaledImage(image, maxDimension: 1024)
        capturedImage = forDisplay
        analysisText = ""
        errorMessage = nil
        phase = .analyzing
        sheetMode = .expanded

        analysisTask = Task { [weak self] in
            guard let self else { return }
            do {
                let reply = try await self.runAnalysis(image: forModel)
                guard !Task.isCancelled else { return }
                self.analysisText = reply
                self.phase = .result
                if self.sheetMode == .hidden {
                    self.sheetMode = .expanded
                }
            } catch is CancellationError {
                // Retake / dismiss — leave UI as-is for the new state.
            } catch {
                guard !Task.isCancelled else { return }
                let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self.errorMessage = msg
                self.analysisText = ""
                self.phase = .failed(msg)
                self.sheetMode = .expanded
            }
        }
    }

    func retake() {
        analysisTask?.cancel()
        analysisTask = nil
        capturedImage = nil
        analysisText = ""
        errorMessage = nil
        phase = .live
        sheetMode = .hidden
    }

    func toggleSheet() {
        switch sheetMode {
        case .hidden:
            if phase == .result || isThinking || analysisText.isEmpty == false {
                sheetMode = .expanded
            }
        case .minimized:
            sheetMode = .expanded
        case .expanded:
            sheetMode = .minimized
        }
    }

    func setSheetMinimized() {
        guard sheetMode != .hidden else { return }
        sheetMode = .minimized
    }

    func setSheetExpanded() {
        guard sheetMode != .hidden else { return }
        sheetMode = .expanded
    }

    // MARK: - Private

    private func runAnalysis(image: UIImage) async throws -> String {
        guard let state else {
            throw ProviderError.transport("App state is not ready.")
        }
        guard let model = selectedModel ?? VisionCapability.preferredVisionModel(
            from: state.allModels,
            current: state.selectedModel,
            isVision: { state.modelSupportsVision($0) }
        ) else {
            throw ProviderError.transport(
                "No vision model available. Add an API key for OpenAI, Anthropic, OpenRouter, or xAI in Settings, or mark a custom provider as vision-capable."
            )
        }
        selectedModel = model

        if model.provider == .localMetal {
            // Always pin the *vision* model as the selected Metal model before
            // load — previously we loaded whatever chat had selected first,
            // briefly double-resident and often the wrong weights.
            if state.selectedModel?.id != model.id {
                state.selectedModel = model
            }
            await state.ensureSelectedLocalMetalLoaded()
            if let loadError = state.localMetalLoadError, !loadError.isEmpty {
                throw ProviderError.transport(loadError)
            }
        }

        let key = state.resolvedAPIKey(for: model.provider)
        if model.provider.requiresAPIKey, key.isEmpty {
            throw ProviderError.missingKey
        }

        // On-device VLMs are far more memory-sensitive than cloud APIs.
        let maxDim: CGFloat = model.provider == .localMetal ? 1024 : 1600
        let quality: CGFloat = model.provider == .localMetal ? 0.65 : 0.72
        let jpeg = try Self.jpegData(from: image, maxDimension: maxDim, quality: quality)
        let base64 = jpeg.base64EncodedString()
        let attachment = ProviderChatMessage.ImageAttachment(
            mimeType: "image/jpeg",
            base64Data: base64
        )

        let prompt = """
        Analyze this photo in clear, useful detail. Cover:
        - What the scene or subject is
        - Notable objects, people, or text (transcribe readable text)
        - Layout, materials, colors, and condition when relevant
        - Any practical insights or risks worth calling out

        Be concise but thorough. Use short sections or bullets when helpful.
        """

        let turns: [ProviderChatMessage] = [
            ProviderChatMessage(role: .user, content: prompt, images: [attachment]),
        ]

        let baseURL = state.baseURL(for: model.provider)
        let style = state.apiStyle(for: model.provider)
        if case .custom = model.provider, baseURL == nil {
            throw ProviderError.transport("Custom provider is missing a base URL. Edit it in Settings.")
        }

        try Task.checkCancellation()

        let reply: String
        do {
            reply = try await catalog.provider(
                model.provider,
                customBaseURL: baseURL,
                style: style
            ).chat(
                model: model.modelID,
                apiKey: key,
                messages: turns,
                // Cap on-device vision at medium — long high-effort generations
                // balloon the KV cache and jetsam mid-reply on phones.
                effort: model.provider == .localMetal
                    ? (state.effort == .high ? .medium : state.effort)
                    : state.effort
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Surface Metal/VLM failures as a clean error instead of an uncaught abort.
            let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            throw ProviderError.transport(
                model.provider == .localMetal
                    ? "On-device vision failed: \(msg)"
                    : msg
            )
        }

        try Task.checkCancellation()

        let parsed = ThinkingExtractor.extract(from: reply)
        var text = parsed.content.trimmingCharacters(in: .whitespacesAndNewlines)
        // Some VLMs (Gemma-family) return only thinking tags for short turns —
        // fall back so we don't treat a real answer as empty.
        if text.isEmpty, let thinking = parsed.thinking?.trimmingCharacters(in: .whitespacesAndNewlines),
           !thinking.isEmpty {
            text = thinking
        }
        guard !text.isEmpty else {
            throw ProviderError.transport("The model returned an empty analysis.")
        }
        return text
    }

    /// Freeze-frame for the UI — capped so we don't keep a 12MP buffer around.
    private static func displayImage(from image: UIImage, maxDimension: CGFloat = 1440) -> UIImage {
        scaledImage(image, maxDimension: maxDimension)
    }

    /// Downscale + JPEG-compress so multimodal payloads stay under typical API limits.
    /// `image` is expected to already be roughly the right size; `maxDimension`
    /// is a second safety clamp.
    private static func jpegData(
        from image: UIImage,
        maxDimension: CGFloat = 1600,
        quality: CGFloat = 0.72
    ) throws -> Data {
        let scaled = scaledImage(image, maxDimension: maxDimension)
        guard let data = scaled.jpegData(compressionQuality: quality), !data.isEmpty else {
            throw ProviderError.transport("Could not encode the photo for analysis.")
        }
        return data
    }

    private static func scaledImage(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = image.size
        let longest = max(size.width, size.height)
        guard longest > maxDimension, longest > 0 else { return image }
        let scale = maxDimension / longest
        let newSize = CGSize(width: floor(size.width * scale), height: floor(size.height * scale))
        guard newSize.width >= 1, newSize.height >= 1 else { return image }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}
