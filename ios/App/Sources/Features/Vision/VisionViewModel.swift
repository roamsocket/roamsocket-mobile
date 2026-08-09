import Foundation
import UIKit
import AnyProvCore

/// One visible turn in the Vision analysis thread (follow-ups after the first look).
struct VisionChatTurn: Identifiable, Equatable {
    enum Role: Equatable {
        case user
        case assistant
    }

    let id: UUID
    let role: Role
    var text: String
    var isError: Bool

    init(id: UUID = UUID(), role: Role, text: String, isError: Bool = false) {
        self.id = id
        self.role = role
        self.text = text
        self.isError = isError
    }
}

/// Drives capture → multimodal analysis → follow-up chat for Vision mode.
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
        /// Default mid-height card after capture / analysis.
        case expanded
        /// Pulled up nearly full-screen so long analysis is readable and scrollable.
        case full
    }

    @Published var phase: Phase = .live
    @Published var sheetMode: SheetMode = .hidden
    @Published var capturedImage: UIImage?
    /// Latest assistant text (first analysis or last follow-up) for pill previews.
    @Published var analysisText: String = ""
    /// Visible thread: first assistant analysis, then user/assistant follow-ups.
    @Published var turns: [VisionChatTurn] = []
    @Published var draftText: String = ""
    @Published var selectedModel: AIModel?
    @Published var showModelPicker = false
    @Published var showPromptLibrary = false
    @Published var errorMessage: String?
    /// Follow-up reply in flight (after the first analysis).
    @Published private(set) var isReplying: Bool = false

    // MARK: Capture prompt (optional, before shutter)

    /// Freeform / preset text used for the next capture. Empty → default analysis.
    @Published var capturePrompt: String = ""
    /// Active preset chip; `nil` when the field was edited freely.
    @Published var selectedPresetID: UUID? = VisionPromptStore.defaultPresetID
    /// Prompt actually sent with the frozen photo (for the thread header).
    @Published private(set) var lastUsedPrompt: String = ""
    @Published private(set) var lastUsedPresetTitle: String?

    let promptStore: VisionPromptStore

    private let catalog: ModelCatalog
    private weak var state: AppState?
    private var analysisTask: Task<Void, Never>?

    /// Provider-facing history (includes the hidden first analysis prompt + image).
    private var providerMessages: [ProviderChatMessage] = []
    /// JPEG kept for the session so retakes clear memory and follow-ups stay grounded.
    private var sessionImageAttachment: ProviderChatMessage.ImageAttachment?

    /// Built-in fallback when the user leaves the capture prompt empty.
    /// Lead with the takeaway so the user sees the useful result without scrolling.
    static let defaultAnalysisPrompt = """
    Analyze this photo for the user. Structure your reply exactly like this:

    ## Answer
    Start with the key takeaway, result, identification, or recommendation in 1–3 short sentences (or a tight bullet list). Put what the user needs first — not a scenic description.

    ## Details
    Brief supporting facts: notable objects, readable text (transcribe if useful), layout, materials, condition, or risks.

    ## Notes (optional)
    Uncertainty, missing context, or follow-up suggestions only if helpful.

    Be concise. Do not open with “This photo shows…” or a long scene description before the answer.
    """

    var presets: [VisionPromptPreset] {
        promptStore.presets
    }

    var trimmedCapturePrompt: String {
        capturePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when the user typed or picked a non-empty task prompt.
    var hasCustomCapturePrompt: Bool {
        !trimmedCapturePrompt.isEmpty
    }

    var canSaveCapturePromptAsPreset: Bool {
        hasCustomCapturePrompt
    }

    var isThinking: Bool {
        if case .analyzing = phase { return true }
        return isReplying
    }

    /// Whether the follow-up composer should be shown.
    var canChat: Bool {
        switch phase {
        case .result:
            return capturedImage != nil
        case .failed:
            // Allow questions only after at least one successful analysis turn.
            return !turns.isEmpty && capturedImage != nil
        default:
            return false
        }
    }

    var canSendFollowUp: Bool {
        canChat
            && !isThinking
            && !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canCapture: Bool {
        switch phase {
        case .live, .result, .failed: return !isReplying
        case .capturing, .analyzing: return false
        }
    }

    init(
        catalog: ModelCatalog = ModelCatalog(),
        promptStore: VisionPromptStore = .shared
    ) {
        self.catalog = catalog
        self.promptStore = promptStore
    }

    // MARK: - Capture prompts / presets

    func selectPreset(_ preset: VisionPromptPreset) {
        selectedPresetID = preset.id
        capturePrompt = preset.prompt
    }

    func clearCapturePrompt() {
        selectedPresetID = VisionPromptStore.defaultPresetID
        capturePrompt = ""
    }

    /// Keep chip selection in sync when the user edits the field.
    func capturePromptEdited() {
        let trimmed = trimmedCapturePrompt
        if let match = promptStore.presets.first(where: {
            $0.prompt.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed
        }) {
            selectedPresetID = match.id
        } else if trimmed.isEmpty {
            selectedPresetID = VisionPromptStore.defaultPresetID
        } else {
            selectedPresetID = nil
        }
    }

    @discardableResult
    func saveCapturePromptAsPreset(title: String) -> VisionPromptPreset? {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = trimmedCapturePrompt
        guard !name.isEmpty, !body.isEmpty else { return nil }
        let preset = promptStore.add(title: name, prompt: body)
        selectedPresetID = preset.id
        return preset
    }

    func deletePreset(id: UUID) {
        promptStore.delete(id: id)
        if selectedPresetID == id {
            clearCapturePrompt()
        }
    }

    func updatePreset(_ preset: VisionPromptPreset) {
        promptStore.update(preset)
        if selectedPresetID == preset.id {
            capturePrompt = preset.prompt
        }
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
        turns = []
        draftText = ""
        providerMessages = []
        sessionImageAttachment = nil
        isReplying = false
        phase = .analyzing
        sheetMode = .expanded

        // Snapshot the prompt at shutter time so editing the field mid-flight
        // does not change what this analysis was asked to do.
        let promptSnapshot = resolvedProviderPrompt()
        let displayPrompt = trimmedCapturePrompt
        let presetTitle = selectedPresetID.flatMap { id in
            promptStore.presets.first(where: { $0.id == id })?.title
        }
        lastUsedPrompt = displayPrompt.isEmpty ? "" : displayPrompt
        lastUsedPresetTitle = displayPrompt.isEmpty ? nil : presetTitle

        let livePreview = displayPrompt.isEmpty ? "Analyzing image" : displayPrompt
        AIThinkingActivityManager.shared.thinkingDidStart(kind: .vision, prompt: livePreview)

        analysisTask = Task { [weak self] in
            guard let self else { return }
            defer { AIThinkingActivityManager.shared.thinkingDidEnd() }
            do {
                let reply = try await self.runInitialAnalysis(
                    image: forModel,
                    providerPrompt: promptSnapshot
                )
                guard !Task.isCancelled else { return }
                self.analysisText = reply
                // Initial capture/system prompt is a compact header chip (popover
                // for full text) — never a thread bubble — so the answer leads.
                self.turns = [VisionChatTurn(role: .assistant, text: reply)]
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
                self.turns = []
                self.providerMessages = []
                self.sessionImageAttachment = nil
                self.phase = .failed(msg)
                self.sheetMode = .expanded
            }
        }
    }

    /// Ask a follow-up about the frozen photo and prior analysis.
    func sendFollowUp() {
        let text = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSendFollowUp, !text.isEmpty else { return }
        guard !providerMessages.isEmpty else { return }

        draftText = ""
        let userTurn = VisionChatTurn(role: .user, text: text)
        turns.append(userTurn)
        providerMessages.append(ProviderChatMessage(role: .user, content: text))
        isReplying = true
        // Give the thread room while the model answers.
        if sheetMode == .minimized || sheetMode == .expanded {
            sheetMode = .full
        }
        phase = .result

        AIThinkingActivityManager.shared.thinkingDidStart(kind: .vision, prompt: text)

        analysisTask?.cancel()
        analysisTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.isReplying = false
                AIThinkingActivityManager.shared.thinkingDidEnd()
            }
            do {
                let reply = try await self.runChat(messages: self.providerMessages)
                guard !Task.isCancelled else { return }
                self.providerMessages.append(ProviderChatMessage(role: .assistant, content: reply))
                self.turns.append(VisionChatTurn(role: .assistant, text: reply))
                self.analysisText = reply
                self.phase = .result
            } catch is CancellationError {
                // Retake / dismiss.
            } catch {
                guard !Task.isCancelled else { return }
                let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                // Drop the failed user turn from the provider history so a retry can resend.
                if self.providerMessages.last?.role == .user {
                    self.providerMessages.removeLast()
                }
                self.turns.append(VisionChatTurn(role: .assistant, text: msg, isError: true))
                self.errorMessage = msg
                self.phase = .result
            }
        }
    }

    func retake() {
        analysisTask?.cancel()
        analysisTask = nil
        AIThinkingActivityManager.shared.thinkingDidEnd()
        capturedImage = nil
        analysisText = ""
        errorMessage = nil
        turns = []
        draftText = ""
        lastUsedPrompt = ""
        lastUsedPresetTitle = nil
        providerMessages = []
        sessionImageAttachment = nil
        isReplying = false
        phase = .live
        sheetMode = .hidden
        // Keep capturePrompt / selectedPreset so the same task can re-run.
    }

    /// Prompt string sent to the model for the next capture.
    func resolvedProviderPrompt() -> String {
        let custom = trimmedCapturePrompt
        if custom.isEmpty {
            return Self.defaultAnalysisPrompt
        }
        return custom
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
            sheetMode = .full
        case .full:
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

    func setSheetFull() {
        guard sheetMode != .hidden else { return }
        sheetMode = .full
    }

    // MARK: - Private

    private func runInitialAnalysis(image: UIImage, providerPrompt: String) async throws -> String {
        let model = try await resolveModel()
        let attachment = try makeAttachment(from: image, model: model)
        sessionImageAttachment = attachment

        let turns: [ProviderChatMessage] = [
            ProviderChatMessage(role: .user, content: providerPrompt, images: [attachment]),
        ]
        let reply = try await runChat(messages: turns)
        // Seed multi-turn history: image+prompt, then assistant analysis.
        providerMessages = turns + [ProviderChatMessage(role: .assistant, content: reply)]
        return reply
    }

    private func runChat(messages: [ProviderChatMessage]) async throws -> String {
        guard let state else {
            throw ProviderError.transport("App state is not ready.")
        }
        let model = try await resolveModel()

        let key = state.resolvedAPIKey(for: model.provider)
        if model.provider.requiresAPIKey, key.isEmpty {
            throw ProviderError.missingKey
        }

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
                messages: messages,
                // Cap on-device vision at medium — long high-effort generations
                // balloon the KV cache and jetsam mid-reply on phones.
                effort: model.provider == .localMetal
                    ? (state.effort == .high ? .medium : state.effort)
                    : state.effort
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
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

    private func resolveModel() async throws -> AIModel {
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
        return model
    }

    private func makeAttachment(from image: UIImage, model: AIModel) throws -> ProviderChatMessage.ImageAttachment {
        // On-device VLMs are far more memory-sensitive than cloud APIs.
        let maxDim: CGFloat = model.provider == .localMetal ? 1024 : 1600
        let quality: CGFloat = model.provider == .localMetal ? 0.65 : 0.72
        let jpeg = try Self.jpegData(from: image, maxDimension: maxDim, quality: quality)
        return ProviderChatMessage.ImageAttachment(
            mimeType: "image/jpeg",
            base64Data: jpeg.base64EncodedString()
        )
    }

    /// Freeze-frame for the UI — capped so we don't keep a 12MP buffer around.
    private static func displayImage(from image: UIImage, maxDimension: CGFloat = 1440) -> UIImage {
        scaledImage(image, maxDimension: maxDimension)
    }

    /// Downscale + JPEG-compress so multimodal payloads stay under typical API limits.
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
