import XCTest
@testable import ClipDock

final class SelectionRulesServiceTests: XCTestCase {
    func testBuildMonthIndexGroupsVideos() {
        let cal = Calendar(identifier: .gregorian)
        let svc = SelectionRulesService(calendar: cal)

        let v1 = VideoAssetSummary(id: "A", creationDate: Date(timeIntervalSince1970: 1704067200), duration: 1, pixelWidth: 1, pixelHeight: 1) // 2024-01-01
        let v2 = VideoAssetSummary(id: "B", creationDate: Date(timeIntervalSince1970: 1706745600), duration: 1, pixelWidth: 1, pixelHeight: 1) // 2024-02-01
        let v3 = VideoAssetSummary(id: "C", creationDate: Date(timeIntervalSince1970: 1706745600 + 10), duration: 1, pixelWidth: 1, pixelHeight: 1) // 2024-02

        let idx = svc.buildMonthIndex(videos: [v1, v2, v3])

        XCTAssertEqual(Set(idx.keys), [.yearMonth(year: 2024, month: 1), .yearMonth(year: 2024, month: 2)])
        XCTAssertEqual(Set(idx[.yearMonth(year: 2024, month: 1)] ?? []), ["A"])
        XCTAssertEqual(Set(idx[.yearMonth(year: 2024, month: 2)] ?? []), ["B", "C"])
    }

    func testMonthSummariesSortsDesc() {
        let svc = SelectionRulesService(calendar: Calendar(identifier: .gregorian))
        let idx: [MonthKey: [String]] = [
            .yearMonth(year: 2023, month: 12): ["A"],
            .yearMonth(year: 2024, month: 1): ["B", "C"],
            .unknown: ["X"],
        ]

        let summaries = svc.monthSummaries(from: idx)
        let keys = summaries.map { $0.key }
        XCTAssertEqual(keys, [.yearMonth(year: 2024, month: 1), .yearMonth(year: 2023, month: 12), .unknown])
    }

    func testAssetIDsForSelectedMonthsIsUnion() {
        let svc = SelectionRulesService(calendar: Calendar(identifier: .gregorian))
        let idx: [MonthKey: [String]] = [
            .yearMonth(year: 2024, month: 1): ["A", "B"],
            .yearMonth(year: 2024, month: 2): ["C"],
        ]

        let ids = svc.assetIDs(for: [.yearMonth(year: 2024, month: 2), .yearMonth(year: 2024, month: 1)], in: idx)
        XCTAssertEqual(ids, ["A", "B", "C"])
    }

    func testTopNSelectsLargestKnownSizesOnly() {
        let svc = SelectionRulesService(calendar: Calendar(identifier: .gregorian))
        let videos = [
            VideoAssetSummary(id: "A", creationDate: Date(timeIntervalSince1970: 3), duration: 1, pixelWidth: 1, pixelHeight: 1),
            VideoAssetSummary(id: "B", creationDate: Date(timeIntervalSince1970: 2), duration: 1, pixelWidth: 1, pixelHeight: 1),
            VideoAssetSummary(id: "C", creationDate: Date(timeIntervalSince1970: 1), duration: 1, pixelWidth: 1, pixelHeight: 1),
        ]

        let sizes: [String: Int64] = [
            "A": 10,
            "C": 30,
            // B unknown
        ]

        XCTAssertEqual(svc.topNAssetIDsBySize(n: 2, videos: videos, sizesBytesByID: sizes), ["C", "A"])
        XCTAssertEqual(svc.topNAssetIDsBySize(n: 3, videos: videos, sizesBytesByID: sizes), ["C", "A"])
    }
}
