import SwiftUI

/// Full-featured in-app browser: tabs, bookmarks, history, and an AI prompt
/// bar that always proposes a step-by-step plan before touching the page.
/// Bottom chrome (top to bottom): AI bar → address bar → nav/bookmark/tabs
/// toolbar, so the AI bar sits where a URL bar usually would, above the
/// standard controls.
struct BrowserHomeView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var store: BrowserStore
    var onOpenSidebar: () -> Void = {}

    @FocusState private var promptFocused: Bool
    @FocusState private var addressFocused: Bool
    @State private var showProviderSettings = false

    var body: some View {
        VStack(spacing: 0) {
            topBar
            content
                .frame(maxHeight: .infinity)
        }
        .background(Theme.background)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomChrome
        }
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $store.showTabsSheet) { tabsSheet }
        .sheet(isPresented: $store.showBookmarksSheet) { bookmarksSheet }
        .sheet(isPresented: $store.showModelPicker) {
            ModelPickerSheet()
        }
        .sheet(isPresented: $showProviderSettings) {
            AppSettingsView(initialFocus: .providers)
        }
    }

    // MARK: - Top bar

    /// Which model drives the AI prompt bar — tap to switch, same dropdown
    /// pattern as the Vision header's model pill. Empty string flips the
    /// pill into a "+ Add a model" CTA when nothing usable is configured.
    private var modelPillTitle: String {
        guard let model = state.selectedModel else { return "" }
        return state.displayName(for: model)
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Button(action: onOpenSidebar) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 34, height: 34)
                    .background(Theme.surfaceElevated, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Menu")

            Text(store.activeTab?.title.isEmpty == false ? store.activeTab!.title : "Browser")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            ModelSelectorPill(
                modelDisplayName: modelPillTitle,
                onPick: { store.showModelPicker = true },
                onAddModel: { showProviderSettings = true }
            )
            .accessibilityLabel("Browser AI model")

            if let urlString = store.activeTab?.urlString, let url = URL(string: urlString), !urlString.isEmpty {
                ShareLink(item: url) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .frame(width: 34, height: 34)
                        .background(Theme.surfaceElevated, in: Circle())
                }
            } else {
                Color.clear.frame(width: 34, height: 34)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background(Theme.background)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let tab = store.activeTab, !tab.urlString.isEmpty {
            ZStack(alignment: .top) {
                BrowserWebViewRepresentable(tab: tab)
                if tab.isLoading {
                    ProgressView(value: max(tab.estimatedProgress, 0.05))
                        .tint(Theme.accent)
                        .padding(.horizontal, 0)
                }
            }
        } else {
            emptyState
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "sparkles")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(Theme.accent)
            Text("Browse the web, hands-free")
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("Type an address below, ask the AI a question about a page with Ask, or tell it to do something — it always shows its plan before acting.")
                .font(.system(size: 14))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 44)
            if !store.bookmarks.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(store.bookmarks.prefix(8)) { bookmark in
                            Button(bookmark.title.isEmpty ? bookmark.url : bookmark.title) {
                                store.openBookmark(bookmark)
                            }
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.textPrimary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Theme.surface, in: Capsule())
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .padding(.top, 6)
            }
            Spacer()
            Spacer()
        }
    }

    // MARK: - Bottom chrome

    private var bottomChrome: some View {
        VStack(spacing: 0) {
            if let plan = store.pendingPlan {
                planApprovalCard(plan)
            } else if let steps = store.pendingStepsApproval {
                stepsApprovalCard(steps)
            } else if let running = store.runningPlan {
                if store.isPlanRunning {
                    runningPlanBanner(running)
                } else {
                    finishedPlanBanner(running)
                }
            }
            if !store.chatMessages.isEmpty {
                askChatPanel
            }
            if let error = store.errorMessage {
                errorBanner(error)
            }
            aiPromptBar
            addressBar
            bottomToolbar
        }
        .background(Theme.surfaceElevated)
    }

    // MARK: - AI prompt bar (sits where the URL bar usually would)

    private var aiPromptBar: some View {
        HStack(spacing: 8) {
            promptModeToggle

            Image(systemName: store.promptMode == .ask ? "questionmark.bubble" : "sparkles")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 20)

            TextField(
                store.promptMode == .ask ? "Ask about this page…" : "Ask AI to do something on this page…",
                text: $store.promptText,
                axis: .vertical
            )
            .font(.system(size: 15))
            .foregroundStyle(Theme.textPrimary)
            .lineLimit(1...3)
            .focused($promptFocused)
            .submitLabel(.send)
            .onSubmit(submitPrompt)

            if store.isPlanning || store.isAsking {
                ProgressView()
                    .tint(Theme.textSecondary)
            } else if !store.promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button(action: submitPrompt) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Theme.surface)
        .overlay(Divider().overlay(Theme.separator), alignment: .top)
    }

    /// Compact Ask / Do switch in the prompt bar. "Ask" talks to the model
    /// about the page without ever proposing or running an action.
    private var promptModeToggle: some View {
        HStack(spacing: 2) {
            modeToggleButton(.ask)
            modeToggleButton(.act)
        }
        .padding(2)
        .background(Theme.surfaceElevated, in: Capsule())
        .accessibilityLabel("Prompt mode: \(store.promptMode.title)")
    }

    private func modeToggleButton(_ mode: BrowserPromptMode) -> some View {
        Button {
            store.promptMode = mode
            store.chatMessages.removeAll()
        } label: {
            Text(mode.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(store.promptMode == mode ? Theme.inkOnAccent : Theme.textSecondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(store.promptMode == mode ? Theme.accent : Color.clear, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func submitPrompt() {
        promptFocused = false
        Task { await store.submitPrompt(appState: state) }
    }

    // MARK: - Address bar

    private var addressBar: some View {
        HStack(spacing: 10) {
            Image(systemName: (store.activeTab?.urlString.hasPrefix("https") ?? false) ? "lock.fill" : "globe")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)

            TextField("Search or enter address", text: $store.addressText)
                .font(.system(size: 15))
                .foregroundStyle(Theme.textPrimary)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.webSearch)
                .focused($addressFocused)
                .submitLabel(.go)
                .onSubmit {
                    addressFocused = false
                    store.goToAddress()
                }

            if store.activeTab?.isLoading == true {
                Button(action: { store.activeTab?.stop() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)
            } else {
                Button(action: { store.activeTab?.reload() }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)
            }

            Button(action: toggleBookmark) {
                Image(systemName: store.isCurrentPageBookmarked ? "star.fill" : "star")
                    .font(.system(size: 14))
                    .foregroundStyle(store.isCurrentPageBookmarked ? Theme.accent : Theme.textSecondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Theme.field)
        .overlay(Divider().overlay(Theme.separator), alignment: .top)
    }

    private func toggleBookmark() {
        guard let tab = store.activeTab else { return }
        if let existing = store.bookmarks.first(where: { $0.url == tab.urlString }) {
            store.removeBookmark(existing.id)
        } else {
            store.addBookmarkForCurrentPage()
        }
    }

    // MARK: - Standard bottom toolbar (nav / bookmarks / tabs)

    private var bottomToolbar: some View {
        HStack {
            toolbarButton("chevron.left", enabled: store.activeTab?.canGoBack ?? false) {
                store.activeTab?.goBack()
            }
            Spacer()
            toolbarButton("chevron.right", enabled: store.activeTab?.canGoForward ?? false) {
                store.activeTab?.goForward()
            }
            Spacer()
            toolbarButton("book", enabled: true) {
                store.showBookmarksSheet = true
            }
            Spacer()
            toolbarButton("square.on.square", enabled: true) {
                store.showTabsSheet = true
            }
            .overlay(alignment: .topTrailing) {
                if store.tabs.count > 1 {
                    Text("\(store.tabs.count)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.inkOnAccent)
                        .padding(3)
                        .background(Theme.accent, in: Circle())
                        .offset(x: 8, y: -6)
                }
            }
            Spacer()
            toolbarButton("plus", enabled: true) {
                store.newTab()
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(Theme.surfaceElevated)
        .overlay(Divider().overlay(Theme.separator), alignment: .top)
    }

    private func toolbarButton(_ systemImage: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 19, weight: .regular))
                .foregroundStyle(enabled ? Theme.textPrimary : Theme.textTertiary)
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    // MARK: - Plan / approval UI

    private func planApprovalCard(_ plan: BrowserPlan) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text(plan.goal)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(3)
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(plan.steps.enumerated()), id: \.element.id) { index, step in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(index + 1).")
                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Theme.textTertiary)
                        Image(systemName: step.kind.systemImage)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 14)
                        Text(step.description)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.textSecondary)
                        Spacer(minLength: 0)
                    }
                }
            }

            Text("These steps run in order below. After that, the AI re-checks the live page before proposing anything further — it may ask to run several more mechanical steps at once (like checking a row of boxes), but always shows them first.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)

            HStack(spacing: 10) {
                Button("Deny") { store.denyPendingPlan() }
                    .buttonStyle(.bordered)
                    .tint(Theme.textSecondary)
                Spacer()
                Button("Review each step") { store.approvePlanStepByStep() }
                    .buttonStyle(.bordered)
                    .tint(Theme.accent)
                Button("Run all") { store.approvePlanBulk() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
            }
        }
        .padding(14)
        .background(Theme.surface)
        .overlay(Divider().overlay(Theme.separator), alignment: .top)
    }

    /// Shows one combined approval for whatever the AI just proposed after
    /// re-analyzing the page — usually a single step, but it may bundle
    /// several clearly-independent mechanical actions together (e.g.
    /// checking a row of checkboxes) so the user approves the whole group
    /// with one tap instead of confirming each checkbox individually.
    private func stepsApprovalCard(_ steps: [BrowserStep]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text(steps.count == 1 ? "Allow this step?" : "Allow these \(steps.count) steps?")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                    HStack(alignment: .top, spacing: 8) {
                        if steps.count > 1 {
                            Text("\(index + 1).")
                                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                                .foregroundStyle(Theme.textTertiary)
                        }
                        Image(systemName: step.kind.systemImage)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 16)
                        Text(step.description)
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(2)
                        Spacer(minLength: 0)
                    }
                }
            }

            HStack(spacing: 10) {
                Button("Deny") { store.respondToPendingStep(allow: false) }
                    .buttonStyle(.bordered)
                    .tint(Theme.textSecondary)
                Spacer()
                Button(steps.count == 1 ? "Allow" : "Allow all \(steps.count)") {
                    store.respondToPendingStep(allow: true)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
            }
        }
        .padding(14)
        .background(Theme.surface)
        .overlay(Divider().overlay(Theme.separator), alignment: .top)
    }

    private func runningPlanBanner(_ plan: BrowserPlan) -> some View {
        HStack(spacing: 10) {
            ProgressView()
                .tint(Theme.accent)
            Text(currentStepLabel(plan))
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Theme.surface)
        .overlay(Divider().overlay(Theme.separator), alignment: .top)
    }

    private func currentStepLabel(_ plan: BrowserPlan) -> String {
        if let running = plan.steps.last, running.status == .running {
            return running.description
        }
        return "Thinking about the next step…"
    }

    /// The Ask-mode conversation about the current page. Follow-ups keep the
    /// thread: each new question is grounded in a fresh page snapshot and the
    /// prior turns are sent along as history. Thinking is collapsed behind a
    /// disclosure row (matching Chat) so raw `<think>` markup never leaks.
    private var askChatPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "questionmark.bubble")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text("Ask · About this page")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 0)
                if store.isAsking {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(Theme.textSecondary)
                }
                Button(action: { store.clearChat() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 26, height: 26)
                        .background(Theme.surfaceElevated, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear conversation")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            Divider().overlay(Theme.separator)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(store.chatMessages) { message in
                            askMessageRow(message)
                                .id(message.id)
                        }
                        if store.isAsking {
                            HStack(spacing: 8) {
                                Image(systemName: "questionmark.bubble")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Theme.accent)
                                    .frame(width: 18)
                                AssistantTypingIndicator()
                            }
                            .padding(.top, 2)
                        }
                    }
                    .padding(14)
                }
                .frame(maxHeight: 340)
                .onChange(of: store.chatMessages.count) {
                    if let last = store.chatMessages.last {
                        withAnimation(.easeOut(duration: 0.3)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
                .onChange(of: store.isAsking) {
                    if store.isAsking {
                        withAnimation(.easeOut(duration: 0.3)) {
                            proxy.scrollTo(store.chatMessages.last?.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .background(Theme.surface)
        .overlay(Divider().overlay(Theme.separator), alignment: .top)
    }

    private func askMessageRow(_ message: BrowserChatMessage) -> some View {
        Group {
            if message.role == .user {
                HStack {
                    Spacer(minLength: 48)
                    Text(message.content)
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .textSelection(.enabled)
                }
            } else {
                let parsed = ThinkingExtractor.extract(from: message.content)
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "questionmark.bubble")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 18)
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 8) {
                        if message.searchedWeb {
                            HStack(spacing: 4) {
                                Image(systemName: "magnifyingglass.circle")
                                    .font(.system(size: 10, weight: .medium))
                                Text("Searched the web for more context")
                                    .font(.system(size: 10, weight: .medium))
                            }
                            .foregroundStyle(Theme.textTertiary)
                        }
                        if let thinking = parsed.thinking {
                            ThinkingBlock(text: thinking, expanded: state.alwaysExpandThinking)
                        }
                        if !parsed.content.isEmpty {
                            MarkdownContentView(text: parsed.content, fontSize: 15)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// Shown once a run finishes, fails, or gets denied. Individual steps
    /// dismiss themselves after ~5s (see `BrowserStore.scheduleStepDismiss`);
    /// the remaining banner auto-dismisses after ~10s but can also be closed
    /// immediately.
    private func finishedPlanBanner(_ plan: BrowserPlan) -> some View {
        let failed = plan.steps.contains { $0.status == .failed }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: failed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(failed ? Color.orange : Color.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(failed ? "Plan stopped early" : "Plan finished")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    if let summary = store.completionSummary, !summary.isEmpty {
                        Text(summary)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(3)
                    }
                }
                Spacer(minLength: 0)
                Button(action: { store.dismissRunningPlan() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 26, height: 26)
                        .background(Theme.surfaceElevated, in: Circle())
                }
                .buttonStyle(.plain)
            }
            VStack(alignment: .leading, spacing: 5) {
                ForEach(plan.steps) { step in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: statusIcon(step.status))
                            .font(.system(size: 11))
                            .foregroundStyle(statusColor(step.status))
                            .frame(width: 14)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(step.description)
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textSecondary)
                            if let note = step.resultNote {
                                Text(note)
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.textTertiary)
                                    .lineLimit(2)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .padding(14)
        .background(Theme.surface)
        .overlay(Divider().overlay(Theme.separator), alignment: .top)
    }

    private func statusIcon(_ status: BrowserStep.Status) -> String {
        switch status {
        case .done: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .denied: return "minus.circle"
        default: return "circle"
        }
    }

    private func statusColor(_ status: BrowserStep.Status) -> Color {
        switch status {
        case .done: return .green
        case .failed: return .red
        default: return Theme.textTertiary
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.orange)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(2)
            Spacer(minLength: 0)
            Button(action: { store.errorMessage = nil }) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Theme.surface)
        .overlay(Divider().overlay(Theme.separator), alignment: .top)
    }

    // MARK: - Sheets

    private var tabsSheet: some View {
        SheetScaffold(
            title: "Tabs",
            trailing: AnyView(
                Button(action: {
                    store.newTab()
                    store.showTabsSheet = false
                }) {
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .frame(width: 40, height: 40)
                        .background(Theme.surfaceElevated, in: Circle())
                }
                .buttonStyle(.plain)
            ),
            onClose: { store.showTabsSheet = false }
        ) {
            List {
                ForEach(store.tabs) { tab in
                    Button {
                        store.selectTab(tab.id)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tab.title.isEmpty ? "New Tab" : tab.title)
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(Theme.textPrimary)
                                    .lineLimit(1)
                                if !tab.urlString.isEmpty {
                                    Text(tab.urlString)
                                        .font(.system(size: 12))
                                        .foregroundStyle(Theme.textTertiary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                            if tab.id == store.activeTabID {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Theme.accent)
                            }
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) { store.closeTab(tab.id) } label: {
                            Label("Close", systemImage: "xmark")
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Theme.background)
        .presentationDragIndicator(.visible)
    }

    private var bookmarksSheet: some View {
        SheetScaffold(title: "Bookmarks", trailing: nil, onClose: { store.showBookmarksSheet = false }) {
            List {
                Section("Bookmarks") {
                    if store.bookmarks.isEmpty {
                        Text("No bookmarks yet")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    ForEach(store.bookmarks) { bookmark in
                        Button {
                            store.openBookmark(bookmark)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(bookmark.title.isEmpty ? bookmark.url : bookmark.title)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(Theme.textPrimary)
                                    .lineLimit(1)
                                Text(bookmark.url)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.textTertiary)
                                    .lineLimit(1)
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) { store.removeBookmark(bookmark.id) } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
                Section("Recent") {
                    ForEach(store.history.prefix(30)) { entry in
                        Button {
                            openFromHistory(entry)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.title.isEmpty ? entry.url : entry.title)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(Theme.textPrimary)
                                    .lineLimit(1)
                                Text(entry.url)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.textTertiary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    if !store.history.isEmpty {
                        Button("Clear history", role: .destructive) { store.clearHistory() }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Theme.background)
        .presentationDragIndicator(.visible)
    }

    private func openFromHistory(_ entry: BrowserHistoryEntry) {
        guard let url = URL(string: entry.url) else { return }
        if store.activeTab == nil { store.newTab() }
        store.activeTab?.load(url: url)
        store.showBookmarksSheet = false
    }
}
