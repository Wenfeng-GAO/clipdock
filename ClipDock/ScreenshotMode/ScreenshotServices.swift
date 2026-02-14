import Foundation

// MARK: - Screenshot Services (simulator only)
//
// This is used to generate App Store screenshots without requiring Photos permission
// dialogs or real media on the simulator.

#if DEBUG
#if targetEnvironment(simulator)

struct ScreenshotPhotoPermissionService: PhotoPermissionServicing {
    func currentStatus() -> PhotoPermissionState { .authorized }
    func requestReadWriteAccess() async -> PhotoPermissionState { .authorized }
}

final class ScreenshotExternalStorageService: ExternalStorageServicing {
    private let folderURL: URL

    init(folderURL: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!) {
        self.folderURL = folderURL
    }

    func saveFolderBookmark(_ folderURL: URL) throws {
        // No-op in screenshot mode.
    }

    func resolveSavedFolderURL() throws -> URL? {
        folderURL
    }

    func validateFolderWritable(_ folderURL: URL) -> Bool {
        true
    }
}

struct ScreenshotVideoLibraryService: VideoLibraryServicing {
    let videos: [VideoAssetSummary]
    let sizes: [String: Int64]

    init(seed: Int = 1) {
        let calendar = Calendar(identifier: .gregorian)
        let base = calendar.date(from: DateComponents(year: 2026, month: 2, day: 12, hour: 23, minute: 50)) ?? Date()

        var out: [VideoAssetSummary] = []
        out.reserveCapacity(28)

        // Build a "realistic" looking dataset: multiple months, mixed durations/resolutions.
        for i in 0..<28 {
            let minutesOffset = -(i * 37)
            let date = calendar.date(byAdding: .minute, value: minutesOffset, to: base) ?? base
            let duration = TimeInterval(3 + (i % 9) * 7)
            let is4K = (i % 5 == 0)
            let w = is4K ? 3840 : 1920
            let h = is4K ? 2160 : 1080
            out.append(
                VideoAssetSummary(
                    id: "screenshot_asset_\(seed)_\(i)",
                    creationDate: date,
                    duration: duration,
                    pixelWidth: w,
                    pixelHeight: h
                )
            )
        }

        self.videos = out.sorted { $0.creationDate > $1.creationDate }

        // Sizes: make them deterministic and varied (3MB .. 2.3GB).
        var sizes: [String: Int64] = [:]
        sizes.reserveCapacity(self.videos.count)
        for (idx, v) in self.videos.enumerated() {
            let mb = 3 + (idx * 97) % 2400
            sizes[v.id] = Int64(mb) * 1024 * 1024
        }
        self.sizes = sizes
    }

    func fetchVideosSortedByDate(limit: Int?) async -> [VideoAssetSummary] {
        if let limit { return Array(videos.prefix(limit)) }
        return videos
    }

    func fetchVideoFileSizesBytes(assetIDs: [String]) async -> [String: Int64] {
        guard !assetIDs.isEmpty else { return [:] }
        var out: [String: Int64] = [:]
        out.reserveCapacity(assetIDs.count)
        for id in assetIDs {
            if let bytes = sizes[id] {
                out[id] = bytes
            }
        }
        return out
    }
}

struct ScreenshotVideoMigrationService: VideoMigrating {
    func migrateVideoAssetIDs(
        _ assetIDs: [String],
        to targetFolderURL: URL,
        progress: @escaping @Sendable (MigrationProgress) -> Void,
        onResult: @escaping @Sendable (MigrationRunResult) -> Void
    ) async {
        progress(MigrationProgress(completed: 0, total: max(assetIDs.count, 1), currentFilename: nil, isIndeterminate: false))
        onResult(MigrationRunResult(successes: [], failures: []))
    }
}

struct ScreenshotPhotoDeletionService: PhotoDeleting {
    func deleteAssets(withLocalIDs assetIDs: [String]) async throws {
        // No-op.
    }
}

#endif
#endif

