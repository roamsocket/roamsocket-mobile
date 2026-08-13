import XCTest
import AnyProvCore
@testable import RoamSocket

/// Locks in the "vision is API-only" semantics in `VisionCapability`.
///
/// The chat composer calls `AppState.modelSupportsVision(_:)` to decide
/// whether the camera + gallery buttons are enabled. If this regresses,
/// the buttons come back on for on-device Metal models — which immediately
/// re-introduces the in-process MLX vision path and the OOM/jetsam risks
/// the team explicitly retired.
final class VisionGateTests: XCTestCase {

    func testOnDeviceMetalNeverSupportsVision() {
        // Even hub ids that look like a Vision model stay disabled.
        let visionHubIDs = [
            "gemma-4-e2b",
            "qwen3-vl-4b",
            "smolvlm2-256m",
            "lfm2.5-vl-1.6b",
        ]
        for id in visionHubIDs {
            let model = AIModel(
                provider: .localMetal,
                modelID: id,
                displayName: id,
                contextWindow: 8192
            )
            XCTAssertFalse(
                VisionCapability.supportsVision(model),
                "On-device Metal model \(id) must not be treated as vision-capable"
            )
        }
    }

    func testCloudVisionCapableModelsPass() {
        // Each canonical vision-capable cloud model id should be enabled.
        let cases: [(ProviderID, String)] = [
            (.anthropic, "claude-sonnet-4-5"),
            (.openai, "gpt-4o"),
            (.openai, "gpt-5"),
            (.google, "gemini-2.0-flash"),
            (.xai, "grok-4"),
            (.minimax, "minimax-m3"),
        ]
        for (provider, modelID) in cases {
            let model = AIModel(
                provider: provider,
                modelID: modelID,
                displayName: modelID,
                contextWindow: 128000
            )
            XCTAssertTrue(
                VisionCapability.supportsVision(model),
                "\(provider.displayName)/\(modelID) must be vision-capable"
            )
        }
    }

    func testTextOnlyModelsAreRejectedEvenFromVisionProviders() {
        // Embeddings, TTS, DALL-E, etc.
        let cases: [(ProviderID, String)] = [
            (.openai, "text-embedding-3-small"),
            (.openai, "whisper-1"),
            (.openai, "dall-e-3"),
            (.openai, "gpt-3.5-turbo-instruct"),
        ]
        for (provider, modelID) in cases {
            let model = AIModel(
                provider: provider,
                modelID: modelID,
                displayName: modelID,
                contextWindow: 8192
            )
            XCTAssertFalse(
                VisionCapability.supportsVision(model),
                "\(provider.displayName)/\(modelID) must remain text-only"
            )
        }
    }

    func testCustomProviderRequiresOptIn() {
        // Custom providers with `supportsVision = false` (the default) must
        // not enable vision from name heuristics alone — the user has to
        // turn the toggle on in Settings.
        let model = AIModel(
            provider: .custom(id: "my-ollama"),
            modelID: "llava-13b",
            displayName: "llava-13b",
            contextWindow: 4096
        )
        XCTAssertFalse(
            VisionCapability.supportsVision(model, providerMarkedVisionCapable: false),
            "Custom provider without the vision toggle must not enable vision"
        )
        XCTAssertTrue(
            VisionCapability.supportsVision(model, providerMarkedVisionCapable: true),
            "Custom provider with the vision toggle must opt every non-excluded model in"
        )
    }
}
