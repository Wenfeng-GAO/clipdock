import XCTest
@testable import ClipDock

final class MigrationHistoryStoreTests: XCTestCase {
    func testAppendAndLoadHonorsMaxRecords() throws {
        let store = MigrationHistoryStore(maxRecords: 3)
        try? store.clear()
        defer { try? store.clear() }

        func record(_ n: Int) -> MigrationHistoryRecord {
            MigrationHistoryRecord(
                id: UUID(),
                startedAt: Date(timeIntervalSince1970: TimeInterval(n)),
                finishedAt: Date(timeIntervalSince1970: TimeInterval(n + 1)),
                targetFolderPath: "target-\(n)",
                successes: n,
                failures: 0,
                items: []
            )
        }

        try store.append(record(1))
        try store.append(record(2))
        try store.append(record(3))
        try store.append(record(4))

        let loaded = try store.load()
        XCTAssertEqual(loaded.count, 3)
        XCTAssertEqual(loaded[0].targetFolderPath, "target-4")
        XCTAssertEqual(loaded[1].targetFolderPath, "target-3")
        XCTAssertEqual(loaded[2].targetFolderPath, "target-2")
    }
}

