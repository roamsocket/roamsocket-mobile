import Foundation
import SwiftUI
import AnyProvCore

/// Owns every tab, the address/AI prompt state, bookmarks, history, and the
/// plan/approve execution loop for the in-app browser. Lives on `AppState`
/// (like `codeSessionStore`) so tabs and history survive leaving/returning
/// to the Browser sidebar destination.
@MainActor
final class BrowserStore: ObservableObject {
    @Published var tabs: [BrowserTab] = []
    @Published var activeTabID: BrowserTab.ID?

    @Published var addressText: String = ""
    @Published var promptText: String = ""
    /// Whether the prompt bar plans actions ("Do") or just talks about the
    /// page ("Ask"). Ask mode never touches the page.
    @Published var promptMode: BrowserPromptMode = .act

    @Published var isPlanning = false
    /// Model is answering a question in Ask mode (page untouched).
    @Published var isAsking = false
    /// The model's plain-prose answer to an Ask-mode question.
    @Published var chatReply: String?
    /// True when a web search was used to supplement a thin page snapshot in
    /// Ask mode — drives a small "Searched the web" indicator on the reply.
    @Published var chatSearchedWeb = false
    /// True while the approved plan is actively executing steps.
    @Published var isPlanRunning = false
    /// A freshly proposed plan awaiting Approve/Deny — nothing has executed yet.
    @Published var pendingPlan: BrowserPlan?
    /// The plan currently executing (or just finished). Starts empty and
    /// grows one real step at a time as `runApprovedSteps` re-analyzes the
    /// live page after every action — it is not a static copy of the
    /// original preview shown in `pendingPlan`.
    @Published var runningPlan: BrowserPlan?
    /// In step-by-step mode, the step(s) waiting for one explicit decision.
    /// The model may batch several mechanical actions together (e.g.
    /// checking a row of checkboxes) into a single approval instead of
    /// asking again after every individual one — this can hold 1 or more.
    @Published var pendingStepsApproval: [BrowserStep]?

    @Published var lastGranularity: BrowserApprovalGranularity
    @Published var errorMessage: String?
    /// Set once a run finishes (or the model declares the goal done/blocked)
    /// so the finished banner can show the model's actual last word instead
    /// of a generic "Plan finished".
    @Published var completionSummary: String?

    @Published var bookmarks: [BrowserBookmark] = []
    @Published var history: [BrowserHistoryEntry] = []
    @Published var showTabsSheet = false
    @Published var showBookmarksSheet = false
    /// Drives the model-picker sheet opened from the header dropdown.
    @Published var showModelPicker = false

    /// Weak back-reference captured the first time a prompt is submitted,
    /// so the execution loop can re-query the model (for real-time
    /// re-analysis between steps) without AppState needing to own us.
    private weak var appState: AppState?

    private let bookmarksKey = "browser.bookmarks.v1"
    private let historyKey = "browser.history.v1"
    private let granularityKey = "browser.approvalGranularity.v1"
    private var stepDecisionContinuation: CheckedContinuation<Bool, Never>?
    /// Safety valve: stop re-planning after this many actions even if the
    /// model keeps saying "done": false, so a confused loop can't run away.
    private let maxStepsPerRun = 12
    /// How long a finished step stays visible in the plan list before it
    /// dismisses itself individually (so the list shows recent activity
    /// instead of stacking every action forever).
    private let stepAutoDismissSeconds: UInt64 = 5
    /// How long the finished/stopped banner stays up before it auto-dismisses.
    private let finishedBannerAutoDismissSeconds: UInt64 = 10
    private var autoDismissTask: Task<Void, Never>?
    /// Per-step dismissal tasks keyed by step id, so a new run (or manual
    /// dismissal) can cancel the old ones. Each task also guards on the plan
    /// id it was scheduled for, so a stale task can never eat steps from a
    /// later run.
    private var stepDismissTasks: [UUID: Task<Void, Never>] = [:]

    init() {
        let raw = UserDefaults.standard.string(forKey: granularityKey)
        lastGranularity = raw.flatMap(BrowserApprovalGranularity.init(rawValue:)) ?? .bulk
        loadBookmarks()
        loadHistory()
        newTab()
    }

    var activeTab: BrowserTab? { tabs.first(where: { $0.id == activeTabID }) }

    // MARK: - Tabs

