import Foundation
import UIKit
import AnyProvCore

/// One flashcard being composed in the scan flow. Tracks save + dirty state
/// so the review UI can show per-card Save buttons.
struct StudyFlashcardDraft: Identifiable, Equatable {
    let id: UUID
    var question: String
    var answer: String
    var reasoning: String
    /// True once the card has been written to the session deck.
    var isSaved: Bool
    /// True when the user edited fields after the last save.
    var isDirty: Bool

    init(
        id: UUID = UUID(),
        question: String,
        answer: String,
        reasoning: String,
        isSaved: Bool = false,
        isDirty: Bool = false
    ) {
        self.id = id
        self.question = question
        self.answer = answer
        self.reasoning = reasoning
        self.isSaved = isSaved
        self.isDirty = isDirty
    }

    var flashcard: Flashcard {
        Flashcard(
            id: id,
            question: question,
            answer: answer,
            reasoning: reasoning
        )
    }
}

/// Drives the Study scan flow: camera → vision analysis → editable flashcards
/// → save into the session deck.
@MainActor
final class StudyViewModel: ObservableObject {
    enum Phase: Equatable {
        case live
        case capturing
        case analyzing
        case review
        case failed(String)
    }

    @Published var phase: Phase = .live
    @Published var capturedImage: UIImage?
    @Published var cards: [StudyFlashcardDraft] = []
    @Published var selectedModel: AIModel?
    @Published var showModelPicker = false
    @Published var errorMessage: String?

    /// Deck this scan session saves into. Created on the first capture and
    /// persisted to the store on the first card save.
    private(set) var sessionDeck: FlashcardDeck?

    let deckStore: FlashcardDeckStore

    private let catalog: ModelCatalog
    private weak var state: AppState?
    private var analysisTask: Task<Void, Never>?

    init(
        catalog: ModelCatalog = ModelCatalog(),
        deckStore: FlashcardDeckStore = .shared
    ) {
        self.catalog = catalog
        self.deckStore = deckStore
    }

    // MARK: - Computed state

    var isThinking: Bool {
        phase == .capturing || phase == .analyzing
    }

    var hasFrozenCapture: Bool {
        phase != .live
    }

    var showsCameraSession: Bool {
        phase == .live || phase == .capturing
    }

    var freezesCameraPreview: Bool {
        phase == .capturing
    }

    var canCapture: Bool {
        phase != .capturing && phase != .analyzing
    }

    var savedCount: Int {
        cards.filter(\.isSaved).count
    }

    var unsavedCount: Int {
        cards.count - savedCount
    }

    var hasUnsavedCards: Bool {
        cards.contains { !$0.isSaved }
    }

    var canSaveAll: Bool {
        hasUnsavedCards && !isThinking
    }

    var canRetry: Bool {
        if case .failed = phase { return capturedImage != nil }
        return false
    }

    var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    // MARK: - Prompt

    /// Study-specific vision prompt that asks the model to return strictly
    /// separated QUESTION / ANSWER / REASON blocks (see `StudyQuestionParser`).
    static let studyAnalysisPrompt = """
    You are a study assistant. Look at this photo. It contains questions — a quiz, test, worksheet, homework page, or flashcard set.

    Extract every question together with its correct answer and a short reasoning.

    Output exactly one block per question in this format, with blocks separated by a line containing only ---:

    QUESTION: <the full question, including the options if it is multiple choice>
    ANSWER: <the correct answer: True/False, a letter, a number, or a short phrase>
    REASON: <one or two concise sentences explaining why that is the correct answer>

    Rules:
    - Copy each question text as closely as you can.
    - If a question has no visible answer, still give your best answer and note the uncertainty in REASON.
    - If the photo does not contain any questions, reply with exactly: NO_QUESTIONS
    - Do not add an intro, outro, numbering, headers, or any other text outside the blocks.
    """

    // MARK: - Model binding

