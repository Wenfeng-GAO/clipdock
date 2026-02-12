import Foundation
import Photos
import AVFoundation

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
    case targetFolderPermissionExpired
    case assetNotFound
    case noVideoResource
    case exportFailed(String)
    case copyFailed(String)

    var errorDescription: String? {
        switch self {
        case .noTargetFolder:
            return L10n.tr("No external folder selected.")
        case .targetFolderNotWritable:
            return L10n.tr("External folder is not writable.")
        case .targetFolderPermissionExpired:
            return L10n.tr("External folder permission expired. Please choose the external folder again.")
        case .assetNotFound:
            return L10n.tr("Selected video could not be found in the photo library.")
        case .noVideoResource:
            return L10n.tr("No exportable video resource found for this item.")
        case .exportFailed(let message):
            return L10n.tr("Export failed: %@", message)
        case .copyFailed(let message):
            return L10n.tr("Copy failed: %@", message)
        }
    }
}

protocol VideoMigrating {
    func migrateVideoAssetIDs(
        _ assetIDs: [String],
        to targetFolderURL: URL,
        progress: @escaping @Sendable (MigrationProgress) -> Void,
        onResult: @escaping @Sendable (MigrationRunResult) -> Void
    ) async
}

/// Minimal v1: export original video resources to a chosen external folder.
/// Validation/deletion/task history will be layered on later.
struct VideoMigrationService: VideoMigrating {
    func migrateVideoAssetIDs(
        _ assetIDs: [String],
        to targetFolderURL: URL,
        progress: @escaping @Sendable (MigrationProgress) -> Void,
        onResult: @escaping @Sendable (MigrationRunResult) -> Void
    ) async {
        guard !assetIDs.isEmpty else { return }

        let started = targetFolderURL.startAccessingSecurityScopedResource()
        if !started {
            onResult(MigrationRunResult(successes: [], failures: assetIDs.map { .init(assetID: $0, message: VideoMigrationError.targetFolderPermissionExpired.localizedDescription) }))
            return
        }
        defer { targetFolderURL.stopAccessingSecurityScopedResource() }

        // Basic write check up-front (with active security scope).
        if !validateFolderWritableWithoutStartingScope(targetFolderURL) {
            onResult(MigrationRunResult(successes: [], failures: assetIDs.map { .init(assetID: $0, message: VideoMigrationError.targetFolderNotWritable.localizedDescription) }))
            return
        }

        let total = assetIDs.count
        progress(MigrationProgress(completed: 0, total: total, currentFilename: nil, isIndeterminate: false))

        let assets = PHAsset.fetchAssets(withLocalIdentifiers: assetIDs, options: nil)
        if assets.count == 0 {
            onResult(MigrationRunResult(successes: [], failures: assetIDs.map { .init(assetID: $0, message: VideoMigrationError.assetNotFound.localizedDescription) }))
            return
        }

        var successes: [MigrationItemSuccess] = []
        var failures: [MigrationItemFailure] = []

        // Export sequentially for simplicity and stability.
        for index in 0..<assets.count {
            let asset = assets.object(at: index)
            let resources = PHAssetResource.assetResources(for: asset)

            // Prefer the primary video resource.
            guard let resource = resources.first(where: { $0.type == .video }) ?? resources.first(where: { $0.type == .pairedVideo }) else {
                failures.append(.init(assetID: asset.localIdentifier, message: VideoMigrationError.noVideoResource.localizedDescription))
                progress(MigrationProgress(completed: index + 1, total: total, currentFilename: nil, isIndeterminate: false))
                continue
            }

            let originalName = resource.originalFilename
            let outputName = makeOutputFilename(asset: asset, originalFilename: originalName)
            let destinationURL = uniqueDestinationURL(folderURL: targetFolderURL, filename: outputName)

            progress(MigrationProgress(completed: index, total: total, currentFilename: outputName, isIndeterminate: true))

            do {
                let bytes = try await export(resource: resource, expectedDuration: asset.duration, to: destinationURL)
                successes.append(.init(assetID: asset.localIdentifier, destinationURL: destinationURL, bytes: bytes))
            } catch {
                failures.append(.init(assetID: asset.localIdentifier, message: error.localizedDescription))
            }

            progress(MigrationProgress(completed: index + 1, total: total, currentFilename: outputName, isIndeterminate: false))
        }

        onResult(MigrationRunResult(successes: successes, failures: failures))
    }

