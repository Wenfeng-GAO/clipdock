import XCTest
@testable import ClipDock

final class HomeViewModelSortAndSizeTests: XCTestCase {
    func testPrefetchSizeCappedAt200() async {
        let permission = MockPhotoPermissionService()
        permission.status = .authorized

        let videoLibrary = MockVideoLibraryService()
        // Mirror real behavior: videos are scanned sorted by date DESC.
        videoLibrary.fetchVideosResult = (0..<250).map { idx in
            VideoAssetSummary(
                id: "id-\(idx)",
                creationDate: Date(timeIntervalSince1970: TimeInterval(10_000 - idx)),
                duration: 1,
                pixelWidth: 1920,
                pixelHeight: 1080
            )
        }
        for idx in 0..<250 {
            videoLibrary.fetchSizesResult["id-\(idx)"] = Int64(idx + 1)
        }

        let vm = await MainActor.run {
            HomeViewModel(
                photoPermissionService: permission,
                externalStorageService: MockExternalStorageService(),
                videoLibraryService: videoLibrary,
                videoMigrationService: MockVideoMigrationService(),
                photoDeletionService: MockPhotoDeletionService(),
                historyStore: MockHistoryStore()
            )
        }

        await MainActor.run {
            vm.permissionState = .authorized
            vm.sortMode = .sizeDesc
            vm.scanVideos()
        }

        await TestWait.until {
            await MainActor.run { !vm.isScanningVideos && !vm.isFetchingVideoSizes }
        }

        XCTAssertEqual(videoLibrary.fetchVideosCallCount, 1)
        XCTAssertEqual(videoLibrary.fetchSizesCalls.count, 1)
        XCTAssertEqual(videoLibrary.fetchSizesCalls[0].count, 200)
        XCTAssertEqual(videoLibrary.fetchSizesCalls[0].first, "id-0")
        XCTAssertEqual(videoLibrary.fetchSizesCalls[0].last, "id-199")
    }

    func testSortBySizeDescendingUnknownsAtBottom() async {
        let videoLibrary = MockVideoLibraryService()
        videoLibrary.fetchVideosResult = [
            .init(id: "A", creationDate: Date(timeIntervalSince1970: 3), duration: 1, pixelWidth: 1, pixelHeight: 1),
            .init(id: "B", creationDate: Date(timeIntervalSince1970: 2), duration: 1, pixelWidth: 1, pixelHeight: 1),
            .init(id: "C", creationDate: Date(timeIntervalSince1970: 1), duration: 1, pixelWidth: 1, pixelHeight: 1),
        ]
        videoLibrary.fetchSizesResult = [
            "A": 10,
            "C": 30,
            // "B" missing => unknown
        ]

        let vm = await MainActor.run {
            HomeViewModel(
                photoPermissionService: MockPhotoPermissionService(),
                externalStorageService: MockExternalStorageService(),
                videoLibraryService: videoLibrary,
                videoMigrationService: MockVideoMigrationService(),
                photoDeletionService: MockPhotoDeletionService(),
                historyStore: MockHistoryStore()
            )
        }

        await MainActor.run {
            vm.permissionState = .authorized
            vm.sortMode = .sizeDesc
            vm.scanVideos()
        }

        await TestWait.until {
            await MainActor.run { !vm.isScanningVideos && !vm.isFetchingVideoSizes }
        }

        let ids = await MainActor.run { vm.videos.map(\.id) }
        XCTAssertEqual(ids, ["C", "A", "B"])
    }

    func testSortBySizeAscending() async {
        let videoLibrary = MockVideoLibraryService()
        videoLibrary.fetchVideosResult = [
            .init(id: "A", creationDate: Date(timeIntervalSince1970: 3), duration: 1, pixelWidth: 1, pixelHeight: 1),
            .init(id: "B", creationDate: Date(timeIntervalSince1970: 2), duration: 1, pixelWidth: 1, pixelHeight: 1),
            .init(id: "C", creationDate: Date(timeIntervalSince1970: 1), duration: 1, pixelWidth: 1, pixelHeight: 1),
        ]
        videoLibrary.fetchSizesResult = [
            "A": 10,
            "B": 5,
            "C": 30,
        ]

        let vm = await MainActor.run {
            HomeViewModel(
                photoPermissionService: MockPhotoPermissionService(),
                externalStorageService: MockExternalStorageService(),
                videoLibraryService: videoLibrary,
                videoMigrationService: MockVideoMigrationService(),
                photoDeletionService: MockPhotoDeletionService(),
                historyStore: MockHistoryStore()
            )
        }

        await MainActor.run {
            vm.permissionState = .authorized
            vm.sortMode = .sizeAsc
            vm.scanVideos()
        }

        await TestWait.until {
            await MainActor.run { !vm.isScanningVideos && !vm.isFetchingVideoSizes }
        }

        let ids = await MainActor.run { vm.videos.map(\.id) }
        XCTAssertEqual(ids, ["B", "A", "C"])
    }

    func testFormattedSizeTextUnknownIsPlaceholder() async {
        let videoLibrary = MockVideoLibraryService()
        videoLibrary.fetchVideosResult = [
            .init(id: "A", creationDate: .distantPast, duration: 1, pixelWidth: 1, pixelHeight: 1),
        ]
        videoLibrary.fetchSizesResult = [:]

        let vm = await MainActor.run {
            HomeViewModel(
                photoPermissionService: MockPhotoPermissionService(),
                externalStorageService: MockExternalStorageService(),
                videoLibraryService: videoLibrary,
                videoMigrationService: MockVideoMigrationService(),
                photoDeletionService: MockPhotoDeletionService(),
                historyStore: MockHistoryStore()
            )
        }

        let text = await MainActor.run { vm.formattedSizeText(for: "A") }
        XCTAssertEqual(text, "--")
    }
}
