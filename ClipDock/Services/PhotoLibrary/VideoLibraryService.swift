import Foundation
import AVFoundation
import Photos

protocol VideoLibraryServicing {
    func fetchVideosSortedByDate(limit: Int?) async -> [VideoAssetSummary]
    func fetchVideoFileSizesBytes(assetIDs: [String]) async -> [String: Int64]
}

struct VideoLibraryService: VideoLibraryServicing {
    func fetchVideosSortedByDate(limit: Int? = nil) async -> [VideoAssetSummary] {
        await Task.detached(priority: .userInitiated) {
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            let assets = PHAsset.fetchAssets(with: .video, options: options)

            var output: [VideoAssetSummary] = []
            output.reserveCapacity(min(assets.count, limit ?? assets.count))

            assets.enumerateObjects { asset, _, stop in
                let summary = VideoAssetSummary(
                    id: asset.localIdentifier,
                    creationDate: asset.creationDate ?? .distantPast,
                    duration: asset.duration,
                    pixelWidth: asset.pixelWidth,
                    pixelHeight: asset.pixelHeight
                )
                output.append(summary)

                if let limit, output.count >= limit {
                    stop.pointee = true
                }
            }
            return output
        }.value
    }

    func fetchVideoFileSizesBytes(assetIDs: [String]) async -> [String: Int64] {
        // App Store safe: use public PhotoKit APIs only.
        // Note: size is best-effort and "local-only" when `isNetworkAccessAllowed=false`.
        // iCloud-only assets will likely return no size until they are downloaded/exported.
        await Task.detached(priority: .utility) {
            guard !assetIDs.isEmpty else { return [:] }

            let fetch = PHAsset.fetchAssets(withLocalIdentifiers: assetIDs, options: nil)
            var assets: [PHAsset] = []
            assets.reserveCapacity(fetch.count)
            fetch.enumerateObjects { asset, _, _ in assets.append(asset) }

            return await self.fetchLocalVideoFileSizesBytes(assets: assets, maxConcurrent: 8)
        }.value
    }

    private func fetchLocalVideoFileSizesBytes(
        assets: [PHAsset],
        maxConcurrent: Int
    ) async -> [String: Int64] {
        guard !assets.isEmpty else { return [:] }

        var output: [String: Int64] = [:]
        output.reserveCapacity(assets.count)

        await withTaskGroup(of: (String, Int64?).self) { group in
            var it = assets.makeIterator()

            func enqueueNext() {
                guard let asset = it.next() else { return }
                group.addTask {
                    let size = await self.localVideoFileSizeBytes(asset: asset)
                    return (asset.localIdentifier, size)
                }
            }

            for _ in 0..<min(maxConcurrent, assets.count) {
                enqueueNext()
            }

            while let (id, size) = await group.next() {
                if let size, size > 0 {
                    output[id] = size
                }
                enqueueNext()
            }
        }

        return output
    }

    private func localVideoFileSizeBytes(asset: PHAsset) async -> Int64? {
        await withCheckedContinuation { continuation in
            let options = PHVideoRequestOptions()
            options.isNetworkAccessAllowed = false
            options.deliveryMode = .fastFormat
            options.version = .original

            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, _ in
                guard let urlAsset = avAsset as? AVURLAsset else {
                    continuation.resume(returning: nil)
                    return
                }

                let url = urlAsset.url
                do {
                    let values = try url.resourceValues(forKeys: [.fileSizeKey])
                    if let size = values.fileSize {
                        continuation.resume(returning: Int64(size))
                        return
                    }
                } catch {
                    // Fall through to FileManager.
                }

                do {
                    let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
                    if let n = attrs[.size] as? NSNumber {
                        continuation.resume(returning: n.int64Value)
                        return
                    }
                } catch {
                    // Ignore.
                }

                continuation.resume(returning: nil)
            }
        }
    }
}
