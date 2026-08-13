import Foundation
import UIKit
import AnyProvCore

/// Drives a Guided Learning session: choose study material → the tutor plans a
/// few steps → teaches one at a time → checks understanding with a question →
/// feedback + hints instead of answers → recap with flashcards.
///
/// The model is called as a stateless chat: every turn re-sends the full
/// transcript (system prompt + prior blocks + user answers), and each reply is
/// parsed into `GuidedLessonTurn` blocks by `GuidedLearningParser`.
@MainActor
final class GuidedLearningViewModel: ObservableObject {

    // MARK: - Published state

    @Published var phase: GuidedLearningPhase = .setup
    @Published var selectedSource: GuidedLearningSource = .topic

    @Published var topic = ""
    @Published var notes = ""
    @Published var selectedDeck: FlashcardDeck?
    @Published var photoThumbnail: UIImage?
    @Published var isTranscribingPhoto = false
    @Published var photoTranscriptionError: String?

    @Published var selectedModel: AIModel?
    @Published var showModelPicker = false

    @Published var plan: [String] = []
    @Published var currentStep = 0
    @Published var turn: GuidedLessonTurn?
    @Published var input = ""
    @Published var errorMessage: String?

    /// Deck the recap flashcards were saved into (nil until saved).
    @Published var savedDeck: FlashcardDeck?

    let deckStore: FlashcardDeckStore

    private let catalog: ModelCatalog
    private weak var state: AppState?
    private var analysisTask: Task<Void, Never>?
    private var transcript: [ProviderChatMessage] = []
    private var lessonCount = 0
    private var lastSubmission: String?

    init(
        catalog: ModelCatalog = ModelCatalog(),
        deckStore: FlashcardDeckStore = .shared
    ) {
        self.catalog = catalog
        self.deckStore = deckStore
    }

    // MARK: - Computed state

    var isWorking: Bool {
        phase == .planning || phase == .evaluating || isTranscribingPhoto
    }

    var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    var canStart: Bool {
        switch selectedSource {
        case .topic:
            return !topic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .notes, .photo:
            return !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .deck:
            return selectedDeck != nil
        }
    }

    var canSubmit: Bool {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && !isWorking
    }

    /// Title of the plan step currently being taught (nil before any plan).
    var stepTitle: String? {
        guard !plan.isEmpty else { return nil }
        if currentStep < plan.count { return plan[currentStep] }
        return "Follow-up"
    }

    var stepNumber: Int? {
        guard !plan.isEmpty else { return nil }
        return min(currentStep + 1, plan.count)
    }

    var savedCardCount: Int {
        turn?.cards.count ?? 0
    }

    // MARK: - Prompt

    /// Socratic-tutor system prompt. Defines the only wire format the parser
    /// understands — keep the blocks in `GuidedLearningParser` in sync.
    static let tutorSystemPrompt = """
    You are a patient Socratic tutor inside a study app. You teach one concept at a time, check understanding, and give hints instead of answers.

    REPLY FORMAT
    Your replies contain only the labelled blocks below, separated by blank lines.

    PLAN
    Use only in your very first reply, before any lesson. List exactly 3-4 sequential learning steps, one per line starting with "- ".

    LESSON
    Teach the current step: a short explanation with a concrete example. Keep it to 3-6 short paragraphs.

    QUESTION
    One interactive check on the lesson just taught. Prefer multiple choice: options on their own lines starting with "A) ", "B) ", "C) ", "D) ".

    HINT
    Optional after a lesson when the check has a common misconception. After a wrong answer, include one more specific hint than the last.

    FEEDBACK
    Begin every reply that follows a user answer with "CORRECT:" or "INCORRECT:", then 1-2 sentences explaining why.

    RECAP
    Only when every plan step is complete: a 3-5 sentence summary of the whole topic, followed by the CARDS block.

    CARDS
    Only with RECAP. 3-5 study flashcards in this format, separated by a line containing only ---:
    QUESTION: ...
    ANSWER: ...
    REASON: ...

    RULES
    - Always end with exactly one QUESTION, or a RECAP when the lesson is finished.
    - Never reveal the answer to a check-in. Give hints and let the user arrive at it.
    - After an INCORRECT answer, never advance to the next LESSON.
    - Adapt depth to the user: if they clearly know the material, move faster and dig deeper; if they struggle, break it down further.
    - Stay on the user's chosen topic or uploaded material.
    - No greetings, no outro, no text outside the blocks.
    """

