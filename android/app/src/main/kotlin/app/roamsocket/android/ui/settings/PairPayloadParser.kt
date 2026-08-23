package app.roamsocket.android.ui.settings

import java.net.URLDecoder

/**
 * Parsed `host` + `code` from a desktop QR. Mirrors the iOS
 * `PairQRScannerView.parsePairPayload` in
 * `ios/.../Settings/PairQRScannerView.swift`:
 *
 *  - JSON `{"host":"…","code":"…"}`
 *  - URL `anyprov://pair?host=…&code=…` or `roamsocket://pair?…`
 *  - URL with `?host=…&code=…` (no scheme)
 *  - bare 6-character alphanumeric code
 */
data class PairPayload(val host: String, val code: String) {
    val isHost: Boolean get() = host.isNotEmpty()
}

/**
 * Tolerant parser — accepts any of the formats the iOS scanner
 * accepts and returns null when nothing parseable comes out.
 */
fun parsePairPayload(raw: String): PairPayload? {
    val trimmed = raw.trim()
    if (trimmed.isEmpty()) return null

    // Bare 6-char code (alphanumeric, no spaces) — covers the most
    // common print/console paste scenario.
    if (!trimmed.contains(' ') && !trimmed.contains('{') && !trimmed.contains("://") &&
        !trimmed.contains('?') && !trimmed.contains('=') &&
        trimmed.length in 4..8 && trimmed.all { it.isLetterOrDigit() }
    ) {
        return PairPayload(host = "", code = trimmed.uppercase())
    }

    // JSON {"host": "...", "code": "..."}
    if (trimmed.startsWith("{")) {
        val host = jsonField(trimmed, "host")
        val code = jsonField(trimmed, "code")
        if (host != null || code != null) {
            return PairPayload(host = host.orEmpty(), code = (code ?: "").uppercase())
        }
    }

    // URL form: anyprov://pair?host=…&code=…  (or roamsocket://, or
    // bare ?host=…&code=… with no scheme).
    if (trimmed.contains("://") || trimmed.contains('?')) {
        val urlResult = tryParseUrl(trimmed)
        if (urlResult != null) return urlResult
    }

    return null
}

private fun jsonField(text: String, key: String): String? {
    val regex = Regex("\"$key\"\\s*:\\s*\"([^\"]+)\"")
    return regex.find(text)?.groupValues?.get(1)
}

private fun tryParseUrl(raw: String): PairPayload? {
    val query = when {
        raw.contains("://") -> {
            val q = raw.substringAfter('?', missingDelimiterValue = "")
            if (q.isEmpty()) return null
            q
        }
        raw.contains('?') -> raw.substringAfter('?')
        else -> return null
    }
    val params = query.split('&').mapNotNull { part ->
        val eq = part.indexOf('=')
        if (eq < 0) null else part.substring(0, eq) to URLDecoder.decode(part.substring(eq + 1), "UTF-8")
    }.toMap()
    val host = params["host"].orEmpty()
    val code = params["code"].orEmpty()
    if (host.isEmpty() && code.isEmpty()) return null
    return PairPayload(host = host, code = code.uppercase())
}
