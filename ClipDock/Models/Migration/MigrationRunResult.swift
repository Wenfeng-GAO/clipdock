import Foundation

struct MigrationItemSuccess: Sendable, Hashable {
    let assetID: String
    let destinationURL: URL
    let bytes: Int64
    /// Source `PHAssetResource` size used for the size check. Nil for results recorded before size verification.
    var sourceBytes: Int64? = nil
}

struct MigrationSizeMismatch: Sendable, Hashable {
    let assetID: String
    let destinationURL: URL
    let expectedBytes: Int64
    let actualBytes: Int64
    /// True when the destination file was missing, so `actualBytes` is not a measured size.
    let fileWasMissing: Bool
}

struct MigrationItemFailure: Sendable, Hashable {
    let assetID: String
    let message: String
}

struct MigrationRunResult: Sendable {
    let successes: [MigrationItemSuccess]
    let failures: [MigrationItemFailure]
    /// Copied files whose destination size did not match the source. These are never deleted.
    var sizeMismatches: [MigrationSizeMismatch] = []

    var successCount: Int { successes.count }
    var failureCount: Int { failures.count }
    var totalCount: Int { successCount + failureCount + sizeMismatches.count }
}
