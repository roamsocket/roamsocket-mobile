import Foundation

/// What the guided lesson should teach from. One source is active at a time;
/// the actual material lives in the view model (`topic`, `notes`,
/// `selectedDeck`, photo transcription).
enum GuidedLearningSource: String, CaseIterable, Identifiable {
    case topic
    case notes
    case photo
    case deck

    var id: String { rawValue }

    var title: String {
        switch self {
        case .topic: return "Topic"
        case .notes: return "Notes"
        case .photo: return "Photo"
        case .deck: return "Deck"
        }
    }

    var systemImage: String {
        switch self {
        case .topic: return "lightbulb.max"
        case .notes: return "doc.plaintext"
        case .photo: return "photo"
        case .deck: return "square.stack.3d.up"
        }
    }
}

/// High-level screen the guided learning flow is showing.
enum GuidedLearningPhase: Equatable {
    case setup
    case planning
    case teaching
    case evaluating
    case done
    case failed(String)
}

/// A multiple-choice check-in a tutor asks after teaching a step.
struct GuidedCheckIn: Equatable {
    var question: String
    /// Option texts (empty for free-response checks). Letters are derived
    /// from the index when rendering.
    var options: [String]
}

/// Verdict + explanation for a submitted answer.
struct GuidedFeedback: Equatable {
    var isCorrect: Bool
    var text: String
}

/// One tutor reply, parsed into its labelled blocks (see the system prompt in
/// `GuidedLearningViewModel` for the wire format).
struct GuidedLessonTurn: Equatable {
    var plan: [String]
    var lesson: String?
    var question: GuidedCheckIn?
    var hint: String?
    var feedback: GuidedFeedback?
    var recap: String?
    /// Flashcards emitted at the end of a finished lesson (RECAP + CARDS).
    var cards: [StudyParsedCard]

    init(
        plan: [String] = [],
        lesson: String? = nil,
        question: GuidedCheckIn? = nil,
        hint: String? = nil,
        feedback: GuidedFeedback? = nil,
        recap: String? = nil,
        cards: [StudyParsedCard] = []
    ) {
        self.plan = plan
        self.lesson = lesson
        self.question = question
        self.hint = hint
        self.feedback = feedback
        self.recap = recap
        self.cards = cards
    }
}
