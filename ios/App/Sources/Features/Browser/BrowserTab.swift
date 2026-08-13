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
    /// back to an inner `<img alt>`, an associated `<label for>`, or a
    /// `data-testid` / `data-cy` / `data-qa` test selector since plenty of
    /// real buttons/links — like a site's logo, an icon-only toolbar button,
    /// or a Cypress/Testing Library-tagged element — carry no text of their
    /// own), plus fuzzy matching so a model-provided hint like "Google
    /// button" still finds an element merely labeled "Google". Tried in
    /// order: exact substring either direction, then stopword-stripped
    /// token overlap. Kept as one constant so `click`/`type` share
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
      // Modern frameworks (Cypress, Testing Library, QA pipelines) tag
      // elements via data-* attributes that carry a human-readable name
      // even when the element has no visible text. Fall back to those
      // before giving up to `name`/`id`, which are usually opaque.
      if (!raw) {
        raw = el.getAttribute('data-testid')
          || el.getAttribute('data-cy')
          || el.getAttribute('data-qa')
          || el.getAttribute('data-test-id')
          || '';
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
        // Show the magical pointer at the target before clicking — the user
        // gets to literally see "the AI's finger is hovering here" before
        // the action lands. Best-effort: if the indicator fails to render
        // (CSP, no target yet, etc.) the click still runs.
        await showPointerAtTarget(kind: "click", hint: hint, settleSeconds: 0.75)
        defer { Task { await self.hidePointer() } }

        let escaped = escapeJS(hint)
        let js = """
        (function () {
          \(Self.matchHelperJS)
          // Includes `[aria-label]` and `[data-testid]` etc. so icon-only
          // buttons and modern framework-tagged controls are candidates
          // even when they have no visible text content. Also `[type="submit"]`
          // so a form's submit button — usually the thing that actually
          // runs a search — isn't missed just because it has no aria-label.
          const candidates = Array.from(document.querySelectorAll(
            'a, button, input, [role="button"], [role="link"], [onclick], [aria-label], [data-testid], [data-cy], [data-qa], [type="submit"], summary'
          ));
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
        // Hover the magical pointer at the target field first so the user
        // can see where the AI is about to type.
        await showPointerAtTarget(kind: "type", hint: hint, settleSeconds: 0.75)
        defer { Task { await self.hidePointer() } }

        let escapedHint = escapeJS(hint)
        let escapedText = escapeJS(text)
        let js = """
        (function () {
          \(Self.matchHelperJS)
          // Include `[role="textbox"]` / `[role="searchbox"]` for React/Svelte
          // apps that render `<div contenteditable>`-style inputs with custom
          // roles, plus the data-* attributes for QA-tagged controls. A
          // model hint like "search box" should match a `<div role="searchbox">`
          // that wraps a contenteditable, not just plain `<input>`s.
          const fields = Array.from(document.querySelectorAll(
            'input, textarea, [contenteditable="true"], [role="textbox"], [role="searchbox"], [aria-label], [data-testid], [data-cy], [data-qa]'
          ));
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

    // MARK: - AI "finger" pointer overlay
    //
    // Renders a magical rainbow pointer + sparkle trail at the element the
    // AI is about to act on, so the user can see exactly where the agent is
    // "hovering" before it clicks / types. The overlay lives in the page
    // (not native) so it scales with the web content, sits above every site
    // CSS without z-index wars, and self-cleans after the action finishes.

    /// Anchors the overlay element on which the AI will act, then animates
    /// the magical pointer to it. Returns the JS-driven promise so callers
    /// can await pointer arrival before the real interaction. `selector` is
    /// optional — when omitted the overlay positions itself at the visible
    /// center of `target` (an `Element` JS expression evaluated in the page).
    static let pointerOverlayJS = """
    (function () {
      // ---- container -------------------------------------------------------
      var host = document.getElementById('__rs_pointer_host');
      if (!host) {
        host = document.createElement('div');
        host.id = '__rs_pointer_host';
        host.style.cssText = [
          'position: fixed',
          'left: 0',
          'top: 0',
          'width: 0',
          'height: 0',
          'pointer-events: none',
          'z-index: 2147483647',
          'overflow: visible'
        ].join(';');
        (document.body || document.documentElement).appendChild(host);
      }

      // ---- pulse ring on the actual element --------------------------------
      var target = null;
      try { target = (__RS_TARGET__); } catch (e) {}
      var rect = null;
      if (target && target.getBoundingClientRect) {
        var r = target.getBoundingClientRect();
        rect = { x: r.left, y: r.top, w: r.width, h: r.height };
      }
      // Fallback: position near viewport center if we somehow don't have a target.
      var cx = rect ? (rect.x + rect.w / 2) : (window.innerWidth / 2);
      var cy = rect ? (rect.y + rect.h / 2) : (window.innerHeight / 2);

      // Pre-existing pulse rings: remove so we don't stack forever.
      var oldPulses = document.querySelectorAll('.__rs_pulse_ring');
      for (var i = 0; i < oldPulses.length; i++) oldPulses[i].remove();

      if (rect) {
        var ring = document.createElement('div');
        ring.className = '__rs_pulse_ring';
        ring.style.cssText = [
          'position: fixed',
          'left: ' + rect.x + 'px',
          'top: ' + rect.y + 'px',
          'width: ' + rect.w + 'px',
          'height: ' + rect.h + 'px',
          'border-radius: 14px',
          'border: 2px solid transparent',
          'background-image: linear-gradient(90deg,#ff5fa2,#ffd86b,#7afcff,#9b8cff,#ff7be6,#ff5fa2)',
          'background-origin: border-box',
          '-webkit-background-clip: border-box',
          'background-clip: border-box',
          '-webkit-mask: linear-gradient(#000 0 0) content-box, linear-gradient(#000 0 0)',
          '-webkit-mask-composite: xor',
                  'mask-composite: exclude',
          'padding: 2px',
          'pointer-events: none',
          'box-sizing: border-box',
          'opacity: 0',
          'transition: opacity .15s ease-out',
          'animation: __rsPulse 1.4s ease-out infinite'
        ].join(';');
        (document.body || document.documentElement).appendChild(ring);
        // Force a reflow so the opacity transition runs.
        void ring.offsetWidth;
        ring.style.opacity = '1';
      }

      // ---- magical pointer (SVG with rainbow gradient + sparkles) --------
      var oldPointer = document.getElementById('__rs_pointer');
      if (oldPointer) oldPointer.remove();

      var svgNS = 'http://www.w3.org/2000/svg';
      var svg = document.createElementNS(svgNS, 'svg');
      svg.id = '__rs_pointer';
      svg.setAttribute('width', '64');
      svg.setAttribute('height', '64');
      svg.setAttribute('viewBox', '0 0 64 64');
      svg.style.cssText = [
        'position: fixed',
        'left: 0',
        'top: 0',
        'width: 64px',
        'height: 64px',
        // Start from current pointer pos if known, else center.
        'transform: translate(' + (window.__rsPointerFrom
          ? (window.__rsPointerFrom.x - 32) + 'px,' + (window.__rsPointerFrom.y - 32) + 'px'
          : (cx - 32) + 'px,' + (cy - 32) + 'px') + ')',
        'transition: transform .55s cubic-bezier(.22,1.05,.36,1)',
        'filter: drop-shadow(0 2px 6px rgba(0,0,0,.35))',
        'pointer-events: none',
        'will-change: transform'
      ].join(';');

      // Defs: rainbow gradient for the pointer body + a soft glow gradient.
      var defs = document.createElementNS(svgNS, 'defs');
      var rainbow = document.createElementNS(svgNS, 'linearGradient');
      rainbow.setAttribute('id', '__rs_rainbow');
      rainbow.setAttribute('x1', '0%'); rainbow.setAttribute('y1', '0%');
      rainbow.setAttribute('x2', '100%'); rainbow.setAttribute('y2', '100%');
      var stops = [
        ['#ff5fa2', '0%'], ['#ffd86b', '20%'], ['#7afcff', '40%'],
        ['#9b8cff', '60%'], ['#ff7be6', '80%'], ['#ff5fa2', '100%']
      ];
      for (var s = 0; s < stops.length; s++) {
        var stop = document.createElementNS(svgNS, 'stop');
        stop.setAttribute('offset', stops[s][1]);
        stop.setAttribute('stop-color', stops[s][0]);
        stop.setAttribute('stop-opacity', '1');
        rainbow.appendChild(stop);
      }
      defs.appendChild(rainbow);

      var glow = document.createElementNS(svgNS, 'radialGradient');
      glow.setAttribute('id', '__rs_glow');
      glow.setAttribute('cx', '50%'); glow.setAttribute('cy', '50%');
      glow.setAttribute('r', '50%');
      var glowStop = document.createElementNS(svgNS, 'stop');
      glowStop.setAttribute('offset', '0%');
      glowStop.setAttribute('stop-color', '#ffffff');
      glowStop.setAttribute('stop-opacity', '0.9');
      var glowStop2 = document.createElementNS(svgNS, 'stop');
      glowStop2.setAttribute('offset', '100%');
      glowStop2.setAttribute('stop-color', '#ffffff');
      glowStop2.setAttribute('stop-opacity', '0');
      glow.appendChild(glowStop);
      glow.appendChild(glowStop2);
      defs.appendChild(glow);

      // Sparkle stars are reusable symbols.
      var sparkleSym = document.createElementNS(svgNS, 'symbol');
      sparkleSym.setAttribute('id', '__rs_sparkle');
      sparkleSym.setAttribute('viewBox', '0 0 10 10');
      var sparklePath = document.createElementNS(svgNS, 'path');
      sparklePath.setAttribute('d', 'M5 0 L6 4 L10 5 L6 6 L5 10 L4 6 L0 5 L4 4 Z');
      sparklePath.setAttribute('fill', '#ffffff');
      sparkleSym.appendChild(sparklePath);
      defs.appendChild(sparkleSym);

      svg.appendChild(defs);

      // Soft white halo behind the pointer.
      var halo = document.createElementNS(svgNS, 'circle');
      halo.setAttribute('cx', '32'); halo.setAttribute('cy', '32'); halo.setAttribute('r', '28');
      halo.setAttribute('fill', 'url(#__rs_glow)');
      halo.style.cssText = 'opacity:0.65; animation: __rsHalo 1.6s ease-in-out infinite;';
      svg.appendChild(halo);

      // Cursor arrow filled with the rainbow gradient.
      var cursor = document.createElementNS(svgNS, 'path');
      cursor.setAttribute('d', 'M14 10 L14 46 L24 38 L30 50 L36 47 L30 35 L43 34 Z');
      cursor.setAttribute('fill', 'url(#__rs_rainbow)');
      cursor.setAttribute('stroke', '#ffffff');
      cursor.setAttribute('stroke-width', '1.6');
      cursor.setAttribute('stroke-linejoin', 'round');
      svg.appendChild(cursor);

      // Sparkles scattered around the pointer, each with its own animation
      // delay so they twinkle instead of pulsing in unison.
      var sparklePositions = [
        { x: 4, y: 8, r: 5, d: 0 },
        { x: 52, y: 4, r: 4, d: 200 },
        { x: 56, y: 30, r: 5, d: 400 },
        { x: 40, y: 56, r: 4, d: 600 },
        { x: 10, y: 50, r: 5, d: 800 },
        { x: 26, y: 24, r: 3, d: 1000 }
      ];
      for (var k = 0; k < sparklePositions.length; k++) {
        var sp = sparklePositions[k];
        var use = document.createElementNS(svgNS, 'use');
        use.setAttributeNS('http://www.w3.org/1999/xlink', 'href', '#__rs_sparkle');
        use.setAttribute('href', '#__rs_sparkle');
        use.setAttribute('x', sp.x - sp.r);
        use.setAttribute('y', sp.y - sp.r);
        use.setAttribute('width', sp.r * 2);
        use.setAttribute('height', sp.r * 2);
        use.style.cssText = 'opacity:0; animation: __rsSparkle 1.8s ease-in-out ' + sp.d + 'ms infinite;';
        svg.appendChild(use);
      }

      host.appendChild(svg);

      // Inject keyframes once.
      if (!document.getElementById('__rs_pointer_styles')) {
        var style = document.createElement('style');
        style.id = '__rs_pointer_styles';
        style.textContent = [
          '@keyframes __rsSparkle {',
          '  0%   { opacity: 0; transform: scale(0.6); }',
          '  40%  { opacity: 1; transform: scale(1.15); }',
          '  70%  { opacity: 0.4; transform: scale(0.9); }',
          '  100% { opacity: 0; transform: scale(0.6); }',
          '}',
          '@keyframes __rsHalo {',
          '  0%, 100% { opacity: 0.35; transform: scale(1); }',
          '  50%      { opacity: 0.85; transform: scale(1.15); }',
          '}',
          '@keyframes __rsPulse {',
          '  0%   { opacity: 0.9; transform: scale(1); }',
          '  100% { opacity: 0;   transform: scale(1.08); }',
          '}'
        ].join('\\n');
        document.head.appendChild(style);
      }

      // Animate to the target. We use CSS transition + a forced reflow so the
      // browser actually runs the transition from the start position.
      void svg.offsetWidth;
      svg.style.transform = 'translate(' + (cx - 32) + 'px,' + (cy - 32) + 'px)';
      window.__rsPointerFrom = { x: cx, y: cy };

      return { x: cx, y: cy };
    })();
    """

    /// Builds the JS payload that resolves the target element inside the page
    /// then returns the overlay helper JS with the target substituted in.
    /// We resolve to a single candidate (same fuzzy matcher as click/type) so
    /// the indicator lands on exactly the element the agent will act on.
    private static func resolveTargetJS(kind: String, hint: String, extra: String) -> String {
        let escaped = escapeJSForScript(hint)
        return """
        (function () {
          \(matchHelperJS)
          var match = null;
          if ("\(kind)" === "click") {
            // Mirror the click() candidate selector list (kept in sync so
            // the pointer lands on the same element the click will hit —
            // otherwise the user sees the finger hover over a button that
            // then does nothing).
            var candidates = Array.from(document.querySelectorAll(
              'a, button, input, [role="button"], [role="link"], [onclick], [aria-label], [data-testid], [data-cy], [data-qa], [type="submit"], summary'
            ));
            match = __bestMatch(candidates, "\(escaped)");
          } else if ("\(kind)" === "type") {
            var fields = Array.from(document.querySelectorAll(
              'input, textarea, [contenteditable="true"], [role="textbox"], [role="searchbox"], [aria-label], [data-testid], [data-cy], [data-qa]'
            ));
            match = __bestMatch(fields, "\(escaped)");
            if (!match && fields.length === 1) match = fields[0];
          }
          \(extra)
          if (!match) return null;
          // Stash target on window so the overlay helper can reach it.
          window.__rsOverlayTarget = match;
          return match;
        })();
        """
    }

    /// JS-only escape used inside the pointer overlay's IIFEs; differs from
    /// `escapeJS` in that it also escapes backticks/template-literal sigils
    /// so the resulting string is safe to splice into the overlay template.
    private static func escapeJSForScript(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "$", with: "\\$")
    }

    /// Show the magical pointer hovering at the element the AI is about to
    /// act on. Resolves the target in-page (so the overlay lands on the
    /// exact element the click/type will hit), animates the pointer there
    /// with a rainbow trail + sparkle pulse, and waits for the travel
    /// animation to finish before returning.
    ///
    /// Safe to call when no target is found — quietly no-ops.
    func showPointerAtTarget(kind: String, hint: String, settleSeconds: Double = 0.9) async {
        let resolveJS = Self.resolveTargetJS(kind: kind, hint: hint, extra: "")
        // Stash the target on window for the overlay helper to read.
        _ = await evaluateJS(resolveJS)

        // Now run the overlay with the target variable spliced in.
        let withTarget = Self.pointerOverlayJS
            .replacingOccurrences(of: "__RS_TARGET__", with: "window.__rsOverlayTarget || null")
        _ = await evaluateJS(withTarget)

        // Let the pointer glide in (matches the CSS transition) plus a beat
        // for the user to actually see it.
        try? await Task.sleep(nanoseconds: UInt64(settleSeconds * 1_000_000_000))
    }

    /// Removes the magical pointer + pulse ring from the page. Called after
    /// a click/type finishes so the overlay doesn't linger past the action.
    func hidePointer() async {
        let js = """
        (function () {
          var p = document.getElementById('__rs_pointer'); if (p) p.remove();
          var rings = document.querySelectorAll('.__rs_pulse_ring');
          for (var i = 0; i < rings.length; i++) rings[i].remove();
        })();
        """
        _ = await evaluateJS(js)
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

        // 2. Poll the page until document.readyState is 'complete' AND either
        //    the network is quiet for `quietWindow` OR the page has visibly
        //    stabilized (scroll position + document height unchanged across
        //    two consecutive observations, with no error in the page's last
        //    network attempt). The "stable page" fallback is what stops
        //    infinite-scroll / ad-polling sites (ESPN, news, scoreboards) from
        //    holding us at the bottom of the page forever — their background
        //    fetches never go idle, but the actual content the user can see
        //    has long since stopped changing.
        let js = """
        (function () {
          var ready = document.readyState === 'complete';
          var inflight = (window.__rsInFlight && typeof window.__rsInFlight.count === 'number')
            ? window.__rsInFlight.count : 0;
          var docH = document.documentElement ? document.documentElement.scrollHeight : 0;
          var scrollY = window.scrollY || window.pageYOffset || 0;
          var atBottom = (window.innerHeight + scrollY) >= (docH - 4);
          return { ready: ready, inflight: inflight, docH: docH, scrollY: scrollY, atBottom: atBottom };
        })();
        """

        var lastActive = Date()
        var lastStableSignature: String?
        var stableStreak = 0
        let probeIntervalNS = UInt64(pollInterval * 1_000_000_000)

        while Date() < deadline {
            let probe = await evaluateJS(js) as? [String: Any]
            let ready = (probe?["ready"] as? Bool) ?? false
            let inflight = (probe?["inflight"] as? Int) ?? 0
            let docH = (probe?["docH"] as? Int) ?? 0
            let scrollY = (probe?["scrollY"] as? Int) ?? 0
            let atBottom = (probe?["atBottom"] as? Bool) ?? false

            // Two consecutive probes with the same height + scroll + ready
            // + no observable in-flight work counts as "stable" — even if a
            // background polling loop keeps the network counter > 0.
            let signature = "\(ready)|\(inflight)|\(docH)|\(scrollY)"
            if signature == lastStableSignature, ready {
                stableStreak += 1
            } else {
                stableStreak = 0
                lastStableSignature = signature
            }
            let isQuiet = ready && inflight == 0
            let isStable = ready && stableStreak >= 1

            if isQuiet {
                if lastActive.timeIntervalSinceNow <= -quietWindow { break }
            } else if isStable {
                // Page signature has held across two polls — treat as
                // settled even though the network counter is non-zero.
                // One extra probe worth of quiet to be safe.
                if lastActive.timeIntervalSinceNow <= -quietWindow { break }
                lastActive = Date()
            } else {
                lastActive = Date()
            }
            // Sanity: if the page claims to be at the bottom AND the height
            // matches the viewport, there's literally nothing to load. Bail
            // out immediately instead of burning the full timeout budget.
            // The check happens in-page so we get innerHeight for free.
            if atBottom, docH > 0, docH - scrollY <= 4 {
                break
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
