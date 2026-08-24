package app.roamsocket.android.ui.browser

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put

/**
 * Agent-driven actions that the browser is allowed to perform on the page.
 *
 * Mirrors the iOS actions on `BrowserTab` (click / type / scroll /
 * dismiss_consent / extract) plus the shared `captureContext` snapshot.
 * Every script is wrapped in an IIFE that `JSON.stringify`s a single
 * return value so the Kotlin side can `Json.parseToJsonElement` and pull
 * fields without having to second-guess the WebView's `evaluateJavascript`
 * callback shape.
 *
 * The matching helper (`matchHelperJS`) is shared verbatim between click
 * and type so a model hint of "Google button" finds an element labeled
 * "Google" — see iOS `BrowserTab.matchHelperJS` for the original Swift
 * comments.
 */
object BrowserTabActions {

    private val json = Json {
        ignoreUnknownKeys = true
        isLenient = true
    }

    /**
     * Pull a lightweight snapshot of the page: title, URL, visible text,
     * and the most prominent clickable elements with their text labels.
     */
    suspend fun captureContext(tab: BrowserTabState): BrowserPageContext {
        val js = """
            (function () {
              $MATCH_HELPER_JS
              function visible(el) {
                const r = el.getBoundingClientRect();
                const style = window.getComputedStyle(el);
                return r.width > 0 && r.height > 0
                  && style.visibility !== 'hidden'
                  && style.display !== 'none';
              }
              var text = '';
              if (document.body) {
                var inner = document.body.innerText;
                if (inner && inner.trim().length > 0) {
                  text = inner.replace(/\s+/g, ' ').trim();
                } else {
                  var clone = document.body.cloneNode(true);
                  var drop = clone.querySelectorAll('script, style, noscript, svg, canvas, iframe');
                  for (var i = 0; i < drop.length; i++) {
                    if (drop[i].parentNode) drop[i].parentNode.removeChild(drop[i]);
                  }
                  var tc = (clone.textContent || '').replace(/\s+/g, ' ').trim();
                  if (tc.length > 0) text = tc;
                }
              }
              text = text.slice(0, 12000);
              const nodes = Array.from(document.querySelectorAll('a, button, input, [role="button"]'))
                .filter(visible).slice(0, 60);
              const links = nodes.map(function (el) {
                const label = __labelOf(el).replace(/\s+/g, ' ').trim().slice(0, 80);
                const href = el.getAttribute('href') || el.getAttribute('name') || el.id || '';
                return { label: label, href: href };
              }).filter(function (l) { return l.label.length > 0; });
              return JSON.stringify({
                title: document.title,
                url: location.href,
                text: text,
                links: links
              });
            })();
        """.trimIndent()
        val raw = tab.evaluateJs(js) ?: return BrowserPageContext(tab.urlString.value, tab.title.value, "", emptyList())
        return parseContext(raw, fallbackUrl = tab.urlString.value, fallbackTitle = tab.title.value)
    }

    /**
     * Clicks the visible link/button/input that best matches [hint].
     * Returns true when an element was found and clicked.
     */
    suspend fun click(tab: BrowserTabState, hint: String): Boolean {
        val js = """
            (function () {
              $MATCH_HELPER_JS
              const candidates = Array.from(document.querySelectorAll(
                'a, button, input, [role="button"], [role="link"], [onclick], [aria-label], [data-testid], [data-cy], [data-qa], [type="submit"], summary'
              ));
              let match = __bestMatch(candidates, ${jsString(hint)});
              if (!match) {
                try { match = document.querySelector(${jsString(hint)}); } catch (e) { match = null; }
              }
              if (!match) return false;
              match.scrollIntoView({ block: 'center' });
              match.click();
              return true;
            })();
        """.trimIndent()
        return (tab.evaluateJs(js) == "true")
    }

