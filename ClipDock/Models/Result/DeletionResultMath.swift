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

/// Result-page reading of measured free space against the bytes moved to Recently Deleted.
enum FreedSpaceResultState: Equatable {
    /// No positive system-storage drop yet. `expectedBytes` is the deletable total.
    case pendingRelease(expectedBytes: Int64)
    case freedWithinTolerance(freedBytes: Int64)
    case freedOutsideTolerance(freedBytes: Int64, expectedBytes: Int64)

    /// Nil, zero, and negative measurements stay pending.
    /// A positive measurement reuses `FreedSpaceTolerance.withinTolerance` (false when `expectedBytes <= 0`).
    static func resolve(
        expectedBytes: Int64,
        measuredFreedBytes: Int64?,
        tolerance: Double = 0.05
    ) -> FreedSpaceResultState {
        guard let measuredFreedBytes, measuredFreedBytes > 0 else {
            return .pendingRelease(expectedBytes: expectedBytes)
        }
        if FreedSpaceTolerance.withinTolerance(
            freed: measuredFreedBytes,
            expected: expectedBytes,
            tolerance: tolerance
        ) {
            return .freedWithinTolerance(freedBytes: measuredFreedBytes)
        }
        return .freedOutsideTolerance(freedBytes: measuredFreedBytes, expectedBytes: expectedBytes)
    }

    /// Line under the pending card. Nil until a positive measurement. Only the within-tolerance line includes ✓.
    var freedStatusText: String? {
        switch self {
        case .pendingRelease:
            return nil
        case .freedWithinTolerance(let freedBytes):
            return L10n.tr("Back · Freed %@ ✓", ByteCountText.string(fromBytes: freedBytes))
        case .freedOutsideTolerance(let freedBytes, let expectedBytes):
            return L10n.tr(
                "Freed %@ (est. %@)",
                ByteCountText.string(fromBytes: freedBytes),
                ByteCountText.string(fromBytes: expectedBytes)
            )
        }
    }
}

enum ReviewPromptPolicy {
    /// Ask once per result, and only when the measured free-space delta is within tolerance.
    static func shouldRequestReview(withinTolerance: Bool, alreadyRequested: Bool) -> Bool {
        withinTolerance && !alreadyRequested
    }
}
