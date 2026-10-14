import XCTest
@testable import ClipDock

final class PickerFilterChipTests: XCTestCase {
    func testChipOrderMatchesThePickerRow() {
        XCTAssertEqual(PickerFilterChip.allCases, [.top20, .year2024, .year2025, .all])
        XCTAssertEqual(HomeLibrarySummary.defaultTopN, 20)
    }

    func testAllKeepsInputOrder() {
        let videos = [
            sample("late", year: 2025, month: 2, day: 1, calendar: utc),
            sample("early", year: 2024, month: 1, day: 2, calendar: utc),
        ]
        let shown = PickerFilterChip.visibleVideos(videos, chip: .all, calendar: utc, sizesBytesByID: ["late": 1, "early": 99])
        XCTAssertEqual(shown.map(\.id), ["late", "early"])
    }

    func testYearFiltersUseTheGivenCalendarYear() {
        let utcPlus8 = PickerFilterCalendar.offset(secondsFromGMT: 8 * 60 * 60)
        // 2024-12-31 20:00 UTC is 2025-01-01 04:00 at UTC+8.
        let newYearsEveUTC = date(year: 2024, month: 12, day: 31, hour: 20, calendar: utc)
        // 2024-01-01 00:00 at UTC+8 is still 2023-12-31 in UTC.
        let newYearEast = date(year: 2024, month: 1, day: 1, hour: 0, calendar: utcPlus8)
        let mid2024 = date(year: 2024, month: 6, day: 1, hour: 12, calendar: utc)
        let mid2025 = date(year: 2025, month: 3, day: 2, hour: 8, calendar: utc)
        let videos = [
            VideoAssetSummary(id: "eve", creationDate: newYearsEveUTC, duration: 1, pixelWidth: 1, pixelHeight: 1),
            VideoAssetSummary(id: "mid24", creationDate: mid2024, duration: 1, pixelWidth: 1, pixelHeight: 1),
            VideoAssetSummary(id: "mid25", creationDate: mid2025, duration: 1, pixelWidth: 1, pixelHeight: 1),
            VideoAssetSummary(id: "early", creationDate: newYearEast, duration: 1, pixelWidth: 1, pixelHeight: 1),
        ]

        XCTAssertEqual(
            PickerFilterChip.visibleVideos(videos, chip: .year2024, calendar: utcPlus8).map(\.id),
            ["mid24", "early"]
        )
        XCTAssertEqual(
            PickerFilterChip.visibleVideos(videos, chip: .year2024, calendar: utc).map(\.id),
            ["eve", "mid24"]
        )
        XCTAssertEqual(
            PickerFilterChip.visibleVideos(videos, chip: .year2025, calendar: utcPlus8).map(\.id),
            ["eve", "mid25"]
        )
        XCTAssertEqual(
            PickerFilterChip.visibleVideos(videos, chip: .year2025, calendar: utc).map(\.id),
            ["mid25"]
        )
    }

    func testTop20ShowsEveryVideoLargestFirst() {
        let older = date(year: 2024, month: 1, day: 1, hour: 0, calendar: utc)
        let newer = date(year: 2024, month: 6, day: 1, hour: 0, calendar: utc)
        let videos = [
            VideoAssetSummary(id: "small", creationDate: older, duration: 1, pixelWidth: 1, pixelHeight: 1),
            VideoAssetSummary(id: "tieOld", creationDate: older, duration: 1, pixelWidth: 1, pixelHeight: 1),
            VideoAssetSummary(id: "tieNew", creationDate: newer, duration: 1, pixelWidth: 1, pixelHeight: 1),
            VideoAssetSummary(id: "big", creationDate: older, duration: 1, pixelWidth: 1, pixelHeight: 1),
            VideoAssetSummary(id: "unknown", creationDate: newer, duration: 1, pixelWidth: 1, pixelHeight: 1),
        ]
        let sizes: [String: Int64] = [
            "small": 10,
            "tieOld": 50,
            "tieNew": 50,
            "big": 80,
        ]

        let shown = PickerFilterChip.visibleVideos(videos, chip: .top20, calendar: utc, sizesBytesByID: sizes)
        XCTAssertEqual(shown.map(\.id), ["big", "tieNew", "tieOld", "small", "unknown"])
        XCTAssertEqual(shown.count, videos.count)
    }

