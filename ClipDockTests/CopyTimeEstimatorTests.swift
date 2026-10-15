import XCTest
@testable import ClipDock

final class CopyTimeEstimatorTests: XCTestCase {
    func testReturnsNilWithoutEnoughData() {
        XCTAssertNil(CopyTimeEstimator.remainingSeconds(copiedBytes: 0, totalBytes: 100, elapsed: 30))
        XCTAssertNil(CopyTimeEstimator.remainingSeconds(copiedBytes: -5, totalBytes: 100, elapsed: 30))
        XCTAssertNil(CopyTimeEstimator.remainingSeconds(copiedBytes: 50, totalBytes: 100, elapsed: 0))
        XCTAssertNil(CopyTimeEstimator.remainingSeconds(copiedBytes: 50, totalBytes: 100, elapsed: 0.999))
        XCTAssertNil(CopyTimeEstimator.remainingSeconds(copiedBytes: 50, totalBytes: 100, elapsed: -3))
        // Even a finished total is withheld until there is a real sample.
        XCTAssertNil(CopyTimeEstimator.remainingSeconds(copiedBytes: 0, totalBytes: 0, elapsed: 10))
        XCTAssertNil(CopyTimeEstimator.remainingSeconds(copiedBytes: 10, totalBytes: 10, elapsed: 0.5))
    }

    func testEstimatesAtTheOneSecondBoundary() {
        let remaining = CopyTimeEstimator.remainingSeconds(copiedBytes: 40, totalBytes: 100, elapsed: 1)
        XCTAssertEqual(remaining ?? -1, 1.5, accuracy: 0.000_1)
    }

    func testReturnsZeroWhenCopiedBytesCoverTheTotal() {
        XCTAssertEqual(
            CopyTimeEstimator.remainingSeconds(copiedBytes: 100, totalBytes: 100, elapsed: 5),
            0 as TimeInterval
        )
        XCTAssertEqual(
            CopyTimeEstimator.remainingSeconds(copiedBytes: 150, totalBytes: 100, elapsed: 5),
            0 as TimeInterval
        )
    }

    func testTypicalCopyRoundsUpToTwoMinutes() {
        // 8.6 GB of 13.4 GB in 120s -> (4.8 / 8.6) * 120 ≈ 67s -> 2 minutes.
        let copied: Int64 = 8_600_000_000
        let total: Int64 = 13_400_000_000
        let remaining = CopyTimeEstimator.remainingSeconds(copiedBytes: copied, totalBytes: total, elapsed: 120)

        XCTAssertNotNil(remaining)
        XCTAssertEqual(remaining ?? -1, (4.8 / 8.6) * 120, accuracy: 0.001)
        XCTAssertEqual(remaining ?? -1, 67, accuracy: 0.1)
        XCTAssertEqual(CopyTimeEstimator.minutesText(remaining ?? 0), L10n.tr("About %d min", 2))
    }

    func testMinutesTextRoundsUpAndUsesUnderOneMinute() {
        XCTAssertEqual(CopyTimeEstimator.minutesText(0), L10n.tr("Under 1 min"))
        XCTAssertEqual(CopyTimeEstimator.minutesText(59.9), L10n.tr("Under 1 min"))
        XCTAssertEqual(CopyTimeEstimator.minutesText(60), L10n.tr("About %d min", 1))
        XCTAssertEqual(CopyTimeEstimator.minutesText(61), L10n.tr("About %d min", 2))
        XCTAssertEqual(CopyTimeEstimator.minutesText(120), L10n.tr("About %d min", 2))
        XCTAssertEqual(CopyTimeEstimator.minutesText(121), L10n.tr("About %d min", 3))
    }
}
