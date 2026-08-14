import XCTest
@testable import AnyProvCore

final class MemoryTagParserTests: XCTestCase {
    func testSimpleAddTag() {
        let p = MemoryTagParser()
        let r = p.push(chunk: #"Got it.<memory action="add" category="you" title="Profile" summary="I work at Verizon" details="I work at Verizon" /> Will remember."#)
        XCTAssertEqual(r.text, "Got it. Will remember.")
        XCTAssertEqual(r.actions, [
            .add(category: .you, title: "Profile", summary: "I work at Verizon", details: ["I work at Verizon"])
        ])
    }

    func testTagSplitAcrossChunks() {
        let p = MemoryTagParser()
        let r1 = p.push(chunk: "Sure thing. <memory act")
        XCTAssertEqual(r1.text, "")
        XCTAssertEqual(r1.actions, [])
        let r2 = p.push(chunk: #"ion="add" category="you" title="Profile" summary="I live in Colorado" details="I live in Colorado" />"#)
        XCTAssertEqual(r2.text, "Sure thing. ")
        XCTAssertEqual(r2.actions, [
            .add(category: .you, title: "Profile", summary: "I live in Colorado", details: ["I live in Colorado"])
        ])
    }

    func testForgetTag() {
        let p = MemoryTagParser()
        let r = p.push(chunk: #"Forgetting.<memory action="forget" target="Verizon" />"#)
        XCTAssertEqual(r.text, "Forgetting.")
        XCTAssertEqual(r.actions, [.forget(target: "Verizon")])
    }

    func testRenameTag() {
        let p = MemoryTagParser()
        let r = p.push(chunk: #"<memory action="rename" target="Profile" value="About me" />"#)
        XCTAssertEqual(r.actions, [.rename(target: "Profile", value: "About me")])
    }

    func testSetDetailsWithPipes() {
        let p = MemoryTagParser()
        let r = p.push(chunk: #"<memory action="set_details" target="Profile" value="A|B|C" />"#)
        XCTAssertEqual(r.actions, [.setDetails(target: "Profile", value: ["A", "B", "C"])])
    }

    func testTagInsideCodeBlockPreserved() {
        let p = MemoryTagParser()
        let r = p.push(chunk: "Here is the snippet:\n```\n<memory action=\"add\" />\n```\nGot it.")
        XCTAssertEqual(r.text, "Here is the snippet:\n```\n<memory action=\"add\" />\n```\nGot it.")
        XCTAssertEqual(r.actions, [])
    }

    func testTagInsideInlineCodePreserved() {
        let p = MemoryTagParser()
        let r = p.push(chunk: #"Use `<memory action="add" />` in your app."#)
        XCTAssertEqual(r.text, #"Use `<memory action="add" />` in your app."#)
        XCTAssertEqual(r.actions, [])
    }

    func testMultipleTags() {
        let p = MemoryTagParser()
        let r = p.push(chunk: #"Noted.<memory action="add" category="you" title="Profile" summary="A" details="A" /><memory action="forget" target="old" />"#)
        XCTAssertEqual(r.actions.count, 2)
        XCTAssertEqual(r.actions[0], .add(category: .you, title: "Profile", summary: "A", details: ["A"]))
        XCTAssertEqual(r.actions[1], .forget(target: "old"))
    }

    func testUnknownActionDropped() {
        let p = MemoryTagParser()
        let r = p.push(chunk: #"Hi <memory action="explode" /> there."#)
        XCTAssertEqual(r.text, "Hi  there.")
        XCTAssertEqual(r.actions, [])
    }

    func testNonSelfClosingWrapperIsText() {
        let p = MemoryTagParser()
        let r1 = p.push(chunk: "text <memory> not a tag really</memory> end")
        XCTAssertEqual(r1.text, "text <memory> not a tag really</memory> end")
        XCTAssertEqual(r1.actions, [])
        let r2 = p.end()
        XCTAssertEqual(r2.text, "")
    }

    func testEndFlushesUnterminatedTail() {
        let p = MemoryTagParser()
        p.push(chunk: "partial <memory act")
        let r = p.end()
        XCTAssertEqual(r.text, "partial ")
        XCTAssertEqual(r.actions, [])
    }

    func testAddWithMultiplePipeDetails() {
        let p = MemoryTagParser()
        let r = p.push(chunk: #"<memory action="add" category="you" title="Profile" summary="" details="A|B|C" />"#)
        XCTAssertEqual(r.actions, [
            .add(category: .you, title: "Profile", summary: "", details: ["A", "B", "C"])
        ])
    }

    func testCategoryDefaultsToYou() {
        let p = MemoryTagParser()
        let r = p.push(chunk: #"<memory action="add" title="Profile" summary="X" details="X" />"#)
        XCTAssertEqual(r.actions, [.add(category: .you, title: "Profile", summary: "X", details: ["X"])])
    }

    func testInvalidCategoryDropped() {
        let p = MemoryTagParser()
        let r = p.push(chunk: #"<memory action="add" category="global" title="Profile" summary="X" details="X" />"#)
        XCTAssertEqual(r.actions, [])
        XCTAssertEqual(r.text, "")
    }

    func testEndToEndVisibleAndActions() {
        // Realistic shape: greeting, tag, follow-up. Visible text should
        // drop the tag cleanly; actions should parse the add.
        let p = MemoryTagParser()
        let r1 = p.push(chunk: "Got it. ")
        XCTAssertEqual(r1.text, "Got it. ")
        XCTAssertEqual(r1.actions, [])
        let r2 = p.push(chunk: #"<memory action="add" category="you" title="Profile" summary="I work at Verizon" details="I work at Verizon" />"#)
        XCTAssertEqual(r2.text, "")
        XCTAssertEqual(r2.actions, [
            .add(category: .you, title: "Profile", summary: "I work at Verizon", details: ["I work at Verizon"])
        ])
        let r3 = p.push(chunk: " Will remember.")
        XCTAssertEqual(r3.text, " Will remember.")
        let r4 = p.end()
        XCTAssertEqual(r4.text, "")
    }
}
