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

    func testResolveCoversPendingWithinAndOutsideIncludingBoundaries() {
        let expected: Int64 = 1_000

        XCTAssertEqual(
            FreedSpaceResultState.resolve(expectedBytes: expected, measuredFreedBytes: nil),
            .pendingRelease(expectedBytes: expected)
        )
        XCTAssertEqual(
            FreedSpaceResultState.resolve(expectedBytes: expected, measuredFreedBytes: 0),
            .pendingRelease(expectedBytes: expected)
        )
        XCTAssertEqual(
            FreedSpaceResultState.resolve(expectedBytes: expected, measuredFreedBytes: -1),
            .pendingRelease(expectedBytes: expected)
        )
        XCTAssertEqual(
            FreedSpaceResultState.resolve(expectedBytes: 0, measuredFreedBytes: nil),
            .pendingRelease(expectedBytes: 0)
        )
        XCTAssertEqual(
            FreedSpaceResultState.resolve(expectedBytes: 0, measuredFreedBytes: 0),
            .pendingRelease(expectedBytes: 0)
        )
        XCTAssertEqual(
            FreedSpaceResultState.resolve(expectedBytes: -5, measuredFreedBytes: -1),
            .pendingRelease(expectedBytes: -5)
        )

        XCTAssertEqual(
            FreedSpaceResultState.resolve(expectedBytes: expected, measuredFreedBytes: 950),
            .freedWithinTolerance(freedBytes: 950)
        )
        XCTAssertEqual(
            FreedSpaceResultState.resolve(expectedBytes: expected, measuredFreedBytes: 1_050),
            .freedWithinTolerance(freedBytes: 1_050)
        )
        XCTAssertEqual(
            FreedSpaceResultState.resolve(expectedBytes: expected, measuredFreedBytes: 949),
            .freedOutsideTolerance(freedBytes: 949, expectedBytes: expected)
        )
        XCTAssertEqual(
            FreedSpaceResultState.resolve(expectedBytes: expected, measuredFreedBytes: 1_051),
            .freedOutsideTolerance(freedBytes: 1_051, expectedBytes: expected)
        )

        let big: Int64 = 10_000_000_000
        XCTAssertEqual(
            FreedSpaceResultState.resolve(expectedBytes: big, measuredFreedBytes: 9_490_000_000),
            .freedOutsideTolerance(freedBytes: 9_490_000_000, expectedBytes: big)
        )
        XCTAssertEqual(
            FreedSpaceResultState.resolve(expectedBytes: big, measuredFreedBytes: 9_500_000_000),
            .freedWithinTolerance(freedBytes: 9_500_000_000)
        )
        XCTAssertEqual(
            FreedSpaceResultState.resolve(expectedBytes: big, measuredFreedBytes: 10_500_000_000),
            .freedWithinTolerance(freedBytes: 10_500_000_000)
        )
        XCTAssertEqual(
            FreedSpaceResultState.resolve(expectedBytes: big, measuredFreedBytes: 10_510_000_000),
            .freedOutsideTolerance(freedBytes: 10_510_000_000, expectedBytes: big)
        )

        XCTAssertEqual(
            FreedSpaceResultState.resolve(expectedBytes: 0, measuredFreedBytes: 1),
            .freedOutsideTolerance(freedBytes: 1, expectedBytes: 0)
        )
        XCTAssertEqual(
            FreedSpaceResultState.resolve(expectedBytes: -5, measuredFreedBytes: 10),
            .freedOutsideTolerance(freedBytes: 10, expectedBytes: -5)
        )

        // Tolerance is forwarded into withinTolerance: 90% is outside 5% and inside 10%.
        XCTAssertEqual(
            FreedSpaceResultState.resolve(expectedBytes: expected, measuredFreedBytes: 900),
            .freedOutsideTolerance(freedBytes: 900, expectedBytes: expected)
        )
        XCTAssertEqual(
            FreedSpaceResultState.resolve(expectedBytes: expected, measuredFreedBytes: 900, tolerance: 0.10),
            .freedWithinTolerance(freedBytes: 900)
        )

        let outside = FreedSpaceResultState.freedOutsideTolerance(freedBytes: 949, expectedBytes: expected)
        let outsideText = outside.freedStatusText
        XCTAssertEqual(
            outsideText,
            L10n.tr(
                "Freed %@ (est. %@)",
                ByteCountText.string(fromBytes: 949),
                ByteCountText.string(fromBytes: expected)
            )
        )
        XCTAssertFalse(outsideText?.contains("✓") ?? true)
        XCTAssertNil(FreedSpaceResultState.pendingRelease(expectedBytes: expected).freedStatusText)
        let withinText = FreedSpaceResultState.freedWithinTolerance(freedBytes: 950).freedStatusText
        XCTAssertEqual(withinText, L10n.tr("Back · Freed %@ ✓", ByteCountText.string(fromBytes: 950)))
        XCTAssertTrue(withinText?.contains("✓") == true)
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
    func testInitialStateIsPendingAndDoesNotRequestReview() {
        let review = RecordingReviewRequester()
        let vm = makeViewModel(
            bytes: [1_000],
            space: ScriptedFreeSpaceMonitor([]),
            review: review,
            opener: RecordingPhotosOpener()
        )

        XCTAssertEqual(vm.state, .pendingRelease(expectedBytes: 1_000))
        XCTAssertEqual(
            vm.state,
            FreedSpaceResultState.resolve(expectedBytes: 1_000, measuredFreedBytes: nil)
        )
        XCTAssertNil(vm.state.freedStatusText)
        XCTAssertEqual(review.requestCount, 0)
    }

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
        XCTAssertEqual(vm.state, .pendingRelease(expectedBytes: 1_500))
        XCTAssertEqual(review.requestCount, 0)
        XCTAssertEqual(space.readCount, 1)

        leaveAndReturn(vm)
        XCTAssertEqual(vm.state, .freedWithinTolerance(freedBytes: 1_500))
        XCTAssertTrue(vm.state.freedStatusText?.contains("✓") == true)
        XCTAssertEqual(review.requestCount, 1)

        // A later sample can move outside tolerance. The review stays once per result.
        leaveAndReturn(vm)
        XCTAssertEqual(vm.state, .freedOutsideTolerance(freedBytes: 2_200, expectedBytes: 1_500))
        XCTAssertFalse(vm.state.freedStatusText?.contains("✓") ?? true)
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

        XCTAssertEqual(vm.state, .pendingRelease(expectedBytes: 100))
        XCTAssertNil(vm.state.freedStatusText)
        XCTAssertEqual(review.requestCount, 0)
    }

    func testNegativeDeltaIsNotShownAndDoesNotRequestReview() {
        let space = ScriptedFreeSpaceMonitor([9_000, 1_000])
        let review = RecordingReviewRequester()
        let vm = makeViewModel(space: space, review: review, opener: RecordingPhotosOpener())

        vm.openPhotos()
        leaveAndReturn(vm)

        XCTAssertEqual(vm.state, .pendingRelease(expectedBytes: 100))
        XCTAssertNil(vm.state.freedStatusText)
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
        XCTAssertEqual(missingBaseline.state, .pendingRelease(expectedBytes: 100))
        XCTAssertEqual(review.requestCount, 0)

        let missingReturn = makeViewModel(
            space: ScriptedFreeSpaceMonitor([1_000, nil]),
            review: review,
            opener: RecordingPhotosOpener()
        )
        missingReturn.openPhotos()
        leaveAndReturn(missingReturn)
        XCTAssertEqual(missingReturn.state, .pendingRelease(expectedBytes: 100))
        XCTAssertEqual(review.requestCount, 0)
    }

    func testReviewWaitsForAPositiveDeltaThenFiresOnce() {
        let space = ScriptedFreeSpaceMonitor([100, 100, 80, 260])
        let review = RecordingReviewRequester()
        let vm = makeViewModel(bytes: [160], space: space, review: review, opener: RecordingPhotosOpener())

        vm.openPhotos()
        leaveAndReturn(vm)
        XCTAssertEqual(vm.state, .pendingRelease(expectedBytes: 160))
        XCTAssertEqual(review.requestCount, 0)

        leaveAndReturn(vm, via: .inactive)
        XCTAssertEqual(vm.state, .pendingRelease(expectedBytes: 160))
        XCTAssertEqual(review.requestCount, 0)

        leaveAndReturn(vm)
        XCTAssertEqual(vm.state, .freedWithinTolerance(freedBytes: 160))
        XCTAssertEqual(review.requestCount, 1)

        leaveAndReturn(vm)
        XCTAssertEqual(vm.state, .freedWithinTolerance(freedBytes: 160))
        XCTAssertEqual(review.requestCount, 1)
    }

    func testShownFreedSpaceStaysWhenALaterDeltaIsNotPositive() {
        let space = ScriptedFreeSpaceMonitor([1_000, 1_800, 1_000])
        let review = RecordingReviewRequester()
        let vm = makeViewModel(bytes: [800], space: space, review: review, opener: RecordingPhotosOpener())

        vm.openPhotos()
        leaveAndReturn(vm)
        XCTAssertEqual(vm.state, .freedWithinTolerance(freedBytes: 800))
        XCTAssertEqual(review.requestCount, 1)

        leaveAndReturn(vm)
        XCTAssertEqual(vm.state, .freedWithinTolerance(freedBytes: 800))
        XCTAssertEqual(review.requestCount, 1)
    }

    func testSceneChangesBeforeOpeningPhotosDoNotRequestReview() {
        let space = ScriptedFreeSpaceMonitor([100, 999])
        let review = RecordingReviewRequester()
        let vm = makeViewModel(space: space, review: review, opener: RecordingPhotosOpener())

        leaveAndReturn(vm)
        XCTAssertEqual(vm.state, .pendingRelease(expectedBytes: 100))
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
        XCTAssertEqual(vm.state, .pendingRelease(expectedBytes: 450))
    }

    func testWithinToleranceShowsCheckAndRequestsReviewOnce() {
        let space = ScriptedFreeSpaceMonitor([0, 950, 1_050])
        let review = RecordingReviewRequester()
        let vm = makeViewModel(bytes: [1_000], space: space, review: review, opener: RecordingPhotosOpener())

        vm.openPhotos()
        leaveAndReturn(vm)

        let state = vm.state
        let reviews = review.requestCount
        XCTAssertEqual(state, .freedWithinTolerance(freedBytes: 950))
        XCTAssertTrue(state.freedStatusText?.contains("✓") == true)
        XCTAssertEqual(reviews, 1)

        leaveAndReturn(vm)
        let stateAgain = vm.state
        let reviewsAgain = review.requestCount
        XCTAssertEqual(stateAgain, .freedWithinTolerance(freedBytes: 1_050))
        XCTAssertTrue(stateAgain.freedStatusText?.contains("✓") == true)
        XCTAssertEqual(reviewsAgain, 1)
    }

    func testOutsideToleranceShowsFigureWithoutCheckOrReview() {
        let belowSpace = ScriptedFreeSpaceMonitor([0, 949])
        let belowReview = RecordingReviewRequester()
        let below = makeViewModel(bytes: [1_000], space: belowSpace, review: belowReview, opener: RecordingPhotosOpener())
        below.openPhotos()
        leaveAndReturn(below)
        let belowState = below.state
        let belowReviews = belowReview.requestCount
        XCTAssertEqual(belowState, .freedOutsideTolerance(freedBytes: 949, expectedBytes: 1_000))
        XCTAssertEqual(
            belowState.freedStatusText,
            L10n.tr(
                "Freed %@ (est. %@)",
                ByteCountText.string(fromBytes: 949),
                ByteCountText.string(fromBytes: 1_000)
            )
        )
        XCTAssertFalse(belowState.freedStatusText?.contains("✓") ?? true)
        XCTAssertEqual(belowReviews, 0)

        let aboveSpace = ScriptedFreeSpaceMonitor([0, 1_051])
        let aboveReview = RecordingReviewRequester()
        let above = makeViewModel(bytes: [1_000], space: aboveSpace, review: aboveReview, opener: RecordingPhotosOpener())
        above.openPhotos()
        leaveAndReturn(above)
        let aboveState = above.state
        let aboveReviews = aboveReview.requestCount
        XCTAssertEqual(aboveState, .freedOutsideTolerance(freedBytes: 1_051, expectedBytes: 1_000))
        XCTAssertFalse(aboveState.freedStatusText?.contains("✓") ?? true)
        XCTAssertEqual(aboveReviews, 0)
    }

    func testZeroPendingReleaseIsNeverWithinTolerance() {
        let space = ScriptedFreeSpaceMonitor([100, 500])
        let review = RecordingReviewRequester()
        let vm = makeViewModel(bytes: [], space: space, review: review, opener: RecordingPhotosOpener())

        vm.openPhotos()
        leaveAndReturn(vm)

        let state = vm.state
        let reviews = review.requestCount
        XCTAssertEqual(state, .freedOutsideTolerance(freedBytes: 400, expectedBytes: 0))
        XCTAssertFalse(state.freedStatusText?.contains("✓") ?? true)
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

        let immediateState = vm.state
        let immediateReviews = review.requestCount
        let delays = sleeper.recordedDelays()
        let readsAfterImmediate = space.readCount
        XCTAssertEqual(immediateState, .freedOutsideTolerance(freedBytes: 1_000, expectedBytes: 10_000))
        XCTAssertFalse(immediateState.freedStatusText?.contains("✓") ?? true)
        XCTAssertEqual(immediateReviews, 0)
        XCTAssertEqual(delays, [DeletionResultViewModel.remeasureDelayNanoseconds])
        XCTAssertEqual(DeletionResultViewModel.remeasureDelayNanoseconds, 3_000_000_000)
        XCTAssertEqual(readsAfterImmediate, 2)

        sleeper.resumeNext()
        await TestWait.until { @MainActor in
            vm.state == .freedWithinTolerance(freedBytes: 10_000)
        }

        let state = vm.state
        let reviews = review.requestCount
        let reads = space.readCount
        XCTAssertEqual(state, .freedWithinTolerance(freedBytes: 10_000))
        XCTAssertTrue(state.freedStatusText?.contains("✓") == true)
        XCTAssertEqual(reviews, 1)
        XCTAssertEqual(reads, 3)

        vm.handleScenePhase(.background)
        vm.handleScenePhase(.active)
        let stateAgain = vm.state
        let reviewsAgain = review.requestCount
        XCTAssertEqual(stateAgain, .freedWithinTolerance(freedBytes: 10_000))
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

        let stateBefore = vm.state
        let reviewsBefore = review.requestCount
        XCTAssertEqual(stateBefore, .pendingRelease(expectedBytes: 1_000))
        XCTAssertEqual(reviewsBefore, 0)

        sleeper.resumeNext()
        await TestWait.until { @MainActor in
            vm.state == .freedWithinTolerance(freedBytes: 1_000)
        }

        let state = vm.state
        let reviews = review.requestCount
        XCTAssertEqual(state, .freedWithinTolerance(freedBytes: 1_000))
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

        let state = vm.state
        let reads = space.readCount
        XCTAssertEqual(state, .freedOutsideTolerance(freedBytes: 1_000, expectedBytes: 500))
        XCTAssertEqual(reads, 2)

        vm.handleScenePhase(.inactive)
        await TestWait.until { !sleeper.isWaiting }
        await Task.yield()

        let stateAfterCancel = vm.state
        let readsAfterCancel = space.readCount
        let reviewsAfterCancel = review.requestCount
        XCTAssertEqual(stateAfterCancel, .freedOutsideTolerance(freedBytes: 1_000, expectedBytes: 500))
        XCTAssertEqual(readsAfterCancel, 2)
        XCTAssertEqual(reviewsAfterCancel, 0)

        vm.handleScenePhase(.active)
        let stateOnReturn = vm.state
        let reviews = review.requestCount
        let readsOnReturn = space.readCount
        XCTAssertEqual(stateOnReturn, .freedWithinTolerance(freedBytes: 500))
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

        let values = try await MainActor.run { () -> (Int64, Int, Int, Int, FreedSpaceResultState) in
            let presented = try XCTUnwrap(vm.deletionResultModel)
            return (Int64(presented.pendingReleaseBytes), presented.snapshot.copiedCount,
                    presented.snapshot.verifiedMatchCount, presented.snapshot.verifiedTotalCount,
                    presented.state)
        }
        XCTAssertEqual(values.0, 350)
        XCTAssertEqual(values.1, 2)
        XCTAssertEqual(values.2, 2)
        XCTAssertEqual(values.3, 2)
        XCTAssertEqual(values.4, .pendingRelease(expectedBytes: 350))
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
