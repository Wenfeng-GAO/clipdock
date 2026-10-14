import Foundation

/// Picker chips on mock screen 02. Exactly one is active.
///
/// Top 20 shows every video, largest known size first. Year chips keep the input
/// order and drop videos whose creation year in `calendar` is different. All shows
/// the input unchanged.
enum PickerFilterChip: String, CaseIterable, Identifiable, Equatable, Sendable {
    case top20
    case year2024
    case year2025
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .top20:
            return L10n.tr("Top 20")
        case .year2024:
            return L10n.tr("2024")
        case .year2025:
            return L10n.tr("2025")
        case .all:
            return L10n.tr("All")
        }
    }

    var calendarYear: Int? {
        switch self {
        case .year2024:
            return 2024
        case .year2025:
            return 2025
        case .top20, .all:
            return nil
        }
    }

    static func visibleVideos(
        _ videos: [VideoAssetSummary],
        chip: PickerFilterChip,
        calendar: Calendar,
        sizesBytesByID: [String: Int64] = [:]
    ) -> [VideoAssetSummary] {
        switch chip {
        case .all:
            return videos
        case .year2024, .year2025:
            guard let year = chip.calendarYear else { return videos }
            return videos.filter { calendar.component(.year, from: $0.creationDate) == year }
        case .top20:
            return videos.sorted { lhs, rhs in
                let left = sizesBytesByID[lhs.id]
                let right = sizesBytesByID[rhs.id]
                if let left, let right, left != right {
                    return left > right
                }
                if left != nil && right == nil { return true }
                if left == nil && right != nil { return false }
                return lhs.creationDate > rhs.creationDate
            }
        }
    }
}

/// Bottom-tray copy of the drive card's free space. Nil hides the label.
enum PickerTrayText {
    static func driveFreeText(freeBytes: Int64?) -> String? {
        guard let freeBytes else { return nil }
        return L10n.tr("Drive free %@", ByteCountText.storage(freeBytes))
    }
}