    func testTop20DoesNotTruncatePastTwenty() {
        let videos = (0..<25).map { index in
            VideoAssetSummary(
                id: "v\(index)",
                creationDate: Date(timeIntervalSince1970: TimeInterval(index)),
                duration: 1,
                pixelWidth: 1,
                pixelHeight: 1
            )
        }
        let sizes = Dictionary(uniqueKeysWithValues: videos.enumerated().map { index, video in
            (video.id, Int64(index + 1))
        })
        let shown = PickerFilterChip.visibleVideos(videos, chip: .top20, calendar: utc, sizesBytesByID: sizes)
        XCTAssertEqual(shown.count, 25)
        XCTAssertEqual(shown.first?.id, "v24")
        XCTAssertEqual(shown.last?.id, "v0")
    }

    private let utc = PickerFilterCalendar.offset(secondsFromGMT: 0)

    private func date(year: Int, month: Int, day: Int, hour: Int, calendar: Calendar) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = 0
        components.second = 0
        return calendar.date(from: components)!
    }

    private func sample(_ id: String, year: Int, month: Int, day: Int, calendar: Calendar) -> VideoAssetSummary {
        VideoAssetSummary(
            id: id,
            creationDate: date(year: year, month: month, day: day, hour: 12, calendar: calendar),
            duration: 1,
            pixelWidth: 1,
            pixelHeight: 1
        )
    }
}

final class PickerTrayTextTests: XCTestCase {
    func testDriveFreeTextIsNilWhenUnknown() {
        XCTAssertNil(PickerTrayText.driveFreeText(freeBytes: nil))
    }

    func testDriveFreeTextUsesSharedStorageFormatter() {
        let bytes: Int64 = 212_000_000_000
        XCTAssertEqual(
            PickerTrayText.driveFreeText(freeBytes: bytes),
            L10n.tr("Drive free %@", ByteCountText.storage(bytes))
        )
        XCTAssertNotNil(PickerTrayText.driveFreeText(freeBytes: 0))
    }
}

@MainActor
final class PickerFilterSelectionTests: XCTestCase {
    func testLargestEntryActivatesTop20AndOrdersBySize() async {
        let library = MockVideoLibraryService()
        library.fetchVideosResult = [
            video("small", seconds: 30),
            video("big", seconds: 10),
            video("mid", seconds: 20),
        ]
        library.fetchSizesResult = ["small": 10, "big": 80, "mid": 40]
        let vm = makeViewModel(library: library)
        vm.permissionState = .authorized
        vm.scanVideos()
        await TestWait.until { @MainActor in
            vm.hasCompletedScan && !vm.isFetchingAllVideoSizes
        }

        vm.selectLargestVideos(count: HomeLibrarySummary.defaultTopN)
        XCTAssertEqual(vm.pickerFilter, .top20)
        XCTAssertEqual(vm.sortMode, .sizeDesc)
        XCTAssertEqual(vm.pickerVisibleVideos(calendar: .current).map(\.id), ["big", "mid", "small"])

        await TestWait.until { @MainActor in
            vm.selectedVideoIDs.count == 3
        }
        XCTAssertEqual(vm.selectedVideoIDs, ["small", "big", "mid"])

        vm.sortMode = .dateDesc
        XCTAssertEqual(vm.pickerFilter, .top20)
        XCTAssertEqual(vm.pickerVisibleVideos(calendar: .current).map(\.id), ["small", "mid", "big"])
    }

