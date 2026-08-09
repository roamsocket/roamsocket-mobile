import Foundation

/// Credentials needed for cloud neural TTS (OpenAI reuses the chat key).
struct VoiceTTSCredentials: Sendable {
    var openAIKey: String
    var elevenLabsKey: String

    var hasOpenAI: Bool { !openAIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var hasElevenLabs: Bool { !elevenLabsKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// Fetches natural-sounding speech audio from OpenAI or ElevenLabs.
enum NeuralTTSService {
    enum TTSError: LocalizedError {
        case missingAPIKey(String)
        case badStatus(Int, String)
        case emptyAudio
        case network(String)

        var errorDescription: String? {
            switch self {
            case .missingAPIKey(let name):
                return "Add an API key for \(name) in Settings → Provider API keys."
            case .badStatus(let code, let body):
                return "TTS failed (\(code)): \(body)"
            case .emptyAudio:
                return "TTS returned empty audio."
            case .network(let message):
                return message
            }
        }
    }

    // MARK: - OpenAI

    /// OpenAI Speech API: `POST /v1/audio/speech`
    static func synthesizeOpenAI(
        text: String,
        apiKey: String,
        voice: String,
        model: String,
        speed: Double
    ) async throws -> Data {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw TTSError.missingAPIKey("OpenAI") }

        guard let url = URL(string: "https://api.openai.com/v1/audio/speech") else {
            throw TTSError.network("Invalid OpenAI TTS URL.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60

        // tts-1 / tts-1-hd: max 4096 chars. Clip defensively.
        let clipped = String(text.prefix(4_000))
        let clampedSpeed = min(max(speed, 0.25), 4.0)
        let body: [String: Any] = [
            "model": model,
            "input": clipped,
            "voice": voice,
            "response_format": "mp3",
            "speed": clampedSpeed,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateHTTP(response, data: data, provider: "OpenAI")
        guard !data.isEmpty else { throw TTSError.emptyAudio }
        return data
    }

    // MARK: - ElevenLabs

    /// ElevenLabs TTS: `POST /v1/text-to-speech/{voice_id}`
    static func synthesizeElevenLabs(
        text: String,
        apiKey: String,
        voiceID: String,
        modelID: String
    ) async throws -> Data {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw TTSError.missingAPIKey("ElevenLabs") }

        let vid = voiceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !vid.isEmpty else {
            throw TTSError.network("Pick an ElevenLabs voice in Voice settings.")
        }

        guard let url = URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(vid)") else {
            throw TTSError.network("Invalid ElevenLabs TTS URL.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 90

        let body: [String: Any] = [
            "text": String(text.prefix(5_000)),
            "model_id": modelID,
            "voice_settings": [
                "stability": 0.4,
                "similarity_boost": 0.75,
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateHTTP(response, data: data, provider: "ElevenLabs")
        guard !data.isEmpty else { throw TTSError.emptyAudio }
        return data
    }

    /// List voices available on the account (for the settings picker).
    static func listElevenLabsVoices(apiKey: String) async throws -> [ElevenLabsVoice] {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw TTSError.missingAPIKey("ElevenLabs") }
        guard let url = URL(string: "https://api.elevenlabs.io/v1/voices") else {
            throw TTSError.network("Invalid ElevenLabs voices URL.")
        }
        var request = URLRequest(url: url)
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        try validateHTTP(response, data: data, provider: "ElevenLabs")
        let decoded = try JSONDecoder().decode(ElevenLabsVoicesResponse.self, from: data)
        return decoded.voices
            .map { ElevenLabsVoice(id: $0.voice_id, name: $0.name, category: $0.category) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Shared

    private static func validateHTTP(_ response: URLResponse, data: Data, provider: String) throws {
        guard let http = response as? HTTPURLResponse else {
            throw TTSError.network("No HTTP response from \(provider).")
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let snippet = body.isEmpty ? http.statusCode.description : String(body.prefix(280))
            throw TTSError.badStatus(http.statusCode, snippet)
        }
    }
}

struct ElevenLabsVoice: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let category: String?
}

private struct ElevenLabsVoicesResponse: Decodable {
    struct Item: Decodable {
        let voice_id: String
        let name: String
        let category: String?
    }

    let voices: [Item]
}
