package app.roamsocket.android.ui.chat

import app.roamsocket.android.data.EffortLevel
import app.roamsocket.android.data.ToolAccessLevel
import app.roamsocket.android.ui.sidebar.ChatHistoryStore
import app.roamsocket.core.chats.ChatHistoryItem
import app.roamsocket.core.chats.InMemoryChatHistoryRepository
import app.roamsocket.core.chats.PersistedChatMessage
import app.roamsocket.core.projects.InMemoryProjectRepository
import app.roamsocket.core.providers.ModelProvider
import app.roamsocket.core.providers.ProviderId
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.Dispatchers as KDispatchers
import io.mockk.coEvery
import io.mockk.every
import io.mockk.mockk
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * Unit tests for port #9 (per-chat model selection).
 *
 * The repo's `setModel` is already covered by
 * `RoamSocketCore/.../InMemoryChatHistoryRepositoryTest`. These tests
 * instead exercise the new wiring inside [ChatViewModel]:
 *
 * 1. On open, a chat row that carries a `(provider, model)` override
 *    has the override applied to `_state`, not the global default.
 * 2. On open, a chat row without an override keeps the global default
 *    (the existing init behaviour is unchanged).
 * 3. `selectModel` on an active chat writes the new model id into the
 *    repo via `setModel(...)`.
 * 4. `selectModel` on a blank draft does NOT eagerly mint a chat row
 *    — the first `send` is the trigger that stamps the model via
 *    `persistCurrent`.
 * 5. `persistCurrent` on a previously-blank draft mints a chat id,
 *    persists the transcript, and stamps the current `(provider, model)`
 *    onto the new row in the same step.
 * 6. `selectProvider` on an active chat writes the new provider into
 *    the repo (no blank-draft side effect).
 * 7. On open, a row with an unrecognised `selectedProvider` raw value
 *    falls back to the global default provider while still restoring
 *    the model id verbatim (matches iOS `restoreSelectedModel`).
 *
 * Uses a relaxed [io.mockk.mockk] of [app.roamsocket.android.AppContainer]
 * with a real [InMemoryChatHistoryRepository] swapped in for the
 * `chatHistoryRepository` field — every other container dependency is
 * stubbed to its no-op default. [viewModelScope] is bridged onto a
 * [StandardTestDispatcher] via `Dispatchers.setMain` so the init's
 * `launch { ... }` block runs to completion when [advanceUntilIdle] is
 * called.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class ChatViewModelPerChatModelTest {

    private lateinit var scheduler: kotlinx.coroutines.test.TestCoroutineScheduler
    private lateinit var dispatcher: kotlinx.coroutines.test.TestDispatcher
    private lateinit var repo: InMemoryChatHistoryRepository
    private lateinit var viewModel: ChatViewModel

    @Before
    fun setUp() {
        scheduler = kotlinx.coroutines.test.TestCoroutineScheduler()
        // `StandardTestDispatcher(...)` is a factory function (not a class)
        // in kotlinx-coroutines 1.9.x. The returned `TestDispatcher`
        // shares our scheduler so `advanceUntilIdle()` drains it.
        dispatcher = kotlinx.coroutines.test.StandardTestDispatcher(scheduler)
        Dispatchers.setMain(dispatcher)
        repo = InMemoryChatHistoryRepository()
    }

    @After
    fun tearDown() {
        Dispatchers.resetMain()
    }

    /**
     * Build a [ChatViewModel] whose container is fully relaxed except
     * for the few fields this test actually exercises. The `chatClientFor`
     * stub returns a relaxed [ModelProvider] whose `chat(...)` returns
     * a canned "OK" reply so the `send` path can complete.
     */
    private fun newViewModel(chatId: String?): ChatViewModel {
        val container = mockk<app.roamsocket.android.AppContainer>(relaxed = true)
        every { container.chatHistoryRepository } returns repo
        every { container.userSettings.currentProvider } returns flowOf(ProviderId.Anthropic)
        every { container.userSettings.currentModel } returns flowOf("claude-3-5-sonnet-20241022")
        every { container.userSettings.researchEnabled } returns flowOf(false)
        every { container.userSettings.webSearchEnabled } returns flowOf(false)
        every { container.userSettings.locationEnabled } returns flowOf(false)
        every { container.userSettings.toolAccess } returns flowOf(ToolAccessLevel.Auto)
        every { container.userSettings.alwaysExpandThinking } returns flowOf(false)
        every { container.userSettings.effort } returns flowOf(EffortLevel.High)
        every { container.userSettings.studyModeEnabled } returns flowOf(false)
        // No API key in tests → `hasApiKey = false` after init.
        coEvery { container.secretStore.readApiKey(any()) } returns null
        // Stub the live-list fetch + setCurrent to no-ops.
        coEvery { container.userSettings.setCurrent(any(), any()) } returns Unit
        // Stub the chat client so `send` can complete. A relaxed mock
        // returns "" for the suspend `chat(...)` which is enough for
        // the persistence path to land. The streaming path uses `chatStream`
        // which must also return a valid Flow.
        val fakeProvider = mockk<ModelProvider>(relaxed = true)
        coEvery { fakeProvider.chat(any(), any(), any(), any(), any()) } returns "OK"
        coEvery { fakeProvider.chatStream(any(), any(), any(), any(), any()) } returns kotlinx.coroutines.flow.flowOf("OK")
        every { fakeProvider.id } returns ProviderId.Anthropic
        every { container.chatClientFor(any()) } returns fakeProvider
        // Phase 1 (Android Projects): provide a real ChatHistoryStore
        // backed by the same in-memory chat repo and a fresh
        // InMemoryProjectRepository so the relaxed mock doesn't
        // accidentally satisfy the project-match path with mock
        // projects. Phase 1 doesn't touch the tests' chat rows
        // (they're all in the global repo, not any project), so an
        // empty project repo is the correct setup.
        every { container.chatHistoryStore } returns ChatHistoryStore(
            repository = repo,
            projectRepository = InMemoryProjectRepository(),
            flowScope = CoroutineScope(SupervisorJob() + KDispatchers.Unconfined),
        )
        return ChatViewModel(container, chatId)
    }

    @Test
    fun `init restores per-chat model override from the repo row`() = runTest(dispatcher) {
        // Pre-seed a chat with an override that differs from the global default.
        val id = repo.startNewChat()
        repo.saveMessages(
            id,
            listOf(
                PersistedChatMessage(
                    id = "u-1",
                    role = PersistedChatMessage.Role.USER,
                    content = "hi",
                    timestampMillis = 1L,
                ),
                PersistedChatMessage(
                    id = "a-1",
                    role = PersistedChatMessage.Role.ASSISTANT,
                    content = "hello",
                    timestampMillis = 2L,
                ),
            ),
        )
        repo.setModel(id, ProviderId.OpenAI, "gpt-4o")

        viewModel = newViewModel(chatId = id)
        advanceUntilIdle()

        val state = viewModel.state.value
        assertEquals(ProviderId.OpenAI, state.provider)
        assertEquals("gpt-4o", state.model)
    }

    @Test
    fun `init without per-chat override keeps the global default`() = runTest(dispatcher) {
        val id = repo.startNewChat()
        repo.saveMessages(
            id,
            listOf(
                PersistedChatMessage(
                    id = "u-1",
                    role = PersistedChatMessage.Role.USER,
                    content = "hi",
                    timestampMillis = 1L,
                ),
            ),
        )
        // Intentionally no setModel call.

        viewModel = newViewModel(chatId = id)
        advanceUntilIdle()

        val state = viewModel.state.value
        assertEquals(ProviderId.Anthropic, state.provider)
        assertEquals("claude-3-5-sonnet-20241022", state.model)
        assertFalse(repo.snapshot().first { it.id == id }.hasModelOverride)
    }

    @Test
    fun `init on a chat with unrecognised provider falls back to the global default`() = runTest(dispatcher) {
        // Persist a row with a garbage provider raw value. The helper
        // `setModel` would write a real ProviderId, so we go through
        // `replaceAll` to inject the malformed row directly.
        val id = "stale-chat"
        val item = ChatHistoryItem(
            id = id,
            title = "stale",
            lastMessageAtMillis = 1L,
            messages = listOf(
                PersistedChatMessage(
                    id = "u-1",
                    role = PersistedChatMessage.Role.USER,
                    content = "hi",
                    timestampMillis = 1L,
                ),
            ),
            selectedProvider = "unknown-vendor",
            selectedModel = "some-model",
        )
        repo.replaceAll(listOf(item))

        viewModel = newViewModel(chatId = id)
        advanceUntilIdle()

        // `resolvedProvider` is null for the garbage raw value; the
        // restore code falls back to the global default (Anthropic in
        // this test) instead of leaving a junk provider on `_state`.
        val state = viewModel.state.value
        assertEquals(ProviderId.Anthropic, state.provider)
        // The model id is still restored verbatim so the pill + next
        // send keep targeting the same id even if the live list
        // dropped it (matches iOS `restoreSelectedModel`).
        assertEquals("some-model", state.model)
        // The persisted row is untouched — the restore is in-memory only.
        val stored = repo.snapshot().first { it.id == id }
        assertEquals("unknown-vendor", stored.selectedProvider)
    }

    @Test
    fun `selectModel on an active chat persists the new model id to the repo`() = runTest(dispatcher) {
        val id = repo.startNewChat()
        repo.saveMessages(
            id,
            listOf(
                PersistedChatMessage(
                    id = "u-1",
                    role = PersistedChatMessage.Role.USER,
                    content = "hi",
                    timestampMillis = 1L,
                ),
            ),
        )

        viewModel = newViewModel(chatId = id)
        advanceUntilIdle()

        viewModel.selectModel("claude-3-5-sonnet-latest")
        advanceUntilIdle()

        val updated = repo.snapshot().first { it.id == id }
        assertTrue(updated.hasModelOverride)
        assertEquals(ProviderId.Anthropic, updated.resolvedProvider)
        assertEquals("claude-3-5-sonnet-latest", updated.selectedModel)
    }

    @Test
    fun `selectModel on a blank draft does not write to the repo`() = runTest(dispatcher) {
        // No chat id passed in → view-model starts on a blank draft.
        viewModel = newViewModel(chatId = null)
        advanceUntilIdle()

        // The in-memory repo only has the empty default state — no chat
        // row exists yet, so the persist helper is a no-op.
        assertEquals(0, repo.snapshot().size)

        viewModel.selectModel("claude-3-5-sonnet-latest")
        advanceUntilIdle()

        // Still no row was minted — the first send is the trigger.
        assertEquals(0, repo.snapshot().size)
    }

    @Test
    fun `selectProvider on an active chat persists the new provider to the repo`() = runTest(dispatcher) {
        val id = repo.startNewChat()
        repo.saveMessages(
            id,
            listOf(
                PersistedChatMessage(
                    id = "u-1",
                    role = PersistedChatMessage.Role.USER,
                    content = "hi",
                    timestampMillis = 1L,
                ),
            ),
        )

        viewModel = newViewModel(chatId = id)
        advanceUntilIdle()

        viewModel.selectProvider(ProviderId.Google)
        advanceUntilIdle()

        // `selectProvider` clears the model until the live list lands,
        // so the persisted row carries an empty `selectedModel` and
        // `hasModelOverride` is still false. The provider raw value is
        // what we just wrote — that's the bit the next open would
        // restore from.
        val updated = repo.snapshot().first { it.id == id }
        assertEquals(ProviderId.Google.rawValue, updated.selectedProvider)
        assertEquals("", updated.selectedModel)
    }

    @Test
    fun `persistCurrent on a previously-blank draft stamps the current model`() = runTest(dispatcher) {
        // User opens a brand-new chat (no id), picks a model in the
        // picker, then sends their first message. The view-model mints
        // a chat id during `persistCurrent` and stamps the per-chat
        // model on the new row in the same step.
        viewModel = newViewModel(chatId = null)
        advanceUntilIdle()

        // Simulate the user picking a model on the blank draft.
        viewModel.selectModel("claude-3-5-sonnet-latest")
        advanceUntilIdle()

        // First send → `persistCurrent` mints a new chat id, saves the
        // message, and stamps the current `(provider, model)` onto the
        // new row.
        viewModel.send("hello")
        advanceUntilIdle()

        val items = repo.snapshot()
        assertEquals(1, items.size)
        val newItem: ChatHistoryItem = items.first()
        assertTrue(newItem.hasModelOverride)
        assertEquals(ProviderId.Anthropic, newItem.resolvedProvider)
        assertEquals("claude-3-5-sonnet-latest", newItem.selectedModel)
        // The user message and assistant placeholder are both persisted
        // (streaming mode persists the assistant immediately so the UI
        // can update incrementally as chunks arrive). This proves the send
        // path ran through `persistCurrent`.
        assertEquals(2, newItem.messages.size)
        assertEquals(PersistedChatMessage.Role.USER, newItem.messages.first().role)
        assertEquals(PersistedChatMessage.Role.ASSISTANT, newItem.messages.last().role)
    }

    @Test
    fun `persistCurrent on a blank draft stamps even when no model is picked`() = runTest(dispatcher) {
        // Edge case: user opens a brand-new chat and sends the first
        // message without ever touching the model picker. The model on
        // `_state` is the global default; that gets stamped.
        viewModel = newViewModel(chatId = null)
        advanceUntilIdle()

        assertEquals("claude-3-5-sonnet-20241022", viewModel.state.value.model)

        viewModel.send("hello")
        advanceUntilIdle()

        val items = repo.snapshot()
        assertEquals(1, items.size)
        val newItem: ChatHistoryItem = items.first()
        assertTrue(newItem.hasModelOverride)
        assertEquals("claude-3-5-sonnet-20241022", newItem.selectedModel)
    }

    @Test
    fun `init with no chat id and no row leaves the state at the global default`() = runTest(dispatcher) {
        // Edge case: brand-new chat, no row in the repo, no override.
        // The global default applies (matches the iOS `applyDefault(for: .chat)`
        // no-op path).
        viewModel = newViewModel(chatId = null)
        advanceUntilIdle()

        val state = viewModel.state.value
        assertEquals(ProviderId.Anthropic, state.provider)
        assertEquals("claude-3-5-sonnet-20241022", state.model)
        // No chat row was created — the repo stays empty.
        assertEquals(0, repo.snapshot().size)
    }

    @Test
    fun `init on a chat id that is not in the repo is a no-op for the per-chat model`() = runTest(dispatcher) {
        // Edge case: view-model was constructed with a chat id but the
        // repo has no matching row (e.g. the user just deleted it). The
        // global default applies and no row is created.
        viewModel = newViewModel(chatId = "missing")
        advanceUntilIdle()

        val state = viewModel.state.value
        assertEquals(ProviderId.Anthropic, state.provider)
        assertEquals("claude-3-5-sonnet-20241022", state.model)
        assertEquals(0, repo.snapshot().size)
        // Sanity: the `repoItem` is null so the restore branch is
        // skipped entirely — nothing was written back to the repo.
        assertNull(repo.activeChatId)
    }

    @Test
    fun `setModel is exposed on the in-memory repo and the no-op on unknown id is honoured`() = runTest(dispatcher) {
        // Sanity check: the data layer's `setModel` is a no-op when the
        // chat id doesn't exist, so a stale `persistModelForActiveChat`
        // call doesn't accidentally create a new row.
        repo.setModel("never-existed", ProviderId.OpenAI, "gpt-4o")
        assertTrue(repo.snapshot().isEmpty())
        assertNotNull(repo)
    }
}
