import Foundation

/// Per-file state while a batch is copied to external storage and then size-checked.
enum CopyFileStatus: Equatable, Sendable {
    case pending
    case copying
    case verified
    case mismatch(expected: Int64, actual: Int64)
    case failed(String)

    var isFinished: Bool {
        switch self {
        case .pending, .copying:
            return false
        case .verified, .mismatch, .failed:
            return true
        }
    }

    var isVerified: Bool {
        if case .verified = self { return true }
        return false
    }

    var isMismatch: Bool {
        if case .mismatch = self { return true }
        return false
    }
}

struct CopyItemState: Equatable, Sendable, Identifiable {
    let assetID: String
    var displayName: String
    var expectedBytes: Int64
    var actualBytes: Int64?
    var destinationURL: URL?
    var status: CopyFileStatus

    var id: String { assetID }

    /// Size shown on the row. Prefer the source size; fall back to whatever was measured.
    var displayBytes: Int64 {
        if expectedBytes > 0 { return expectedBytes }
        return max(actualBytes ?? 0, 0)
    }

    init(
        assetID: String,
        displayName: String? = nil,
        expectedBytes: Int64 = 0,
        actualBytes: Int64? = nil,
        destinationURL: URL? = nil,
        status: CopyFileStatus
    ) {
        self.assetID = assetID
        self.displayName = displayName ?? assetID
        self.expectedBytes = expectedBytes
        self.actualBytes = actualBytes
        self.destinationURL = destinationURL
        self.status = status
    }
}

struct MigrationFileSnapshot: Equatable, Sendable {
    let assetID: String
    var displayName: String
    var expectedBytes: Int64
    var actualBytes: Int64?
    var destinationURL: URL?
    var status: CopyFileStatus
}

/// Outcome of comparing a destination file's size with the source size.
enum SizeVerificationResult: Equatable, Sendable {
    case match(bytes: Int64)
    case mismatch(expected: Int64, actual: Int64)
    case missingFile(expected: Int64)
}

protocol CopySizeVerifying: Sendable {
    func verify(expectedBytes: Int64, at destinationURL: URL) -> SizeVerificationResult
}

/// Compares the copied file's `FileManager` size with the source byte count.
struct CopySizeVerifier: CopySizeVerifying, Sendable {
    func verify(expectedBytes: Int64, at destinationURL: URL) -> SizeVerificationResult {
        Self.compare(expectedBytes: expectedBytes, actualBytes: destinationFileSizeBytes(at: destinationURL))
    }

    /// `nil` when the path is missing or its size cannot be read.
    func destinationFileSizeBytes(at url: URL) -> Int64? {
        let path = url.path
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        if let number = attributes[.size] as? NSNumber {
            return number.int64Value
        }
        if let number = attributes[.size] as? Int64 {
            return number
        }
        if let number = attributes[.size] as? Int {
            return Int64(number)
        }
        return nil
    }

    static func compare(expectedBytes: Int64, actualBytes: Int64?) -> SizeVerificationResult {
        guard let actualBytes else {
            return .missingFile(expected: expectedBytes)
        }
        if actualBytes == expectedBytes {
            return .match(bytes: actualBytes)
        }
        return .mismatch(expected: expectedBytes, actual: actualBytes)
    }

    /// Missing files are mismatches so they stay out of the deletable set and can be re-copied.
    static func status(for result: SizeVerificationResult) -> CopyFileStatus {
        switch result {
        case .match:
            return .verified
        case .mismatch(let expected, let actual):
            return .mismatch(expected: expected, actual: actual)
        case .missingFile(let expected):
            return .mismatch(expected: expected, actual: 0)
        }
    }
}

struct CopyDeletionEligibility: Equatable, Sendable {
    let isVerificationComplete: Bool
    let deletableAssetIDs: [String]
    let deletableBytes: Int64
    let verifiedCount: Int
    let mismatchCount: Int

    var isDeleteEnabled: Bool {
        isVerificationComplete && !deletableAssetIDs.isEmpty
    }
}

/// Decides which copied originals may be deleted, and which files a re-copy should target.
enum CopyDeletionPolicy {
    static func eligibility(for items: [CopyItemState]) -> CopyDeletionEligibility {
        let isVerificationComplete = !items.isEmpty && items.allSatisfy { $0.status.isFinished }
        let verified = items.filter { $0.status.isVerified }
        let mismatchCount = items.reduce(0) { partial, item in
            item.status.isMismatch ? partial + 1 : partial
        }
        let deletable = isVerificationComplete ? verified : []
        let deletableBytes = deletable.reduce(Int64(0)) { $0 + $1.displayBytes }
        return CopyDeletionEligibility(
            isVerificationComplete: isVerificationComplete,
            deletableAssetIDs: deletable.map(\.assetID),
            deletableBytes: deletableBytes,
            verifiedCount: verified.count,
            mismatchCount: mismatchCount
        )
    }

    /// Re-copy is only the files whose size did not match. Pending, copying, verified, and failed items are excluded.
    static func mismatchAssetIDs(in items: [CopyItemState]) -> [String] {
        items.compactMap { item in
            item.status.isMismatch ? item.assetID : nil
        }
    }
}

struct CopySessionStats: Equatable, Sendable {
    let numerator: Int
    let totalCount: Int
    let copiedBytes: Int64
    let totalBytes: Int64
    let inProgressFraction: Double
    let verifiedFraction: Double
    let mismatchFraction: Double
    let eligibility: CopyDeletionEligibility

    static func make(items: [CopyItemState], isMigrating: Bool) -> CopySessionStats {
        let eligibility = CopyDeletionPolicy.eligibility(for: items)
        let totalCount = items.count
        let started = items.filter { item in
            if case .pending = item.status { return false }
            return true
        }.count
        let numerator = isMigrating ? started : eligibility.verifiedCount
        let totalBytes = items.reduce(Int64(0)) { $0 + $1.displayBytes }
        let verifiedBytes = items.reduce(Int64(0)) { partial, item in
            item.status.isVerified ? partial + item.displayBytes : partial
        }
        let mismatchBytes = items.reduce(Int64(0)) { partial, item in
            item.status.isMismatch ? partial + item.displayBytes : partial
        }
        let copiedBytes = items.reduce(Int64(0)) { partial, item in
            switch item.status {
            case .verified:
                return partial + item.displayBytes
            case .mismatch(_, let actual):
                return partial + max(0, actual)
            default:
                return partial
            }
        }

        let inProgressFraction = fraction(part: started, wholeCount: totalCount)
        let verifiedFraction: Double
        let mismatchFraction: Double
        if totalBytes > 0 {
            verifiedFraction = clamp(Double(verifiedBytes) / Double(totalBytes))
            mismatchFraction = clamp(Double(mismatchBytes) / Double(totalBytes))
        } else {
            verifiedFraction = fraction(part: eligibility.verifiedCount, wholeCount: totalCount)
            mismatchFraction = fraction(part: eligibility.mismatchCount, wholeCount: totalCount)
        }

        return CopySessionStats(
            numerator: numerator,
            totalCount: totalCount,
            copiedBytes: copiedBytes,
            totalBytes: totalBytes,
            inProgressFraction: inProgressFraction,
            verifiedFraction: verifiedFraction,
            mismatchFraction: mismatchFraction,
            eligibility: eligibility
        )
    }

    private static func fraction(part: Int, wholeCount: Int) -> Double {
        guard wholeCount > 0 else { return 0 }
        return clamp(Double(part) / Double(wholeCount))
    }

    private static func clamp(_ value: Double) -> Double {
        min(1, max(0, value))
    }
}

enum ByteCountText {
    static func string(fromBytes bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
