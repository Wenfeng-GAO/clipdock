import Photos
import UIKit

/// Loads square video poster frames for the picker grid.
///
/// `targetSize` is in pixels. Call cache methods from the main thread.
/// `PHCachingImageManager` (a `PHImageManager`) serves both requests and the cache.
protocol VideoThumbnailProviding: AnyObject {
    /// Yields a degraded image and then a final image when Photos delivers both.
    /// Finishes when the request completes or the consumer cancels the task.
    func thumbnailImages(localIdentifier: String, targetSize: CGSize) -> AsyncStream<UIImage>

    func updateThumbnailCache(localIdentifiers: [String], targetSize: CGSize)
    func stopThumbnailCache()
}

final class PhotoKitVideoThumbnailProvider: VideoThumbnailProviding {
    private let imageManager: PHCachingImageManager
    private let requestOptions: PHImageRequestOptions
    private var cachedAssets: [PHAsset] = []
    private var cachedIdentifiers: [String] = []
    private var cachedTargetSize: CGSize = .zero

    init(imageManager: PHCachingImageManager = PHCachingImageManager()) {
        imageManager.allowsCachingHighQualityImages = false
        self.imageManager = imageManager

        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isSynchronous = false
        self.requestOptions = options
    }

    func thumbnailImages(localIdentifier: String, targetSize: CGSize) -> AsyncStream<UIImage> {
        let imageManager = self.imageManager
        let options = self.requestOptions
        return AsyncStream { continuation in
            guard targetSize.width > 1, targetSize.height > 1,
                  let asset = Self.fetchAsset(localIdentifier: localIdentifier) else {
                continuation.finish()
                return
            }

            let requestID = imageManager.requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFill,
                options: options
            ) { image, info in
                if Self.flag(info, key: PHImageCancelledKey) {
                    continuation.finish()
                    return
                }
                if let image {
                    continuation.yield(image)
                }
                if Self.flag(info, key: PHImageResultIsDegradedKey) == false {
                    continuation.finish()
                }
            }

            continuation.onTermination = { _ in
                imageManager.cancelImageRequest(requestID)
            }
        }
    }

    func updateThumbnailCache(localIdentifiers: [String], targetSize: CGSize) {
        guard targetSize.width > 1, targetSize.height > 1 else {
            stopThumbnailCache()
            return
        }
        if localIdentifiers == cachedIdentifiers, targetSize == cachedTargetSize {
            return
        }
        stopThumbnailCache()

        let assets = Self.fetchAssets(localIdentifiers: localIdentifiers)
        guard !assets.isEmpty else { return }
        imageManager.startCachingImages(
            for: assets,
            targetSize: targetSize,
            contentMode: .aspectFill,
            options: requestOptions
        )
        cachedAssets = assets
        cachedIdentifiers = localIdentifiers
        cachedTargetSize = targetSize
    }

    func stopThumbnailCache() {
        guard !cachedAssets.isEmpty else { return }
        imageManager.stopCachingImages(
            for: cachedAssets,
            targetSize: cachedTargetSize,
            contentMode: .aspectFill,
            options: requestOptions
        )
        cachedAssets = []
        cachedIdentifiers = []
        cachedTargetSize = .zero
    }

    private static func fetchAsset(localIdentifier: String) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject
    }

    private static func fetchAssets(localIdentifiers: [String]) -> [PHAsset] {
        guard !localIdentifiers.isEmpty else { return [] }
        let result = PHAsset.fetchAssets(withLocalIdentifiers: localIdentifiers, options: nil)
        var assets: [PHAsset] = []
        assets.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            assets.append(asset)
        }
        return assets
    }

    private static func flag(_ info: [AnyHashable: Any]?, key: String) -> Bool {
        guard let info else { return false }
        if let value = info[key] as? Bool {
            return value
        }
        if let value = info[key] as? NSNumber {
            return value.boolValue
        }
        return false
    }
}
