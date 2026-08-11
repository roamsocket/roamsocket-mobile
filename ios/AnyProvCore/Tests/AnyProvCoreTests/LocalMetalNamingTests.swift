import XCTest
@testable import AnyProvCore

final class LocalMetalNamingTests: XCTestCase {
    func testPrettyNameHumanizesHubIDs() {
        let cases: [(String, String)] = [
            ("lmstudio-community/Qwen3-1.7B-MLX-4bit", "Qwen 3 1.7B"),
            ("lmstudio-community/Qwen3-0.6B-MLX-4bit", "Qwen 3 0.6B"),
            ("lmstudio-community/Qwen3-4B-Instruct-MLX-4bit", "Qwen 3 4B Instruct"),
            ("lmstudio-community/Qwen2.5-Coder-1.5B-Instruct-MLX-4bit", "Qwen 2.5 Coder 1.5B Instruct"),
            ("mlx-community/Meta-Llama-3.2-1B-Instruct-4bit", "Llama 3.2 1B Instruct"),
            ("mlx-community/Phi-4-mini-reasoning-4bit", "Phi 4 Mini Reasoning"),
            ("local/Qwen3-1.7B-MLX-4bit", "Qwen 3 1.7B"),
        ]
        for (hub, expected) in cases {
            XCTAssertEqual(
                LocalMetalCatalog.prettyName(from: hub),
                expected,
                "hub \(hub)"
            )
        }
    }

    func testDisplayNameUsesRecommendedHandNames() {
        let hub = "lmstudio-community/LFM2.5-1.2B-Instruct-MLX-4bit"
        XCTAssertEqual(LocalMetalCatalog.displayName(for: hub), "LFM2.5 1.2B")
    }

    func testDisplayNameNeverReturnsRawCodeName() {
        let hub = "lmstudio-community/Qwen3-4B-Thinking-2507-MLX-4bit"
        let name = LocalMetalCatalog.displayName(for: hub)
        XCTAssertFalse(name.lowercased().contains("mlx"))
        XCTAssertFalse(name.lowercased().contains("4bit"))
        XCTAssertFalse(name.contains("-"))
        XCTAssertTrue(name.localizedCaseInsensitiveContains("Qwen"))
        XCTAssertTrue(name.localizedCaseInsensitiveContains("Thinking"))
    }

    // MARK: - Legacy size tokens (must not treat 1.7B as 7B)

    func testLegacySizeDoesNotMatchDecimalBillions() {
        let phoneFriendly = [
            "lmstudio-community/Qwen3-1.7B-MLX-4bit",
            "lmstudio-community/Qwen2.5-0.5B-Instruct-MLX-4bit",
            "lmstudio-community/LFM2.5-1.2B-Instruct-MLX-4bit",
            "lmstudio-community/Qwen3-0.6B-MLX-4bit",
            "mlx-community/SmolLM-135M-Instruct-4bit",
        ]
        for hub in phoneFriendly {
            XCTAssertFalse(
                LocalMetalCatalogEntry.matchesLegacyParameterSize(hub),
                "should not be legacy: \(hub)"
            )
        }
    }

    func testLegacySizeMatchesWholeParameterTokens() {
        let large = [
            "mlx-community/Mistral-7B-Instruct-v0.3-4bit",
            "mlx-community/Meta-Llama-3-8B-Instruct-4bit",
            "mlx-community/Qwen2.5-14B-Instruct-4bit",
            "mlx-community/Mixtral-8x7B-Instruct-v0.1-4bit",
            "some-org/model-70B-Instruct-4bit",
        ]
        for hub in large {
            XCTAssertTrue(
                LocalMetalCatalogEntry.matchesLegacyParameterSize(hub),
                "should be legacy: \(hub)"
            )
        }
    }

    // MARK: - Family naming

    func testNemotronIsNotClassifiedAsMistral() {
        let hub = "mlx-community/Nemotron-Labs-Diffusion-3B-4bit"
        XCTAssertEqual(LocalMetalCatalogEntry.familyName(for: hub), "Nemotron")
        // Entry section helpers use the same familyName path.
        let entry = LocalMetalCatalogEntry(
            hubID: hub,
            displayName: "Nemotron 3B",
            source: .mlxSwiftRegistry
        )
        XCTAssertEqual(entry.family, "Nemotron")
    }

    func testMistralNemoStillMapsToMistral() {
        let hub = "mlx-community/Mistral-Nemo-Instruct-2407-4bit"
        XCTAssertEqual(LocalMetalCatalogEntry.familyName(for: hub), "Mistral")
    }

    // MARK: - Hub folder parsing