    func testManualPickActivatesAllAndDropsPendingTop20() async {
        let library = MockVideoLibraryService()
        library.fetchVideosResult = [
            video("a", seconds: 2),
            video("b", seconds: 1),
        ]
        library.fetchSizesResult = ["a": 5, "b": 9]
        let vm = makeViewModel(library: library)
        vm.permissionState = .authorized
        vm.scanVideos()
        XCTAssertTrue(vm.isScanningVideos)

        vm.selectLargestVideos(count: HomeLibrarySummary.defaultTopN)
        XCTAssertEqual(vm.pickerFilter, .top20)
        vm.prepareManualPick()
        XCTAssertEqual(vm.pickerFilter, .all)

        await TestWait.until { @MainActor in
            vm.hasCompletedScan && !vm.isFetchingAllVideoSizes
        }
        XCTAssertTrue(vm.selectedVideoIDs.isEmpty)
        XCTAssertEqual(vm.pickerFilter, .all)
    }

    func testYearChipFiltersWithoutChangingSelection() {
        let vm = makeViewModel()
        vm.permissionState = .authorized
        vm.videos = [
            video("in2024", seconds: 1_704_067_200),
            video("in2025", seconds: 1_735_689_600),
        ]
        vm.selectedVideoIDs = ["in2025"]
        vm.selectPickerChip(.year2024)

        XCTAssertEqual(vm.pickerFilter, .year2024)
        XCTAssertEqual(vm.selectedVideoIDs, ["in2025"])
        let shown = vm.pickerVisibleVideos(calendar: utc).map(\.id)
        XCTAssertEqual(shown, ["in2024"])
    }

    func testChipTop20SelectsLargest() async {
        let library = MockVideoLibraryService()
        library.fetchVideosResult = [
            video("a", seconds: 1),
            video("b", seconds: 2),
            video("c", seconds: 3),
        ]
        library.fetchSizesResult = ["a": 1, "b": 50, "c": 20]
        let vm = makeViewModel(library: library)
        vm.permissionState = .authorized
        vm.scanVideos()
        await TestWait.until { @MainActor in
            vm.hasCompletedScan && !vm.isFetchingAllVideoSizes
        }

        vm.selectPickerChip(.top20)
        XCTAssertEqual(vm.pickerFilter, .top20)
        await TestWait.until { @MainActor in
            vm.selectedVideoIDs.count == 3
        }
        XCTAssertEqual(vm.selectedVideoIDs, ["a", "b", "c"])
    }

    func testDriveFreeTextHiddenWhenCapacityUnknown() {
        let folder = URL(fileURLWithPath: "/Volumes/SanDisk")
        let reader = MockVolumeCapacityReader()
        reader.snapshotByPath[folder.path] = VolumeCapacitySnapshot(name: "SanDisk", totalBytes: 500, availableBytes: nil)
        let vm = makeViewModel(reader: reader)
        XCTAssertNil(vm.pickerDriveFreeText)

        vm.setSelectedFolder(folder)
        XCTAssertNil(vm.pickerDriveFreeText)

        reader.snapshotByPath[folder.path] = VolumeCapacitySnapshot(
            name: "SanDisk",
            totalBytes: 500_000_000_000,
            availableBytes: 212_000_000_000
        )
        vm.rescanFolderAccess()
        XCTAssertEqual(vm.pickerDriveFreeText, PickerTrayText.driveFreeText(freeBytes: 212_000_000_000))
    }

    private let utc = PickerFilterCalendar.offset(secondsFromGMT: 0)

    private func makeViewModel(
        library: MockVideoLibraryService = MockVideoLibraryService(),
        reader: MockVolumeCapacityReader = MockVolumeCapacityReader()
    ) -> HomeViewModel {
        HomeViewModel(
            photoPermissionService: MockPhotoPermissionService(),
            externalStorageService: MockExternalStorageService(),
            videoLibraryService: library,
            videoMigrationService: MockVideoMigrationService(),
            photoDeletionService: MockPhotoDeletionService(),
            volumeCapacityReader: reader
        )
    }

    private func video(_ id: String, seconds: TimeInterval) -> VideoAssetSummary {
        VideoAssetSummary(
            id: id,
            creationDate: Date(timeIntervalSince1970: seconds),
            duration: 1,
            pixelWidth: 1,
            pixelHeight: 1
        )
    }
}

private enum PickerFilterCalendar {
    static func offset(secondsFromGMT: Int) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: secondsFromGMT)!
        return calendar
    }
}
