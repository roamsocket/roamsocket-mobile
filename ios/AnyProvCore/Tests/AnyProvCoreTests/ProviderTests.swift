import XCTest
@testable import AnyProvCore

final class ProviderTests: XCTestCase {
    func testAnthropicParsesModels() async throws {
        let http = MockHTTPClient(routes: [(
            match: "api.anthropic.com/v1/models",
            status: 200,
            body: json(#"{"data":[{"id":"claude-sonnet-4","display_name":"Claude Sonnet 4"},{"id":"claude-opus-4"}]}"#)
        )])
        let models = try await AnthropicProvider(http: http).listModels(apiKey: "sk-test")
        XCTAssertEqual(models.count, 2)
        XCTAssertEqual(models[0].modelID, "claude-sonnet-4")
        XCTAssertEqual(models[0].displayName, "Claude Sonnet 4")
        XCTAssertEqual(models[1].displayName, "claude-opus-4") // falls back to id
        XCTAssertEqual(models[0].provider, .anthropic)
    }

    func testOpenAICompatibleParsesModels() async throws {
        let http = MockHTTPClient(routes: [(
            match: "api.groq.com/openai/v1/models",
            status: 200,
            body: json(#"{"data":[{"id":"llama-3.3-70b","context_window":131072}]}"#)
        )])
        let models = try await OpenAICompatibleProvider(id: .groq, http: http).listModels(apiKey: "gsk-test")
        XCTAssertEqual(models.count, 1)
        XCTAssertEqual(models[0].modelID, "llama-3.3-70b")
        XCTAssertEqual(models[0].contextWindow, 131072)
        XCTAssertEqual(models[0].provider, .groq)
    }

    func testGoogleFiltersToGenerateContent() async throws {
        let http = MockHTTPClient(routes: [(
            match: "generativelanguage.googleapis.com",
            status: 200,
            body: json(#"""
            {"models":[
              {"name":"models/gemini-1.5-pro","displayName":"Gemini 1.5 Pro","inputTokenLimit":2000000,"supportedGenerationMethods":["generateContent"]},
              {"name":"models/embedding-001","supportedGenerationMethods":["embedContent"]}
            ]}
            """#)
        )])
        let models = try await GoogleProvider(http: http).listModels(apiKey: "AIza-test")
        XCTAssertEqual(models.count, 1)
        XCTAssertEqual(models[0].modelID, "gemini-1.5-pro")
        XCTAssertEqual(models[0].contextWindow, 2000000)
    }

    func testGoogleChatGenerateContent() async throws {
        final class CapturingHTTP: HTTPClient, @unchecked Sendable {
            var lastURL: String?
            var lastBody: Data?
            func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                lastURL = request.url?.absoluteString
                lastBody = request.httpBody
                let payload = #"""
                {"candidates":[{"content":{"parts":[{"text":"Hello from Gemini"}]}}]}
                """#
                let resp = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (Data(payload.utf8), resp)
            }
        }
        let http = CapturingHTTP()
        let provider = GoogleProvider(http: http)
        let reply = try await provider.chat(
            model: "gemini-2.0-flash",
            apiKey: "AIza-test",
            messages: [
                ProviderChatMessage(role: .system, content: "Be brief."),
                ProviderChatMessage(role: .user, content: "Hi"),
            ],
            effort: nil
        )
        XCTAssertEqual(reply, "Hello from Gemini")
        let url = try XCTUnwrap(http.lastURL)
        XCTAssertTrue(url.contains("models/gemini-2.0-flash:generateContent"), url)
        XCTAssertTrue(url.contains("key=AIza-test"), url)
        let body = try XCTUnwrap(http.lastBody)
        let json = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        let contents = json["contents"] as! [[String: Any]]
        XCTAssertEqual(contents.count, 1)
        XCTAssertEqual(contents[0]["role"] as? String, "user")
        let sys = json["system_instruction"] as! [String: Any]
        let sysParts = sys["parts"] as! [[String: Any]]
        XCTAssertEqual(sysParts[0]["text"] as? String, "Be brief.")
    }

    func testMissingKeyThrows() async {
        do {
            _ = try await AnthropicProvider(http: MockHTTPClient(routes: [])).listModels(apiKey: "")
            XCTFail("expected missingKey")
        } catch {
            XCTAssertEqual(error as? ProviderError, .missingKey)
        }
    }

    func testHTTPErrorSurfacesStatus() async {
        let http = MockHTTPClient(routes: [(
            match: "api.openai.com", status: 401, body: json(#"{"error":"bad key"}"#)
        )])
        do {
            _ = try await OpenAICompatibleProvider(id: .openai, http: http).listModels(apiKey: "x")
            XCTFail("expected http error")
        } catch let ProviderError.http(status, _) {
            XCTAssertEqual(status, 401)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testCatalogFanOutCapturesPerProviderErrors() async {
        let http = MockHTTPClient(routes: [
            (match: "api.anthropic.com", status: 200, body: json(#"{"data":[{"id":"claude-x"}]}"#)),
            (match: "api.openai.com", status: 500, body: json("boom")),
        ])
        let results = await ModelCatalog(http: http).fetchAll(keys: [
            .anthropic: "a", .openai: "b",
        ])
        // +2 for always-listed on-device chat providers (Metal + Apple Intelligence).
        XCTAssertEqual(results.count, 4)
        let anthropic = results.first { $0.provider == .anthropic }!
        let openai = results.first { $0.provider == .openai }!
        XCTAssertEqual(anthropic.models.count, 1)
        XCTAssertNil(anthropic.error)
        XCTAssertTrue(openai.models.isEmpty)
        XCTAssertNotNil(openai.error)
        XCTAssertNotNil(results.first { $0.provider == .localMetal })
        XCTAssertNotNil(results.first { $0.provider == .appleFoundation })
    }

    func testAppleFoundationProviderIDRoundTrips() throws {
        let id = ProviderID.appleFoundation
        XCTAssertEqual(id.rawValue, "apple-foundation")
        XCTAssertEqual(ProviderID(rawValue: "apple"), .appleFoundation)
        XCTAssertEqual(ProviderID(rawValue: "apple-intelligence"), .appleFoundation)
        XCTAssertFalse(id.requiresAPIKey)
        XCTAssertFalse(id.supportsCodingAgent)

        let data = try JSONEncoder().encode(id)
        let decoded = try JSONDecoder().decode(ProviderID.self, from: data)
        XCTAssertEqual(decoded, .appleFoundation)
    }

    func testLocalMetalSupportsCodingAgentAndWireAliases() throws {
        let id = ProviderID.localMetal
        XCTAssertEqual(id.rawValue, "local-metal")
        XCTAssertEqual(ProviderID(rawValue: "localMetal"), .localMetal)
        XCTAssertEqual(ProviderID(rawValue: "metal"), .localMetal)
        XCTAssertFalse(id.requiresAPIKey)
        // Desktop-installed Metal can drive coding; phone weights are filtered in UI.
        XCTAssertTrue(id.supportsCodingAgent)
    }

    func testDesktopMetalModelMapsToAIModel() {
        let m = DesktopMetalModel(hubID: "mlx-community/foo", displayName: "Foo", downloadedAt: 1)
        let ai = m.asAIModel()
        XCTAssertEqual(ai.provider, .localMetal)
        XCTAssertEqual(ai.modelID, "mlx-community/foo")
        XCTAssertTrue(ai.displayName.contains("Desktop"))
    }

    func testCustomProviderIDDoesNotCollapseToOpenAI() throws {
        let id = ProviderID.custom("ollama")
        XCTAssertEqual(id.rawValue, "custom:ollama")
        XCTAssertNotEqual(id, .openai)
        XCTAssertEqual(id.customSlug, "ollama")

        let data = try JSONEncoder().encode(id)
        let decoded = try JSONDecoder().decode(ProviderID.self, from: data)
        XCTAssertEqual(decoded, .custom("ollama"))
        XCTAssertNotEqual(decoded, .openai)
    }

    func testCustomProviderSupportsVisionRoundTripAndDefault() throws {
        let legacy = #"{"id":"ollama","label":"Ollama","baseURL":"http://localhost:11434/v1"}"#.data(using: .utf8)!
        let decodedLegacy = try JSONDecoder().decode(CustomProvider.self, from: legacy)
        XCTAssertFalse(decodedLegacy.supportsVision)

        let withVision = CustomProvider(
            id: "vlm-proxy",
            label: "VLM Proxy",
            baseURL: "https://example.com/v1",
            style: .openAI,
            supportsVision: true
        )
        let data = try JSONEncoder().encode(withVision)
        let decoded = try JSONDecoder().decode(CustomProvider.self, from: data)
        XCTAssertTrue(decoded.supportsVision)
        XCTAssertEqual(decoded.id, "vlm-proxy")
    }

    func testCustomOpenAICompatibleListsAgainstBaseURL() async throws {
        let http = MockHTTPClient(routes: [(
            match: "127.0.0.1:11434/v1/models",
            status: 200,
            body: json(#"{"data":[{"id":"llama3.2"}]}"#)
        )])
        let custom = ProviderID.custom("ollama")
        let base = URL(string: "http://127.0.0.1:11434/v1")!
        let models = try await OpenAICompatibleProvider(
            id: custom,
            http: http,
            baseURL: base
        ).listModels(apiKey: "local")
        XCTAssertEqual(models.count, 1)
        XCTAssertEqual(models[0].provider, custom)
        XCTAssertEqual(models[0].modelID, "llama3.2")
    }

    func testCatalogRoutesCustomToBaseURLNotOpenAI() async {
        let http = MockHTTPClient(routes: [
            (match: "127.0.0.1:9999/v1/models", status: 200, body: json(#"{"data":[{"id":"proxy-model"}]}"#)),
            (match: "api.openai.com", status: 500, body: json("should-not-hit")),
        ])
        let custom = ProviderID.custom("my-proxy")
        let results = await ModelCatalog(http: http).fetchAll(
            keys: [custom: "sk-proxy"],
            customBaseURLs: [custom: URL(string: "http://127.0.0.1:9999/v1")!],
            styles: [custom: .openAI]
        )
        // custom + always-listed on-device providers (Metal + Apple Intelligence)
        XCTAssertEqual(results.count, 3)
        let customResult = results.first { $0.provider == custom }!
        XCTAssertEqual(customResult.models.map(\.modelID), ["proxy-model"])
        XCTAssertNil(customResult.error)
        XCTAssertNotNil(results.first { $0.provider == .localMetal })
        XCTAssertNotNil(results.first { $0.provider == .appleFoundation })
    }

    func testOpenAICompatibleEncodesVisionImageParts() async throws {
        final class CapturingHTTP: HTTPClient, @unchecked Sendable {
            var lastBody: Data?
            func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                lastBody = request.httpBody
                let payload = #"{"choices":[{"message":{"role":"assistant","content":"A red cup."}}]}"#
                let resp = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (Data(payload.utf8), resp)
            }
        }
        let http = CapturingHTTP()
        let provider = OpenAICompatibleProvider(id: .openai, http: http)
        let image = ProviderChatMessage.ImageAttachment(
            mimeType: "image/jpeg",
            base64Data: "abc123"
        )
        let reply = try await provider.chat(
            model: "gpt-4o",
            apiKey: "sk-test",
            messages: [
                ProviderChatMessage(role: .user, content: "What is this?", images: [image]),
            ],
            effort: nil
        )
        XCTAssertEqual(reply, "A red cup.")
        let body = try XCTUnwrap(http.lastBody)
        let json = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        let messages = json["messages"] as! [[String: Any]]
        let content = messages[0]["content"] as! [[String: Any]]
        XCTAssertEqual(content.count, 2)
        XCTAssertEqual(content[0]["type"] as? String, "text")
        XCTAssertEqual(content[0]["text"] as? String, "What is this?")
        XCTAssertEqual(content[1]["type"] as? String, "image_url")
        let imageURL = content[1]["image_url"] as! [String: Any]
        XCTAssertEqual(imageURL["url"] as? String, "data:image/jpeg;base64,abc123")
    }

    func testAnthropicEncodesVisionImageBlocks() async throws {
        final class CapturingHTTP: HTTPClient, @unchecked Sendable {
            var lastBody: Data?
            func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                lastBody = request.httpBody
                let payload = #"{"content":[{"type":"text","text":"A blue book."}]}"#
                let resp = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (Data(payload.utf8), resp)
            }
        }
        let http = CapturingHTTP()
        let provider = AnthropicProvider(http: http)
        let image = ProviderChatMessage.ImageAttachment(
            mimeType: "image/png",
            base64Data: "pngdata"
        )
        let reply = try await provider.chat(
            model: "claude-sonnet-4",
            apiKey: "sk-ant",
            messages: [
                ProviderChatMessage(role: .user, content: "Describe", images: [image]),
            ],
            effort: nil
        )
        XCTAssertEqual(reply, "A blue book.")
        let body = try XCTUnwrap(http.lastBody)
        let json = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        let messages = json["messages"] as! [[String: Any]]
        let content = messages[0]["content"] as! [[String: Any]]
        XCTAssertEqual(content[0]["type"] as? String, "image")
        let source = content[0]["source"] as! [String: Any]
        XCTAssertEqual(source["type"] as? String, "base64")
        XCTAssertEqual(source["media_type"] as? String, "image/png")
        XCTAssertEqual(source["data"] as? String, "pngdata")
        XCTAssertEqual(content[1]["type"] as? String, "text")
        XCTAssertEqual(content[1]["text"] as? String, "Describe")
    }

    func testModelSelectionEncodesBaseUrlAndApiStyle() throws {
        let sel = ModelSelection(
            provider: .custom("ollama"),
            model: "llama3.2",
            effort: .medium,
            apiKey: "local",
            baseURL: "http://127.0.0.1:11434/v1",
            apiStyle: .openAI
        )
        let data = try JSONEncoder().encode(sel)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(obj["provider"] as? String, "custom:ollama")
        XCTAssertEqual(obj["baseUrl"] as? String, "http://127.0.0.1:11434/v1")
        XCTAssertEqual(obj["apiStyle"] as? String, "openai")
        XCTAssertEqual(obj["model"] as? String, "llama3.2")
    }
}
