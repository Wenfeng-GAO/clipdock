import Foundation

struct LastMigrationSummary: Codable, Equatable, Sendable {
    var date: Date
    var copiedCount: Int
    var verifiedCount: Int
    var totalCount: Int
}

protocol LastMigrationSummaryStoring {
    func load() -> LastMigrationSummary?
    func save(_ summary: LastMigrationSummary)
}

/// Persists the latest finished migration so the home card survives relaunch.
final class LastMigrationSummaryStore: LastMigrationSummaryStoring {
    static let defaultKey = "clipdock.lastMigrationSummary"

    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = LastMigrationSummaryStore.defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    func load() -> LastMigrationSummary? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? PropertyListDecoder().decode(LastMigrationSummary.self, from: data)
    }

    func save(_ summary: LastMigrationSummary) {
        guard let data = try? PropertyListEncoder().encode(summary) else { return }
        defaults.set(data, forKey: key)
    }
}
