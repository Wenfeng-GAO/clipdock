import XCTest
@testable import ClipDock

@MainActor
final class DeletionResultMathTests: XCTestCase {
    func testPendingReleaseTotalSumsItemBytes() {
        XCTAssertEqual(PendingReleaseTotal(itemBytes: []).bytes, 0)
        XCTAssertEqual(PendingReleaseTotal(itemBytes: [0]).bytes, 0)
        XCTAssertEqual(PendingReleaseTotal(itemBytes: [10, 20, 30]).bytes, 60)

        // Mock screen 03: 3.8 + 3.1 + 2.6 + 2.2 + 1.7 = 13.4 GB (decimal).
        let itemBytes: [Int64] = [
            3_800_000_000,
            3_100_000_000,
            2_600_000_000,
            2_200_000_000,
            1_700_000_000,
        ]
        XCTAssertEqual(PendingReleaseTotal(itemBytes: itemBytes).bytes, 13_400_000_000)

        let snapshot = DeletionResultSnapshot(deletedSuccesses: itemBytes.enumerated().map { index, bytes in
            MigrationItemSuccess(
                assetID: "id-\(index)",
                destinationURL: URL(fileURLWithPath: "/tmp/\(index)"),
                bytes: bytes
            )
        })
        XCTAssertEqual(snapshot.pendingReleaseBytes, 13_400_000_000)
        XCTAssertEqual(snapshot.copiedCount, 5)
        XCTAssertEqual(snapshot.verifiedMatchCount, 5)
        XCTAssertEqual(snapshot.verifiedTotalCount, 5)
    }

    func testFreedSpaceDeltaIsPositiveOnly() {
        XCTAssertEqual(FreedSpaceDelta.freedBytes(before: 1_000, after: 2_500), 1_500)
        XCTAssertEqual(FreedSpaceDelta.freedBytes(before: 0, after: 1), 1)
        XCTAssertNil(FreedSpaceDelta.freedBytes(before: 1_000, after: 1_000))
        XCTAssertNil(FreedSpaceDelta.freedBytes(before: 0, after: 0))
        XCTAssertNil(FreedSpaceDelta.freedBytes(before: 5_000, after: 4_999))
        XCTAssertNil(FreedSpaceDelta.freedBytes(before: Int64.max, after: Int64.min))
    }

    func testReviewIsAllowedOnceAndOnlyWhenWithinTolerance() {
        XCTAssertFalse(ReviewPromptPolicy.shouldRequestReview(withinTolerance: false, alreadyRequested: false))
        XCTAssertFalse(ReviewPromptPolicy.shouldRequestReview(withinTolerance: false, alreadyRequested: true))
        XCTAssertTrue(ReviewPromptPolicy.shouldRequestReview(withinTolerance: true, alreadyRequested: false))
        XCTAssertFalse(ReviewPromptPolicy.shouldRequestReview(withinTolerance: true, alreadyRequested: true))
    }

    func testWithinToleranceIsInclusiveAtFivePercent() {
        XCTAssertTrue(FreedSpaceTolerance.withinTolerance(freed: 950, expected: 1_000))
        XCTAssertTrue(FreedSpaceTolerance.withinTolerance(freed: 1_050, expected: 1_000))
        XCTAssertFalse(FreedSpaceTolerance.withinTolerance(freed: 949, expected: 1_000))
        XCTAssertFalse(FreedSpaceTolerance.withinTolerance(freed: 1_051, expected: 1_000))

        let expected: Int64 = 10_000_000_000
        XCTAssertFalse(FreedSpaceTolerance.withinTolerance(freed: 9_490_000_000, expected: expected))
        XCTAssertTrue(FreedSpaceTolerance.withinTolerance(freed: 9_500_000_000, expected: expected))
        XCTAssertTrue(FreedSpaceTolerance.withinTolerance(freed: 10_500_000_000, expected: expected))
        XCTAssertFalse(FreedSpaceTolerance.withinTolerance(freed: 10_510_000_000, expected: expected))

        XCTAssertFalse(FreedSpaceTolerance.withinTolerance(freed: 0, expected: 0))
        XCTAssertFalse(FreedSpaceTolerance.withinTolerance(freed: 1, expected: 0))
        XCTAssertFalse(FreedSpaceTolerance.withinTolerance(freed: -1, expected: -5))
        XCTAssertFalse(FreedSpaceTolerance.withinTolerance(freed: 100, expected: -100))
    }

