import Foundation

enum MonthKey: Hashable, Comparable, Identifiable {
    case unknown
    case yearMonth(year: Int, month: Int)

    var id: String {
        switch self {
        case .unknown:
            return "unknown"
        case let .yearMonth(year, month):
            return String(format: "%04d-%02d", year, month)
        }
    }

    var displayText: String {
        switch self {
        case .unknown:
            return L10n.tr("Unknown")
        case let .yearMonth(year, month):
            return String(format: "%04d-%02d", year, month)
        }
    }

    static func < (lhs: MonthKey, rhs: MonthKey) -> Bool {
        switch (lhs, rhs) {
        case (.unknown, .unknown):
            return false
        case (.unknown, _):
            return false
        case (_, .unknown):
            return true
        case let (.yearMonth(yl, ml), .yearMonth(yr, mr)):
            if yl != yr { return yl < yr }
            return ml < mr
        }
    }

    static func > (lhs: MonthKey, rhs: MonthKey) -> Bool {
        // Ensure `.unknown` always sorts last even when sorting descending.
        switch (lhs, rhs) {
        case (.unknown, .unknown):
            return false
        case (.unknown, _):
            return false
        case (_, .unknown):
            return true
        default:
            return rhs < lhs
        }
    }
}

struct MonthSummary: Identifiable, Hashable {
    let key: MonthKey
    let count: Int

    var id: String { key.id }
}

protocol SelectionRulesServicing {
    func buildMonthIndex(videos: [VideoAssetSummary]) -> [MonthKey: [String]]
    func monthSummaries(from index: [MonthKey: [String]]) -> [MonthSummary]
    func assetIDs(for selectedMonths: Set<MonthKey>, in index: [MonthKey: [String]]) -> Set<String>
    func topNAssetIDsBySize(
        n: Int,
        videos: [VideoAssetSummary],
        sizesBytesByID: [String: Int64]
    ) -> [String]
}

struct SelectionRulesService: SelectionRulesServicing {
    private let calendar: Calendar

    init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    func buildMonthIndex(videos: [VideoAssetSummary]) -> [MonthKey: [String]] {
        var index: [MonthKey: [String]] = [:]
        index.reserveCapacity(24)

        for v in videos {
            let key: MonthKey
            if v.creationDate == .distantPast {
                key = .unknown
            } else {
                let comps = calendar.dateComponents([.year, .month], from: v.creationDate)
                if let year = comps.year, let month = comps.month {
                    key = .yearMonth(year: year, month: month)
                } else {
                    key = .unknown
                }
            }

            index[key, default: []].append(v.id)
        }

        return index
    }

    func monthSummaries(from index: [MonthKey: [String]]) -> [MonthSummary] {
        let keys = index.keys.sorted { $0 > $1 }
        return keys.map { key in
            MonthSummary(key: key, count: index[key]?.count ?? 0)
        }
    }

    func assetIDs(for selectedMonths: Set<MonthKey>, in index: [MonthKey: [String]]) -> Set<String> {
        guard !selectedMonths.isEmpty else { return [] }
        var out: Set<String> = []
        for key in selectedMonths {
            if let ids = index[key] {
                out.formUnion(ids)
            }
        }
        return out
    }

    func topNAssetIDsBySize(
        n: Int,
        videos: [VideoAssetSummary],
        sizesBytesByID: [String: Int64]
    ) -> [String] {
        guard n > 0 else { return [] }

        let known: [(VideoAssetSummary, Int64)] = videos.compactMap { v in
            guard let size = sizesBytesByID[v.id] else { return nil }
            return (v, size)
        }

        let sorted = known.sorted { a, b in
            if a.1 != b.1 { return a.1 > b.1 }
            return a.0.creationDate > b.0.creationDate
        }

        return sorted.prefix(n).map { $0.0.id }
    }
}
