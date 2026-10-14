import XCTest
@testable import ClipDock

final class VideoPickerFormattingTests: XCTestCase {
    private let iCloudMarker = "\u{2601}\u{FE0E}"

    func testDurationLabelUsesMinutesAndPaddedSeconds() {
        XCTAssertEqual(VideoPickerFormatting.durationLabel(seconds: 0), "0:00")
        XCTAssertEqual(VideoPickerFormatting.durationLabel(seconds: 58), "0:58")
        XCTAssertEqual(VideoPickerFormatting.durationLabel(seconds: 59), "0:59")
        XCTAssertEqual(VideoPickerFormatting.durationLabel(seconds: 60), "1:00")
        XCTAssertEqual(VideoPickerFormatting.durationLabel(seconds: 4 * 60 + 12), "4:12")
        XCTAssertEqual(VideoPickerFormatting.durationLabel(seconds: 6 * 60 + 1), "6:01")
        XCTAssertEqual(VideoPickerFormatting.durationLabel(seconds: 61 * 60 + 5), "61:05")
        XCTAssertEqual(VideoPickerFormatting.durationLabel(seconds: 252.4), "4:12")
        XCTAssertEqual(VideoPickerFormatting.durationLabel(seconds: -4), "0:00")
        XCTAssertEqual(VideoPickerFormatting.durationLabel(seconds: .nan), "0:00")
        XCTAssertEqual(VideoPickerFormatting.durationLabel(seconds: .infinity), "0:00")
    }

    func testSizeLabelExactVersusEstimate() {
        XCTAssertEqual(VideoPickerFormatting.sizeLabel(byteCount: 3_800_000_000, isEstimate: false), "3.8 GB")
        XCTAssertEqual(VideoPickerFormatting.sizeLabel(byteCount: 1_000_000_000, isEstimate: false), "1.0 GB")
        XCTAssertEqual(VideoPickerFormatting.sizeLabel(byteCount: 13_400_000_000, isEstimate: false), "13.4 GB")
        XCTAssertEqual(VideoPickerFormatting.sizeLabel(byteCount: 1_200_000_000, isEstimate: true), "≈1.2 GB")
        XCTAssertEqual(VideoPickerFormatting.sizeLabel(byteCount: 900_000_000, isEstimate: false), "900 MB")
        XCTAssertEqual(VideoPickerFormatting.sizeLabel(byteCount: 1_500_000, isEstimate: false), "1.5 MB")
        XCTAssertEqual(VideoPickerFormatting.sizeLabel(byteCount: nil, isEstimate: true), "--")
        XCTAssertEqual(VideoPickerFormatting.sizeLabel(byteCount: 0, isEstimate: false), "0 GB")
        XCTAssertFalse(VideoPickerFormatting.sizeLabel(byteCount: 3_800_000_000, isEstimate: false).contains("≈"))
        XCTAssertTrue(VideoPickerFormatting.sizeLabel(byteCount: 1_200_000_000, isEstimate: true).hasPrefix("≈"))
    }

    func testCellContentCloudOnlyReplacesDurationAndPrefixesEstimate() {
        let cloud = VideoPickerCellContent.make(
            durationSeconds: 81,
            exactByteCount: nil,
            estimateByteCount: 1_200_000_000,
            isCloudOnly: true
        )
        XCTAssertEqual(cloud.leadingText, iCloudMarker)
        XCTAssertEqual(cloud.sizeText, "≈1.2 GB")
        XCTAssertTrue(cloud.isCloudOnly)

        let local = VideoPickerCellContent.make(
            durationSeconds: 252,
            exactByteCount: 3_800_000_000,
            estimateByteCount: 1_200_000_000,
            isCloudOnly: false
        )
        XCTAssertEqual(local.leadingText, "4:12")
        XCTAssertEqual(local.sizeText, "3.8 GB")
        XCTAssertFalse(local.isCloudOnly)
    }

    func testRunningTotalIncludesEstimatedItems() {
        let sizes = mockSizes()
        let selected: Set<String> = ["a", "b", "c", "d", "e"]
        let total = VideoPickerFormatting.runningTotal(selectedIDs: selected, sizes: sizes)

        XCTAssertEqual(total.count, 5)
        XCTAssertEqual(total.byteCount, 13_400_000_000)
        XCTAssertFalse(total.includesEstimate)
        XCTAssertEqual(total.sizeLabel, "13.4 GB")
        XCTAssertTrue(total.displayText.contains("13.4 GB"))
        XCTAssertTrue(total.displayText.contains("5"))

        let withCloud = VideoPickerFormatting.runningTotal(
            selectedIDs: selected.union(["cloud"]),
            sizes: sizes
        )
        XCTAssertEqual(withCloud.count, 6)
        XCTAssertEqual(withCloud.byteCount, 14_600_000_000)
        XCTAssertTrue(withCloud.includesEstimate)
        XCTAssertEqual(withCloud.sizeLabel, "≈14.6 GB")

        let onlyCloud = VideoPickerFormatting.runningTotal(selectedIDs: ["cloud"], sizes: sizes)
        XCTAssertEqual(onlyCloud.count, 1)
        XCTAssertEqual(onlyCloud.byteCount, 1_200_000_000)
        XCTAssertEqual(onlyCloud.sizeLabel, "≈1.2 GB")

        let empty = VideoPickerFormatting.runningTotal(selectedIDs: [], sizes: sizes)
        XCTAssertEqual(empty.count, 0)
        XCTAssertEqual(empty.byteCount, 0)
        XCTAssertEqual(empty.sizeLabel, "0 GB")
    }