    /**
     * Types [text] into the visible input/textarea that best matches [hint],
     * dispatching input/change events so frameworks (React, etc.) observe
     * the update. When [submit] is true, the field's enclosing form (or the
     * Enter key on a non-form input) is submitted.
     */
    suspend fun type(tab: BrowserTabState, hint: String, text: String, submit: Boolean): Boolean {
        val js = """
            (function () {
              $MATCH_HELPER_JS
              const fields = Array.from(document.querySelectorAll(
                'input, textarea, [contenteditable="true"], [role="textbox"], [role="searchbox"], [aria-label], [data-testid], [data-cy], [data-qa]'
              ));
              let field = __bestMatch(fields, ${jsString(hint)});
              if (!field && fields.length === 1) field = fields[0];
              if (!field) {
                try { field = document.querySelector(${jsString(hint)}); } catch (e) { field = null; }
              }
              if (!field) return false;
              field.scrollIntoView({ block: 'center' });
              field.focus();
              if (field.isContentEditable) {
                field.innerText = ${jsString(text)};
              } else {
                field.value = ${jsString(text)};
              }
              field.dispatchEvent(new Event('input', { bubbles: true }));
              field.dispatchEvent(new Event('change', { bubbles: true }));
              if (${submit}) {
                const form = field.closest('form');
                if (form) {
                  if (form.requestSubmit) form.requestSubmit(); else form.submit();
                } else {
                  field.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));
                }
              }
              return true;
            })();
        """.trimIndent()
        return (tab.evaluateJs(js) == "true")
    }

    /** Scroll the page by [amount] px in the given [direction] ("up"/"down"). */
    suspend fun scroll(tab: BrowserTabState, direction: String, amount: Int = 600) {
        val dy = if (direction.equals("up", ignoreCase = true)) -amount else amount
        tab.evaluateJs("window.scrollBy(0, $dy);")
    }

    /**
     * Tries to dismiss whatever cookie/consent banner is covering the page
     * by running the privacy-first consent dismisser and re-verifying the
     * overlay is actually gone.
     */
    suspend fun dismissConsent(tab: BrowserTabState): ConsentResult {
        val first = tab.evaluateJs(CONSENT_DISMISSER_JS) ?: return ConsentResult(false, "no-banner", -1)
        // Allow banner SDKs a beat to start animating the overlay out.
        kotlinx.coroutines.delay(250)
        val second = tab.evaluateJs(CONSENT_DISMISSER_VERIFY_JS) ?: first
        return parseConsent(first, second)
    }

    /** Wait for the page to fully settle (readyState complete + network quiet). */
    suspend fun waitForSettle(tab: BrowserTabState, maxSeconds: Int = 6): Boolean {
        val js = """
            (function () {
              function ready() { return document.readyState === 'complete'; }
              if (ready()) return true;
              return new Promise(function (resolve) {
                var t = setTimeout(function () { resolve(false); }, ${maxSeconds * 1000});
                function done() { clearTimeout(t); resolve(true); }
                document.addEventListener('readystatechange', function () { if (ready()) done(); });
                window.addEventListener('load', done);
              });
            })();
        """.trimIndent()
        // `evaluateJavascript` doesn't await Promises, so fall back to a
        // bounded poll on the Kotlin side instead.
        val deadline = System.currentTimeMillis() + maxSeconds * 1000L
        while (System.currentTimeMillis() < deadline) {
            val raw = tab.evaluateJs(js) ?: return false
            if (raw == "true") return true
            kotlinx.coroutines.delay(150)
        }
        return false
    }

    // -- JSON decoding helpers ------------------------------------------------

    private fun parseContext(raw: String, fallbackUrl: String, fallbackTitle: String): BrowserPageContext {
        return try {
            val obj = json.parseToJsonElement(raw).jsonObject
            val links = (obj["links"] as? JsonArray)?.mapNotNull { entry ->
                val linkObj = entry as? JsonObject ?: return@mapNotNull null
                val label = (linkObj["label"] as? JsonPrimitive)?.contentOrNull() ?: return@mapNotNull null
                if (label.isEmpty()) return@mapNotNull null
                BrowserPageLink(
                    label = label,
                    href = (linkObj["href"] as? JsonPrimitive)?.contentOrNull().orEmpty(),
                )
            } ?: emptyList()
            BrowserPageContext(
                url = (obj["url"] as? JsonPrimitive)?.contentOrNull() ?: fallbackUrl,
                title = (obj["title"] as? JsonPrimitive)?.contentOrNull() ?: fallbackTitle,
                textSnippet = (obj["text"] as? JsonPrimitive)?.contentOrNull().orEmpty(),
                links = links,
            )
        } catch (_: Throwable) {
            BrowserPageContext(fallbackUrl, fallbackTitle, "", emptyList())
        }
    }

