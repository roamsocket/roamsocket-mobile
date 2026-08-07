import Foundation
import AnyProvCore

/// Preferences for short on-device / cheap helper generations
/// (chat titles, artifact names, commit subjects, thinking summaries).
struct LightweightTasksSettings: Codable, Equatable, Sendable {
    enum Mode: String, Codable, CaseIterable, Identifiable, Sendable {
        /// Apple Intelligence system model (iOS / Apple Silicon Mac when available).
        case appleFoundation
        /// User-selected BYOK cloud (or custom) model for the same jobs.
        case linkedModel

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .appleFoundation: return "Apple Intelligence"
            case .linkedModel: return "Linked model"
            }
        }

        var detail: String {
            switch self {
            case .appleFoundation:
                return "On-device system model. Private and free. Best on iPhone with Apple Intelligence enabled."
            case .linkedModel:
                return "Uses a provider and model you choose (and pay for). Works on any device with an API key."
            }
        }
    }

    var mode: Mode
    /// `ProviderID.rawValue` when mode is `.linkedModel`.
    var linkedProviderRaw: String?
    var linkedModelID: String?
    /// First-launch walkthrough finished.
    var walkthroughCompleted: Bool

    static let storageKey = "lightweightTasks.v1"

    static var `default`: LightweightTasksSettings {
        LightweightTasksSettings(
            mode: LightweightTaskRunner.appleFoundationAvailable ? .appleFoundation : .linkedModel,
            linkedProviderRaw: nil,
            linkedModelID: nil,
            walkthroughCompleted: false
        )
    }

    var linkedProvider: ProviderID? {
        guard let raw = linkedProviderRaw else { return nil }
        return ProviderID(rawValue: raw)
    }

    var hasLinkedModel: Bool {
        guard mode == .linkedModel else { return false }
        return linkedProvider != nil && !(linkedModelID?.isEmpty ?? true)
    }

    static func load() -> LightweightTasksSettings {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(LightweightTasksSettings.self, from: data)
        else { return .default }
        return decoded
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}
