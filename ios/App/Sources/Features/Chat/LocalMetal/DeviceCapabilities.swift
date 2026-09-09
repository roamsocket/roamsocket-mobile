import Foundation

/// Lightweight wrapper around device hardware info used for on-device model
/// compatibility checks. All properties are static — no instance state.
enum DeviceCapabilities {
    /// Total physical RAM on this device in bytes.
    static let physicalMemoryBytes: UInt64 = {
        ProcessInfo.processInfo.physicalMemory
    }()

    /// Total physical RAM in gigabytes (rounded up to nearest integer).
    static let physicalMemoryGB: Int = {
        let bytes = ProcessInfo.processInfo.physicalMemory
        return Int(ceil(Double(bytes) / 1_073_741_824)) // 1024³
    }()

    /// Rough estimate of RAM available for a model after subtracting OS + app
    /// overhead. Uses ~40 % of physical RAM as a conservative upper bound for
    /// the MLX working set (iOS keeps a large portion for system services).
    static var availableForModelBytes: UInt64 {
        UInt64(Double(physicalMemoryBytes) * 0.40)
    }

    /// Human-readable device RAM summary, e.g. "8 GB".
    static var ramSummary: String {
        "\(physicalMemoryGB) GB"
    }
}
