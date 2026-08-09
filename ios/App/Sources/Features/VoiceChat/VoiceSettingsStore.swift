import Foundation
import AVFoundation

/// How spoken replies are produced.
enum VoiceSpeechEngine: String, CaseIterable, Identifiable, Sendable {
    /// Prefer ElevenLabs → OpenAI → free neural → system, based on available keys.
    case auto
    case elevenLabs
    case openAI
    /// Built-in free Microsoft Edge neural voices (no API key; needs network).
    case freeNeural
    /// Apple Personal Voice (on-device clone), else HiFi system.
    case personal
    /// On-device AVSpeech only (offline fallback).
    case system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "Auto (best available)"
        case .elevenLabs: return "ElevenLabs"
        case .openAI: return "OpenAI"
        case .freeNeural: return "Free neural"
        case .personal: return "Personal Voice"
        case .system: return "System (on-device)"
        }
    }

    var subtitle: String {
        switch self {
        case .auto:
            return "Keys first, then free neural, then system speech."
        case .elevenLabs:
            return "Most natural. Free tier ≈ 10k chars/month; then paid."
        case .openAI:
            return "Natural neural voices. Uses your OpenAI chat key."
        case .freeNeural:
            return "No API key. Microsoft Edge neural voices — much better than Apple system TTS."
        case .personal:
            return "Your iOS Accessibility Personal Voice clone."
        case .system:
            return "Apple AVSpeechSynthesizer (offline, more robotic)."
        }
    }
}

/// Persisted preferences for live voice chat (dictation + spoken replies).
@MainActor
final class VoiceSettingsStore: ObservableObject {
    static let shared = VoiceSettingsStore()

    /// Keychain id for the ElevenLabs voice-only key (not a chat provider).
    static let elevenLabsVoiceKeyID = "elevenlabs"

    private enum Keys {
        static let engine = "voiceChat.speechEngine.v2"
        static let voiceIdentifier = "voiceChat.voiceIdentifier.v1"
        static let speechRate = "voiceChat.speechRate.v1"
        static let preferPersonalVoice = "voiceChat.preferPersonalVoice.v1"
        static let continuousConversation = "voiceChat.continuousConversation.v1"
        static let openAIVoice = "voiceChat.openAIVoice.v1"
        static let openAIModel = "voiceChat.openAIModel.v1"
        static let elevenLabsVoiceID = "voiceChat.elevenLabsVoiceID.v1"
        static let elevenLabsModel = "voiceChat.elevenLabsModel.v1"
        static let freeNeuralVoiceID = "voiceChat.freeNeuralVoiceID.v1"
    }

    @Published var engine: VoiceSpeechEngine {
        didSet { UserDefaults.standard.set(engine.rawValue, forKey: Keys.engine) }
    }

    /// Explicit system voice identifier (`AVSpeechSynthesisVoice.identifier`), or empty for auto-pick.
    @Published var voiceIdentifier: String {
        didSet { UserDefaults.standard.set(voiceIdentifier, forKey: Keys.voiceIdentifier) }
    }

    /// 0…1 speech rate (mapped per engine).
    @Published var speechRate: Double {
        didSet { UserDefaults.standard.set(speechRate, forKey: Keys.speechRate) }
    }

    /// When using system / personal path, prefer a Personal Voice clone if authorized.
    @Published var preferPersonalVoice: Bool {
        didSet { UserDefaults.standard.set(preferPersonalVoice, forKey: Keys.preferPersonalVoice) }
    }

    /// After the assistant finishes speaking, automatically start listening again.
    @Published var continuousConversation: Bool {
        didSet { UserDefaults.standard.set(continuousConversation, forKey: Keys.continuousConversation) }
    }

    /// OpenAI preset voice id (alloy, nova, …).
    @Published var openAIVoice: String {
        didSet { UserDefaults.standard.set(openAIVoice, forKey: Keys.openAIVoice) }
    }

    /// OpenAI speech model (`tts-1-hd`, `tts-1`, `gpt-4o-mini-tts`).
    @Published var openAIModel: String {
        didSet { UserDefaults.standard.set(openAIModel, forKey: Keys.openAIModel) }
    }

    /// ElevenLabs voice_id.
    @Published var elevenLabsVoiceID: String {
        didSet { UserDefaults.standard.set(elevenLabsVoiceID, forKey: Keys.elevenLabsVoiceID) }
    }

