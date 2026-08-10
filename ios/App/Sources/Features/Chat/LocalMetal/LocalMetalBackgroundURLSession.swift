import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Process-wide **background** `URLSession` for Hugging Face weight downloads.
///
/// Why this exists:
/// - The hub client’s default session pauses when iOS suspends the app.
/// - A background-configured session keeps download tasks moving while the app
///   is suspended, and can relaunch the app when transfers finish.
///
/// Used only for multi‑GB model snapshots. Metadata / listing still use a
/// normal foreground session (background sessions defer data tasks).
final class LocalMetalBackgroundURLSession: NSObject, URLSessionDelegate, @unchecked Sendable {
    static let shared = LocalMetalBackgroundURLSession()

    /// Stable identifier — must match across launches for the system to reconnect.
    static let sessionIdentifier = "app.roamsocket.metal-hub-downloads"

    /// System completion handler from `handleEventsForBackgroundURLSession`.
    var backgroundCompletionHandler: (() -> Void)?

    /// Session for hub file downloads (download tasks continue in the background).
    private(set) lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        // Start promptly — multi‑GB models should not wait for “optimal” conditions.
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.allowsCellularAccess = true
        config.waitsForConnectivity = true
        // Cap concurrency a bit; background transfers share system bandwidth.
        config.httpMaximumConnectionsPerHost = 4
        // Long transfers (timeout is effectively managed by the system for background).
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 60 * 60 * 24 * 2 // 48h wall clock budget
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    private override init() {
        super.init()
    }

    /// Ensure the session exists early (e.g. on background relaunch events).
    func ensureSession() {
        _ = session
    }

    // MARK: - URLSessionDelegate

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        #if canImport(UIKit)
        DispatchQueue.main.async { [weak self] in
            let handler = self?.backgroundCompletionHandler
            self?.backgroundCompletionHandler = nil
            handler?()
        }
        #endif
    }

    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        // Background sessions are long-lived; log only in debug if needed.
        #if DEBUG
        if let error {
            print("[LocalMetalBackgroundURLSession] invalidated: \(error.localizedDescription)")
        }
        #endif
    }
}
