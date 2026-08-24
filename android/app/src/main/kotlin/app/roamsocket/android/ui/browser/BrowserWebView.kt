package app.roamsocket.android.ui.browser

import android.annotation.SuppressLint
import android.view.ViewGroup
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.viewinterop.AndroidView

/**
 * Compose wrapper around the platform [WebView]. Bridges the tab's
 * [BrowserTabState] to the actual WebView instance via [AndroidView]'s
 * factory/update pair, and forwards WebView callbacks back to the state
 * (URL/title/loading/progress/nav buttons).
 *
 * Mirrors the iOS `BrowserWebViewRepresentable` (in `BrowserView.swift`)
 * — a thin `WKWebView` holder — but uses Android's [WebView] +
 * [WebViewClient] because Compose has no first-party browser component.
 */
@SuppressLint("SetJavaScriptEnabled")
@Composable
fun BrowserWebView(
    tab: BrowserTabState,
    onPageFinished: (BrowserTabState) -> Unit,
    modifier: Modifier = Modifier,
) {
    AndroidView(
        modifier = modifier.fillMaxSize(),
        factory = { context ->
            WebView(context).apply {
                layoutParams = ViewGroup.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.MATCH_PARENT,
                )
                settings.javaScriptEnabled = true
                settings.domStorageEnabled = true
                settings.loadWithOverviewMode = true
                settings.useWideViewPort = true
                settings.builtInZoomControls = true
                settings.displayZoomControls = false
                settings.setSupportZoom(true)
                settings.javaScriptCanOpenWindowsAutomatically = false
                settings.allowFileAccess = false
                settings.allowContentAccess = false
                settings.mediaPlaybackRequiresUserGesture = true
                webChromeClient = ChromeClient(tab)
                webViewClient = ViewClient(tab, onPageFinished)
            }.also { tab.bindTo(it) }
        },
        update = { /* state writes happen via the WebViewClient/ChromeClient callbacks */ },
        onRelease = { view -> tab.unbind(view) },
    )
}

private class ViewClient(
    private val tab: BrowserTabState,
    private val onPageFinished: (BrowserTabState) -> Unit,
) : WebViewClient() {
    override fun onPageStarted(view: WebView, url: String?, favicon: android.graphics.Bitmap?) {
        super.onPageStarted(view, url, favicon)
        tab.setIsLoading(true)
        tab.setUrlString(url.orEmpty())
    }

    override fun onPageFinished(view: WebView, url: String?) {
        super.onPageFinished(view, url)
        tab.setIsLoading(false)
        tab.setEstimatedProgress(1.0)
        tab.setUrlString(url.orEmpty())
        tab.setCanGoBack(view.canGoBack())
        tab.setCanGoForward(view.canGoForward())
        tab.setTitle(view.title.orEmpty())
        onPageFinished(tab)
    }

    override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
        // External schemes (mailto:, tel:, market:, etc.) should be left to
        // the OS, not loaded into the in-app browser. Otherwise navigate in
        // place so back-button history is preserved.
        val url = request.url?.toString().orEmpty()
        if (url.startsWith("mailto:") || url.startsWith("tel:") ||
            url.startsWith("market:") || url.startsWith("intent:")
        ) {
            return true
        }
        return false
    }

    override fun doUpdateVisitedHistory(view: WebView, url: String?, isReload: Boolean) {
        super.doUpdateVisitedHistory(view, url, isReload)
        tab.setCanGoBack(view.canGoBack())
        tab.setCanGoForward(view.canGoForward())
    }

    override fun onReceivedError(
        view: WebView,
        request: WebResourceRequest,
        error: android.webkit.WebResourceError,
    ) {
        super.onReceivedError(view, request, error)
        // Only surface the error if the error is for the main frame — sub-resource
        // 404s on a healthy page shouldn't be presented as a page error.
        if (request.isForMainFrame) {
            tab.setLoadError("Couldn't load page (${error.errorCode}).")
            tab.setIsLoading(false)
        }
    }
}

private class ChromeClient(private val tab: BrowserTabState) : WebChromeClient() {
    override fun onProgressChanged(view: WebView, newProgress: Int) {
        tab.setEstimatedProgress(newProgress.toDouble() / 100.0)
    }

    override fun onReceivedTitle(view: WebView, title: String?) {
        tab.setTitle(title.orEmpty())
    }
}