    /// ElevenLabs model_id.
    @Published var elevenLabsModel: String {
        didSet { UserDefaults.standard.set(elevenLabsModel, forKey: Keys.elevenLabsModel) }
    }

    /// Free neural (Edge) voice short name, e.g. `en-US-EmmaMultilingualNeural`.
    @Published var freeNeuralVoiceID: String {
        didSet { UserDefaults.standard.set(freeNeuralVoiceID, forKey: Keys.freeNeuralVoiceID) }
    }

    private init() {
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: Keys.engine),
           let eng = VoiceSpeechEngine(rawValue: raw) {
            self.engine = eng
        } else {
            // Upgrade: former preferPersonalVoice-only installs → auto neural.
            self.engine = .auto
        }
        self.voiceIdentifier = defaults.string(forKey: Keys.voiceIdentifier) ?? ""
        let storedRate = defaults.object(forKey: Keys.speechRate) as? Double
        self.speechRate = storedRate ?? 0.5
        self.preferPersonalVoice = defaults.object(forKey: Keys.preferPersonalVoice) as? Bool ?? true
        self.continuousConversation = defaults.object(forKey: Keys.continuousConversation) as? Bool ?? true
        self.openAIVoice = defaults.string(forKey: Keys.openAIVoice) ?? "nova"
        self.openAIModel = defaults.string(forKey: Keys.openAIModel) ?? "tts-1-hd"
        // Rachel — widely available default stock voice on ElevenLabs free tier.
        self.elevenLabsVoiceID = defaults.string(forKey: Keys.elevenLabsVoiceID) ?? "21m00Tcm4TlvDq8ikWAM"
        self.elevenLabsModel = defaults.string(forKey: Keys.elevenLabsModel) ?? "eleven_multilingual_v2"
        self.freeNeuralVoiceID = defaults.string(forKey: Keys.freeNeuralVoiceID)
            ?? EdgeFreeTTSService.defaultVoiceID
    }

    // MARK: - Catalogs

    static let openAIVoices: [(id: String, name: String)] = [
        ("alloy", "Alloy"),
        ("ash", "Ash"),
        ("ballad", "Ballad"),
        ("coral", "Coral"),
        ("echo", "Echo"),
        ("fable", "Fable"),
        ("nova", "Nova"),
        ("onyx", "Onyx"),
        ("sage", "Sage"),
        ("shimmer", "Shimmer"),
        ("marin", "Marin"),
        ("cedar", "Cedar"),
    ]

    static let openAIModels: [(id: String, name: String)] = [
        ("tts-1-hd", "TTS-1 HD (best quality)"),
        ("tts-1", "TTS-1 (lower latency)"),
        ("gpt-4o-mini-tts", "GPT-4o mini TTS"),
    ]

    static let elevenLabsModels: [(id: String, name: String)] = [
        ("eleven_multilingual_v2", "Multilingual v2"),
        ("eleven_turbo_v2_5", "Turbo v2.5 (faster)"),
        ("eleven_flash_v2_5", "Flash v2.5 (lowest latency)"),
    ]

    /// Well-known stock voices when the account list hasn’t been fetched yet.
    static let elevenLabsPresetVoices: [ElevenLabsVoice] = [
        ElevenLabsVoice(id: "21m00Tcm4TlvDq8ikWAM", name: "Rachel", category: "premade"),
        ElevenLabsVoice(id: "29vD33N1CtxCmqQRPOHJ", name: "Drew", category: "premade"),
        ElevenLabsVoice(id: "2EiwWnXFnvU5JabPnv8n", name: "Clyde", category: "premade"),
        ElevenLabsVoice(id: "5Q0t7uMcjvnagumLfvZi", name: "Paul", category: "premade"),
        ElevenLabsVoice(id: "AZnzlk1XvdvUeBnXmlld", name: "Domi", category: "premade"),
        ElevenLabsVoice(id: "CYw3kZ02Hs0563khs1Fj", name: "Dave", category: "premade"),
        ElevenLabsVoice(id: "D38z5RcWu1voky8WS1ja", name: "Fin", category: "premade"),
        ElevenLabsVoice(id: "EXAVITQu4vr4xnSDxMaL", name: "Sarah", category: "premade"),
        ElevenLabsVoice(id: "ErXwobaYiN019PkySvjV", name: "Antoni", category: "premade"),
        ElevenLabsVoice(id: "GBv7mTt0atIp3Br8iCZE", name: "Thomas", category: "premade"),
        ElevenLabsVoice(id: "IKne3meq5aSn9XLyUdCD", name: "Charlie", category: "premade"),
        ElevenLabsVoice(id: "JBFqnCBsd6RMkjVDRZzb", name: "George", category: "premade"),
        ElevenLabsVoice(id: "LcfcDJNUP1GQjkzn1xUU", name: "Emily", category: "premade"),
        ElevenLabsVoice(id: "MF3mGyEYCl7XYWbV9V6O", name: "Elli", category: "premade"),
        ElevenLabsVoice(id: "N2lVS1w4EtoT3dr4eOWO", name: "Callum", category: "premade"),
        ElevenLabsVoice(id: "ODq5zmih8GrVes37Dizd", name: "Patrick", category: "premade"),
        ElevenLabsVoice(id: "SOYHLrjzK2X1ezoPC6cr", name: "Harry", category: "premade"),
        ElevenLabsVoice(id: "TX3LPaxmHKxFdv7VOQHJ", name: "Liam", category: "premade"),
        ElevenLabsVoice(id: "ThT5KcBeYPX3keUQqHPh", name: "Dorothy", category: "premade"),
        ElevenLabsVoice(id: "TxGEqnHWrfWFTfGW9XjX", name: "Josh", category: "premade"),
        ElevenLabsVoice(id: "VR6AewLTigWG4xSOukaG", name: "Arnold", category: "premade"),
        ElevenLabsVoice(id: "XB0fDUnXU5powFXDhCwa", name: "Charlotte", category: "premade"),
        ElevenLabsVoice(id: "XrExE9yKIg1WjnnlVkGX", name: "Matilda", category: "premade"),
        ElevenLabsVoice(id: "pNInz6obpgDQGcFmaJgB", name: "Adam", category: "premade"),
        ElevenLabsVoice(id: "yoZ06aMxZJJ28mfd3POQ", name: "Sam", category: "premade"),
        ElevenLabsVoice(id: "z9fAnlkpzviPz146aGWa", name: "Glinda", category: "premade"),
        ElevenLabsVoice(id: "zcAOhNBS3c14rBihAFp1", name: "Giovanni", category: "premade"),
        ElevenLabsVoice(id: "zrHiDhphv9ZnVXBqCLjz", name: "Mimi", category: "premade"),
    ]

    // MARK: - Resolution

    /// Ordered engines to try for the current preference + keys.
    /// Free neural sits above robotic system speech when no paid keys exist.
    func enginePriority(credentials: VoiceTTSCredentials) -> [VoiceSpeechEngine] {
        switch engine {
        case .auto:
            var order: [VoiceSpeechEngine] = []
            if credentials.hasElevenLabs { order.append(.elevenLabs) }
            if credentials.hasOpenAI { order.append(.openAI) }
            order.append(.freeNeural)
            if preferPersonalVoice { order.append(.personal) }
            order.append(.system)
            return order
        case .elevenLabs:
            var order: [VoiceSpeechEngine] = []
            if credentials.hasElevenLabs { order.append(.elevenLabs) }
            if credentials.hasOpenAI { order.append(.openAI) }
            order.append(contentsOf: [.freeNeural, .system])
            return order
        case .openAI:
            var order: [VoiceSpeechEngine] = []
            if credentials.hasOpenAI { order.append(.openAI) }
            order.append(contentsOf: [.freeNeural, .system])
            return order
        case .freeNeural:
            return [.freeNeural, .system]
        case .personal:
            return [.personal, .system]
        case .system:
            return [.system]
        }
    }

    /// First engine that will actually run for the status label.
    func resolvedEngine(credentials: VoiceTTSCredentials) -> VoiceSpeechEngine {
        enginePriority(credentials: credentials).first ?? .system
    }

    /// Edge free-neural rate string offset (−50…+100).
    var freeNeuralRatePercent: Int {
        let clamped = min(max(speechRate, 0), 1)
        // 0 → -20%, 0.5 → 0%, 1 → +30%
        if clamped <= 0.5 {
            return Int((-20.0 + (0 - -20.0) * (clamped / 0.5)).rounded())
        }
        return Int((0 + 30.0 * ((clamped - 0.5) / 0.5)).rounded())
    }

    /// Resolve on-device AVSpeech voice from preferences.
    func resolvedSystemVoice(preferredLanguage: String = Locale.current.identifier) -> AVSpeechSynthesisVoice? {
        if !voiceIdentifier.isEmpty,
           let explicit = AVSpeechSynthesisVoice(identifier: voiceIdentifier) {
            return explicit
        }

        let voices = AVSpeechSynthesisVoice.speechVoices()
        let langPrefix = preferredLanguage.prefix(2).lowercased()

        if preferPersonalVoice || engine == .personal {
            let personal = voices.filter { $0.isPersonalVoiceClone }
            if let match = personal.first(where: { $0.language.lowercased().hasPrefix(langPrefix) })
                ?? personal.first {
                return match
            }
        }

        let localeVoices = voices.filter { $0.language.lowercased().hasPrefix(langPrefix) }
        if let premium = localeVoices.first(where: { $0.quality == .premium }) {
            return premium
        }
        if let enhanced = localeVoices.first(where: { $0.quality == .enhanced }) {
            return enhanced
        }
        if let anyLocale = localeVoices.first {
            return anyLocale
        }
        return AVSpeechSynthesisVoice(language: preferredLanguage)
            ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    /// Catalog of system voices suitable for the settings picker.
    static func availableSystemVoices() -> [AVSpeechSynthesisVoice] {
        let all = AVSpeechSynthesisVoice.speechVoices()
        let personal = all.filter(\.isPersonalVoiceClone)
        let hifi = all.filter { voice in
            !voice.isPersonalVoiceClone
                && (voice.quality == .premium || voice.quality == .enhanced)
        }
        let lang = Locale.current.language.languageCode?.identifier ?? "en"
        let defaults = all.filter {
            !$0.isPersonalVoiceClone
                && $0.quality == .default
                && $0.language.lowercased().hasPrefix(lang)
        }
        var seen = Set<String>()
        var ordered: [AVSpeechSynthesisVoice] = []
        for voice in personal + hifi + defaults {
            if seen.insert(voice.identifier).inserted {
                ordered.append(voice)
            }
        }
        return ordered.sorted {
            if $0.isPersonalVoiceClone != $1.isPersonalVoiceClone {
                return $0.isPersonalVoiceClone && !$1.isPersonalVoiceClone
            }
            if $0.quality.rank != $1.quality.rank {
                return $0.quality.rank > $1.quality.rank
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    var speechRateForUtterance: Float {
        let clamped = min(max(speechRate, 0), 1)
        let minR = Double(AVSpeechUtteranceMinimumSpeechRate)
        let maxR = Double(AVSpeechUtteranceMaximumSpeechRate)
        let defR = Double(AVSpeechUtteranceDefaultSpeechRate)
        if clamped <= 0.5 {
            return Float(minR + (defR - minR) * (clamped / 0.5))
        }
        return Float(defR + (maxR - defR) * ((clamped - 0.5) / 0.5))
    }

    /// OpenAI `speed` parameter (0.25…4.0), mapped from the 0…1 slider.
    var openAISpeed: Double {
        let clamped = min(max(speechRate, 0), 1)
        // 0 → 0.75, 0.5 → 1.0, 1 → 1.4
        if clamped <= 0.5 {
            return 0.75 + (1.0 - 0.75) * (clamped / 0.5)
        }
        return 1.0 + (1.4 - 1.0) * ((clamped - 0.5) / 0.5)
    }

    /// Short status for Settings rows.
    func statusLabel(credentials: VoiceTTSCredentials) -> String {
        switch resolvedEngine(credentials: credentials) {
        case .auto: return "Auto"
        case .elevenLabs: return "ElevenLabs"
        case .openAI: return "OpenAI"
        case .freeNeural: return "Free neural"
        case .personal: return "Personal"
        case .system: return "System"
        }
    }
}

// MARK: - Voice helpers

extension AVSpeechSynthesisVoice {
    /// True when this voice is the user's Accessibility Personal Voice clone.
    var isPersonalVoiceClone: Bool {
        if #available(iOS 17.0, *) {
            return voiceTraits.contains(.isPersonalVoice)
        }
        return false
    }

    var qualityLabel: String {
        if isPersonalVoiceClone { return "Personal Voice" }
        switch quality {
        case .premium: return "Premium (HiFi)"
        case .enhanced: return "Enhanced (HiFi)"
        default: return "Standard"
        }
    }
}

private extension AVSpeechSynthesisVoiceQuality {
    var rank: Int {
        switch self {
        case .premium: return 3
        case .enhanced: return 2
        default: return 1
        }
    }
}
