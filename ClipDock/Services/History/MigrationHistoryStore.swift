import Foundation

protocol MigrationHistoryStoring {
    func load() throws -> [MigrationHistoryRecord]
    func append(_ record: MigrationHistoryRecord) throws
    func clear() throws
}

final class MigrationHistoryStore: MigrationHistoryStoring {
    private let fileURL: URL
    private let maxRecords: Int

    init(maxRecords: Int = 20) {
        self.maxRecords = maxRecords

        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        self.fileURL = base.appendingPathComponent("migration_history.json")
    }

    func load() throws -> [MigrationHistoryRecord] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([MigrationHistoryRecord].self, from: data)
    }

    func append(_ record: MigrationHistoryRecord) throws {
        var records = (try? load()) ?? []
        records.insert(record, at: 0)
        if records.count > maxRecords {
            records = Array(records.prefix(maxRecords))
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(records)
        try data.write(to: fileURL, options: [.atomic])
    }

    func clear() throws {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }
}
