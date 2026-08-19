import XCTest
import AnyProvCore
@testable import RoamSocket

/// Pins the "Code + Vision lane don't render '+ Add a model' when the user
/// has a usable provider configured" semantics.
///
/// Regression: a user with a chat default pointing at Apple Intelligence and
/// an Anthropic provider key configured in Settings could open the Code tab
/// and still see the "+ Add a model" CTA. The root cause: `applyDefault`
/// (the entry point `CodeHomeView.onAppear` uses to honor the user's code
/// default) only fell back to the stored `defaultCodeModelID`. When none
/// was set, the chat selection — which doesn't `supportsCodingAgent` for
/// Apple Intelligence / on-device Metal — was left in place, and the
/// `ModelSelectorPill` correctly rejected it for the code lane.
///
/// The fix layers a second fallback on top: when no usable default is set,
/// `applyDefault(for: .code/.vision)` scans the live catalog for the first
/// lane-usable model. `isUsableForLane(_:kind:)` is the single source of
/// truth for "this model can drive the desktop agent / vision job right
/// now" (capability + key + desktop install for Metal).
@MainActor
final class CodeDefaultSelectionTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Lane default ids are backed by `@AppStorage` which writes to the
        // shared `UserDefaults.standard` suite. Wipe before each test in
        // case a prior test in another target polluted the keys.
        let defaults = UserDefaults.standard
        for key in [
            "defaultChatModelID.v1",
            "defaultCodeModelID.v1",
            "defaultVisionModelID.v1",
            "defaultLightweightModelID.v1",
        ] {
            defaults.removeObject(forKey: key)
        }
    }

    override func tearDown() {
        // Same cleanup as setUp so a failing test doesn't leak the
        // default id it set into the next run / a sibling test target.
        let defaults = UserDefaults.standard
        for key in [
            "defaultChatModelID.v1",
            "defaultCodeModelID.v1",
            "defaultVisionModelID.v1",
            "defaultLightweightModelID.v1",
        ] {
            defaults.removeObject(forKey: key)
        }
        super.tearDown()
    }

    // MARK: - isUsableForLane (code)

    func testUsableForCodeRejectsAppleIntelligence() {
        let state = makeState()
        let apple = AIModel(
            provider: .appleFoundation,
            modelID: "system",
            displayName: "Apple Intelligence"
        )
        XCTAssertFalse(state.isUsableForLane(apple, kind: .code))
    }

    func testUsableForCodeRejectsPhoneOnlyMetal() {
        // `localMetal` never `supportsCodingAgent` — it only runs on the
        // phone. Phone weights can never drive the desktop agent, even
        // when the desktop happens to advertise the same hub id.
        let state = makeState()
        let phoneMetal = AIModel(
            provider: .localMetal,
            modelID: "mlx-community/foo",
            displayName: "Foo · Metal"
        )
        XCTAssertFalse(state.isUsableForLane(phoneMetal, kind: .code))
    }

    func testUsableForCodeRejectsProviderWithoutKey() {
        let state = makeState()
        // No `providerAPIKey(.anthropic)` set → not usable for code.
        let anthropic = AIModel(
            provider: .anthropic,
            modelID: "claude-sonnet-4",
            displayName: "Claude Sonnet 4"
        )
        XCTAssertFalse(state.isUsableForLane(anthropic, kind: .code))
    }

    func testUsableForCodeAcceptsCloudProviderWithKey() {
        let state = makeState()
        state.setAPIKey("sk-test", for: .anthropic)
        let anthropic = AIModel(
            provider: .anthropic,
            modelID: "claude-sonnet-4",
            displayName: "Claude Sonnet 4"
        )
        XCTAssertTrue(state.isUsableForLane(anthropic, kind: .code))
    }

    func testUsableForCodeRejectsProviderThatDoesNotSupportCoding() {
        // Sanity check: a phone-only provider that doesn't even pretend to
        // support the coding agent should be rejected up front, regardless
        // of any key state.
        let state = makeState()
        let apple = AIModel(
            provider: .appleFoundation,
            modelID: "system",
            displayName: "Apple Intelligence"
        )
        XCTAssertFalse(state.isUsableForLane(apple, kind: .code))
    }

    // MARK: - isUsableForLane (vision)

    func testUsableForVisionRejectsNonVisionModel() {
        let state = makeState()
        state.setAPIKey("sk-test", for: .openai)
        // `text-embedding-*` is matched by `isClearlyNonVisionModelID` so it
        // fails the vision gate even though it's a real catalog model.
        let nonVision = AIModel(
            provider: .openai,
            modelID: "text-embedding-3-small",
            displayName: "text-embedding-3-small"
        )
        XCTAssertFalse(state.isUsableForLane(nonVision, kind: .vision))
    }

    // MARK: - applyDefault fallback (code)

    /// The headline bug: chat default is Apple Intelligence, no code default
    /// is set, but Anthropic is in the catalog with a key. `applyDefault`
    /// must switch to Anthropic instead of leaving Apple Intelligence in
    /// place (which would render the "+ Add a model" CTA).
    func testApplyDefaultForCodePicksUsableFallbackWhenChatIsAppleIntelligence() {
        let state = makeState()
        state.setAPIKey("sk-test", for: .anthropic)
        state.providerResults = [
            ModelCatalog.ProviderResult(
                provider: .anthropic,
                models: [
                    AIModel(
                        provider: .anthropic,
                        modelID: "claude-sonnet-4",
                        displayName: "Claude Sonnet 4"
                    ),
                ],
                error: nil
            ),
        ]
        state.selectedModel = AIModel(
            provider: .appleFoundation,
            modelID: "system",
            displayName: "Apple Intelligence"
        )

        let applied = state.applyDefault(for: .code)

        XCTAssertNotNil(applied)
        XCTAssertEqual(applied?.provider, .anthropic)
        XCTAssertEqual(state.selectedModel?.provider, .anthropic)
    }

    /// The current selection already meets the code lane — `applyDefault`
    /// must leave it alone even when the catalog has other options. The
    /// user explicitly picked this model in chat and we don't want the
    /// code tab to silently swap it.
    func testApplyDefaultForCodeKeepsCurrentWhenItAlreadyMeetsLane() {
        let state = makeState()
        state.setAPIKey("sk-test", for: .anthropic)
        state.providerResults = [
            ModelCatalog.ProviderResult(
                provider: .anthropic,
                models: [
                    AIModel(
                        provider: .anthropic,
                        modelID: "claude-sonnet-4",
                        displayName: "Claude Sonnet 4"
                    ),
                    AIModel(
                        provider: .anthropic,
                        modelID: "claude-opus-4",
                        displayName: "Claude Opus 4"
                    ),
                ],
                error: nil
            ),
        ]
        let opus = AIModel(
            provider: .anthropic,
            modelID: "claude-opus-4",
            displayName: "Claude Opus 4"
        )
        state.selectedModel = opus

        let applied = state.applyDefault(for: .code)

        XCTAssertEqual(applied?.id, opus.id)
        XCTAssertEqual(state.selectedModel?.id, opus.id)
    }

    /// When the user has set an explicit code default, that default must
    /// win over the catalog fallback.
    func testApplyDefaultForCodeHonorsStoredDefaultOverCatalog() {
        let state = makeState()
        state.setAPIKey("sk-test", for: .anthropic)
        state.setAPIKey("oai-test", for: .openai)
        state.providerResults = [
            ModelCatalog.ProviderResult(
                provider: .anthropic,
                models: [
                    AIModel(
                        provider: .anthropic,
                        modelID: "claude-sonnet-4",
                        displayName: "Claude Sonnet 4"
                    ),
                ],
                error: nil
            ),
            ModelCatalog.ProviderResult(
                provider: .openai,
                models: [
                    AIModel(
                        provider: .openai,
                        modelID: "gpt-5",
                        displayName: "GPT-5"
                    ),
                ],
                error: nil
            ),
        ]
        state.selectedModel = AIModel(
            provider: .appleFoundation,
            modelID: "system",
            displayName: "Apple Intelligence"
        )
        // The user explicitly set their code default to GPT-5. The catalog
        // also lists Anthropic, which appears first alphabetically — the
        // stored default must still win.
        state.setDefaultModelID("openai/gpt-5", for: .code)

        let applied = state.applyDefault(for: .code)

        XCTAssertEqual(applied?.provider, .openai)
    }

    /// A stored code default whose API key has since been removed must NOT
    /// be applied — `defaultModel(for: .code)` should drop it so the
    /// catalog fallback can run. Without this guard, `applyDefault` would
    /// write an unusable model into `selectedModel` and the pill would
    /// render "+ Add a model" anyway.
    func testApplyDefaultForCodeDropsStaleDefaultWithoutKey() {
        let state = makeState()
        // Only Anthropic has a key. OpenAI is in the catalog but unkeyed.
        state.setAPIKey("sk-test", for: .anthropic)
        state.providerResults = [
            ModelCatalog.ProviderResult(
                provider: .anthropic,
                models: [
                    AIModel(
                        provider: .anthropic,
                        modelID: "claude-sonnet-4",
                        displayName: "Claude Sonnet 4"
                    ),
                ],
                error: nil
            ),
            ModelCatalog.ProviderResult(
                provider: .openai,
                models: [
                    AIModel(
                        provider: .openai,
                        modelID: "gpt-5",
                        displayName: "GPT-5"
                    ),
                ],
                error: nil
            ),
        ]
        // Stored default points at OpenAI, but no OpenAI key is configured.
        state.setDefaultModelID("openai/gpt-5", for: .code)
        state.selectedModel = AIModel(
            provider: .appleFoundation,
            modelID: "system",
            displayName: "Apple Intelligence"
        )

        let applied = state.applyDefault(for: .code)

        // The stale default should be skipped, and the catalog fallback
        // should pick Anthropic (which has a key).
        XCTAssertEqual(applied?.provider, .anthropic)
    }

    // MARK: - Helpers

    /// Build a bare AppState backed by an in-memory secret store. The init
    /// fires a couple of background tasks (reconnect, marketplace refresh);
    /// we don't await them — the relevant unit under test only reads
    /// `selectedModel`, `providerResults`, and the secret store.
    private func makeState() -> AppState {
        AppState(secrets: InMemorySecretStore())
    }
}
