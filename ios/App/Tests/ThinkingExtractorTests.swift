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

    // MARK: - New providers (added in this revision)

    func testGrokReasoningTagReturnsBodyAndVisibleAnswer() {
        let result = ThinkingExtractor.extract(
            from: "<xai:reasoning>Inspect the call graph.</xai:reasoning>\nThe fix is in PR #42."
        )

        XCTAssertEqual(result.thinking, "Inspect the call graph.")
        XCTAssertEqual(result.content, "The fix is in PR #42.")
    }

    func testGrokReasoningTagUnclosedIsTreatedAsOpen() {
        let result = ThinkingExtractor.extract(
            from: "Lead in\n<xai:reasoning>still working on it"
        )

        XCTAssertEqual(result.thinking, "still working on it")
        XCTAssertEqual(result.content, "Lead in")
        XCTAssertTrue(result.isThinkingOpen)
    }

    func testLlama31ReasoningSpecialTokensAreStripped() {
        // The block pattern matches the well-formed pair and drops
        // the whole reasoning section (body + wrappers) so the body
        // doesn't surface as plain text in the chat bubble.
        let raw = """
        <|reasoning|>let me check the docs first<|/reasoning|>
        The answer is documented in section 4.
        """
        let result = ThinkingExtractor.extract(from: raw)
        XCTAssertEqual(result.content, "The answer is documented in section 4.")
        XCTAssertNil(result.thinking)
    }

    func testLlama31UnclosedReasoningTokenIsHandledGracefully() {
        // When the model emits just the opener (still streaming, or
        // truncated), the block pattern misses and the individual
        // token strip kicks in: the `<|reasoning|>` token is removed
        // and the body becomes part of the visible content. This is
        // a known limitation — we'd rather show the body than leak
        // the marker, but the visible content is no longer flagged
        // as reasoning.
        let raw = "Lead in\n<|reasoning|>still working on it"
        let result = ThinkingExtractor.cleaned(raw)
        XCTAssertFalse(result.contains("<|reasoning|>"))
        XCTAssertTrue(result.contains("still working on it"))
    }

    func testLlama2SystemBlockIsStrippedEntirely() {
        let raw = """
        <<SYS>>You are a helpful assistant. Be concise.<</SYS>>
        The short answer is 42.
        """
        XCTAssertEqual(
            ThinkingExtractor.cleaned(raw),
            "The short answer is 42."
        )
    }

    func testChatGLMOutputWrapperIsStripped() {
        let raw = "<output>The final answer is 42.</output>"
        XCTAssertEqual(ThinkingExtractor.cleaned(raw), "The final answer is 42.")
    }

    func testHTMLCommentReasoningLeakIsStripped() {
        let raw = """
        <!-- I should think about this more carefully -->
        The answer is 42.
        """
        XCTAssertEqual(
            ThinkingExtractor.cleaned(raw),
            "The answer is 42."
        )
    }

    func testAnthropicInvokeWrapperIsStripped() {
        let raw = """
        Let me look that up.
        <antml:invoke name="search">
        <query>swift regex</query>
        </antml:invoke>
        Here's what I found.
        """
        XCTAssertEqual(
            ThinkingExtractor.cleaned(raw),
            "Let me look that up.\n\nHere's what I found."
        )
    }

    func testXAIToolCallsPluralWrapperIsStripped() {
        let raw = """
        I'll search for that.
        <xai:tool_calls>
        <invoke name="search"><query>swift regex</query></invoke>
        </xai:tool_calls>
        Here you go.
        """
        XCTAssertEqual(
            ThinkingExtractor.cleaned(raw),
            "I'll search for that.\n\nHere you go."
        )
    }

    func testLlamaEndOfSentenceTokenIsStripped() {
        let raw = "Here's the answer.</s>"
        XCTAssertEqual(ThinkingExtractor.cleaned(raw), "Here's the answer.")
    }

    func testSystemPromptLeakMarkerIsStripped() {
        let raw = """
        [SYSTEM_PROMPT]You are a helpful assistant. Be concise.

        The actual answer is 42.
        """
        XCTAssertTrue(ThinkingExtractor.cleaned(raw).contains("The actual answer is 42."))
        XCTAssertFalse(ThinkingExtractor.cleaned(raw).contains("[SYSTEM_PROMPT]"))
    }

    func testUserCodeIsNotMistakenForSystemPrompt() {
        // A real system-prompt leak starts with `[SYSTEM_PROMPT]` —
        // a code-fenced example containing that literal should be
        // preserved.
        let raw = """
        Here is how to detect a leak:

        ```
        [SYSTEM_PROMPT]You are helpful.
        ```

        That's the pattern.
        """
        let cleaned = ThinkingExtractor.cleaned(raw)
        XCTAssertTrue(cleaned.contains("[SYSTEM_PROMPT]You are helpful."))
    }

    func testQwenVisionBoxTokensAreStripped() {
        let raw = "<|box_start|>image_pad<|box_end|>\nThe image shows a cat."
        XCTAssertEqual(
            ThinkingExtractor.cleaned(raw),
            "\nThe image shows a cat."
        )
    }

    func testAllNewReasoningTagShapesAreRecognised() {
        // Regression: every tag name we added to the alternation
        // should be picked up by the same paired pattern.
        let cases: [(String, String)] = [
            ("<think>x</think>", "x"),
            ("<xai:reasoning>x</xai:reasoning>", "x"),
            ("<xai:thinking>x</xai:thinking>", "x"),
            ("<antml:thinking>x</antml:thinking>", "x"),
            ("<scratch_pad>x</scratch_pad>", "x"),
        ]
        for (raw, expected) in cases {
            let r = ThinkingExtractor.extract(from: raw)
            XCTAssertEqual(r.thinking, expected, "raw: \(raw)")
            XCTAssertTrue(r.content.isEmpty, "raw: \(raw) -> \(r.content)")
        }
    }
}
