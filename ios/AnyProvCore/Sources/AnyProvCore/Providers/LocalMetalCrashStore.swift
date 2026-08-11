import Foundation

/// A persisted record that an on-device Metal model failed (crashed) during
/// generation. Written at crash time by the MLX engine, surfaced on the next
/// app launch, and removed once the user has copied the logs, deleted the
/// model, or dismissed the report.
public struct LocalMetalCrashRecord: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let modelID: String
    public let displayName: String
    /// When the crash happened (for display + log text).
    public let timestamp: Date
    /// Human-readable crash details offered for copying / support.
    public let logText: String

    public init(
        id: UUID = UUID(),
        modelID: String,
        displayName: String,
        timestamp: Date = Date(),
        logText: String
    ) {
        self.id = id
        self.modelID = modelID
        self.displayName = displayName
        self.timestamp = timestamp
        self.logText = logText
    }
}

/// Persists "model crashed" reports across launches.
///
/// Pure Foundation (UserDefaults) so it stays testable and follows the same
/// storage pattern as `LocalMetalModelStore`. One record is kept per model —
/// a new crash replaces any still-pending report for the same hub id.
public actor LocalMetalCrashStore {
    public static let shared = LocalMetalCrashStore()

    /// Caps how many pending reports are retained (a handful of crashes at most).
    private static let maxPendingRecords = 10

    private let storageKey = "localMetal.crashReports.v1"

    public init() {}

    /// Reports that have not been acknowledged by the user yet (newest first).
    public func pendingRecords() -> [LocalMetalCrashRecord] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([LocalMetalCrashRecord].self, from: data)
        else { return [] }
        return decoded
    }

    /// Record a generation crash for a model. Replaces an earlier pending
    /// report for the same hub id so repeated crashes do not stack up.
    public func record(modelID: String, displayName: String, error: String) {
        let record = LocalMetalCrashRecord(
            modelID: modelID,
            displayName: displayName,
            logText: Self.logText(
                modelID: modelID,
                displayName: displayName,
                error: error
            )
        )
        var pending = pendingRecords().filter { $0.modelID != modelID }
        pending.insert(record, at: 0)
        if pending.count > Self.maxPendingRecords {
            pending = Array(pending.prefix(Self.maxPendingRecords))
        }
        save(pending)
    }

    /// Remove a single report (after the user handled or dismissed it).
    public func remove(id: UUID) {
        save(pendingRecords().filter { $0.id != id })
    }

    /// Remove every pending report (rarely used — e.g. "delete all models").
    public func removeAll() {
        save([])
    }

    private func save(_ records: [LocalMetalCrashRecord]) {
        if records.isEmpty {
            UserDefaults.standard.removeObject(forKey: storageKey)
            return
        }
        if let data = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    /// Composes the "log" text the user can copy, with enough context to file
    /// a useful report (model, timestamp, error).
    private static func logText(modelID: String, displayName: String, error: String) -> String {
        let time = Self.timestampFormatter.string(from: Date())
        let errorLine = error.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        RoamSocket on-device model crash

        Model: \(displayName)
        Model id: \(modelID)
        Crashed at: \(time)

        Error:
        \(errorLine.isEmpty ? "(no error details)" : errorLine)
        """
    }

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
