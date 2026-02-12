import Foundation
import Photos

protocol VideoLibraryServicing {
    func fetchVideosSortedByDate(limit: Int?) async -> [VideoAssetSummary]
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
}
