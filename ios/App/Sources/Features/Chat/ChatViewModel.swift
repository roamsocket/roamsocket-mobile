import Foundation
import Combine
import MobileAICore

/// ViewModel for the Chat feature, handling messages, MCP tools, skills, and connectors
@MainActor
final class ChatViewModel: ObservableObject {
    // MARK: - Published Properties
    
    @Published var messages: [ChatMessage] = []
    @Published var inputText: String = ""
    @Published var isProcessing: Bool = false
    @Published var selectedConnectors: Set<String> = []
    @Published var selectedSkills: Set<String> = []
    @Published var showThoughtProcess: Bool = false
    @Published var currentThoughtProcess: String?
    @Published var showAddToChatSheet: Bool = false
    @Published var showConnectorsView: Bool = false
    @Published var connectorDiscoveryEnabled: Bool = true
    @Published var webSearchEnabled: Bool = true
    @Published var researchEnabled: Bool = false
    @Published var healthEnabled: Bool = false
    @Published var toolAccess: ToolAccess = .auto
    @Published var currentProject: String?
    @Published var error: String?
    
    // MARK: - Dependencies
    
    let mcpClient: MCPClient
    let connectors: [Connector]
    let skills: [Skill]
    
    // MARK: - Tool Access
    
    enum ToolAccess: String, CaseIterable {
        case auto = "Auto"
        case manual = "Manual"
        case disabled = "Disabled"
    }
    
    // MARK: - Init
    
    init(mcpClient: MCPClient = MCPClient()) {
        self.mcpClient = mcpClient
        self.connectors = Connector.sampleConnectors
        self.skills = Skill.sampleSkills
        
        // Initialize with some default connectors
        selectedConnectors = ["gmail", "google-calendar", "google-drive"]
        selectedSkills = ["web-search"]
        
        // Add welcome message
        messages.append(ChatMessage(
            role: .assistant,
            content: "I'm listening. How can I help you today?"
        ))
    }
    
    // MARK: - Message Handling
    
    /// Send a user message
    func sendMessage() async {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        
        // Add user message
        let userMessage = ChatMessage(role: .user, content: text)
        messages.append(userMessage)
        inputText = ""
        
        // Start processing
        isProcessing = true
        
        // Simulate AI response with thought process
        await processMessage(userMessage)
        
        isProcessing = false
    }
    
    /// Process a message and generate a response
    private func processMessage(_ message: ChatMessage) async {
        // Simulate thinking
        currentThoughtProcess = "Processing the user's message. I should analyze the context and determine the best response. Let me check available tools and connectors to provide the most helpful answer."
        showThoughtProcess = true
        
        try? await Task.sleep(nanoseconds: 1_500_000_000) // 1.5s delay
        
        // Hide thought process
        showThoughtProcess = false
        currentThoughtProcess = nil
        
        // Generate response based on message content
        let response = generateResponse(for: message.content)
        
        // Add assistant message
        let assistantMessage = ChatMessage(
            role: .assistant,
            content: response,
            thoughtProcess: "Analyzed the user's request and determined the best approach. Used available context from connectors to provide a relevant response."
        )
        messages.append(assistantMessage)
    }
    
    /// Generate a response based on the user's message
    private func generateResponse(for message: String) -> String {
        let lowercased = message.lowercased()
        
        if lowercased.contains("don't game") || lowercased.contains("no gaming") {
            return "Fixed — here's the updated blurb without gaming:\n\nColorado based, building a nonprofit app around everyday kindness, and probably outside hiking or exploring when I'm not working on it. I'm looking for something real and long term, but I've always believed the good ones start as friendships first. No rush, just genuinely getting to know someone and seeing where it goes. If you've got a favorite trail, a good book recommendation, or a story that starts with \"so this one time,\" I'm listening."
        }
        
        if lowercased.contains("plenty of fish") || lowercased.contains("dating profile") {
            return "Got it — a Plenty of Fish blurb. Let me get a sense of what you're looking for.\n\nAre you aiming for something casual and fun, or more serious and relationship-focused? And what are a few things you're passionate about outside of work?"
        }
        
        if lowercased.contains("hello") || lowercased.contains("hi") {
            return "Hello! I'm here to help. What would you like to work on today?"
        }
        
        return "I understand. Let me help you with that. Could you provide more details about what you're looking for?"
    }
    
    // MARK: - Tool Calls
    
    /// Execute a tool call
    func executeToolCall(toolId: String, parameters: [String: Any]) async throws -> String {
        return try await mcpClient.callTool(toolId: toolId, parameters: parameters)
    }
    
    // MARK: - Connectors
    
    /// Toggle connector selection
    func toggleConnector(_ connector: Connector) {
        if selectedConnectors.contains(connector.id) {
            selectedConnectors.remove(connector.id)
        } else {
            selectedConnectors.insert(connector.id)
        }
    }
    
    /// Check if a connector is selected
    func isConnectorSelected(_ connector: Connector) -> Bool {
        selectedConnectors.contains(connector.id)
    }
    
    // MARK: - Skills
    
    /// Toggle skill selection
    func toggleSkill(_ skill: Skill) {
        if selectedSkills.contains(skill.id) {
            selectedSkills.remove(skill.id)
        } else {
            selectedSkills.insert(skill.id)
        }
    }
    
    /// Check if a skill is selected
    func isSkillSelected(_ skill: Skill) -> Bool {
        selectedSkills.contains(skill.id)
    }
    
    // MARK: - Message Actions
    
    /// Copy message content
    func copyMessage(_ message: ChatMessage) {
        #if canImport(UIKit)
        UIPasteboard.general.string = message.content
        #endif
    }
    
    /// Share message content
    func shareMessage(_ message: ChatMessage) {
        // In production, this would use UIActivityViewController
        print("Sharing: \(message.content)")
    }
    
    /// Star/favorite a message
    func starMessage(_ message: ChatMessage) {
        print("Starring message: \(message.id)")
    }
    
    /// Rename a message (for conversation titles)
    func renameMessage(_ message: ChatMessage, newName: String) {
        print("Renaming to: \(newName)")
    }
    
    /// Delete a message
    func deleteMessage(_ message: ChatMessage) {
        messages.removeAll { $0.id == message.id }
    }
    
    /// Regenerate assistant response
    func regenerateResponse(for message: ChatMessage) async {
        // Remove the message and regenerate
        messages.removeAll { $0.id == message.id }
        
        isProcessing = true
        await processMessage(messages.last ?? ChatMessage(role: .user, content: ""))
        isProcessing = false
    }
    
    // MARK: - Clear Chat
    
    /// Clear all messages
    func clearChat() {
        messages.removeAll()
        messages.append(ChatMessage(
            role: .assistant,
            content: "I'm listening. How can I help you today?"
        ))
    }
}
