import Foundation

struct MigrationItemSuccess: Sendable, Hashable {
    let assetID: String
    let destinationURL: URL
    let bytes: Int64
}

struct MigrationItemFailure: Sendable, Hashable {
    let assetID: String
    let message: String
}

struct MigrationRunResult: Sendable {
    let successes: [MigrationItemSuccess]
    let failures: [MigrationItemFailure]

    var successCount: Int { successes.count }
    var failureCount: Int { failures.count }
    var totalCount: Int { successCount + failureCount }
}
