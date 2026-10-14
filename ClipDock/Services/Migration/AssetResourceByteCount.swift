import Foundation
import Photos

/// Source size for a copied `PHAssetResource`.
///
/// Prefers the resource's `fileSize` (KVC). When that value is unavailable, callers should use the
/// byte count of the file `PHAssetResourceManager` actually wrote — the same measurement as the
/// library's file-size fallback.
enum AssetResourceByteCount {
    static func fileSizeBytes(of resource: PHAssetResource) -> Int64? {
        let selector = NSSelectorFromString("fileSize")
        guard resource.responds(to: selector) else { return nil }
        return positiveByteCount(resource.value(forKey: "fileSize"))
    }

    static func positiveByteCount(_ value: Any?) -> Int64? {
        switch value {
        case let number as NSNumber:
            let bytes = number.int64Value
            return bytes > 0 ? bytes : nil
        case let bytes as Int64 where bytes > 0:
            return bytes
        case let bytes as Int where bytes > 0:
            return Int64(bytes)
        case let bytes as UInt64 where bytes > 0 && bytes <= UInt64(Int64.max):
            return Int64(bytes)
        default:
            return nil
        }
    }
}
