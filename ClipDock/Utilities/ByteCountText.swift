import Foundation

/// The single shared byte formatter for the app.
/// Other units add methods here rather than declaring their own.
enum ByteCountText {
    static func string(fromBytes bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    /// Storage headline style: gigabytes, or terabytes when the value is that large.
    static func storage(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useTB]
        formatter.countStyle = .file
        formatter.includesCount = true
        formatter.includesUnit = true
        formatter.isAdaptive = true
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: max(0, bytes))
    }
}
