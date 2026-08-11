import Foundation
import ActivityKit

/// Starts a Live Activity after the model has been working long enough that a
/// quick reply would not flash chrome on the Lock Screen / Dynamic Island.
@MainActor
final class AIThinkingActivityManager {
    static let shared = AIThinkingActivityManager()

    /// Delay before showing the Live Activity so short prompts stay quiet.
    private let startDelay: TimeInterval = 1.6
    private let maxPreviewLength = 80

    private var activity: Activity<AIThinkingAttributes>?
    private var pendingStart: Task<Void, Never>?
    private var generation = 0
    private var activeKind: AIThinkingAttributes.Kind?

    private init() {}

    // MARK: - Public API

    /// Dismiss Live Activities orphaned by a previous app run. ActivityKit
    /// activities survive process termination, so killing the app mid-
    /// generation leaves the "thinking" banner on the Lock Screen forever.
    /// Safe to call on every foreground: activities this manager still owns
    /// are left untouched.
    func reconcileStaleActivities() {
        for stale in Activity<AIThinkingAttributes>.activities
        where stale.id != activity?.id {
            Task {
                await stale.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    /// Call when Chat / Code / Vision begins waiting on a model response.
    func thinkingDidStart(kind: AIThinkingAttributes.Kind, prompt: String) {
        generation += 1
        let gen = generation
        activeKind = kind
        pendingStart?.cancel()

        let preview = Self.truncate(prompt, max: maxPreviewLength)
        pendingStart = Task { [weak self] in
            guard let self else { return }
            let nanos = UInt64(self.startDelay * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
            guard !Task.isCancelled, gen == self.generation else { return }
            await self.startActivity(kind: kind, preview: preview)
        }
    }

    /// Optional status refresh while still thinking (tools, search, etc.).
    func thinkingDidUpdate(status: String) {
        guard let activity else { return }
        let state = AIThinkingAttributes.ContentState(
            status: status,
            promptPreview: activity.content.state.promptPreview,
            startedAt: activity.content.state.startedAt
        )
        Task {
            await activity.update(
                ActivityContent(state: state, staleDate: nil)
            )
        }
    }

    /// Call when the model finishes, errors, or the user cancels.
    func thinkingDidEnd() {
        generation += 1
        pendingStart?.cancel()
        pendingStart = nil
        activeKind = nil
        endActivity()
    }

    // MARK: - ActivityKit

    private func startActivity(kind: AIThinkingAttributes.Kind, preview: String) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        // Replace any activity already on screen: our own leftover from a
        // previous turn, or an orphan from a previous app run.
        for stale in Activity<AIThinkingAttributes>.activities
        where stale.id != activity?.id {
            Task {
                await stale.end(nil, dismissalPolicy: .immediate)
            }
        }
        if activity != nil {
            endActivity()
        }

        let attributes = AIThinkingAttributes(kind: kind.rawValue, title: kind.title)
        let state = AIThinkingAttributes.ContentState(
            status: defaultStatus(for: kind),
            promptPreview: preview,
            startedAt: Date()
        )

        do {
            activity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: nil),
                pushType: nil
            )
        } catch {
            // Live Activities can be disabled per-app in Settings; fail quietly.
            activity = nil
        }
    }

    private func endActivity() {
        guard let activity else { return }
        let finalState = AIThinkingAttributes.ContentState(
            status: "Done",
            promptPreview: activity.content.state.promptPreview,
            startedAt: activity.content.state.startedAt
        )
        let current = activity
        self.activity = nil
        Task {
            await current.end(
                ActivityContent(state: finalState, staleDate: nil),
                dismissalPolicy: .immediate
            )
        }
    }

    private func defaultStatus(for kind: AIThinkingAttributes.Kind) -> String {
        switch kind {
        case .chat: return "Thinking…"
        case .code: return "Working…"
        case .vision: return "Analyzing…"
        case .study: return "Reading questions…"
        }
    }

    private static func truncate(_ text: String, max: Int) -> String {
        let trimmed = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > max else { return trimmed }
        let idx = trimmed.index(trimmed.startIndex, offsetBy: max)
        return String(trimmed[..<idx]) + "…"
    }
}