    private fun parseConsent(first: String, second: String): ConsentResult {
        return try {
            val ok = (json.parseToJsonElement(second).jsonObject["ok"] as? JsonPrimitive)?.contentOrNull() == "true"
            val firstObj = json.parseToJsonElement(first).jsonObject
            val label = (firstObj["label"] as? JsonPrimitive)?.contentOrNull().orEmpty()
            val tier = (firstObj["tier"] as? JsonPrimitive)?.contentOrNull()?.toIntOrNull() ?: -1
            ConsentResult(ok, label, tier)
        } catch (_: Throwable) {
            ConsentResult(false, "", -1)
        }
    }

    private fun JsonPrimitive.contentOrNull(): String? = if (isString) content else content

    /** Encode [s] as a JS string literal (single-quoted, with escapes). */
    private fun jsString(s: String): String {
        val sb = StringBuilder("'")
        for (c in s) {
            when (c) {
                '\\' -> sb.append("\\\\")
                '\'' -> sb.append("\\'")
                '\n' -> sb.append("\\n")
                '\r' -> sb.append("\\r")
                '\t' -> sb.append("\\t")
                '<' -> sb.append("\\u003c")
                '>' -> sb.append("\\u003e")
                '&' -> sb.append("\\u0026")
                else -> if (c.code < 0x20) {
                    sb.append("\\u").append(String.format("%04x", c.code))
                } else {
                    sb.append(c)
                }
            }
        }
        sb.append("'")
        return sb.toString()
    }

    data class ConsentResult(val ok: Boolean, val label: String, val tier: Int)

    // -- Shared JS helpers ----------------------------------------------------

    private val MATCH_HELPER_JS = """
        function __normalize(s) {
          return (s || '').toLowerCase().replace(/[^a-z0-9 ]/g, ' ').replace(/\s+/g, ' ').trim();
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
    """.trimIndent()

