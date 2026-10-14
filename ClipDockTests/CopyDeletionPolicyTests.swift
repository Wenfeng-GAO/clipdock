import XCTest
@testable import ClipDock

final class CopyDeletionPolicyTests: XCTestCase {
    func testDeletableSetIncludesOnlyVerifiedItems() {
        let items = [
            CopyItemState(assetID: "A", expectedBytes: 100, actualBytes: 100, status: .verified),
            CopyItemState(assetID: "B", expectedBytes: 999, actualBytes: 10, status: .mismatch(expected: 999, actual: 10)),
            CopyItemState(assetID: "C", expectedBytes: 50, actualBytes: 50, status: .verified),
            CopyItemState(assetID: "D", expectedBytes: 8, status: .failed("export failed")),
            CopyItemState(
                assetID: "E",
                expectedBytes: 40,
                status: CopySizeVerifier.status(for: .missingFile(expected: 40))
            ),
        ]

        let eligibility = CopyDeletionPolicy.eligibility(for: items)

        XCTAssertTrue(eligibility.isVerificationComplete)
        XCTAssertTrue(eligibility.isDeleteEnabled)
        XCTAssertEqual(eligibility.deletableAssetIDs, ["A", "C"])
        XCTAssertEqual(eligibility.deletableBytes, 150)
        XCTAssertEqual(eligibility.verifiedCount, 2)
        XCTAssertEqual(eligibility.mismatchCount, 2)
        XCTAssertEqual(CopyDeletionPolicy.mismatchAssetIDs(in: items), ["B", "E"])
    }

    func testDeleteDisabledBeforeVerificationComplete() {
        let items = [
            CopyItemState(assetID: "A", expectedBytes: 100, actualBytes: 100, status: .verified),
            CopyItemState(assetID: "B", expectedBytes: 20, status: .copying),
            CopyItemState(assetID: "C", expectedBytes: 5, status: .pending),
        ]

        let eligibility = CopyDeletionPolicy.eligibility(for: items)

        XCTAssertFalse(eligibility.isVerificationComplete)
        XCTAssertFalse(eligibility.isDeleteEnabled)
        XCTAssertTrue(eligibility.deletableAssetIDs.isEmpty)
        XCTAssertEqual(eligibility.deletableBytes, 0)
        XCTAssertEqual(eligibility.verifiedCount, 1)
    }

    func testEmptyBatchIsNotReadyToDelete() {
        let eligibility = CopyDeletionPolicy.eligibility(for: [])
        XCTAssertFalse(eligibility.isVerificationComplete)
        XCTAssertFalse(eligibility.isDeleteEnabled)
        XCTAssertTrue(eligibility.deletableAssetIDs.isEmpty)
    }

    func testRecopyTargetsOnlyMismatches() {
        let items = [
            CopyItemState(assetID: "A", expectedBytes: 10, status: .verified),
            CopyItemState(assetID: "B", expectedBytes: 20, actualBytes: 4, status: .mismatch(expected: 20, actual: 4)),
            CopyItemState(assetID: "C", expectedBytes: 8, status: .pending),
            CopyItemState(assetID: "D", expectedBytes: 3, status: .failed("copy failed")),
            CopyItemState(assetID: "E", expectedBytes: 6, status: .copying),
        ]

        XCTAssertEqual(CopyDeletionPolicy.mismatchAssetIDs(in: items), ["B"])
    }
}
