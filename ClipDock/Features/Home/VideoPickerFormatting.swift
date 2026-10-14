import Foundation

/// Byte contribution of one library video to the picker total.
struct VideoPickerItemSize: Equatable, Sendable {
    var byteCount: Int64?
    var isEstimate: Bool
}

struct VideoPickerRunningTotal: Equatable, Sendable {
    var count: Int
    var byteCount: Int64
    /// True when any selected item is an iCloud estimate, so the sum is not exact.
    var includesEstimate: Bool

    var sizeLabel: String {
        if count == 0 {
            return VideoPickerFormatting.sizeLabel(byteCount: 0, isEstimate: false)
        }
        if byteCount <= 0 {
            return "--"
        }
        return VideoPickerFormatting.sizeLabel(byteCount: byteCount, isEstimate: includesEstimate)
    }

    var countText: String {
        L10n.tr("Selected %d", count)
    }

    /// Localized " · X GB" (or " · ≈X GB") tail, including the leading separator.
    var sizeSuffixText: String {
        L10n.tr(" · %@", sizeLabel)
    }

    /// 「已选 N 个 · X GB」
    var displayText: String {
        countText + sizeSuffixText
    }
}

struct VideoPickerCellContent: Equatable, Sendable {
    /// Text-style cloud, matching the picker mock (U+2601 U+FE0E).
    static let iCloudOnlyMarker = "\u{2601}\u{FE0E}"

    var leadingText: String
    var sizeText: String
    var isCloudOnly: Bool

    static func make(
        durationSeconds: TimeInterval,
        exactByteCount: Int64?,
        estimateByteCount: Int64?,
        isCloudOnly: Bool
    ) -> VideoPickerCellContent {
        if isCloudOnly {
            let hasEstimate = estimateByteCount != nil
            return VideoPickerCellContent(
                leadingText: iCloudOnlyMarker,
                sizeText: VideoPickerFormatting.sizeLabel(byteCount: estimateByteCount, isEstimate: hasEstimate),
                isCloudOnly: true
            )
        }
        return VideoPickerCellContent(
            leadingText: VideoPickerFormatting.durationLabel(seconds: durationSeconds),
            sizeText: VideoPickerFormatting.sizeLabel(byteCount: exactByteCount, isEstimate: false),
            isCloudOnly: false
        )
    }
}

/// Selection plus per-item sizes. Toggling recomputes the running total.
struct VideoPickerSelectionState: Equatable {
    var selectedIDs: Set<String>
    var sizes: [String: VideoPickerItemSize]

    init(selectedIDs: Set<String> = [], sizes: [String: VideoPickerItemSize] = [:]) {
        self.selectedIDs = selectedIDs
        self.sizes = sizes
    }

    mutating func toggle(_ assetID: String) {
        if selectedIDs.contains(assetID) {
            selectedIDs.remove(assetID)
        } else {
            selectedIDs.insert(assetID)
        }
    }

    var total: VideoPickerRunningTotal {
        VideoPickerFormatting.runningTotal(selectedIDs: selectedIDs, sizes: sizes)
    }
}

enum VideoPickerFormatting {
    /// `m:ss`, with minutes allowed to exceed 59 (a 61-minute video is `61:00`).
    static func durationLabel(seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        // `Double(Int.max)` is 2^63, which does not fit back into `Int`.
        guard seconds < Double(Int.max) else { return "0:00" }
        let rounded = Int(seconds.rounded())
        let clamped = max(0, rounded)
        let minutes = clamped / 60
        let secs = clamped % 60
        return String(format: "%d:%02d", minutes, secs)
    }

    /// Decimal byte label. Estimates are prefixed with `≈` and no extra space (`≈1.2 GB`).
    static func sizeLabel(byteCount: Int64?, isEstimate: Bool) -> String {
        guard let byteCount else { return "--" }
        if byteCount <= 0 {
            return isEstimate ? "≈0 GB" : "0 GB"
        }
        let body = formatByteCount(byteCount)
        return isEstimate ? "≈\(body)" : body
    }

    static func runningTotal(
        selectedIDs: Set<String>,
        sizes: [String: VideoPickerItemSize]
    ) -> VideoPickerRunningTotal {
        var bytes: Int64 = 0
        var includesEstimate = false
        for id in selectedIDs {
            guard let size = sizes[id] else { continue }
            if size.isEstimate {
                includesEstimate = true
            }
            if let value = size.byteCount, value > 0 {
                let (sum, overflow) = bytes.addingReportingOverflow(value)
                bytes = overflow ? Int64.max : sum
            } else if size.byteCount == nil {
                includesEstimate = true
            }
        }
        return VideoPickerRunningTotal(
            count: selectedIDs.count,
            byteCount: bytes,
            includesEstimate: includesEstimate
        )
    }

    private static func formatByteCount(_ bytes: Int64) -> String {
        let tb: Int64 = 1_000_000_000_000
        let gb: Int64 = 1_000_000_000
        let mb: Int64 = 1_000_000
        let kb: Int64 = 1_000
        if bytes >= tb {
            return "\(decimalString(bytes: bytes, unit: tb)) TB"
        }
        if bytes >= gb {
            return "\(decimalString(bytes: bytes, unit: gb)) GB"
        }
        if bytes >= mb {
            return "\(decimalString(bytes: bytes, unit: mb)) MB"
        }
        if bytes >= kb {
            return "\(decimalString(bytes: bytes, unit: kb)) KB"
        }
        return "\(bytes) B"
    }

    /// One decimal place. Drops a trailing `.0` when the whole part is at least 10 (`13.4 GB`, `1.0 GB`, `10 GB`).
    private static func decimalString(bytes: Int64, unit: Int64) -> String {
        let whole = bytes / unit
        let remainder = bytes % unit
        let fraction = (remainder * 10 + unit / 2) / unit
        if fraction >= 10 {
            let rounded = whole + 1
            if rounded >= 10 {
                return "\(rounded)"
            }
            return "\(rounded).0"
        }
        if fraction == 0, whole >= 10 {
            return "\(whole)"
        }
        return "\(whole).\(fraction)"
    }
}
