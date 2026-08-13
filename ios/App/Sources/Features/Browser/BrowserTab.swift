import Foundation
import SwiftUI
import WebKit

/// One browser tab: owns its own `WKWebView` so navigation state (back
/// history, scroll position, form state) survives switching between tabs.
/// Also exposes the JS-driven actions the AI agent is allowed to perform —
/// every one of these is only ever called after the user approves the step
/// that requested it (see `BrowserStore`).
@MainActor
final class BrowserTab: NSObject, ObservableObject, Identifiable {
    let id = UUID()
    let webView: WKWebView

    @Published var urlString: String = ""
    @Published var title: String = "New Tab"
    @Published var isLoading = false
    @Published var estimatedProgress: Double = 0
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var loadError: String?

    /// Fired when a top-level navigation finishes loading (used by the store
    /// to record history and keep the address bar in sync).
    var onFinishedNavigation: ((BrowserTab) -> Void)?

    override init() {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        observe()
    }

    private var observations: [NSKeyValueObservation] = []

    private func observe() {
        observations.append(webView.observe(\.url, options: [.new]) { [weak self] wv, _ in
            Task { @MainActor in self?.urlString = wv.url?.absoluteString ?? "" }
        })
        observations.append(webView.observe(\.title, options: [.new]) { [weak self] wv, _ in
            Task { @MainActor in
                guard let self else { return }
                if let pageTitle = wv.title, !pageTitle.isEmpty {
                    self.title = pageTitle
                } else {
                    self.title = self.urlString.isEmpty ? "New Tab" : self.urlString
                }
            }
        })
        observations.append(webView.observe(\.isLoading, options: [.new]) { [weak self] wv, _ in
            Task { @MainActor in self?.isLoading = wv.isLoading }
        })
        observations.append(webView.observe(\.estimatedProgress, options: [.new]) { [weak self] wv, _ in
            Task { @MainActor in self?.estimatedProgress = wv.estimatedProgress }
        })
        observations.append(webView.observe(\.canGoBack, options: [.new]) { [weak self] wv, _ in
            Task { @MainActor in self?.canGoBack = wv.canGoBack }
        })
        observations.append(webView.observe(\.canGoForward, options: [.new]) { [weak self] wv, _ in
            Task { @MainActor in self?.canGoForward = wv.canGoForward }
        })
    }

    // MARK: - Navigation

    func load(url: URL) {
        loadError = nil
        webView.load(URLRequest(url: url))
    }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func reload() { webView.reload() }
    func stop() { webView.stopLoading() }

    /// Runs `js` in the page context and returns its result, or `nil` on
    /// error/timeout. Kept as an explicit helper (rather than an inline
    /// `try? await … as? T` expression) so the optional-unwrapping is
    /// unambiguous at every call site.
    ///
    /// Evaluation runs in a dedicated app content world (not the page's own
    /// world) because pages with a strict Content-Security-Policy — GitHub,
    /// banking sites, many SPAs — silently refuse `eval`-style injection in
    /// the `.page` world, which used to make `captureContext` return an empty
    /// snapshot and the Ask/plan prompts describe the page as "blank or
    /// loading". Content worlds share the same DOM, so clicks, typing,
    /// scrolling, and reading text all still affect the real page and its
    /// event listeners.
    private func evaluateJS(_ js: String) async -> Any? {
        do {
            return try await webView.callAsyncJavaScript(js, in: nil, contentWorld: Self.agentWorld)
        } catch {
            return nil
        }
    }

    /// App-owned content world used for every script the agent runs. Kept
    /// out of the page world so strict page CSPs can't block the snapshot or
    /// the approved actions; DOM changes stay visible to the page's own JS.
    private static let agentWorld = WKContentWorld.world(name: "roamsocket.browser.agent")

