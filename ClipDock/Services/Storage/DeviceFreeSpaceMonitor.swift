import Foundation

/// Free capacity of the device volume, in bytes.
@MainActor
protocol DeviceFreeSpaceMeasuring {
    func availableCapacityBytes() -> Int64?
}

/// Samples the home-volume capacity the user can actually use.
/// Both readings use the same key so the before/after delta is comparable.
@MainActor
struct DeviceFreeSpaceMonitor: DeviceFreeSpaceMeasuring {
    func availableCapacityBytes() -> Int64? {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        let important = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let bytes = important?.volumeAvailableCapacityForImportantUsage {
            return bytes
        }
        let fallback = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        if let bytes = fallback?.volumeAvailableCapacity {
            return Int64(bytes)
        }
        return nil
    }
}
