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
            Task { @MainActor in self?.title = (wv.title?.isEmpty == false ? wv.title! : self?.urlString) ?? "New Tab" }
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

    // MARK: - Grounding

    /// Pull a lightweight snapshot of the page: title, URL, visible text,
    /// and the most prominent clickable elements with their text labels.
    func captureContext() async -> BrowserPageContext {
        let js = """
        (function () {
          function visible(el) {
            const r = el.getBoundingClientRect();
            const style = window.getComputedStyle(el);
            return r.width > 0 && r.height > 0 && style.visibility !== 'hidden' && style.display !== 'none';
          }
          const text = document.body ? document.body.innerText.replace(/\\s+/g, ' ').trim().slice(0, 4000) : '';
          const nodes = Array.from(document.querySelectorAll('a, button, input, [role="button"]')).filter(visible).slice(0, 60);
          const links = nodes.map(function (el) {
            const label = (el.innerText || el.value || el.getAttribute('aria-label') || el.getAttribute('placeholder') || '').replace(/\\s+/g, ' ').trim().slice(0, 80);
            const href = el.getAttribute('href') || el.getAttribute('name') || el.id || '';
            return { label: label, href: href };
          }).filter(function (l) { return l.label.length > 0; });
          return JSON.stringify({ title: document.title, url: location.href, text: text, links: links });
        })();
        """
        guard let raw = try? await webView.callAsyncJavaScript(js, in: nil, contentWorld: .page) as? String,
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

    /// Clicks the first visible link/button/input whose label, aria-label,
    /// placeholder, id, or name contains `hint` (case-insensitive). Falls
    /// back to treating `hint` as a raw CSS selector if nothing matches.
    @discardableResult
    func click(hint: String) async -> Bool {
        let escaped = escapeJS(hint)
        let js = """
        (function () {
          const hint = "\(escaped)".toLowerCase();
          const candidates = Array.from(document.querySelectorAll('a, button, input, [role="button"], [onclick]'));
          function labelOf(el) {
            return (el.innerText || el.value || el.getAttribute('aria-label') || el.getAttribute('placeholder') || el.id || el.getAttribute('name') || '').toLowerCase();
          }
          let match = candidates.find(function (el) { return labelOf(el).includes(hint); });
          if (!match) {
            try { match = document.querySelector("\(escaped)"); } catch (e) { match = null; }
          }
          if (!match) return false;
          match.scrollIntoView({ block: 'center' });
          match.click();
          return true;
        })();
        """
        return (try? await webView.callAsyncJavaScript(js, in: nil, contentWorld: .page) as? Bool) ?? false
    }

    /// Types `text` into the first visible input/textarea whose label,
    /// placeholder, aria-label, id, or name contains `hint`, dispatching
    /// input/change events so frameworks (React, etc.) observe the update.
    @discardableResult
    func type(hint: String, text: String, submit: Bool) async -> Bool {
        let escapedHint = escapeJS(hint)
        let escapedText = escapeJS(text)
        let js = """
        (function () {
          const hint = "\(escapedHint)".toLowerCase();
          const fields = Array.from(document.querySelectorAll('input, textarea, [contenteditable="true"]'));
          function labelOf(el) {
            return (el.placeholder || el.getAttribute('aria-label') || el.name || el.id || '').toLowerCase();
          }
          let field = fields.find(function (el) { return labelOf(el).includes(hint); });
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
        return (try? await webView.callAsyncJavaScript(js, in: nil, contentWorld: .page) as? Bool) ?? false
    }

    func scroll(direction: String, amount: CGFloat = 600) async {
        let dy = direction.lowercased() == "up" ? -amount : amount
        _ = try? await webView.callAsyncJavaScript(
            "window.scrollBy(0, \(dy));",
            in: nil,
            contentWorld: .page
        )
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
