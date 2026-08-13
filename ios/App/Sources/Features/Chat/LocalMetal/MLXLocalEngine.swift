import Foundation
import AnyProvCore
import os

private let log = Logger(subsystem: "app.roamsocket.app", category: "LocalMetalBootstrap")

/// Bootstrap for on-device Metal chat.
///
/// Coding sessions never use this path (`ProviderID.localMetal.supportsCodingAgent == false`).
/// Models are never bundled — users download them in Settings.
enum LocalMetalBootstrap {
    /// True iff at least one `ensureRegistered` call was rejected by the
    /// Metal probe — meaning the device can't host on-device VLMs in this
    /// session but cloud-provider chat still works fine. Exposed so
    /// Settings can show a one-line hint without falsely claiming
    /// "Metal runtime not linked."
    nonisolated(unsafe) static var lastRegistrationFailed: Bool = false

    /// Call from app launch (and again before Metal chat if needed).
    static func register() {
        if LocalMetalRuntime.engine != nil { return }
        LocalMetalMLXBackend.register()
        LocalMetalRuntime.engine = LocalMetalMLXBackend.shared
    }

    /// Force re-bind even if a nil engine was left behind.
    ///
    /// **Crash-safety:** `LocalMetalMLXBackend.register()` ends up calling
    /// `MLX.Memory.cacheLimit = …`, which goes through `mlx_set_cache_limit`
    /// in `mlx-swift` C++. On simulators where `MTLCreateSystemDefaultDevice()`
    /// returns a device whose `name` is nil (iOS 26.5 sim on Mac17,4-class
    /// Apple Silicon and similar), the C++ `basic_string(const char*)`
    /// constructor triggers `__libcpp_verbose_abort` → uncatchable `SIGABRT`
    /// that kills the app during `RoamSocketApp.init()`. The probe in
    /// `Engine.init()` rejects the bind before that happens.
    ///
    /// We *do not* try to wrap the bind in `autoreleasepool` or `try` —
    /// SIGABRT isn't an Obj-C exception and won't be caught. The gate
    /// must happen *inside* `Engine.init()`, before any MLX API call.
    static func ensureRegistered() {
        if LocalMetalRuntime.engine != nil { return }
        if lastRegistrationFailed { return }

        LocalMetalMLXBackend.register()
        LocalMetalRuntime.engine = LocalMetalMLXBackend.shared

        if LocalMetalRuntime.engine == nil {
            lastRegistrationFailed = true
            log.error("LocalMetalMLXBackend.register() returned no engine — on-device VLM disabled for this session; cloud chat still works.")
        }
    }

    /// Reset the failure latch — call this when the user reinstalls the
    /// package, switches simulator runtimes, or otherwise wants a fresh
    /// probe (e.g. Settings → On-device Metal has a "Retry" button).
    static func retryRegistration() {
        lastRegistrationFailed = false
        LocalMetalRuntime.engine = nil
        ensureRegistered()
    }
}
