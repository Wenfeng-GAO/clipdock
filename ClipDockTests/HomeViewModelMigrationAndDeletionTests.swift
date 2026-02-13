import XCTest
@testable import ClipDock

final class HomeViewModelMigrationAndDeletionTests: XCTestCase {
    func testStartMigrationUsesSelectedOrderFromCurrentVideosList() async {
        let videoLibrary = MockVideoLibraryService()
        videoLibrary.fetchVideosResult = [
            .init(id: "A", creationDate: Date(timeIntervalSince1970: 3), duration: 1, pixelWidth: 1, pixelHeight: 1),
            .init(id: "B", creationDate: Date(timeIntervalSince1970: 2), duration: 1, pixelWidth: 1, pixelHeight: 1),
            .init(id: "C", creationDate: Date(timeIntervalSince1970: 1), duration: 1, pixelWidth: 1, pixelHeight: 1),
        ]

        let migration = MockVideoMigrationService()
        migration.resultToReturn = .init(successes: [], failures: [])

        let vm = await MainActor.run {
            HomeViewModel(
                photoPermissionService: MockPhotoPermissionService(),
                externalStorageService: MockExternalStorageService(),
                videoLibraryService: videoLibrary,
                videoMigrationService: migration,
                photoDeletionService: MockPhotoDeletionService()
            )
        }

        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("clipdock-tests-\(UUID().uuidString)")

        await MainActor.run {
            vm.permissionState = .authorized
            vm.selectedFolderURL = folder
            vm.isFolderWritable = true
            vm.sortMode = .dateDesc
            vm.scanVideos()
        }

        await TestWait.until {
            await MainActor.run { !vm.isScanningVideos }
        }

        await MainActor.run {
            vm.selectedVideoIDs = ["B", "C"]
            vm.startMigration()
        }

        await TestWait.until {
            await MainActor.run { !migration.migrateCalls.isEmpty }
        }

        let call = await MainActor.run { migration.migrateCalls[0] }
        XCTAssertEqual(call.0, ["B", "C"])
        XCTAssertEqual(call.1, folder)
    }

    func testDeleteMigratedOriginalsDeletesOnlySuccessesFromLastRun() async {
        let deletion = MockPhotoDeletionService()
        let vm = await MainActor.run {
            HomeViewModel(
                photoPermissionService: MockPhotoPermissionService(),
                externalStorageService: MockExternalStorageService(),
                videoLibraryService: MockVideoLibraryService(),
                videoMigrationService: MockVideoMigrationService(),
                photoDeletionService: deletion
            )
        }

        await MainActor.run {
            vm.permissionState = .authorized
            vm.lastMigrationResult = .init(
                successes: [
                    .init(assetID: "A", destinationURL: URL(fileURLWithPath: "/tmp/a"), bytes: 1),
                    .init(assetID: "B", destinationURL: URL(fileURLWithPath: "/tmp/b"), bytes: 2),
                ],
                failures: [
                    .init(assetID: "C", message: "nope"),
                ]
            )
            vm.deleteMigratedOriginals()
        }

        await TestWait.until {
            await MainActor.run { !deletion.deleteCalls.isEmpty }
        }

        let ids = await MainActor.run { deletion.deleteCalls[0].sorted() }
        XCTAssertEqual(ids, ["A", "B"])
    }
}