    func testSnapshotUsesEligibilityCountsAndOnlyDeletableBytes() {
        let items = [
            CopyItemState(assetID: "A", expectedBytes: 100, actualBytes: 100, status: .verified),
            CopyItemState(assetID: "B", expectedBytes: 999, actualBytes: 10, status: .mismatch(expected: 999, actual: 10)),
            CopyItemState(assetID: "C", expectedBytes: 50, actualBytes: 50, status: .verified),
            CopyItemState(assetID: "D", expectedBytes: 8, status: .failed("export failed")),
        ]
        let eligibility = CopyDeletionPolicy.eligibility(for: items)
        let copiedCount = eligibility.verifiedCount + eligibility.mismatchCount
        let successes = [
            MigrationItemSuccess(assetID: "A", destinationURL: URL(fileURLWithPath: "/tmp/a"), bytes: 1),
            MigrationItemSuccess(assetID: "Z", destinationURL: URL(fileURLWithPath: "/tmp/z"), bytes: 7),
        ]
        let snapshot = DeletionResultSnapshot(
            copiedCount: copiedCount,
            verifiedMatchCount: eligibility.verifiedCount,
            verifiedTotalCount: copiedCount,
            pendingReleaseBytes: PendingReleaseTotal.releasedBytes(
                deletableAssetIDs: eligibility.deletableAssetIDs,
                items: items,
                successes: successes
            )
        )

        XCTAssertEqual(eligibility.deletableAssetIDs, ["A", "C"])
        XCTAssertEqual(snapshot.copiedCount, 3)
        XCTAssertEqual(snapshot.verifiedMatchCount, 2)
        XCTAssertEqual(snapshot.verifiedTotalCount, 3)
        // Copy-item sizes win over the success row's 1 byte. The mismatch and the failure are not released.
        XCTAssertEqual(snapshot.pendingReleaseBytes, 150)
        XCTAssertEqual(
            PendingReleaseTotal.releasedBytes(
                deletableAssetIDs: ["A", "Z"],
                items: items,
                successes: successes
            ),
            107
        )
    }

    func testPhotosRedirectOnlyLaunchesPhotos() {
        XCTAssertEqual(PhotosRedirect.url.absoluteString, "photos-redirect://")
    }
}

@MainActor
final class DeletionResultViewModelTests: XCTestCase {
    func testPositiveDeltaShowsFreedSpaceAndRequestsReviewOnce() {
        let space = ScriptedFreeSpaceMonitor([1_000, 2_500, 3_200])
        let review = RecordingReviewRequester()
        let opener = RecordingPhotosOpener()
        let vm = makeViewModel(bytes: [1_500], space: space, review: review, opener: opener)

        vm.openPhotos()
        XCTAssertEqual(opener.openCount, 1)
        XCTAssertEqual(space.readCount, 1)

        // Still in the foreground: do not treat this as a return.
        vm.handleScenePhase(.active)
        XCTAssertNil(vm.freedBytes)
        XCTAssertFalse(vm.showsFreedSpace)
        XCTAssertEqual(review.requestCount, 0)
        XCTAssertEqual(space.readCount, 1)

        leaveAndReturn(vm)
        XCTAssertEqual(vm.freedBytes, 1_500)
        XCTAssertTrue(vm.showsFreedSpace)
        XCTAssertEqual(review.requestCount, 1)

        // A second return can refresh the number, but the review is once per result.
        leaveAndReturn(vm)
        XCTAssertEqual(vm.freedBytes, 2_200)
        XCTAssertEqual(review.requestCount, 1)

        // An immediate active event does not sample or review again.
        vm.handleScenePhase(.active)
        XCTAssertEqual(space.readCount, 3)
        XCTAssertEqual(review.requestCount, 1)
    }

    func testZeroDeltaIsNotShownAndDoesNotRequestReview() {
        let space = ScriptedFreeSpaceMonitor([4_000, 4_000])
        let review = RecordingReviewRequester()
        let vm = makeViewModel(space: space, review: review, opener: RecordingPhotosOpener())

        vm.openPhotos()
        leaveAndReturn(vm, via: .inactive)

        XCTAssertNil(vm.freedBytes)
        XCTAssertFalse(vm.showsFreedSpace)
        XCTAssertEqual(review.requestCount, 0)
    }