    func newTab(url: URL? = nil) {
        let tab = BrowserTab()
        tab.onFinishedNavigation = { [weak self] tab in self?.handleFinishedLoad(tab) }
        tabs.append(tab)
        activeTabID = tab.id
        addressText = ""
        if let url {
            tab.load(url: url)
        }
    }

    func closeTab(_ id: BrowserTab.ID) {
        tabs.removeAll { $0.id == id }
        if activeTabID == id {
            activeTabID = tabs.last?.id
            addressText = activeTab?.urlString ?? ""
        }
        if tabs.isEmpty { newTab() }
    }

    func selectTab(_ id: BrowserTab.ID) {
        activeTabID = id
        addressText = activeTab?.urlString ?? ""
        showTabsSheet = false
    }

    private func handleFinishedLoad(_ tab: BrowserTab) {
        if tab.id == activeTabID { addressText = tab.urlString }
        guard !tab.urlString.isEmpty, tab.urlString.hasPrefix("http") else { return }
        recordHistory(title: tab.title, url: tab.urlString)
    }

    // MARK: - Address bar

    func goToAddress() {
        guard let url = BrowserAddressResolver.resolve(addressText) else {
            errorMessage = "Enter a valid address or search."
            return
        }
        if activeTab == nil { newTab() }
        activeTab?.load(url: url)
    }

    // MARK: - Bookmarks

    func addBookmarkForCurrentPage() {
        guard let tab = activeTab, !tab.urlString.isEmpty else { return }
        guard !bookmarks.contains(where: { $0.url == tab.urlString }) else { return }
        bookmarks.insert(BrowserBookmark(title: tab.title, url: tab.urlString), at: 0)
        saveBookmarks()
    }

    func removeBookmark(_ id: UUID) {
        bookmarks.removeAll { $0.id == id }
        saveBookmarks()
    }

    func openBookmark(_ bookmark: BrowserBookmark) {
        guard let url = URL(string: bookmark.url) else { return }
        if activeTab == nil { newTab() }
        activeTab?.load(url: url)
        showBookmarksSheet = false
    }

    var isCurrentPageBookmarked: Bool {
        guard let tab = activeTab else { return false }
        return bookmarks.contains { $0.url == tab.urlString }
    }

    // MARK: - History

    private func recordHistory(title: String, url: String) {
        history.insert(BrowserHistoryEntry(title: title.isEmpty ? url : title, url: url), at: 0)
        if history.count > 200 { history.removeLast(history.count - 200) }
        saveHistory()
    }

    func clearHistory() {
        history.removeAll()
        saveHistory()
    }

    // MARK: - AI planning