    private func export(resource: PHAssetResource, expectedDuration: TimeInterval, to destinationURL: URL) async throws -> Int64 {
        // Export to sandbox first, then copy to the external folder while holding the security scope.
        // In practice, Photos export can fail with generic errors when writing directly to external storage URLs.
        let fileManager = FileManager.default
        let tempURL = fileManager.temporaryDirectory
            .appendingPathComponent("clipdock_export_\(UUID().uuidString)")

        defer {
            try? fileManager.removeItem(at: tempURL)
        }

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            PHAssetResourceManager.default().writeData(for: resource, toFile: tempURL, options: options) { error in
                if let error {
                    let nsError = error as NSError
                    continuation.resume(
                        throwing: VideoMigrationError.exportFailed("\(nsError.domain) (\(nsError.code)): \(nsError.localizedDescription)")
                    )
                    return
                }

                do {
                    let attrs = try fileManager.attributesOfItem(atPath: tempURL.path)
                    let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
                    if size <= 0 {
                        continuation.resume(throwing: VideoMigrationError.exportFailed("exported temp file is empty"))
                        return
                    }
                    continuation.resume(returning: ())
                } catch {
                    continuation.resume(throwing: VideoMigrationError.exportFailed(error.localizedDescription))
                }
            }
        }

        let folderURL = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)

        do {
            try coordinatedReplaceCopyItem(from: tempURL, to: destinationURL)
        } catch {
            let nsError = error as NSError
            throw VideoMigrationError.copyFailed("\(nsError.domain) (\(nsError.code)): \(nsError.localizedDescription)")
        }

        // M6 minimal validation: file exists, non-empty, and AVFoundation can read a non-zero duration.
        let attrs = try fileManager.attributesOfItem(atPath: destinationURL.path)
        let bytes = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        if bytes <= 0 {
            throw VideoMigrationError.exportFailed("exported file is empty")
        }
        try await validatePlayableDuration(destinationURL, expectedDuration: expectedDuration)
        return bytes
    }

    private func validatePlayableDuration(_ fileURL: URL, expectedDuration: TimeInterval) async throws {
        let avAsset = AVURLAsset(url: fileURL)
        let duration = try await avAsset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else {
            throw VideoMigrationError.exportFailed("exported file is not playable (duration=0)")
        }

        // Allow some tolerance; we only use this to gate deletion later.
        let tolerance = max(2.0, expectedDuration * 0.10)
        if expectedDuration > 0, abs(duration - expectedDuration) > tolerance {
            throw VideoMigrationError.exportFailed("duration mismatch (expected ~\(expectedDuration)s, got \(duration)s)")
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

    private func validateFolderWritableWithoutStartingScope(_ folderURL: URL) -> Bool {
        do {
            let probeURL = folderURL.appendingPathComponent(".clipdock_write_probe_\(UUID().uuidString)")
            try Data("probe".utf8).write(to: probeURL, options: .atomic)
            try FileManager.default.removeItem(at: probeURL)
            return true
        } catch {
            return false
        }
    }

    private func coordinatedReplaceCopyItem(from sourceURL: URL, to destinationURL: URL) throws {
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var innerError: Error?

        coordinator.coordinate(
            readingItemAt: sourceURL,
            options: [],
            writingItemAt: destinationURL,
            options: .forReplacing,
            error: &coordinationError
        ) { coordinatedSourceURL, coordinatedDestinationURL in
            do {
                let fm = FileManager.default
                if fm.fileExists(atPath: coordinatedDestinationURL.path) {
                    try fm.removeItem(at: coordinatedDestinationURL)
                }
                try fm.copyItem(at: coordinatedSourceURL, to: coordinatedDestinationURL)
            } catch {
                innerError = error
            }
        }

        if let coordinationError {
            throw coordinationError
        }
        if let innerError {
            throw innerError
        }
    }
}
