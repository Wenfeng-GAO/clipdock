import Foundation

/// Remaining copy time from measured throughput (`copiedBytes / elapsed`).
enum CopyTimeEstimator {
    /// Seconds still needed at the average rate so far.
    ///
    /// Returns `nil` when there is not enough data (`copiedBytes <= 0`, or `elapsed` under one second).
    /// Returns `0` when `totalBytes <= copiedBytes`.
    static func remainingSeconds(
        copiedBytes: Int64,
        totalBytes: Int64,
        elapsed: TimeInterval
    ) -> TimeInterval? {
        guard copiedBytes > 0 else { return nil }
        guard elapsed.isFinite, elapsed >= 1 else { return nil }
        if totalBytes <= copiedBytes { return 0 }
        let throughput = Double(copiedBytes) / elapsed
        let remainingBytes = Double(totalBytes - copiedBytes)
        return remainingBytes / throughput
    }

    /// Localized remaining time. Under a minute is a fixed phrase; longer estimates round up to whole minutes.
    static func minutesText(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 60 else {
            return L10n.tr("Under 1 min")
        }
        let minutes = max(1, Int((seconds / 60).rounded(.up)))
        return L10n.tr("About %d min", minutes)
    }
}