    func testNegativeDeltaIsNotShownAndDoesNotRequestReview() {
        let space = ScriptedFreeSpaceMonitor([9_000, 1_000])
        let review = RecordingReviewRequester()
        let vm = makeViewModel(space: space, review: review, opener: RecordingPhotosOpener())

        vm.openPhotos()
        leaveAndReturn(vm)

        XCTAssertNil(vm.freedBytes)
        XCTAssertFalse(vm.showsFreedSpace)
        XCTAssertEqual(review.requestCount, 0)
    }

    func testMissingReadingDoesNotShowFreedSpaceOrRequestReview() {
        let review = RecordingReviewRequester()

        let missingBaseline = makeViewModel(
            space: ScriptedFreeSpaceMonitor([nil, 5_000]),
            review: review,
            opener: RecordingPhotosOpener()
        )
        missingBaseline.openPhotos()
        leaveAndReturn(missingBaseline)
        XCTAssertNil(missingBaseline.freedBytes)
        XCTAssertEqual(review.requestCount, 0)

        let missingReturn = makeViewModel(
            space: ScriptedFreeSpaceMonitor([1_000, nil]),
            review: review,
            opener: RecordingPhotosOpener()
        )
        missingReturn.openPhotos()
        leaveAndReturn(missingReturn)
        XCTAssertNil(missingReturn.freedBytes)
        XCTAssertEqual(review.requestCount, 0)
    }

    func testReviewWaitsForAPositiveDeltaThenFiresOnce() {
        let space = ScriptedFreeSpaceMonitor([100, 100, 80, 260])
        let review = RecordingReviewRequester()
        let vm = makeViewModel(bytes: [160], space: space, review: review, opener: RecordingPhotosOpener())

        vm.openPhotos()
        leaveAndReturn(vm)
        XCTAssertNil(vm.freedBytes)
        XCTAssertEqual(review.requestCount, 0)

        leaveAndReturn(vm, via: .inactive)
        XCTAssertNil(vm.freedBytes)
        XCTAssertEqual(review.requestCount, 0)

        leaveAndReturn(vm)
        XCTAssertEqual(vm.freedBytes, 160)
        XCTAssertEqual(review.requestCount, 1)

        leaveAndReturn(vm)
        XCTAssertEqual(vm.freedBytes, 160)
        XCTAssertEqual(review.requestCount, 1)
    }

    func testShownFreedSpaceStaysWhenALaterDeltaIsNotPositive() {
        let space = ScriptedFreeSpaceMonitor([1_000, 1_800, 1_000])
        let review = RecordingReviewRequester()
        let vm = makeViewModel(bytes: [800], space: space, review: review, opener: RecordingPhotosOpener())

        vm.openPhotos()
        leaveAndReturn(vm)
        XCTAssertEqual(vm.freedBytes, 800)
        XCTAssertEqual(review.requestCount, 1)

        leaveAndReturn(vm)
        XCTAssertEqual(vm.freedBytes, 800)
        XCTAssertEqual(review.requestCount, 1)
    }

    func testSceneChangesBeforeOpeningPhotosDoNotRequestReview() {
        let space = ScriptedFreeSpaceMonitor([100, 999])
        let review = RecordingReviewRequester()
        let vm = makeViewModel(space: space, review: review, opener: RecordingPhotosOpener())

        leaveAndReturn(vm)
        XCTAssertNil(vm.freedBytes)
        XCTAssertEqual(review.requestCount, 0)
        XCTAssertEqual(space.readCount, 0)
    }

    func testOpenPhotosRecordsFreeSpaceBeforeOpening() {
        let spy = FreeSpaceOpenOrderSpy()
        let vm = DeletionResultViewModel(
            snapshot: DeletionResultSnapshot(deletedSuccesses: []),
            freeSpaceMonitor: spy,
            reviewRequester: RecordingReviewRequester(),
            photosOpener: spy
        )

        vm.openPhotos()
        XCTAssertEqual(spy.events, ["measure", "open"])
    }

    func testViewModelPendingReleaseTotalUsesDeletedBytesOnly() {
        let vm = makeViewModel(
            bytes: [400, 50],
            space: ScriptedFreeSpaceMonitor([]),
            review: RecordingReviewRequester(),
            opener: RecordingPhotosOpener()
        )
        XCTAssertEqual(vm.pendingReleaseBytes, 450)
        XCTAssertEqual(vm.snapshot.copiedCount, 2)
        XCTAssertFalse(vm.showsFreedSpace)
    }

