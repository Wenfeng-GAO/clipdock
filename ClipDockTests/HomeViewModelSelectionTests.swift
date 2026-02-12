import XCTest
@testable import ClipDock

@MainActor
final class HomeViewModelSelectionTests: XCTestCase {
    func testToggleSelection() {
        let vm = HomeViewModel(
            photoPermissionService: MockPhotoPermissionService(),
            externalStorageService: MockExternalStorageService(),
            videoLibraryService: MockVideoLibraryService(),
            videoMigrationService: MockVideoMigrationService(),
            photoDeletionService: MockPhotoDeletionService(),
            historyStore: MockHistoryStore()
        )

        XCTAssertTrue(vm.selectedVideoIDs.isEmpty)
        vm.toggleSelection(for: "A")
        XCTAssertEqual(vm.selectedVideoIDs, ["A"])
        vm.toggleSelection(for: "A")
        XCTAssertTrue(vm.selectedVideoIDs.isEmpty)
    }

    func testSelectAllAndClear() {
        let vm = HomeViewModel(
            photoPermissionService: MockPhotoPermissionService(),
            externalStorageService: MockExternalStorageService(),
            videoLibraryService: MockVideoLibraryService(),
            videoMigrationService: MockVideoMigrationService(),
            photoDeletionService: MockPhotoDeletionService(),
            historyStore: MockHistoryStore()
        )

        vm.videos = [
            .init(id: "A", creationDate: .distantPast, duration: 1, pixelWidth: 1, pixelHeight: 1),
            .init(id: "B", creationDate: .distantPast, duration: 1, pixelWidth: 1, pixelHeight: 1),
        ]

        vm.selectAllScannedVideos()
        XCTAssertEqual(vm.selectedVideoIDs, ["A", "B"])

        vm.clearSelection()
        XCTAssertTrue(vm.selectedVideoIDs.isEmpty)
    }
}

