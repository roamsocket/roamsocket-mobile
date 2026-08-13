import Foundation

/// Streaming parser for `<memory>` tags emitted by the model in chat replies.
///
/// Tags are self-closing: `<memory action="..." attributes... />`. Bare
/// `<memory>` without attributes or a self-close is treated as text. Tags
/// inside fenced code blocks (```…```) or inline `…` spans are preserved as
/// visible text.
///
/// The parser is stateful: `push(chunk:)` returns the visible text delta
/// since the last call and any complete actions parsed so far. When the
/// stream ends, `end()` flushes any unclosed tail back as visible text.
public final class MemoryTagParser {
    public enum Action: Equatable {
        case add(category: Category, title: String, summary: String, details: [String])
        case forget(target: String)
        case rename(target: String, value: String)
        case setSummary(target: String, value: String)
        case setDetails(target: String, value: [String])

        public enum Category: String, Equatable {
            case you
            case topic
            case area
        }
    }

    public struct Result: Equatable {
        public let text: String
        public let actions: [Action]
        public init(text: String, actions: [Action]) {
            self.text = text
            self.actions = actions
        }
    }

    private var buffer: String = ""

    public init() {}

    /// Feed a chunk of assistant text. Returns the visible text delta
    /// (caller concatenates these) and any complete actions.
    public func push(chunk: String) -> Result {
        buffer += chunk
        return drain()
    }

    /// End of stream: emit any trailing visible text, drop unclosed tags.
    public func end() -> Result {
        let tail = buffer
        let cutAt = findUnclosedCut(tail)
        let text = String(tail.prefix(cutAt))
        buffer = ""
        return Result(text: text, actions: [])
    }

    // MARK: - Drain

    private func drain() -> Result {
        var actions: [Action] = []
        var visible = ""
        var cursor = buffer.startIndex
        while cursor < buffer.endIndex {
            guard let tagStart = findTagStart(in: buffer, from: cursor) else {
                let tail = String(buffer[cursor...])
                let safe = safeBoundary(tail)
                if safe > 0 {
                    visible += String(tail.prefix(safe))
                }
                cursor = buffer.endIndex
                break
            }
            if tagStart > cursor {
                visible += String(buffer[cursor..<tagStart])
            }
            guard let tagEnd = findTagEnd(in: buffer, from: tagStart) else {
                // Incomplete tag — keep both the visible prefix and the
                // partial tag in the buffer so the next chunk can complete
                // it. We must NOT emit the visible prefix here, because the
                // next push would re-emit it. So return an empty text delta
                // and let the next push (or end()) flush the held prefix.
                buffer = String(buffer[cursor...])
                return Result(text: "", actions: actions)
            }
            let tagRaw = String(buffer[tagStart..<tagEnd])
            let tagBody = tagRaw
                .replacingOccurrences(of: #"^<memory\s*"#, with: "", options: [.regularExpression, .caseInsensitive])
                .replacingOccurrences(of: #"\s*/?>\s*$"#, with: "", options: .regularExpression)
            if let action = buildAction(from: tagBody) {
                actions.append(action)
            }
            cursor = tagEnd
        }
        if cursor >= buffer.endIndex {
            buffer = ""
        }
        return Result(text: visible, actions: actions)
    }

    private func findUnclosedCut(_ text: String) -> Int {
        var search = text.startIndex
        while search < text.endIndex {
            guard let start = findTagStart(in: text, from: search) else { return text.count }
            guard let _ = findTagEnd(in: text, from: start) else {
                return text.distance(from: text.startIndex, to: start)
            }
            search = text.index(after: start)
        }
        return text.count
    }

    // MARK: - Tag detection

    private func findTagStart(in s: String, from start: String.Index) -> String.Index? {
        let tagOpen = "<memory"
        var i = start
        while i < s.endIndex {
            guard let found = s.range(of: tagOpen, range: i..<s.endIndex) else { return nil }
            let after = s.index(found.lowerBound, offsetBy: tagOpen.count)
            let next: Character? = after < s.endIndex ? s[after] : nil
            let isTag = next == nil || next == "/" || (next.map { $0.isWhitespace } ?? false)
            if isTag && !isInsideUnclosedCodeFence(s, upTo: found.lowerBound) {
                return found.lowerBound
            }
            i = s.index(after: found.lowerBound)
        }
        return nil
    }

    private func findTagEnd(in s: String, from start: String.Index) -> String.Index? {
        guard let r = s.range(of: "/>", range: start..<s.endIndex) else { return nil }
        return r.upperBound
    }

    private func isInsideUnclosedCodeFence(_ s: String, upTo pos: String.Index) -> Bool {
        let before = String(s[..<pos])
        let fence = before.components(separatedBy: "```").count - 1
        if fence % 2 == 1 { return true }
        let lineStart = before.lastIndex(of: "\n").map { s.index(after: $0) } ?? s.startIndex
        let line = String(s[lineStart..<pos])
        let inline = line.filter { $0 == "`" }.count
        return inline % 2 == 1
    }

    private func safeBoundary(_ s: String) -> Int {
        guard let lastLT = s.lastIndex(of: "<") else { return s.count }
        let tail = s[lastLT...]
        let tagOpen = "<memory"
        if tail.count >= tagOpen.count { return s.count }
        let head = String(tagOpen.prefix(tail.count))
        if tail.lowercased() == head.lowercased() {
            return s.distance(from: s.startIndex, to: lastLT)
        }
        return s.count
    }

    // MARK: - Attribute parsing

    private func parseAttrs(_ body: String) -> [String: String] {
        var out: [String: String] = [:]
        let pattern = #"([a-zA-Z_][\w-]*)\s*=\s*"([^"]*)""#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return out }
        let range = NSRange(body.startIndex..., in: body)
        re.enumerateMatches(in: body, range: range) { match, _, _ in
            guard let match,
                  let keyR = Range(match.range(at: 1), in: body),
                  let valR = Range(match.range(at: 2), in: body) else { return }
            out[String(body[keyR]).lowercased()] = String(body[valR])
        }
        return out
    }

    private func buildAction(from tagBody: String) -> Action? {
        let attrs = parseAttrs(tagBody)
        guard let raw = attrs["action"]?.lowercased() else { return nil }
        switch raw {
        case "add":
            let catRaw = (attrs["category"] ?? "you").lowercased()
            guard let category = Action.Category(rawValue: catRaw) else { return nil }
            let details = (attrs["details"] ?? "")
                .split(separator: "|")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let title = (attrs["title"] ?? "Profile").trimmingCharacters(in: .whitespacesAndNewlines)
            return .add(
                category: category,
                title: title.isEmpty ? "Profile" : title,
                summary: (attrs["summary"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                details: details
            )
        case "forget":
            guard let target = attrs["target"]?.trimmingCharacters(in: .whitespacesAndNewlines), !target.isEmpty else { return nil }
            return .forget(target: target)
        case "rename":
            guard let target = attrs["target"]?.trimmingCharacters(in: .whitespacesAndNewlines), !target.isEmpty,
                  let value = attrs["value"]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return .rename(target: target, value: value)
        case "set_summary":
            guard let target = attrs["target"]?.trimmingCharacters(in: .whitespacesAndNewlines), !target.isEmpty,
                  let value = attrs["value"]?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
            return .setSummary(target: target, value: value)
        case "set_details":
            guard let target = attrs["target"]?.trimmingCharacters(in: .whitespacesAndNewlines), !target.isEmpty else { return nil }
            let value = (attrs["value"] ?? "")
                .split(separator: "|")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return .setDetails(target: target, value: value)
        default:
            return nil
        }
    }
}
