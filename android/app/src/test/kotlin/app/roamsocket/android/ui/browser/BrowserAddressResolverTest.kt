package app.roamsocket.android.ui.browser

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Mirrors the iOS `BrowserAddressResolverTests` — keeps the resolver's
 * "bare host → https, anything else → Google search" rule honest as
 * the surface area grows.
 */
class BrowserAddressResolverTest {

    @Test fun `blank input yields null`() {
        assertNull(BrowserAddressResolver.resolve(""))
        assertNull(BrowserAddressResolver.resolve("   "))
    }

    @Test fun `bare host is upgraded to https`() {
        assertEquals("https://example.com", BrowserAddressResolver.resolve("example.com"))
        assertEquals("https://docs.example.com/path", BrowserAddressResolver.resolve("docs.example.com/path"))
    }

    @Test fun `scheme-prefixed URL is passed through unchanged`() {
        assertEquals("http://example.com", BrowserAddressResolver.resolve("http://example.com"))
        assertEquals("https://example.com/foo?bar=1", BrowserAddressResolver.resolve("https://example.com/foo?bar=1"))
        assertEquals("ftp://example.com", BrowserAddressResolver.resolve("ftp://example.com"))
    }

    @Test fun `search query is routed through Google`() {
        val resolved = BrowserAddressResolver.resolve("kotlin coroutines")
        assertNotNull(resolved)
        // Must be a Google search URL with the query url-encoded.
        assert(resolved!!.startsWith("https://www.google.com/search?q=")) {
            "expected Google search URL, got $resolved"
        }
        assert(resolved.contains("kotlin%20coroutines") || resolved.contains("kotlin+coroutines")) {
            "expected query to be url-encoded, got $resolved"
        }
    }

    @Test fun `single-word input without a dot becomes a search`() {
        // A single token with no dot looks like neither a URL nor a
        // hostname, so it must fall through to the search path.
        val resolved = BrowserAddressResolver.resolve("roamsocket")
        assertNotNull(resolved)
        assert(resolved!!.startsWith("https://www.google.com/search?q="))
    }

    @Test fun `whitespace around input is trimmed`() {
        assertEquals("https://example.com", BrowserAddressResolver.resolve("  example.com  "))
    }
}