    /// Route the prompt bar text: in Ask mode the model just answers
    /// questions about the current page (nothing executes); in Do mode it
    /// produces `pendingPlan` for approval (also nothing executes).
    func submitPrompt(appState: AppState) async {
        self.appState = appState
        let goal = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !goal.isEmpty else { return }
        guard let model = appState.selectedModel else {
            errorMessage = "Pick a model first (composer model picker in Chat, or Settings)."
            return
        }
        let apiKey = appState.resolvedAPIKey(for: model.provider)
        if model.provider.requiresAPIKey, apiKey.isEmpty {
            errorMessage = "Add an API key for \(model.provider.displayName) first."
            return
        }

        promptText = ""
        errorMessage = nil
        chatSearchedWeb = false

        guard promptMode == .act else {
            chatReply = nil
            isAsking = true
            defer { isAsking = false }

            // Wait for the page to finish loading before capturing content —
            // heavy JS sites (ESPN, etc.) are often still rendering when the
            // snapshot would otherwise be taken, yielding an empty context.
            if let tab = activeTab {
                await waitForLoadSettled(tab)
            }
            var context = await activeTab?.captureContext()

            // Retry once after a short delay if the page yielded no text
            // (common on JS-heavy sites where content renders asynchronously).
            if (context?.textSnippet.isEmpty ?? true), let tab = activeTab {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                await waitForLoadSettled(tab, timeout: 4)
                context = await tab.captureContext()
            }

            // Fall back to a web search when the page snapshot is thin so the
            // model gets curated live content instead of guessing from stale
            // training data — this is what Chat and Vision already do.
            var webSearchBlock: String?
            if (context?.textSnippet.count ?? 0) < 200 {
                let query = Self.browserSearchQuery(prompt: goal, context: context)
                let service = WebSearchService()
                do {
                    let bundle = try await service.search(
                        userMessage: query,
                        mode: .webSearch,
                        onStep: { _ in }
                    )
                    if !bundle.hits.isEmpty {
                        webSearchBlock = bundle.promptBlock
                        chatSearchedWeb = true
                    }
                } catch {
                    // Search failed — we still have whatever page context was captured.
                }
            }

            do {
                chatReply = try await BrowserAgent.chatAboutPage(
                    prompt: goal,
                    context: context,
                    webSearchBlock: webSearchBlock,
                    model: model,
                    apiKey: apiKey,
                    catalog: appState.catalog,
                    customBaseURL: appState.baseURL(for: model.provider),
                    style: appState.apiStyle(for: model.provider)
                )
            } catch {
                errorMessage = error.localizedDescription
            }
            return
        }

        completionSummary = nil
        cancelAutoDismiss()
        isPlanning = true
        // Wait for the page to settle before planning, same reason as Ask mode.
        if let tab = activeTab {
            await waitForLoadSettled(tab)
        }
        let context = await activeTab?.captureContext()
        defer { isPlanning = false }

        do {
            let plan = try await BrowserAgent.requestPlan(
                goal: goal,
                context: context,
                model: model,
                apiKey: apiKey,
                catalog: appState.catalog,
                customBaseURL: appState.baseURL(for: model.provider),
                style: appState.apiStyle(for: model.provider)
            )
            pendingPlan = plan
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func denyPendingPlan() {
        pendingPlan = nil
    }

    /// Approve and run every step in the plan now (they run in order and
    /// stop at the first failure). Once that batch finishes, everything
    /// after it is decided in real time (see `runApprovedSteps`) by
    /// re-analyzing the live page rather than trusting further guesses,
    /// and no further confirmation is required for those either.
    func approvePlanBulk() {
        guard let plan = pendingPlan else { return }
        lastGranularity = .bulk
        saveGranularity()
        beginRun(plan, bulk: true)
    }

    /// Approve and run every step in the plan now, but pause for a fresh
    /// combined approval before anything the AI proposes afterward —
    /// which may itself be more than one step at once.
    func approvePlanStepByStep() {
        guard let plan = pendingPlan else { return }
        lastGranularity = .stepByStep
        saveGranularity()
        beginRun(plan, bulk: false)
    }

    private func beginRun(_ plan: BrowserPlan, bulk: Bool) {
        pendingPlan = nil
        completionSummary = nil
        cancelAutoDismiss()
        cancelStepDismissals()
        isPlanRunning = true
        // Start the live/executed list empty — the preview steps above were
        // only ever a forecast for the approval card. What actually runs is
        // decided one action at a time (see `runApprovedSteps`), so this
        // list is rebuilt from real executed steps as they happen.
        runningPlan = BrowserPlan(id: plan.id, goal: plan.goal, steps: [])
        // The steps above were already approved as a batch (this is exactly
        // the same "approve several things at once" flow used for anything
        // proposed later) — they run immediately; only what comes *after*
        // this batch gets freshly re-derived from the live page.
        Task { await runApprovedSteps(goal: plan.goal, initialQueue: plan.steps, bulk: bulk) }
    }

    /// Response to the step(s) currently shown in `pendingStepsApproval`.
    /// One decision approves or denies the whole batch together.
    func respondToPendingStep(allow: Bool) {
        pendingStepsApproval = nil
        let continuation = stepDecisionContinuation
        stepDecisionContinuation = nil
        continuation?.resume(returning: allow)
    }

    func dismissRunningPlan() {
        cancelAutoDismiss()
        cancelStepDismissals()
        runningPlan = nil
        completionSummary = nil
        isPlanRunning = false
    }

    private func cancelAutoDismiss() {
        autoDismissTask?.cancel()
        autoDismissTask = nil
    }

    private func cancelStepDismissals() {
        stepDismissTasks.values.forEach { $0.cancel() }
        stepDismissTasks.removeAll()
    }

    /// Removes a single finished step from the visible plan list after
    /// `stepAutoDismissSeconds`, so completed actions fade out one by one
    /// instead of the list growing taller forever. Guards on the plan id it
    /// was scheduled under so a stale task can't remove steps from a later run.
    private func scheduleStepDismiss(stepID: UUID) {
        guard let planID = runningPlan?.id else { return }
        stepDismissTasks[stepID]?.cancel()
        let task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: stepAutoDismissSeconds * 1_000_000_000)
            guard !Task.isCancelled else { return }
            guard let self, var plan = self.runningPlan, plan.id == planID else { return }
            plan.steps.removeAll { $0.id == stepID }
            self.runningPlan = plan
            self.stepDismissTasks[stepID] = nil
        }
        stepDismissTasks[stepID] = task
    }

