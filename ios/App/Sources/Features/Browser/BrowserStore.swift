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

    @Published var isPlanning = false
    /// A freshly proposed plan awaiting Approve/Deny — nothing has executed yet.
    @Published var pendingPlan: BrowserPlan?
    /// The plan currently executing (or just finished) so progress/results show.
    @Published var runningPlan: BrowserPlan?
    /// In step-by-step mode, the single step waiting for an explicit decision.
    @Published var pendingStepApproval: BrowserStep?

    @Published var lastGranularity: BrowserApprovalGranularity
    @Published var errorMessage: String?

    @Published var bookmarks: [BrowserBookmark] = []
    @Published var history: [BrowserHistoryEntry] = []
    @Published var showTabsSheet = false
    @Published var showBookmarksSheet = false

    private let bookmarksKey = "browser.bookmarks.v1"
    private let historyKey = "browser.history.v1"
    private let granularityKey = "browser.approvalGranularity.v1"
    private var stepDecisionContinuation: CheckedContinuation<Bool, Never>?

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

    /// Ask the model for a plan grounded in the current page. Always
    /// produces `pendingPlan` (or an error) — never executes anything.
    func submitPrompt(appState: AppState) async {
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
        isPlanning = true
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

    /// Approve every step now; steps still run one at a time and stop at the
    /// first failure, but no further per-step confirmation is required.
    func approvePlanBulk() {
        guard let plan = pendingPlan else { return }
        lastGranularity = .bulk
        saveGranularity()
        var approved = plan
        for idx in approved.steps.indices { approved.steps[idx].status = .approved }
        runningPlan = approved
        pendingPlan = nil
        Task { await runApprovedSteps(bulk: true) }
    }

    /// Approve the plan but pause before every individual step.
    func approvePlanStepByStep() {
        guard let plan = pendingPlan else { return }
        lastGranularity = .stepByStep
        saveGranularity()
        runningPlan = plan
        pendingPlan = nil
        Task { await runApprovedSteps(bulk: false) }
    }

    /// Response to the single step currently shown in `pendingStepApproval`.
    func respondToPendingStep(allow: Bool) {
        pendingStepApproval = nil
        let continuation = stepDecisionContinuation
        stepDecisionContinuation = nil
        continuation?.resume(returning: allow)
    }

    func dismissRunningPlan() {
        runningPlan = nil
    }

    private func waitForStepDecision() async -> Bool {
        await withCheckedContinuation { continuation in
            self.stepDecisionContinuation = continuation
        }
    }

    private func runApprovedSteps(bulk: Bool) async {
        guard var plan = runningPlan else { return }
        stepLoop: for idx in plan.steps.indices {
            if !bulk {
                plan.steps[idx].status = .pending
                runningPlan = plan
                pendingStepApproval = plan.steps[idx]
                let approved = await waitForStepDecision()
                guard approved else {
                    plan.steps[idx].status = .denied
                    runningPlan = plan
                    continue
                }
            }
            plan.steps[idx].status = .running
            runningPlan = plan
            let result = await execute(step: plan.steps[idx])
            plan.steps[idx].status = result.ok ? .done : .failed
            plan.steps[idx].resultNote = result.note
            runningPlan = plan
            if !result.ok { break stepLoop }
        }
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
}