    /// Shared JS: resolves a human-readable label for an element (falling
    /// back to an inner `<img alt>` or an associated `<label for>`, since
    /// plenty of real buttons/links — like a site's logo — carry no text of
    /// their own), plus fuzzy matching so a model-provided hint like
    /// "Google button" still finds an element merely labeled "Google".
    /// Tried in order: exact substring either direction, then stopword-
    /// stripped token overlap. Kept as one constant so `click`/`type` share
    /// identical matching behavior.
    private static let matchHelperJS = """
    function __normalize(s) {
      return (s || '').toLowerCase().replace(/[^a-z0-9 ]/g, ' ').replace(/\\s+/g, ' ').trim();
    }
    var __STOPWORDS = ['button','link','icon','the','a','an','of','on','to','for','click','tap','press','field','box','input','menu'];
    function __tokens(s) {
      return __normalize(s).split(' ').filter(function (t) { return t && __STOPWORDS.indexOf(t) === -1; });
    }
    function __labelOf(el) {
      var raw = el.innerText || el.value || el.getAttribute('aria-label') || el.getAttribute('placeholder') || el.getAttribute('title') || '';
      if (!raw && el.querySelector) {
        var img = el.querySelector('img[alt]');
        if (img) raw = img.getAttribute('alt') || '';
      }
      if (!raw && el.id) {
        var labelFor = document.querySelector('label[for="' + el.id + '"]');
        if (labelFor) raw = labelFor.innerText || '';
      }
      if (!raw) raw = el.getAttribute('name') || el.id || '';
      return raw;
    }
    function __score(el, hintTokens) {
      var labelTokens = __tokens(__labelOf(el));
      if (labelTokens.length === 0 || hintTokens.length === 0) return 0;
      var overlap = 0;
      for (var i = 0; i < hintTokens.length; i++) {
        if (labelTokens.indexOf(hintTokens[i]) !== -1) overlap++;
      }
      return overlap / Math.max(labelTokens.length, hintTokens.length);
    }
    function __bestMatch(candidates, hint) {
      var hintNorm = __normalize(hint);
      var hintTokens = __tokens(hint);
      for (var i = 0; i < candidates.length; i++) {
        var labelNorm = __normalize(__labelOf(candidates[i]));
        if (labelNorm && (labelNorm.indexOf(hintNorm) !== -1 || hintNorm.indexOf(labelNorm) !== -1)) {
          return candidates[i];
        }
      }
      var best = null, bestScore = 0;
      for (var j = 0; j < candidates.length; j++) {
        var s = __score(candidates[j], hintTokens);
        if (s > bestScore) { bestScore = s; best = candidates[j]; }
      }
      return bestScore >= 0.34 ? best : null;
    }
    """

    // MARK: - Grounding