    func testWithinToleranceShowsCheckAndRequestsReviewOnce() {
        let space = ScriptedFreeSpaceMonitor([0, 950, 1_050])
        let review = RecordingReviewRequester()
        let vm = makeViewModel(bytes: [1_000], space: space, review: review, opener: RecordingPhotosOpener())

        vm.openPhotos()
        leaveAndReturn(vm)

        let freed = vm.freedBytes
        let within = vm.isFreedWithinTolerance
        let shows = vm.showsFreedSpace
        let reviews = review.requestCount
        XCTAssertEqual(freed, 950)
        XCTAssertTrue(shows)
        XCTAssertTrue(within)
        XCTAssertEqual(reviews, 1)

        leaveAndReturn(vm)
        let freedAgain = vm.freedBytes
        let withinAgain = vm.isFreedWithinTolerance
        let reviewsAgain = review.requestCount
        XCTAssertEqual(freedAgain, 1_050)
        XCTAssertTrue(withinAgain)
        XCTAssertEqual(reviewsAgain, 1)
    }

    func testOutsideToleranceShowsFigureWithoutCheckOrReview() {
        let belowSpace = ScriptedFreeSpaceMonitor([0, 949])
        let belowReview = RecordingReviewRequester()
        let below = makeViewModel(bytes: [1_000], space: belowSpace, review: belowReview, opener: RecordingPhotosOpener())
        below.openPhotos()
        leaveAndReturn(below)
        let belowFreed = below.freedBytes
        let belowWithin = below.isFreedWithinTolerance
        let belowShows = below.showsFreedSpace
        let belowReviews = belowReview.requestCount
        XCTAssertEqual(belowFreed, 949)
        XCTAssertTrue(belowShows)
        XCTAssertFalse(belowWithin)
        XCTAssertEqual(belowReviews, 0)

        let aboveSpace = ScriptedFreeSpaceMonitor([0, 1_051])
        let aboveReview = RecordingReviewRequester()
        let above = makeViewModel(bytes: [1_000], space: aboveSpace, review: aboveReview, opener: RecordingPhotosOpener())
        above.openPhotos()
        leaveAndReturn(above)
        let aboveFreed = above.freedBytes
        let aboveWithin = above.isFreedWithinTolerance
        let aboveReviews = aboveReview.requestCount
        XCTAssertEqual(aboveFreed, 1_051)
        XCTAssertFalse(aboveWithin)
        XCTAssertEqual(aboveReviews, 0)
    }

    func testZeroPendingReleaseIsNeverWithinTolerance() {
        let space = ScriptedFreeSpaceMonitor([100, 500])
        let review = RecordingReviewRequester()
        let vm = makeViewModel(bytes: [], space: space, review: review, opener: RecordingPhotosOpener())

        vm.openPhotos()
        leaveAndReturn(vm)

        let freed = vm.freedBytes
        let within = vm.isFreedWithinTolerance
        let reviews = review.requestCount
        XCTAssertEqual(freed, 400)
        XCTAssertFalse(within)
        XCTAssertEqual(reviews, 0)
    }

    func testRemeasureAfterDelayUpdatesFreedBytesAndRequestsReviewOnce() async {
        let space = ScriptedFreeSpaceMonitor([0, 1_000, 10_000])
        let review = RecordingReviewRequester()
        let sleeper = PausingSleep()
        let vm = makeViewModel(
            bytes: [10_000],
            space: space,
            review: review,
            opener: RecordingPhotosOpener(),
            sleep: { nanoseconds in
                await sleeper.sleep(nanoseconds)
            }
        )

        vm.openPhotos()
        vm.handleScenePhase(.background)
        vm.handleScenePhase(.active)
        await TestWait.until { sleeper.isWaiting }

        let immediateFreed = vm.freedBytes
        let immediateWithin = vm.isFreedWithinTolerance
        let immediateReviews = review.requestCount
        let delays = sleeper.recordedDelays()
        let readsAfterImmediate = space.readCount
        XCTAssertEqual(immediateFreed, 1_000)
        XCTAssertFalse(immediateWithin)
        XCTAssertEqual(immediateReviews, 0)
        XCTAssertEqual(delays, [DeletionResultViewModel.remeasureDelayNanoseconds])
        XCTAssertEqual(DeletionResultViewModel.remeasureDelayNanoseconds, 3_000_000_000)
        XCTAssertEqual(readsAfterImmediate, 2)

        sleeper.resumeNext()
        await TestWait.until { @MainActor in
            vm.freedBytes == 10_000
        }

        let freed = vm.freedBytes
        let within = vm.isFreedWithinTolerance
        let reviews = review.requestCount
        let reads = space.readCount
        XCTAssertEqual(freed, 10_000)
        XCTAssertTrue(within)
        XCTAssertEqual(reviews, 1)
        XCTAssertEqual(reads, 3)

        vm.handleScenePhase(.background)
        vm.handleScenePhase(.active)
        let freedAgain = vm.freedBytes
        let withinAgain = vm.isFreedWithinTolerance
        let reviewsAgain = review.requestCount
        XCTAssertEqual(freedAgain, 10_000)
        XCTAssertTrue(withinAgain)
        XCTAssertEqual(reviewsAgain, 1)
        vm.handleScenePhase(.inactive)
    }

