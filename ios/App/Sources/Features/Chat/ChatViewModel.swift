import Foundation
import Combine
import UIKit
import AnyProvCore

/// ViewModel for the Chat feature. Drives the messages, the model picker,
/// and the toggles in the Add-to-Chat sheet. Backed by real provider API
/// calls — no fake/demo responses.
@MainActor
final class ChatViewModel: ObservableObject {
    // MARK: - Published Properties

    @Published var messages: [ChatMessage] = []
    @Published var inputText: String = ""
    @Published var isProcessing: Bool = false
    @Published var showAddToChatSheet: Bool = false
    @Published var showConnectorsView: Bool = false
    @Published var showModelPicker: Bool = false
    @Published var error: String?
    /// When set, tapping the error banner runs this (e.g. open provider settings).
    @Published var errorBannerAction: ChatErrorBannerAction?

    enum ChatErrorBannerAction: Equatable {
        /// Open Settings → Provider API keys (add / fix a model).
        case openProviderSettings
    }

    /// Sets the banner message and optional tap destination.
    func presentError(_ message: String, action: ChatErrorBannerAction? = nil) {
        error = message
        errorBannerAction = action
    }

    func clearError() {
        error = nil
        errorBannerAction = nil
    }

    // Per-chat feature toggles (live in the Add-to-Chat sheet).
    @Published var webSearchEnabled: Bool = true
    @Published var researchEnabled: Bool = false
    @Published var healthEnabled: Bool = false
    @Published var connectorDiscoveryEnabled: Bool = true
    @Published var selectedConnectors: Set<String> = []

    @Published var toolAccess: ToolAccess = .auto
    @Published var currentProject: String?
    @Published var attachedFileURLs: [URL] = []
    @Published var showFilePicker: Bool = false

    /// Connectors surfaced by the desktop server. Empty until the server
    /// reports its catalog of available connectors.
    @Published var connectors: [Connector] = []

    /// Apple Health integration for this chat (read-only snapshot → system prompt).
    let healthService = HealthKitService()
    /// True while the system Health authorization sheet is up.
    @Published var isRequestingHealthAccess: Bool = false

    // MARK: - Dependencies

    let catalog: ModelCatalog

    weak var state: AppState?
    /// Sidebar history store — set by ChatView for persist / resume.
    weak var history: ChatHistoryStore?
    /// Active chat id in the history store (global recents or project chat).
    var activeChatID: UUID?
    var activeProjectID: UUID?

    private var cancellables = Set<AnyCancellable>()
    private var persistTask: Task<Void, Never>?

    // MARK: - Tool Access

    enum ToolAccess: String, CaseIterable {
        case auto = "Auto"
        case manual = "Manual"
        case disabled = "Disabled"
    }

    // MARK: - Init

