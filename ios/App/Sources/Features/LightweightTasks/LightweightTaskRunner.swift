import Foundation
import AnyProvCore

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Routes short “Lightweight Tasks” generations to Apple Intelligence or a
/// user-linked BYOK model, based on `LightweightTasksSettings`.
///
/// Independent of `AppState` so history / title jobs can call it from any
/// context (uses Keychain + UserDefaults the same way Settings does).
enum LightweightTaskRunner {
    /// Whether the on-device Apple system model can run right now.
    static var appleFoundationAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return SystemLanguageModel.default.isAvailable
        }
        #endif
        return false
    }

    /// Human status for settings / walkthrough.
    static var appleFoundationStatusLine: String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            let model = SystemLanguageModel.default
            switch model.availability {
            case .available:
                return "Ready on this device"
            case .unavailable(let reason):
                return unavailableMessage(reason)
            @unknown default:
                return model.isAvailable ? "Ready on this device" : "Not available"
            }
        }
        #endif
        return "Requires iOS 26+ with Apple Intelligence"
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    private static func unavailableMessage(
        _ reason: SystemLanguageModel.Availability.UnavailableReason
    ) -> String {
        switch reason {
        case .deviceNotEligible:
            return "This device doesn’t support Apple Intelligence"
        case .appleIntelligenceNotEnabled:
            return "Turn on Apple Intelligence in Settings"
        case .modelNotReady:
            return "Still downloading or preparing"
        @unknown default:
            return "Not available (\(String(describing: reason)))"
        }
    }
    #endif

    /// Run a short completion. Returns nil when no backend is configured or all fail.
    static func complete(
        system: String,
        user: String,
        maxTokens: Int = 48
    ) async -> String? {
        // The new default-model storage is the source of truth. Three possible
        // shapes the storage slot can hold:
        //   - empty string                       → no default picked yet
        //   - `__apple-foundation__` sentinel    → use Apple Intelligence first
        //   - `<provider>/<modelID>`             → use the linked model first
        // For each branch we keep the original Apple ↔ Linked fallback chain
        // (Apple Foundation can fail if the device disabled Apple Intelligence
        // mid-session; Linked can fail if the API key was removed).
        let raw = UserDefaults.standard.string(forKey: DefaultModelStorageKey) ?? ""
        let usesAppleFoundation = (raw == DefaultAppleFoundationSentinel)
        let linked = !raw.isEmpty && !usesAppleFoundation ? parseLinkedDefaults(raw) : nil

        if usesAppleFoundation {
            if let text = await completeWithAppleFoundation(
                system: system,
                user: user,
                maxTokens: maxTokens
            ) {
                return text
            }
            return await completeWithLinkedModel(
                system: system,
                user: user,
                maxTokens: maxTokens,
                provider: linked?.provider,
                modelID: linked?.modelID
            )
        }

        if linked != nil {
            if let text = await completeWithLinkedModel(
                system: system,
                user: user,
                maxTokens: maxTokens,
                provider: linked?.provider,
                modelID: linked?.modelID
            ) {
                return text
            }
            return await completeWithAppleFoundation(
                system: system,
                user: user,
                maxTokens: maxTokens
            )
        }

        // Nothing picked yet — try Apple first (cheap, on-device) and bail.
        return await completeWithAppleFoundation(
            system: system,
            user: user,
            maxTokens: maxTokens
        )
    }

    /// Storage key shared with `AppState.defaultLightweightModelID` (`@AppStorage`
    /// ultimately writes to `UserDefaults.standard` under the same key).
    /// Keeping these as `static let` lets us reference them from the runner
    /// without going through an `AppState` instance.
    private static let DefaultModelStorageKey = "defaultLightweightModelID.v1"
    private static let DefaultAppleFoundationSentinel = "__apple-foundation__"

    private struct LinkedDefault {
        let provider: ProviderID
        let modelID: String
    }

    /// Parse a stored `"<providerRaw>/<modelID>"` string back into a typed
    /// `(ProviderID, modelID)` pair. Returns nil when the format is unparsable.
    private static func parseLinkedDefaults(_ raw: String) -> LinkedDefault? {
        guard let slash = raw.firstIndex(of: "/") else { return nil }
        let providerRaw = String(raw[..<slash])
        let modelID = String(raw[raw.index(after: slash)...])
        guard !providerRaw.isEmpty, !modelID.isEmpty,
              let provider = ProviderID(rawValue: providerRaw)
        else { return nil }
        return LinkedDefault(provider: provider, modelID: modelID)
    }

    // MARK: - Backends

    private static func completeWithAppleFoundation(
        system: String,
        user: String,
        maxTokens: Int
    ) async -> String? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            let model = SystemLanguageModel.default
            guard model.isAvailable else { return nil }
            do {
                let session = LanguageModelSession(instructions: system)
                let options = GenerationOptions(
                    sampling: .greedy,
                    temperature: 0.2,
                    maximumResponseTokens: maxTokens
                )
                let response = try await session.respond(to: user, options: options)
                let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : text
            } catch {
                return nil
            }
        }
        #endif
        return nil
    }

    private static func completeWithLinkedModel(
        system: String,
        user: String,
        maxTokens: Int,
        provider: ProviderID?,
        modelID: String?
    ) async -> String? {
        guard let provider, let modelID, !modelID.isEmpty else { return nil }

        let store = KeychainSecretStore()
        var key = store.get(SecretKey.providerAPIKey(provider)) ?? ""
        if key.isEmpty, !provider.requiresAPIKey {
            key = "local"
        }
        // Keyless OpenAI-compatible customs (Ollama).
        if key.isEmpty, case .custom = provider {
            key = "local"
        }
        guard !key.isEmpty else { return nil }

        let custom = loadCustomProvider(for: provider)
        let catalog = ModelCatalog()
        let client = catalog.provider(
            provider,
            customBaseURL: custom.flatMap { URL(string: $0.baseURL) },
            style: custom?.style
        )

        var messages: [ProviderChatMessage] = []
        if !system.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            messages.append(ProviderChatMessage(role: .system, content: system))
        }
        messages.append(ProviderChatMessage(role: .user, content: user))

        do {
            let text = try await client.chat(
                model: modelID,
                apiKey: key,
                messages: messages,
                effort: .low
            )
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } catch {
            return nil
        }
    }

    private static func loadCustomProvider(for provider: ProviderID) -> CustomProvider? {
        guard case .custom(let slug) = provider else { return nil }
        guard let data = UserDefaults.standard.data(forKey: "customProviders.v1"),
              let list = try? JSONDecoder().decode([CustomProvider].self, from: data)
        else { return nil }
        return list.first(where: { $0.id == slug })
    }
}
