import Foundation
import Combine
import UIKit
import ImageIO
import AnyProvCore

/// A camera photo staged in the composer. Keeps only the compact JPEG payload
/// (sent to the model) and a small thumbnail (preview + transcript bubble) so
/// a 12 MP frame never lives in the view model.
struct ChatImageAttachment: Identifiable {
    let id: UUID
    let jpegData: Data
    let thumbnailData: Data

    init(id: UUID = UUID(), jpegData: Data, thumbnailData: Data) {
        self.id = id
        self.jpegData = jpegData
        self.thumbnailData = thumbnailData
    }
}

/// ViewModel for the Chat feature. Drives the messages, the model picker,
/// and the toggles in the Add-to-Chat sheet. Backed by real provider API
/// calls — no fake/demo responses.
@MainActor
final class ChatViewModel: ObservableObject {
    // MARK: - Published Properties

    @Published var messages: [ChatMessage] = []
    @Published var inputText: String = ""
    @Published var isProcessing: Bool = false
    /// True while a large/existing chat is being hydrated into the UI.
    /// Chat chrome should appear immediately with a spinner rather than
    /// freezing on the previous screen until conversion finishes.
    @Published var isLoadingChat: Bool = false
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
    @Published var webSearchEnabled: Bool = false
    @Published var researchEnabled: Bool = false
    @Published var healthEnabled: Bool = false
    @Published var locationEnabled: Bool = false
    @Published var connectorDiscoveryEnabled: Bool = true
    @Published var selectedConnectors: Set<String> = []

    @Published var toolAccess: ToolAccess = .auto
    @Published var currentProject: String?
    @Published var attachedFileURLs: [URL] = []
    @Published var showFilePicker: Bool = false
    /// Photos captured from the camera, staged in the composer until Send.
    @Published var attachedImages: [ChatImageAttachment] = []
    @Published var showCamera: Bool = false

    /// Connectors surfaced by the desktop server. Empty until the server
    /// reports its catalog of available connectors.
    @Published var connectors: [Connector] = []

    /// Apple Health integration for this chat (read-only snapshot → system prompt).
    let healthService = HealthKitService()
    /// True while the system Health authorization sheet is up.
    @Published var isRequestingHealthAccess: Bool = false

    /// Device location for this chat (fresh fix → system prompt).
    let locationService = LocationService()
    /// True while the system location permission sheet or a fix is in flight.
    @Published var isRequestingLocationAccess: Bool = false

    /// Client-side web search / research (DuckDuckGo + Wikipedia).
    private let webSearchService = WebSearchService()

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
    /// In-flight history hydrate (cancelled when switching chats quickly).
    private var loadChatTask: Task<Void, Never>?
    /// Full-quality image payloads keyed by user message ID, so Regenerate can
    /// restore the exact photos that were sent (attachments aren't persisted).
    private var imagePayloadsByMessageID: [UUID: [ChatImageAttachment]] = [:]

    // MARK: - Tool Access

    enum ToolAccess: String, CaseIterable {
        case auto = "Auto"
        case manual = "Manual"
        case disabled = "Disabled"
    }

    // MARK: - Attached Photos

