import Foundation
import Combine
import AnyProvCore

/// Process-wide Metal model downloads.
///
/// Owns the download `Task` so transfers keep running when the Manage models
/// sheet is dismissed. Progress is published for any reopened UI to observe.
@MainActor
final class LocalMetalDownloadManager: ObservableObject {
    static let shared = LocalMetalDownloadManager()

    /// Hub id currently downloading (one at a time).
    @Published private(set) var activeModelID: String?
    /// Monotonic 0…1 progress keyed by hub id.
    @Published private(set) var progressByID: [String: Double] = [:]
    @Published private(set) var lastError: String?
    @Published private(set) var lastStatus: String = ""

    private var tasks: [String: Task<Void, Never>] = [:]

    private init() {}

    var isBusy: Bool { activeModelID != nil }

    func progress(for modelID: String) -> Double? {
        guard activeModelID == modelID else { return nil }
        return progressByID[modelID]
    }

    /// Start (or no-op if already running) a download that outlives the settings sheet.
    func start(modelID: String, appState: AppState) {
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

        lastError = nil
        lastStatus = "Downloading in the background…"
        activeModelID = modelID
        progressByID[modelID] = 0

        // Detached: not a child of the sheet/button task, so dismiss cannot cancel it.
        // Hub I/O runs off the main actor; progress/UI hop back via noteProgress.
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
            try await engine.downloadModel(modelID: modelID) { fraction in
                Task { @MainActor in
                    LocalMetalDownloadManager.shared.noteProgress(modelID: modelID, fraction: fraction)
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

    private func noteProgress(modelID: String, fraction: Double) {
        let previous = progressByID[modelID] ?? 0
        guard fraction > previous else { return }
        progressByID[modelID] = fraction
        if activeModelID == modelID {
            let pct = Int((fraction * 100).rounded(.down))
            lastStatus = pct > 0
                ? "Downloading in the background… \(pct)%"
                : "Downloading in the background…"
        }
    }

    private func succeed(modelID: String, appState: AppState) async {
        progressByID[modelID] = 1
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
    }

    private func fail(modelID: String, message: String, clearStatus: Bool = false) {
        lastError = message
        if clearStatus { lastStatus = "" }
        clearTask(modelID: modelID)
    }

    private func clearTask(modelID: String) {
        tasks[modelID] = nil
        if activeModelID == modelID {
            activeModelID = nil
        }
    }
}
