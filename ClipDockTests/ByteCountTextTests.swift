import XCTest
@testable import ClipDock

final class ByteCountTextTests: XCTestCase {
    func testZeroBytesIsNonEmpty() {
        XCTAssertFalse(ByteCountText.string(fromBytes: 0).isEmpty)
    }

    func testGigabyteScaleContainsGB() {
        let text = ByteCountText.string(fromBytes: 1_500_000_000)
        XCTAssertTrue(text.contains("GB"))
    }
}
