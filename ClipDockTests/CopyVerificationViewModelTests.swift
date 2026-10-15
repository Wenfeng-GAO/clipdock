import XCTest
@testable import ClipDock

@MainActor
final class CopyVerificationViewModelTests: XCTestCase {
    func testDeletableSetDeletesOnlyVerifiedItems() async throws {
        let deletion = MockPhotoDeletionService()
        let vm = makeViewModel(deletion: deletion)
        vm.permissionState = .authorized
        vm.copyItems = [
            CopyItemState(assetID: "A", displayName: "a.mov", expectedBytes: 100, actualBytes: 100, destinationURL: URL(fileURLWithPath: "/tmp/a.mov"), status: .verified),
            CopyItemState(assetID: "B", displayName: "b.mov", expectedBytes: 999, actualBytes: 10, destinationURL: URL(fileURLWithPath: "/tmp/b.mov"), status: .mismatch(expected: 999, actual: 10)),
            CopyItemState(assetID: "C", displayName: "c.mov", expectedBytes: 50, actualBytes: 50, destinationURL: URL(fileURLWithPath: "/tmp/c.mov"), status: .verified),
            CopyItemState(assetID: "D", displayName: "d.mov", expectedBytes: 8, status: .failed("export failed")),
        ]

        XCTAssertTrue(vm.isDeleteEnabled)
        XCTAssertEqual(vm.deletableAssetIDs, ["A", "C"])
        XCTAssertEqual(vm.copyEligibility.deletableBytes, 150)

        vm.deleteMigratedOriginals()

        await TestWait.until { @MainActor in
            vm.deletionResultModel != nil
        }

        let calls = deletion.deleteCalls
        let model = vm.deletionResultModel
        let snapshot = try XCTUnwrap(model).snapshot
        XCTAssertEqual(calls, [["A", "C"]])
        XCTAssertEqual(snapshot.copiedCount, 3)
        XCTAssertEqual(snapshot.verifiedMatchCount, 2)
        XCTAssertEqual(snapshot.verifiedTotalCount, 3)
        XCTAssertEqual(snapshot.pendingReleaseBytes, 150)
    }

    func testDeleteDisabledBeforeVerificationComplete() {
        let deletion = MockPhotoDeletionService()
        let vm = makeViewModel(deletion: deletion)
        vm.permissionState = .authorized
        vm.copyItems = [
            CopyItemState(assetID: "A", expectedBytes: 100, actualBytes: 100, status: .verified),
            CopyItemState(assetID: "B", expectedBytes: 20, status: .copying),
        ]

        XCTAssertFalse(vm.copyEligibility.isVerificationComplete)
        XCTAssertFalse(vm.isDeleteEnabled)
        XCTAssertTrue(vm.deletableAssetIDs.isEmpty)
        XCTAssertEqual(
            vm.deleteOriginalsButtonTitle,
            L10n.tr("Delete originals (available after verification)")
        )

        vm.isMigrating = true
        XCTAssertFalse(vm.isDeleteEnabled)
        XCTAssertEqual(
            vm.deleteOriginalsButtonTitle,
            L10n.tr("Delete originals (available after verification)")
        )
        vm.isMigrating = false

        vm.deleteMigratedOriginals()
        vm.promptDeleteMigratedOriginals()

        XCTAssertTrue(deletion.deleteCalls.isEmpty)
        XCTAssertFalse(vm.isShowingDeleteConfirm)
    }

    func testRecopyTargetsOnlyMismatches() async {
        let migration = MockVideoMigrationService()
        let vm = makeViewModel(migration: migration)
        vm.permissionState = .authorized
        vm.isFolderWritable = true
        vm.selectedFolderURL = URL(fileURLWithPath: "/tmp/clipdock-recopy")
        vm.copyItems = [
            CopyItemState(assetID: "A", displayName: "a.mov", expectedBytes: 10, actualBytes: 10, destinationURL: URL(fileURLWithPath: "/tmp/a.mov"), status: .verified),
            CopyItemState(assetID: "B", displayName: "b.mov", expectedBytes: 20, actualBytes: 4, destinationURL: URL(fileURLWithPath: "/tmp/b.mov"), status: .mismatch(expected: 20, actual: 4)),
            CopyItemState(assetID: "C", displayName: "c.mov", expectedBytes: 8, status: .pending),
        ]

        vm.recopyMismatchedFiles(assetIDs: ["A"])
        XCTAssertTrue(migration.migrateCalls.isEmpty)

        vm.recopyMismatchedFiles(assetIDs: ["A", "B", "Z"])

        await TestWait.until { @MainActor in
            !migration.migrateCalls.isEmpty
        }

        XCTAssertEqual(migration.migrateCalls.map(\.0), [["B"]])
        XCTAssertEqual(migration.migrateCalls.map(\.1), [URL(fileURLWithPath: "/tmp/clipdock-recopy")])
    }

