import XCTest
@testable import AnyProvCore

final class E2BKeyStoreTests: XCTestCase {
    private var suite: String = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = "E2BKeyStoreTests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testEmptyStoreHasNoKey() {
        let store = E2BKeyStore(defaults: defaults)
        XCTAssertFalse(store.hasKey)
        XCTAssertNil(store.get())
    }

    func testSetPersistsAndPublishesHasKey() {
        let store = E2BKeyStore(defaults: defaults)
        store.set("e2b_abcdefghijklmnopqrstuvwxyz123456")
        XCTAssertTrue(store.hasKey)
        XCTAssertEqual(store.get(), "e2b_abcdefghijklmnopqrstuvwxyz123456")
    }

    func testSetTrimsWhitespace() {
        let store = E2BKeyStore(defaults: defaults)
        store.set("  e2b_abcdefghijklmnopqrstuvwxyz123456  \n")
        XCTAssertEqual(store.get(), "e2b_abcdefghijklmnopqrstuvwxyz123456")
    }

    func testSetNilClears() {
        let store = E2BKeyStore(defaults: defaults)
        store.set("e2b_abcdefghijklmnopqrstuvwxyz123456")
        XCTAssertTrue(store.hasKey)
        store.set(nil)
        XCTAssertFalse(store.hasKey)
        XCTAssertNil(store.get())
    }

    func testSetEmptyStringClears() {
        let store = E2BKeyStore(defaults: defaults)
        store.set("e2b_abcdefghijklmnopqrstuvwxyz123456")
        store.set("   ")
        XCTAssertFalse(store.hasKey)
    }

    func testNewInstanceReadsExistingKey() {
        let store1 = E2BKeyStore(defaults: defaults)
        store1.set("e2b_persistentkey1234567890abcdef")
        // Brand new instance pointing at the same defaults suite
        // should see the persisted value on first read.
        let store2 = E2BKeyStore(defaults: defaults)
        XCTAssertTrue(store2.hasKey)
        XCTAssertEqual(store2.get(), "e2b_persistentkey1234567890abcdef")
    }

    // MARK: - validate()

    func testValidateEmptyIsMissing() {
        XCTAssertEqual(E2BKeyStore.validate(""), .missing)
        XCTAssertEqual(E2BKeyStore.validate(nil), .missing)
        XCTAssertEqual(E2BKeyStore.validate("   "), .missing)
    }

    func testValidateRejectsNonE2BPrefix() {
        guard case let .invalid(reason) = E2BKeyStore.validate("sk-abc123") else {
            XCTFail("Expected .invalid")
            return
        }
        XCTAssertTrue(reason.contains("e2b_"))
    }

    func testValidateRejectsTooShort() {
        guard case let .invalid(reason) = E2BKeyStore.validate("e2b_short") else {
            XCTFail("Expected .invalid")
            return
        }
        XCTAssertTrue(reason.lowercased().contains("short"))
    }

    func testValidateRejectsUnexpectedCharacters() {
        // 20+ chars but includes spaces.
        let bad = "e2b_abc def ghi jkl mno pqr"
        guard case let .invalid(reason) = E2BKeyStore.validate(bad) else {
            XCTFail("Expected .invalid")
            return
        }
        XCTAssertTrue(reason.lowercased().contains("unexpected"))
    }

    func testValidateAcceptsCanonicalShape() {
        XCTAssertEqual(E2BKeyStore.validate("e2b_abc123def456ghi789jkl012mno345pqr678"), .valid)
        XCTAssertEqual(E2BKeyStore.validate("e2b_" + String(repeating: "a", count: 20)), .valid)
        XCTAssertEqual(E2BKeyStore.validate("e2b_" + String(repeating: "a", count: 200)), .valid)
    }

    func testValidateAcceptsHyphenAndUnderscore() {
        XCTAssertEqual(
            E2BKeyStore.validate("e2b_abc-def_ghi-jkl_mno-pqr_stu-vwx_yz12345"),
            .valid
        )
    }

    func testValidateTrimsBeforeChecking() {
        XCTAssertEqual(
            E2BKeyStore.validate("  e2b_abc123def456ghi789jkl012mno345pqr678  "),
            .valid
        )
    }
}
