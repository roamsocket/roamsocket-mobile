import Foundation
import Combine
import AnyProvCore

/// Process-wide Metal model downloads with desktop-style step progress.
///
/// Owns the download `Task` so transfers keep running when the Manage models
/// sheet is dismissed. Progress (fraction + status + bytes) is published for
/// any reopened UI to observe.
@MainActor
final class LocalMetalDownloadManager: ObservableObject {
    static let shared = LocalMetalDownloadManager()

    enum Phase: String, Sendable {
        case active
        case done
        case error
    }

    /// One download track — shown in the multi-download banner + per-row UI.
    struct Track: Identifiable, Equatable {
        var id: String { hubID }
        var hubID: String
        var displayName: String
        var fraction: Double
        var status: String
        var error: String?
        var phase: Phase
        var bytesDownloaded: Int64?
        var bytesTotal: Int64?
        var file: String?
        var updatedAt: Date
    }

    /// Hub id currently downloading (one at a time on phone).
    @Published private(set) var activeModelID: String?
    /// All tracks (active + recent done/error) for the Downloads banner.
    @Published private(set) var tracks: [String: Track] = [:]
    @Published private(set) var lastError: String?
    @Published private(set) var lastStatus: String = ""

    private var tasks: [String: Task<Void, Never>] = [:]

    private init() {}

    var isBusy: Bool { activeModelID != nil }

