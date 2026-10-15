import XCTest
@testable import ClipDock

final class LastMigrationSummaryTextTests: XCTestCase {
    func testLineWhenEveryFileVerified() {
        let calendar = makeUTCCalendar()
        let summary = LastMigrationSummary(
            date: makeDate(year: 2026, month: 10, day: 12, calendar: calendar),
            copiedCount: 12,
            verifiedCount: 12,
            totalCount: 12
        )

        XCTAssertEqual(
            LastMigrationSummaryText.line(for: summary, calendar: calendar, locale: Locale(identifier: "en_US_POSIX")),
            "10/12 · \(L10n.tr("%d videos", summary.copiedCount)) · \(L10n.tr("Size verified"))"
        )
    }

    func testLineWhenSizesDoNotAllMatch() {
        let calendar = makeUTCCalendar()
        let summary = LastMigrationSummary(
            date: makeDate(year: 2026, month: 10, day: 12, calendar: calendar),
            copiedCount: 11,
            verifiedCount: 9,
            totalCount: 12
        )
        let mismatches = summary.totalCount - summary.verifiedCount

        XCTAssertEqual(
            LastMigrationSummaryText.line(for: summary, calendar: calendar, locale: Locale(identifier: "en_US_POSIX")),
            "10/12 · \(L10n.tr("%d videos", summary.copiedCount)) · \(L10n.tr("%d size mismatch(es)", mismatches))"
        )
    }

    func testLineUsesCalendarTimeZoneForMonthAndDay() {
        let utc = makeUTCCalendar()
        let date = utc.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 2))!
        var pacific = Calendar(identifier: .gregorian)
        pacific.timeZone = TimeZone(secondsFromGMT: -7 * 60 * 60)!
        let summary = LastMigrationSummary(date: date, copiedCount: 1, verifiedCount: 1, totalCount: 1)

        let line = LastMigrationSummaryText.line(
            for: summary,
            calendar: pacific,
            locale: Locale(identifier: "en_US_POSIX")
        )

        XCTAssertTrue(line.hasPrefix("10/11 · \(L10n.tr("%d videos", 1))"))
    }

    private func makeUTCCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func makeDate(year: Int, month: Int, day: Int, calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }
}

final class LastMigrationSummaryStoreTests: XCTestCase {
    func testRoundTripUsesInjectedUserDefaults() {
        let suiteName = "clipdock.lastMigration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let key = "lastMigrationSummary"
        let store = LastMigrationSummaryStore(defaults: defaults, key: key)
        XCTAssertNil(store.load())

        let summary = LastMigrationSummary(
            date: Date(timeIntervalSince1970: 1_760_227_200.5),
            copiedCount: 12,
            verifiedCount: 10,
            totalCount: 12
        )
        store.save(summary)

        let reloaded = LastMigrationSummaryStore(defaults: defaults, key: key).load()
        XCTAssertEqual(reloaded, summary)
        XCTAssertNil(LastMigrationSummaryStore(defaults: defaults, key: "other-key").load())
    }
}

@MainActor
final class LastMigrationSummaryViewModelTests: XCTestCase {
    func testInitLoadsStoredSummary() {
        let stored = LastMigrationSummary(
            date: Date(timeIntervalSince1970: 1_760_227_200),
            copiedCount: 4,
            verifiedCount: 4,
            totalCount: 4
        )
        let store = MockLastMigrationSummaryStore(stored: stored)
        let vm = makeViewModel(store: store)

        XCTAssertEqual(vm.lastMigrationSummary, stored)
        XCTAssertEqual(store.saveCount, 0)
    }

    func testSavesSummaryAfterMigrationCompletesWithVerifiedItems() async {
        let fixedNow = Date(timeIntervalSince1970: 1_760_227_200)
        let now: @Sendable () -> Date = { fixedNow }
        let migration = MockVideoMigrationService()
        let folder = URL(fileURLWithPath: "/tmp/clipdock-last-migration")
        migration.resultToReturn = MigrationRunResult(
            successes: [
                .init(assetID: "A", destinationURL: folder.appendingPathComponent("A.mov"), bytes: 100, sourceBytes: 100),
            ],
            failures: [
                .init(assetID: "C", message: "export failed"),
            ],
            sizeMismatches: [
                .init(
                    assetID: "B",
                    destinationURL: folder.appendingPathComponent("B.mov"),
                    expectedBytes: 80,
                    actualBytes: 40,
                    fileWasMissing: false
                ),
            ]
        )
        let store = MockLastMigrationSummaryStore()
        let vm = makeViewModel(migration: migration, now: now, store: store)
        vm.permissionState = .authorized
        vm.selectedFolderURL = folder
        vm.isFolderWritable = true
        vm.videos = videos(["A", "B", "C"], date: fixedNow)
        vm.selectedVideoIDs = ["A", "B", "C"]

        vm.startMigration()

        await TestWait.until { @MainActor in
            store.stored != nil
        }

        let summary = store.stored
        XCTAssertEqual(summary?.date, fixedNow)
        XCTAssertEqual(summary?.copiedCount, 2)
        XCTAssertEqual(summary?.verifiedCount, 1)
        XCTAssertEqual(summary?.totalCount, 3)
        XCTAssertEqual(vm.lastMigrationSummary, summary)
        XCTAssertEqual(store.saveCount, 1)
    }

