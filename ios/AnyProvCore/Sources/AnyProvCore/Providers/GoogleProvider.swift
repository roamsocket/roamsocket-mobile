import Foundation

/// Google Gemini provider:
/// - List: `GET …/v1beta/models?key=…`
/// - Chat: `POST …/v1beta/models/{id}:generateContent?key=…`
public struct GoogleProvider: ModelProvider {
    public let id: ProviderID = .google
    private let http: HTTPClient
    private let baseURL: URL

    public init(http: HTTPClient = URLSessionHTTPClient(), baseURL: URL? = nil) {
        self.http = http
        self.baseURL = baseURL ?? URL(string: "https://generativelanguage.googleapis.com/v1beta")!
    }

    private struct ModelList: Decodable {
        struct Model: Decodable {
            let name: String                 // "models/gemini-1.5-pro"
            let displayName: String?
            let inputTokenLimit: Int?
            let supportedGenerationMethods: [String]?
        }
        let models: [Model]
    }

    public func listModels(apiKey: String) async throws -> [AIModel] {
        guard !apiKey.isEmpty else { throw ProviderError.missingKey }
        var components = URLComponents(
            url: baseURL.appendingPathComponent("models"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        let request = ProviderHTTP.get(components.url!, headers: [:])
        let (data, response) = try await http.data(for: request)
        try ProviderHTTP.validate(data, response)
        do {
            let list = try JSONDecoder().decode(ModelList.self, from: data)
            return list.models
                // Only models that can generate content are usable for chat.
                .filter { ($0.supportedGenerationMethods ?? []).contains("generateContent") }
                .map {
                    let shortID = $0.name.replacingOccurrences(of: "models/", with: "")
                    return AIModel(
                        provider: .google,
                        modelID: shortID,
                        displayName: $0.displayName ?? shortID,
                        contextWindow: $0.inputTokenLimit
                    )
                }
        } catch {
            throw ProviderError.decoding(String(describing: error))
        }
    }

    // MARK: - Chat (generateContent)

    private struct GenerateRequest: Encodable {
        let contents: [Content]
        let systemInstruction: Content?
        let generationConfig: GenerationConfig?

        enum CodingKeys: String, CodingKey {
            case contents
            case systemInstruction = "system_instruction"
            case generationConfig = "generation_config"
        }
    }

    private struct GenerationConfig: Encodable {
        let maxOutputTokens: Int?
        let temperature: Double?

        enum CodingKeys: String, CodingKey {
            case maxOutputTokens = "max_output_tokens"
            case temperature
        }
    }

    private struct Content: Encodable {
        let role: String?
        let parts: [Part]
    }

    private struct Part: Encodable {
        let text: String?
        let inlineData: InlineData?

        enum CodingKeys: String, CodingKey {
            case text
            case inlineData = "inline_data"
        }
    }

    private struct InlineData: Encodable {
        let mimeType: String
        let data: String

        enum CodingKeys: String, CodingKey {
            case mimeType = "mime_type"
            case data
        }
    }

    private struct GenerateResponse: Decodable {
        struct Candidate: Decodable {
            struct Content: Decodable {
                struct Part: Decodable {
                    let text: String?
                }
                let parts: [Part]?
            }
            let content: Content?
        }
        let candidates: [Candidate]?
        struct PromptFeedback: Decodable {
            let blockReason: String?
            enum CodingKeys: String, CodingKey {
                case blockReason = "block_reason"
            }
        }
        let promptFeedback: PromptFeedback?
        enum CodingKeys: String, CodingKey {
            case candidates
            case promptFeedback = "prompt_feedback"
        }
    }

    public func chat(
        model: String,
        apiKey: String,
        messages: [ProviderChatMessage],
        effort: Effort?
    ) async throws -> String {
        guard !apiKey.isEmpty else { throw ProviderError.missingKey }

        let systemParts = messages
            .filter { $0.role == .system }
            .map(\.content)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let systemInstruction: Content? = systemParts.isEmpty
            ? nil
            : Content(role: nil, parts: [Part(text: systemParts.joined(separator: "\n\n"), inlineData: nil)])

        var contents: [Content] = []
        for message in messages where message.role != .system {
            let role = message.role == .assistant ? "model" : "user"
            var parts: [Part] = []
            let text = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                parts.append(Part(text: text, inlineData: nil))
            }
            for image in message.images {
                parts.append(Part(
                    text: nil,
                    inlineData: InlineData(mimeType: image.mimeType, data: image.base64Data)
                ))
            }
            if parts.isEmpty {
                parts.append(Part(text: " ", inlineData: nil))
            }
            contents.append(Content(role: role, parts: parts))
        }

        guard !contents.isEmpty else {
            throw ProviderError.transport("Nothing to send to Gemini — empty conversation.")
        }

        let hasImages = messages.contains(where: \.hasImages)
        let body = GenerateRequest(
            contents: contents,
            systemInstruction: systemInstruction,
            generationConfig: GenerationConfig(
                maxOutputTokens: hasImages ? 2048 : 1024,
                temperature: nil
            )
        )

        // Build URL by hand so `:` in `models/{id}:generateContent` is not
        // percent-encoded by `appendingPathComponent`.
        let root = baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var components = URLComponents(string: "\(root)/models/\(model):generateContent")
        components?.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        guard let url = components?.url else {
            throw ProviderError.transport("Invalid Gemini request URL.")
        }

        let req = ProviderHTTP.post(
            url,
            headers: ["content-type": "application/json"],
            body: try JSONEncoder().encode(body)
        )
        let (data, response) = try await http.data(for: req)
        try ProviderHTTP.validate(data, response)

        do {
            let parsed = try JSONDecoder().decode(GenerateResponse.self, from: data)
            if let reason = parsed.promptFeedback?.blockReason, !reason.isEmpty {
                throw ProviderError.transport("Gemini blocked the prompt (\(reason)).")
            }
            let text = parsed.candidates?
                .compactMap { candidate in
                    candidate.content?.parts?.compactMap(\.text).joined()
                }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if text.isEmpty {
                throw ProviderError.transport("Gemini returned an empty response.")
            }
            return text
        } catch let error as ProviderError {
            throw error
        } catch {
            throw ProviderError.decoding(String(describing: error))
        }
    }
}
