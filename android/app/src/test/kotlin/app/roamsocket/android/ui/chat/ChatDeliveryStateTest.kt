package app.roamsocket.android.ui.chat

import app.roamsocket.core.chats.PersistedChatMessage
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

/**
 * Unit tests for the in-memory delivery-state logic on
 * [ChatMessage.User]. These are pure data-class checks; the actual
 * API call path is exercised by `assembleDebug` + the live chat
 * surface.
 */
class ChatDeliveryStateTest {

    @Test
    fun freshUserMessageDefaultsToSent() {
        val msg = ChatMessage.User(text = "hi")
        assertEquals(ChatMessage.User.Delivery.SENT, msg.delivery)
    }

    @Test
    fun markingFailedPreservesTheOriginalText() {
        val msg = ChatMessage.User(text = "Why?", delivery = ChatMessage.User.Delivery.FAILED, failureReason = "boom")
        assertEquals("Why?", msg.text)
        assertEquals(ChatMessage.User.Delivery.FAILED, msg.delivery)
        assertEquals("boom", msg.failureReason)
    }

    @Test
    fun retryRecoversFromFailedWithoutLosingText() {
        val failed = ChatMessage.User(text = "retry me", delivery = ChatMessage.User.Delivery.FAILED, failureReason = "boom")
        val recovered = failed.copy(delivery = ChatMessage.User.Delivery.SENT, failureReason = null)
        assertEquals("retry me", recovered.text)
        assertEquals(ChatMessage.User.Delivery.SENT, recovered.delivery)
        assertEquals(null, recovered.failureReason)
    }

    @Test
    fun deliveryStateRoundtripsThroughPersistence() {
        val msg = ChatMessage.User(text = "ping", delivery = ChatMessage.User.Delivery.FAILED, failureReason = "x")
        val persisted = msg.toPersisted()
        assertEquals(PersistedChatMessage.Delivery.FAILED, persisted.delivery)
        val back = persisted.toUi() as ChatMessage.User
        assertEquals(ChatMessage.User.Delivery.FAILED, back.delivery)
        assertEquals("ping", back.text)
    }

    @Test
    fun persistedPendingDeliveryBecomesUiPending() {
        val persisted = PersistedChatMessage(
            id = "u-1",
            role = PersistedChatMessage.Role.USER,
            content = "mid-flight",
            timestampMillis = 1L,
            delivery = PersistedChatMessage.Delivery.PENDING,
        )
        val ui = persisted.toUi() as ChatMessage.User
        assertEquals(ChatMessage.User.Delivery.PENDING, ui.delivery)
        assertNotEquals(ChatMessage.User.Delivery.FAILED, ui.delivery)
    }
}
