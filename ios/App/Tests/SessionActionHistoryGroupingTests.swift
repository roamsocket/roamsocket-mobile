import XCTest
import SwiftUI
@testable import RoamSocket

/// Tests for the Code-session transcript grouping logic. Consecutive
/// `.tool` items must collapse into a single `TranscriptSegment.actions`,
/// while non-tool items stay as their own segments. The grouping is the
/// data contract that `SessionView`'s LazyVStack relies on for rendering
/// one card per action group instead of one per tool call.
final class SessionActionHistoryGroupingTests: XCTestCase {

    // MARK: - Empty / single item

    func testEmptyItemsProduceNoSegments() {
        let segments = TranscriptSegment.segments(from: [])
        XCTAssertTrue(segments.isEmpty)
    }

    func testSingleNonToolItemStaysAsItem() {
        let items = [user("hello")]
        let segments = TranscriptSegment.segments(from: items)
        XCTAssertEqual(segments.count, 1)
        XCTAssertItem(segments[0], matches: items[0])
    }

    // MARK: - Tool grouping

    func testSingleToolBecomesOneActionGroup() {
        let t = tool("bash", "ls", ok: true)
        let segments = TranscriptSegment.segments(from: [t])
        XCTAssertEqual(segments.count, 1)
        guard case let .actions(_, tools) = segments[0] else {
            return XCTFail("Expected a single .actions segment, got \(segments[0])")
        }
        XCTAssertEqual(tools.count, 1)
    }

    func testConsecutiveToolsCollapseIntoOneGroup() {
        let t1 = tool("bash", "ls", ok: true)
        let t2 = tool("read_file", "main.swift", ok: true)
        let t3 = tool("edit_file", "main.swift", ok: false)
        let segments = TranscriptSegment.segments(from: [t1, t2, t3])
        XCTAssertEqual(segments.count, 1)
        guard case let .actions(_, tools) = segments[0] else {
            return XCTFail("Expected a single .actions segment, got \(segments[0])")
        }
        XCTAssertEqual(tools.map(\.id), [t1.id, t2.id, t3.id])
    }

    // MARK: - Group breaks

    func testAssistantMessageBreaksGroup() {
        let t1 = tool("bash", "ls", ok: true)
        let t2 = tool("read_file", "main.swift", ok: true)
        let a = assistant("looking at the file…")
        let t3 = tool("edit_file", "main.swift", ok: true)
        let segments = TranscriptSegment.segments(from: [t1, t2, a, t3])
        XCTAssertEqual(segments.count, 3)
        guard case let .actions(_, first) = segments[0] else { return XCTFail() }
        XCTAssertEqual(first.count, 2)
        XCTAssertItem(segments[1], matches: a)
        guard case let .actions(_, second) = segments[2] else { return XCTFail() }
        XCTAssertEqual(second.count, 1)
    }

    func testUserMessageBreaksGroup() {
        let t1 = tool("bash", "ls", ok: true)
        let u = user("now do X")
        let t2 = tool("bash", "pwd", ok: true)
        let segments = TranscriptSegment.segments(from: [t1, u, t2])
        XCTAssertEqual(segments.count, 3)
    }

    func testDiffBreaksGroup() {
        let t1 = tool("bash", "ls", ok: true)
        let d = diff("main.swift", added: 1, removed: 0)
        let t2 = tool("bash", "pwd", ok: true)
        let segments = TranscriptSegment.segments(from: [t1, d, t2])
        XCTAssertEqual(segments.count, 3)
    }

    func testNoticeBreaksGroup() {
        let t1 = tool("bash", "ls", ok: true)
        let n = notice("connecting…")
        let t2 = tool("bash", "pwd", ok: true)
        let segments = TranscriptSegment.segments(from: [t1, n, t2])
        XCTAssertEqual(segments.count, 3)
    }

    // MARK: - ID stability

    func testActionGroupIDStaysStableAsGroupGrows() {
        let t1 = tool("bash", "ls", ok: true)
        let t2 = tool("bash", "pwd", ok: true)
        let id1: String
        let id2: String
        if case let .actions(id, _) = TranscriptSegment.segments(from: [t1]).first! {
            id1 = id
        } else { return XCTFail() }
        if case let .actions(id, _) = TranscriptSegment.segments(from: [t1, t2]).first! {
            id2 = id
        } else { return XCTFail() }
        // Anchored to the first tool's id so SwiftUI animates the row
        // update instead of tearing down and rebuilding.
        XCTAssertEqual(id1, id2)
    }

    func testAllSegmentsIDsAreUnique() {
        let items: [SessionViewModel.Item] = [
            user("hi"),
            tool("bash", "ls", ok: true),
            tool("bash", "pwd", ok: true),
            assistant("ok"),
            tool("read_file", "a.swift", ok: true),
            diff("a.swift", added: 2, removed: 1),
            tool("edit_file", "a.swift", ok: true),
            notice("done"),
        ]
        let segments = TranscriptSegment.segments(from: items)
        let ids = segments.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "Segment ids must be unique so SwiftUI ForEach can track them")
    }

    // MARK: - Item payload helpers

    func testToolPayloadHelpers() {
        let t = tool("bash", "ls -la", ok: true, output: "file1\nfile2")
        XCTAssertTrue(t.isTool)
        XCTAssertEqual(t.toolName, "bash")
        XCTAssertEqual(t.toolSummary, "ls -la")
        XCTAssertEqual(t.toolOk, true)
        XCTAssertEqual(t.toolOutput, "file1\nfile2")
    }

    func testNonToolPayloadHelpersReturnNil() {
        let u = user("hi")
        XCTAssertFalse(u.isTool)
        XCTAssertNil(u.toolName)
        XCTAssertNil(u.toolSummary)
        XCTAssertNil(u.toolOk)
        XCTAssertNil(u.toolOutput)
    }

    // MARK: - Fixtures

    private func user(_ text: String) -> SessionViewModel.Item {
        .user(id: UUID(), text: text)
    }

    private func assistant(_ text: String) -> SessionViewModel.Item {
        .assistant(id: UUID(), text: text)
    }

    private func tool(
        _ name: String,
        _ summary: String,
        ok: Bool?,
        output: String? = nil
    ) -> SessionViewModel.Item {
        .tool(id: UUID().uuidString, tool: name, summary: summary, ok: ok, output: output)
    }

    private func diff(_ path: String, added: Int, removed: Int) -> SessionViewModel.Item {
        .diff(id: UUID(), path: path, patch: "", added: added, removed: removed)
    }

    private func notice(_ text: String) -> SessionViewModel.Item {
        .notice(id: UUID(), text: text)
    }

    private func XCTAssertItem(
        _ segment: TranscriptSegment,
        matches item: SessionViewModel.Item,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        guard case let .item(actual) = segment else {
            return XCTFail("Expected .item, got \(segment)", file: file, line: line)
        }
        XCTAssertEqual(actual.id, item.id, file: file, line: line)
    }
}
