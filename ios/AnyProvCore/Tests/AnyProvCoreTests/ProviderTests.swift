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
        XCTAssertEqual(results.count, 2)
        let anthropic = results.first { $0.provider == .anthropic }!
        let openai = results.first { $0.provider == .openai }!
        XCTAssertEqual(anthropic.models.count, 1)
        XCTAssertNil(anthropic.error)
        XCTAssertTrue(openai.models.isEmpty)
        XCTAssertNotNil(openai.error)
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
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].provider, custom)
        XCTAssertEqual(results[0].models.map(\.modelID), ["proxy-model"])
        XCTAssertNil(results[0].error)
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
