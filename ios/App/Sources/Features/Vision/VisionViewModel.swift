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
    /// Grey tool-status lines (web search / research) for this assistant turn.
    var toolCalls: [ToolCall]?

    init(
        id: UUID = UUID(),
        role: Role,
        text: String,
        isError: Bool = false,
        toolCalls: [ToolCall]? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.isError = isError
        self.toolCalls = toolCalls
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

    // MARK: Tools (client-side; same stack as Chat)

    /// DuckDuckGo web search. On capture: query is derived from the photo (never the
    /// system/capture instruction). On follow-ups: query is the user's question.
    @Published var webSearchEnabled: Bool = true
    /// Multi-query research + Wikipedia. Implies web search when enabled.
    @Published var researchEnabled: Bool = false
    /// Live tool status while search runs (also mirrored onto the assistant turn).
    @Published private(set) var activeToolCalls: [ToolCall] = []

    // MARK: Capture prompt (optional, before shutter)

    /// Freeform / preset text used for the next capture. Empty → default analysis.
    @Published var capturePrompt: String = ""
    /// Active preset chip; `nil` when the field was edited freely.
    @Published var selectedPresetID: UUID? = VisionPromptStore.defaultPresetID
    /// Prompt actually sent with the frozen photo (for the thread header).
    @Published private(set) var lastUsedPrompt: String = ""
    @Published private(set) var lastUsedPresetTitle: String?
    /// Sheet to re-run analysis on the frozen photo with a different task prompt.
    @Published var showReanalyzePrompt = false

    let promptStore: VisionPromptStore

    private let catalog: ModelCatalog
    private let webSearchService = WebSearchService()
    private weak var state: AppState?
    private var analysisTask: Task<Void, Never>?

    /// Provider-facing history (includes the hidden first analysis prompt + image).
    private var providerMessages: [ProviderChatMessage] = []
    /// JPEG kept for the session so retakes clear memory and follow-ups stay grounded.
    private var sessionImageAttachment: ProviderChatMessage.ImageAttachment?
    /// Full-frame source used for crop → re-analyze (display-scale, orientation-normalized).
    private var analysisSourceImage: UIImage?
    /// Last crop applied for the model payload (normalized image space). Full frame = unit rect.
    private var lastCropNormalized: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    /// Prompt snapshot for the current frozen photo (reused when re-cropping).
    private var lastProviderPrompt: String = ""

    /// Web search / research are client-side and work for any chat-capable vision model.
    var supportsWebTools: Bool { true }

    /// Built-in fallback when the user leaves the capture prompt empty.
    /// Lead with the takeaway so the user sees the useful result without scrolling.
    static let defaultAnalysisPrompt = """
    Analyze this photo for the user.

    **If this is a quiz, test, worksheet, or homework** (true/false, multiple choice, short answer, or several discrete questions), use this layout instead of the general one:

    1. One-line intro naming the question type and count (e.g. “Here are the answers to the four true/false questions on your screen.”).
    2. For each question:

    ## Question N

    - **Text:** Restate the full question (and options if multiple choice).
    - **Answer:** Bold the correct choice, True/False, number, or short phrase.
    - **Reason:** One or two concise sentences of explanation.

    Separate questions with `---`. Do not open with a photo description.

    **Otherwise** (general photos), structure your reply like this:

    ## Answer
    Start with the key takeaway, result, identification, or recommendation in 1–3 short sentences (or a tight bullet list). Put what the user needs first — not a scenic description.

    ## Details
    Brief supporting facts: notable objects, readable text (transcribe if useful), layout, materials, condition, or risks.

    ## Notes (optional)
    Uncertainty, missing context, or follow-up suggestions only if helpful.

    Be concise. Never open with “This photo shows…” or a long scene description before the answer.
    """

    var presets: [VisionPromptPreset] {
        promptStore.presets
    }

    var trimmedCapturePrompt: String {
        capturePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Full analysis text for copy / artifact export (all successful assistant turns).
    var exportableAnalysisText: String {
        let answers = turns
            .filter { $0.role == .assistant && !$0.isError }
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !answers.isEmpty {
            return answers.joined(separator: "\n\n---\n\n")
        }
        return analysisText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var canExportAnalysis: Bool {
        !exportableAnalysisText.isEmpty && !isThinking
    }

    /// True when the user typed or picked a non-empty task prompt.
    var hasCustomCapturePrompt: Bool {
        !trimmedCapturePrompt.isEmpty
    }

    var canSaveCapturePromptAsPreset: Bool {
        hasCustomCapturePrompt
    }

    var isThinking: Bool {
        switch phase {
        case .capturing, .analyzing:
            return true
        default:
            return isReplying
        }
    }

    /// Shutter has fired — freeze frame + analysis card (preview freeze or still).
    var hasFrozenCapture: Bool {
        phase != .live
    }

    /// Keep the capture session mounted while live and while the still is developing.
    var showsCameraSession: Bool {
        switch phase {
        case .live, .capturing:
            return true
        default:
            return false
        }
    }

    /// Pause the live preview connection so the last frame freezes immediately.
    var freezesCameraPreview: Bool {
        phase == .capturing
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

    /// Frozen photo available to re-run with a new system/task prompt.
    var canReanalyze: Bool {
        guard !isThinking, (analysisSourceImage ?? capturedImage) != nil else { return false }
        switch phase {
        case .result, .failed:
            return true
        default:
            return false
        }
    }

    init(
        catalog: ModelCatalog = ModelCatalog(),
        promptStore: VisionPromptStore? = nil
    ) {
        self.catalog = catalog
        // Resolve on MainActor (class is @MainActor); default args are nonisolated.
        self.promptStore = promptStore ?? VisionPromptStore.shared
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

    /// Call as soon as the shutter fires (before the still finishes developing).
    /// Freezes the preview path and opens the analyzing card immediately.
    func beginCapture() {
        guard canCapture else { return }
        analysisTask?.cancel()
        analysisTask = nil
        AIThinkingActivityManager.shared.thinkingDidEnd()

        analysisText = ""
        errorMessage = nil
        turns = []
        draftText = ""
        providerMessages = []
        sessionImageAttachment = nil
        // Keep any previous still until the new one lands only when retaking from
        // result/failed — from live, capturedImage is already nil.
        if phase == .live {
            capturedImage = nil
            analysisSourceImage = nil
            lastCropNormalized = CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        activeToolCalls = []
        isReplying = false

        // Snapshot prompt/preset at shutter so the sheet header is correct while
        // the sensor still is still developing.
        let displayPrompt = trimmedCapturePrompt
        let presetTitle = selectedPresetID.flatMap { id in
            promptStore.presets.first(where: { $0.id == id })?.title
        }
        lastUsedPrompt = displayPrompt.isEmpty ? "" : displayPrompt
        lastUsedPresetTitle = displayPrompt.isEmpty ? nil : presetTitle
        lastProviderPrompt = resolvedProviderPrompt()

        phase = .capturing
        sheetMode = .expanded
        AIThinkingActivityManager.shared.thinkingDidStart(
            kind: .vision,
            prompt: displayPrompt.isEmpty ? "Analyzing image" : displayPrompt
        )
    }

    /// Capture failed before a still arrived — return to the live viewfinder.
    func abortCapture(message: String? = nil) {
        guard phase == .capturing else { return }
        analysisTask?.cancel()
        analysisTask = nil
        AIThinkingActivityManager.shared.thinkingDidEnd()
        capturedImage = nil
        analysisSourceImage = nil
        lastCropNormalized = CGRect(x: 0, y: 0, width: 1, height: 1)
        lastProviderPrompt = ""
        analysisText = ""
        errorMessage = message
        turns = []
        draftText = ""
        lastUsedPrompt = ""
        lastUsedPresetTitle = nil
        providerMessages = []
        sessionImageAttachment = nil
        activeToolCalls = []
        isReplying = false
        phase = .live
        sheetMode = .hidden
    }

    /// Encode a captured frame and run the selected vision model.
    /// Prefer calling `beginCapture()` first so the UI freezes on shutter.
    func analyze(image: UIImage) {
        // Ignore stills that finish after Retake restored the live viewfinder.
        guard phase == .capturing || phase == .analyzing else { return }

        analysisTask?.cancel()

        // Publish analyzing UI *before* any downscale work so the sheet and
        // freeze path never wait on JPEG/raster work.
        analysisText = ""
        errorMessage = nil
        turns = []
        draftText = ""
        providerMessages = []
        sessionImageAttachment = nil
        activeToolCalls = []
        isReplying = false
        lastCropNormalized = CGRect(x: 0, y: 0, width: 1, height: 1)
        phase = .analyzing
        sheetMode = .expanded

        // Show the still immediately (even full-res) so freeze doesn't wait on
        // downscale; replace with the capped display buffer next.
        capturedImage = image

        let promptSnapshot = lastProviderPrompt.isEmpty ? resolvedProviderPrompt() : lastProviderPrompt
        lastProviderPrompt = promptSnapshot
        let displayPrompt = lastUsedPrompt
        let livePreview = displayPrompt.isEmpty ? "Analyzing image" : displayPrompt

        // Downscale off the synchronous entry so freeze + analyzing chrome paint
        // on the same frame as phase flip. Then hand off to the shared task runner.
        analysisTask = Task { [weak self] in
            guard let self else { return }
            let forDisplay = Self.displayImage(from: image)
            let forModel = Self.scaledImage(forDisplay, maxDimension: 1024)
            guard !Task.isCancelled else {
                AIThinkingActivityManager.shared.thinkingDidEnd()
                return
            }
            self.analysisSourceImage = forDisplay
            self.capturedImage = forDisplay
            // Replaces this task reference with the network/VLM work task.
            self.startAnalysisTask(
                image: forModel,
                providerPrompt: promptSnapshot,
                livePreview: livePreview
            )
        }
    }

    /// User finished resizing the Lens-style crop; re-run analysis on that region.
    /// No-op when the crop is effectively unchanged (avoids thrashing on tiny tweaks).
    func applyCropAndReanalyze(normalizedRect: CGRect) {
        guard let source = analysisSourceImage ?? capturedImage else { return }
        let next = Self.clampedNormalizedCrop(normalizedRect)
        // Skip if crop barely moved (corner handle release without real change).
        if Self.cropsApproximatelyEqual(lastCropNormalized, next) { return }
        lastCropNormalized = next

        let cropped = Self.croppedImage(source, normalized: next)
        let forModel = Self.scaledImage(cropped, maxDimension: 1024)
        let prompt = lastProviderPrompt.isEmpty ? resolvedProviderPrompt() : lastProviderPrompt

        analysisTask?.cancel()
        analysisText = ""
        errorMessage = nil
        turns = []
        draftText = ""
        providerMessages = []
        sessionImageAttachment = nil
        activeToolCalls = []
        isReplying = false
        phase = .analyzing
        if sheetMode == .hidden || sheetMode == .minimized {
            sheetMode = .expanded
        }

        let livePreview = lastUsedPrompt.isEmpty ? "Analyzing selection" : lastUsedPrompt
        startAnalysisTask(
            image: forModel,
            providerPrompt: prompt,
            livePreview: livePreview
        )
    }

    /// Open the re-analyze editor prefilled with the last (or current) task prompt.
    func presentReanalyzePrompt() {
        guard canReanalyze else { return }
        // Prefill the editor with what was last sent for this still so the user
        // can tweak it rather than starting from a blank field.
        if capturePrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !lastUsedPrompt.isEmpty {
            capturePrompt = lastUsedPrompt
            capturePromptEdited()
        }
        showReanalyzePrompt = true
    }

    /// Re-run analysis on the frozen photo using the current capture prompt.
    func reanalyzeWithCurrentPrompt() {
        guard canReanalyze else { return }
        guard let source = analysisSourceImage ?? capturedImage else { return }

        showReanalyzePrompt = false

        let promptSnapshot = resolvedProviderPrompt()
        lastProviderPrompt = promptSnapshot
        let displayPrompt = trimmedCapturePrompt
        let presetTitle = selectedPresetID.flatMap { id in
            promptStore.presets.first(where: { $0.id == id })?.title
        }
        lastUsedPrompt = displayPrompt.isEmpty ? "" : displayPrompt
        lastUsedPresetTitle = displayPrompt.isEmpty ? nil : presetTitle

        let forModel: UIImage = {
            let cropped = Self.croppedImage(source, normalized: lastCropNormalized)
            return Self.scaledImage(cropped, maxDimension: 1024)
        }()

        analysisTask?.cancel()
        analysisText = ""
        errorMessage = nil
        turns = []
        draftText = ""
        providerMessages = []
        sessionImageAttachment = nil
        activeToolCalls = []
        isReplying = false
        phase = .analyzing
        if sheetMode == .hidden || sheetMode == .minimized {
            sheetMode = .expanded
        }

        let livePreview = displayPrompt.isEmpty ? "Re-analyzing image" : displayPrompt
        startAnalysisTask(
            image: forModel,
            providerPrompt: promptSnapshot,
            livePreview: livePreview
        )
    }

    /// Re-run analysis on the frozen photo after a failure (e.g. the network
    /// dropped while the app was backgrounded). Keeps the same prompt that was
    /// used for the failed attempt.
    func retryAnalysis() {
        guard canReanalyze else { return }
        reanalyzeWithCurrentPrompt()
    }

    /// Ask a follow-up about the frozen photo and prior analysis.
    func sendFollowUp() {
        let text = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSendFollowUp, !text.isEmpty else { return }
        guard !providerMessages.isEmpty else { return }

        draftText = ""
        let userTurn = VisionChatTurn(role: .user, text: text)
        turns.append(userTurn)
        // User turn is appended after optional search context is injected.
        isReplying = true
        activeToolCalls = []
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
                self.activeToolCalls = []
                AIThinkingActivityManager.shared.thinkingDidEnd()
            }
            do {
                var messages = self.providerMessages
                let tools = try await self.runOptionalWebTools(query: text)
                if let context = tools.promptBlock, !context.isEmpty {
                    messages.append(ProviderChatMessage(role: .system, content: context))
                }
                messages.append(ProviderChatMessage(role: .user, content: text))
                self.providerMessages = messages

                let reply = try await self.runChat(messages: messages, webSearchQuery: tools.nativeWebSearchQuery)
                guard !Task.isCancelled else { return }
                self.providerMessages.append(ProviderChatMessage(role: .assistant, content: reply))
                self.turns.append(
                    VisionChatTurn(role: .assistant, text: reply, toolCalls: tools.calls.isEmpty ? nil : tools.calls)
                )
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
                // Also drop a trailing system search block if we injected one.
                if self.providerMessages.last?.role == .system {
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
        showReanalyzePrompt = false
        capturedImage = nil
        analysisSourceImage = nil
        lastCropNormalized = CGRect(x: 0, y: 0, width: 1, height: 1)
        lastProviderPrompt = ""
        analysisText = ""
        errorMessage = nil
        turns = []
        draftText = ""
        lastUsedPrompt = ""
        lastUsedPresetTitle = nil
        providerMessages = []
        sessionImageAttachment = nil
        activeToolCalls = []
        isReplying = false
        phase = .live
        sheetMode = .hidden
        // Keep capturePrompt / selectedPreset / web tool toggles so the same task can re-run.
    }

    /// Research on implies web search (matches Chat Add-to-chat behavior).
    func setResearchEnabled(_ on: Bool) {
        researchEnabled = on
        if on { webSearchEnabled = true }
    }

    func setWebSearchEnabled(_ on: Bool) {
        webSearchEnabled = on
        if !on { researchEnabled = false }
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

    /// Ask the VLM for a short SERP query grounded in image content only —
    /// never the capture/system instruction.
    private static let imageSearchQueryPrompt = """
    Look at this photo and write ONE web search query (max 12 words) that would help identify or research what is actually visible: main subject, product, brand, landmark, plant, animal, model number, place name, or readable text.

    Rules:
    - Search for content IN the image only — not analysis instructions or meta commentary.
    - Prefer specific names, brands, products, species, places, or short quoted text from the photo.
    - If nothing is usefully searchable (heavy blur, pure UI chrome, empty scene), reply with exactly: NONE
    - Reply with ONLY the query text or NONE. No quotes, labels, or explanation.
    """

    private func startAnalysisTask(
        image: UIImage,
        providerPrompt: String,
        livePreview: String
    ) {
        AIThinkingActivityManager.shared.thinkingDidStart(kind: .vision, prompt: livePreview)

        analysisTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.activeToolCalls = []
                AIThinkingActivityManager.shared.thinkingDidEnd()
            }
            do {
                let model = try await self.resolveModel()
                let attachment = try self.makeAttachment(from: image, model: model)

                // Capture-time search is image-grounded: extract a query from the
                // photo, then SERP — never use the system/capture prompt as the query.
                let imageQuery = try await self.extractImageSearchQuery(attachment: attachment)
                let tools = try await self.runOptionalWebTools(query: imageQuery)
                let reply = try await self.runInitialAnalysis(
                    attachment: attachment,
                    providerPrompt: providerPrompt,
                    searchContext: tools.promptBlock,
                    webSearchQuery: tools.nativeWebSearchQuery
                )
                guard !Task.isCancelled else { return }
                self.analysisText = reply
                // Initial capture/system prompt is a compact header chip (popover
                // for full text) — never a thread bubble — so the answer leads.
                self.turns = [
                    VisionChatTurn(
                        role: .assistant,
                        text: reply,
                        toolCalls: tools.calls.isEmpty ? nil : tools.calls
                    ),
                ]
                self.phase = .result
                if self.sheetMode == .hidden {
                    self.sheetMode = .expanded
                }
            } catch is CancellationError {
                // Retake / dismiss / re-crop — leave UI as-is for the new state.
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

    /// Lightweight VLM pass → short SERP query from photo content. Returns nil to skip search.
    private func extractImageSearchQuery(
        attachment: ProviderChatMessage.ImageAttachment
    ) async throws -> String? {
        guard supportsWebTools, researchEnabled || webSearchEnabled else { return nil }

        let scanID = UUID()
        var scan = ToolCall(
            id: scanID,
            name: "image_scan",
            summary: "Finding searchable details in the photo…",
            status: .running
        )
        activeToolCalls = [scan]
        AIThinkingActivityManager.shared.thinkingDidUpdate(status: scan.summary)

        do {
            let raw = try await runChat(
                messages: [
                    ProviderChatMessage(
                        role: .user,
                        content: Self.imageSearchQueryPrompt,
                        images: [attachment]
                    ),
                ]
            )
            try Task.checkCancellation()
            let query = Self.parseImageSearchQuery(raw)
            if let query {
                scan.summary = "Search terms from photo: “\(Self.truncateForUI(query, 72))”"
                scan.detail = query
                scan.status = .completed
            } else {
                scan.summary = "No web search needed for this photo"
                scan.status = .completed
            }
            activeToolCalls = [scan]
            return query
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Soft-fail: continue without image-grounded search.
            scan.summary = "Could not derive search terms from photo"
            scan.detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            scan.status = .failed(scan.detail ?? "failed")
            activeToolCalls = [scan]
            return nil
        }
    }

    /// Parse a one-line SERP query from the lightweight vision reply.
    private static func parseImageSearchQuery(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip common wrappers models still emit despite instructions.
        if text.hasPrefix("```") {
            text = text
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let firstLine = text.split(whereSeparator: \.isNewline).first {
            text = String(firstLine).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if (text.hasPrefix("\"") && text.hasSuffix("\""))
            || (text.hasPrefix("'") && text.hasSuffix("'")) {
            text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let upper = text.uppercased()
        if upper.isEmpty || upper == "NONE" || upper == "N/A" || upper == "NA" {
            return nil
        }
        // Reject if the model echoed a long instruction instead of a query.
        if text.count > 120 || text.contains("\n") {
            let clipped = String(text.prefix(120)).trimmingCharacters(in: .whitespacesAndNewlines)
            return clipped.isEmpty ? nil : clipped
        }
        return text
    }

    private static func truncateForUI(_ text: String, _ max: Int) -> String {
        guard text.count > max else { return text }
        return String(text.prefix(max - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    private struct WebToolsResult {
        var calls: [ToolCall]
        var promptBlock: String?
        /// Query to hand to the provider-native web search (OpenRouter), when used.
        var nativeWebSearchQuery: String?

        init(calls: [ToolCall] = [], promptBlock: String? = nil, nativeWebSearchQuery: String? = nil) {
            self.calls = calls
            self.promptBlock = promptBlock
            self.nativeWebSearchQuery = nativeWebSearchQuery
        }
    }

    private func applyWebSearchStep(
        _ step: WebSearchService.Step,
        preserving prior: [ToolCall] = []
    ) {
        var calls = activeToolCalls
        // Ensure image-scan (or other prior) steps stay first when SERP updates stream in.
        if !prior.isEmpty {
            let priorIDs = Set(prior.map(\.id))
            let rest = calls.filter { !priorIDs.contains($0.id) }
            calls = prior + rest
        }
        if let idx = calls.firstIndex(where: { $0.id == step.id }) {
            calls[idx] = ToolCall(from: step)
        } else {
            calls.append(ToolCall(from: step))
        }
        activeToolCalls = calls
        AIThinkingActivityManager.shared.thinkingDidUpdate(
            status: step.summary.isEmpty ? "Searching…" : step.summary
        )
    }

    private func runOptionalWebTools(query: String?) async throws -> WebToolsResult {
        guard supportsWebTools, researchEnabled || webSearchEnabled else {
            return WebToolsResult()
        }
        let q = (query ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            return WebToolsResult()
        }

        // Keep any prior image-scan step visible while SERP runs.
        let prior = activeToolCalls.filter { $0.name == "image_scan" }

        // OpenRouter models use the provider-native web search API — the host
        // runs the search and injects fresh results server-side.
        if let model = try? await resolveModel(), model.provider == .openrouter {
            let step = WebSearchService.Step(
                name: researchEnabled ? "research" : "web_search",
                summary: researchEnabled
                    ? "Researching with OpenRouter web search…"
                    : "Searching the web with OpenRouter…",
                detail: "Native OpenRouter web search API",
                status: .completed
            )
            let call = ToolCall(from: step)
            activeToolCalls = prior + [call]
            return WebToolsResult(
                calls: prior + [call],
                promptBlock: nil,
                nativeWebSearchQuery: q
            )
        }

        let mode: WebSearchService.Mode = researchEnabled ? .research : .webSearch
        do {
            let bundle = try await webSearchService.search(userMessage: q, mode: mode) {
                [weak self] step in
                await self?.applyWebSearchStep(step, preserving: prior)
            }
            let searchCalls = bundle.steps.map { ToolCall(from: $0) }
            activeToolCalls = prior + searchCalls
            return WebToolsResult(
                calls: prior + searchCalls,
                promptBlock: bundle.promptBlock.isEmpty ? nil : bundle.promptBlock
            )
        } catch {
            let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            let failed = ToolCall(
                name: researchEnabled ? "research" : "web_search",
                summary: researchEnabled ? "Research unavailable" : "Web search unavailable",
                detail: msg,
                status: .failed(msg)
            )
            activeToolCalls = prior + [failed]
            // Soft-fail: continue analysis without web context.
            return WebToolsResult(calls: prior + [failed], promptBlock: nil)
        }
    }

    private func runInitialAnalysis(
        attachment: ProviderChatMessage.ImageAttachment,
        providerPrompt: String,
        searchContext: String?,
        webSearchQuery: String? = nil
    ) async throws -> String {
        sessionImageAttachment = attachment

        var turns: [ProviderChatMessage] = []
        if let searchContext, !searchContext.isEmpty {
            turns.append(ProviderChatMessage(role: .system, content: searchContext))
        }
        turns.append(
            ProviderChatMessage(role: .user, content: providerPrompt, images: [attachment])
        )
        let reply = try await runChat(messages: turns, webSearchQuery: webSearchQuery)
        // Seed multi-turn history: optional search context, image+prompt, then assistant.
        providerMessages = turns + [ProviderChatMessage(role: .assistant, content: reply)]
        return reply
    }

    private func runChat(messages: [ProviderChatMessage], webSearchQuery: String? = nil) async throws -> String {
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
                    : state.effort,
                webSearchQuery: webSearchQuery
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

    /// Crop in image pixel space from a normalized rect (origin top-leading, 0…1).
    private static func croppedImage(_ image: UIImage, normalized: CGRect) -> UIImage {
        let n = clampedNormalizedCrop(normalized)
        // Nearly full frame — skip a redundant raster.
        if n.minX <= 0.002, n.minY <= 0.002, n.maxX >= 0.998, n.maxY >= 0.998 {
            return image
        }
        guard let cg = image.cgImage else { return image }
        let w = CGFloat(cg.width)
        let h = CGFloat(cg.height)
        let pixelRect = CGRect(
            x: floor(n.minX * w),
            y: floor(n.minY * h),
            width: floor(n.width * w),
            height: floor(n.height * h)
        )
        guard pixelRect.width >= 2, pixelRect.height >= 2,
              let cropped = cg.cropping(to: pixelRect)
        else { return image }
        return UIImage(cgImage: cropped, scale: image.scale, orientation: .up)
    }

    private static func clampedNormalizedCrop(_ rect: CGRect) -> CGRect {
        let minSide: CGFloat = 0.05
        var r = rect.standardized
        if r.width < minSide { r.size.width = minSide }
        if r.height < minSide { r.size.height = minSide }
        r.origin.x = min(max(r.origin.x, 0), 1 - r.size.width)
        r.origin.y = min(max(r.origin.y, 0), 1 - r.size.height)
        r.size.width = min(r.size.width, 1 - r.origin.x)
        r.size.height = min(r.size.height, 1 - r.origin.y)
        return r
    }

    private static func cropsApproximatelyEqual(_ a: CGRect, _ b: CGRect, epsilon: CGFloat = 0.008) -> Bool {
        abs(a.minX - b.minX) < epsilon
            && abs(a.minY - b.minY) < epsilon
            && abs(a.width - b.width) < epsilon
            && abs(a.height - b.height) < epsilon
    }
}