    /// Attach a camera photo to the composer. The raw JPEG data is downsampled
    /// via ImageIO off the main thread so a full 12 MP bitmap is never decoded
    /// (critical when a Metal VLM is resident in memory).
    func attachCameraImage(_ data: Data) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let jpeg = Self.downsampledJPEG(from: data, maxDimension: 1600, quality: 0.8),
                  let thumb = Self.downsampledJPEG(from: data, maxDimension: 320, quality: 0.6)
            else { return }
            let attachment = ChatImageAttachment(jpegData: jpeg, thumbnailData: thumb)
            DispatchQueue.main.async {
                self?.attachedImages.append(attachment)
            }
        }
    }

    func removeAttachedImage(_ id: ChatImageAttachment.ID) {
        attachedImages.removeAll { $0.id == id }
    }

    /// Downsample JPEG data straight to the target pixel size with ImageIO, then
    /// re-encode at the given quality. Decodes once at the target resolution
    /// (never a full-size bitmap) and bakes EXIF orientation in.
    private static func downsampledJPEG(
        from data: Data,
        maxDimension: CGFloat,
        quality: CGFloat
    ) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(Int(maxDimension), 1),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let image = UIImage(cgImage: cgImage, scale: 1, orientation: .up)
        return image.jpegData(compressionQuality: quality)
    }

    // MARK: - Init

    init(catalog: ModelCatalog = ModelCatalog()) {
        self.catalog = catalog
        // Seed connector list from marketplace (official + user-added catalogs).
        applyMarketplaceConnectors(MarketplaceStore.shared.connectors)
        let availableIds = connectors.filter(\.isEnabled).map(\.id)
        // Prefer common productivity connectors when present in the catalog.
        let preferred = ["gmail", "gcal", "gdrive", "google-calendar", "google-drive"]
        let defaults = preferred.filter { availableIds.contains($0) }
        // Both branches must be `[String]` — `prefix` returns `ArraySlice`.
        self.selectedConnectors = Set(defaults.isEmpty ? Array(availableIds.prefix(3)) : defaults)
        healthService.refreshAuthorizationState()
        locationService.refreshAuthorizationState()
        // Bubble nested service publishes so the Add-to-Chat sheet
        // refreshes authorization subtitles without a second ObservedObject.
        healthService.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
        locationService.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
        MarketplaceStore.shared.objectWillChange
            .sink { [weak self] _ in
                guard let self else { return }
                self.applyMarketplaceConnectors(MarketplaceStore.shared.connectors)
            }
            .store(in: &cancellables)
    }

    /// Map marketplace connector rows into chat UI models.
    func applyMarketplaceConnectors(_ items: [MarketplaceConnector]) {
        connectors = items.map { item in
            Connector(
                id: item.id,
                name: item.name,
                iconName: item.icon ?? "puzzlepiece.extension",
                itemCount: 0,
                isEnabled: item.isAvailable,
                description: item.description
            )
        }
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

    // MARK: - Location

    /// Turn location context on/off. Enabling triggers the system location
    /// permission sheet the first time.
    func setLocationEnabled(_ enabled: Bool) async {
        if !enabled {
            locationEnabled = false
            return
        }
        guard locationService.isLocationServicesEnabled else {
            locationEnabled = false
            presentError(LocationServiceError.servicesDisabled.errorDescription ?? "Location is unavailable.")
            return
        }
        isRequestingLocationAccess = true
        defer { isRequestingLocationAccess = false }
        do {
            try await locationService.requestAuthorization()
            locationEnabled = true
        } catch {
            locationEnabled = false
            presentError((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    // MARK: - Message Handling

    /// Voice-mode entry: set the composer text and send, returning the assistant
    /// reply body for TTS (or nil on failure / empty).
    @discardableResult
    func sendVoiceMessage(_ text: String) async -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        inputText = trimmed
        await sendMessage()
        // Prefer the latest non-empty assistant turn (the one we just finished).
        if let last = messages.last(where: {
            $0.role == .assistant
                && !$0.isStreaming
                && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) {
            // Surface soft API errors as spoken text too so the user hears them.
            return last.content
        }
        return nil
    }

    /// Send a user message and stream the assistant reply from the
    /// currently selected provider/model.
    func sendMessage() async {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachedImages.isEmpty else { return }
        // Don't send while a large transcript is still hydrating — the load
        // would replace `messages` and drop the just-sent turn.
        guard !isLoadingChat else { return }
        guard let state,
              let model = state.selectedModel
        else {
            presentError(
                "Select a model in Settings first.",
                action: .openProviderSettings
            )
            return
        }
        // Local Metal is chat-only and needs no API key. Ensure MLX engine is bound
        // and the selected weights are loaded before we call generate (avoids a
        // second concurrent multi-GB load racing the selection preload).
        if model.provider == .localMetal {
            LocalMetalBootstrap.ensureRegistered()
            guard LocalMetalRuntime.isReady else {
                presentError(
                    "On-device Metal runtime is not ready. Rebuild the app with MLX packages, then download a model in Settings → Manage models.",
                    action: .openProviderSettings
                )
                return
            }
            await state.ensureSelectedLocalMetalLoaded()
            if let loadError = state.localMetalLoadError, !loadError.isEmpty {
                presentError(loadError, action: .openProviderSettings)
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
            activeChatID = history?.ensureActiveChat(selectedModel: model)
        }
        // Remember which model this chat is using so reopen restores it.
        persistSelectedModel(model)

        // Snapshot the staged photos onto this exact user turn before clearing
        // the composer. Payload rides the wire; thumbnails render the bubble.
        let stagedImages = attachedImages
        let imagePayload: [ProviderChatMessage.ImageAttachment] = stagedImages.map {
            ProviderChatMessage.ImageAttachment(
                mimeType: "image/jpeg",
                base64Data: $0.jpegData.base64EncodedString()
            )
        }
        let displayAttachments: [Attachment] = stagedImages.map {
            Attachment(name: "Camera photo", type: .image, thumbnailData: $0.thumbnailData)
        }
        let userMessageID = UUID()
        messages.append(ChatMessage(
            id: userMessageID,
            role: .user,
            content: text,
            attachments: displayAttachments.isEmpty ? nil : displayAttachments
        ))
        // Cache the full-quality payloads so Regenerate can restore them.
        if !stagedImages.isEmpty {
            imagePayloadsByMessageID[userMessageID] = stagedImages
        }
        schedulePersist()
        inputText = ""
        attachedImages = []
        isProcessing = true
        // Live Activity after a short delay (skips fast replies / small prompts).
        AIThinkingActivityManager.shared.thinkingDidStart(kind: .chat, prompt: text)
        defer {
            isProcessing = false
            AIThinkingActivityManager.shared.thinkingDidEnd()
        }

        // Placeholder assistant bubble so web-search / research steps stream
        // in as grey status text before the model reply arrives.
        let assistantID = UUID()
        messages.append(ChatMessage(
            id: assistantID,
            role: .assistant,
            content: "",
            isStreaming: true,
            toolCalls: []
        ))

        // Build the multi-turn payload from the in-memory conversation
        // (skip the empty streaming assistant shell).
        var turns: [ProviderChatMessage] = messages.compactMap { msg in
            if msg.id == assistantID { return nil }
            let body = msg.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty || msg.id == userMessageID else { return nil }
            let images = msg.id == userMessageID ? imagePayload : []
            return ProviderChatMessage(role: mapRole(msg.role), content: msg.content, images: images)
        }

        // Optional context snapshots — injected as system turns so Anthropic
        // (system field) and OpenAI-compatible hosts both see them. Fresh per
        // send so health stats and location stay current.
        var systemContext: [String] = []

        // User profile memory (Settings → Memory), when search/generate is on.
        // `state` was already unwrapped non-optionally in the guard above.
        if state.memorySearchChats || state.memoryGenerateFromChats {
            let mem = UserMemoryStore.shared.formatForSystem()
            if !mem.isEmpty {
                systemContext.append("User memory (private, on this device):\n\(mem)")
            }
        }

        if healthEnabled {
            do {
                systemContext.append(try await healthService.snapshotForPrompt())
            } catch {
                // Don't block the chat; surface a soft warning on the reply path.
                let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                presentError("Health data unavailable: \(msg)")
            }
        }
        if locationEnabled {
            do {
                systemContext.append(try await locationService.snapshotForPrompt())
            } catch {
                let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                presentError("Location unavailable: \(msg)")
            }
        }

        // Web search / Research — live SERP + optional Wikipedia, shown as
        // grey tool lines on the assistant bubble. OpenRouter models use the
        // provider-native web search API instead of client-side scraping.
        var toolCalls: [ToolCall] = []
        let nativeWebSearch = model.provider == .openrouter && (researchEnabled || webSearchEnabled)
        if researchEnabled || webSearchEnabled {
            if nativeWebSearch {
                let step = WebSearchService.Step(
                    name: researchEnabled ? "research" : "web_search",
                    summary: researchEnabled
                        ? "Researching with OpenRouter web search…"
                        : "Searching the web with OpenRouter…",
                    detail: "Native OpenRouter web search API",
                    status: .completed
                )
                toolCalls = [ToolCall(from: step)]
                if let idx = messages.firstIndex(where: { $0.id == assistantID }) {
                    messages[idx].toolCalls = toolCalls
                }
            } else {
                let mode: WebSearchService.Mode = researchEnabled ? .research : .webSearch
                do {
                    let bundle = try await webSearchService.search(userMessage: text, mode: mode) {
                        [weak self] step in
                        await self?.applyWebSearchStep(step, toAssistant: assistantID)
                        await MainActor.run {
                            AIThinkingActivityManager.shared.thinkingDidUpdate(
                                status: step.summary.isEmpty ? "Searching…" : step.summary
                            )
                        }
                    }
                    toolCalls = bundle.steps.map { ToolCall(from: $0) }
                    if let idx = messages.firstIndex(where: { $0.id == assistantID }) {
                        messages[idx].toolCalls = toolCalls
                    }
                    if !bundle.promptBlock.isEmpty {
                        systemContext.append(bundle.promptBlock)
                    }
                } catch {
                    let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    let failed = ToolCall(
                        name: researchEnabled ? "research" : "web_search",
                        summary: researchEnabled
                            ? "Research unavailable"
                            : "Web search unavailable",
                        detail: msg,
                        status: .failed(msg)
                    )
                    toolCalls = [failed]
                    if let idx = messages.firstIndex(where: { $0.id == assistantID }) {
                        messages[idx].toolCalls = toolCalls
                    }
                    presentError(msg)
                }
            }
        }

        if !systemContext.isEmpty {
            turns.insert(
                ProviderChatMessage(role: .system, content: systemContext.joined(separator: "\n\n")),
                at: 0
            )
        }

        do {
            // Re-read selection immediately before the API call so a mid-conversation
            // model/effort switch in the picker is always honored (not a stale capture).
            guard let liveModel = state.selectedModel else {
                presentError("Select a model in Settings first.", action: .openProviderSettings)
                finishAssistant(
                    assistantID,
                    content: "Select a model in Settings first.",
                    toolCalls: toolCalls
                )
                return
            }
            let liveKey = state.resolvedAPIKey(for: liveModel.provider)
            if liveModel.provider.requiresAPIKey, liveKey.isEmpty {
                presentError(
                    "Add an API key for \(liveModel.provider.displayName) in Settings.",
                    action: .openProviderSettings
                )
                finishAssistant(
                    assistantID,
                    content: "Add an API key for \(liveModel.provider.displayName) in Settings.",
                    toolCalls: toolCalls
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
                finishAssistant(
                    assistantID,
                    content: "Custom provider is missing a base URL. Edit it in Settings.",
                    toolCalls: toolCalls
                )
                return
            }
            AIThinkingActivityManager.shared.thinkingDidUpdate(status: "Thinking…")
            let reply = try await catalog.provider(
                liveModel.provider,
                customBaseURL: baseURL,
                style: style
            ).chat(
                model: liveModel.modelID,
                apiKey: liveKey,
                messages: turns,
                effort: state.effort,
                webSearchQuery: (liveModel.provider == .openrouter
                    && (researchEnabled || webSearchEnabled))
                    ? text
                    : nil
            )
            let parsed = ThinkingExtractor.extract(from: reply)
            // Persist reasoning only when there is a body; empty open tags are a live UI concern.
            let thought = parsed.thinking.flatMap { $0.isEmpty ? nil : $0 }
            // Instant heuristic label; refine with on-device model in the background.
            let heuristicSummary = thought.map { ThinkingSummaryGenerator.heuristicSummary(from: $0) }
            if let idx = messages.firstIndex(where: { $0.id == assistantID }) {
                messages[idx].content = parsed.content
                messages[idx].thoughtProcess = thought
                messages[idx].thoughtSummary = heuristicSummary
                messages[idx].toolCalls = toolCalls.isEmpty ? nil : toolCalls
                messages[idx].isStreaming = false
            } else {
                messages.append(ChatMessage(
                    id: assistantID,
                    role: .assistant,
                    content: parsed.content,
                    thoughtProcess: thought,
                    thoughtSummary: heuristicSummary,
                    toolCalls: toolCalls.isEmpty ? nil : toolCalls
                ))
            }
            schedulePersist()
            if let thought {
                Task { @MainActor [weak self] in
                    let refined = await ThinkingSummaryGenerator.summarize(thought)
                    guard let self,
                          let idx = self.messages.firstIndex(where: { $0.id == assistantID })
                    else { return }
                    self.messages[idx].thoughtSummary = refined
                    self.schedulePersist()
                }
            }
            // Capture long outputs / code blocks as an Artifact (≥ 10 lines OR contains ```).
            // Prefer visible answer content so artifacts aren't polluted with reasoning.
            // Title starts as a heuristic, then Apple Foundation Model renames when available.
            if let artifact = state.artifactStore.maybeSave(
                chatId: activeChatID,
                messageId: assistantID,
                content: parsed.content
            ) {
                Task { @MainActor [weak self] in
                    guard self != nil else { return }
                    let named = await ArtifactTitleGenerator.suggestTitle(for: parsed.content)
                    if named != artifact.title {
                        state.artifactStore.updateTitle(id: artifact.id, title: named)
                        // Keep an open split panel title in sync if this artifact is showing.
                        if state.openArtifact?.id == artifact.id {
                            state.openArtifact = state.artifactStore.artifacts
                                .first(where: { $0.id == artifact.id })
                        }
                    }
                }
            }
        } catch {
            let msg = (error as? ProviderError)?.errorDescription ?? error.localizedDescription
            presentError(msg)
            let name = state.selectedModel?.provider.displayName ?? model.provider.displayName
            if let idx = messages.firstIndex(where: { $0.id == assistantID }) {
                messages[idx].content = "I couldn't reach \(name): \(msg)"
                messages[idx].toolCalls = toolCalls.isEmpty ? nil : toolCalls
                messages[idx].isStreaming = false
            } else {
                messages.append(ChatMessage(
                    id: assistantID,
                    role: .assistant,
                    content: "I couldn't reach \(name): \(msg)",
                    toolCalls: toolCalls.isEmpty ? nil : toolCalls
                ))
            }
            schedulePersist()
        }
    }

    /// Apply a live web-search / research step onto the streaming assistant bubble.
    @MainActor
    private func applyWebSearchStep(_ step: WebSearchService.Step, toAssistant assistantID: UUID) {
        guard let idx = messages.firstIndex(where: { $0.id == assistantID }) else { return }
        var calls = messages[idx].toolCalls ?? []
        if let existing = calls.firstIndex(where: { $0.id == step.id }) {
            calls[existing] = ToolCall(from: step)
        } else {
            calls.append(ToolCall(from: step))
        }
        messages[idx].toolCalls = calls
    }

    /// Finalize the streaming assistant bubble with content (and optional tools).
    private func finishAssistant(_ id: UUID, content: String, toolCalls: [ToolCall]) {
        if let idx = messages.firstIndex(where: { $0.id == id }) {
            messages[idx].content = content
            messages[idx].toolCalls = toolCalls.isEmpty ? nil : toolCalls
            messages[idx].isStreaming = false
        } else {
            messages.append(ChatMessage(
                id: id,
                role: .assistant,
                content: content,
                toolCalls: toolCalls.isEmpty ? nil : toolCalls
            ))
        }
        schedulePersist()
    }

    // MARK: - History resume / persist

    /// Switch to a global recent chat. Updates chrome immediately, then
    /// hydrates messages after a frame so large transcripts don't block
    /// navigation (sidebar close + chat title + spinner first).
    func loadChat(id: UUID, from store: ChatHistoryStore) {
        loadChatTask?.cancel()
        persistTask?.cancel()

        history = store
        activeChatID = id
        activeProjectID = nil
        currentProject = nil
        inputText = ""
        attachedImages = []
        imagePayloadsByMessageID.removeAll()
        clearError()

        // Prefer the store row (fresh messages) over a stale sidebar snapshot.
        let item = store.recents.first(where: { $0.id == id }) ?? ChatHistoryItem(
            id: id,
            title: "Chat",
            lastMessageAt: Date(),
            messages: []
        )
        // Mark active + reorder without waiting for message conversion.
        store.openChat(item)
        restoreSelectedModel(store.selectedModel(for: id) ?? item.selectedModel)

        let persistedCount = item.messages.count
        // Small chats can hydrate inline; larger ones show a spinner so
        // the main thread can paint chat chrome first.
        if persistedCount == 0 {
            messages = []
            isLoadingChat = false
            return
        }
        if persistedCount <= 12 {
            messages = store.messages(for: id)
            isLoadingChat = false
            return
        }

        messages = []
        isLoadingChat = true
        let chatID = id
        loadChatTask = Task { @MainActor [weak self] in
            // Yield so SwiftUI can close the sidebar and show the spinner.
            await Task.yield()
            // A second yield + tiny sleep lets the first layout commit on
            // busy devices before we allocate/map a large transcript.
            try? await Task.sleep(nanoseconds: 16_000_000)
            guard let self, !Task.isCancelled else { return }
            guard self.activeChatID == chatID else { return }

            let loaded = store.messages(for: chatID)
            guard !Task.isCancelled, self.activeChatID == chatID else { return }
            self.messages = loaded
            self.isLoadingChat = false
        }
    }

    /// Switch to a project-scoped chat with the same non-blocking hydrate path.
    func loadProjectChat(project: ProjectItem, chat: ProjectChatItem, from store: ChatHistoryStore) {
        loadChatTask?.cancel()
        persistTask?.cancel()

        history = store
        activeChatID = chat.id
        activeProjectID = project.id
        currentProject = project.name
        inputText = ""
        attachedImages = []
        imagePayloadsByMessageID.removeAll()
        clearError()

        // Prefer the store snapshot over the navigation value (which can be stale).
        let saved = store.projectChatSelectedModel(projectID: project.id, chatID: chat.id)
            ?? chat.selectedModel
        restoreSelectedModel(saved)

        let persistedCount = store.projectChats[project.id]?
            .first(where: { $0.id == chat.id })?
            .messages.count
            ?? chat.messages.count

        if persistedCount == 0 {
            messages = []
            isLoadingChat = false
            return
        }
        if persistedCount <= 12 {
            messages = store.projectChatMessages(projectID: project.id, chatID: chat.id)
            isLoadingChat = false
            return
        }

        messages = []
        isLoadingChat = true
        let projectID = project.id
        let chatID = chat.id
        loadChatTask = Task { @MainActor [weak self] in
            await Task.yield()
            try? await Task.sleep(nanoseconds: 16_000_000)
            guard let self, !Task.isCancelled else { return }
            guard self.activeChatID == chatID, self.activeProjectID == projectID else { return }

            let loaded = store.projectChatMessages(projectID: projectID, chatID: chatID)
            guard !Task.isCancelled,
                  self.activeChatID == chatID,
                  self.activeProjectID == projectID
            else { return }
            self.messages = loaded
            self.isLoadingChat = false
        }
    }

    func beginNewChat(in store: ChatHistoryStore) {
        loadChatTask?.cancel()
        persistTask?.cancel()
        history = store
        let currentModel = state?.selectedModel
        let item = store.startNewChat(selectedModel: currentModel)
        activeChatID = item.id
        activeProjectID = nil
        currentProject = nil
        messages = []
        isLoadingChat = false
        inputText = ""
        attachedImages = []
        imagePayloadsByMessageID.removeAll()
        clearError()
    }

    /// Write the current composer model onto the active chat history row.
    /// Only non-nil models are stored so a temporary catalog clear cannot
    /// wipe a chat's remembered selection.
    func persistSelectedModel(_ model: AIModel? = nil) {
        guard let history else { return }
        guard let model = model ?? state?.selectedModel else { return }
        if let projectID = activeProjectID, let chatID = activeChatID {
            history.saveProjectChatSelectedModel(model, projectID: projectID, chatID: chatID)
        } else if let chatID = activeChatID {
            history.saveSelectedModel(model, for: chatID)
        }
    }

    /// Apply a chat's saved model to the global composer selection.
    /// Prefers a live catalog entry (fresher display name / listing) when present.
    private func restoreSelectedModel(_ saved: AIModel?) {
        guard let saved, let state else { return }
        if let live = state.allModels.first(where: { $0.id == saved.id }) {
            if state.selectedModel?.id != live.id {
                state.selectedModel = live
            }
            return
        }
        // Do not re-select a deleted / unavailable on-device model.
        if saved.provider == .localMetal {
            return
        }
        if state.selectedModel?.id != saved.id {
            // Cloud model may have left the catalog temporarily; restore the snapshot
            // so the pill and next send target the same provider/id.
            state.selectedModel = saved
        }
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
        // Messages only — model is persisted explicitly on pick / send so a
        // catalog refresh cannot overwrite a chat's saved selection.
        if let projectID = activeProjectID, let chatID = activeChatID {
            history.saveProjectChatMessages(messages, projectID: projectID, chatID: chatID)
        } else if let chatID = activeChatID {
            history.saveMessages(messages, for: chatID)
        } else if !messages.isEmpty {
            let id = history.ensureActiveChat(selectedModel: state?.selectedModel)
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
        let trimmed = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        #if canImport(UIKit)
        UIPasteboard.general.string = trimmed
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
        imagePayloadsByMessageID.removeValue(forKey: message.id)
        schedulePersist()
    }

    /// Regenerate the last assistant response.
    func regenerateResponse(for message: ChatMessage) async {
        guard message.role == .assistant else { return }
        messages.removeAll { $0.id == message.id }
        guard let lastUser = messages.last(where: { $0.role == .user }) else { return }
        inputText = lastUser.content
        // Restore the original photos so regeneration sends the same image
        // payload instead of silently dropping the image.
        attachedImages = imagePayloadsByMessageID[lastUser.id] ?? []
        messages.removeAll { $0.id == lastUser.id }
        await sendMessage()
    }

    /// Clear all messages and start fresh.
    func clearChat() {
        messages.removeAll()
        imagePayloadsByMessageID.removeAll()
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