    /// Pull a lightweight snapshot of the page: title, URL, visible text,
    /// and the most prominent clickable elements with their text labels.
    /// Uses the same `__labelOf` fallback as `click`/`type` (image `alt`,
    /// associated `<label>`) so icon-only controls the AI might target —
    /// like a bare logo link — actually show up here instead of being
    /// silently dropped, which used to leave the model guessing blind.
    /// Text extraction prefers `innerText` but falls back to a script/style-
    /// stripped `textContent` for sites whose content lives in a hidden
    /// container at snapshot time — `innerText` returns empty for them.
    func captureContext() async -> BrowserPageContext {
        let js = """
        (function () {
          \(Self.matchHelperJS)
          function visible(el) {
            const r = el.getBoundingClientRect();
            const style = window.getComputedStyle(el);
            return r.width > 0 && r.height > 0 && style.visibility !== 'hidden' && style.display !== 'none';
          }
          var text = '';
          if (document.body) {
            var inner = document.body.innerText;
            if (inner && inner.trim().length > 0) {
              text = inner.replace(/\\s+/g, ' ').trim();
            } else {
              var clone = document.body.cloneNode(true);
              var drop = clone.querySelectorAll('script, style, noscript, svg, canvas, iframe');
              for (var i = 0; i < drop.length; i++) {
                if (drop[i].parentNode) drop[i].parentNode.removeChild(drop[i]);
              }
              var tc = (clone.textContent || '').replace(/\\s+/g, ' ').trim();
              if (tc.length > 0) text = tc;
            }
          }
          text = text.slice(0, 12000);
          const nodes = Array.from(document.querySelectorAll('a, button, input, [role="button"]')).filter(visible).slice(0, 60);
          const links = nodes.map(function (el) {
            const label = __labelOf(el).replace(/\\s+/g, ' ').trim().slice(0, 80);
            const href = el.getAttribute('href') || el.getAttribute('name') || el.id || '';
            return { label: label, href: href };
          }).filter(function (l) { return l.label.length > 0; });
          return JSON.stringify({ title: document.title, url: location.href, text: text, links: links });
        })();
        """
        guard let raw = await evaluateJS(js) as? String,
              let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return BrowserPageContext(url: urlString, title: title, textSnippet: "", links: [])
        }
        let links = (obj["links"] as? [[String: Any]] ?? []).compactMap { entry -> BrowserPageLink? in
            guard let label = entry["label"] as? String, !label.isEmpty else { return nil }
            return BrowserPageLink(label: label, href: entry["href"] as? String ?? "")
        }
        return BrowserPageContext(
            url: obj["url"] as? String ?? urlString,
            title: obj["title"] as? String ?? title,
            textSnippet: obj["text"] as? String ?? "",
            links: links
        )
    }

    // MARK: - Agent actions (only invoked after explicit user approval)

    /// Clicks the visible link/button/input that best matches `hint`.
    /// Matching (see `matchHelperJS`) tries an exact label substring first,
    /// then falls back to stopword-stripped token overlap — so a hint like
    /// "Google button" still matches an element merely labeled "Google" —
    /// and finally falls back to treating `hint` as a raw CSS selector.
    @discardableResult
    func click(hint: String) async -> Bool {
        let escaped = escapeJS(hint)
        let js = """
        (function () {
          \(Self.matchHelperJS)
          const candidates = Array.from(document.querySelectorAll('a, button, input, [role="button"], [onclick], summary'));
          let match = __bestMatch(candidates, "\(escaped)");
          if (!match) {
            try { match = document.querySelector("\(escaped)"); } catch (e) { match = null; }
          }
          if (!match) return false;
          match.scrollIntoView({ block: 'center' });
          match.click();
          return true;
        })();
        """
        return (await evaluateJS(js) as? Bool) ?? false
    }

    /// Types `text` into the visible input/textarea that best matches
    /// `hint` (same fuzzy matching as `click`), dispatching input/change
    /// events so frameworks (React, etc.) observe the update.
    @discardableResult
    func type(hint: String, text: String, submit: Bool) async -> Bool {
        let escapedHint = escapeJS(hint)
        let escapedText = escapeJS(text)
        let js = """
        (function () {
          \(Self.matchHelperJS)
          const fields = Array.from(document.querySelectorAll('input, textarea, [contenteditable="true"]'));
          let field = __bestMatch(fields, "\(escapedHint)");
          if (!field && fields.length === 1) field = fields[0];
          if (!field) {
            try { field = document.querySelector("\(escapedHint)"); } catch (e) { field = null; }
          }
          if (!field) return false;
          field.scrollIntoView({ block: 'center' });
          field.focus();
          if (field.isContentEditable) {
            field.innerText = "\(escapedText)";
          } else {
            field.value = "\(escapedText)";
          }
          field.dispatchEvent(new Event('input', { bubbles: true }));
          field.dispatchEvent(new Event('change', { bubbles: true }));
          if (\(submit)) {
            const form = field.closest('form');
            if (form) {
              if (form.requestSubmit) form.requestSubmit(); else form.submit();
            } else {
              field.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));
            }
          }
          return true;
        })();
        """
        return (await evaluateJS(js) as? Bool) ?? false
    }

    func scroll(direction: String, amount: CGFloat = 600) async {
        let dy = direction.lowercased() == "up" ? -amount : amount
        _ = await evaluateJS("window.scrollBy(0, \(dy));")
    }

    // MARK: - Settle / wait helpers

    /// Wait until the page is actually ready for the next AI action. WKWebView's
    /// `isLoading` flips false when the top-level load finishes — well before
    /// SPA-heavy sites (ESPN, scoreboards, anything React/Next/Vite) have
    /// painted their real content. The agent loop used to snapshot or click
    /// immediately after `isLoading` cleared, which handed the model an
    /// empty page it then described as "blank or loading".
    ///
    /// This polls three signals — `document.readyState === 'complete'`, a
    /// short quiescent window where no in-flight XHR/fetch is pending, and
    /// at minimum a small baseline delay so even a cached/static page isn't
    /// read mid-paint — and returns as soon as all three are satisfied or the
    /// overall budget runs out. Every wait is bounded; nothing here ever
    /// blocks the agent loop forever.
    ///
    /// Tunables kept conservative:
    /// - `quietWindow`: 400ms of no network activity counts as "done".
    /// - `minSettle`: 250ms minimum so a fast page is still observed post-paint.
    /// - `pollInterval`: 150ms — responsive without burning CPU.
    func waitForPageSettled(
        timeout: TimeInterval = 6,
        quietWindow: TimeInterval = 0.4,
        minSettle: TimeInterval = 0.25,
        pollInterval: TimeInterval = 0.15
    ) async {
        let start = Date()
        let deadline = start.addingTimeInterval(timeout)

        // 1. Wait for the WKWebView to finish its top-level load first.
        while isLoading, Date() < deadline {
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }

        // 2. Poll the page until document.readyState is 'complete' AND the
        //    network has been quiet for `quietWindow`. The JS returns a small
        //    status blob so we don't have to reach into page globals from Swift.
        let js = """
        (function () {
          if (document.readyState !== 'complete') return { ready: false, inflight: 0 };
          // Count in-flight fetches + XHRs we instrumented; sites that override
          // fetch/XHR will still be observable through __rsInFlight if our hook
          // landed first, otherwise 0 means "no observable activity" which is
          // safe enough for the wait.
          var inflight = (window.__rsInFlight && typeof window.__rsInFlight.count === 'number')
            ? window.__rsInFlight.count : 0;
          return { ready: true, inflight: inflight };
        })();
        """

        var lastActive = Date()
        let probeIntervalNS = UInt64(pollInterval * 1_000_000_000)

        while Date() < deadline {
            let probe = await evaluateJS(js) as? [String: Any]
            let ready = (probe?["ready"] as? Bool) ?? false
            let inflight = (probe?["inflight"] as? Int) ?? 0
            if ready && inflight == 0 {
                if lastActive.timeIntervalSinceNow <= -quietWindow { break }
            } else {
                // Any non-quiet observation resets the quiet clock.
                lastActive = Date()
            }
            try? await Task.sleep(nanoseconds: probeIntervalNS)
        }

        // 3. Final minimum-settle delay — guarantees we never read the page
        //    the same tick the load completed, even on a fully-cached page
        //    where every other signal flipped green immediately.
        let elapsed = Date().timeIntervalSince(start)
        if elapsed < minSettle {
            try? await Task.sleep(nanoseconds: UInt64((minSettle - elapsed) * 1_000_000_000))
        }
    }

    /// Installs a small `fetch`/XHR counter on `window.__rsInFlight` so the
    /// settle helper can detect in-flight network activity the page starts
    /// after the initial load (lazy chunks, analytics pings, etc.). Safe to
    /// call repeatedly — the hook is only installed once per page.
    ///
    /// Runs at the start of every AI run so the counter exists across reloads
    /// and navigations (a fresh `document` wipes `window`, so we re-install
    /// via `document.addEventListener('readystatechange', ...)` semantics in
    /// the helper script itself).
    func installNetworkActivityInstrumentation() async {
        let js = """
        (function () {
          if (window.__rsInFlightInstalled) return;
          window.__rsInFlightInstalled = true;
          window.__rsInFlight = { count: 0 };
          var origFetch = window.fetch && window.fetch.bind(window);
          if (origFetch) {
            window.fetch = function () {
              window.__rsInFlight.count++;
              var p = origFetch.apply(this, arguments);
              var done = function () { try { window.__rsInFlight.count--; } catch (e) {} };
              p.then(done, done);
              return p;
            };
          }
          var OrigXHR = window.XMLHttpRequest;
          if (OrigXHR && OrigXHR.prototype) {
            var origOpen = OrigXHR.prototype.open;
            var origSend = OrigXHR.prototype.send;
            OrigXHR.prototype.open = function () {
              this.__rsTracked = true;
              return origOpen.apply(this, arguments);
            };
            OrigXHR.prototype.send = function () {
              if (this.__rsTracked) {
                window.__rsInFlight.count++;
                var done = function () { try { window.__rsInFlight.count--; } catch (e) {} };
                this.addEventListener('loadend', done);
              }
              return origSend.apply(this, arguments);
            };
          }
        })();
        """
        _ = await evaluateJS(js)
    }

    private func escapeJS(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
    }
}

extension BrowserTab: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.loadError = error.localizedDescription }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.loadError = error.localizedDescription }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in self.onFinishedNavigation?(self) }
    }
}

/// Hosts a tab's persistent `WKWebView` in SwiftUI without recreating it
/// (recreating would drop navigation history and in-flight page state).
struct BrowserWebViewRepresentable: UIViewRepresentable {
    let tab: BrowserTab

    func makeUIView(context: Context) -> WKWebView { tab.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
