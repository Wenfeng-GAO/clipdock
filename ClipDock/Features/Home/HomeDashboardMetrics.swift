import Foundation

enum NumberText {
    static func grouped(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}

struct HomeLibrarySummary: Equatable {
    static let defaultTopN = 20

    var videoCount: Int
    var reclaimableBytes: Int64
    var topN: Int
    var topNBytes: Int64
    var topNSelectedCount: Int

    static func make(
        videos: [VideoAssetSummary],
        sizesBytesByID: [String: Int64],
        topN: Int = defaultTopN,
        rules: SelectionRulesServicing
    ) -> HomeLibrarySummary {
        var reclaimable: Int64 = 0
        for video in videos {
            if let bytes = sizesBytesByID[video.id], bytes > 0 {
                reclaimable += bytes
            }
        }

        let topIDs = rules.topNAssetIDsBySize(
            n: topN,
            videos: videos,
            sizesBytesByID: sizesBytesByID
        )
        var topBytes: Int64 = 0
        for id in topIDs {
            if let bytes = sizesBytesByID[id], bytes > 0 {
                topBytes += bytes
            }
        }

        return HomeLibrarySummary(
            videoCount: videos.count,
            reclaimableBytes: reclaimable,
            topN: topN,
            topNBytes: topBytes,
            topNSelectedCount: topIDs.count
        )
    }

    var headlineText: String {
        ByteCountText.storage(reclaimableBytes)
    }

    var sublineText: String {
        L10n.tr(
            "%@ videos · largest %d use %@",
            NumberText.grouped(videoCount),
            topN,
            ByteCountText.storage(topNBytes)
        )
    }
}

struct StorageBarFractions: Equatable {
    var videos: Double
    var other: Double
    var available: Double

    static let zero = StorageBarFractions(videos: 0, other: 0, available: 0)

    var sum: Double { videos + other + available }

    /// Clamps video and available bytes onto `totalBytes` so the three parts are
    /// non-negative and add up to the device capacity.
    static func clampedBytes(
        videoBytes: Int64,
        totalBytes: Int64,
        availableBytes: Int64
    ) -> (videos: Int64, other: Int64, available: Int64) {
        guard totalBytes > 0 else { return (0, 0, 0) }
        let available = min(max(availableBytes, 0), totalBytes)
        let videos = min(max(videoBytes, 0), totalBytes - available)
        let other = totalBytes - videos - available
        return (videos, other, available)
    }

    static func make(videoBytes: Int64, totalBytes: Int64?, availableBytes: Int64?) -> StorageBarFractions {
        guard let totalBytes, totalBytes > 0, let availableBytes else {
            return zero
        }
        let parts = clampedBytes(
            videoBytes: videoBytes,
            totalBytes: totalBytes,
            availableBytes: availableBytes
        )
        let total = Double(totalBytes)
        var videos = Double(parts.videos) / total
        var available = Double(parts.available) / total
        var other = max(0, 1 - videos - available)
        let sum = videos + other + available
        if sum > 1 {
            let excess = sum - 1
            if other >= excess {
                other -= excess
            } else if videos >= excess {
                videos -= excess
            } else {
                available = max(0, available - excess)
            }
        }
        return StorageBarFractions(videos: videos, other: other, available: available)
    }

    static func byteText(_ bytes: Int64?) -> String {
        guard let bytes else { return L10n.tr("Capacity Unknown") }
        return ByteCountText.storage(bytes)
    }

    static func legend(availableBytes: Int64?, totalBytes: Int64?) -> String {
        L10n.tr(
            "■ Videos  ■ Other  ■ Available %@ / %@",
            byteText(availableBytes),
            byteText(totalBytes)
        )
    }
}

enum DriveStatusFormatter {
    static func title(volumeName: String?, folderURL: URL?) -> String {
        guard let folderURL else {
            return L10n.tr("USB Drive")
        }
        let trimmed = volumeName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name = trimmed.isEmpty ? folderURL.lastPathComponent : trimmed
        if name.isEmpty {
            return L10n.tr("USB Drive")
        }
        return L10n.tr("USB Drive · %@", name)
    }

    static func statusLine(isWritable: Bool, freeBytes: Int64?) -> String {
        if let freeBytes {
            let size = ByteCountText.storage(freeBytes)
            if isWritable {
                return L10n.tr("Writable ✓ · %@ free", size)
            }
            return L10n.tr("Not writable · %@ free", size)
        }
        return isWritable ? L10n.tr("Writable ✓") : L10n.tr("Not writable")
    }
}
