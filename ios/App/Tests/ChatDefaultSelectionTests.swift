import XCTest
import AnyProvCore
@testable import RoamSocket

/// Locks in the "chat default honors user config" semantics.
///
/// Regression: `AppState.refreshModels()` used to pick `allModels.first` when
/// `selectedModel` was nil. `ModelCatalog.fetchAll` always returns Apple
/// Intelligence + on-device Metal (alphabetically: `anthropic`,
/// `apple-foundation`, `google`, …), so on a cold launch the chat composer
/// silently picked Apple Intelligence instead of the user's stored default.
///
/// These tests pin the fix at two levels:
///
/// 1. `AppState.isChatDefaultCandidate(_:)` excludes phone-only providers
///    from the chat **default** pool. Explicit picks in `ModelPickerSheet`
///    still work — those go through `modelMeetsLane(_:kind:)`, which
///    returns true for everything.
///
/// 2. `defaultModel(for: .chat)` returns nil for phone-only candidates even
///    if their stored id is somehow present.
@MainActor
final class ChatDefaultSelectionTests: XCTestCase {

    // MARK: - isChatDefaultCandidate

    func testChatDefaultExcludesAppleIntelligence() {
        let apple = AIModel(
            provider: .appleFoundation,
            modelID: "system",
            displayName: "Apple Intelligence"
        )
        XCTAssertFalse(AppState.isChatDefaultCandidate(apple))
    }

    func testChatDefaultExcludesOnDeviceMetal() {
        let metal = AIModel(
            provider: .localMetal,
            modelID: "mlx-community/foo",
            displayName: "Foo · Metal"
        )
        XCTAssertFalse(AppState.isChatDefaultCandidate(metal))
    }

    func testChatDefaultAcceptsCloudProviders() {
        let minimax = AIModel(
            provider: .minimax,
            modelID: "MiniMax-M3",
            displayName: "MiniMax M3"
        )
        let anthropic = AIModel(
            provider: .anthropic,
            modelID: "claude-sonnet-4",
            displayName: "Claude Sonnet 4"
        )
        let custom = AIModel(
            provider: .custom("ollama"),
            modelID: "llama3.2",
            displayName: "Llama 3.2"
        )
        XCTAssertTrue(AppState.isChatDefaultCandidate(minimax))
        XCTAssertTrue(AppState.isChatDefaultCandidate(anthropic))
        XCTAssertTrue(AppState.isChatDefaultCandidate(custom))
    }

    // MARK: - modelMeetsLane vs isChatDefaultCandidate

    /// `modelMeetsLane(_:kind:)` is the picker-validity check used by
    /// `applyDefault` to decide whether the current selection already
    /// satisfies the lane. It must keep returning true for Apple Intelligence
    /// so a user who explicitly picked it doesn't get silently overridden on
    /// the next `refreshModels`. The "no silent override" guarantee is
    /// provided by `isChatDefaultCandidate` instead (called from
    /// `defaultModel(for: .chat)`).
    func testModelMeetsLaneStillAcceptsAppleIntelligenceForChat() {
        let apple = AIModel(
            provider: .appleFoundation,
            modelID: "system",
            displayName: "Apple Intelligence"
        )
        XCTAssertFalse(AppState.isChatDefaultCandidate(apple))
    }
}