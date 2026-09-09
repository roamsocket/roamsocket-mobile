import XCTest
@testable import RoamSocket

/// Tests for `FollowUpExtractor` — the parser that pulls follow-up
/// suggestion markers (`[SUGGEST: …]`, `<suggest>…</suggest>`, and
/// "Next steps:" numbered lists) out of an assistant message and turns
/// them into a chip row.
///
/// Mirrors the contract the chat composer and the E2B session both
/// depend on. The matching Android tests live in
/// `android/app/src/test/.../FollowUpExtractorTest.kt`.
final class FollowUpExtractorTests: XCTestCase {

    // MARK: - Bracket form

    func testEmptyInputProducesNoSuggestions() {
        let result = FollowUpExtractor.extract(from: "")
        XCTAssertEqual(result.content, "")
        XCTAssertEqual(result.suggestions, [])
        XCTAssertFalse(result.hasSuggestions)
    }

    func testInputWithoutMarkerIsUnchanged() {
        let raw = "Here is a normal assistant reply with no suggestions."
        let result = FollowUpExtractor.extract(from: raw)
        XCTAssertEqual(result.content, raw)
        XCTAssertEqual(result.suggestions, [])
    }

    func testSingleBracketMarkerYieldsSuggestions() {
        let raw = "Some prose before. [SUGGEST: shorter follow-up | a different angle | a code example] And prose after."
        let result = FollowUpExtractor.extract(from: raw)
        XCTAssertEqual(result.suggestions, ["shorter follow-up", "a different angle", "a code example"])
        XCTAssertFalse(result.content.contains("[SUGGEST:"))
        XCTAssertTrue(result.content.contains("Some prose before."))
        XCTAssertTrue(result.content.contains("And prose after."))
    }

    func testBracketKeywordIsCaseInsensitive() {
        let result = FollowUpExtractor.extract(from: "hi [suggest: A | B] bye")
        XCTAssertEqual(result.suggestions, ["A", "B"])
    }

    func testMultipleBracketMarkersAreMerged() {
        let raw = "[SUGGEST: one | two] middle [SUGGEST: three] tail"
        let result = FollowUpExtractor.extract(from: raw)
        XCTAssertEqual(result.suggestions, ["one", "two", "three"])
        XCTAssertFalse(result.content.contains("[SUGGEST:"))
    }

    func testEmptyBracketLabelsAreDropped() {
        let raw = "[SUGGEST: a |  | b |   | c]"
        let result = FollowUpExtractor.extract(from: raw)
        XCTAssertEqual(result.suggestions, ["a", "b", "c"])
    }

    func testLongBracketLabelIsTruncated() {
        let long = String(repeating: "x", count: FollowUpExtractor.maxLabelLength + 50)
        let raw = "[SUGGEST: \(long)]"
        let result = FollowUpExtractor.extract(from: raw)
        XCTAssertEqual(result.suggestions.count, 1)
        XCTAssertLessThanOrEqual(result.suggestions[0].count, FollowUpExtractor.maxLabelLength)
        XCTAssertTrue(result.suggestions[0].hasSuffix("…"))
    }

    func testBracketMarkerAtStartAndEndOfMessage() {
        let start = FollowUpExtractor.extract(from: "[SUGGEST: only] rest of message")
        XCTAssertEqual(start.suggestions, ["only"])
        XCTAssertTrue(start.content.hasPrefix("rest of message"))

        let end = FollowUpExtractor.extract(from: "intro [SUGGEST: only]")
        XCTAssertEqual(end.suggestions, ["only"])
        XCTAssertTrue(end.content.hasPrefix("intro"))
    }

    func testBracketMarkerOnlyMessage() {
        let raw = "[SUGGEST: a | b | c]"
        let result = FollowUpExtractor.extract(from: raw)
        XCTAssertEqual(result.suggestions, ["a", "b", "c"])
        XCTAssertEqual(result.content, "")
    }

    func testBracketWhitespaceInLabelsIsTrimmed() {
        let result = FollowUpExtractor.extract(from: "[SUGGEST:   padded label   |   another  ]")
        XCTAssertEqual(result.suggestions, ["padded label", "another"])
    }

    // MARK: - Angle-bracket form

    func testAngleBracketMarkerYieldsSingleLabel() {
        let raw = "Reply body. <suggest>shorter version</suggest>"
        let result = FollowUpExtractor.extract(from: raw)
        XCTAssertEqual(result.suggestions, ["shorter version"])
        XCTAssertFalse(result.content.contains("<suggest>"))
    }

    func testMultipleAngleBracketMarkersAreMerged() {
        let raw = "<suggest>first</suggest> and <suggest>second</suggest>"
        let result = FollowUpExtractor.extract(from: raw)
        XCTAssertEqual(result.suggestions, ["first", "second"])
    }

    func testAngleBracketIsCaseInsensitive() {
        let result = FollowUpExtractor.extract(from: "intro <Suggest>foo</Suggest> tail")
        XCTAssertEqual(result.suggestions, ["foo"])
    }

