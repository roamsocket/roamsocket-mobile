import Foundation

/// A single automated browser action proposed by the AI. Steps are always
/// shown to the user before they run — see `BrowserApprovalGranularity`.
struct BrowserStep: Identifiable, Codable, Equatable {
    enum Kind: String, Codable {
        case navigate
        case click
        case type
        case scroll
        case back
        case forward
        case reload
        case wait
        case extract

        var systemImage: String {
            switch self {
            case .navigate: return "arrow.right.circle"
            case .click: return "hand.tap"
            case .type: return "keyboard"
            case .scroll: return "arrow.up.and.down"
            case .back: return "chevron.left"
            case .forward: return "chevron.right"
            case .reload: return "arrow.clockwise"
            case .wait: return "clock"
            case .extract: return "doc.text.magnifyingglass"
            }
        }

        /// Only "read" actions may ever run without a pause; every kind is
        /// still gated by the plan/approve flow before the first execution.
        var isReadOnly: Bool { self == .extract }
    }

    enum Status: String, Codable {
        case pending
        case approved
        case denied
        case running
        case done
        case failed
    }

    let id: UUID
    let kind: Kind
    /// URL for `.navigate`; a text/selector hint for `.click`/`.type`; a
    /// direction ("up"/"down") for `.scroll`; seconds for `.wait`.
    let target: String?
    /// Text to type for `.type`. Unused otherwise.
    let value: String?
    /// Human-readable explanation of *why* this step is being proposed,
    /// shown verbatim in the approval card.
    let description: String
    var status: Status = .pending
    /// Short result note filled in after the step runs (or fails).
    var resultNote: String?

    init(
        id: UUID = UUID(),
        kind: Kind,
        target: String? = nil,
        value: String? = nil,
        description: String,
        status: Status = .pending,
        resultNote: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.target = target
        self.value = value
        self.description = description
        self.status = status
        self.resultNote = resultNote
    }
}

/// A plan proposed by the AI in response to one prompt: a restated goal plus
/// the ordered steps it wants permission to run. Nothing in `steps` executes
/// until the user approves — either the whole plan at once, or one step at a
/// time — which is why this always renders before any browser action happens.
struct BrowserPlan: Identifiable, Equatable {
    let id: UUID
    let goal: String
    var steps: [BrowserStep]
    let createdAt: Date

    init(id: UUID = UUID(), goal: String, steps: [BrowserStep], createdAt: Date = Date()) {
        self.id = id
        self.goal = goal
        self.steps = steps
        self.createdAt = createdAt
    }
}

/// What the AI prompt bar does with the user's text.
enum BrowserPromptMode: String, CaseIterable {
    /// Ask questions about the current page — the model answers in prose
    /// grounded in the live page and never proposes actions.
    case ask
    /// Turn the request into an action plan to review and approve.
    case act

    var title: String {
        switch self {
        case .ask: return "Ask"
        case .act: return "Do"
        }
    }
}

/// How much the user has to bless before the agent moves on to the next step.
enum BrowserApprovalGranularity: String, CaseIterable, Codable {
    /// One tap approves every step in the plan; steps still run one at a
    /// time and stop immediately if any of them fails.
    case bulk
    /// Every step pauses for an individual Allow/Deny before it runs.
    case stepByStep

    var title: String {
        switch self {
        case .bulk: return "Approve all at once"
        case .stepByStep: return "Approve each step"
        }
    }

    var subtitle: String {
        switch self {
        case .bulk: return "Review the full plan, then run it in one go."
        case .stepByStep: return "Confirm every action before it happens."
        }
    }

    var systemImage: String {
        switch self {
        case .bulk: return "checklist.checked"
        case .stepByStep: return "hand.raised"
        }
    }
}

/// A snapshot of the current page handed to the model so it can plan against
/// real content instead of guessing blindly.
struct BrowserPageContext: Equatable {
    var url: String
    var title: String
    /// Trimmed visible text (first ~4000 chars) for grounding.
    var textSnippet: String
    /// `label -> href` pairs for the most prominent links/buttons on the page.
    var links: [BrowserPageLink]
}

struct BrowserPageLink: Equatable {
    var label: String
    var href: String
}

struct BrowserBookmark: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var url: String
    var createdAt: Date

    init(id: UUID = UUID(), title: String, url: String, createdAt: Date = Date()) {
        self.id = id
        self.title = title
        self.url = url
        self.createdAt = createdAt
    }
}

struct BrowserHistoryEntry: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var url: String
    var visitedAt: Date

    init(id: UUID = UUID(), title: String, url: String, visitedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.url = url
        self.visitedAt = visitedAt
    }
}

/// A single turn in the browser's Ask-mode conversation about the current page.
struct BrowserChatMessage: Identifiable, Equatable {
    enum Role: Equatable {
        case user
        case assistant
    }

    let id: UUID
    let role: Role
    /// Raw assistant text may include `…` tags; the UI peels them
    /// before display and before feeding them back as history.
    var content: String
    /// True when this assistant reply was supplemented with live web search
    /// that returned at least one hit. Renders as a quiet grey "Searched
    /// the web for more context" pill under the assistant message.
    var searchedWeb: Bool
    /// Set when the Ask-mode web-search fallback ran and returned zero hits.
    /// Lets the UI tell the user "we tried, nothing came back" instead of
    /// just showing a confident-sounding "I can't find that" answer with no
    /// signal that the agent actually searched. When this is non-nil it
    /// takes precedence over `searchedWeb` so we don't claim success while
    /// also showing the empty-results note.
    var webSearchEmpty: String?
    let createdAt: Date

    init(
        id: UUID = UUID(),
        role: Role,
        content: String,
        searchedWeb: Bool = false,
        webSearchEmpty: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.searchedWeb = searchedWeb
        self.webSearchEmpty = webSearchEmpty
        self.createdAt = createdAt
    }

    /// User-facing copy of the turn (thinking tags stripped) — sent back to
    /// the model as history so follow-ups keep conversational context.
    var visibleContent: String {
        ThinkingExtractor.plainVisibleText(from: content)
    }
}

/// Normalizes whatever the user typed in the address/prompt bar into a URL:
/// bare domains get `https://` prefixed, anything else falls back to a search.
enum BrowserAddressResolver {
    static func resolve(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let url = URL(string: trimmed), url.scheme != nil {
            return url
        }
        if looksLikeHost(trimmed), let url = URL(string: "https://\(trimmed)") {
            return url
        }
        var q = URLComponents()
        q.scheme = "https"
        q.host = "www.google.com"
        q.path = "/search"
        q.queryItems = [URLQueryItem(name: "q", value: trimmed)]
        return q.url
    }

    private static func looksLikeHost(_ s: String) -> Bool {
        guard !s.contains(" ") else { return false }
        guard s.contains(".") else { return false }
        let disallowed = CharacterSet(charactersIn: "!?,;:'\"()[]{}")
        return s.rangeOfCharacter(from: disallowed) == nil
    }
}
