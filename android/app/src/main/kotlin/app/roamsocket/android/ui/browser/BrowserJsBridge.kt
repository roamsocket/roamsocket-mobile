package app.roamsocket.android.ui.browser

import android.webkit.WebView
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import kotlin.coroutines.resume

/**
 * Coroutine-friendly wrapper around [WebView.evaluateJavascript].
 *
 * Android's `WebView.evaluateJavascript` is a fire-and-forget callback API
 * that must be called on the WebView's thread. The agent code needs to
 * `await` each script, so this helper marshals to the WebView thread and
 * suspends until the callback (or the supplied timeout) returns.
 *
 * Mirrors the iOS pattern in `BrowserTab.evaluateJS` but uses Android's
 * `runOnUiThread` + `Looper` plumbing instead of `async/await` on
 * `WKWebView`.
 */
object BrowserJsBridge {
    /**
     * How long a single JS call is allowed to take before we give up and
     * return `null`. The WebView's underlying V8 instance is single-threaded
     * for the page world, so a runaway script could otherwise block every
     * subsequent agent call. 8s is generous — most agent scripts complete
     * in tens of ms — but long enough that an idle/loading page can finish
     * its first paint before the timeout fires.
     */
    private const val DEFAULT_TIMEOUT_MS: Long = 8_000L

    suspend fun eval(
        webView: WebView?,
        js: String,
        timeoutMs: Long = DEFAULT_TIMEOUT_MS,
    ): String? {
        if (webView == null) return null
        // `WebView` doesn't expose an `isDestroyed` flag (and accessing the
        // native handle after `destroy()` is undefined). The
        // `evaluateJavascript` call below is wrapped in try/catch so a
        // destroyed view just yields `null` instead of crashing the
        // coroutine.
        return withContext(Dispatchers.Main) {
            withTimeoutOrNull(timeoutMs) {
                suspendCancellableCoroutine<String?> { cont ->
                    try {
                        webView.evaluateJavascript(js) { raw ->
                            // `evaluateJavascript` wraps JSON primitives
                            // (`null`, numbers, booleans) as JSON strings
                            // and pre-stringifies object results, so the
                            // callback always receives a String. We pass
                            // it through unchanged and let the action
                            // scripts decode it.
                            cont.resume(raw)
                        }
                    } catch (t: Throwable) {
                        cont.resume(null)
                    }
                }
            }
        }
    }
}
