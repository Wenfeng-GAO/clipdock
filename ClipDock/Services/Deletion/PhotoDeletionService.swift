import Foundation
import Photos

protocol PhotoDeleting {
    func deleteAssets(withLocalIDs localIDs: [String]) async throws
}

enum PhotoDeletionError: LocalizedError {
    case nothingToDelete
    case deleteFailed(String)

    var errorDescription: String? {
        switch self {
        case .nothingToDelete:
            return "Nothing to delete."
        case .deleteFailed(let message):
            return "Delete failed: \(message)"
        }
    }
}

struct PhotoDeletionService: PhotoDeleting {
    func deleteAssets(withLocalIDs localIDs: [String]) async throws {
        let uniqueIDs = Array(Set(localIDs))
        guard !uniqueIDs.isEmpty else {
            throw PhotoDeletionError.nothingToDelete
        }

        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: uniqueIDs, options: nil)
        guard fetchResult.count > 0 else {
            throw PhotoDeletionError.nothingToDelete
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(fetchResult)
            } completionHandler: { success, error in
                if let error {
                    let nsError = error as NSError
                    continuation.resume(
                        throwing: PhotoDeletionError.deleteFailed("\(nsError.domain) (\(nsError.code)): \(nsError.localizedDescription)")
                    )
                    return
                }
                if !success {
                    continuation.resume(throwing: PhotoDeletionError.deleteFailed("Unknown failure"))
                    return
                }
                continuation.resume(returning: ())
            }
        }
    }
}
