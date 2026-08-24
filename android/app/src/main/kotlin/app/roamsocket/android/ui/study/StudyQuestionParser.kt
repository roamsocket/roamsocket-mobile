package app.roamsocket.android.ui.study

import app.roamsocket.android.ui.chat.ThinkingExtractor

/**
 * A question / answer / reasoning triple extracted from a study-scan analysis.
 *
 * Ports [StudyParsedCard] from iOS `StudyQuestionParser.swift`.
 */
data class StudyParsedCard(
    val question: String,
    val answer: String,
    val reasoning: String,
)

/**
 * Save state shown on a flashcard's Save button.
 *
 * Ports [StudyCardSaveState] from iOS `StudyFlashcardCardView.swift`.
 */
enum class StudyCardSaveState {
    /** Never written to the deck yet. */
    UNSAVED,
    /** Saved and unchanged since. */
    SAVED,
    /** Already saved but edited again since the last save. */
    DIRTY,
}

/** One flashcard being composed in the scan flow.
 *
 *  Ports [StudyFlashcardDraft] from iOS `StudyViewModel.swift`.
 */
data class StudyFlashcardDraft(
    val id: String = java.util.UUID.randomUUID().toString(),
    var question: String = "",
    var answer: String = "",
    var reasoning: String = "",
    var isSaved: Boolean = false,
    var isDirty: Boolean = false,
) {
    fun toFlashcard() = Flashcard(
        id = id,
        question = question,
        answer = answer,
        reasoning = reasoning,
    )
}

/**
 * Turns a vision model's answer into editable flashcard drafts.
 *
 * Ports [StudyQuestionParser] from iOS `StudyQuestionParser.swift`.
 *
 * Primary target format (emitted by the Study prompt):
 * ```
 * QUESTION: …
 * ANSWER: …
 * REASON: …
 * ---
 * ```
 *
 * Also tolerates the general Vision quiz layout (`## Question N` with
 * `**Text:**` / `**Answer:**` / `**Reason:**`), bare numbered questions,
 * and any free-form reply (as a single fallback card so nothing is lost).
 */
object StudyQuestionParser {

    private enum class Field(val labels: List<String>) {
        QUESTION(listOf("question", "q", "text", "prompt")),
        ANSWER(listOf("answer", "solution", "a", "ans")),
        REASONING(listOf("reason", "reasoning", "rationale", "explanation", "why", "r")),
    }

    private data class MutableCard(
        var question: String = "",
        var answer: String = "",
        var reasoning: String = "",
        var lastField: Field? = null,
    ) {
        val hasAnyContent: Boolean
            get() = question.isNotEmpty() || answer.isNotEmpty() || reasoning.isNotEmpty()

        fun toParsedCard() = StudyParsedCard(
            question = question.trim(),
            answer = answer.trim(),
            reasoning = reasoning.trim(),
        )
    }

    fun parse(rawText: String): List<StudyParsedCard> {
        val extracted = ThinkingExtractor.extract(rawText)
        var text = extracted.content.trim()
        if (text.isEmpty() && !extracted.thinking.isNullOrBlank()) {
            text = extracted.thinking.trim()
        }

        val upper = text.uppercase()
        if (upper == "NO_QUESTIONS" || upper == "NONE" || upper == "NO QUESTIONS") {
            return emptyList()
        }

        val cards = parseStructured(text)
        if (cards.isNotEmpty()) return cards

        // Fallback: the model didn't follow any block format. Keep the whole
        // analysis as one editable card so nothing is silently dropped.
        if (text.isNotEmpty()) {
            return listOf(StudyParsedCard(question = "", answer = text, reasoning = ""))
        }
        return emptyList()
    }

    // ---------------------------------------------------------------------
    // Structured parsing
    // ---------------------------------------------------------------------

