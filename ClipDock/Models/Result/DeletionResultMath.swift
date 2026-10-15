import Foundation

/// Bytes that stay occupied until the user empties Recently Deleted.
struct PendingReleaseTotal: Equatable, Sendable {
    let bytes: Int64

    init(itemBytes: [Int64]) {
        bytes = itemBytes.reduce(0, +)
    }
}

/// Checklist and pending-release figures for one deletion.
struct DeletionResultSnapshot: Equatable, Sendable {
    let copiedCount: Int
    /// Size-checked items that matched (numerator of “N/M match”).
    let verifiedMatchCount: Int
    /// Copied items that were size-checked (denominator): verified + mismatch.
    let verifiedTotalCount: Int
    let pendingReleaseBytes: Int64

    init(
        copiedCount: Int,
        verifiedMatchCount: Int,
        verifiedTotalCount: Int,
        pendingReleaseBytes: Int64
    ) {
        self.copiedCount = copiedCount
        self.verifiedMatchCount = verifiedMatchCount
        self.verifiedTotalCount = verifiedTotalCount
        self.pendingReleaseBytes = pendingReleaseBytes
    }

    /// Legacy path with no per-file copy session. Every success was copied, checked, and deleted.
    init(deletedSuccesses: [MigrationItemSuccess]) {
        let count = deletedSuccesses.count
        self.init(
            copiedCount: count,
            verifiedMatchCount: count,
            verifiedTotalCount: count,
            pendingReleaseBytes: PendingReleaseTotal(itemBytes: deletedSuccesses.map(\.bytes)).bytes
        )
    }
}

extension PendingReleaseTotal {
    /// Bytes of the items actually deleted.
    /// Copy-item display size wins (same figure as the delete button). A success row fills an id that is not in `items`.
    static func releasedBytes(
        deletableAssetIDs: [String],
        items: [CopyItemState],
        successes: [MigrationItemSuccess]
    ) -> Int64 {
        var itemBytes: [String: Int64] = [:]
        itemBytes.reserveCapacity(items.count)
        for item in items where itemBytes[item.assetID] == nil {
            itemBytes[item.assetID] = item.displayBytes
        }

        var successBytes: [String: Int64] = [:]
        successBytes.reserveCapacity(successes.count)
        for success in successes where successBytes[success.assetID] == nil {
            successBytes[success.assetID] = success.bytes
        }

        var total: Int64 = 0
        for id in deletableAssetIDs {
            if let bytes = itemBytes[id] {
                total += bytes
            } else if let bytes = successBytes[id] {
                total += bytes
            }
        }
        return total
    }
}

enum FreedSpaceDelta {
    /// Free-space increase to show. Zero and negative deltas are not shown.
    static func freedBytes(before: Int64, after: Int64) -> Int64? {
        let (delta, overflow) = after.subtractingReportingOverflow(before)
        guard !overflow, delta > 0 else { return nil }
        return delta
    }
}

enum FreedSpaceTolerance {
    /// `true` when `expected > 0` and `|freed - expected| <= tolerance * expected` (inclusive).
    /// At the default 5%, 95% and 105% are inside; 94.9% and 105.1% are outside.
    static func withinTolerance(freed: Int64, expected: Int64, tolerance: Double = 0.05) -> Bool {
        guard expected > 0 else { return false }
        let difference = abs(Double(freed) - Double(expected))
        return difference <= tolerance * Double(expected)
    }
}

enum ReviewPromptPolicy {
    /// Ask once per result, and only when the measured free-space delta is within tolerance.
    static func shouldRequestReview(withinTolerance: Bool, alreadyRequested: Bool) -> Bool {
        withinTolerance && !alreadyRequested
    }
}
