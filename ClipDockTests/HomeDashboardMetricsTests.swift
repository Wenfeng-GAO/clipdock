import XCTest
@testable import ClipDock

final class HomeDashboardMetricsTests: XCTestCase {
    func testReclaimableTotalSumsKnownPositiveSizesOnly() {
        let videos = [
            video("a", 4),
            video("b", 3),
            video("c", 2),
            video("d", 1),
        ]
        let sizes: [String: Int64] = [
            "a": 10,
            "b": 0,
            "c": -4,
            "missing": 100,
        ]

        let summary = HomeLibrarySummary.make(
            videos: videos,
            sizesBytesByID: sizes,
            rules: SelectionRulesService()
        )

        XCTAssertEqual(summary.videoCount, 4)
        XCTAssertEqual(summary.reclaimableBytes, 10)
        XCTAssertEqual(summary.topN, 20)
        XCTAssertEqual(summary.topNBytes, 10)
        XCTAssertEqual(summary.topNSelectedCount, 3)
    }

    func testTop20TotalIsSumOfLargestTwentyKnownSizes() {
        var videos: [VideoAssetSummary] = []
        var sizes: [String: Int64] = [:]
        for index in 0..<25 {
            let id = "id-\(index)"
            videos.append(video(id, TimeInterval(index)))
            if index > 0 {
                sizes[id] = Int64(index + 1)
            }
        }

        let summary = HomeLibrarySummary.make(
            videos: videos,
            sizesBytesByID: sizes,
            rules: SelectionRulesService()
        )

        XCTAssertEqual(summary.videoCount, 25)
        XCTAssertEqual(summary.reclaimableBytes, (2...25).reduce(Int64(0), +))
        XCTAssertEqual(summary.topNBytes, (6...25).reduce(Int64(0), +))
        XCTAssertEqual(summary.topNSelectedCount, 20)
    }

    func testTop20TotalWithFewerVideosEqualsReclaimableTotal() {
        let summary = HomeLibrarySummary.make(
            videos: [video("a", 1), video("b", 2)],
            sizesBytesByID: ["a": 5, "b": 9],
            rules: SelectionRulesService()
        )

        XCTAssertEqual(summary.reclaimableBytes, 14)
        XCTAssertEqual(summary.topNBytes, 14)
        XCTAssertEqual(summary.topNSelectedCount, 2)
    }

    func testSublineUsesCountAndTopTotal() {
        let summary = HomeLibrarySummary(
            videoCount: 1490,
            reclaimableBytes: 38_600_000_000,
            topN: 20,
            topNBytes: 21_400_000_000,
            topNSelectedCount: 20
        )

        XCTAssertEqual(summary.headlineText, ByteCountText.storage(38_600_000_000))
        XCTAssertEqual(
            summary.sublineText,
            L10n.tr(
                "%@ videos · largest %d use %@",
                NumberText.grouped(1490),
                20,
                ByteCountText.storage(21_400_000_000)
            )
        )
    }

    func testStorageBarFractionsMatchCapacityParts() {
        let total: Int64 = 128_000_000_000
        let available: Int64 = 18_000_000_000
        let videos: Int64 = 38_600_000_000
        let fractions = StorageBarFractions.make(
            videoBytes: videos,
            totalBytes: total,
            availableBytes: available
        )

        assertUnitInterval(fractions)
        XCTAssertEqual(fractions.videos, Double(videos) / Double(total), accuracy: 1e-9)
        XCTAssertEqual(fractions.available, Double(available) / Double(total), accuracy: 1e-9)
        XCTAssertEqual(
            fractions.other,
            Double(total - videos - available) / Double(total),
            accuracy: 1e-9
        )
    }