    /// Keeps the finished/stopped banner up long enough to actually read,
    /// then clears it automatically.
    private func scheduleAutoDismiss() {
        cancelAutoDismiss()
        autoDismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: (self?.finishedBannerAutoDismissSeconds ?? 10) * 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.runningPlan = nil
            self?.completionSummary = nil
        }
    }

    private func waitForStepDecision() async -> Bool {
        await withCheckedContinuation { continuation in
            self.stepDecisionContinuation = continuation
        }
    }

    /// Runs steps in batches, re-analyzing the actual page after each batch
    /// finishes to decide what happens next. `initialQueue` (the approved
    /// plan) always runs immediately since the user already approved it as
    /// a group; every batch after that is freshly proposed by the model —
    /// usually one step, but it may bundle several clearly-independent
    /// mechanical actions (e.g. checking a row of checkboxes) into a single
    /// combined approval instead of asking again after every individual one.
    /// Either way, the model always sees each batch's real outcome before
    /// proposing the next, so it can adapt instead of marching through a
    /// script that's gone stale the moment the page changed.
    private func runApprovedSteps(goal: String, initialQueue: [BrowserStep], bulk: Bool) async {
        var queue = initialQueue
        var completed: [BrowserStep] = []

        while !queue.isEmpty {
            var stoppedEarly = false

            for step in queue {
                if completed.count >= maxStepsPerRun {
                    completionSummary = "Stopped after \(maxStepsPerRun) steps to avoid an endless loop — ask again to continue."
                    stoppedEarly = true
                    break
                }
                var currentStep = step
                currentStep.status = .running
                appendStep(currentStep)
                let result = await execute(step: currentStep)
                currentStep.status = result.ok ? .done : .failed
                currentStep.resultNote = result.note
                updateLastStep(currentStep)
                scheduleStepDismiss(stepID: currentStep.id)
                completed.append(currentStep)
                if !result.ok {
                    stoppedEarly = true
                    break
                }
            }

            if stoppedEarly { break }

            guard let modelContext = resolveModelContext() else {
                completionSummary = "Stopped: no model/API key available to plan the next step."
                break
            }

            let context = await activeTab?.captureContext()
            do {
                let decision = try await BrowserAgent.requestNextStep(
                    goal: goal,
                    completedSteps: completed,
                    context: context,
                    model: modelContext.model,
                    apiKey: modelContext.apiKey,
                    catalog: modelContext.catalog,
                    customBaseURL: modelContext.customBaseURL,
                    style: modelContext.style
                )
                guard !decision.done, !decision.steps.isEmpty else {
                    completionSummary = decision.summary.isEmpty ? "Done." : decision.summary
                    queue = []
                    continue
                }
                if bulk {
                    queue = decision.steps
                } else {
                    pendingStepsApproval = decision.steps
                    let approved = await waitForStepDecision()
                    pendingStepsApproval = nil
                    if approved {
                        queue = decision.steps
                    } else {
                        for deniedStep in decision.steps {
                            var denied = deniedStep
                            denied.status = .denied
                            appendStep(denied)
                            scheduleStepDismiss(stepID: denied.id)
                        }
                        queue = []
                    }
                }
            } catch {
                errorMessage = error.localizedDescription
                completionSummary = "Stopped: couldn't work out the next step."
                queue = []
            }
        }

        isPlanRunning = false
        scheduleAutoDismiss()
    }

    /// Appends `step` as a new entry at the end of the live `runningPlan`.
    private func appendStep(_ step: BrowserStep) {
        guard var plan = runningPlan else { return }
        plan.steps.append(step)
        runningPlan = plan
    }

    /// Replaces the last entry in the live `runningPlan` (used right after
    /// `appendStep` to reflect that same step's final status/result).
    private func updateLastStep(_ step: BrowserStep) {
        guard var plan = runningPlan, !plan.steps.isEmpty else { return }
        plan.steps[plan.steps.count - 1] = step
        runningPlan = plan
    }

    private struct ResolvedModelContext {
        let model: AIModel
        let apiKey: String
        let catalog: ModelCatalog
        let customBaseURL: URL?
        let style: CustomProviderStyle?
    }

    private func resolveModelContext() -> ResolvedModelContext? {
        guard let appState, let model = appState.selectedModel else { return nil }
        let apiKey = appState.resolvedAPIKey(for: model.provider)
        if model.provider.requiresAPIKey, apiKey.isEmpty { return nil }
        return ResolvedModelContext(
            model: model,
            apiKey: apiKey,
            catalog: appState.catalog,
            customBaseURL: appState.baseURL(for: model.provider),
            style: appState.apiStyle(for: model.provider)
        )
    }

    private func execute(step: BrowserStep) async -> (ok: Bool, note: String?) {
        guard let tab = activeTab else { return (false, "No active tab.") }
        switch step.kind {
        case .navigate:
            guard let target = step.target, let url = BrowserAddressResolver.resolve(target) else {
                return (false, "Missing or invalid URL.")
            }
            tab.load(url: url)
            await waitForLoadSettled(tab)
            return (true, "Opened \(url.absoluteString).")
        case .click:
            guard let hint = step.target, !hint.isEmpty else { return (false, "No element description given.") }
            let ok = await tab.click(hint: hint)
            await waitForLoadSettled(tab, timeout: 4)
            return (ok, ok ? "Clicked \"\(hint)\"." : "Couldn't find anything matching \"\(hint)\" on the page.")
        case .type:
            guard let hint = step.target, let text = step.value else {
                return (false, "Missing field description or text.")
            }
            let ok = await tab.type(hint: hint, text: text, submit: false)
            return (ok, ok ? "Typed into \"\(hint)\"." : "Couldn't find a field matching \"\(hint)\".")
        case .scroll:
            await tab.scroll(direction: step.target ?? "down")
            return (true, "Scrolled \(step.target ?? "down").")
        case .back:
            tab.goBack()
            await waitForLoadSettled(tab, timeout: 4)
            return (true, "Went back.")
        case .forward:
            tab.goForward()
            await waitForLoadSettled(tab, timeout: 4)
            return (true, "Went forward.")
        case .reload:
            tab.reload()
            await waitForLoadSettled(tab)
            return (true, "Reloaded the page.")
        case .wait:
            let seconds = min(max(Double(step.target ?? "1") ?? 1, 0), 10)
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return (true, "Waited \(Int(seconds))s.")
        case .extract:
            let context = await tab.captureContext()
            let summary = context.textSnippet.isEmpty ? "(no visible text)" : String(context.textSnippet.prefix(280))
            return (true, "\(context.title): \(summary)")
        }
    }

    private func waitForLoadSettled(_ tab: BrowserTab, timeout: TimeInterval = 8) async {
        let start = Date()
        while tab.isLoading, Date().timeIntervalSince(start) < timeout {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    // MARK: - Persistence

    private func loadBookmarks() {
        guard let data = UserDefaults.standard.data(forKey: bookmarksKey),
              let decoded = try? JSONDecoder().decode([BrowserBookmark].self, from: data)
        else { return }
        bookmarks = decoded
    }

    private func saveBookmarks() {
        guard let data = try? JSONEncoder().encode(bookmarks) else { return }
        UserDefaults.standard.set(data, forKey: bookmarksKey)
    }

    private func loadHistory() {
        guard let data = UserDefaults.standard.data(forKey: historyKey),
              let decoded = try? JSONDecoder().decode([BrowserHistoryEntry].self, from: data)
        else { return }
        history = decoded
    }

    private func saveHistory() {
        guard let data = try? JSONEncoder().encode(history) else { return }
        UserDefaults.standard.set(data, forKey: historyKey)
    }

    private func saveGranularity() {
        UserDefaults.standard.set(lastGranularity.rawValue, forKey: granularityKey)
    }

    /// Constructs a web search query from the page title/host + user's question
    /// so the fallback search is grounded in the current browsing context.
    private static func browserSearchQuery(prompt: String, context: BrowserPageContext?) -> String {
        var parts: [String] = []
        if let context, !context.title.isEmpty, !context.title.lowercased().contains("new tab") {
            let title = context.title
                .replacingOccurrences(of: #"\s*[\|\-–—].*$"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty {
                parts.append(title)
            }
        }
        parts.append(prompt)
        return parts.joined(separator: " ")
    }
}
