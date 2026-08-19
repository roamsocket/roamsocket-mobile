package app.roamsocket.core.server

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

class EndpointTest {

    @Test
    fun `bare host gets default port and http scheme`() {
        val ep = Endpoint.fromHost("192.168.1.20")
        assertNotNull(ep)
        assertEquals("http://192.168.1.20:4319", ep!!.baseURL)
    }

    @Test
    fun `host with port preserves the port`() {
        val ep = Endpoint.fromHost("desktop.local:5000")
        assertNotNull(ep)
        assertEquals("http://desktop.local:5000", ep!!.baseURL)
    }

    @Test
    fun `host with scheme preserves it`() {
        val ep = Endpoint.fromHost("https://example.com:8443")
        assertNotNull(ep)
        assertEquals("https://example.com:8443", ep!!.baseURL)
    }

    @Test
    fun `trailing slashes are dropped`() {
        val ep = Endpoint.fromHost("https://example.com:443/")
        assertNotNull(ep)
        assertEquals("https://example.com:443", ep!!.baseURL)
    }

    @Test
    fun `empty input is rejected`() {
        assertNull(Endpoint.fromHost(""))
        assertNull(Endpoint.fromHost("   "))
    }

    @Test
    fun `host with no port defaults to 4319`() {
        val ep = Endpoint.fromHost("desktop.local")
        assertNotNull(ep)
        assertEquals("http://desktop.local:4319", ep!!.baseURL)
    }
}