    func testStorageBarFractionsClampAndSumAtMostOne() {
        let overflow = StorageBarFractions.make(videoBytes: 1_000, totalBytes: 100, availableBytes: 80)
        assertUnitInterval(overflow)
        XCTAssertEqual(overflow.videos, 0.2, accuracy: 1e-9)
        XCTAssertEqual(overflow.available, 0.8, accuracy: 1e-9)
        XCTAssertEqual(overflow.other, 0, accuracy: 1e-9)

        let availableTooLarge = StorageBarFractions.make(videoBytes: 50, totalBytes: 100, availableBytes: 250)
        assertUnitInterval(availableTooLarge)
        XCTAssertEqual(availableTooLarge.available, 1, accuracy: 1e-9)
        XCTAssertEqual(availableTooLarge.videos, 0, accuracy: 1e-9)
        XCTAssertEqual(availableTooLarge.other, 0, accuracy: 1e-9)

        let negative = StorageBarFractions.make(videoBytes: -20, totalBytes: 50, availableBytes: -5)
        assertUnitInterval(negative)
        XCTAssertEqual(negative.videos, 0, accuracy: 1e-9)
        XCTAssertEqual(negative.available, 0, accuracy: 1e-9)
        XCTAssertEqual(negative.other, 1, accuracy: 1e-9)

        XCTAssertEqual(StorageBarFractions.make(videoBytes: 10, totalBytes: nil, availableBytes: 10), .zero)
        XCTAssertEqual(StorageBarFractions.make(videoBytes: 10, totalBytes: 0, availableBytes: 4), .zero)
        XCTAssertEqual(StorageBarFractions.make(videoBytes: 10, totalBytes: 100, availableBytes: nil), .zero)
    }

    func testClampedBytePartsStayInsideCapacity() {
        let samples: [(Int64, Int64, Int64)] = [
            (38_600_000_000, 128_000_000_000, 18_000_000_000),
            (1_000, 100, 80),
            (50, 100, 250),
            (-20, 50, -5),
            (0, 64, 64),
            (5, 10, 0),
            (10, 0, 4),
            (Int64.max, 1_000, 1),
            (1, Int64.max, Int64.max),
        ]

        for (videoBytes, total, available) in samples {
            let parts = StorageBarFractions.clampedBytes(
                videoBytes: videoBytes,
                totalBytes: total,
                availableBytes: available
            )
            XCTAssertGreaterThanOrEqual(parts.videos, 0)
            XCTAssertGreaterThanOrEqual(parts.other, 0)
            XCTAssertGreaterThanOrEqual(parts.available, 0)
            if total > 0 {
                XCTAssertEqual(parts.videos + parts.other + parts.available, total)
                XCTAssertLessThanOrEqual(parts.videos, total)
                XCTAssertLessThanOrEqual(parts.other, total)
                XCTAssertLessThanOrEqual(parts.available, total)
            } else {
                XCTAssertEqual(parts.videos, 0)
                XCTAssertEqual(parts.other, 0)
                XCTAssertEqual(parts.available, 0)
            }

            let fractions = StorageBarFractions.make(
                videoBytes: videoBytes,
                totalBytes: total > 0 ? total : nil,
                availableBytes: available
            )
            assertUnitInterval(fractions)
        }
    }

    func testLegendFormatsAvailableOverTotal() {
        let text = StorageBarFractions.legend(
            availableBytes: 18_000_000_000,
            totalBytes: 128_000_000_000
        )
        XCTAssertEqual(
            text,
            L10n.tr(
                "■ Videos  ■ Other  ■ Available %@ / %@",
                ByteCountText.storage(18_000_000_000),
                ByteCountText.storage(128_000_000_000)
            )
        )
    }

    func testDriveStatusTextWritableIncludesFreeSpace() {
        let free = ByteCountText.storage(212_000_000_000)
        let text = DriveStatusFormatter.statusLine(isWritable: true, freeBytes: 212_000_000_000)
        XCTAssertEqual(text, L10n.tr("Writable ✓ · %@ free", free))
        XCTAssertTrue(text.contains("✓"))
        XCTAssertTrue(text.contains(free))
    }

    func testDriveStatusTextNotWritableKeepsFreeSpace() {
        let free = ByteCountText.storage(48_000_000_000)
        let text = DriveStatusFormatter.statusLine(isWritable: false, freeBytes: 48_000_000_000)
        XCTAssertEqual(text, L10n.tr("Not writable · %@ free", free))
        XCTAssertFalse(text.contains("✓"))
        XCTAssertTrue(text.contains(free))
    }

    func testDriveStatusTextWithoutFreeSpace() {
        XCTAssertEqual(DriveStatusFormatter.statusLine(isWritable: true, freeBytes: nil), L10n.tr("Writable ✓"))
        XCTAssertEqual(DriveStatusFormatter.statusLine(isWritable: false, freeBytes: nil), L10n.tr("Not writable"))
        let zero = DriveStatusFormatter.statusLine(isWritable: true, freeBytes: 0)
        XCTAssertEqual(zero, L10n.tr("Writable ✓ · %@ free", ByteCountText.storage(0)))
    }

