import Foundation
import AnyProvCore

/// Bootstrap for on-device Metal chat.
///
/// Coding sessions never use this path (`ProviderID.localMetal.supportsCodingAgent == false`).
/// Models are never bundled — users download them in Settings.
enum LocalMetalBootstrap {
    /// Call from app launch (and again before Metal chat if needed).
    static func register() {
        if LocalMetalRuntime.engine != nil { return }
        LocalMetalMLXBackend.register()
        LocalMetalRuntime.engine = LocalMetalMLXBackend.shared
        assert(
            LocalMetalRuntime.engine != nil,
            "LocalMetalMLXBackend.register() must set shared engine"
        )
    }

    /// Force re-bind even if a nil engine was left behind.
    static func ensureRegistered() {
        if LocalMetalRuntime.engine == nil {
            LocalMetalMLXBackend.register()
            LocalMetalRuntime.engine = LocalMetalMLXBackend.shared
        }
    }
}
