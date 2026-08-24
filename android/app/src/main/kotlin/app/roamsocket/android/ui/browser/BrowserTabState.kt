package app.roamsocket.android.ui.browser

import android.graphics.Bitmap
import android.webkit.WebView
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * One browser tab: owns its own [WebView] so navigation state (back
 * history, scroll position, form state) survives switching between tabs.
 *
 * The class is the tab *state* — it deliberately doesn't hold a reference
 * to the live WebView. Compose's `AndroidView` creates the actual WebView
 * per composition and bridges the two via [bindTo] / [unbind]. All action
 * methods call [evaluateJs] which dispatches to whichever WebView is
 * currently bound (set via [bindTo]).
 *
 * Mirrors the iOS `BrowserTab` (in `ios/App/Sources/Features/Browser/`)
 * so the Android browser exposes the same step-execution surface the AI
 * agent is allowed to call.
 */
class BrowserTabState(
    val id: String = java.util.UUID.randomUUID().toString(),
) {
    private val _urlString = MutableStateFlow("")
    val urlString: StateFlow<String> = _urlString.asStateFlow()

    private val _title = MutableStateFlow("New Tab")
    val title: StateFlow<String> = _title.asStateFlow()

    private val _isLoading = MutableStateFlow(false)
    val isLoading: StateFlow<Boolean> = _isLoading.asStateFlow()

    private val _estimatedProgress = MutableStateFlow(0.0)
    val estimatedProgress: StateFlow<Double> = _estimatedProgress.asStateFlow()

    private val _canGoBack = MutableStateFlow(false)
    val canGoBack: StateFlow<Boolean> = _canGoBack.asStateFlow()

    private val _canGoForward = MutableStateFlow(false)
    val canGoForward: StateFlow<Boolean> = _canGoForward.asStateFlow()

    private val _loadError = MutableStateFlow<String?>(null)
    val loadError: StateFlow<String?> = _loadError.asStateFlow()

    private val _snapshot = MutableStateFlow<Bitmap?>(null)
    val snapshot: StateFlow<Bitmap?> = _snapshot.asStateFlow()

    /**
     * The currently bound WebView. Set by the Compose `AndroidView` factory
     * so the state class can drive navigation and evaluate JS without
     * recreating the WebView on every recomposition.
     */
    private var webView: WebView? = null

    /**
     * URL captured by [loadUrl] before the WebView was bound. The first
     * call to [bindTo] (or the next [consumePendingUrl]) flushes it so
     * the address bar can drive navigation in the same frame the
     * `AndroidView` factory finishes creating the WebView.
     *
     * PR #96: without this, `goToAddress` on a brand-new tab (created
     * by `BrowserStore.goToAddress` when `activeTab == null`) was a
     * silent no-op because `webView?.loadUrl(...)` had nothing to call
     * yet — the user typed a URL, pressed Go, and saw the empty state.
     */
    private var pendingUrl: String? = null

    fun bindTo(view: WebView) {
        webView = view
        // Flush any URL captured before the WebView existed. Bound
        // callback observers (history, address bar) re-read the URL
        // from the WebViewClient's `onPageStarted`, so we don't need
        // to also push the value into `_urlString` here.
        val pending = pendingUrl
        if (pending != null) {
            pendingUrl = null
            view.loadUrl(pending)
        }
    }

    fun unbind(view: WebView) {
        if (webView === view) webView = null
    }

    // MARK: - State setters used by the WebViewClient / WebChromeClient

    fun setUrlString(s: String) {
        _urlString.value = s
    }

    fun setTitle(s: String) {
        if (s.isNotEmpty()) {
            _title.value = s
        } else {
            _title.value = if (_urlString.value.isEmpty()) "New Tab" else _urlString.value
        }
    }

    fun setIsLoading(loading: Boolean) {
        _isLoading.value = loading
    }

    fun setEstimatedProgress(p: Double) {
        _estimatedProgress.value = p
    }

    fun setCanGoBack(v: Boolean) {
        _canGoBack.value = v
    }

    fun setCanGoForward(v: Boolean) {
        _canGoForward.value = v
    }

    fun setLoadError(message: String?) {
        _loadError.value = message
    }

    fun setSnapshot(bitmap: Bitmap?) {
        _snapshot.value = bitmap
    }

    // MARK: - Navigation

    fun loadUrl(url: String) {
        _loadError.value = null
        val view = webView
        if (view != null) {
            view.loadUrl(url)
        } else {
            // PR #96: the WebView hasn't been bound yet (e.g. the user
            // hit Go on the very first address-bar submission, before
            // AndroidView's factory has run). Stash the URL so the
            // first `bindTo` call can flush it.
            pendingUrl = url
        }
    }

    fun goBack() {
        webView?.goBack()
    }

    fun goForward() {
        webView?.goForward()
    }

    fun reload() {
        webView?.reload()
    }

    fun stop() {
        webView?.stopLoading()
    }

    // MARK: - JS bridge

    /**
     * Run [js] in the page context. Returns the raw evaluation result
     * (string), or `null` on error. The agent-side scripts (see
     * `BrowserTabActions`) are designed to `JSON.stringify` their
     * payload so callers can decode it on the Kotlin side.
     */
    suspend fun evaluateJs(js: String): String? = BrowserJsBridge.eval(webView, js)

    fun snapshotForTabSwitcher() {
        val view = webView ?: return
        if (_urlString.value.isEmpty()) return
        // `Picture.capture` is the cheapest cross-version way to get a
        // thumbnail — no async round-trip, no permission gating. iOS uses
        // `WKSnapshotConfiguration`; this is the closest non-deprecated
        // Android equivalent.
        val picture = view.capturePicture()
        if (picture.width <= 0 || picture.height <= 0) return
        val bitmap = Bitmap.createBitmap(picture.width, picture.height, Bitmap.Config.ARGB_8888)
        val canvas = android.graphics.Canvas(bitmap)
        picture.draw(canvas)
        _snapshot.value = bitmap
    }
}