    /// Active + recent tracks for the banner (same filter as desktop).
    var bannerTracks: [Track] {
        tracks.values
            .filter { t in
                switch t.phase {
                case .active: return true
                case .error: return true
                case .done: return Date().timeIntervalSince(t.updatedAt) < 5
                }
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func track(for modelID: String) -> Track? {
        tracks[modelID]
    }

    /// 0…1 while this hub id is actively downloading; nil otherwise.
    func progress(for modelID: String) -> Double? {
        guard let t = tracks[modelID], t.phase == .active else { return nil }
        return t.fraction
    }

    /// Step status for an active (or recent error) download.
    func status(for modelID: String) -> String? {
        guard let t = tracks[modelID] else { return nil }
        if t.phase == .error { return t.error ?? "Download failed" }
        if t.phase == .done { return "Ready" }
        return t.status
    }

    /// Start (or no-op if already running) a download that outlives the settings sheet.
    func start(modelID: String, appState: AppState, displayName: String? = nil) {
        if tasks[modelID] != nil { return }
        if let active = activeModelID, active != modelID {
            lastError = "Another model is already downloading. It continues in the background — wait for it to finish, then try again."
            return
        }

        LocalMetalBootstrap.ensureRegistered()
        guard LocalMetalRuntime.engine != nil else {
            lastError = "Metal runtime is not linked. Rebuild the iOS app with mlx-swift-lm packages."
            return
        }

        let name = displayName
            ?? LocalMetalCatalog.displayName(for: modelID)

        lastError = nil
        lastStatus = "Listing files…"
        activeModelID = modelID
        tracks[modelID] = Track(
            hubID: modelID,
            displayName: name,
            fraction: 0,
            status: "Listing files…",
            error: nil,
            phase: .active,
            bytesDownloaded: nil,
            bytesTotal: nil,
            file: nil,
            updatedAt: Date()
        )

        // Detached: not a child of the sheet/button task, so dismiss cannot cancel it.
        let task = Task.detached(priority: .utility) {
            await LocalMetalDownloadManager.runDownload(
                modelID: modelID,
                appState: appState
            )
        }
        tasks[modelID] = task
    }

    private nonisolated static func runDownload(modelID: String, appState: AppState) async {
        LocalMetalBootstrap.ensureRegistered()
        guard let engine = LocalMetalRuntime.engine else {
            await LocalMetalDownloadManager.shared.fail(
                modelID: modelID,
                message: "Metal runtime is not linked. Rebuild the iOS app with mlx-swift-lm packages."
            )
            return
        }

        do {
            try await engine.downloadModel(modelID: modelID) { update in
                Task { @MainActor in
                    LocalMetalDownloadManager.shared.noteProgress(modelID: modelID, update: update)
                }
            }
            await LocalMetalModelStore.shared.markDownloaded(modelID: modelID)
            await LocalMetalDownloadManager.shared.succeed(modelID: modelID, appState: appState)
        } catch is CancellationError {
            await LocalMetalDownloadManager.shared.fail(
                modelID: modelID,
                message: "Download was cancelled.",
                clearStatus: true
            )
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            await LocalMetalDownloadManager.shared.fail(modelID: modelID, message: message)
        }
    }

    private func noteProgress(modelID: String, update: LocalMetalDownloadProgress) {
        guard var cur = tracks[modelID], cur.phase == .active else { return }
        let nextFraction = max(cur.fraction, min(1, update.fraction))
        cur.fraction = nextFraction
        cur.status = update.status
        cur.bytesDownloaded = update.bytesDownloaded ?? cur.bytesDownloaded
        cur.bytesTotal = update.bytesTotal ?? cur.bytesTotal
        cur.file = update.file ?? cur.file
        cur.updatedAt = Date()
        tracks[modelID] = cur
        if activeModelID == modelID {
            lastStatus = Self.formatStatus(cur)
        }
    }

    private func succeed(modelID: String, appState: AppState) async {
        if var cur = tracks[modelID] {
            cur.fraction = 1
            cur.status = "Ready"
            cur.phase = .done
            cur.error = nil
            cur.updatedAt = Date()
            tracks[modelID] = cur
        }
        await appState.refreshModels()
        if appState.selectedModel?.provider == .localMetal,
           appState.selectedModel?.modelID == modelID {
            await appState.ensureSelectedLocalMetalLoaded()
        }
        let inPicker = appState.allModels.contains {
            $0.provider == .localMetal && $0.modelID == modelID
        }
        lastStatus = inPicker
            ? "Downloaded — select it in the model picker to load into memory."
            : "Downloaded. Tap “Refresh chat model list” if it isn’t in the picker yet."
        lastError = nil
        clearTask(modelID: modelID)
        // Drop completed banner rows after a short delay (desktop parity).
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if tracks[modelID]?.phase == .done {
                tracks[modelID] = nil
            }
        }
    }

    private func fail(modelID: String, message: String, clearStatus: Bool = false) {
        lastError = message
        if clearStatus { lastStatus = "" }
        if var cur = tracks[modelID] {
            cur.phase = .error
            cur.status = "Failed"
            cur.error = message
            cur.updatedAt = Date()
            tracks[modelID] = cur
        }
        clearTask(modelID: modelID)
    }

    private func clearTask(modelID: String) {
        tasks[modelID] = nil
        if activeModelID == modelID {
            activeModelID = nil
        }
    }

    nonisolated static func formatStatus(_ track: Track) -> String {
        var parts: [String] = [track.status]
        if let down = track.bytesDownloaded, let total = track.bytesTotal, total > 0 {
            parts.append("(\(byteLabel(down)) / \(byteLabel(total)))")
        } else if track.fraction > 0, track.phase == .active {
            parts.append("\(track.percent)%")
        }
        return parts.joined(separator: " ")
    }

    /// Pure formatting — safe off the main actor (used from `Track.detailLine`).
    nonisolated static func byteLabel(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

extension LocalMetalDownloadManager.Track {
    var percent: Int {
        Int((min(1, max(0, fraction)) * 100).rounded(.down))
    }

    var detailLine: String {
        if phase == .error {
            return error ?? "Download failed"
        }
        if let down = bytesDownloaded, let total = bytesTotal, total > 0 {
            return "\(status) · \(LocalMetalDownloadManager.byteLabel(down)) / \(LocalMetalDownloadManager.byteLabel(total))"
        }
        if phase == .active {
            return "\(status) · \(percent)%"
        }
        return status
    }
}