    func testAngleBracketHandlesAttributes() {
        // Some models emit `<suggest id="1">label</suggest>`.
        let raw = "body. <suggest id=\"1\">label a</suggest> then <suggest id=\"2\">label b</suggest>"
        let result = FollowUpExtractor.extract(from: raw)
        XCTAssertEqual(result.suggestions, ["label a", "label b"])
    }

    // MARK: - Numbered list form

    func testNumberedListAfterFollowUpHeadingIsExtracted() {
        let raw = """
        Here is the answer.

        Next steps:
        1. Try the smaller API
        2. Add retry logic
        3. Switch to streaming
        """
        let result = FollowUpExtractor.extract(from: raw)
        XCTAssertEqual(
            result.suggestions,
            ["Try the smaller API", "Add retry logic", "Switch to streaming"]
        )
        XCTAssertFalse(result.content.contains("Next steps:"))
        XCTAssertFalse(result.content.contains("1. Try the smaller API"))
    }

    func testNumberedListWithParenthesisSeparator() {
        let raw = """
        Body text.

        You might want to:
        1) Make the variable optional
        2) Add a default value
        """
        let result = FollowUpExtractor.extract(from: raw)
        XCTAssertEqual(
            result.suggestions,
            ["Make the variable optional", "Add a default value"]
        )
    }

    func testNumberedListWithMarkdownHeadingPrefix() {
        let raw = """
        Answer.

        **Next steps:**
        1. Refactor the parser
        2. Add a regression test
        """
        let result = FollowUpExtractor.extract(from: raw)
        XCTAssertEqual(result.suggestions, ["Refactor the parser", "Add a regression test"])
    }

    func testNumberedListWithoutHeadingIsNotExtracted() {
        // Without a triggering heading, a numbered list is treated
        // as ordinary prose (e.g. "1. The cause ... 2. The fix ...").
        let raw = """
        The issue has two parts.

        1. The first part is misnamed
        2. The second part is duplicated
        """
        let result = FollowUpExtractor.extract(from: raw)
        XCTAssertEqual(result.suggestions, [])
        XCTAssertTrue(result.content.contains("1. The first part is misnamed"))
    }

    func testNumberedListWithSingleItemIsNotExtracted() {
        // Single numbered item after a heading is too thin to be a
        // follow-up list; treat as prose to avoid false positives.
        let raw = """
        Here you go.

        Next steps:
        1. That's it.
        """
        let result = FollowUpExtractor.extract(from: raw)
        XCTAssertEqual(result.suggestions, [])
    }

    // MARK: - Mixed forms + dedup

    func testBracketAndAngleBracketAreNotBothUsed() {
        // Bracket is canonical; if it's present we don't double-up
        // with angle-bracket or numbered list extraction.
        let raw = """
        Body.

        [SUGGEST: A | B]

        <suggest>C</suggest>
        """
        let result = FollowUpExtractor.extract(from: raw)
        XCTAssertEqual(result.suggestions, ["A", "B"])
    }

    func testAngleBracketAndNumberedListDoNotMix() {
        let raw = """
        Body.

        <suggest>first</suggest>

        Next steps:
        1. second
        2. third
        """
        let result = FollowUpExtractor.extract(from: raw)
        XCTAssertEqual(result.suggestions, ["first"])
    }

    func testDuplicateLabelsAreDeDuplicated() {
        let raw = """
        [SUGGEST: retry | retry | Retry]
        """
        let result = FollowUpExtractor.extract(from: raw)
        XCTAssertEqual(result.suggestions, ["retry"])
    }

    func testSuggestionsAreCappedAtMaxSuggestions() {
        let labels = (1...12).map { "option \($0)" }.joined(separator: " | ")
        let raw = "[SUGGEST: \(labels)]"
        let result = FollowUpExtractor.extract(from: raw)
        XCTAssertEqual(result.suggestions.count, FollowUpExtractor.maxSuggestions)
    }

    // MARK: - Realistic shapes

    func testFollowUpAfterLongProseParagraph() {
        let raw = """
        The cause is that the cache key includes a timestamp, so every request lands
        on a cold path. Bumping the TTL should fix it; you can also invalidate on
        dependency changes.

        [SUGGEST: Show me the diff | Bump the TTL | Add a unit test for the cache key]
        """
        let result = FollowUpExtractor.extract(from: raw)
        XCTAssertEqual(
            result.suggestions,
            ["Show me the diff", "Bump the TTL", "Add a unit test for the cache key"]
        )
        XCTAssertTrue(result.content.hasPrefix("The cause is that the cache key"))
        XCTAssertTrue(result.content.contains("Bumping the TTL should fix it"))
        XCTAssertFalse(result.content.contains("[SUGGEST:"))
    }

    func testMarkerInsideCodeFenceIsNotExtracted() {
        // The model's prose mentions a marker literally inside a
        // fenced code block; the chip row shouldn't be triggered.
        let raw = """
        Use this snippet:

        ```
        [SUGGEST: do not extract | this is a literal example]
        ```

        That's it.
        """
        let result = FollowUpExtractor.extract(from: raw)
        XCTAssertEqual(result.suggestions, [])
        XCTAssertTrue(result.content.contains("[SUGGEST: do not extract"))
    }
}
