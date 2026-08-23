package app.roamsocket.android.ui.settings

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

class PairPayloadParserTest {

    @Test
    fun bareSixCharCode() {
        val r = parsePairPayload("ABC123")
        assertNotNull(r)
        assertEquals("ABC123", r!!.code)
        assertEquals("", r.host)
    }

    @Test
    fun jsonPayload() {
        val r = parsePairPayload("""{"host":"192.168.1.20:4319","code":"ABC123"}""")
        assertNotNull(r)
        assertEquals("192.168.1.20:4319", r!!.host)
        assertEquals("ABC123", r.code)
    }

    @Test
    fun anyprovUrlPayload() {
        val r = parsePairPayload("anyprov://pair?host=192.168.1.20:4319&code=XYZ789")
        assertNotNull(r)
        assertEquals("192.168.1.20:4319", r!!.host)
        assertEquals("XYZ789", r.code)
    }

    @Test
    fun roamsocketUrlPayload() {
        val r = parsePairPayload("roamsocket://pair?host=desktop.local&code=ZZZ999")
        assertNotNull(r)
        assertEquals("desktop.local", r!!.host)
        assertEquals("ZZZ999", r.code)
    }

    @Test
    fun bareQueryString() {
        val r = parsePairPayload("?host=10.0.0.5:4319&code=QWE111")
        assertNotNull(r)
        assertEquals("10.0.0.5:4319", r!!.host)
        assertEquals("QWE111", r.code)
    }

    @Test
    fun urlEncodedHost() {
        val r = parsePairPayload("roamsocket://pair?host=192.168.1.10%3A4319&code=ABC123")
        assertNotNull(r)
        assertEquals("192.168.1.10:4319", r!!.host)
        assertEquals("ABC123", r.code)
    }

    @Test
    fun garbageReturnsNull() {
        assertNull(parsePairPayload(""))
        assertNull(parsePairPayload("not a qr"))
        assertNull(parsePairPayload("{}"))
    }
}
