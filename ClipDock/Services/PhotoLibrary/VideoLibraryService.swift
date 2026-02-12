import Foundation
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
        // PHAsset does not expose file size via public API. For MVP we read `PHAssetResource.fileSize`
        // through KVC when available. If it fails, we return no entry for that asset.
        await Task.detached(priority: .utility) {
            guard !assetIDs.isEmpty else { return [:] }

            let fetch = PHAsset.fetchAssets(withLocalIdentifiers: assetIDs, options: nil)
            var output: [String: Int64] = [:]
            output.reserveCapacity(min(fetch.count, assetIDs.count))

            fetch.enumerateObjects { asset, _, _ in
                let resources = PHAssetResource.assetResources(for: asset)
                let resource = resources.first(where: { $0.type == .fullSizeVideo || $0.type == .video }) ?? resources.first
                guard let resource else { return }

                let raw = resource.value(forKey: "fileSize")
                if let n = raw as? NSNumber {
                    output[asset.localIdentifier] = n.int64Value
                    return
                }
                if let i = raw as? Int {
                    output[asset.localIdentifier] = Int64(i)
                    return
                }
                if let i64 = raw as? Int64 {
                    output[asset.localIdentifier] = i64
                    return
                }
            }

            return output
        }.value
    }
}