    /// Vision prompt that turns a photo of study material into editable notes.
    static let photoTranscriptionPrompt = """
    You are a study assistant. This photo contains study material: lecture slides, textbook pages, handwritten notes, or worksheets.

    Transcribe and organize it into clear study notes. Capture the key concepts, definitions, formulas, and any practice questions exactly as written.

    Output only the notes text — no commentary, no markdown headers.
    """

    // MARK: - Model binding

    func bind(state: AppState) {
        self.state = state
        let stillListed = selectedModel.map { current in
            state.allModels.contains(where: { $0.id == current.id })
        } ?? false
        if selectedModel == nil || !stillListed {
            selectedModel = state.selectedModel
        }
    }

    func allModels(from state: AppState) -> [AIModel] {
        state.allModels
    }

    // MARK: - Session control

    /// Start the lesson from the current source material.
    func startLesson() {
        guard canStart, !isWorking else { return }
        analysisTask?.cancel()
        analysisTask = nil
        errorMessage = nil
        transcript = []
        plan = []
        currentStep = 0
        lessonCount = 0
        turn = nil
        savedDeck = nil
        input = ""

        send(userText: buildInitialPrompt(), workingPhase: .planning)
    }

    func submitAnswer(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isWorking else { return }
        input = ""
        send(userText: trimmed, workingPhase: .evaluating)
    }

    func retry() {
        guard isFailed else { return }
        let phase: GuidedLearningPhase = lastSubmission == initialPrompt() ? .planning : .evaluating
        if let lastSubmission {
            send(userText: lastSubmission, workingPhase: phase)
        }
    }

    func reset() {
        analysisTask?.cancel()
        analysisTask = nil
        AIThinkingActivityManager.shared.thinkingDidEnd()
        transcript = []
        plan = []
        currentStep = 0
        lessonCount = 0
        turn = nil
        input = ""
        savedDeck = nil
        errorMessage = nil
        lastSubmission = nil
        phase = .setup
    }

    /// Save the recap flashcards into a new deck.
    func saveCards() {
        guard let cards = turn?.cards, !cards.isEmpty, savedDeck == nil else { return }
        let deck = FlashcardDeck(
            title: Self.deriveDeckTitle(),
            cards: cards.map {
                Flashcard(question: $0.question, answer: $0.answer, reasoning: $0.reasoning)
            }
        )
        savedDeck = deckStore.upsertDeck(deck)
    }

    // MARK: - Photo transcription