    func bind(state: AppState) {
        self.state = state
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

    // MARK: - Capture

    /// Shutter fired — freeze the preview and open the analyzing state before
    /// the still finishes developing.
    func beginCapture() {
        guard canCapture else { return }
        analysisTask?.cancel()
        analysisTask = nil
        AIThinkingActivityManager.shared.thinkingDidEnd()

        errorMessage = nil
        cards = []
        capturedImage = nil
        phase = .capturing
        AIThinkingActivityManager.shared.thinkingDidStart(
            kind: .study,
            prompt: "Scanning questions"
        )
    }

    /// Process the captured still with the selected vision model.
    func analyze(image: UIImage) {
        guard phase == .capturing || phase == .analyzing else { return }
        analysisTask?.cancel()
        errorMessage = nil
        cards = []
        phase = .analyzing
        capturedImage = image

        runAnalysisTask(image: image)
    }

    func retryAnalysis() {
        guard canRetry, let image = capturedImage else { return }
        analysisTask?.cancel()
        errorMessage = nil
        cards = []
        phase = .analyzing
        runAnalysisTask(image: image)
    }

    private func runAnalysisTask(image: UIImage) {
        AIThinkingActivityManager.shared.thinkingDidStart(
            kind: .study,
            prompt: "Scanning questions"
        )

        analysisTask = Task { [weak self] in
            guard let self else { return }
            defer { AIThinkingActivityManager.shared.thinkingDidEnd() }
            do {
                let forDisplay = Self.displayImage(from: image)
                guard !Task.isCancelled else { return }
                let attachment = try self.makeAttachment(from: forDisplay)
                let reply = try await self.runChat(
                    messages: [
                        ProviderChatMessage(
                            role: .user,
                            content: Self.studyAnalysisPrompt,
                            images: [attachment]
                        ),
                    ]
                )
                guard !Task.isCancelled else { return }
                let parsed = StudyQuestionParser.parse(reply)
                guard !Task.isCancelled else { return }

                self.capturedImage = forDisplay
                self.cards = parsed.map {
                    StudyFlashcardDraft(
                        question: $0.question,
                        answer: $0.answer,
                        reasoning: $0.reasoning
                    )
                }
                self.phase = .review
            } catch is CancellationError {
                // Retake / dismiss — leave UI in the new state.
            } catch {
                guard !Task.isCancelled else { return }
                let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self.errorMessage = msg
                self.phase = .failed(msg)
            }
        }
    }

    /// Back to the live camera for the next page. Called only after the user
    /// confirmed discarding unsaved cards (or all cards were saved).
    func startNextScan() {
        analysisTask?.cancel()
        analysisTask = nil
        AIThinkingActivityManager.shared.thinkingDidEnd()
        capturedImage = nil
        errorMessage = nil
        cards = []
        phase = .live
    }

    // MARK: - Card edits / saving

    func cardEdited(id: UUID) {
        guard let idx = cards.firstIndex(where: { $0.id == id }) else { return }
        if !cards[idx].isDirty {
            cards[idx].isDirty = true
        }
    }

    /// Write one card into the session deck (insert or update by id).
    func saveCard(id: UUID) {
        guard let idx = cards.firstIndex(where: { $0.id == id }) else { return }
        let flashcard = cards[idx].flashcard
        let deck = deckByUpserting(flashcard)
        sessionDeck = deck
        cards[idx].isSaved = true
        cards[idx].isDirty = false
    }

    /// Save every unsaved card.
    func saveAllCards() {
        for id in cards.filter({ !$0.isSaved }).map(\.id) {
            saveCard(id: id)
        }
    }

    /// Insert/update `flashcard` in the session deck and persist the deck.
    private func deckByUpserting(_ flashcard: Flashcard) -> FlashcardDeck {
        var deck = ensureSessionDeck()
        if let existing = deck.cards.firstIndex(where: { $0.id == flashcard.id }) {
            deck.cards[existing] = flashcard
        } else {
            deck.cards.append(flashcard)
        }
        // Name the deck from the first real question so multiple decks on the
        // same day stay distinguishable.
        if deck.cards.count == 1, !flashcard.question.isEmpty {
            deck.title = Self.deriveDeckTitle(from: flashcard.question)
        }
        return deckStore.upsertDeck(deck)
    }

    private func ensureSessionDeck() -> FlashcardDeck {
        if let sessionDeck { return sessionDeck }
        let deck = FlashcardDeck(title: Self.defaultDeckTitle())
        sessionDeck = deck
        return deck
    }

    static func defaultDeckTitle() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return "Study · \(formatter.string(from: Date()))"
    }

    static func deriveDeckTitle(from question: String) -> String {
        let clean = question
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        guard !clean.isEmpty else { return defaultDeckTitle() }
        if clean.count <= 42 { return clean }
        return String(clean.prefix(42)).trimmingCharacters(in: .whitespaces) + "…"
    }

    // MARK: - Provider plumbing (mirrors VisionViewModel, no web tools)

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

    private func makeAttachment(from image: UIImage, model: AIModel? = nil) throws -> ProviderChatMessage.ImageAttachment {
        let resolved = model ?? selectedModel
        // On-device VLMs are far more memory-sensitive than cloud APIs.
        let maxDim: CGFloat = resolved?.provider == .localMetal ? 1024 : 1600
        let quality: CGFloat = resolved?.provider == .localMetal ? 0.65 : 0.72
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