    func testHubIDFromRepoFolder() {
        XCTAssertEqual(
            LocalMetalModelStore.hubID(fromRepoFolder: "models--lmstudio-community--Qwen3-1.7B-MLX-4bit"),
            "lmstudio-community/Qwen3-1.7B-MLX-4bit"
        )
        XCTAssertEqual(
            LocalMetalModelStore.hubID(fromRepoFolder: "models--mlx-community--Meta-Llama-3.2-1B-Instruct-4bit"),
            "mlx-community/Meta-Llama-3.2-1B-Instruct-4bit"
        )
        XCTAssertNil(LocalMetalModelStore.hubID(fromRepoFolder: "not-a-repo"))
    }

    // MARK: - Vision hub detection (Vision mode + MLXVLM load path)

    func testLikelyVisionHubIDsMatchCatalogVisionModels() {
        let visionHubs = [
            "mlx-community/gemma-4-e2b-it-4bit",
            "mlx-community/gemma-4-e4b-it-4bit",
            "mlx-community/Qwen3-VL-2B-Instruct-4bit",
            "mlx-community/Qwen2.5-VL-3B-Instruct-4bit",
            "mlx-community/LFM2.5-VL-1.6B-4bit",
            "mlx-community/SmolVLM2-500M-Video-Instruct-mlx",
            "mlx-community/PaddleOCR-VL-1.5-bf16",
            "mlx-community/gemma-3-4b-it-qat-4bit",
        ]
        for hub in visionHubs {
            XCTAssertTrue(
                LocalMetalCatalog.isLikelyVisionHubID(hub),
                "expected vision: \(hub)"
            )
            XCTAssertTrue(
                LocalMetalCatalog.isCatalogVisionModel(hubID: hub),
                "catalog should tag vision: \(hub)"
            )
        }
    }

    func testTextOnlyHubsAreNotVision() {
        let textHubs = [
            "mlx-community/Qwen3-1.7B-4bit",
            "lmstudio-community/Qwen3-0.6B-MLX-4bit",
            "mlx-community/gemma-3n-E4B-it-lm-4bit",
            "mlx-community/Llama-3.2-1B-Instruct-4bit",
            "mlx-community/SmolLM-135M-Instruct-4bit",
        ]
        for hub in textHubs {
            XCTAssertFalse(
                LocalMetalCatalog.isLikelyVisionHubID(hub),
                "expected text-only: \(hub)"
            )
        }
    }

    func testCanonicalAndLegacyPathRootsDiffer() {
        XCTAssertEqual(LocalMetalPaths.relativeRoot, "RoamSocket/LocalModels")
        XCTAssertEqual(LocalMetalPaths.legacyRelativeRoot, "AnyProvCode/LocalModels")
        XCTAssertNotEqual(LocalMetalPaths.relativeRoot, LocalMetalPaths.legacyRelativeRoot)
    }

    // MARK: - Download completeness

    func testHasUsableModelCacheRequiresConfigAndWeights() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("apc-cache-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        // Empty dir
        XCTAssertFalse(LocalMetalModelStore.hasUsableModelCache(at: root))

        // Config only
        try " {}".write(to: root.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        XCTAssertFalse(LocalMetalModelStore.hasUsableModelCache(at: root))

        // Index JSON alone is not a weight
        try "{}".write(
            to: root.appendingPathComponent("model.safetensors.index.json"),
            atomically: true,
            encoding: .utf8
        )
        XCTAssertFalse(LocalMetalModelStore.hasUsableModelCache(at: root))

        // Real weight shard
        try Data([0x00, 0x01]).write(to: root.appendingPathComponent("model.safetensors"))
        XCTAssertTrue(LocalMetalModelStore.hasUsableModelCache(at: root))
    }

    func testHasUsableModelCacheAcceptsSnapshotLayout() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("apc-snap-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let rev = root
            .appendingPathComponent("snapshots", isDirectory: true)
            .appendingPathComponent("main", isDirectory: true)
        try FileManager.default.createDirectory(at: rev, withIntermediateDirectories: true)

        // Blobs + empty snapshot is not enough
        let blobs = root.appendingPathComponent("blobs", isDirectory: true)
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 500_000).write(to: blobs.appendingPathComponent("abc123"))
        XCTAssertFalse(LocalMetalModelStore.hasUsableModelCache(at: root))

        try "{}".write(to: rev.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        try Data([0x00]).write(to: rev.appendingPathComponent("model.safetensors"))

        // Snapshot layouts now require the verified sentinel.
        XCTAssertFalse(LocalMetalModelStore.hasUsableModelCache(at: root))
        LocalMetalModelStore.touchVerifiedSentinel(at: root)
        XCTAssertTrue(LocalMetalModelStore.hasUsableModelCache(at: root))
    }
}
