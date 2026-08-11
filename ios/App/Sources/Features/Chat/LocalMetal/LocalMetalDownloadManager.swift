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
/// the long haul — iOS will eventually pause work without a running process.
/// (Hub downloads use a foreground session: `HubClient` relies on
/// completion-handler based async APIs that background URLSessions reject.)
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
        /// When the transfer started — used to compute download rate + ETA.
        var startedAt: Date?
    }

    /// Hub id currently downloading (one at a time on phone).
    @Published private(set) var activeModelID: String?
    /// All tracks (active + recent done/error) for the Downloads banner.
    @Published private(set) var tracks: [String: Track] = [:]
    @Published private(set) var lastError: String?
    @Published private(set) var lastStatus: String = ""

    private var tasks: [String: Task<Void, Never>] = [:]
    /// Always-current track state; `@Published tracks` is a throttled mirror for UI.
    private var workingTracks: [String: Track] = [:]
    /// Throttle SwiftUI publishes — multi‑GB hub ticks can arrive faster than frames.
    private var lastUIPublishAt: [String: Date] = [:]
    private var lastPublishedMB: [String: Int64] = [:]
    #if canImport(UIKit)
    /// Extends runtime briefly when the user leaves the app mid-download.
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    #endif

    /// Persisted hub ids that should resume after relaunch (process kill).
    private static let pendingKey = "localMetal.pendingDownloads.v1"

    private init() {
        // Nothing to warm at init; downloads run on the foreground session.
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
        lastUIPublishAt[modelID] = Date()
        lastPublishedMB[modelID] = 0
        // Seed total from catalog so Gemma E4B (~5.2 GB) etc. show a real
        // denominator before hub listing finishes.
        let catalogTotal = Self.catalogApproxBytes(for: modelID)
        activeModelID = modelID
        let track = Track(
            hubID: modelID,
            displayName: name,
            fraction: 0,
            status: "Listing files…",
            error: nil,
            phase: .active,
            bytesDownloaded: 0,
            bytesTotal: catalogTotal,
            file: nil,
            updatedAt: Date(),
            startedAt: Date()
        )
        workingTracks[modelID] = track
        tracks[modelID] = track
        rememberPending(modelID)
        updateIdleTimer()
        beginBackgroundExecutionIfNeeded()

        // Detached: not a child of the sheet/button task, so dismiss cannot cancel it.
        // Weight bytes use a foreground session (background URLSessions reject
        // HubClient's completion-handler based APIs). Slight defer so the progress
        // banner paints before hub I/O starts.
        let task = Task.detached(priority: .utility) {
            await Task.yield()
            await LocalMetalDownloadManager.runDownload(
                modelID: modelID,
                appState: appState
            )
        }
        tasks[modelID] = task
    }

    /// Fully cancel an active download: the transfer stops, the banner row and
    /// pending marker disappear immediately, and it will not auto-resume. The
    /// partial hub cache stays on disk so a later manual "Download" can resume
    /// from where it stopped.
    func cancel(modelID: String) {
        guard tasks[modelID] != nil else { return }
        tasks[modelID]?.cancel()
        // Drop the track + pending marker now. The cancelled task's `fail`
        // path then finds no track to repopulate and only clears the task slot.
        tracks[modelID] = nil
        workingTracks[modelID] = nil
        forgetPending(modelID)
    }

    /// Retry a failed download by **resuming** the in-place hub transfer
    /// (Range-resumes any partial blobs the HF cache already has on disk).
    /// This is the expected behavior when a connection drops mid-download —
    /// throwing away multi‑GB of partial weights and starting over is wasteful
    /// and often not what the user means by "Retry". If a task is somehow
    /// still in flight it is cancelled and drained before the new one starts.
    ///
    /// Callers that really want a clean redownload (e.g. corruption) should
    /// call `redownloadFromScratch(modelID:appState:displayName:)` instead.
    func retry(modelID: String, appState: AppState, displayName: String? = nil) {
        lastError = nil
        Task { @MainActor in
            tasks[modelID]?.cancel()
            var waitCount = 0
            while tasks[modelID] != nil, waitCount < 50 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                waitCount += 1
            }
            tracks[modelID] = nil
            workingTracks[modelID] = nil
            // Keep the hub cache on disk so HubClient can Range-resume any
            // partial blobs. Only drop the verified-sentinel so a previous
            // (now-stale) "complete" flag is not honored.
            LocalMetalBootstrap.ensureRegistered()
            if let engine = LocalMetalRuntime.engine {
                await engine.invalidateVerifiedSentinel(modelID: modelID)
            }
            start(modelID: modelID, appState: appState, displayName: displayName)
        }
    }

    /// Nuke the partial hub cache and re-download the model from zero. Use
    /// when a resume won't make progress (e.g. corrupted blob, repeated
    /// verification failures). Exposed as a separate flow from `retry` so
    /// the default "Retry" button is the cheap, user-friendly option.
    func redownloadFromScratch(modelID: String, appState: AppState, displayName: String? = nil) {
        lastError = nil
        Task { @MainActor in
            tasks[modelID]?.cancel()
            var waitCount = 0
            while tasks[modelID] != nil, waitCount < 50 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                waitCount += 1
            }
            tracks[modelID] = nil
            workingTracks[modelID] = nil
            forgetPending(modelID)
            LocalMetalBootstrap.ensureRegistered()
            if let engine = LocalMetalRuntime.engine {
                try? await engine.deleteModel(modelID: modelID)
            }
            await LocalMetalModelStore.shared.markDeleted(modelID: modelID)
            start(modelID: modelID, appState: appState, displayName: displayName)
        }
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
            // User-initiated or app-suspension cancellation: do not auto-resume.
            await LocalMetalModelStore.shared.markDeleted(modelID: modelID)
            await LocalMetalDownloadManager.shared.fail(
                modelID: modelID,
                message: "Download was cancelled.",
                clearStatus: true,
                forgetPending: true
            )
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            await LocalMetalDownloadManager.shared.fail(modelID: modelID, message: message)
        }
    }

    // MARK: - System background budget

    /// Keep the screen awake while any model download is in flight so multi‑GB
    /// transfers are not interrupted by the auto-lock idle timer.
    private func updateIdleTimer() {
        #if canImport(UIKit)
        UIApplication.shared.isIdleTimerDisabled = isBusy
        #endif
    }

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
        guard var cur = workingTracks[modelID] ?? tracks[modelID], cur.phase == .active else { return }
        let prevFraction = cur.fraction
        let prevStatus = cur.status
        let prevFile = cur.file

        let nextFraction = max(cur.fraction, min(1, update.fraction))
        let nextDown = update.bytesDownloaded ?? cur.bytesDownloaded
        let nextTotal = update.bytesTotal ?? cur.bytesTotal
        let nextStatus = update.status
        let nextFile = update.file ?? cur.file

        cur.fraction = nextFraction
        cur.status = nextStatus
        cur.bytesDownloaded = nextDown
        cur.bytesTotal = nextTotal
        cur.file = nextFile
        cur.updatedAt = Date()
        // Always keep working state current (even when UI publish is skipped).
        workingTracks[modelID] = cur

        let mb = (nextDown ?? 0) / 1_048_576
        let prevMB = lastPublishedMB[modelID] ?? -1
        let now = Date()
        let lastAt = lastUIPublishAt[modelID] ?? .distantPast
        let statusChanged = nextStatus != prevStatus || nextFile != prevFile
        let fractionJumped = nextFraction >= 1 || nextFraction - prevFraction >= 0.005
        let mbMoved = mb != prevMB
        let timedOut = now.timeIntervalSince(lastAt) >= 0.25
        guard statusChanged || fractionJumped || mbMoved || timedOut || nextFraction >= 1 else {
            return
        }
        tracks[modelID] = cur
        lastUIPublishAt[modelID] = now
        lastPublishedMB[modelID] = mb
        if activeModelID == modelID {
            lastStatus = Self.formatStatus(cur)
        }
    }

    /// Catalog `~5.2 GB` hints so the progress bar has a total before hub listing.
    nonisolated private static func catalogApproxBytes(for modelID: String) -> Int64? {
        let lower = modelID.lowercased()
        let hit = LocalMetalCatalog.recommended.first {
            $0.hubID == modelID || $0.hubID.lowercased() == lower
        } ?? LocalMetalCatalog.registry.first {
            $0.hubID == modelID || $0.hubID.lowercased() == lower
        }
        guard var s = hit?.approxSize.trimmingCharacters(in: .whitespacesAndNewlines),
              !s.isEmpty
        else { return nil }
        if s.hasPrefix("~") { s = String(s.dropFirst()) }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let numberPart = s.prefix(while: { $0.isNumber || $0 == "." || $0 == "," })
        let unitPart = s.dropFirst(numberPart.count).trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = numberPart.replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalized), value > 0 else { return nil }
        if unitPart.hasPrefix("GB") || unitPart.hasPrefix("G") {
            return Int64(value * 1_000_000_000)
        }
        if unitPart.hasPrefix("MB") || unitPart.hasPrefix("M") {
            return Int64(value * 1_000_000)
        }
        return nil
    }

    private func succeed(modelID: String, appState: AppState) async {
        if var cur = workingTracks[modelID] ?? tracks[modelID] {
            cur.fraction = 1
            cur.status = "Ready"
            cur.phase = .done
            cur.error = nil
            cur.updatedAt = Date()
            workingTracks[modelID] = cur
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

    private func fail(modelID: String, message: String, clearStatus: Bool = false, forgetPending: Bool = false) {
        lastError = message
        if clearStatus { lastStatus = "" }
        if forgetPending {
            self.forgetPending(modelID)
        }
        // Keep pending so the user (or next launch) can retry / resume.
        if var cur = workingTracks[modelID] ?? tracks[modelID] {
            cur.phase = .error
            cur.status = "Failed"
            cur.error = message
            cur.updatedAt = Date()
            workingTracks[modelID] = cur
            tracks[modelID] = cur
        }
        clearTask(modelID: modelID)
    }

    private func clearTask(modelID: String) {
        tasks[modelID] = nil
        lastUIPublishAt[modelID] = nil
        lastPublishedMB[modelID] = nil
        // Keep error/done tracks in `tracks` for the banner; drop working buffer.
        if let phase = tracks[modelID]?.phase, phase != .active {
            workingTracks[modelID] = nil
        }
        if activeModelID == modelID {
            activeModelID = nil
        }
        updateIdleTimer()
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
        "Downloading… \(track.percent)%"
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

    /// Downloaded bytes as MB rounded to the nearest tenth (e.g. `456.7 MB`).
    var mbTenthsLabel: String {
        let mb = max(0, Double(bytesDownloaded ?? 0) / 1_048_576)
        return String(format: "%.1f MB", mb)
    }

    /// Estimated time remaining, rounded to the nearest second (e.g. `2m 15s`).
    /// Falls back to nil when bytes/size are unknown or not enough time has elapsed.
    var etaSeconds: Int? {
        guard let startedAt,
              let downloaded = bytesDownloaded, downloaded > 0,
              let total = bytesTotal, total > downloaded
        else { return nil }
        let elapsed = Date().timeIntervalSince(startedAt)
        guard elapsed >= 1 else { return nil }
        let rate = Double(downloaded) / elapsed
        guard rate > 0 else { return nil }
        return Int((Double(total - downloaded) / rate).rounded())
    }

    var etaLabel: String? {
        guard let seconds = etaSeconds else { return nil }
        if seconds < 60 {
            return "\(seconds)s"
        }
        if seconds < 3600 {
            return "\(seconds / 60)m \(seconds % 60)s"
        }
        return "\(seconds / 3600)h \((seconds % 3600) / 60)m"
    }

    /// Right-edge label for an active download: time remaining + MB to the tenth.
    var trailingLabel: String {
        if let eta = etaLabel {
            return "\(eta) · \(mbTenthsLabel)"
        }
        return mbTenthsLabel
    }

    var detailLine: String {
        if phase == .error {
            return error ?? "Download failed"
        }
        if phase == .done {
            return "Ready"
        }
        return "Downloading… \(percent)%"
    }
}