    func testDriveTitleUsesVolumeNameAndHidesFolderPath() {
        let folder = URL(fileURLWithPath: "/Volumes/SanDisk/ClipDock")
        XCTAssertEqual(
            DriveStatusFormatter.title(volumeName: "SanDisk", folderURL: folder),
            L10n.tr("USB Drive · %@", "SanDisk")
        )
        XCTAssertEqual(
            DriveStatusFormatter.title(volumeName: "  ", folderURL: folder),
            L10n.tr("USB Drive · %@", "ClipDock")
        )
        XCTAssertEqual(DriveStatusFormatter.title(volumeName: "SanDisk", folderURL: nil), L10n.tr("USB Drive"))
    }

    func testViewModelDriveStatusWritableAndFreeSpace() async {
        let storage = MockExternalStorageService()
        storage.validateWritableResult = true
        let reader = MockVolumeCapacityReader()
        let folder = URL(fileURLWithPath: "/Volumes/SanDisk/ClipDock")
        reader.snapshotByPath[folder.path] = VolumeCapacitySnapshot(
            name: "SanDisk",
            totalBytes: 256_000_000_000,
            availableBytes: 212_000_000_000
        )

        let vm = await MainActor.run {
            makeViewModel(storage: storage, reader: reader)
        }
        await MainActor.run {
            vm.setSelectedFolder(folder)
        }

        let title = await MainActor.run { vm.driveTitleText }
        let status = await MainActor.run { vm.driveStatusText }
        let path = await MainActor.run { vm.driveFolderPath }
        let free = await MainActor.run { vm.driveCapacity.availableBytes }
        let writable = await MainActor.run { vm.isFolderWritable }

        XCTAssertTrue(writable)
        XCTAssertEqual(free, 212_000_000_000 as Int64?)
        XCTAssertEqual(title, L10n.tr("USB Drive · %@", "SanDisk"))
        XCTAssertFalse(title.contains("ClipDock"))
        XCTAssertEqual(status, DriveStatusFormatter.statusLine(isWritable: true, freeBytes: 212_000_000_000))
        XCTAssertTrue(status.contains("✓"))
        XCTAssertEqual(path, folder.path as String?)
        XCTAssertFalse(status.contains(folder.path))
    }

    func testViewModelDriveStatusNotWritableStillReportsFreeSpace() async {
        let storage = MockExternalStorageService()
        storage.validateWritableResult = false
        let reader = MockVolumeCapacityReader()
        let folder = URL(fileURLWithPath: "/Volumes/ReadOnly")
        reader.snapshotByPath[folder.path] = VolumeCapacitySnapshot(
            name: "ReadOnly",
            totalBytes: 64_000_000_000,
            availableBytes: 8_000_000_000
        )
        let vm = await MainActor.run {
            makeViewModel(storage: storage, reader: reader)
        }
        await MainActor.run {
            vm.setSelectedFolder(folder)
        }

        let writable = await MainActor.run { vm.isFolderWritable }
        let free = await MainActor.run { vm.driveCapacity.availableBytes }
        let status = await MainActor.run { vm.driveStatusText }

        XCTAssertFalse(writable)
        XCTAssertEqual(free, 8_000_000_000 as Int64?)
        XCTAssertEqual(status, DriveStatusFormatter.statusLine(isWritable: false, freeBytes: 8_000_000_000))
        XCTAssertFalse(status.contains("✓"))
        XCTAssertFalse(status.contains(folder.path))
    }

    func testViewModelDriveStatusWhenNoFolder() async {
        let vm = await MainActor.run { makeViewModel() }
        let title = await MainActor.run { vm.driveTitleText }
        let status = await MainActor.run { vm.driveStatusText }
        let path = await MainActor.run { vm.driveFolderPath }

        XCTAssertEqual(title, L10n.tr("USB Drive"))
        XCTAssertEqual(status, L10n.tr("Not Selected"))
        XCTAssertNil(path)
    }

