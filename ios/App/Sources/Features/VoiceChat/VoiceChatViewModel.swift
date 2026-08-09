import Foundation
import Combine
import AnyProvCore

/// Orchestrates live voice conversation: listen (Siri dictation) → model → speak (HiFi / Personal Voice).
@MainActor
final class VoiceChatViewModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case listening
        case thinking
        case speaking
        case error(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var liveCaption: String = ""
    @Published var showModelPicker = false
    @Published var showSettings = false
    @Published var showProviderSettings = false

    let recognition = SpeechRecognitionService()
    let synthesis = SpeechSynthesisService()
    let voiceSettings = VoiceSettingsStore.shared

    /// Shared chat transcript so voice turns land in the same conversation.
    private weak var chatViewModel: ChatViewModel?
    private weak var appState: AppState?
    private var turnTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    init() {
        recognition.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        synthesis.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        voiceSettings.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    func bind(chat: ChatViewModel, state: AppState) {
        chatViewModel = chat
        appState = state
    }

    var modelDisplayName: String {
        guard let state = appState, let model = state.selectedModel else {
            return "Add a model"
        }
        return stripEffort(from: state.displayName(for: model))
    }

    var statusHeadline: String {
        switch phase {
        case .idle:
            return "Start chatting anytime"
        case .listening:
            let partial = recognition.partialTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            if !partial.isEmpty { return partial }
            return "Listening…"
        case .thinking:
            return liveCaption.isEmpty ? "Thinking…" : liveCaption
        case .speaking:
            return liveCaption.isEmpty ? "Speaking…" : liveCaption
        case .error(let message):
            return message
        }
    }

    var isActive: Bool {
        switch phase {
        case .idle, .error: return false
        default: return true
        }
    }

    // MARK: - Controls

    /// Primary mic: start conversation, or interrupt speaking / stop listening.
    func micTapped() {
        switch phase {
        case .idle, .error:
            Task { await startConversation() }
        case .listening:
            stopListeningOnly()
        case .thinking:
            cancelTurn()
        case .speaking:
            interruptSpeechAndListen()
        }
    }

    func stopAll() {
        turnTask?.cancel()
        turnTask = nil
        recognition.stopListening()
        synthesis.stop()
        liveCaption = ""
        phase = .idle
    }

    // MARK: - Loop

    private func startConversation() async {
        guard let state = appState, state.selectedModel != nil else {
            phase = .error("Select a model first.")
            showProviderSettings = true
            return
        }

        let ok = await recognition.requestAuthorization()
        guard ok else {
            phase = .error(recognition.lastError ?? "Microphone or speech recognition permission is required.")
            return
        }

        await synthesis.preparePersonalVoiceIfNeeded(preferPersonal: voiceSettings.preferPersonalVoice)
        await beginListening()
    }

    private func beginListening() async {
        synthesis.stop()
        liveCaption = ""
        do {
            try recognition.startListening { [weak self] utterance in
                self?.handleUtterance(utterance)
            }
            phase = .listening
        } catch {
            phase = .error(error.localizedDescription)
        }
    }

    private func stopListeningOnly() {
        recognition.stopListening(clearTranscript: false)
        phase = .idle
        liveCaption = ""
    }

    private func interruptSpeechAndListen() {
        synthesis.stop()
        turnTask?.cancel()
        turnTask = nil
        Task { await beginListening() }
    }

    private func cancelTurn() {
        turnTask?.cancel()
        turnTask = nil
        recognition.stopListening()
        synthesis.stop()
        phase = .idle
        liveCaption = ""
    }

    private func handleUtterance(_ text: String) {
        turnTask?.cancel()
        turnTask = Task { @MainActor [weak self] in
            await self?.runTurn(userText: text)
        }
    }

    private func runTurn(userText: String) async {
        guard let chat = chatViewModel else {
            phase = .error("Chat is not ready.")
            return
        }

        let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            await beginListening()
            return
        }

        liveCaption = trimmed
        phase = .thinking

        let reply = await chat.sendVoiceMessage(trimmed)
        guard !Task.isCancelled else { return }

        if let reply, !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Speak a voice-friendly version (strip heavy markdown fences for TTS clarity).
            let spoken = Self.voiceFriendly(reply)
            liveCaption = spoken
            phase = .speaking
            let credentials = VoiceTTSCredentials(
                openAIKey: appState?.apiKey(for: .openai) ?? "",
                elevenLabsKey: appState?.voiceAPIKey(for: VoiceSettingsStore.elevenLabsVoiceKeyID) ?? ""
            )
            await synthesis.speak(spoken, settings: voiceSettings, credentials: credentials)
            guard !Task.isCancelled else { return }
            // Surface soft TTS failures without blocking the conversation loop.
            if let ttsErr = synthesis.lastError, !ttsErr.isEmpty {
                liveCaption = ttsErr
            }
        } else if let err = chat.error {
            phase = .error(err)
            return
        }

        if voiceSettings.continuousConversation {
            await beginListening()
        } else {
            phase = .idle
            liveCaption = ""
        }
    }

    /// Soften markdown so AVSpeechSynthesizer doesn't read backticks / fence labels.
    private static func voiceFriendly(_ text: String) -> String {
        var s = text
        // Fenced code blocks → short placeholder.
        if let regex = try? NSRegularExpression(
            pattern: "```[\\s\\S]*?```",
            options: []
        ) {
            let range = NSRange(s.startIndex..., in: s)
            s = regex.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: " Code block. ")
        }
        s = s.replacingOccurrences(of: "`", with: "")
        s = s.replacingOccurrences(of: "**", with: "")
        s = s.replacingOccurrences(of: "__", with: "")
        s = s.replacingOccurrences(of: "*", with: "")
        // Collapse whitespace.
        s = s.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        // Cap very long replies for TTS comfort (still full text is in chat).
        let maxChars = 2_400
        if s.count > maxChars {
            let idx = s.index(s.startIndex, offsetBy: maxChars)
            s = String(s[..<idx]) + "…"
        }
        return s
    }

    private func stripEffort(from name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        for suffix in Effort.allCases.reversed() {
            let token = " " + suffix.displayName
            if trimmed.lowercased().hasSuffix(token.lowercased()) {
                return String(trimmed.dropLast(token.count))
            }
        }
        return trimmed
    }
}
