import XCTest
import Combine
import AnyProvCore
@testable import RoamSocket

/// Pins the "E2B inner stores re-render AppState observers" wiring.
///
/// Both `E2bSessionStore` and `SandboxesStore` are held as
/// `ObservableObject` properties on `AppState` and mutated by code
/// the views don't directly observe (a new session lands in
/// `e2bSessionStore.sessions` from a `Task` in `openSession`; a new
/// run lands in `sandboxesStore.phoneRuns` from `startPhoneRun`).
/// Without the Combine forward wired in `AppState.init`, a view
/// observing only `AppState` would miss those mutations — same
/// shape as the e2bKeyStore regression pinned in
/// `E2BKeyStoreForwardingTests`.
///
/// We test the wiring directly: call `objectWillChange.send()` on
/// the inner store and assert AppState's `objectWillChange` fires.
/// That's a "wiring" test (we don't mutate the @Published arrays
/// end-to-end), but it's exactly the contract the fix relies on —
/// if the sink in `AppState.init` ever gets dropped, this trips.
@MainActor
final class E2BStoreForwardingTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Wipe the shared .standard entry the E2B key store reads.
        // The forwarding tests don't touch the key, but the AppState
        // init touches every store, so the key has to be predictable.
        UserDefaults.standard.removeObject(forKey: "e2b.apiKey.v1")
    }

    // MARK: - e2bSessionStore

    func testE2BSessionStoreForwardingTriggersAppStateChange() {
        let state = makeState()

        let expectation = XCTestExpectation(description: "AppState re-renders on session-store change")
        expectation.assertForOverFulfill = false
        let cancellable = state.objectWillChange.sink { _ in expectation.fulfill() }
        defer { cancellable.cancel() }

        // Synthesize a mutation. In production this is what
        // `@Published var sessions` does when a new row lands
        // from `openSession`. The forward must relay it.
        state.e2bSessionStore.objectWillChange.send()

        wait(for: [expectation], timeout: 1.0)
    }

    func testE2BSessionStoreForwardingSurvivesMultipleChanges() {
        let state = makeState()

        let expectation = XCTestExpectation(description: "Forwarding handles a burst")
        expectation.expectedFulfillmentCount = 3
        let cancellable = state.objectWillChange.sink { _ in expectation.fulfill() }
        defer { cancellable.cancel() }

        state.e2bSessionStore.objectWillChange.send()
        state.e2bSessionStore.objectWillChange.send()
        state.e2bSessionStore.objectWillChange.send()

        wait(for: [expectation], timeout: 1.0)
    }

    // MARK: - sandboxesStore

    func testSandboxesStoreForwardingTriggersAppStateChange() {
        let state = makeState()

        let expectation = XCTestExpectation(description: "AppState re-renders on sandboxes-store change")
        expectation.assertForOverFulfill = false
        let cancellable = state.objectWillChange.sink { _ in expectation.fulfill() }
        defer { cancellable.cancel() }

        state.sandboxesStore.objectWillChange.send()

        wait(for: [expectation], timeout: 1.0)
    }

    func testSandboxesStoreForwardingSurvivesMultipleChanges() {
        let state = makeState()

        let expectation = XCTestExpectation(description: "Forwarding handles a burst")
        expectation.expectedFulfillmentCount = 3
        let cancellable = state.objectWillChange.sink { _ in expectation.fulfill() }
        defer { cancellable.cancel() }

        state.sandboxesStore.objectWillChange.send()
        state.sandboxesStore.objectWillChange.send()
        state.sandboxesStore.objectWillChange.send()

        wait(for: [expectation], timeout: 1.0)
    }

    // MARK: - Helpers

    private func makeState() -> AppState {
        AppState(secrets: InMemorySecretStore())
    }
}