    func testTogglingSelectionUpdatesRunningTotal() {
        var state = VideoPickerSelectionState(sizes: [
            "local": VideoPickerItemSize(byteCount: 3_800_000_000, isEstimate: false),
            "cloud": VideoPickerItemSize(byteCount: 1_200_000_000, isEstimate: true),
        ])

        XCTAssertEqual(state.total.count, 0)
        XCTAssertEqual(state.total.byteCount, 0)
        XCTAssertEqual(state.total.sizeLabel, "0 GB")

        state.toggle("local")
        XCTAssertEqual(state.total.count, 1)
        XCTAssertEqual(state.total.byteCount, 3_800_000_000)
        XCTAssertFalse(state.total.includesEstimate)
        XCTAssertEqual(state.total.sizeLabel, "3.8 GB")

        state.toggle("cloud")
        XCTAssertEqual(state.selectedIDs, ["local", "cloud"])
        XCTAssertEqual(state.total.count, 2)
        XCTAssertEqual(state.total.byteCount, 5_000_000_000)
        XCTAssertTrue(state.total.includesEstimate)
        XCTAssertEqual(state.total.sizeLabel, "≈5.0 GB")

        state.toggle("local")
        XCTAssertEqual(state.total.count, 1)
        XCTAssertEqual(state.total.byteCount, 1_200_000_000)
        XCTAssertEqual(state.total.sizeLabel, "≈1.2 GB")

        state.toggle("cloud")
        XCTAssertTrue(state.selectedIDs.isEmpty)
        XCTAssertEqual(state.total.count, 0)
        XCTAssertEqual(state.total.byteCount, 0)
        XCTAssertEqual(state.total.sizeLabel, "0 GB")
        XCTAssertFalse(state.total.includesEstimate)
    }

    func testCloudEstimateClassifier() {
        let cloud = VideoCloudEstimateClassifier.estimateForAssetMissingLocalFile(
            locallyAvailable: false,
            resourceFileSize: 1_200_000_000
        )
        XCTAssertEqual(cloud, VideoCloudEstimate(isCloudOnly: true, estimatedByteCount: 1_200_000_000))

        let cloudWithoutSize = VideoCloudEstimateClassifier.estimateForAssetMissingLocalFile(
            locallyAvailable: false,
            resourceFileSize: nil
        )
        XCTAssertEqual(cloudWithoutSize, VideoCloudEstimate(isCloudOnly: true, estimatedByteCount: nil))

        XCTAssertNil(
            VideoCloudEstimateClassifier.estimateForAssetMissingLocalFile(
                locallyAvailable: true,
                resourceFileSize: 1_200_000_000
            )
        )

        let missingKey = VideoCloudEstimateClassifier.estimateForAssetMissingLocalFile(
            locallyAvailable: nil,
            resourceFileSize: 500
        )
        XCTAssertEqual(missingKey?.isCloudOnly, true)
        XCTAssertEqual(missingKey?.estimatedByteCount, 500)

        XCTAssertNil(
            VideoCloudEstimateClassifier.estimateForAssetMissingLocalFile(
                locallyAvailable: nil,
                resourceFileSize: nil
            )
        )
    }

    func testResourceValueParsing() {
        XCTAssertEqual(VideoCloudEstimateClassifier.locallyAvailable(fromRawValue: true), true)
        XCTAssertEqual(VideoCloudEstimateClassifier.locallyAvailable(fromRawValue: false), false)
        XCTAssertEqual(VideoCloudEstimateClassifier.locallyAvailable(fromRawValue: NSNumber(value: true)), true)
        XCTAssertEqual(VideoCloudEstimateClassifier.locallyAvailable(fromRawValue: NSNumber(value: false)), false)
        XCTAssertNil(VideoCloudEstimateClassifier.locallyAvailable(fromRawValue: NSNumber(value: 2)))
        XCTAssertNil(VideoCloudEstimateClassifier.locallyAvailable(fromRawValue: nil))

        XCTAssertEqual(
            VideoCloudEstimateClassifier.fileSizeBytes(fromRawValue: NSNumber(value: Int64(1_200_000_000))),
            1_200_000_000
        )
        XCTAssertEqual(VideoCloudEstimateClassifier.fileSizeBytes(fromRawValue: 42), 42)
        XCTAssertEqual(VideoCloudEstimateClassifier.fileSizeBytes(fromRawValue: Int64(8)), 8)
        XCTAssertNil(VideoCloudEstimateClassifier.fileSizeBytes(fromRawValue: NSNumber(value: true)))
        XCTAssertNil(VideoCloudEstimateClassifier.fileSizeBytes(fromRawValue: 0))
        XCTAssertNil(VideoCloudEstimateClassifier.fileSizeBytes(fromRawValue: nil))
    }

