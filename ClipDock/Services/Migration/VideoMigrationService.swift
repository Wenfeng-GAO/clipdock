import Foundation
import Photos

struct MigrationProgress: Sendable {
    let completed: Int
    let total: Int
    let currentFilename: String?
    let isIndeterminate: Bool

    var fraction: Double {
        guard total > 0 else { return 0 }
        return Double(completed) / Double(total)
    }
}

enum VideoMigrationError: LocalizedError {
    case noTargetFolder
    case targetFolderNotWritable
    case assetNotFound
    case noVideoResource
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .noTargetFolder:
            return "No external folder selected."
        case .targetFolderNotWritable:
            return "External folder is not writable."
        case .assetNotFound:
            return "Selected video could not be found in the photo library."
        case .noVideoResource:
            return "No exportable video resource found for this item."
        case .exportFailed(let message):
            return "Export failed: \(message)"
        }
    }
}

protocol VideoMigrating {
    func migrateVideoAssetIDs(
        _ assetIDs: [String],
        to targetFolderURL: URL,
        progress: @escaping @Sendable (MigrationProgress) -> Void
    ) async throws
}

/// Minimal v1: export original video resources to a chosen external folder.
/// Validation/deletion/task history will be layered on later.
struct VideoMigrationService: VideoMigrating {
    func migrateVideoAssetIDs(
        _ assetIDs: [String],
        to targetFolderURL: URL,
        progress: @escaping @Sendable (MigrationProgress) -> Void
    ) async throws {
        guard !assetIDs.isEmpty else { return }

        // Basic write check up-front.
        if !validateFolderWritable(targetFolderURL) {
            throw VideoMigrationError.targetFolderNotWritable
        }

        let total = assetIDs.count
        progress(MigrationProgress(completed: 0, total: total, currentFilename: nil, isIndeterminate: false))

        let assets = PHAsset.fetchAssets(withLocalIdentifiers: assetIDs, options: nil)
        if assets.count == 0 {
            throw VideoMigrationError.assetNotFound
        }

        // Export sequentially for simplicity and stability.
        for index in 0..<assets.count {
            let asset = assets.object(at: index)
            let resources = PHAssetResource.assetResources(for: asset)

            // Prefer the primary video resource.
            guard let resource = resources.first(where: { $0.type == .video }) ?? resources.first(where: { $0.type == .pairedVideo }) else {
                throw VideoMigrationError.noVideoResource
            }

            let originalName = resource.originalFilename
            let outputName = makeOutputFilename(asset: asset, originalFilename: originalName)
            let destinationURL = uniqueDestinationURL(folderURL: targetFolderURL, filename: outputName)

            progress(MigrationProgress(completed: index, total: total, currentFilename: outputName, isIndeterminate: true))

            try await export(resource: resource, to: destinationURL)

            progress(MigrationProgress(completed: index + 1, total: total, currentFilename: outputName, isIndeterminate: false))
        }
    }

    private func export(resource: PHAssetResource, to destinationURL: URL) async throws {
        // Ensure folder exists.
        let folderURL = destinationURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)

        let started = folderURL.startAccessingSecurityScopedResource()
        defer {
            if started {
                folderURL.stopAccessingSecurityScopedResource()
            }
        }

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            PHAssetResourceManager.default().writeData(for: resource, toFile: destinationURL, options: options) { error in
                if let error {
                    continuation.resume(throwing: VideoMigrationError.exportFailed(error.localizedDescription))
                    return
                }

                // Minimal validation: file exists and is non-empty.
                do {
                    let attrs = try FileManager.default.attributesOfItem(atPath: destinationURL.path)
                    let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
                    if size <= 0 {
                        continuation.resume(throwing: VideoMigrationError.exportFailed("exported file is empty"))
                    } else {
                        continuation.resume(returning: ())
                    }
                } catch {
                    continuation.resume(throwing: VideoMigrationError.exportFailed(error.localizedDescription))
                }
            }
        }
    }

    private func makeOutputFilename(asset: PHAsset, originalFilename: String) -> String {
        let date = asset.creationDate ?? Date()
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyyMMdd_HHmmss"

        let base = "ClipDock_\(fmt.string(from: date))"
        let ext = (originalFilename as NSString).pathExtension
        let safeExt = ext.isEmpty ? "mov" : ext
        return "\(base).\(safeExt)"
    }

    private func uniqueDestinationURL(folderURL: URL, filename: String) -> URL {
        let fm = FileManager.default
        var candidate = folderURL.appendingPathComponent(filename)
        if !fm.fileExists(atPath: candidate.path) {
            return candidate
        }

        let stem = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        for i in 2...9999 {
            let newName = ext.isEmpty ? "\(stem)_\(i)" : "\(stem)_\(i).\(ext)"
            candidate = folderURL.appendingPathComponent(newName)
            if !fm.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        // Fallback: add UUID.
        let uuidName = ext.isEmpty ? "\(stem)_\(UUID().uuidString)" : "\(stem)_\(UUID().uuidString).\(ext)"
        return folderURL.appendingPathComponent(uuidName)
    }

    private func validateFolderWritable(_ folderURL: URL) -> Bool {
        do {
            let started = folderURL.startAccessingSecurityScopedResource()
            defer {
                if started {
                    folderURL.stopAccessingSecurityScopedResource()
                }
            }

            let probeURL = folderURL.appendingPathComponent(".clipdock_write_probe_\(UUID().uuidString)")
            try Data("probe".utf8).write(to: probeURL, options: .atomic)
            try FileManager.default.removeItem(at: probeURL)
            return true
        } catch {
            return false
        }
    }
}
