import XCTest
@testable import ClipDock

@MainActor
final class CopyVerificationViewModelTests: XCTestCase {
    func testDeletableSetDeletesOnlyVerifiedItems() async {
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
            !deletion.deleteCalls.isEmpty
        }

        XCTAssertEqual(deletion.deleteCalls.count, 1)
        XCTAssertEqual(deletion.deleteCalls[0], ["A", "C"])
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

    private func makeViewModel(
        migration: MockVideoMigrationService = MockVideoMigrationService(),
        deletion: MockPhotoDeletionService = MockPhotoDeletionService()
    ) -> HomeViewModel {
        HomeViewModel(
            photoPermissionService: MockPhotoPermissionService(),
            externalStorageService: MockExternalStorageService(),
            videoLibraryService: MockVideoLibraryService(),
            videoMigrationService: migration,
            photoDeletionService: deletion
        )
    }
}
