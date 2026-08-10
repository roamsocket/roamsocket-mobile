import Foundation
import Combine
import AnyProvCore
#if canImport(UIKit)
import UIKit
#endif

/// Process-wide Metal model downloads with desktop-style step progress.
///
/// Owns the download `Task` so transfers keep running when the Manage models
/// sheet is dismissed. Progress (fraction + status + bytes) is published for
/// any reopened UI to observe.
///
/// **Background:** downloads continue after leaving Settings (in-process
/// detached task) and request a short system background budget when the app
/// is suspended. Multi‑GB hub transfers still need the app to stay alive for
/// the long haul — iOS will eventually pause non–background-URLSession work.
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
    #if canImport(UIKit)
    /// Extends runtime briefly when the user leaves the app mid-download.
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    #endif

    /// Persisted hub ids that should resume after relaunch (process kill).
    private static let pendingKey = "localMetal.pendingDownloads.v1"

    private init() {
        // Reconnect the system background session as early as possible.
        LocalMetalBackgroundURLSession.shared.ensureSession()
    }

    var isBusy: Bool { activeModelID != nil }

    /// Hub ids still marked incomplete after a previous session (for auto-resume).
    var pendingDownloadIDs: [String] {
        UserDefaults.standard.stringArray(forKey: Self.pendingKey) ?? []
    }

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
        rememberPending(modelID)
        LocalMetalBackgroundURLSession.shared.ensureSession()
        beginBackgroundExecutionIfNeeded()

        // Detached: not a child of the sheet/button task, so dismiss cannot cancel it.
        // Weight bytes use a background URLSession so transfers continue while suspended.
        let task = Task.detached(priority: .utility) {
            await LocalMetalDownloadManager.runDownload(
                modelID: modelID,
                appState: appState
            )
        }
        tasks[modelID] = task
    }

    /// After a cold launch, resume any incomplete hub downloads (Range-resumes blobs).
    /// Safe to call multiple times; no-ops when already busy or nothing pending.
    func resumePendingDownloadsIfNeeded(appState: AppState) {
        guard activeModelID == nil, tasks.isEmpty else { return }
        let pending = pendingDownloadIDs
        guard let first = pending.first else { return }
        // Only resume if weights are not already usable on disk.
        Task { @MainActor in
            if await LocalMetalModelStore.shared.isDownloaded(modelID: first) {
                forgetPending(first)
                // Try the next pending id if any.
                resumePendingDownloadsIfNeeded(appState: appState)
                return
            }
            lastStatus = "Resuming background download…"
            start(modelID: first, appState: appState)
        }
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

    // MARK: - System background budget

    /// Ask iOS for extra time when the app is backgrounded so multi‑GB hub
    /// transfers can keep moving for a short window (not unlimited).
    private func beginBackgroundExecutionIfNeeded() {
        #if canImport(UIKit)
        guard backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "LocalMetalModelDownload") { [weak self] in
            Task { @MainActor in
                self?.endBackgroundExecution()
            }
        }
        #endif
    }

    private func endBackgroundExecution() {
        #if canImport(UIKit)
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
        #endif
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
        forgetPending(modelID)
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
            // Chain the next pending model (one-at-a-time on phone).
            resumePendingDownloadsIfNeeded(appState: appState)
        }
    }

    private func fail(modelID: String, message: String, clearStatus: Bool = false) {
        lastError = message
        if clearStatus { lastStatus = "" }
        // Keep pending so the user (or next launch) can retry / resume.
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
        // Release the system background budget once nothing is in flight.
        if tasks.isEmpty {
            endBackgroundExecution()
        }
    }

    private func rememberPending(_ modelID: String) {
        var ids = pendingDownloadIDs
        if !ids.contains(modelID) {
            ids.append(modelID)
            UserDefaults.standard.set(ids, forKey: Self.pendingKey)
        }
    }

    private func forgetPending(_ modelID: String) {
        var ids = pendingDownloadIDs
        ids.removeAll { $0 == modelID }
        if ids.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.pendingKey)
        } else {
            UserDefaults.standard.set(ids, forKey: Self.pendingKey)
        }
    }

    nonisolated static func formatStatus(_ track: Track) -> String {
        var parts: [String] = [track.status]
        if let progress = track.mbProgressLabel {
            parts.append("(\(progress))")
        }
        return parts.joined(separator: " ")
    }

    /// Whole-megabyte label so progress UI does not thrash on every byte tick.
    /// (e.g. `412 MB` instead of `431,204,112 bytes` / `411.8 MB` / `412.1 MB`).
    nonisolated static func byteLabel(_ bytes: Int64) -> String {
        let mb = max(0, bytes / 1_048_576)
        return "\(mb) MB"
    }
}

extension LocalMetalDownloadManager.Track {
    var percent: Int {
        Int((min(1, max(0, fraction)) * 100).rounded(.down))
    }

    /// Stable `downloaded / total` in whole MB, or nil when size is unknown.
    var mbProgressLabel: String? {
        if let down = bytesDownloaded, let total = bytesTotal, total > 0 {
            return "\(LocalMetalDownloadManager.byteLabel(down)) / \(LocalMetalDownloadManager.byteLabel(total))"
        }
        if let down = bytesDownloaded, down > 0 {
            return LocalMetalDownloadManager.byteLabel(down)
        }
        return nil
    }

    var detailLine: String {
        if phase == .error {
            return error ?? "Download failed"
        }
        if let progress = mbProgressLabel {
            return "\(status) · \(progress)"
        }
        // No byte totals yet (listing files / connecting) — avoid a ticking %.
        return status
    }
}
