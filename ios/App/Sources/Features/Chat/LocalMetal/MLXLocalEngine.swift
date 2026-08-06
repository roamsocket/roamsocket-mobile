import Foundation
import AnyProvCore

/// Bootstrap for on-device Metal chat.
///
/// Coding sessions never use this path (`ProviderID.localMetal.supportsCodingAgent == false`).
enum LocalMetalBootstrap {
    /// Call from app launch so chat can use on-device models.
    static func register() {
        LocalMetalMLXBackend.register()
        LocalMetalRuntime.engine = LocalMetalMLXBackend.shared
    }
}
