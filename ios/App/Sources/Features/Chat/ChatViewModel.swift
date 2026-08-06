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

    private var cancellables = Set<AnyCancellable>()

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
            error = HealthKitServiceError.unavailable.errorDescription
            return
        }
        isRequestingHealthAccess = true
        defer { isRequestingHealthAccess = false }
        do {
            try await healthService.requestAuthorization()
            healthEnabled = true
        } catch {
            healthEnabled = false
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
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
            error = "Select a model in Settings first."
            return
        }
        let key = state.resolvedAPIKey(for: model.provider)
        guard !key.isEmpty else {
            error = "Add an API key for \(model.provider.displayName) in Settings."
            return
        }

        messages.append(ChatMessage(role: .user, content: text))
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
                self.error = "Health data unavailable: \(msg)"
            }
        }

        do {
            // Custom providers must hit their configured base URL + API style —
            // never the built-in OpenAI host just because a model was listed.
            let baseURL = state.baseURL(for: model.provider)
            let style = state.apiStyle(for: model.provider)
            if case .custom = model.provider, baseURL == nil {
                error = "Custom provider is missing a base URL. Edit it in Settings."
                return
            }
            let reply = try await catalog.provider(
                model.provider,
                customBaseURL: baseURL,
                style: style
            ).chat(
                model: model.modelID,
                apiKey: key,
                messages: turns,
                effort: state.effort
            )
            let parsed = ThinkingExtractor.extract(from: reply)
            messages.append(ChatMessage(
                role: .assistant,
                content: parsed.content,
                thoughtProcess: parsed.thinking
            ))
            // Capture long outputs / code blocks as an Artifact (≥ 10 lines OR contains ```).
            // Prefer visible answer content so artifacts aren't polluted with reasoning.
            state.artifactStore.maybeSave(chatId: nil, content: parsed.content)
        } catch {
            let msg = (error as? ProviderError)?.errorDescription ?? error.localizedDescription
            self.error = msg
            messages.append(ChatMessage(
                role: .assistant,
                content: "I couldn't reach \(model.provider.displayName): \(msg)"
            ))
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