    func testCopyingSubtitleUsesInjectedClockAndResetsOnRecopy() {
        let clock = MutableClock(Date(timeIntervalSince1970: 1_700_000_000))
        let now: @Sendable () -> Date = { clock.date }
        let vm = makeViewModel(now: now)
        vm.permissionState = .authorized
        vm.isFolderWritable = true
        vm.selectedFolderURL = URL(fileURLWithPath: "/tmp/clipdock-clock")
        vm.videos = [
            VideoAssetSummary(id: "A", creationDate: clock.date, duration: 1, pixelWidth: 1, pixelHeight: 1),
            VideoAssetSummary(id: "B", creationDate: clock.date, duration: 1, pixelWidth: 1, pixelHeight: 1),
        ]
        vm.selectedVideoIDs = ["A", "B"]

        vm.startMigration()
        vm.copyItems = [
            CopyItemState(assetID: "A", displayName: "a.mov", expectedBytes: 8_600_000_000, actualBytes: 8_600_000_000, status: .verified),
            CopyItemState(assetID: "B", displayName: "b.mov", expectedBytes: 4_800_000_000, status: .pending),
        ]

        let copied = ByteCountText.string(fromBytes: 8_600_000_000)
        let total = ByteCountText.string(fromBytes: 13_400_000_000)
        let ratio = "\(copied) / \(total)"
        XCTAssertEqual(vm.copyingByteSubtitle, ratio)

        clock.date = clock.date.addingTimeInterval(120)
        let remaining = CopyTimeEstimator.remainingSeconds(
            copiedBytes: 8_600_000_000,
            totalBytes: 13_400_000_000,
            elapsed: 120
        )
        XCTAssertEqual(vm.copyingByteSubtitle, "\(ratio) · \(CopyTimeEstimator.minutesText(remaining ?? -1))")
        XCTAssertEqual(CopyTimeEstimator.minutesText(remaining ?? -1), L10n.tr("About %d min", 2))

        vm.stopMigration()
        vm.copyItems = [
            CopyItemState(assetID: "A", displayName: "a.mov", expectedBytes: 8_600_000_000, actualBytes: 8_600_000_000, status: .verified),
            CopyItemState(
                assetID: "B",
                displayName: "b.mov",
                expectedBytes: 4_800_000_000,
                actualBytes: 10,
                destinationURL: URL(fileURLWithPath: "/tmp/clipdock-clock/b.mov"),
                status: .mismatch(expected: 4_800_000_000, actual: 10)
            ),
        ]
        clock.date = clock.date.addingTimeInterval(30)
        vm.recopyMismatchedFiles()

        let recopied = ByteCountText.string(fromBytes: 8_600_000_000)
        let recopiedTotal = ByteCountText.string(fromBytes: 13_400_000_000)
        XCTAssertEqual(vm.copyingByteSubtitle, "\(recopied) / \(recopiedTotal)")
    }

    private func makeViewModel(
        migration: MockVideoMigrationService = MockVideoMigrationService(),
        deletion: MockPhotoDeletionService = MockPhotoDeletionService(),
        now: @escaping @Sendable () -> Date = Date.init
    ) -> HomeViewModel {
        HomeViewModel(
            photoPermissionService: MockPhotoPermissionService(),
            externalStorageService: MockExternalStorageService(),
            videoLibraryService: MockVideoLibraryService(),
            videoMigrationService: migration,
            photoDeletionService: deletion,
            now: now
        )
    }
}

private final class MutableClock: @unchecked Sendable {
    var date: Date
    init(_ date: Date) { self.date = date }
}
