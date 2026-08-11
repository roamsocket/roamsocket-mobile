import XCTest
@testable import AnyProvCore

final class LocalMetalCrashStoreTests: XCTestCase {
    private let store = LocalMetalCrashStore()

    override func setUp() async throws {
        try await super.setUp()
        await store.removeAll()
    }

    override func tearDown() async throws {
        await store.removeAll()
        try await super.tearDown()
    }

    func testRecordPersistsPendingReport() async {
        await store.record(
            modelID: "lmstudio-community/Qwen3-1.7B-MLX-4bit",
            displayName: "Qwen 3 1.7B",
            error: "Metal command buffer failed"
        )
        let pending = await store.pendingRecords()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.modelID, "lmstudio-community/Qwen3-1.7B-MLX-4bit")
        XCTAssertEqual(pending.first?.displayName, "Qwen 3 1.7B")
        XCTAssertNotNil(pending.first?.timestamp)
    }

    func testRecordReplacesEarlierReportForSameModel() async {
        await store.record(
            modelID: "mlx-community/gemma-4-e2b-it-4bit",
            displayName: "Gemma 4 E2B",
            error: "first crash"
        )
        await store.record(
            modelID: "mlx-community/gemma-4-e2b-it-4bit",
            displayName: "Gemma 4 E2B",
            error: "second crash"
        )
        let pending = await store.pendingRecords()
        XCTAssertEqual(pending.count, 1)
        XCTAssertTrue(pending.first?.logText.contains("second crash") == true)
    }

    func testKeepsReportsForDifferentModels() async {
        await store.record(
            modelID: "lmstudio-community/Qwen3-1.7B-MLX-4bit",
            displayName: "Qwen 3 1.7B",
            error: "crash A"
        )
        await store.record(
            modelID: "mlx-community/gemma-4-e2b-it-4bit",
            displayName: "Gemma 4 E2B",
            error: "crash B"
        )
        let pending = await store.pendingRecords()
        XCTAssertEqual(pending.count, 2)
        // Newest first.
        XCTAssertEqual(pending.first?.modelID, "mlx-community/gemma-4-e2b-it-4bit")
    }

    func testRemoveClearsOnlyTheRequestedReport() async {
        await store.record(
            modelID: "lmstudio-community/Qwen3-1.7B-MLX-4bit",
            displayName: "Qwen 3 1.7B",
            error: "crash A"
        )
        await store.record(
            modelID: "mlx-community/gemma-4-e2b-it-4bit",
            displayName: "Gemma 4 E2B",
            error: "crash B"
        )
        let pending = await store.pendingRecords()
        guard let newest = pending.first else {
            return XCTFail("expected a pending report")
        }
        await store.remove(id: newest.id)
        let remaining = await store.pendingRecords()
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.modelID, "lmstudio-community/Qwen3-1.7B-MLX-4bit")
    }

    func testLogTextContainsCopyableContext() async {
        await store.record(
            modelID: "mlx-community/Phi-4-mini-reasoning-4bit",
            displayName: "Phi 4 Mini Reasoning",
            error: "GPU allocation failed"
        )
        let pending = await store.pendingRecords()
        guard let log = pending.first?.logText else {
            return XCTFail("expected a log text")
        }
        XCTAssertTrue(log.contains("Phi 4 Mini Reasoning"))
        XCTAssertTrue(log.contains("mlx-community/Phi-4-mini-reasoning-4bit"))
        XCTAssertTrue(log.contains("GPU allocation failed"))
    }

    func testRemoveAllClearsEverything() async {
        await store.record(
            modelID: "lmstudio-community/Qwen3-1.7B-MLX-4bit",
            displayName: "Qwen 3 1.7B",
            error: "crash A"
        )
        await store.removeAll()
        let pending = await store.pendingRecords()
        XCTAssertTrue(pending.isEmpty)
    }
}