    func testViewModelStorageBarUsesVideoTotalAndDeviceCapacity() async {
        let library = MockVideoLibraryService()
        library.fetchVideosResult = [video("a", 1), video("b", 2)]
        library.fetchSizesResult = ["a": 30, "b": 10]
        let reader = MockVolumeCapacityReader()
        let deviceURL = URL(fileURLWithPath: "/device-volume")
        reader.snapshotByPath[deviceURL.path] = VolumeCapacitySnapshot(
            name: "iPhone",
            totalBytes: 100,
            availableBytes: 40
        )

        let vm = await MainActor.run {
            makeViewModel(library: library, reader: reader, deviceURL: deviceURL)
        }
        await MainActor.run {
            vm.permissionState = .authorized
            vm.scanVideos()
        }
        await TestWait.until {
            await MainActor.run { vm.hasCompletedScan && !vm.isFetchingAllVideoSizes }
        }
        await MainActor.run {
            vm.refreshCapacitySnapshots()
        }

        let summary = await MainActor.run { vm.librarySummary }
        let fractions = await MainActor.run { vm.storageBarFractions }
        XCTAssertEqual(summary.videoCount, 2)
        XCTAssertEqual(summary.reclaimableBytes, 40)
        XCTAssertEqual(summary.topNBytes, 40)
        XCTAssertEqual(fractions.videos, 0.4, accuracy: 1e-9)
        XCTAssertEqual(fractions.available, 0.4, accuracy: 1e-9)
        XCTAssertEqual(fractions.other, 0.2, accuracy: 1e-9)
        assertUnitInterval(fractions)
    }

    func testSelectLargestVideosPreselectsTopN() async {
        let library = MockVideoLibraryService()
        library.fetchVideosResult = [
            video("a", 1),
            video("b", 2),
            video("c", 3),
            video("d", 4),
        ]
        library.fetchSizesResult = ["a": 10, "b": 50, "c": 30, "d": 40]
        let vm = await MainActor.run { makeViewModel(library: library) }

        await MainActor.run {
            vm.permissionState = .authorized
            vm.scanVideos()
        }
        await TestWait.until {
            await MainActor.run { vm.hasCompletedScan && !vm.isFetchingAllVideoSizes }
        }
        await MainActor.run {
            vm.selectLargestVideos(count: 2)
        }
        await TestWait.until {
            await MainActor.run { vm.selectedVideoIDs.count == 2 }
        }

        let selected = await MainActor.run { vm.selectedVideoIDs }
        let selectedBytes = await MainActor.run { vm.selectedTotalKnownBytes }
        XCTAssertEqual(selected, ["b", "d"])
        XCTAssertEqual(selectedBytes, 90)
    }

    private func assertUnitInterval(
        _ fractions: StorageBarFractions,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertGreaterThanOrEqual(fractions.videos, 0, file: file, line: line)
        XCTAssertGreaterThanOrEqual(fractions.other, 0, file: file, line: line)
        XCTAssertGreaterThanOrEqual(fractions.available, 0, file: file, line: line)
        XCTAssertLessThanOrEqual(fractions.videos, 1, file: file, line: line)
        XCTAssertLessThanOrEqual(fractions.other, 1, file: file, line: line)
        XCTAssertLessThanOrEqual(fractions.available, 1, file: file, line: line)
        XCTAssertLessThanOrEqual(fractions.sum, 1 + 1e-9, file: file, line: line)
    }
}

@MainActor
private func makeViewModel(
    library: MockVideoLibraryService = MockVideoLibraryService(),
    storage: MockExternalStorageService = MockExternalStorageService(),
    reader: MockVolumeCapacityReader = MockVolumeCapacityReader(),
    deviceURL: URL = URL(fileURLWithPath: "/device-volume")
) -> HomeViewModel {
    HomeViewModel(
        photoPermissionService: MockPhotoPermissionService(),
        externalStorageService: storage,
        videoLibraryService: library,
        videoMigrationService: MockVideoMigrationService(),
        photoDeletionService: MockPhotoDeletionService(),
        volumeCapacityReader: reader,
        deviceVolumeURL: deviceURL
    )
}

private func video(_ id: String, _ time: TimeInterval) -> VideoAssetSummary {
    VideoAssetSummary(
        id: id,
        creationDate: Date(timeIntervalSince1970: time),
        duration: 1,
        pixelWidth: 1,
        pixelHeight: 1
    )
}
