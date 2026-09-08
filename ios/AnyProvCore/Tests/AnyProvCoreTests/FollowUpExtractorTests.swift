import XCTest
@testable import AnyProvCore

/// Tests for `FollowUpExtractor` — the parser that pulls the
/// `[SUGGEST: a | b | c]` marker out of an assistant message and
/// turns it into a chip row. Mirrors the contract the chat
/// composer and the E2B session both depend on.
final class FollowUpExtractorTests: XCTestCase {
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

    func testSingleMarkerYieldsSuggestions() {
        let raw = "Some prose before. [SUGGEST: shorter follow-up | a different angle | a code example] And prose after."
        let result = FollowUpExtractor.extract(from: raw)
        XCTAssertEqual(result.suggestions, ["shorter follow-up", "a different angle", "a code example"])
        XCTAssertFalse(result.hasSuggestions ? result.suggestions.isEmpty : true)
        // Marker is stripped; surrounding prose remains.
        XCTAssertFalse(result.content.contains("[SUGGEST:"))
        XCTAssertTrue(result.content.contains("Some prose before."))
        XCTAssertTrue(result.content.contains("And prose after."))
    }

    func testCaseInsensitiveKeyword() {
        let result = FollowUpExtractor.extract(from: "hi [suggest: A | B] bye")
        XCTAssertEqual(result.suggestions, ["A", "B"])
    }

    func testMultipleMarkersAreMerged() {
        let raw = "[SUGGEST: one | two] middle [SUGGEST: three] tail"
        let result = FollowUpExtractor.extract(from: raw)
        XCTAssertEqual(result.suggestions, ["one", "two", "three"])
        XCTAssertFalse(result.content.contains("[SUGGEST:"))
    }

    func testEmptyLabelsAreDropped() {
        let raw = "[SUGGEST: a |  | b |   | c]"
        let result = FollowUpExtractor.extract(from: raw)
        XCTAssertEqual(result.suggestions, ["a", "b", "c"])
    }

    func testLongLabelIsTruncated() {
        let long = String(repeating: "x", count: FollowUpExtractor.maxLabelLength + 50)
        let raw = "[SUGGEST: \(long)]"
        let result = FollowUpExtractor.extract(from: raw)
        XCTAssertEqual(result.suggestions.count, 1)
        XCTAssertLessThanOrEqual(result.suggestions[0].count, FollowUpExtractor.maxLabelLength)
        XCTAssertTrue(result.suggestions[0].hasSuffix("…"))
    }

    func testMarkerAtStartAndEndOfMessage() {
        let start = FollowUpExtractor.extract(from: "[SUGGEST: only] rest of message")
        XCTAssertEqual(start.suggestions, ["only"])
        XCTAssertTrue(start.content.hasPrefix("rest of message"))

        let end = FollowUpExtractor.extract(from: "intro [SUGGEST: only]")
        XCTAssertEqual(end.suggestions, ["only"])
        XCTAssertTrue(end.content.hasPrefix("intro"))
    }

    func testMarkerOnlyMessage() {
        let raw = "[SUGGEST: a | b | c]"
        let result = FollowUpExtractor.extract(from: raw)
        XCTAssertEqual(result.suggestions, ["a", "b", "c"])
        XCTAssertEqual(result.content, "")
    }

    func testWhitespaceInLabelsIsTrimmed() {
        let result = FollowUpExtractor.extract(from: "[SUGGEST:   padded label   |   another  ]")
        XCTAssertEqual(result.suggestions, ["padded label", "another"])
    }
}
