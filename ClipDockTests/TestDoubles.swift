import Foundation
import XCTest
@testable import ClipDock

final class MockPhotoPermissionService: PhotoPermissionServicing {
    var status: PhotoPermissionState = .authorized
    var requestResult: PhotoPermissionState = .authorized

    func currentStatus() -> PhotoPermissionState { status }

    func requestReadWriteAccess() async -> PhotoPermissionState {
        requestResult
    }
}

final class MockExternalStorageService: ExternalStorageServicing {
    var resolvedURL: URL?
    var validateWritableResult: Bool = true
    var saveBookmarkError: Error?
    var resolveError: Error?

    private(set) var savedBookmarks: [URL] = []

    func saveFolderBookmark(_ folderURL: URL) throws {
        if let saveBookmarkError { throw saveBookmarkError }
        savedBookmarks.append(folderURL)
        resolvedURL = folderURL
    }

    func resolveSavedFolderURL() throws -> URL? {
        if let resolveError { throw resolveError }
        return resolvedURL
    }

    func validateFolderWritable(_ folderURL: URL) -> Bool {
        validateWritableResult
    }
}

final class MockVideoLibraryService: VideoLibraryServicing {
    var fetchVideosResult: [VideoAssetSummary] = []
    private(set) var fetchVideosCallCount = 0
    var fetchVideosDelayNanoseconds: UInt64 = 0

    private(set) var fetchSizesCalls: [[String]] = []
    var fetchSizesResult: [String: Int64] = [:]

    func fetchVideosSortedByDate(limit: Int?) async -> [VideoAssetSummary] {
        fetchVideosCallCount += 1
        if fetchVideosDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: fetchVideosDelayNanoseconds)
        }
        return fetchVideosResult
    }

    func fetchVideoFileSizesBytes(assetIDs: [String]) async -> [String : Int64] {
        fetchSizesCalls.append(assetIDs)
        var out: [String: Int64] = [:]
        out.reserveCapacity(assetIDs.count)
        for id in assetIDs {
            if let v = fetchSizesResult[id] {
                out[id] = v
            }
        }
        return out
    }
}

final class MockVideoMigrationService: VideoMigrating {
    private(set) var migrateCalls: [([String], URL)] = []
    var resultToReturn: MigrationRunResult = .init(successes: [], failures: [])

    func migrateVideoAssetIDs(
        _ assetIDs: [String],
        to targetFolderURL: URL,
        progress: @escaping @Sendable (MigrationProgress) -> Void,
        onResult: @escaping @Sendable (MigrationRunResult) -> Void
    ) async {
        migrateCalls.append((assetIDs, targetFolderURL))
        progress(.init(completed: assetIDs.count, total: assetIDs.count, currentFilename: nil, isIndeterminate: false))
        onResult(resultToReturn)
    }
}

final class MockPhotoDeletionService: PhotoDeleting {
    private(set) var deleteCalls: [[String]] = []
    var errorToThrow: Error?

    func deleteAssets(withLocalIDs localIDs: [String]) async throws {
        deleteCalls.append(localIDs)
        if let errorToThrow { throw errorToThrow }
    }
}

final class MockHistoryStore: MigrationHistoryStoring {
    var loaded: [MigrationHistoryRecord] = []
    private(set) var appended: [MigrationHistoryRecord] = []

    func load() throws -> [MigrationHistoryRecord] { loaded }

    func append(_ record: MigrationHistoryRecord) throws {
        appended.append(record)
    }

    func clear() throws {}
}

enum TestWait {
    static func until(timeoutSeconds: Double = 2.0, _ condition: @escaping @Sendable () async -> Bool) async {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 20_000_000) // 20ms
        }
    }
}
