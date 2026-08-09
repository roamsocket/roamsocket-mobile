import Foundation
import AVFoundation

/// Spoken assistant replies.
/// Cascade: ElevenLabs → OpenAI → free Edge neural → Personal / system AVSpeech.
@MainActor
final class SpeechSynthesisService: NSObject, ObservableObject {
    @Published private(set) var isSpeaking = false
    @Published private(set) var spokenProgress: Double = 0
    @Published var lastError: String?

    private let synthesizer = AVSpeechSynthesizer()
    private var audioPlayer: AVAudioPlayer?
    private var continuation: CheckedContinuation<Void, Never>?
    private var tempAudioURL: URL?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Ask for Personal Voice access when the user may use their clone.
    func preparePersonalVoiceIfNeeded(preferPersonal: Bool) async {
        guard preferPersonal else { return }
        guard #available(iOS 17.0, *) else { return }
        let status = AVSpeechSynthesizer.personalVoiceAuthorizationStatus
        switch status {
        case .notDetermined:
            _ = await withCheckedContinuation { (cont: CheckedContinuation<AVSpeechSynthesizer.PersonalVoiceAuthorizationStatus, Never>) in
                AVSpeechSynthesizer.requestPersonalVoiceAuthorization { cont.resume(returning: $0) }
            }
        case .denied, .unsupported, .authorized:
            break
        @unknown default:
            break
        }
    }

    /// Speak `text`, trying engines in preference order until one succeeds.
    func speak(
        _ text: String,
        settings: VoiceSettingsStore,
        credentials: VoiceTTSCredentials
    ) async {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }

        stop()
        lastError = nil

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers, .allowBluetoothA2DP])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            lastError = error.localizedDescription
        }

        let order = settings.enginePriority(credentials: credentials)
        var lastFailure: String?

        for engine in order {
            do {
                switch engine {
                case .elevenLabs:
                    let data = try await NeuralTTSService.synthesizeElevenLabs(
                        text: cleaned,
                        apiKey: credentials.elevenLabsKey,
                        voiceID: settings.elevenLabsVoiceID,
                        modelID: settings.elevenLabsModel
                    )
                    await playMP3(data)
                    lastError = nil
                    return

                case .openAI:
                    let data = try await NeuralTTSService.synthesizeOpenAI(
                        text: cleaned,
                        apiKey: credentials.openAIKey,
                        voice: settings.openAIVoice,
                        model: settings.openAIModel,
                        speed: settings.openAISpeed
                    )
                    await playMP3(data)
                    lastError = nil
                    return

                case .freeNeural:
                    let data = try await EdgeFreeTTSService.synthesize(
                        text: cleaned,
                        voiceID: settings.freeNeuralVoiceID,
                        ratePercent: settings.freeNeuralRatePercent
                    )
                    await playMP3(data)
                    lastError = nil
                    return

                case .personal:
                    await preparePersonalVoiceIfNeeded(preferPersonal: true)
                    await speakSystem(cleaned, settings: settings)
                    return

                case .system:
                    await speakSystem(cleaned, settings: settings)
                    return

                case .auto:
                    continue
                }
            } catch {
                lastFailure = error.localizedDescription
                continue
            }
        }

        if let lastFailure {
            lastError = lastFailure
        }
    }

    // MARK: - Neural playback

    private func playMP3(_ data: Data) async {
        stopAudioOnly()
        do {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("roamsocket-tts-\(UUID().uuidString).mp3")
            try data.write(to: url, options: .atomic)
            tempAudioURL = url

            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            player.prepareToPlay()
            audioPlayer = player

            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                self.continuation = cont
                self.isSpeaking = true
                self.spokenProgress = 0
                if !player.play() {
                    self.finishSpeaking()
                }
            }
        } catch {
            lastError = error.localizedDescription
            if continuation != nil { finishSpeaking() }
        }
    }

    // MARK: - System speech

    private func speakSystem(_ text: String, settings: VoiceSettingsStore) async {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }

        let utterance = AVSpeechUtterance(string: cleaned)
        utterance.voice = settings.resolvedSystemVoice()
        utterance.rate = settings.speechRateForUtterance
        utterance.pitchMultiplier = 1.0
        utterance.preUtteranceDelay = 0.05
        utterance.postUtteranceDelay = 0.05

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            self.continuation = cont
            self.isSpeaking = true
            self.spokenProgress = 0
            self.synthesizer.speak(utterance)
        }
    }

    func stop() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        stopAudioOnly()
        finishSpeaking()
    }

    private func stopAudioOnly() {
        audioPlayer?.stop()
        audioPlayer = nil
        if let url = tempAudioURL {
            try? FileManager.default.removeItem(at: url)
            tempAudioURL = nil
        }
    }

    private func finishSpeaking() {
        isSpeaking = false
        spokenProgress = 0
        if let cont = continuation {
            continuation = nil
            cont.resume()
        }
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension SpeechSynthesisService: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finishSpeaking() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finishSpeaking() }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in
            let total = utterance.speechString.utf16.count
            guard total > 0 else { return }
            self.spokenProgress = Double(characterRange.location + characterRange.length) / Double(total)
        }
    }
}

// MARK: - AVAudioPlayerDelegate

extension SpeechSynthesisService: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.stopAudioOnly()
            self.finishSpeaking()
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in
            self.lastError = error?.localizedDescription
            self.stopAudioOnly()
            self.finishSpeaking()
        }
    }
}
