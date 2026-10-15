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
}
