package app.roamsocket.android.data

import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import app.roamsocket.core.chats.PersistedChatMessage
import app.roamsocket.core.providers.AIModel
import app.roamsocket.core.providers.ProviderId
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

/**
 * End-to-end persistence test for the project DataStore wrapper.
 * Mirrors `DataStoreChatHistoryRepositoryTest`.
 */
@RunWith(AndroidJUnit4::class)
@Config(manifest = Config.NONE, sdk = [34])
class DataStoreProjectRepositoryTest {

    private lateinit var context: android.content.Context
    private val testScope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)

    @Before
    fun setUp() {
        context = ApplicationProvider.getApplicationContext()
    }

    @After
    fun tearDown() {
        runBlocking {
            val file = java.io.File(
                context.filesDir.parentFile,
                "datastore/roamsocket_projects.preferences_pb",
            )
            if (file.exists()) file.delete()
        }
    }

    @Test
    fun projectStateSurvivesAcrossInstances() = runBlocking {
        val first = DataStoreProjectRepository(context, testScope)
        first.awaitReady()
        val p = first.createProject("Phase 1")
        first.updateProjectMemory(p.id, "hello world")
        first.setActiveProject(p.id)
        // Allow the persist collector to flush.
        delay(80)

        val second = DataStoreProjectRepository(context, testScope)
        second.awaitReady()
        val resumed = second.snapshot().projects.firstOrNull { it.id == p.id }
        assertNotNull("project $p.id should be persisted", resumed)
        assertEquals("hello world", resumed!!.memory)
        assertEquals(p.id, second.snapshot().activeProjectId)
    }

    @Test
    fun projectChatMessagesSurviveAcrossInstances() = runBlocking {
        val first = DataStoreProjectRepository(context, testScope)
        first.awaitReady()
        val p = first.createProject("Phase 1")
        val chat = first.startNewChatInProject(
            p.id,
            selectedModel = AIModel(
                provider = ProviderId.Anthropic,
                modelID = "claude-3-5-sonnet-20241022",
                displayName = "Claude 3.5 Sonnet",
            ),
        )
        first.saveProjectChatMessages(
            p.id, chat.id,
            listOf(
                PersistedChatMessage(
                    id = "u-1", role = PersistedChatMessage.Role.USER,
                    content = "hello", timestampMillis = 1L,
                ),
            ),
        )
        delay(200)

        val second = DataStoreProjectRepository(context, testScope)
        second.awaitReady()
        val messages = second.projectChatMessages(p.id, chat.id)
        assertEquals(1, messages.size)
        assertEquals("hello", messages[0].content)
        assertTrue(
            second.projectChats.value[p.id]?.firstOrNull { it.id == chat.id }?.selectedModel != null,
        )
    }
}