    /// Transcribe a photo of study material into `notes` using a vision model.
    func transcribePhoto(_ image: UIImage) {
        guard let state, !isWorking else { return }
        guard let vision = VisionCapability.preferredVisionModel(
            from: state.allModels,
            current: selectedModel,
            isVision: { state.modelSupportsVision($0) }
        ) else {
            photoTranscriptionError = "Photo study material needs a vision-capable model. Add an API key for OpenAI, Anthropic, OpenRouter, or xAI in Settings, or mark a custom provider as Supports vision."
            return
        }
        photoTranscriptionError = nil
        isTranscribingPhoto = true
        AIThinkingActivityManager.shared.thinkingDidStart(
            kind: .guided,
            prompt: "Analyzing study material"
        )

        analysisTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.isTranscribingPhoto = false
                AIThinkingActivityManager.shared.thinkingDidEnd()
            }
            do {
                let attachment = try makeAttachment(from: image, model: vision)
                let reply = try await self.runChat(
                    messages: [
                        ProviderChatMessage(
                            role: .user,
                            content: Self.photoTranscriptionPrompt,
                            images: [attachment]
                        ),
                    ],
                    modelOverride: vision
                )
                guard !Task.isCancelled else { return }
                self.notes = reply
                self.selectedSource = .notes
            } catch is CancellationError {
                // User navigated away — leave the state alone.
            } catch {
                guard !Task.isCancelled else { return }
                let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self.photoTranscriptionError = msg
            }
        }
    }

    // MARK: - Turn pipeline

    private func send(userText: String, workingPhase: GuidedLearningPhase) {
        lastSubmission = userText
        transcript.append(
            ProviderChatMessage(role: .user, content: userText)
        )
        phase = workingPhase
        AIThinkingActivityManager.shared.thinkingDidStart(
            kind: .guided,
            prompt: userText
        )

        analysisTask = Task { [weak self] in
            guard let self else { return }
            defer { AIThinkingActivityManager.shared.thinkingDidEnd() }
            do {
                let reply = try await self.runChat(messages: transcript)
                guard !Task.isCancelled else { return }
                let parsed = GuidedLearningParser.parse(reply)
                self.transcript.append(
                    ProviderChatMessage(
                        role: .assistant,
                        content: Self.renderTurn(parsed)
                    )
                )
                self.apply(parsed)
            } catch is CancellationError {
                // Retake / reset — leave the UI in its new state.
            } catch {
                guard !Task.isCancelled else { return }
                // The failed user message is not part of the transcript.
                self.transcript.removeLast()
                let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self.errorMessage = msg
                self.phase = .failed(msg)
            }
        }
    }

    /// Fold a parsed turn into the session state.
    private func apply(_ parsed: GuidedLessonTurn) {
        if !parsed.plan.isEmpty {
            plan = parsed.plan
            currentStep = 0
            lessonCount = 1
        } else if parsed.lesson != nil {
            lessonCount += 1
            currentStep = lessonCount - 1
        }

        turn = parsed
        if parsed.recap != nil {
            phase = .done
        } else {
            phase = .teaching
        }
    }

    // MARK: - Material

    private func initialPrompt() -> String {
        buildInitialPrompt()
    }

    private func buildInitialPrompt() -> String {
        switch selectedSource {
        case .topic:
            return "Please teach me this topic step by step:\n\(topic.trimmingCharacters(in: .whitespacesAndNewlines))"
        case .notes, .photo:
            return "Here is my study material. Teach me this material step by step.\n\n\(notes.trimmingCharacters(in: .whitespacesAndNewlines))"
        case .deck:
            let material = selectedDeck?.sortedCards
                .map { "Q: \($0.question)\nA: \($0.answer)" }
                .joined(separator: "\n\n")
            return "Here is my study material (flashcards). Teach me this material step by step.\n\n\(material ?? "")"
        }
    }

    /// Rebuild the assistant-side transcript text for one parsed turn, so the
    /// model sees its own previous blocks in every stateless call.
    static func renderTurn(_ turn: GuidedLessonTurn) -> String {
        var parts: [String] = []

        if !turn.plan.isEmpty {
            parts.append("PLAN\n" + turn.plan.map { "- \($0)" }.joined(separator: "\n"))
        }
        if let lesson = turn.lesson {
            parts.append("LESSON\n\(lesson)")
        }
        if let feedback = turn.feedback {
            let verdict = feedback.isCorrect ? "CORRECT" : "INCORRECT"
            parts.append("FEEDBACK\n\(verdict): \(feedback.text)")
        }
        if let hint = turn.hint {
            parts.append("HINT\n\(hint)")
        }
        if let question = turn.question {
            var block = "QUESTION\n\(question.question)"
            if !question.options.isEmpty {
                let letters = ["A", "B", "C", "D"]
                block += "\n" + question.options.enumerated()
                    .map { "\(letters[$0.offset]) \($0.element)" }
                    .joined(separator: "\n")
            }
            parts.append(block)
        }
        if let recap = turn.recap {
            parts.append("RECAP\n\(recap)")
        }
        if !turn.cards.isEmpty {
            parts.append(
                "CARDS\n" + turn.cards.map {
                    "QUESTION: \($0.question)\nANSWER: \($0.answer)\nREASON: \($0.reasoning)"
                }
                .joined(separator: "\n---\n")
            )
        }

        return parts.joined(separator: "\n\n")
    }

    static func deriveDeckTitle() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return "Guided · \(formatter.string(from: Date()))"
    }

    // MARK: - Provider plumbing (mirrors StudyViewModel)

    private func runChat(
        messages: [ProviderChatMessage],
        modelOverride: AIModel? = nil
    ) async throws -> String {
        guard let state else {
            throw ProviderError.transport("App state is not ready.")
        }
        let model = try await resolveModel(override: modelOverride)

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
                    ? "On-device tutor failed: \(msg)"
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
            throw ProviderError.transport("The model returned an empty reply.")
        }
        return text
    }

    private func resolveModel(override: AIModel?) async throws -> AIModel {
        guard let state else {
            throw ProviderError.transport("App state is not ready.")
        }
        guard let model = override ?? selectedModel ?? state.selectedModel else {
            throw ProviderError.transport(
                "No model available. Add an API key for OpenAI, Anthropic, OpenRouter, or xAI in Settings, or download an on-device model."
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
