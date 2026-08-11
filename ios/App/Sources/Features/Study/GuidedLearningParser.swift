import Foundation

/// Turns a tutor reply into a `GuidedLessonTurn` by splitting it on the
/// labelled blocks the Guided Learning system prompt asks for:
///
/// ```
/// PLAN
/// - step one
/// - step two
///
/// LESSON
/// …explanation…
///
/// QUESTION
/// Which of these is…?
/// A) …
/// B) …
///
/// HINT
/// …nudge…
///
/// FEEDBACK
/// CORRECT: nice — that's why…
///
/// RECAP
/// …summary…
///
/// CARDS
/// QUESTION: …
/// ANSWER: …
/// REASON: …
/// ---
/// ```
///
/// Blocks may carry inline content after the header (`QUESTION: …`). Text that
/// appears before any header is dropped (models sometimes add a preamble); if
/// no structure is recognized at all, the whole reply falls back to a lesson so
/// nothing is silently lost.
enum GuidedLearningParser {

    private enum Block: String, CaseIterable {
        case plan = "PLAN"
        case lesson = "LESSON"
        case question = "QUESTION"
        case hint = "HINT"
        case feedback = "FEEDBACK"
        case recap = "RECAP"
        case cards = "CARDS"
    }

    // MARK: - Entry

    static func parse(_ rawText: String) -> GuidedLessonTurn {
        let parsed = ThinkingExtractor.extract(from: rawText)
        var text = parsed.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty,
           let thinking = parsed.thinking?.trimmingCharacters(in: .whitespacesAndNewlines),
           !thinking.isEmpty {
            text = thinking
        }

        var turn = GuidedLessonTurn()

        for (block, content) in splitIntoSections(text) {
            switch block {
            case .plan: turn.plan = parsePlan(content)
            case .lesson: turn.lesson = content
            case .question: turn.question = parseCheckIn(content)
            case .hint: turn.hint = content
            case .feedback: turn.feedback = parseFeedback(content)
            case .recap: turn.recap = content
            case .cards: turn.cards = parseCards(content)
            }
        }

        // Resilience: the model rambled with no recognized structure — keep the
        // whole reply visible as a lesson rather than showing an empty screen.
        if turn.plan.isEmpty,
           turn.lesson == nil,
           turn.question == nil,
           turn.hint == nil,
           turn.feedback == nil,
           turn.recap == nil,
           !text.isEmpty
        {
            turn.lesson = text
        }
        return turn
    }

    // MARK: - Section splitting

    private static func splitIntoSections(_ text: String) -> [(Block, String)] {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        var sections: [(Block, String)] = []
        var currentBlock: Block?
        var currentLines: [String] = []

        func flush() {
            guard let block = currentBlock else { return }
            let content = currentLines
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            sections.append((block, content))
            currentBlock = nil
            currentLines = []
        }

        for line in lines {
            // Inside a CARDS block, `QUESTION: …` lines belong to the cards —
            // never treat them as a new section header.
            if let (block, inline) = header(of: line),
               !(currentBlock == .cards && block == .question)
            {
                flush()
                currentBlock = block
                if let inline {
                    currentLines.append(inline)
                }
            } else if currentBlock != nil {
                currentLines.append(line)
            }
            // Text before the first header is preamble — intentionally dropped.
        }
        flush()
        return sections
    }

    /// Matches a bare block header (`LESSON`, `LESSON:`) or an inline header
    /// (`LESSON: …content…`). Returns the block and any inline content.
    private static func header(of line: String) -> (Block, String?)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        let upper = trimmed.uppercased()
        for block in Block.allCases {
            if upper == block.rawValue {
                return (block, nil)
            }
            let prefix = block.rawValue + ":"
            if upper.hasPrefix(prefix) {
                let inline = trimmed.dropFirst(block.rawValue.count)
                    .trimmingCharacters(in: CharacterSet(charactersIn: ": "))
                return (block, inline.isEmpty ? nil : inline)
            }
        }
        return nil
    }

    // MARK: - Block parsers

    private static func parsePlan(_ content: String) -> [String] {
        content
            .split(whereSeparator: \.isNewline)
            .map { line in
                var cleaned = line.trimmingCharacters(in: .whitespaces)
                for prefix in ["- ", "* ", "+ ", "• "] where cleaned.hasPrefix(prefix) {
                    cleaned = String(cleaned.dropFirst(prefix.count))
                    break
                }
                if let num = cleaned.range(of: #"^\d{1,2}[.)]\s+"#, options: .regularExpression) {
                    cleaned = String(cleaned[num.upperBound...])
                }
                return cleaned.trimmingCharacters(in: .whitespaces)
            }
            .filter { !$0.isEmpty }
    }

    private static func parseCheckIn(_ content: String) -> GuidedCheckIn {
        var body: [String] = []
        var options: [String] = []
        for line in content.split(whereSeparator: \.isNewline).map(String.init) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let option = optionText(trimmed) {
                options.append(option)
            } else if !trimmed.isEmpty {
                body.append(trimmed)
            }
        }
        return GuidedCheckIn(
            question: body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines),
            options: options
        )
    }

    /// `A) …`, `B. …`, `c) …` → the option text (without the letter).
    private static func optionText(_ line: String) -> String? {
        guard let r = line.range(
            of: #"^[A-Da-d][).:]\s+"#,
            options: .regularExpression
        ) else { return nil }
        let body = String(line[r.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? nil : body
    }

    private static func parseFeedback(_ content: String) -> GuidedFeedback {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let upper = trimmed.uppercased()
        if upper.hasPrefix("CORRECT") {
            return GuidedFeedback(isCorrect: true, text: stripVerdict(trimmed))
        }
        if upper.hasPrefix("INCORRECT") {
            return GuidedFeedback(isCorrect: false, text: stripVerdict(trimmed))
        }
        // No verdict prefix — default to correct so the session keeps moving.
        return GuidedFeedback(isCorrect: true, text: trimmed)
    }

    private static func stripVerdict(_ text: String) -> String {
        guard let colon = text.range(of: ":") else {
            // "CORRECT" with no explanation.
            return ""
        }
        return String(text[colon.upperBound...])
            .trimmingCharacters(in: CharacterSet(charactersIn: " :\n"))
    }

    private static func parseCards(_ content: String) -> [StudyParsedCard] {
        StudyQuestionParser.parse(content)
    }
}
