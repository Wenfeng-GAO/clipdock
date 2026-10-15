import Foundation

/// Size metadata for a video that is not stored on the device.
struct VideoCloudEstimate: Equatable, Sendable {
    var isCloudOnly: Bool
    /// `PHAssetResource` `fileSize` when the system can report one. Nil when the asset is in iCloud but the byte count is unavailable.
    var estimatedByteCount: Int64?
}

/// Pure parsing for `PHAssetResource` KVC values (`locallyAvailable`, `fileSize`).
enum VideoCloudEstimateClassifier {
    /// Reads the private `locallyAvailable` value. Returns nil when the key is missing or not a boolean.
    static func locallyAvailable(fromRawValue raw: Any?) -> Bool? {
        guard let raw else { return nil }
        if let object = raw as? NSObject, CFGetTypeID(object) == CFBooleanGetTypeID() {
            return (object as? NSNumber)?.boolValue
        }
        if type(of: raw) == Bool.self {
            return raw as? Bool
        }
        return nil
    }

    /// Reads the private `fileSize` value in bytes. Booleans and non-positive numbers are ignored.
    static func fileSizeBytes(fromRawValue raw: Any?) -> Int64? {
        guard let raw else { return nil }
        if let object = raw as? NSObject, CFGetTypeID(object) == CFBooleanGetTypeID() {
            return nil
        }
        if let number = raw as? NSNumber {
            let value = number.int64Value
            return value > 0 ? value : nil
        }
        if let value = raw as? Int64 {
            return value > 0 ? value : nil
        }
        if let value = raw as? Int {
            return value > 0 ? Int64(value) : nil
        }
        if let value = raw as? UInt64, value > 0, value <= UInt64(Int64.max) {
            return Int64(value)
        }
        return nil
    }

    /// Decides how to label an asset whose local file size could not be read.
    /// - `locallyAvailable == true`: the file is on device; do not invent an estimate.
    /// - `locallyAvailable == false`: iCloud-only; use `fileSize` as an estimate when present.
    /// - key missing: fall back to the existing "no local file" result and treat `fileSize` as an estimate.
    static func estimateForAssetMissingLocalFile(
        locallyAvailable: Bool?,
        resourceFileSize: Int64?
    ) -> VideoCloudEstimate? {
        let size = resourceFileSize.flatMap { $0 > 0 ? $0 : nil }
        if locallyAvailable == true {
            return nil
        }
        if locallyAvailable == false {
            return VideoCloudEstimate(isCloudOnly: true, estimatedByteCount: size)
        }
        guard let size else { return nil }
        return VideoCloudEstimate(isCloudOnly: true, estimatedByteCount: size)
    }
}
