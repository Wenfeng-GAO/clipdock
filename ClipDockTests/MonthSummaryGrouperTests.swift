import XCTest
@testable import ClipDock

final class MonthSummaryGrouperTests: XCTestCase {
    func testGroupBuildsYearHierarchyAndKeepsUnknown() {
        var summaries: [MonthSummary] = []
        // Build 6 years * 12 months = 72 month entries.
        for year in 2020...2025 {
            for month in 1...12 {
                summaries.append(.init(key: .yearMonth(year: year, month: month), count: 1))
            }
        }
        summaries.append(.init(key: .unknown, count: 9))

        let out = MonthSummaryGrouper.group(summaries)

        XCTAssertEqual(out.yearGroups.map(\.year), [2025, 2024, 2023, 2022, 2021, 2020])
        XCTAssertEqual(out.yearGroups.first?.months.first?.key, .yearMonth(year: 2025, month: 12))
        XCTAssertEqual(out.yearGroups.first?.months.last?.key, .yearMonth(year: 2025, month: 1))
        XCTAssertEqual(out.unknown?.key, .unknown)
        XCTAssertEqual(out.unknown?.count, 9)
    }
}

