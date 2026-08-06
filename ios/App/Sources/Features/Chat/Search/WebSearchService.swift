import Foundation

/// Client-side web search for Chat **Web search** and **Research** modes.
///
/// Uses DuckDuckGo HTML results (no API key) plus optional Wikipedia summaries
/// for research depth. Results are formatted into a system-prompt block the
/// model can cite; UI steps are emitted for grey tool-status text.
actor WebSearchService {
    enum Mode: Sendable {
        /// Single query, fewer hits — quick context for the current message.
        case webSearch
        /// Multi-query expansion + Wikipedia extracts for deeper answers.
        case research
    }

    struct Hit: Sendable, Equatable {
        let title: String
        let url: String
        let snippet: String
    }

    struct WikiExtract: Sendable, Equatable {
        let title: String
        let extract: String
        let url: String
    }

    /// One grey-text status line shown while tools run (and kept on the reply).
    struct Step: Sendable, Equatable, Identifiable {
        let id: UUID
        let name: String
        var summary: String
        var detail: String?
        var status: ChatToolStatus

        init(
            id: UUID = UUID(),
            name: String,
            summary: String,
            detail: String? = nil,
            status: ChatToolStatus = .running
        ) {
            self.id = id
            self.name = name
            self.summary = summary
            self.detail = detail
            self.status = status
        }
    }

    struct Bundle: Sendable {
        let mode: Mode
        let queries: [String]
        let hits: [Hit]
        let wiki: [WikiExtract]
        let steps: [Step]
        let promptBlock: String
    }

    private let session: URLSession
    private let userAgent =
        "AnyProvCode/1.0 (iOS; chat web-search; +https://github.com/anyprov/code-mobile-ai)"

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Run search for the latest user message. `onStep` is called on the main
    /// actor path via the callback for live grey status updates.
    func search(
        userMessage: String,
        mode: Mode,
        onStep: @Sendable (Step) async -> Void
    ) async throws -> Bundle {
        let primary = Self.normalizeQuery(userMessage)
        guard !primary.isEmpty else {
            throw WebSearchError.emptyQuery
        }

        var steps: [Step] = []
        var allHits: [Hit] = []
        var wiki: [WikiExtract] = []
        var queries: [String] = [primary]

        // 1) Primary web search
        let primaryStep = Step(
            name: "web_search",
            summary: "Searching the web for “\(Self.truncate(primary, 72))”…",
            status: .running
        )
        steps.append(primaryStep)
        await onStep(primaryStep)

        let primaryHits = try await duckDuckGoHTML(query: primary, limit: mode == .research ? 8 : 6)
        allHits.append(contentsOf: primaryHits)

        var donePrimary = primaryStep
        if primaryHits.isEmpty {
            donePrimary.summary = "No web results for “\(Self.truncate(primary, 72))”"
            donePrimary.status = .failed("No results")
        } else {
            donePrimary.summary = "Searched the web for “\(Self.truncate(primary, 72))”"
            donePrimary.detail = "\(primaryHits.count) source\(primaryHits.count == 1 ? "" : "s")"
            donePrimary.status = .completed
        }
        steps[steps.count - 1] = donePrimary
        await onStep(donePrimary)

        // 2) Research: follow-up queries + Wikipedia
        if mode == .research {
            let followUps = Self.followUpQueries(primary: primary, hits: primaryHits, limit: 2)
            for q in followUps {
                queries.append(q)
                var step = Step(
                    name: "web_search",
                    summary: "Researching “\(Self.truncate(q, 72))”…",
                    status: .running
                )
                steps.append(step)
                await onStep(step)

                do {
                    let hits = try await duckDuckGoHTML(query: q, limit: 5)
                    let fresh = Self.dedupe(hits, against: allHits)
                    allHits.append(contentsOf: fresh)
                    step.summary = "Researched “\(Self.truncate(q, 72))”"
                    step.detail = fresh.isEmpty
                        ? "No new sources"
                        : "\(fresh.count) more source\(fresh.count == 1 ? "" : "s")"
                    step.status = .completed
                } catch {
                    step.summary = "Research search failed for “\(Self.truncate(q, 48))”"
                    step.detail = error.localizedDescription
                    step.status = .failed(error.localizedDescription)
                }
                steps[steps.count - 1] = step
                await onStep(step)
            }

            let wikiTopics = Self.wikiTopics(primary: primary, hits: allHits, limit: 2)
            for topic in wikiTopics {
                var step = Step(
                    name: "wikipedia",
                    summary: "Looking up “\(Self.truncate(topic, 72))” on Wikipedia…",
                    status: .running
                )
                steps.append(step)
                await onStep(step)

                if let extract = await wikipediaSummary(title: topic) {
                    wiki.append(extract)
                    step.summary = "Read Wikipedia: \(extract.title)"
                    step.detail = Self.truncate(extract.extract, 80)
                    step.status = .completed
                } else {
                    step.summary = "No Wikipedia page for “\(Self.truncate(topic, 48))”"
                    step.status = .failed("Not found")
                }
                steps[steps.count - 1] = step
                await onStep(step)
            }
        }

        // Instant-answer fallback when HTML returned nothing.
        if allHits.isEmpty {
            if let ia = await duckDuckGoInstantAnswer(query: primary) {
                allHits.append(ia)
                if var last = steps.first {
                    last.summary = "Searched the web for “\(Self.truncate(primary, 72))”"
                    last.detail = "1 instant answer"
                    last.status = .completed
                    steps[0] = last
                    await onStep(last)
                }
            }
        }

        let prompt = Self.formatPrompt(
            mode: mode,
            queries: queries,
            hits: allHits,
            wiki: wiki
        )

        return Bundle(
            mode: mode,
            queries: queries,
            hits: allHits,
            wiki: wiki,
            steps: steps,
            promptBlock: prompt
        )
    }

    // MARK: - DuckDuckGo HTML

    private func duckDuckGoHTML(query: String, limit: Int) async throws -> [Hit] {
        var components = URLComponents(string: "https://html.duckduckgo.com/html/")!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = components.url else { throw WebSearchError.invalidURL }

        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw WebSearchError.transport("Non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw WebSearchError.http(status: http.statusCode)
        }
        guard let html = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
        else {
            throw WebSearchError.decoding
        }

        return Array(Self.parseDuckDuckGoHTML(html).prefix(limit))
    }

    /// Parse DDG HTML SERP (`result__a` + `result__snippet`). Pure for tests.
    static func parseDuckDuckGoHTML(_ html: String) -> [Hit] {
        // Split on result anchors so title/href stay paired with nearby snippet.
        let anchorPattern = #"<a[^>]*class="result__a"[^>]*href="([^"]+)"[^>]*>(.*?)</a>"#
        guard let anchorRegex = try? NSRegularExpression(
            pattern: anchorPattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return [] }

        let ns = html as NSString
        let full = NSRange(location: 0, length: ns.length)
        let matches = anchorRegex.matches(in: html, options: [], range: full)

        var hits: [Hit] = []
        hits.reserveCapacity(matches.count)

        for (index, match) in matches.enumerated() {
            guard match.numberOfRanges >= 3,
                  let hrefRange = Range(match.range(at: 1), in: html),
                  let titleRange = Range(match.range(at: 2), in: html)
            else { continue }

            let href = String(html[hrefRange])
            let title = stripTags(String(html[titleRange])).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, let absolute = absoluteURL(from: href) else { continue }

            // Snippet: look between this anchor and the next.
            let searchStart = match.range.upperBound
            let searchEnd: Int
            if index + 1 < matches.count {
                searchEnd = matches[index + 1].range.location
            } else {
                searchEnd = min(ns.length, searchStart + 2500)
            }
            let windowLen = max(0, searchEnd - searchStart)
            let window = ns.substring(with: NSRange(location: searchStart, length: windowLen))
            let snippet = firstSnippet(in: window)

            hits.append(Hit(title: title, url: absolute, snippet: snippet))
        }

        return dedupe(hits, against: [])
    }

    private static func firstSnippet(in window: String) -> String {
        let pattern = #"<[^>]*class="result__snippet"[^>]*>(.*?)</(?:a|div|td|span)>"#
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return "" }
        let ns = window as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let match = regex.firstMatch(in: window, options: [], range: range),
              match.numberOfRanges >= 2,
              let r = Range(match.range(at: 1), in: window)
        else { return "" }
        return stripTags(String(window[r]))
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func absoluteURL(from href: String) -> String? {
        // DDG sometimes wraps destinations: //duckduckgo.com/l/?uddg=…
        if let components = URLComponents(string: href),
           let items = components.queryItems,
           let uddg = items.first(where: { $0.name == "uddg" })?.value,
           let decoded = uddg.removingPercentEncoding,
           decoded.hasPrefix("http")
        {
            return decoded
        }
        if href.hasPrefix("http://") || href.hasPrefix("https://") {
            return href
        }
        if href.hasPrefix("//") {
            return "https:\(href)"
        }
        return nil
    }

    // MARK: - Instant Answer fallback

    private func duckDuckGoInstantAnswer(query: String) async -> Hit? {
        var components = URLComponents(string: "https://api.duckduckgo.com/")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "no_html", value: "1"),
            URLQueryItem(name: "skip_disambig", value: "1"),
        ]
        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 12

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode)
            else { return nil }

            struct IA: Decodable {
                let AbstractText: String?
                let AbstractURL: String?
                let Heading: String?
                let Answer: String?
            }
            let ia = try JSONDecoder().decode(IA.self, from: data)
            let text = (ia.AbstractText?.isEmpty == false ? ia.AbstractText : ia.Answer) ?? ""
            guard !text.isEmpty else { return nil }
            let title = (ia.Heading?.isEmpty == false ? ia.Heading : query) ?? query
            let link = ia.AbstractURL?.isEmpty == false
                ? ia.AbstractURL!
                : "https://duckduckgo.com/?q=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query)"
            return Hit(title: title, url: link, snippet: text)
        } catch {
            return nil
        }
    }

    // MARK: - Wikipedia

    private func wikipediaSummary(title: String) async -> WikiExtract? {
        // Prefer opensearch → rest summary for better title matching.
        let resolved = await wikipediaOpenSearch(query: title) ?? title
        let encoded = resolved
            .replacingOccurrences(of: " ", with: "_")
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
            ?? resolved
        guard let url = URL(string: "https://en.wikipedia.org/api/rest_v1/page/summary/\(encoded)")
        else { return nil }

        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 12

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode)
            else { return nil }

            struct Summary: Decodable {
                let title: String
                let extract: String?
                let content_urls: ContentURLs?
                struct ContentURLs: Decodable {
                    let desktop: Desktop?
                    struct Desktop: Decodable { let page: String? }
                }
                let type: String?
            }
            let s = try JSONDecoder().decode(Summary.self, from: data)
            // Skip disambiguation / not-found style pages.
            if s.type == "disambiguation" { return nil }
            let extract = (s.extract ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !extract.isEmpty else { return nil }
            let pageURL = s.content_urls?.desktop?.page
                ?? "https://en.wikipedia.org/wiki/\(encoded)"
            return WikiExtract(title: s.title, extract: extract, url: pageURL)
        } catch {
            return nil
        }
    }

    private func wikipediaOpenSearch(query: String) async -> String? {
        var components = URLComponents(string: "https://en.wikipedia.org/w/api.php")!
        components.queryItems = [
            URLQueryItem(name: "action", value: "opensearch"),
            URLQueryItem(name: "search", value: query),
            URLQueryItem(name: "limit", value: "1"),
            URLQueryItem(name: "namespace", value: "0"),
            URLQueryItem(name: "format", value: "json"),
        ]
        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode)
            else { return nil }
            // Response: [query, [titles], [descriptions], [urls]]
            guard let root = try JSONSerialization.jsonObject(with: data) as? [Any],
                  root.count >= 2,
                  let titles = root[1] as? [String],
                  let first = titles.first,
                  !first.isEmpty
            else { return nil }
            return first
        } catch {
            return nil
        }
    }

    // MARK: - Query helpers

    static func normalizeQuery(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Derive extra research queries from the primary question + top hit titles.
    static func followUpQueries(primary: String, hits: [Hit], limit: Int) -> [String] {
        var out: [String] = []
        let keywords = keywordCore(from: primary)
        if !keywords.isEmpty, keywords.caseInsensitiveCompare(primary) != .orderedSame {
            out.append(keywords)
        }
        for hit in hits.prefix(4) {
            let t = stripTags(hit.title)
                .replacingOccurrences(of: #"\s*[\|\-–—].*$"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard t.count >= 8, t.count <= 80 else { continue }
            if out.contains(where: { $0.caseInsensitiveCompare(t) == .orderedSame }) { continue }
            if t.caseInsensitiveCompare(primary) == .orderedSame { continue }
            out.append(t)
            if out.count >= limit { break }
        }
        // Year-aware angle for current events.
        if out.count < limit {
            let year = Calendar.current.component(.year, from: Date())
            let withYear = "\(keywordCore(from: primary)) \(year)"
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if withYear.count > 6,
               !out.contains(where: { $0.caseInsensitiveCompare(withYear) == .orderedSame }),
               withYear.caseInsensitiveCompare(primary) != .orderedSame
            {
                out.append(withYear)
            }
        }
        return Array(out.prefix(limit))
    }

    static func wikiTopics(primary: String, hits: [Hit], limit: Int) -> [String] {
        var topics: [String] = []
        let core = keywordCore(from: primary)
        if core.split(separator: " ").count <= 5, core.count >= 2 {
            topics.append(core)
        }
        for hit in hits.prefix(5) {
            let t = stripTags(hit.title)
                .replacingOccurrences(of: #"\s*[\|\-–—].*$"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard t.count >= 3, t.count <= 60 else { continue }
            if topics.contains(where: { $0.caseInsensitiveCompare(t) == .orderedSame }) { continue }
            topics.append(t)
            if topics.count >= limit { break }
        }
        return Array(topics.prefix(limit))
    }

    /// Drop stop-words / question fluff so multi-search has a tighter core.
    static func keywordCore(from text: String) -> String {
        let stop: Set<String> = [
            "a", "an", "the", "and", "or", "but", "if", "then", "so", "to", "of",
            "in", "on", "for", "with", "about", "as", "at", "by", "from", "into",
            "is", "are", "was", "were", "be", "been", "being", "do", "does", "did",
            "what", "when", "where", "who", "whom", "which", "why", "how",
            "can", "could", "would", "should", "will", "shall", "may", "might",
            "please", "tell", "me", "my", "your", "you", "i", "we", "us", "our",
            "this", "that", "these", "those", "it", "its", "they", "them", "their",
            "find", "search", "look", "up", "explain", "describe", "give", "show",
            "latest", "current", "info", "information", "research",
        ]
        let tokens = text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !stop.contains($0) && $0.count > 1 }
        if tokens.isEmpty {
            return normalizeQuery(text)
        }
        return tokens.joined(separator: " ")
    }

    static func dedupe(_ hits: [Hit], against existing: [Hit]) -> [Hit] {
        var seen = Set(existing.map { normalizeURLKey($0.url) })
        var out: [Hit] = []
        for h in hits {
            let key = normalizeURLKey(h.url)
            guard !key.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            out.append(h)
        }
        return out
    }

    private static func normalizeURLKey(_ url: String) -> String {
        guard var c = URLComponents(string: url) else {
            return url.lowercased()
        }
        c.scheme = c.scheme?.lowercased()
        c.host = c.host?.lowercased()
        c.fragment = nil
        // Drop tracking params
        if let items = c.queryItems {
            c.queryItems = items.filter {
                let n = $0.name.lowercased()
                return !(n.hasPrefix("utm_") || n == "ref" || n == "fbclid")
            }
            if c.queryItems?.isEmpty == true { c.queryItems = nil }
        }
        var s = c.string ?? url
        if s.hasSuffix("/") { s.removeLast() }
        return s
    }

    static func formatPrompt(
        mode: Mode,
        queries: [String],
        hits: [Hit],
        wiki: [WikiExtract]
    ) -> String {
        var lines: [String] = []
        let modeLabel = mode == .research ? "Research" : "Web search"
        lines.append("## \(modeLabel) results (live, for this turn)")
        lines.append(
            "You have access to fresh web results below. Prefer them over outdated training data. "
                + "Cite sources inline with markdown links when you use a fact. "
                + "If results are thin or conflicting, say so."
        )
        lines.append("Queries: \(queries.map { "“\($0)”" }.joined(separator: ", "))")
        lines.append("")

        if hits.isEmpty && wiki.isEmpty {
            lines.append("No web sources were retrieved. Answer from general knowledge and note the lack of live sources.")
            return lines.joined(separator: "\n")
        }

        if !hits.isEmpty {
            lines.append("### Web sources")
            for (i, h) in hits.enumerated() {
                lines.append("\(i + 1). **\(h.title)**")
                lines.append("   URL: \(h.url)")
                if !h.snippet.isEmpty {
                    lines.append("   Snippet: \(h.snippet)")
                }
            }
            lines.append("")
        }

        if !wiki.isEmpty {
            lines.append("### Wikipedia")
            for w in wiki {
                lines.append("- **\(w.title)** — \(w.url)")
                lines.append("  \(w.extract)")
            }
        }

        return lines.joined(separator: "\n")
    }

    static func stripTags(_ html: String) -> String {
        var s = html
        // Decode a few common entities before stripping tags.
        let entities: [(String, String)] = [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
            ("&#x27;", "'"), ("&nbsp;", " "),
        ]
        // Remove tags
        s = s.replacingOccurrences(
            of: "<[^>]+>",
            with: "",
            options: .regularExpression
        )
        for (e, r) in entities {
            s = s.replacingOccurrences(of: e, with: r)
        }
        // Numeric entities
        if let regex = try? NSRegularExpression(pattern: "&#(\\d+);") {
            let ns = s as NSString
            let matches = regex.matches(in: s, range: NSRange(location: 0, length: ns.length)).reversed()
            var result = s
            for m in matches {
                guard m.numberOfRanges >= 2,
                      let r = Range(m.range(at: 1), in: result),
                      let code = Int(result[r]),
                      let scalar = UnicodeScalar(code)
                else { continue }
                if let full = Range(m.range, in: result) {
                    result.replaceSubrange(full, with: String(Character(scalar)))
                }
            }
            s = result
        }
        return s
    }

    static func truncate(_ s: String, _ n: Int) -> String {
        guard s.count > n else { return s }
        let idx = s.index(s.startIndex, offsetBy: max(0, n - 1))
        return String(s[..<idx]) + "…"
    }
}

enum WebSearchError: Error, LocalizedError, Equatable {
    case emptyQuery
    case invalidURL
    case http(status: Int)
    case transport(String)
    case decoding

    var errorDescription: String? {
        switch self {
        case .emptyQuery: return "Nothing to search for."
        case .invalidURL: return "Invalid search URL."
        case let .http(status): return "Search failed (HTTP \(status))."
        case let .transport(msg): return "Search network error: \(msg)"
        case .decoding: return "Could not read search results."
        }
    }
}

/// Shared status for chat tool steps (web search, research, etc.).
enum ChatToolStatus: Equatable, Sendable {
    case pending
    case running
    case completed
    case failed(String)
}
