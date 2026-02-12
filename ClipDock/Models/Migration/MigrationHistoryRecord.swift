import Foundation

struct MigrationHistoryItem: Codable, Hashable {
    enum Status: String, Codable {
        case success
        case failure
    }

    var assetID: String
    var status: Status
    var destinationRelativePath: String?
    var bytes: Int64?
    var errorMessage: String?
}

struct MigrationHistoryRecord: Codable, Identifiable, Hashable {
    var id: UUID
    var startedAt: Date
    var finishedAt: Date
    var targetFolderPath: String
    var successes: Int
    var failures: Int
    var items: [MigrationHistoryItem]

    var total: Int { successes + failures }
}