    func testRemeasureAfterAZeroDeltaCanBecomeWithinTolerance() async {
        let space = ScriptedFreeSpaceMonitor([5_000, 5_000, 6_000])
        let review = RecordingReviewRequester()
        let sleeper = PausingSleep()
        let vm = makeViewModel(
            bytes: [1_000],
            space: space,
            review: review,
            opener: RecordingPhotosOpener(),
            sleep: { nanoseconds in
                await sleeper.sleep(nanoseconds)
            }
        )

        vm.openPhotos()
        vm.handleScenePhase(.background)
        vm.handleScenePhase(.active)
        await TestWait.until { sleeper.isWaiting }

        let freedBefore = vm.freedBytes
        let reviewsBefore = review.requestCount
        XCTAssertNil(freedBefore)
        XCTAssertEqual(reviewsBefore, 0)

        sleeper.resumeNext()
        await TestWait.until { @MainActor in
            vm.freedBytes == 1_000
        }

        let freed = vm.freedBytes
        let within = vm.isFreedWithinTolerance
        let reviews = review.requestCount
        XCTAssertEqual(freed, 1_000)
        XCTAssertTrue(within)
        XCTAssertEqual(reviews, 1)
        vm.handleScenePhase(.background)
    }

    func testLeavingAgainCancelsThePendingRemeasure() async {
        let space = ScriptedFreeSpaceMonitor([1_000, 2_000, 1_500])
        let review = RecordingReviewRequester()
        let sleeper = PausingSleep()
        let vm = makeViewModel(
            bytes: [500],
            space: space,
            review: review,
            opener: RecordingPhotosOpener(),
            sleep: { nanoseconds in
                await sleeper.sleep(nanoseconds)
            }
        )

        vm.openPhotos()
        vm.handleScenePhase(.background)
        vm.handleScenePhase(.active)
        await TestWait.until { sleeper.isWaiting }

        let freed = vm.freedBytes
        let reads = space.readCount
        XCTAssertEqual(freed, 1_000)
        XCTAssertEqual(reads, 2)

        vm.handleScenePhase(.inactive)
        await TestWait.until { !sleeper.isWaiting }
        await Task.yield()

        let freedAfterCancel = vm.freedBytes
        let readsAfterCancel = space.readCount
        let reviewsAfterCancel = review.requestCount
        XCTAssertEqual(freedAfterCancel, 1_000)
        XCTAssertEqual(readsAfterCancel, 2)
        XCTAssertEqual(reviewsAfterCancel, 0)

        vm.handleScenePhase(.active)
        let freedOnReturn = vm.freedBytes
        let within = vm.isFreedWithinTolerance
        let reviews = review.requestCount
        let readsOnReturn = space.readCount
        XCTAssertEqual(freedOnReturn, 500)
        XCTAssertTrue(within)
        XCTAssertEqual(reviews, 1)
        XCTAssertEqual(readsOnReturn, 3)
        vm.handleScenePhase(.background)
    }

    func testReleasingTheResultCancelsThePendingRemeasure() async {
        let space = ScriptedFreeSpaceMonitor([100, 200, 9_999])
        let sleeper = PausingSleep()
        var vm: DeletionResultViewModel? = makeViewModel(
            bytes: [100],
            space: space,
            review: RecordingReviewRequester(),
            opener: RecordingPhotosOpener(),
            sleep: { nanoseconds in
                await sleeper.sleep(nanoseconds)
            }
        )
        vm?.openPhotos()
        vm?.handleScenePhase(.background)
        vm?.handleScenePhase(.active)
        await TestWait.until { sleeper.isWaiting }

        let reads = space.readCount
        XCTAssertEqual(reads, 2)
        vm = nil
        await TestWait.until { !sleeper.isWaiting }
        await Task.yield()
        let readsAfter = space.readCount
        XCTAssertEqual(readsAfter, 2)
    }