    init(catalog: ModelCatalog = ModelCatalog()) {
        self.catalog = catalog
        // Default connectors — these are *ids* of connectors the user has
        // authorised; the actual data fetching lives in the desktop server.
        self.selectedConnectors = ["gmail", "google-calendar", "google-drive"]
        healthService.refreshAuthorizationState()
        // Bubble nested HealthKitService publishes so the Add-to-Chat sheet
        // refreshes authorization subtitles without a second ObservedObject.
        healthService.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    // MARK: - Health

    /// Turn Health context on/off. Enabling triggers the system HealthKit
    /// permission sheet the first time.
    func setHealthEnabled(_ enabled: Bool) async {
        if !enabled {
            healthEnabled = false
            return
        }
        guard healthService.isHealthDataAvailable else {
            healthEnabled = false
            presentError(HealthKitServiceError.unavailable.errorDescription ?? "Health is unavailable.")
            return
        }
        isRequestingHealthAccess = true
        defer { isRequestingHealthAccess = false }
        do {
            try await healthService.requestAuthorization()
            healthEnabled = true
        } catch {
            healthEnabled = false
            presentError((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    // MARK: - Message Handling

    /// Send a user message and stream the assistant reply from the
    /// currently selected provider/model.
    func sendMessage() async {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard let state,
              let model = state.selectedModel
        else {
            presentError(
                "Select a model in Settings first.",
                action: .openProviderSettings
            )
            return
        }
        // Local Metal is chat-only and needs no API key. Ensure MLX engine is bound.
        if model.provider == .localMetal {
            LocalMetalBootstrap.ensureRegistered()
            guard LocalMetalRuntime.isReady else {
                presentError(
                    "On-device Metal runtime is not ready. Rebuild the app with MLX packages, then download a model in Settings → On-device (Metal).",
                    action: .openProviderSettings
                )
                return
            }
        }
        let key = state.resolvedAPIKey(for: model.provider)
        if model.provider.requiresAPIKey, key.isEmpty {
            presentError(
                "Add an API key for \(model.provider.displayName) in Settings.",
                action: .openProviderSettings
            )
            return
        }

        // Ensure this conversation has a sidebar row before we write.
        if activeChatID == nil {
            activeChatID = history?.ensureActiveChat()
        }

        messages.append(ChatMessage(role: .user, content: text))
        schedulePersist()
        inputText = ""
        isProcessing = true
        defer { isProcessing = false }

        // Build the multi-turn payload from the in-memory conversation.
        var turns: [ProviderChatMessage] = messages.map {
            ProviderChatMessage(role: mapRole($0.role), content: $0.content)
        }

        // Optional Apple Health context — injected as a system turn so
        // Anthropic (system field) and OpenAI-compatible hosts both see it.
        // Snapshot is fresh per send so "how many steps today" stays current.
        if healthEnabled {
            do {
                let snapshot = try await healthService.snapshotForPrompt()
                turns.insert(ProviderChatMessage(role: .system, content: snapshot), at: 0)
            } catch {
                // Don't block the chat; surface a soft warning on the reply path.
                let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                presentError("Health data unavailable: \(msg)")
            }
        }

        do {
            // Re-read selection immediately before the API call so a mid-conversation
            // model/effort switch in the picker is always honored (not a stale capture).
            guard let liveModel = state.selectedModel else {
                presentError("Select a model in Settings first.", action: .openProviderSettings)
                return
            }
            let liveKey = state.resolvedAPIKey(for: liveModel.provider)
            if liveModel.provider.requiresAPIKey, liveKey.isEmpty {
                presentError(
                    "Add an API key for \(liveModel.provider.displayName) in Settings.",
                    action: .openProviderSettings
                )
                return
            }
            // Custom providers must hit their configured base URL + API style —
            // never the built-in OpenAI host just because a model was listed.
            let baseURL = state.baseURL(for: liveModel.provider)
            let style = state.apiStyle(for: liveModel.provider)
            if case .custom = liveModel.provider, baseURL == nil {
                presentError(
                    "Custom provider is missing a base URL. Edit it in Settings.",
                    action: .openProviderSettings
                )
                return
            }
            let reply = try await catalog.provider(
                liveModel.provider,
                customBaseURL: baseURL,
                style: style
            ).chat(
                model: liveModel.modelID,
                apiKey: liveKey,
                messages: turns,
                effort: state.effort
            )
            let parsed = ThinkingExtractor.extract(from: reply)
            messages.append(ChatMessage(
                role: .assistant,
                content: parsed.content,
                thoughtProcess: parsed.thinking
            ))
            schedulePersist()
            // Capture long outputs / code blocks as an Artifact (≥ 10 lines OR contains ```).
            // Prefer visible answer content so artifacts aren't polluted with reasoning.
            state.artifactStore.maybeSave(chatId: activeChatID, content: parsed.content)
        } catch {
            let msg = (error as? ProviderError)?.errorDescription ?? error.localizedDescription
            presentError(msg)
            let name = state.selectedModel?.provider.displayName ?? model.provider.displayName
            messages.append(ChatMessage(
                role: .assistant,
                content: "I couldn't reach \(name): \(msg)"
            ))
            schedulePersist()
        }
    }

    // MARK: - History resume / persist

    func loadChat(id: UUID, from store: ChatHistoryStore) {
        history = store
        activeChatID = id
        activeProjectID = nil
        messages = store.messages(for: id)
        store.openChat(store.recents.first(where: { $0.id == id }) ?? ChatHistoryItem(
            id: id,
            title: "Chat",
            lastMessageAt: Date(),
            messages: []
        ))
    }

    func loadProjectChat(project: ProjectItem, chat: ProjectChatItem, from store: ChatHistoryStore) {
        history = store
        activeChatID = chat.id
        activeProjectID = project.id
        currentProject = project.name
        messages = store.projectChatMessages(projectID: project.id, chatID: chat.id)
    }

    func beginNewChat(in store: ChatHistoryStore) {
        history = store
        let item = store.startNewChat()
        activeChatID = item.id
        activeProjectID = nil
        messages = []
        clearError()
    }

    private func schedulePersist() {
        persistTask?.cancel()
        persistTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            persistNow()
        }
    }

    func persistNow() {
        guard let history else { return }
        if let projectID = activeProjectID, let chatID = activeChatID {
            history.saveProjectChatMessages(messages, projectID: projectID, chatID: chatID)
        } else if let chatID = activeChatID {
            history.saveMessages(messages, for: chatID)
        } else if !messages.isEmpty {
            let id = history.ensureActiveChat()
            activeChatID = id
            history.saveMessages(messages, for: id)
        }
    }

    private func mapRole(_ role: ChatMessage.Role) -> ProviderChatMessage.Role {
        switch role {
        case .system: return .system
        case .user: return .user
        case .assistant: return .assistant
        case .tool: return .assistant
        }
    }

    // MARK: - Message Actions

    /// Copy message content to the system clipboard.
    func copyMessage(_ message: ChatMessage) {
        #if canImport(UIKit)
        UIPasteboard.general.string = message.content
        #endif
    }

    /// Share a message via the system share sheet.
    func shareMessage(_ message: ChatMessage) {
        // The actual UIActivityViewController is presented by the view via
        // `shareItems`. This hook is kept so the message view can call into
        // the view model for state bookkeeping.
    }

    /// Recent share content for `UIActivityViewController`.
    func shareItems(for message: ChatMessage) -> [Any] { [message.content] }

    /// Delete a message from the conversation.
    func deleteMessage(_ message: ChatMessage) {
        messages.removeAll { $0.id == message.id }
        schedulePersist()
    }

    /// Regenerate the last assistant response.
    func regenerateResponse(for message: ChatMessage) async {
        guard message.role == .assistant else { return }
        messages.removeAll { $0.id == message.id }
        guard let lastUser = messages.last(where: { $0.role == .user }) else { return }
        inputText = lastUser.content
        messages.removeAll { $0.id == lastUser.id }
        await sendMessage()
    }

    /// Clear all messages and start fresh.
    func clearChat() {
        messages.removeAll()
        schedulePersist()
    }

    // MARK: - Connectors

    /// Toggle a connector as enabled for this chat.
    func toggleConnector(_ connector: Connector) {
        if selectedConnectors.contains(connector.id) {
            selectedConnectors.remove(connector.id)
        } else {
            selectedConnectors.insert(connector.id)
        }
    }

    /// True when the connector is currently attached to this chat.
    func isConnectorSelected(_ connector: Connector) -> Bool {
        selectedConnectors.contains(connector.id)
    }
}