    private func mockSizes() -> [String: VideoPickerItemSize] {
        [
            "a": VideoPickerItemSize(byteCount: 3_800_000_000, isEstimate: false),
            "b": VideoPickerItemSize(byteCount: 3_100_000_000, isEstimate: false),
            "c": VideoPickerItemSize(byteCount: 2_600_000_000, isEstimate: false),
            "d": VideoPickerItemSize(byteCount: 2_200_000_000, isEstimate: false),
            "e": VideoPickerItemSize(byteCount: 1_700_000_000, isEstimate: false),
            "cloud": VideoPickerItemSize(byteCount: 1_200_000_000, isEstimate: true),
        ]
    }
}

final class HomeViewModelPickerTotalTests: XCTestCase {
    func testToggleSelectionUpdatesRunningTotalIncludingEstimates() async {
        let library = MockVideoLibraryService()
        library.fetchVideosResult = [
            .init(id: "local", creationDate: Date(timeIntervalSince1970: 3), duration: 252, pixelWidth: 1920, pixelHeight: 1080),
            .init(id: "cloud", creationDate: Date(timeIntervalSince1970: 2), duration: 80, pixelWidth: 1920, pixelHeight: 1080),
        ]
        library.fetchSizesResult = ["local": 3_800_000_000]
        library.fetchCloudEstimatesResult = [
            "cloud": VideoCloudEstimate(isCloudOnly: true, estimatedByteCount: 1_200_000_000),
        ]

        let vm = await MainActor.run {
            HomeViewModel(
                photoPermissionService: MockPhotoPermissionService(),
                externalStorageService: MockExternalStorageService(),
                videoLibraryService: library,
                videoMigrationService: MockVideoMigrationService(),
                photoDeletionService: MockPhotoDeletionService()
            )
        }

        await MainActor.run {
            vm.permissionState = .authorized
            vm.scanVideos()
        }

        await TestWait.until {
            await MainActor.run {
                !vm.isScanningVideos
                    && !vm.isFetchingAllVideoSizes
                    && vm.cloudEstimatesByID["cloud"] == 1_200_000_000
            }
        }

        let snapshot = await MainActor.run { () -> (Int64?, Bool, VideoPickerCellContent, VideoPickerCellContent) in
            let localVideo = VideoAssetSummary(
                id: "local",
                creationDate: .distantPast,
                duration: 252,
                pixelWidth: 1,
                pixelHeight: 1
            )
            let cloudVideo = VideoAssetSummary(
                id: "cloud",
                creationDate: .distantPast,
                duration: 80,
                pixelWidth: 1,
                pixelHeight: 1
            )
            return (
                vm.videoSizeBytesByID["local"],
                vm.cloudOnlyAssetIDs.contains("cloud"),
                vm.pickerCellContent(for: localVideo),
                vm.pickerCellContent(for: cloudVideo)
            )
        }

        XCTAssertEqual(snapshot.0, 3_800_000_000)
        XCTAssertNil(library.fetchSizesResult["cloud"])
        XCTAssertTrue(snapshot.1)
        XCTAssertEqual(snapshot.2.leadingText, "4:12")
        XCTAssertEqual(snapshot.2.sizeText, "3.8 GB")
        XCTAssertEqual(snapshot.3.leadingText, "\u{2601}\u{FE0E}")
        XCTAssertEqual(snapshot.3.sizeText, "≈1.2 GB")
        XCTAssertTrue(library.fetchCloudEstimatesCalls.contains { $0.contains("cloud") && !$0.contains("local") })

        let afterLocal = await MainActor.run { () -> VideoPickerRunningTotal in
            vm.toggleSelection(for: "local")
            return vm.pickerRunningTotal
        }
        XCTAssertEqual(afterLocal.count, 1)
        XCTAssertEqual(afterLocal.byteCount, 3_800_000_000)
        XCTAssertEqual(afterLocal.sizeLabel, "3.8 GB")
        XCTAssertFalse(afterLocal.includesEstimate)

        let afterBoth = await MainActor.run { () -> VideoPickerRunningTotal in
            vm.toggleSelection(for: "cloud")
            return vm.pickerRunningTotal
        }
        XCTAssertEqual(afterBoth.count, 2)
        XCTAssertEqual(afterBoth.byteCount, 5_000_000_000)
        XCTAssertEqual(afterBoth.sizeLabel, "≈5.0 GB")
        XCTAssertTrue(afterBoth.includesEstimate)

        let afterCloudOnly = await MainActor.run { () -> VideoPickerRunningTotal in
            vm.toggleSelection(for: "local")
            return vm.pickerRunningTotal
        }
        XCTAssertEqual(afterCloudOnly.count, 1)
        XCTAssertEqual(afterCloudOnly.byteCount, 1_200_000_000)
        XCTAssertEqual(afterCloudOnly.sizeLabel, "≈1.2 GB")
    }
}