    private func makeViewModel(
        bytes: [Int64] = [100],
        space: DeviceFreeSpaceMeasuring,
        review: ReviewRequesting,
        opener: PhotosAppOpening,
        sleep: @escaping @Sendable (UInt64) async -> Void = { _ in
            try? await Task.sleep(nanoseconds: 60_000_000_000)
        }
    ) -> DeletionResultViewModel {
        let successes = bytes.enumerated().map { index, count in
            MigrationItemSuccess(
                assetID: "id-\(index)",
                destinationURL: URL(fileURLWithPath: "/tmp/\(index)"),
                bytes: count
            )
        }
        return DeletionResultViewModel(
            snapshot: DeletionResultSnapshot(deletedSuccesses: successes),
            freeSpaceMonitor: space,
            reviewRequester: review,
            photosOpener: opener,
            sleep: sleep
        )
    }

    private func leaveAndReturn(_ vm: DeletionResultViewModel, via phase: ResultScenePhase = .background) {
        vm.handleScenePhase(phase)
        vm.handleScenePhase(.active)
    }
}

final class HomeViewModelDeletionResultTests: XCTestCase {
    func testSuccessfulDeletionPresentsPendingReleaseExcludingFailures() async throws {
        let vm = await MainActor.run {
            HomeViewModel(
                photoPermissionService: MockPhotoPermissionService(),
                externalStorageService: MockExternalStorageService(),
                videoLibraryService: MockVideoLibraryService(),
                videoMigrationService: MockVideoMigrationService(),
                photoDeletionService: MockPhotoDeletionService()
            )
        }

        await MainActor.run {
            vm.permissionState = .authorized
            vm.lastMigrationResult = MigrationRunResult(
                successes: [
                    MigrationItemSuccess(assetID: "A", destinationURL: URL(fileURLWithPath: "/tmp/a"), bytes: 100),
                    MigrationItemSuccess(assetID: "B", destinationURL: URL(fileURLWithPath: "/tmp/b"), bytes: 250),
                ],
                failures: [
                    MigrationItemFailure(assetID: "C", message: "mismatch"),
                ]
            )
            vm.deleteMigratedOriginals()
        }

        await TestWait.until {
            await MainActor.run { vm.deletionResultModel != nil && !vm.isScanningVideos && !vm.isDeleting }
        }

        let values = try await MainActor.run { () -> (Int64, Int, Int, Int, Bool) in
            let presented = try XCTUnwrap(vm.deletionResultModel)
            return (Int64(presented.pendingReleaseBytes), presented.snapshot.copiedCount,
                    presented.snapshot.verifiedMatchCount, presented.snapshot.verifiedTotalCount,
                    presented.showsFreedSpace)
        }
        XCTAssertEqual(values.0, 350)
        XCTAssertEqual(values.1, 2)
        XCTAssertEqual(values.2, 2)
        XCTAssertEqual(values.3, 2)
        XCTAssertFalse(values.4)
        let alert = await MainActor.run { vm.alertMessage }
        XCTAssertNil(alert)
    }

    func testFailedDeletionDoesNotPresentResult() async {
        let deletion = MockPhotoDeletionService()
        deletion.errorToThrow = StubDeletionError()
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
            vm.lastMigrationResult = MigrationRunResult(
                successes: [
                    MigrationItemSuccess(assetID: "A", destinationURL: URL(fileURLWithPath: "/tmp/a"), bytes: 80),
                ],
                failures: []
            )
            vm.deleteMigratedOriginals()
        }

        await TestWait.until {
            await MainActor.run { !deletion.deleteCalls.isEmpty && !vm.isDeleting }
        }