    private val CONSENT_DISMISSER_JS = """
        (function () {
          try {
            function visible(el) {
              if (!el) return false;
              var r = el.getBoundingClientRect();
              if (r.width <= 0 || r.height <= 0) return false;
              var s = window.getComputedStyle(el);
              if (s.visibility === 'hidden' || s.display === 'none') return false;
              if (parseFloat(s.opacity || '1') <= 0) return false;
              if (s.position !== 'fixed' && s.position !== 'sticky') {
                var vw = window.innerWidth, vh = window.innerHeight;
                var coversX = r.left <= 16 && r.right >= vw - 16;
                var coversY = r.top <= 16 && r.bottom >= vh - 16;
                if (!(coversX && coversY)) return false;
              }
              return true;
            }
            function labelOf(el) {
              if (!el) return '';
              var raw = el.innerText || el.value || el.textContent || '';
              raw = (raw || '').replace(/\s+/g, ' ').trim();
              if (raw) return raw;
              raw = el.getAttribute('aria-label') || el.getAttribute('title') || '';
              return (raw || '').replace(/\s+/g, ' ').trim();
            }
            var TIERS = [
              ['reject all', 'reject all optional cookies', 'decline all', 'refuse all', 'reject non-essential'],
              ['reject', 'reject non essential', 'reject non-essential', 'reject optional', 'decline', 'refuse', 'do not accept', 'do not consent', 'no thanks'],
              ['accept only essential', 'accept essential only', 'only essential', 'essential only', 'use necessary cookies only', 'strictly necessary only', 'use essential cookies'],
              ['manage', 'manage settings', 'cookie settings', 'settings', 'customize', 'customise', 'preferences', 'more options', 'i agree', 'i accept'],
              ['accept all', 'accept', 'allow all', 'allow', 'agree', 'ok', 'okay', 'got it', 'i understand', 'continue', 'close', 'dismiss']
            ];
            function tierScore(label) {
              if (!label) return -1;
              var n = label.toLowerCase();
              for (var i = 0; i < TIERS.length; i++) {
                for (var j = 0; j < TIERS[i].length; j++) {
                  if (n.indexOf(TIERS[i][j]) !== -1) return i;
                }
              }
              return -1;
            }
            var containers = [];
            var knownIds = ['onetrust-banner-sdk','onetrust-consent-sdk','CybotCookiebotDialog','CybotCookiebotDialogBodyUnderlay','cookie-law-info-bar','cky-notification','truste-consent-track','truste-consent-button','termly-console','iubenda-cs-banner'];
            for (var k = 0; k < knownIds.length; k++) {
              var el = document.getElementById(knownIds[k]);
              if (el && visible(el)) containers.push(el);
              var q = document.querySelector('[id*="' + knownIds[k] + '"]');
              if (q && q !== el && visible(q)) containers.push(q);
            }
            var knownClass = ['cc-window','cc-banner','ot-floating-button','cc-floating','cookie-banner','cookie-consent','gdpr-banner','gdpr-cookie-notice','privacy-banner'];
            for (var c = 0; c < knownClass.length; c++) {
              var found = document.querySelectorAll('.' + knownClass[c]);
              for (var f = 0; f < found.length; f++) {
                if (visible(found[f])) containers.push(found[f]);
              }
            }
            var fixedEls = document.querySelectorAll('*');
            for (var fe = 0; fe < fixedEls.length; fe++) {
              var node = fixedEls[fe];
              if (containers.indexOf(node) !== -1) continue;
              var s = window.getComputedStyle(node);
              if (s.position !== 'fixed' && s.position !== 'sticky') continue;
              if (!visible(node)) continue;
              if (!node.querySelector('a, button, [role="button"], input[type="submit"], input[type="button"]')) continue;
              containers.push(node);
            }
            if (containers.length === 0) {
              var all = document.querySelectorAll('body *');
              for (var a = 0; a < all.length; a++) {
                var node2 = all[a];
                if (containers.indexOf(node2) !== -1) continue;
                if (!visible(node2)) continue;
                if (!node2.querySelector('a, button, [role="button"], input[type="submit"], input[type="button"]')) continue;
                containers.push(node2);
              }
            }
            if (containers.length === 0) {
              return JSON.stringify({ ok: false, label: '', tier: -1, reason: 'no-banner' });
            }
            var best = null, bestTier = 999, bestArea = 0;
            for (var i2 = 0; i2 < containers.length; i2++) {
              var cont = containers[i2];
              var candidates = cont.querySelectorAll('a, button, [role="button"], input[type="submit"], input[type="button"]');
              for (var c2 = 0; c2 < candidates.length; c2++) {
                var cand = candidates[c2];
                if (!visible(cand)) continue;
                var lab = labelOf(cand);
                var t = tierScore(lab);
                if (t < 0) continue;
                var rect = cand.getBoundingClientRect();
                var area = rect.width * rect.height;
                if (t < bestTier || (t === bestTier && area > bestArea)) {
                  best = cand; bestTier = t; bestArea = area;
                }
              }
            }
            if (!best) {
              return JSON.stringify({ ok: false, label: '', tier: -1, reason: 'no-button' });
            }
            best.click();
            return JSON.stringify({ ok: true, label: labelOf(best), tier: bestTier, reason: 'clicked' });
          } catch (e) {
            return JSON.stringify({ ok: false, label: '', tier: -1, reason: 'error:' + (e && e.message ? e.message : 'unknown') });
          }
        })();
    """.trimIndent()

    private val CONSENT_DISMISSER_VERIFY_JS = """
        (function () {
          try {
            function visible(el) {
              if (!el) return false;
              var r = el.getBoundingClientRect();
              if (r.width <= 0 || r.height <= 0) return false;
              var s = window.getComputedStyle(el);
              if (s.visibility === 'hidden' || s.display === 'none') return false;
              if (parseFloat(s.opacity || '1') <= 0) return false;
              return s.position === 'fixed' || s.position === 'sticky';
            }
            var knownIds = ['onetrust-banner-sdk','CybotCookiebotDialog','cookie-law-info-bar','cky-notification','truste-consent-track','termly-console','iubenda-cs-banner'];
            for (var k = 0; k < knownIds.length; k++) {
              var el = document.getElementById(knownIds[k]);
              if (el && visible(el)) return JSON.stringify({ ok: false, label: '', tier: -1, reason: 'still-visible' });
            }
            return JSON.stringify({ ok: true, label: '', tier: -1, reason: 'gone' });
          } catch (e) {
            return JSON.stringify({ ok: true, label: '', tier: -1, reason: 'verify-error' });
          }
        })();
    """.trimIndent()
}
