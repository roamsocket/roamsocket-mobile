import Foundation

/// A question / answer / reasoning triple extracted from a study-scan analysis.
struct StudyParsedCard: Equatable {
    var question: String
    var answer: String
    var reasoning: String
}

/// Turns a vision model's answer into editable flashcard drafts.
///
/// Primary target format (emitted by the Study prompt):
///
/// ```
/// QUESTION: …
/// ANSWER: …
/// REASON: …
/// ---
/// ```
///
/// Also tolerates the general Vision quiz layout (`## Question N` with
/// `**Text:**` / `**Answer:**` / `**Reason:**`), bare numbered questions, and
/// any free-form reply (as a single fallback card so nothing is lost).
enum StudyQuestionParser {

    private enum Field: CaseIterable {
        case question, answer, reasoning

        var labels: [String] {
            switch self {
            case .question: return ["question", "q", "text", "prompt"]
            case .answer: return ["answer", "solution", "a", "ans"]
            case .reasoning: return ["reason", "reasoning", "rationale", "explanation", "why", "r"]
            }
        }
    }

    private struct MutableCard {
        var question: String = ""
        var answer: String = ""
        var reasoning: String = ""
        var lastField: Field?

        var hasAnyContent: Bool {
            !question.isEmpty || !answer.isEmpty || !reasoning.isEmpty
        }

