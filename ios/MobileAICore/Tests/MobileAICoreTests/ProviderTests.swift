import XCTest
@testable import MobileAICore

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

    func testCustomProviderHitsBaseURL() async throws {
        let http = MockHTTPClient(routes: [(
            match: "proxy.example.com/v1/models",
            status: 200,
            body: json(#"{"data":[{"id":"llama-3.3-70b","context_length":131072}]}"#)
        )])
        let provider: ProviderID = .custom("internal")
        let url = URL(string: "https://proxy.example.com/v1")!
        let models = try await OpenAICompatibleProvider(
            id: provider, http: http, baseURLOverride: url
        ).listModels(apiKey: "x")
        XCTAssertEqual(models.count, 1)
        XCTAssertEqual(models[0].modelID, "llama-3.3-70b")
        XCTAssertEqual(models[0].provider, provider)
    }

    func testCustomProviderIDRoundTrips() throws {
        let original: ProviderID = .custom("internal")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ProviderID.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.rawValue, "custom:internal")
    }

    func testCustomProviderIDAcceptsBareSlug() throws {
        // Defensive: a server pre-fix might send a bare slug without the
        // `custom:` prefix; still parse it as a custom provider.
        let data = Data("\"legacy-slug\"".utf8)
        let decoded = try JSONDecoder().decode(ProviderID.self, from: data)
        XCTAssertEqual(decoded, .custom("legacy-slug"))
    }
}
