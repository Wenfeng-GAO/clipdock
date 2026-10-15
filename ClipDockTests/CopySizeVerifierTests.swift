import XCTest
@testable import ClipDock

final class CopySizeVerifierTests: XCTestCase {
    private var createdURLs: [URL] = []

    override func tearDown() {
        for url in createdURLs {
            try? FileManager.default.removeItem(at: url)
        }
        createdURLs = []
        super.tearDown()
    }

    func testVerifyMatchWhenDestinationSizeEqualsSource() throws {
        let url = try makeFile(byteCount: 128)
        let result = CopySizeVerifier().verify(expectedBytes: 128, at: url)
        XCTAssertEqual(result, .match(bytes: 128))
        XCTAssertEqual(CopySizeVerifier.status(for: result), .verified)
    }

    func testVerifyMismatchWhenDestinationSizeDiffers() throws {
        let url = try makeFile(byteCount: 10)
        let result = CopySizeVerifier().verify(expectedBytes: 25, at: url)
        XCTAssertEqual(result, .mismatch(expected: 25, actual: 10))
        XCTAssertEqual(CopySizeVerifier.status(for: result), .mismatch(expected: 25, actual: 10))
    }

    func testVerifyMissingFile() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipdock-missing-\(UUID().uuidString).mov")
        let result = CopySizeVerifier().verify(expectedBytes: 40, at: url)
        XCTAssertEqual(result, .missingFile(expected: 40))
        XCTAssertEqual(CopySizeVerifier.status(for: result), .mismatch(expected: 40, actual: 0))
    }

    func testCompareTreatsNilActualAsMissingFile() {
        XCTAssertEqual(
            CopySizeVerifier.compare(expectedBytes: 7, actualBytes: nil),
            .missingFile(expected: 7)
        )
        XCTAssertEqual(
            CopySizeVerifier.compare(expectedBytes: 7, actualBytes: 7),
            .match(bytes: 7)
        )
        XCTAssertEqual(
            CopySizeVerifier.compare(expectedBytes: 7, actualBytes: 3),
            .mismatch(expected: 7, actual: 3)
        )
    }

    func testPositiveByteCountRejectsZeroAndAcceptsNumbers() {
        XCTAssertEqual(AssetResourceByteCount.positiveByteCount(NSNumber(value: 42)), 42)
        XCTAssertEqual(AssetResourceByteCount.positiveByteCount(Int64(99)), 99)
        XCTAssertNil(AssetResourceByteCount.positiveByteCount(NSNumber(value: 0)))
        XCTAssertNil(AssetResourceByteCount.positiveByteCount(nil))
    }

    private func makeFile(byteCount: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipdock-verify-\(UUID().uuidString).mov")
        try Data(count: byteCount).write(to: url)
        createdURLs.append(url)
        return url
    }
}
