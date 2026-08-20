package app.roamsocket.android.data

import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import app.roamsocket.core.chats.PersistedChatMessage
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

/**
 * End-to-end persistence test for the chat history DataStore wrapper.
 * Uses Robolectric to host a real `Context` + DataStore.
 */
@RunWith(AndroidJUnit4::class)
@Config(manifest = Config.NONE, sdk = [34])
class DataStoreChatHistoryRepositoryTest {

    private lateinit var context: android.content.Context
    private val testScope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)

    @Before
    fun setUp() {
        context = ApplicationProvider.getApplicationContext()
    }

    @After
    fun tearDown() {
        // Wipe the DataStore file so each test starts from a blank history.
        runBlocking {
            val file = java.io.File(
                context.filesDir.parentFile,
                "datastore/roamsocket_chat_history.preferences_pb",
            )
            if (file.exists()) file.delete()
        }
    }

    @Test
    fun newChatIsPersistedAcrossInstances() = runBlocking {
        val first = DataStoreChatHistoryRepository(context, testScope)
        first.awaitReady()
        val id = first.startNewChat()
        first.saveMessages(
            id,
            listOf(
                PersistedChatMessage(id = "u-1", role = PersistedChatMessage.Role.USER, content = "hi", timestampMillis = 1L),
                PersistedChatMessage(id = "a-1", role = PersistedChatMessage.Role.ASSISTANT, content = "hello", timestampMillis = 2L),
            ),
        )
        // Wait for the persist collector to flush.
        delay(50)

        val second = DataStoreChatHistoryRepository(context, testScope)
        second.awaitReady()
        val resumed = second.snapshot().firstOrNull { it.id == id }
        assertTrue("chat $id should have been persisted", resumed != null)
        assertEquals(2, resumed!!.messages.size)
        assertEquals("hi", resumed.messages[0].content)
        assertEquals("hello", resumed.messages[1].content)
    }
}