    func testDoesNotSaveWhenNothingCopied() async {
        let existing = LastMigrationSummary(
            date: Date(timeIntervalSince1970: 1_700_000_000),
            copiedCount: 2,
            verifiedCount: 2,
            totalCount: 2
        )
        let migration = MockVideoMigrationService()
        migration.resultToReturn = MigrationRunResult(
            successes: [],
            failures: [
                .init(assetID: "A", message: "nope"),
                .init(assetID: "B", message: "nope"),
            ]
        )
        let store = MockLastMigrationSummaryStore(stored: existing)
        let vm = makeViewModel(migration: migration, store: store)
        vm.permissionState = .authorized
        vm.selectedFolderURL = URL(fileURLWithPath: "/tmp/clipdock-last-migration-empty")
        vm.isFolderWritable = true
        vm.videos = videos(["A", "B"], date: Date(timeIntervalSince1970: 10))
        vm.selectedVideoIDs = ["A", "B"]

        vm.startMigration()

        await TestWait.until { @MainActor in
            !vm.isMigrating && !migration.migrateCalls.isEmpty
        }

        XCTAssertEqual(store.saveCount, 0)
        XCTAssertEqual(store.stored, existing)
        XCTAssertEqual(vm.lastMigrationSummary, existing)
    }

    func testRecopyPassUpdatesSummaryAfterVerification() async {
        let fixedNow = Date(timeIntervalSince1970: 1_760_300_000)
        let now: @Sendable () -> Date = { fixedNow }
        let migration = MockVideoMigrationService()
        let folder = URL(fileURLWithPath: "/tmp/clipdock-last-migration-recopy")
        migration.resultToReturn = MigrationRunResult(
            successes: [
                .init(assetID: "A", destinationURL: folder.appendingPathComponent("A.mov"), bytes: 10, sourceBytes: 10),
            ],
            failures: [],
            sizeMismatches: [
                .init(
                    assetID: "B",
                    destinationURL: folder.appendingPathComponent("B.mov"),
                    expectedBytes: 20,
                    actualBytes: 4,
                    fileWasMissing: false
                ),
            ]
        )
        let store = MockLastMigrationSummaryStore()
        let vm = makeViewModel(migration: migration, now: now, store: store)
        vm.permissionState = .authorized
        vm.selectedFolderURL = folder
        vm.isFolderWritable = true
        vm.videos = videos(["A", "B"], date: fixedNow)
        vm.selectedVideoIDs = ["A", "B"]

        vm.startMigration()
        await TestWait.until { @MainActor in
            store.saveCount == 1
        }
        XCTAssertEqual(store.stored?.copiedCount, 2)
        XCTAssertEqual(store.stored?.verifiedCount, 1)
        XCTAssertEqual(store.stored?.totalCount, 2)

        migration.resultToReturn = MigrationRunResult(
            successes: [
                .init(assetID: "B", destinationURL: folder.appendingPathComponent("B.mov"), bytes: 20, sourceBytes: 20),
            ],
            failures: []
        )
        vm.recopyMismatchedFiles()

        await TestWait.until { @MainActor in
            store.saveCount == 2
        }

        XCTAssertEqual(store.stored?.date, fixedNow)
        XCTAssertEqual(store.stored?.copiedCount, 2)
        XCTAssertEqual(store.stored?.verifiedCount, 2)
        XCTAssertEqual(store.stored?.totalCount, 2)
        XCTAssertEqual(vm.lastMigrationSummary, store.stored)
    }

    private func makeViewModel(
        migration: MockVideoMigrationService = MockVideoMigrationService(),
        now: @escaping @Sendable () -> Date = Date.init,
        store: MockLastMigrationSummaryStore
    ) -> HomeViewModel {
        HomeViewModel(
            photoPermissionService: MockPhotoPermissionService(),
            externalStorageService: MockExternalStorageService(),
            videoLibraryService: MockVideoLibraryService(),
            videoMigrationService: migration,
            photoDeletionService: MockPhotoDeletionService(),
            now: now,
            lastMigrationSummaryStore: store
        )
    }

    private func videos(_ ids: [String], date: Date) -> [VideoAssetSummary] {
        ids.map { id in
            VideoAssetSummary(id: id, creationDate: date, duration: 1, pixelWidth: 1, pixelHeight: 1)
        }
    }
}