        var card: StudyParsedCard {
            StudyParsedCard(
                question: question.trimmingCharacters(in: .whitespacesAndNewlines),
                answer: answer.trimmingCharacters(in: .whitespacesAndNewlines),
                reasoning: reasoning.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    static func parse(_ rawText: String) -> [StudyParsedCard] {
        let parsed = ThinkingExtractor.extract(from: rawText)
        var text = parsed.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty,
           let thinking = parsed.thinking?.trimmingCharacters(in: .whitespacesAndNewlines),
           !thinking.isEmpty {
            text = thinking
        }

        let upper = text.uppercased()
        if upper == "NO_QUESTIONS" || upper == "NONE" || upper == "NO QUESTIONS" {
            return []
        }

        let cards = parseStructured(text)
        if !cards.isEmpty { return cards }

        // Fallback: the model didn't follow any block format. Keep the whole
        // analysis as one editable card so nothing is silently dropped.
        if !text.isEmpty {
            return [StudyParsedCard(question: "", answer: text, reasoning: "")]
        }
        return []
    }

    // MARK: - Structured parsing

    private static func parseStructured(_ text: String) -> [StudyParsedCard] {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        var cards: [StudyParsedCard] = []
        var current = MutableCard()
        /// True when any heading / label / numbered-question marker was seen.
        /// Unstructured prose falls through to the single-card fallback.
        var sawStructure = false

        func flush() {
            cards.append(current.card)
            current = MutableCard()
        }

        for rawLine in lines {
            let cleaned = clean(rawLine)

            if isBlockSeparator(cleaned) {
                if current.hasAnyContent { flush() }
                continue
            }
            // Models sometimes echo the separator instruction — drop it.
            if cleaned.lowercased().contains("separate question") {
                if current.hasAnyContent { flush() }
                continue
            }

            // "## Question N", "Question 1:", "Q2." — new card (optional inline text).
            if let rest = questionHeadingRest(cleaned) {
                sawStructure = true
                if current.hasAnyContent { flush() }
                current.question = rest
                current.lastField = rest.isEmpty ? nil : .question
                continue
            }

            // "QUESTION:" / "ANSWER:" / "REASON:" labels.
            if let (field, body) = matchLabel(cleaned) {
                sawStructure = true
                switch field {
                case .question:
                    if current.hasAnyContent { flush() }
                    current.question = body
                case .answer:
                    if !current.answer.isEmpty || !current.reasoning.isEmpty { flush() }
                    current.answer = body
                case .reasoning:
                    if !current.reasoning.isEmpty { flush() }
                    current.reasoning = body
                }
                current.lastField = field
                continue
            }

            // "1. What is…" — bare numbered question starts a card.
            if let rest = numberedQuestionRest(cleaned) {
                sawStructure = true
                if current.hasAnyContent { flush() }
                current.question = rest
                current.lastField = .question
                continue
            }

            guard !cleaned.isEmpty else { continue }

            // Continuation line → append to the field the model is filling.
            switch current.lastField {
            case .question:
                current.question = append(current.question, cleaned)
            case .answer:
                current.answer = append(current.answer, cleaned)
            case .reasoning:
                current.reasoning = append(current.reasoning, cleaned)
            case nil:
                current.question = append(current.question, cleaned)
            }
        }

        flush()
        return sawStructure ? cards : []
    }

    // MARK: - Line classification

    /// Strip list bullets, bold markers, and leading/trailing noise.
    private static func clean(_ line: String) -> String {
        var result = line.trimmingCharacters(in: .whitespaces)
        for prefix in ["- ", "* ", "+ ", "• "] where result.hasPrefix(prefix) {
            result = String(result.dropFirst(prefix.count))
            break
        }
        if result.hasPrefix("**") { result = String(result.dropFirst(2)) }
        if result.hasPrefix("_") { result = String(result.dropFirst()) }
        return result.trimmingCharacters(in: .whitespaces)
    }

    private static func isBlockSeparator(_ line: String) -> Bool {
        guard !line.isEmpty else { return false }
        let allowed = CharacterSet(charactersIn: "-*_=~")
        return line.unicodeScalars.allSatisfy { allowed.contains($0) }
            && line.unicodeScalars.count >= 3
    }

    /// Matches `## Question 1`, `Question 1:`, `**Q1.**`, `Q2.`. Returns any
    /// inline question text after the heading (empty when the body follows).
    private static func questionHeadingRest(_ line: String) -> String? {
        guard let h = line.range(
            of: #"(?:^#{1,6}\s+question|^question|^q)(?:\s*\d+)?\s*[:.)—–-]?\s*"#,
            options: [.regularExpression, .caseInsensitive]
        ) else { return nil }
        return trimmedHeadingBody(String(line[h.upperBound...]))
    }

    /// "1. What is…" / "1) What is…" (bare numbered question lines).
    private static func numberedQuestionRest(_ line: String) -> String? {
        guard let r = line.range(of: #"^\d{1,3}[.)]\s+"#, options: .regularExpression) else {
            return nil
        }
        return String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
    }

    /// Strip the trailing ":" / "." / ")" after a heading.
    private static func trimmedHeadingBody(_ text: String) -> String {
        var trimmed = text.trimmingCharacters(in: .whitespaces)
        trimmed = String(trimmed.drop(while: { $0 == ":" || $0 == "." || $0 == ")" || $0 == "-" || $0 == "—" }))
        return trimmed.trimmingCharacters(in: .whitespaces)
    }

    /// Match a leading `QUESTION:` / `ANSWER:` / `REASON:`-style label.
    private static func matchLabel(_ line: String) -> (Field, String)? {
        let lowered = line.lowercased()
        for field in Field.allCases {
            for label in field.labels {
                guard lowered.hasPrefix(label) else { continue }
                var remainder = String(line.dropFirst(label.count))
                // Allow "question 1:" / "q1" numbering.
                if let numEnd = remainder.range(of: #"^\s*\d+"#, options: .regularExpression) {
                    remainder = String(remainder[numEnd.upperBound...])
                }
                let trimmed = remainder.trimmingCharacters(in: .whitespaces)
                guard let first = trimmed.unicodeScalars.first else {
                    return (field, "")
                }
                let separators = CharacterSet(charactersIn: ":.-=—–")
                guard separators.contains(first) else { continue }
                let body = trimmed.dropFirst()
                    .trimmingCharacters(in: CharacterSet(charactersIn: " -*`_"))
                return (field, body)
            }
        }
        return nil
    }

    private static func append(_ existing: String, _ line: String) -> String {
        if existing.isEmpty { return line }
        return existing + " " + line
    }
}
