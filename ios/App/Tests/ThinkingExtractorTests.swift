import XCTest
@testable import RoamSocket

final class ThinkingExtractorTests: XCTestCase {
    func testPairedThinkingTagReturnsBodyAndVisibleAnswer() {
        let result = ThinkingExtractor.extract(
            from: "<think>Plan the answer first.</think>\nThe full answer is here."
        )

        XCTAssertEqual(result.thinking, "Plan the answer first.")
        XCTAssertEqual(result.content, "The full answer is here.")
        XCTAssertFalse(result.isThinkingOpen)
    }

    func testOpenThinkingTagReturnsBodyAndPreservesEarlierAnswer() {
        let result = ThinkingExtractor.extract(
            from: "Visible prefix\n<think>Still reasoning"
        )

        XCTAssertEqual(result.thinking, "Still reasoning")
        XCTAssertEqual(result.content, "Visible prefix")
        XCTAssertTrue(result.isThinkingOpen)
    }

    func testNamespacedThinkingTagReturnsBodyAndVisibleAnswer() {
        let result = ThinkingExtractor.extract(
            from: "<antml:thinking>Check the image carefully.</antml:thinking>\nThe full answer is here."
        )

        XCTAssertEqual(result.thinking, "Check the image carefully.")
        XCTAssertEqual(result.content, "The full answer is here.")
        XCTAssertFalse(result.isThinkingOpen)
    }

    func testQwenTurnMarkersAreRemovedWithoutRemovingAnswer() {
        let result = ThinkingExtractor.extract(
            from: "<|im_start|>assistant\nA complete answer<|im_end|>"
        )

        XCTAssertEqual(result.content, "assistant\nA complete answer")
        XCTAssertFalse(result.content.contains("im_end"))
    }

    func testFamilySpecificToolCallWrappersAreRemoved() {
        let raw = """
        Answer before tool output.
        <|tool_call_start|>[lookup(query='swift')]<|tool_call_end|>
        """
        XCTAssertEqual(
            ThinkingExtractor.cleaned(raw),
            "Answer before tool output."
        )

        let gemma4 = "Answer. <|tool_call>call:lookup{query:<|\"|>swift<|\"|>}<tool_call|>"
        XCTAssertEqual(ThinkingExtractor.cleaned(gemma4), "Answer.")

        let gemma = "Answer. <start_function_call>call:lookup{query:swift}<end_function_call>"
        XCTAssertEqual(ThinkingExtractor.cleaned(gemma), "Answer.")
    }

    func testMistralToolCallOutputDoesNotLeakIntoVisibleText() {
        let result = ThinkingExtractor.cleaned(
            "Answer before call. [TOOL_CALLS]lookup [ARGS]{\"query\":\"swift\"}"
        )

        XCTAssertEqual(result, "Answer before call.")
    }

    func testReasoningAndTurnMarkersFromMultipleFamiliesAreCleaned() {
        let raw = """
        <think>Check the result.</think>
        <|start_header_id|>assistant<|end_header_id|>
        <start_of_turn>model
        Complete answer.<end_of_turn>
        <|end|>
        """
        XCTAssertEqual(ThinkingExtractor.plainVisibleText(from: raw), "assistant\nmodel\nComplete answer.")
    }
}
