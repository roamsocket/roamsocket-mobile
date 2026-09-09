import XCTest
import Combine
import AnyProvCore
@testable import RoamSocket

/// Pins the "Code home + Sandboxes sheet re-render when the user
/// pastes an E2B key in Settings" regression.
///
/// Before the fix, the views read `state.e2bKeyStore.hasKey` but
/// only observed `state` (AppState). `e2bKeyStore` is a separate
/// `ObservableObject`, so its `hasKey` change never bubbled to
/// AppState. The empty-state copy on the Code tab therefore kept
/// showing "Add your e2b.dev API key, then tap Start a run…" (and
/// the Start button on the Sandboxes sheet stayed disabled) even
/// after the user saved a key in Settings — the key was on disk
/// but the UI never re-rendered.
///
/// The fix is the same Combine forward the `codeSessionStore`
/// already has: `e2bKeyStore.objectWillChange → AppState.objectWillChange.send()`.
@MainActor
final class E2BKeyStoreForwardingTests: XCTestCase {
    private var suite: String = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        // The e2b key is stored under "e2b.apiKey.v1" in the shared
        // `.standard` UserDefaults. Wipe the suite so prior tests
        // in other targets don't leak a key into this one.
        suite = "E2BKeyStoreForwardingTests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        // Also wipe `.standard` for the same reason.
        UserDefaults.standard.removeObject(forKey: "e2b.apiKey.v1")
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        UserDefaults.standard.removeObject(forKey: "e2b.apiKey.v1")
        super.tearDown()
    }

    /// Setting a key on the inner store must publish through AppState
    /// so the views observing AppState re-render. This is the exact
    /// path the user hits in Settings → E2B key sheet → Code tab.
    /// Uses `XCTestExpectation` because the production forward uses
    /// `.receive(on: RunLoop.main)`, which schedules rather than
    /// delivers synchronously — checking `fired` immediately after
    /// the set call would be racy.
    func testSettingKeyTriggersAppStateChange() {
        let state = makeState()
        XCTAssertFalse(state.e2bKeyStore.hasKey)

        let expectation = XCTestExpectation(description: "AppState.objectWillChange fires")
        // We expect at least one fire; a single transition can
        // legally produce multiple (`@Published` willSet on `hasKey`
        // is the obvious one). `assertForOverFulfill` would mask
        // a future second store on the same chain, so allow extras.
        expectation.assertForOverFulfill = false
        let cancellable = state.objectWillChange.sink { _ in expectation.fulfill() }
        defer { cancellable.cancel() }

        state.e2bKeyStore.set("e2b_abcdefghijklmnopqrstuvwxyz123456")

        wait(for: [expectation], timeout: 1.0)
        XCTAssertTrue(state.e2bKeyStore.hasKey)
        XCTAssertEqual(
            state.e2bKeyStore.get(),
            "e2b_abcdefghijklmnopqrstuvwxyz123456"
        )
    }

    /// Clearing a key must also publish through AppState so the
    /// Settings row + empty-state copy flip back to "Not set".
    func testClearingKeyTriggersAppStateChange() {
        let state = makeState()
        state.e2bKeyStore.set("e2b_abcdefghijklmnopqrstuvwxyz123456")
        XCTAssertTrue(state.e2bKeyStore.hasKey)

        let expectation = XCTestExpectation(description: "AppState.objectWillChange fires on clear")
        expectation.assertForOverFulfill = false
        let cancellable = state.objectWillChange.sink { _ in expectation.fulfill() }
        defer { cancellable.cancel() }

        state.e2bKeyStore.set(nil)

        wait(for: [expectation], timeout: 1.0)
        XCTAssertFalse(state.e2bKeyStore.hasKey)
    }

    /// Whitespace-only drafts (which the sheet would reject via
    /// `E2BKeyStore.validate` anyway) must not flip hasKey — the
    /// store's `set` treats them as "clear" so the Settings row
    /// wouldn't flicker "Set / Not set" while the user is still
    /// typing if we go from no-key → whitespace. The key here is
    /// that `hasKey` stays false and `get()` returns nil; whether
    /// `objectWillChange` fires is up to `@Published`.
    func testWhitespaceOnlyDoesNotFlipHasKey() {
        let state = makeState()
        XCTAssertFalse(state.e2bKeyStore.hasKey)

        state.e2bKeyStore.set("   ")

        XCTAssertFalse(state.e2bKeyStore.hasKey)
        XCTAssertNil(state.e2bKeyStore.get())
    }

    /// Belt-and-braces: even when the inner store was set BEFORE
    /// the AppState started observing (e.g. a future caller who
    /// reads the value at app launch but subscribes later), a new
    /// `set` on the same store must still publish through. The
    /// forward is wired in `init` so this is the steady state; the
    /// test is here to make sure nobody "optimises" the forward
    /// out by checking for a one-time hydrate that doesn't exist.
    func testKeySetBeforeSubscriptionStillPublishes() {
        let state = makeState()
        state.e2bKeyStore.set("e2b_abcdefghijklmnopqrstuvwxyz123456")

        let expectation = XCTestExpectation(description: "Subsequent set still fires")
        expectation.assertForOverFulfill = false
        let cancellable = state.objectWillChange.sink { _ in expectation.fulfill() }
        defer { cancellable.cancel() }

        state.e2bKeyStore.set("e2b_xyzzyxwvutsrqponmlkjihgfedcba0987")

        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(
            state.e2bKeyStore.get(),
            "e2b_xyzzyxwvutsrqponmlkjihgfedcba0987"
        )
    }

    // MARK: - Helpers

    private func makeState() -> AppState {
        AppState(secrets: InMemorySecretStore())
    }
}