    private fun parseStructured(text: String): List<StudyParsedCard> {
        val lines = text.split("\n").filter { it.isNotEmpty() }
        val cards = mutableListOf<StudyParsedCard>()
        var current = MutableCard()
        var sawStructure = false

        for (rawLine in lines) {
            val cleaned = clean(rawLine)

            if (isBlockSeparator(cleaned)) {
                if (current.hasAnyContent) {
                    cards.add(current.toParsedCard())
                    current = MutableCard()
                }
                continue
            }
            // Models sometimes echo the separator instruction — drop it.
            if (cleaned.lowercase().contains("separate question")) {
                if (current.hasAnyContent) {
                    cards.add(current.toParsedCard())
                    current = MutableCard()
                }
                continue
            }

            // "## Question N", "Question 1:", "Q2." — new card (optional inline text).
            val headingRest = questionHeadingRest(cleaned)
            if (headingRest != null) {
                sawStructure = true
                if (current.hasAnyContent) {
                    cards.add(current.toParsedCard())
                    current = MutableCard()
                }
                current.question = headingRest
                current.lastField = if (headingRest.isEmpty()) null else Field.QUESTION
                continue
            }

            // "QUESTION:" / "ANSWER:" / "REASON:" labels.
            val labelMatch = matchLabel(cleaned)
            if (labelMatch != null) {
                sawStructure = true
                val (field, body) = labelMatch
                when (field) {
                    Field.QUESTION -> {
                        if (current.hasAnyContent) {
                            cards.add(current.toParsedCard())
                            current = MutableCard()
                        }
                        current.question = body
                    }
                    Field.ANSWER -> {
                        if (current.answer.isNotEmpty() || current.reasoning.isNotEmpty()) {
                            cards.add(current.toParsedCard())
                            current = MutableCard()
                        }
                        current.answer = body
                    }
                    Field.REASONING -> {
                        if (current.reasoning.isNotEmpty()) {
                            cards.add(current.toParsedCard())
                            current = MutableCard()
                        }
                        current.reasoning = body
                    }
                }
                current.lastField = field
                continue
            }

            // "1. What is…" — bare numbered question lines.
            val numberedRest = numberedQuestionRest(cleaned)
            if (numberedRest != null) {
                sawStructure = true
                if (current.hasAnyContent) {
                    cards.add(current.toParsedCard())
                    current = MutableCard()
                }
                current.question = numberedRest
                current.lastField = Field.QUESTION
                continue
            }

            if (cleaned.isEmpty()) continue

            // Continuation line → append to the field the model is filling.
            when (current.lastField) {
                Field.QUESTION -> current.question = append(current.question, cleaned)
                Field.ANSWER -> current.answer = append(current.answer, cleaned)
                Field.REASONING -> current.reasoning = append(current.reasoning, cleaned)
                null -> current.question = append(current.question, cleaned)
            }
        }

        if (current.hasAnyContent) {
            cards.add(current.toParsedCard())
        }
        return if (sawStructure) cards else emptyList()
    }

    // ---------------------------------------------------------------------
    // Line classification
    // ---------------------------------------------------------------------

    /** Strip list bullets, bold markers, and leading/trailing noise. */
    private fun clean(line: String): String {
        var result = line.trim()
        for (prefix in listOf("- ", "* ", "+ ", "\u2022 ")) {
            if (result.startsWith(prefix)) {
                result = result.drop(prefix.length)
                break
            }
        }
        if (result.startsWith("**")) result = result.drop(2)
        if (result.startsWith("_")) result = result.drop(1)
        return result.trim()
    }

    private fun isBlockSeparator(line: String): Boolean {
        if (line.isEmpty()) return false
        val allowedChars = setOf('-', '*', '_', '=', '~')
        return line.all { it in allowedChars } && line.length >= 3
    }

    /** Matches `## Question 1`, `Question 1:`, `**Q1.**`, `Q2.`.
     *  Returns any inline question text after the heading (empty when body follows). */
    private fun questionHeadingRest(line: String): String? {
        val patterns = listOf(
            Regex("""^#{1,6}\s+question""", RegexOption.IGNORE_CASE),
            Regex("""^question""", RegexOption.IGNORE_CASE),
            Regex("""^q\b""", RegexOption.IGNORE_CASE),
        )
        for (pattern in patterns) {
            val match = pattern.find(line) ?: continue
            val rest = line.substring(match.range.last + 1).trim()
            // Try to strip optional "N" + ":.", etc.
            val after = trimmedHeadingBody(rest)
            return after
        }
        return null
    }

    /** "1. What is…" / "1) What is…" (bare numbered question lines). */
    private fun numberedQuestionRest(line: String): String? {
        val match = Regex("""^\d{1,3}[.)]\s+""").find(line) ?: return null
        return line.substring(match.range.last + 1).trim()
    }

    /** Strip the trailing ":" / "." / ")" after a heading. */
    private fun trimmedHeadingBody(text: String): String {
        var trimmed = text.trim()
        val drops = setOf(':', '.', ')', '-', '\u2014', '\u2013')
        while (trimmed.isNotEmpty() && trimmed.first() in drops) {
            trimmed = trimmed.drop(1)
        }
        return trimmed.trim()
    }

    /** Match a leading `QUESTION:` / `ANSWER:` / `REASON:`-style label. */
    private fun matchLabel(line: String): Pair<Field, String>? {
        val lowered = line.lowercase()
        for (field in Field.entries) {
            for (label in field.labels) {
                if (!lowered.startsWith(label)) continue
                var remainder = line.drop(label.length)
                // Allow "question 1:" / "q1" numbering.
                val numMatch = Regex("""^\s*\d+""").find(remainder)
                if (numMatch != null) {
                    remainder = remainder.substring(numMatch.range.last + 1)
                }
                val trimmed = remainder.trim()
                if (trimmed.isEmpty()) return field to ""
                val first = trimmed.first()
                val separators = setOf(':', '.', '-', '=', '\u2014', '\u2013')
                if (first !in separators) continue
                val body = trimmed.drop(1).trimStart(' ', '*', '`')
                return field to body
            }
        }
        return null
    }

    private fun append(existing: String, line: String): String {
        return if (existing.isEmpty()) line else "$existing $line"
    }
}