        let presented = await MainActor.run { vm.deletionResultModel }
        let alert = await MainActor.run { vm.alertMessage }
        XCTAssertNil(presented)
        XCTAssertNotNil(alert)
    }

    func testCopyBatchDeletionKeepsEligibilityCountsAndDeletableBytes() async throws {
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
            vm.copyItems = [
                CopyItemState(assetID: "A", displayName: "a.mov", expectedBytes: 100, actualBytes: 100, destinationURL: URL(fileURLWithPath: "/tmp/a.mov"), status: .verified),
                CopyItemState(assetID: "B", displayName: "b.mov", expectedBytes: 999, actualBytes: 10, destinationURL: URL(fileURLWithPath: "/tmp/b.mov"), status: .mismatch(expected: 999, actual: 10)),
                CopyItemState(assetID: "C", displayName: "c.mov", expectedBytes: 50, actualBytes: 50, destinationURL: URL(fileURLWithPath: "/tmp/c.mov"), status: .verified),
                CopyItemState(assetID: "D", displayName: "d.mov", expectedBytes: 8, status: .failed("export failed")),
            ]
            vm.lastMigrationResult = MigrationRunResult(
                successes: [
                    MigrationItemSuccess(assetID: "A", destinationURL: URL(fileURLWithPath: "/tmp/a"), bytes: 1),
                    MigrationItemSuccess(assetID: "C", destinationURL: URL(fileURLWithPath: "/tmp/c"), bytes: 2),
                ],
                failures: []
            )
            vm.deleteMigratedOriginals()
        }

        await TestWait.until {
            await MainActor.run { vm.deletionResultModel != nil && !vm.isDeleting }
        }

        let deleted = await MainActor.run { deletion.deleteCalls }
        let counts = try await MainActor.run { () -> (Int, Int, Int, Int64) in
            let snapshot = try XCTUnwrap(vm.deletionResultModel).snapshot
            return (
                snapshot.copiedCount,
                snapshot.verifiedMatchCount,
                snapshot.verifiedTotalCount,
                snapshot.pendingReleaseBytes
            )
        }
        XCTAssertEqual(deleted, [["A", "C"]])
        XCTAssertEqual(counts.0, 3)
        XCTAssertEqual(counts.1, 2)
        XCTAssertEqual(counts.2, 3)
        XCTAssertEqual(counts.3, 150)
    }
}

@MainActor
private final class ScriptedFreeSpaceMonitor: DeviceFreeSpaceMeasuring {
    private let readings: [Int64?]
    private(set) var readCount = 0

    init(_ readings: [Int64?]) {
        self.readings = readings
    }

    func availableCapacityBytes() -> Int64? {
        let index = readCount
        readCount += 1
        guard !readings.isEmpty else { return nil }
        if index < readings.count {
            return readings[index]
        }
        return readings[readings.count - 1]
    }
}

@MainActor
private final class RecordingReviewRequester: ReviewRequesting {
    private(set) var requestCount = 0

    func requestReview() {
        requestCount += 1
    }
}

@MainActor
private final class RecordingPhotosOpener: PhotosAppOpening {
    private(set) var openCount = 0

    func openPhotosApp() {
        openCount += 1
    }
}

@MainActor
private final class FreeSpaceOpenOrderSpy: DeviceFreeSpaceMeasuring, PhotosAppOpening {
    private(set) var events: [String] = []

    func availableCapacityBytes() -> Int64? {
        events.append("measure")
        return 10
    }

    func openPhotosApp() {
        events.append("open")
    }
}

private struct StubDeletionError: Error {}

/// Suspends a re-measure until the test resumes it, and wakes immediately if that task is cancelled.
private final class PausingSleep: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var cancelledIDs: Set<UUID> = []
    private var delays: [UInt64] = []

    var isWaiting: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !waiters.isEmpty
    }

    func recordedDelays() -> [UInt64] {
        lock.lock()
        defer { lock.unlock() }
        return delays
    }

    func sleep(_ nanoseconds: UInt64) async {
        let id = UUID()
        lock.lock()
        delays.append(nanoseconds)
        lock.unlock()

        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                if cancelledIDs.remove(id) != nil || Task.isCancelled {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                waiters[id] = continuation
                lock.unlock()
            }
        } onCancel: {
            self.cancel(id)
        }
    }

    func resumeNext() {
        lock.lock()
        let id = waiters.keys.first
        let continuation = id.flatMap { waiters.removeValue(forKey: $0) }
        lock.unlock()
        continuation?.resume()
    }

    private func cancel(_ id: UUID) {
        lock.lock()
        if let continuation = waiters.removeValue(forKey: id) {
            lock.unlock()
            continuation.resume()
            return
        }
        cancelledIDs.insert(id)
        lock.unlock()
    }
}
