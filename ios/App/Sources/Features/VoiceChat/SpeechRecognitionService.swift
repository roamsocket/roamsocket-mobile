import Foundation
import Speech
import AVFoundation

/// Live dictation via `SFSpeechRecognizer` + `AVAudioEngine` (Siri-style speech recognition).
@MainActor
final class SpeechRecognitionService: ObservableObject {
    enum AuthorizationState: Equatable {
        case notDetermined
        case denied
        case restricted
        case authorized
    }

    @Published private(set) var authorization: AuthorizationState = .notDetermined
    @Published private(set) var isListening = false
    @Published private(set) var partialTranscript = ""
    @Published private(set) var finalTranscript = ""
    @Published var lastError: String?

    private let audioEngine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    /// Fires after a short silence following the last partial result → end of utterance.
    private var silenceTask: Task<Void, Never>?
    private var onUtterance: ((String) -> Void)?

    /// Silence after last speech before treating the utterance as complete (seconds).
    var endOfSpeechSilence: TimeInterval = 1.15

    init(locale: Locale = .current) {
        recognizer = SFSpeechRecognizer(locale: locale)
            ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        refreshAuthorization()
    }

    func refreshAuthorization() {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: authorization = .authorized
        case .denied: authorization = .denied
        case .restricted: authorization = .restricted
        case .notDetermined: authorization = .notDetermined
        @unknown default: authorization = .denied
        }
    }

    /// Request speech + microphone permission. Returns true when both are usable.
    func requestAuthorization() async -> Bool {
        let speechOK: Bool = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                Task { @MainActor in
                    switch status {
                    case .authorized: self.authorization = .authorized
                    case .denied: self.authorization = .denied
                    case .restricted: self.authorization = .restricted
                    case .notDetermined: self.authorization = .notDetermined
                    @unknown default: self.authorization = .denied
                    }
                    cont.resume(returning: status == .authorized)
                }
            }
        }
        guard speechOK else {
            lastError = "Speech recognition was denied. Enable it in Settings → Privacy → Speech Recognition."
            return false
        }

        let micOK = await requestMicrophonePermission()
        guard micOK else {
            lastError = "Microphone access was denied. Enable it in Settings → Privacy → Microphone."
            return false
        }
        return true
    }

    private func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { cont in
            if #available(iOS 17.0, *) {
                AVAudioApplication.requestRecordPermission { granted in
                    cont.resume(returning: granted)
                }
            } else {
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    cont.resume(returning: granted)
                }
            }
        }
    }

    /// Start continuous dictation. Calls `onUtterance` when end-of-speech silence is detected.
    func startListening(onUtterance: @escaping (String) -> Void) throws {
        guard authorization == .authorized else {
            throw RecognitionError.notAuthorized
        }
        guard let recognizer, recognizer.isAvailable else {
            throw RecognitionError.unavailable
        }

        stopListening(clearTranscript: false)
        self.onUtterance = onUtterance
        partialTranscript = ""
        finalTranscript = ""
        lastError = nil

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .measurement,
            options: [.duckOthers, .defaultToSpeaker, .allowBluetoothHFP]
        )
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Prefer on-device when the locale supports it (private, lower latency).
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        // Dictation-style: keep the task alive across pauses.
        if #available(iOS 16.0, *) {
            request.addsPunctuation = true
        }
        self.request = request

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw RecognitionError.invalidAudioFormat
        }

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()
        isListening = true

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result {
                    let text = result.bestTranscription.formattedString
                    self.partialTranscript = text
                    if result.isFinal {
                        self.finalTranscript = text
                        self.emitUtteranceIfNeeded(text)
                    } else {
                        self.scheduleSilenceCutoff(current: text)
                    }
                }
                if let error {
                    // Ignore cancellation / no-speech when we intentionally stop.
                    let ns = error as NSError
                    if ns.domain == "kAFAssistantErrorDomain", ns.code == 216 || ns.code == 1110 {
                        return
                    }
                    if self.isListening {
                        self.lastError = error.localizedDescription
                    }
                }
            }
        }
    }

    private func scheduleSilenceCutoff(current: String) {
        silenceTask?.cancel()
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let delay = endOfSpeechSilence
        silenceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled, self.isListening else { return }
            // Only fire if the partial text hasn't moved.
            let latest = self.partialTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard latest == trimmed else { return }
            self.emitUtteranceIfNeeded(latest)
        }
    }

    private func emitUtteranceIfNeeded(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Take ownership of the callback before pausing so a late isFinal cannot re-fire.
        let callback = onUtterance
        onUtterance = nil
        silenceTask?.cancel()
        // Pause the recognizer while the turn is processed so we don't double-fire.
        pauseCapture()
        finalTranscript = trimmed
        partialTranscript = ""
        callback?(trimmed)
    }

    /// Stop audio capture without tearing down the callback (used mid-turn).
    func pauseCapture() {
        silenceTask?.cancel()
        silenceTask = nil
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio()
        task?.finish()
        task = nil
        request = nil
        isListening = false
    }

    func stopListening(clearTranscript: Bool = true) {
        silenceTask?.cancel()
        silenceTask = nil
        onUtterance = nil
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        isListening = false
        if clearTranscript {
            partialTranscript = ""
            finalTranscript = ""
        }
    }

    enum RecognitionError: LocalizedError {
        case notAuthorized
        case unavailable
        case invalidAudioFormat

        var errorDescription: String? {
            switch self {
            case .notAuthorized:
                return "Speech recognition is not authorized."
            case .unavailable:
                return "Speech recognition is unavailable for this language right now."
            case .invalidAudioFormat:
                return "Could not configure the microphone audio format."
            }
        }
    }
}
