import XCTest
@testable import ClipDock

@MainActor
final class HomeViewModelGuardrailTests: XCTestCase {
    func testScanVideosDeniedDoesNotCallLibrary() {
        let permission = MockPhotoPermissionService()
        permission.status = .denied

        let library = MockVideoLibraryService()

        let vm = HomeViewModel(
            photoPermissionService: permission,
            externalStorageService: MockExternalStorageService(),
            videoLibraryService: library,
            videoMigrationService: MockVideoMigrationService(),
            photoDeletionService: MockPhotoDeletionService()
        )

        vm.permissionState = .denied
        vm.scanVideos()

        XCTAssertNotNil(vm.alertMessage)
        XCTAssertEqual(library.fetchVideosCallCount, 0)
    }

    func testStartMigrationRequiresFolderAndWritableAndSelection() async {
        let migration = MockVideoMigrationService()
        let vm = HomeViewModel(
            photoPermissionService: MockPhotoPermissionService(),
            externalStorageService: MockExternalStorageService(),
            videoLibraryService: MockVideoLibraryService(),
            videoMigrationService: migration,
            photoDeletionService: MockPhotoDeletionService()
        )

        vm.permissionState = .authorized
        vm.videos = [.init(id: "A", creationDate: .now, duration: 1, pixelWidth: 1, pixelHeight: 1)]
        vm.selectedVideoIDs = ["A"]

        // No folder
        vm.selectedFolderURL = nil
        vm.isFolderWritable = true
        vm.startMigration()
        XCTAssertNotNil(vm.alertMessage)
        XCTAssertTrue(migration.migrateCalls.isEmpty)

        // Folder not writable
        vm.alertMessage = nil
        vm.selectedFolderURL = URL(fileURLWithPath: "/tmp")
        vm.isFolderWritable = false
        vm.startMigration()
        XCTAssertNotNil(vm.alertMessage)
        XCTAssertTrue(migration.migrateCalls.isEmpty)

        // No selection
        vm.alertMessage = nil
        vm.isFolderWritable = true
        vm.selectedVideoIDs = []
        vm.startMigration()
        XCTAssertNotNil(vm.alertMessage)
        XCTAssertTrue(migration.migrateCalls.isEmpty)
    }

    func testSelectAllLargeLibrary() {
        let vm = HomeViewModel(
            photoPermissionService: MockPhotoPermissionService(),
            externalStorageService: MockExternalStorageService(),
            videoLibraryService: MockVideoLibraryService(),
            videoMigrationService: MockVideoMigrationService(),
            photoDeletionService: MockPhotoDeletionService()
        )

        vm.videos = (0..<5000).map { idx in
            VideoAssetSummary(id: "id-\(idx)", creationDate: .distantPast, duration: 1, pixelWidth: 1, pixelHeight: 1)
        }
        vm.selectAllScannedVideos()
        XCTAssertEqual(vm.selectedVideoIDs.count, 5000)
    }
}
