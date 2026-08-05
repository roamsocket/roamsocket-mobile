import Foundation
import Combine
import UIKit
import MobileAICore

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

    // MARK: - Dependencies

    let catalog: ModelCatalog

    weak var state: AppState?

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
        let key = state.apiKey(for: model.provider)
        guard !key.isEmpty else {
            error = "Add an API key for \(model.provider.displayName) in Settings."
            return
        }

        messages.append(ChatMessage(role: .user, content: text))
        inputText = ""
        isProcessing = true
        defer { isProcessing = false }

        // Build the multi-turn payload from the in-memory conversation.
        let turns: [ProviderChatMessage] = messages.map {
            ProviderChatMessage(role: mapRole($0.role), content: $0.content)
        }

        do {
            let reply = try await catalog.provider(model.provider).chat(
                model: model.modelID,
                apiKey: key,
                messages: turns,
                effort: state.effort
            )
            messages.append(ChatMessage(role: .assistant, content: reply))
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
