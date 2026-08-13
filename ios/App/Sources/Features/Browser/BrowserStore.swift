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
    /// The Ask-mode conversation about the current page. Grows with follow-up
    /// questions; each turn is grounded in a fresh snapshot of the live page.
    @Published var chatMessages: [BrowserChatMessage] = []
    /// True while the approved plan is actively executing steps.
    @Published var isPlanRunning = false
    /// True while the AI is calling the model for the next-step re-analysis
    /// (i.e. between the last finished step and the next proposed one).
    /// Drives the spinner label so the UI doesn't lie about what it's doing.
    @Published var isDecidingNextStep = false
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
    /// Short user-facing commentary the model chose to include alongside
    /// its most recent next-step decision. Rendered as a soft line in the
    /// running banner so the user understands what the AI is thinking /
    /// about to do, beyond the bare step description. Cleared whenever a
    /// new decision arrives or the run settles.
    @Published var currentCommentary: String?

    @Published var lastGranularity: BrowserApprovalGranularity
    @Published var errorMessage: String?
    /// Set once a run finishes (or the model declares the goal done/blocked)
    /// so the finished banner can show the model's actual last word instead
    /// of a generic "Plan finished".
    @Published var completionSummary: String?
    /// Why the run ended — `.success` (green), `.blocked` (orange — the agent
    /// gave up and named the blocker), or `.stopped` (the per-run step cap or
    /// the user hit Stop). Defaults to `.success` for runs that end before we
    /// had a chance to ask the model (e.g. cancel before any step ran) so the
    /// existing copy still fits.
    @Published var completionOutcome: BrowserAgent.CompletionOutcome = .success

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
    /// Handle to the in-flight plan execution loop, so the user can stop
    /// it mid-flight (long LLM call, runaway waits, etc.). Nil whenever no
    /// plan is running — `stopRun` is then a no-op.
    private var runningPlanTask: Task<Void, Never>?
    /// Handle to the in-flight *initial plan generation* call (the LLM
    /// round-trip between "user tapped send" and "plan card shows up").
    /// `stopRun` cancels this so the user can bail during the prompt
    /// shimmer instead of waiting for a slow model to finish.
    private var planningTask: Task<Void, Never>?
    /// Handle to the in-flight Ask-mode chat call. The Ask branch is just
    /// an LLM round-trip with no inner loop, so it lives in its own task
    /// (the view spawns the Task that drives `submitPrompt`, but the store
    /// owns the cancellation handle so `stopAsk` works from the Stop
    /// button even mid-stream).
    private var askTask: Task<Void, Never>?
    /// Set to true when the run was ended by the user's Stop button (vs
    /// naturally finishing or hitting `maxStepsPerRun`). Read by the
    /// finished banner to show "Stopped by you" instead of a generic done
    /// summary.
    private var wasStoppedByUser = false
    /// Snapshot of the prompt text the user just submitted, so we can keep
    /// `promptText` visible in the input (greyed out + pulsing) while the
    /// agent is thinking instead of clearing it the moment they hit send.
    /// Cleared whenever the run settles (success or failure) so the user
    /// can type a new prompt without manually backspacing.
    var pendingPromptText: String?

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
        guard !isAsking, !isPlanning else { return }
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

        // Keep `promptText` visible (greyed-out with a pulsing light wave)
        // so the user sees what they asked for while the agent works — the
        // text is cleared on completion/failure instead of immediately on
        // submit. `pendingPromptText` snapshots what was sent so we know
        // what to clear after the run lands.
        pendingPromptText = goal
        errorMessage = nil

        guard promptMode == .act else {
            // Ask mode: wrap the whole pipeline (snapshot → optional web
            // search → LLM call → append reply) in a Task we own, so the
            // Stop button can cancel it mid-flight via `stopAsk()`. The
            // Task.isCancelled checks below the awaits are the cooperative
            // cancellation points — without them the LLM call would still
            // run to completion and the user would have to wait it out.
            isAsking = true
            let askHandle = Task { [weak self] in
                guard let self else { return }
                await self.runAskPipeline(
                    goal: goal,
                    model: model,
                    apiKey: apiKey,
                    appState: appState
                )
            }
            askTask = askHandle
            // Wait it out so the caller (the view) sees the same lifecycle
            // shape as the plan path (synchronous "did the run finish"
            // from the view's perspective).
            await askHandle.value
            askTask = nil
            isAsking = false
            return
        }

        completionSummary = nil
        completionOutcome = .success
        cancelAutoDismiss()
        isPlanning = true
        // Wrap the snapshot + initial-plan LLM call in a tracked task so
        // the Stop button can cancel it (this is the prompt-shimmer
        // period — used to be uncancellable, leaving the user staring
        // at a loading field with no way out if the model hung).
        let planHandle = Task { [weak self] in
            guard let self else { return }
            await self.runInitialPlan(
                goal: goal,
                model: model,
                apiKey: apiKey,
                appState: appState
            )
        }
        planningTask = planHandle
        await planHandle.value
        planningTask = nil
        isPlanning = false
    }

    /// Drives the initial plan-generation step (snapshot the page, ask
    /// the model for a plan, set `pendingPlan` for the approval card).
    /// Pulled out of `submitPrompt` so the whole thing runs inside a
    /// `Task` the store owns — that's what lets `stopRun` cancel the
    /// in-flight LLM call when the user taps Stop during the shimmer.
    /// Cancellation is cooperative: each `await` returns control and
    /// the next `Task.isCancelled` check bails out cleanly without
    /// leaving a half-set `pendingPlan` or a stuck error banner.
    private func runInitialPlan(goal: String, model: AIModel, apiKey: String, appState: AppState) async {
        // Wait for the page to settle before planning, same reason as Ask mode.
        if Task.isCancelled { return }
        let context = await captureContextForPage()
        if Task.isCancelled { return }

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
            // Final cancellation check: the model call returned but the
            // user may have hit Stop while we were awaiting. Don't
            // commit a plan they explicitly didn't want.
            if Task.isCancelled { return }
            pendingPlan = plan
            // Keep promptText visible (greyed, pulsing) while the user
            // reviews the plan card. Cleared on approve/deny or once a run
            // finishes — see `denyPendingPlan`, `beginRun`, and the run
            // loop's tail.
        } catch {
            // Cancellation surfaces as CancellationError; treat it like
            // a user stop (no error banner) instead of dumping a
            // confusing provider error.
            if Task.isCancelled { return }
            errorMessage = error.localizedDescription
            clearPendingPrompt()
        }
    }

    func denyPendingPlan() {
        pendingPlan = nil
        clearPendingPrompt()
    }

    /// Clears the prompt text + pending snapshot once the run has settled.
    /// Called from every natural endpoint (plan approved/denied, run finished,
    /// run stopped, Ask answer returned, error). Keeps the input ready for
    /// the next question instead of leaving the user with stale text.
    private func clearPendingPrompt() {
        pendingPromptText = nil
        promptText = ""
    }

    /// Ends the Ask-mode conversation (header X in the browser chat panel).
    func clearChat() {
        chatMessages.removeAll()
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
        // Cancel any prior run before starting a new one so a fresh approval
        // can never collide with a still-in-flight execution loop.
        runningPlanTask?.cancel()
        wasStoppedByUser = false
        pendingPlan = nil
        completionSummary = nil
        completionOutcome = .success
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
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runApprovedSteps(goal: plan.goal, initialQueue: plan.steps, bulk: bulk)
        }
        runningPlanTask = task
    }

    /// Stops whatever the agent is currently doing — Ask-mode chat, the
    /// initial plan-generation LLM call, or the plan execution loop. Safe
    /// to call any time: from the Stop button in the prompt bar, from the
    /// X in the running banner, or programmatically. Cancels the underlying
    /// task so any pending LLM call / settle wait bails out cleanly
    /// instead of the UI lying about progress for several more seconds.
    ///
    /// The three sub-states used to be siloed: `stopRun` only handled
    /// `isPlanRunning` (the post-approval execution loop), Ask mode and
    /// the initial plan-generation shimmer were uncancellable, so the Stop
    /// button was a no-op for the majority of user-visible wait time. All
    /// three now share this entry point and the `wasStoppedByUser` flag
    /// so the finished banner reads "Stopped by you" in every case.
    func stopRun() {
        // Pick the live task. Ask mode and the initial plan-generation
        // LLM call were the two paths that used to be uncancellable;
        // both now run inside their own tracked task so we can cancel
        // them here.
        if let ask = askTask {
            wasStoppedByUser = true
            ask.cancel()
            respondToPendingStep(allow: false)
            scheduleAutoDismiss()
            return
        }
        if let plan = planningTask {
            wasStoppedByUser = true
            plan.cancel()
            respondToPendingStep(allow: false)
            scheduleAutoDismiss()
            return
        }
        if let running = runningPlanTask {
            wasStoppedByUser = true
            running.cancel()
            // Also unblock any pending per-step approval prompt so the
            // cancel propagates immediately instead of waiting for the
            // user to tap.
            respondToPendingStep(allow: false)
            scheduleAutoDismiss()
            return
        }
        // Nothing to stop — just clear any leftover banner state so
        // a stuck "Plan stopped" / "Done" banner doesn't hang around
        // after a manual dismiss.
        cancelAutoDismiss()
        cancelStepDismissals()
        runningPlan = nil
        completionSummary = nil
        completionOutcome = .success
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
        // If a plan is still running, route through stopRun so the in-flight
        // task is cancelled cleanly instead of being orphaned.
        if isPlanRunning {
            stopRun()
            return
        }
        cancelAutoDismiss()
        cancelStepDismissals()
        runningPlan = nil
        completionSummary = nil
        completionOutcome = .success
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
            let delay = self?.stepAutoDismissSeconds ?? 0
            try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
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
            self?.completionOutcome = .success
        }
    }

    private func waitForStepDecision() async -> Bool {
        await withCheckedContinuation { continuation in
            self.stepDecisionContinuation = continuation
        }
    }

    /// Drives an Ask-mode submission end-to-end: append the user turn,
    /// snapshot the page (with the JS-render poll that fixes the "heavy SPA
    /// shows up empty" bug), optionally run a web-search fallback when the
    /// snapshot is thin, call the model, then append the assistant reply.
    ///
    /// Pulled out of `submitPrompt` so the whole pipeline runs inside a
    /// `Task` the store owns (see `askTask`). Cooperative cancellation
    /// points at every `await` keep the Stop button responsive: tapping
    /// it cancels the task, this function bails out at the next check
    /// without committing the assistant message or leaving the user
    /// question stranded in the transcript.
    private func runAskPipeline(goal: String, model: AIModel, apiKey: String, appState: AppState) async {
        let userMessage = BrowserChatMessage(role: .user, content: goal)
        chatMessages.append(userMessage)

        // Poll until the page actually renders text before snapshotting —
        // heavy JS sites (ESPN, etc.) report "loading" done long before
        // their content is painted, which used to hand the model an
        // empty page it then told the user about. `captureContextForPage`
        // already polls in 0.6s ticks up to its budget; the outer
        // Task.isCancelled check lets a Stop request cut it short.
        if Task.isCancelled {
            chatMessages.removeLast()
            clearPendingPrompt()
            return
        }
        let context = await captureContextForPage()
        if Task.isCancelled {
            chatMessages.removeLast()
            clearPendingPrompt()
            return
        }

        // Fall back to a web search when the page snapshot is thin so the
        // model gets curated live content instead of guessing from stale
        // training data — this is what Chat and Vision already do.
        var webSearchBlock: String?
        var webSearchEmpty: String?
        if (context?.textSnippet.count ?? 0) < 200 {
            let query = Self.browserSearchQuery(prompt: goal, context: context)
            let service = WebSearchService()
            do {
                let bundle = try await service.search(
                    userMessage: query,
                    mode: .webSearch,
                    onStep: { _ in }
                )
                if Task.isCancelled {
                    chatMessages.removeLast()
                    clearPendingPrompt()
                    return
                }
                if !bundle.hits.isEmpty {
                    webSearchBlock = bundle.promptBlock
                } else {
                    // Surface "we searched, nothing came back" so the
                    // user knows the "I can't find that" answer wasn't
                    // a confident guess from the model — the web search
                    // fallback also came up empty. The first step's
                    // summary is already formatted for that exact case
                    // ("No web results for X").
                    webSearchEmpty = bundle.steps.first?.summary
                        ?? "No web results for “\(query.prefix(72))”"
                }
            } catch {
                // Search failed — we still have whatever page context was captured.
                if Task.isCancelled {
                    chatMessages.removeLast()
                    clearPendingPrompt()
                    return
                }
            }
        }

        do {
            let reply = try await BrowserAgent.chatAboutPage(
                prompt: goal,
                context: context,
                webSearchBlock: webSearchBlock,
                history: chatHistoryMessages(),
                model: model,
                apiKey: apiKey,
                catalog: appState.catalog,
                customBaseURL: appState.baseURL(for: model.provider),
                style: appState.apiStyle(for: model.provider)
            )
            // Final cancellation check: the model call returned but the
            // user may have hit Stop while we were awaiting. Don't
            // commit a reply they explicitly didn't want.
            if Task.isCancelled {
                chatMessages.removeLast()
                clearPendingPrompt()
                return
            }
            chatMessages.append(
                BrowserChatMessage(
                    role: .assistant,
                    content: reply,
                    searchedWeb: webSearchBlock != nil,
                    webSearchEmpty: webSearchEmpty
                )
            )
            clearPendingPrompt()
        } catch {
            // Don't leave an unanswered question stranded in the transcript.
            // Cancellation surfaces as CancellationError here; treat it
            // like a user stop (silently remove the question, no error
            // banner) instead of dumping a confusing provider error.
            if Task.isCancelled {
                chatMessages.removeLast()
                clearPendingPrompt()
                return
            }
            chatMessages.removeLast()
            errorMessage = error.localizedDescription
            clearPendingPrompt()
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
        // How many step failures we've handed to the re-analysis pipeline
        // in a row. Bounded so a confused loop can't keep retrying forever —
        // the model's system prompt says "adapt, don't repeat", but we don't
        // trust that blindly when it costs the user real LLM round-trips.
        var consecutiveFailures = 0
        /// Maximum times we'll re-plan after a failed step before giving up.
        /// Two retries covers "the page hadn't finished rendering" + "wrong
        /// hint, try another", which is plenty for the vast majority of
        /// cases the user hits.
        let maxConsecutiveFailures = 2

        while !queue.isEmpty {
            if Task.isCancelled {
                if completionSummary == nil || completionSummary?.isEmpty == true {
                    completionSummary = wasStoppedByUser ? "Stopped by you." : "Stopped."
                }
                completionOutcome = .stopped
                break
            }

            // Why we left the inner loop, if we did. Drives whether we fall
            // through to re-analysis (a step failed) or exit entirely (cancel,
            // step cap, too many consecutive failures).
            enum InnerExit { case none, stepFailed, stepCap, cancelled }
            var innerExit: InnerExit = .none

            for step in queue {
                if Task.isCancelled { innerExit = .cancelled; break }
                if completed.count >= maxStepsPerRun {
                    completionSummary = "Stopped after \(maxStepsPerRun) steps to avoid an endless loop — ask again to continue."
                    completionOutcome = .stopped
                    innerExit = .stepCap
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
                    // Don't bail on the *whole run* — fall through to the
                    // re-analysis block so the model gets a fresh page
                    // snapshot plus the failure note and can adapt (different
                    // hint, scroll to find it, navigate elsewhere, or
                    // honestly declare done:outcome=blocked). This is the
                    // change that fixes "click fails → run ends with stale
                    // success banner".
                    innerExit = .stepFailed
                    break
                }
            }

            if Task.isCancelled { innerExit = .cancelled }

            if innerExit == .cancelled || innerExit == .stepCap {
                break
            }
            if innerExit == .stepFailed {
                consecutiveFailures += 1
                if consecutiveFailures > maxConsecutiveFailures {
                    completionSummary = "Stopped after several failed steps — the agent couldn't make progress. Try rephrasing or check the page."
                    completionOutcome = .stopped
                    break
                }
                // Clear any leftover summary so the model's decision below
                // wins the banner instead of inheriting "Plan finished" from
                // a previous successful batch.
                completionSummary = nil
                completionOutcome = .success
            } else {
                // A clean batch (all steps succeeded) resets the counter —
                // a transient failure shouldn't poison later successes.
                consecutiveFailures = 0
            }

            guard let modelContext = resolveModelContext() else {
                completionSummary = "Stopped: no model/API key available to plan the next step."
                completionOutcome = .stopped
                break
            }

            // Wait for the live page to settle after the last step before
            // snapshotting — otherwise we hand the model a mid-paint page and
            // it proposes steps against content that isn't actually there yet.
            if let tab = activeTab {
                isDecidingNextStep = true
                await tab.waitForPageSettled(timeout: 5)
                await tab.installNetworkActivityInstrumentation()
            }
            let context = await activeTab?.captureContext()
            // Lightweight anti-runaway: if the page didn't change at all
            // since the last step and we've already done a few, ask the
            // model to declare done rather than propose another scroll/wait.
            let pageIsUnchanged = isPageUnchangedAfterStep(completed: completed, currentContext: context)
            do {
                isDecidingNextStep = true
                let decision = try await BrowserAgent.requestNextStep(
                    goal: goal,
                    completedSteps: completed,
                    context: context,
                    model: modelContext.model,
                    apiKey: modelContext.apiKey,
                    catalog: modelContext.catalog,
                    customBaseURL: modelContext.customBaseURL,
                    style: modelContext.style,
                    pageUnchangedHint: pageIsUnchanged
                )
                isDecidingNextStep = false
                // Publish whatever commentary the model chose to include,
                // so the running banner can show it alongside the spinner.
                currentCommentary = decision.commentary
                if Task.isCancelled {
                    completionSummary = wasStoppedByUser ? "Stopped by you." : "Stopped."
                    completionOutcome = .stopped
                    queue = []
                    continue
                }
                guard !decision.done, !decision.steps.isEmpty else {
                    completionSummary = decision.summary.isEmpty ? "Done." : decision.summary
                    // The model's own verdict on whether the task was actually
                    // accomplished. Defaulted to .success when the model is too
                    // old to send it — see `parseNextStepDecision`.
                    completionOutcome = decision.outcome
                    queue = []
                    continue
                }
                if bulk {
                    queue = decision.steps
                } else {
                    pendingStepsApproval = decision.steps
                    let approved = await waitForStepDecision()
                    pendingStepsApproval = nil
                    if Task.isCancelled {
                        completionSummary = wasStoppedByUser ? "Stopped by you." : "Stopped."
                        completionOutcome = .stopped
                        queue = []
                        continue
                    }
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
                isDecidingNextStep = false
                // Cancellation surfaces as CancellationError; treat it like
                // a user stop rather than dumping a network/API error in the
                // banner. Everything else is a real failure.
                if Task.isCancelled {
                    completionSummary = wasStoppedByUser ? "Stopped by you." : "Stopped."
                    completionOutcome = .stopped
                } else {
                    errorMessage = error.localizedDescription
                    completionSummary = "Stopped: couldn't work out the next step."
                    completionOutcome = .stopped
                }
                queue = []
            }
        }

        isPlanRunning = false
        isDecidingNextStep = false
        runningPlanTask = nil
        currentCommentary = nil
        // Run has settled (success, error, or stop) — clear the prompt
        // input so the user can type a new question. The greyed/pulsing
        // text gave them something to look at while the agent worked.
        clearPendingPrompt()
        scheduleAutoDismiss()
    }

    /// Cheap signal used to nudge the model toward declaring done: compares
    /// the current page snapshot (URL + title + trimmed text hash) to the
    /// last step's snapshot. If nothing has changed since the most recent
    /// step and we're past the first batch, the page is in a loop — either
    /// stuck at the bottom of an infinite-scroll page or the agent's last
    /// action was a no-op. We pass this hint to the model so it can choose
    /// to stop rather than propose another scroll/wait.
    private func isPageUnchangedAfterStep(completed: [BrowserStep], currentContext: BrowserPageContext?) -> Bool {
        guard let currentContext else { return false }
        // Only kick in after the first batch — give the agent room to actually
        // work the page before complaining that nothing's changing.
        guard completed.count >= 2 else { return false }
        // We don't snapshot after every step (only on the next-step call),
        // so we approximate: if the last step was a `wait` and the page is
        // still loading, flag it. If the last step was a `scroll` and the
        // snapshot's text snippet overlaps heavily with what we'd expect
        // post-scroll, that's also a loop signal. Keep the heuristic simple
        // and let the model decide — we just want to give it a hint.
        let lastStep = completed.last
        let lastWasScroll = lastStep?.kind == .scroll
        let lastWasWait = lastStep?.kind == .wait
        // If the page is still mid-load (text snippet ended with an ellipsis
        // or is suspiciously short after a scroll) we lean on the model.
        let textLooksLikeStillLoading = currentContext.textSnippet.isEmpty
            || currentContext.textSnippet.hasSuffix("…")
            || currentContext.textSnippet.hasSuffix("...")
        return lastWasScroll && textLooksLikeStillLoading
            || lastWasWait && textLooksLikeStillLoading
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
        if Task.isCancelled {
            return (false, "Stopped by you.")
        }
        switch step.kind {
        case .navigate:
            guard let target = step.target, let url = BrowserAddressResolver.resolve(target) else {
                return (false, "Missing or invalid URL.")
            }
            await tab.hidePointer()
            tab.load(url: url)
            // Long budget: a fresh navigation can mean a new SPA bootstrap
            // with lazy chunks, auth redirects, and async data fetches.
            await tab.waitForPageSettled(timeout: 8)
            await tab.installNetworkActivityInstrumentation()
            return (true, "Opened \(url.absoluteString).")
        case .click:
            guard let hint = step.target, !hint.isEmpty else { return (false, "No element description given.") }
            let ok = await tab.click(hint: hint)
            // Clicks frequently trigger XHR-driven UI updates (menus opening,
            // results lists rendering, navigation starting). Give the page a
            // real chance to settle before the next step runs.
            await tab.waitForPageSettled(timeout: 5)
            return (ok, ok ? "Clicked \"\(hint)\"." : "Couldn't find anything matching \"\(hint)\" on the page.")
        case .type:
            guard let hint = step.target, let text = step.value else {
                return (false, "Missing field description or text.")
            }
            let ok = await tab.type(hint: hint, text: text, submit: false)
            // Typing alone rarely starts a network request, but autocomplete
            // dropdowns and validation effects do — a short settle avoids
            // reading mid-animation.
            await tab.waitForPageSettled(timeout: 2, minSettle: 0.15)
            return (ok, ok ? "Typed into \"\(hint)\"." : "Couldn't find a field matching \"\(hint)\".")
        case .scroll:
            await tab.scroll(direction: step.target ?? "down")
            // Scroll alone is cheap, but lazy-loaded sections may fetch new
            // content as soon as they enter the viewport.
            await tab.waitForPageSettled(timeout: 2, minSettle: 0.2)
            return (true, "Scrolled \(step.target ?? "down").")
        case .back:
            await tab.hidePointer()
            tab.goBack()
            await tab.waitForPageSettled(timeout: 5)
            await tab.installNetworkActivityInstrumentation()
            return (true, "Went back.")
        case .forward:
            await tab.hidePointer()
            tab.goForward()
            await tab.waitForPageSettled(timeout: 5)
            await tab.installNetworkActivityInstrumentation()
            return (true, "Went forward.")
        case .reload:
            await tab.hidePointer()
            tab.reload()
            await tab.waitForPageSettled(timeout: 6)
            await tab.installNetworkActivityInstrumentation()
            return (true, "Reloaded the page.")
        case .wait:
            // Model-requested explicit wait. Still let the page settle after
            // the timer so a step that follows (or the next-step re-analysis)
            // doesn't read a mid-paint page. Honors cancellation so the
            // Stop button doesn't have to wait out a 10s sleep.
            let seconds = min(max(Double(step.target ?? "1") ?? 1, 0), 10)
            do {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            } catch {
                return (false, "Stopped by you.")
            }
            await tab.waitForPageSettled(timeout: 2, minSettle: 0.2)
            return (true, "Waited \(Int(seconds))s.")
        case .extract:
            // Extract is the read step — it needs the most up-to-date view, so
            // we deliberately wait here too before snapshotting.
            await tab.waitForPageSettled(timeout: 4)
            let context = await tab.captureContext()
            let summary = context.textSnippet.isEmpty ? "(no visible text)" : String(context.textSnippet.prefix(280))
            return (true, "\(context.title): \(summary)")
        }
    }

    /// Legacy short-form load waiter kept as a thin shim — only used by
    /// `captureContextForPage` for cases where we want "is the top-level load
    /// done?" without the heavier settle dance. New step code should call
    /// `BrowserTab.waitForPageSettled` directly.
    private func waitForLoadSettled(_ tab: BrowserTab, timeout: TimeInterval = 8) async {
        let start = Date()
        while tab.isLoading, Date().timeIntervalSince(start) < timeout {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    /// Snapshot the active page, polling until visible text actually appears.
    /// `WKWebView.isLoading` flips to false when the network load finishes,
    /// well before SPA-heavy sites (ESPN, news, scoreboards) paint their
    /// content — so we re-capture every ~0.6s up to `budget` seconds rather
    /// than handing the model a blank page it then describes as "empty".
    /// We also wait for the page to settle (readyState complete + network
    /// quiet) before the first capture, so the loop never starts reading a
    /// page that's still mid-hydration.
    private func captureContextForPage(budget: TimeInterval = 15) async -> BrowserPageContext? {
        guard let tab = activeTab else { return nil }
        await tab.waitForPageSettled(timeout: 6)
        await tab.installNetworkActivityInstrumentation()
        let start = Date()
        var context = await tab.captureContext()
        while context.textSnippet.isEmpty, Date().timeIntervalSince(start) < budget {
            try? await Task.sleep(nanoseconds: 600_000_000)
            // Re-check settle in case the page kept loading more after the
            // first capture (infinite scroll, late-loading widgets, etc.).
            await tab.waitForPageSettled(timeout: 2, minSettle: 0.15)
            context = await tab.captureContext()
        }
        return context
    }

    /// Prior Ask-mode turns, ready to send back to the model so follow-up
    /// questions keep conversational context. The current turn is excluded
    /// (it is sent separately with a fresh page snapshot).
    private func chatHistoryMessages() -> [ProviderChatMessage] {
        chatMessages.dropLast().map { message in
            let role: ProviderChatMessage.Role = message.role == .assistant ? .assistant : .user
            let content = message.role == .assistant ? message.visibleContent : message.content
            return ProviderChatMessage(role: role, content: content)
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
