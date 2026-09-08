import Foundation
import AnyProvCore

/// Disk persistence for phone-originated E2B runs.
///
/// We keep runs in `Application Support/phoneRuns.v1` (JSON) so the
/// Sandboxes view can show a real history across launches, mirroring
/// the desktop-side `e2b/runner.ts` per-session files. The store
/// writes through `save(_:)` after each mutation and loads on
/// `init()`. Write storms (e.g. log-line events) are coalesced via
/// a 400ms debounce.
final class PhoneRunPersistence {
    static let maxEntries = 200

    private let fileURL: URL
    private var debounceTask: Task<Void, Never>?
    private var pendingSnapshot: [E2bPhoneRun]?

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            self.fileURL = Self.defaultFileURL()
        }
    }

    /// Read the persisted runs, newest first. Returns an empty array
    /// if the file is missing or unreadable.
    func load() -> [E2bPhoneRun] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let runs = try? decoder.decode([E2bPhoneRun].self, from: data) else {
            return []
        }
        return runs
    }

    /// Persist the given runs. Coalesces rapid back-to-back writes
    /// (log events) into a single disk write after 400ms of quiet.
    func save(_ runs: [E2bPhoneRun]) {
        pendingSnapshot = runs
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled, let self else { return }
            await self.flushPending()
        }
    }

    /// Cancel any pending debounce and write immediately. Call this
    /// from `applicationWillTerminate` paths so the very last run
    /// isn't dropped.
    func flushNow() {
        debounceTask?.cancel()
        debounceTask = nil
        guard let snapshot = pendingSnapshot else { return }
        pendingSnapshot = nil
        do {
            try write(snapshot)
        } catch {
            // Best-effort. We log nothing — the user can rebuild
            // history by running again.
        }
    }

    private func flushPending() async {
        guard let snapshot = pendingSnapshot else { return }
        pendingSnapshot = nil
        do {
            try write(snapshot)
        } catch {
            // Swallowed: the next save call will try again.
        }
    }

    private func write(_ runs: [E2bPhoneRun]) throws {
        let capped = Array(runs.prefix(Self.maxEntries))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(capped)
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }

    private static func defaultFileURL() -> URL {
        let support = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("phoneRuns.v1.json")
    }
}
