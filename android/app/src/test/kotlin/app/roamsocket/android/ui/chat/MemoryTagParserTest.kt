package app.roamsocket.android.ui.chat

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Unit tests for the `<memory ... />` tag parser. Mirrors the iOS
 * `MemoryTagParser` tests at
 * `ios/App/Tests/MemoryTagParserTests.swift`. Each test pins one
 * shape of tag so a refactor that drops an action type fails fast.
 */
class MemoryTagParserTest {

    @Test
    fun parsesAddTag() {
        val reply = """
            Sure, I'll remember that. <memory action="add" category="you" title="Profile" summary="Lives in Colorado" details="Lives in|Colorado|Front Range" />
        """.trimIndent()
        val tags = MemoryTagParser.parse(reply)
        assertEquals(1, tags.size)
        val tag = tags[0] as MemoryTag.Add
        assertEquals("Profile", tag.title)
        assertEquals("Lives in Colorado", tag.summary)
        assertEquals("Lives in|Colorado|Front Range", tag.details)
        assertEquals("you", tag.category)
    }

    @Test
    fun parsesForgetTag() {
        val reply = """Got it, <memory action="forget" target="Verizon" />"""
        val tags = MemoryTagParser.parse(reply)
        assertEquals(1, tags.size)
        assertTrue(tags[0] is MemoryTag.Forget)
        assertEquals("Verizon", (tags[0] as MemoryTag.Forget).target)
    }

    @Test
    fun parsesRenameTag() {
        val reply = """Renamed. <memory action="rename" target="Profile" value="About me" />"""
        val tags = MemoryTagParser.parse(reply)
        assertEquals(1, tags.size)
        val tag = tags[0] as MemoryTag.Rename
        assertEquals("Profile", tag.target)
        assertEquals("About me", tag.value)
    }

    @Test
    fun parsesSetSummaryAndSetDetails() {
        val reply = """
            <memory action="set_summary" target="Profile" value="Newer summary" />
            <memory action="set_details" target="Profile" value="A|B|C" />
        """.trimIndent()
        val tags = MemoryTagParser.parse(reply)
        assertEquals(2, tags.size)
        assertTrue(tags[0] is MemoryTag.SetSummary)
        assertTrue(tags[1] is MemoryTag.SetDetails)
        assertEquals("Newer summary", (tags[0] as MemoryTag.SetSummary).value)
        assertEquals("A|B|C", (tags[1] as MemoryTag.SetDetails).value)
    }

    @Test
    fun parsesMultipleTagsInOneReply() {
        val reply = """
            <memory action="add" category="area" title="RoamSocket" summary="A mobile coding client" />
            Some prose.
            <memory action="forget" target="OldProject" />
        """.trimIndent()
        val tags = MemoryTagParser.parse(reply)
        assertEquals(2, tags.size)
        assertTrue(tags[0] is MemoryTag.Add)
        assertTrue(tags[1] is MemoryTag.Forget)
    }

    @Test
    fun stripsTagsFromVisibleReply() {
        val reply = "Sure, here you go. <memory action=\"add\" title=\"Profile\" summary=\"x\" />"
        val stripped = MemoryTagParser.stripTags(reply)
        assertEquals("Sure, here you go.", stripped)
    }

    @Test
    fun unknownActionIsDropped() {
        val reply = """<memory action="frobnicate" target="Profile" value="x" />"""
        val tags = MemoryTagParser.parse(reply)
        assertTrue(tags.isEmpty())
    }

    @Test
    fun missingRequiredAttributeIsDropped() {
        val reply = """<memory action="add" category="you" summary="x" />"""
        val tags = MemoryTagParser.parse(reply)
        assertTrue(tags.isEmpty())
    }
}

/**
 * Unit tests for the in-memory [MemoryStore].
 */
class MemoryStoreTest {

    @Test
    fun applyAddTracksActivity() {
        val store = MemoryStore()
        val entry = store.apply(
            MemoryTag.Add(
                title = "Profile",
                summary = "Lives in Colorado",
                details = "A|B",
                category = "you",
            ),
        )
        assertEquals(MemoryStore.Kind.ADD, entry.kind)
        assertEquals("Profile", entry.target)
        val saved = store.memories.value["Profile"]
        assertNotNull(saved)
        assertEquals("Lives in Colorado", saved!!.summary)
        assertEquals("A|B", saved.details)
    }

    @Test
    fun applyForgetDropsEntry() {
        val store = MemoryStore()
        store.apply(MemoryTag.Add("Profile", "x", "y", "you"))
        store.apply(MemoryTag.Forget("Profile"))
        assertNull(store.memories.value["Profile"])
    }

    @Test
    fun undoActivityRemovesEntry() {
        val store = MemoryStore()
        val entry = store.apply(MemoryTag.Add("Profile", "x", "y", "you"))
        store.undoActivity(entry.id)
        assertNull(store.memories.value["Profile"])
        assertTrue(store.activity.value.none { it.id == entry.id })
    }

    @Test
    fun undoUnknownIdIsNoOp() {
        val store = MemoryStore()
        assertNull(store.undoActivity("does-not-exist"))
    }

    @Test
    fun activityLogIsBounded() {
        val store = MemoryStore()
        repeat(70) { i ->
            store.apply(MemoryTag.Add("T$i", "s", "d", ""))
        }
        assertTrue(store.activity.value.size <= 64)
    }
}
