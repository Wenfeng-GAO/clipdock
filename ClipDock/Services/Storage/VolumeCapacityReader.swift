import Foundation

struct VolumeCapacitySnapshot: Equatable {
    var name: String? = nil
    var totalBytes: Int64? = nil
    var availableBytes: Int64? = nil
}

/// Reads `volumeTotalCapacity` and `volumeAvailableCapacityForImportantUsage`
/// for the volume that contains a URL.
protocol VolumeCapacityReading {
    func snapshot(at url: URL) -> VolumeCapacitySnapshot
}

struct FileVolumeCapacityReader: VolumeCapacityReading {
    func snapshot(at url: URL) -> VolumeCapacitySnapshot {
        let keys: Set<URLResourceKey> = [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey
        ]
        guard let values = try? url.resourceValues(forKeys: keys) else {
            return VolumeCapacitySnapshot()
        }
        let total = values.volumeTotalCapacity.map { Int64($0) }
        return VolumeCapacitySnapshot(
            name: values.volumeName,
            totalBytes: total,
            availableBytes: values.volumeAvailableCapacityForImportantUsage
        )
    }
}
