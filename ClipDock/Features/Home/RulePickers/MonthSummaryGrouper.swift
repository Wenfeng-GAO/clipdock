import Foundation

struct MonthYearGroup: Identifiable, Hashable {
    let year: Int
    let months: [MonthSummary] // key: .yearMonth only, sorted desc by month

    var id: Int { year }

    var totalCount: Int {
        months.reduce(0) { $0 + $1.count }
    }
}

enum MonthSummaryGrouper {
    static func group(_ summaries: [MonthSummary]) -> (yearGroups: [MonthYearGroup], unknown: MonthSummary?) {
        var byYear: [Int: [MonthSummary]] = [:]
        var unknown: MonthSummary?

        for s in summaries {
            switch s.key {
            case .unknown:
                unknown = s
            case let .yearMonth(year, _):
                byYear[year, default: []].append(s)
            }
        }

        let years = byYear.keys.sorted(by: >)
        let groups: [MonthYearGroup] = years.map { year in
            let months = (byYear[year] ?? []).sorted { a, b in
                switch (a.key, b.key) {
                case let (.yearMonth(_, ma), .yearMonth(_, mb)):
                    return ma > mb
                default:
                    return a.key > b.key
                }
            }
            return MonthYearGroup(year: year, months: months)
        }

        return (groups, unknown)
    }
}

