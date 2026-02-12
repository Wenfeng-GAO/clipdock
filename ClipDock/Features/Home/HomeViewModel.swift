import Foundation

enum VideoSortMode: String, CaseIterable, Identifiable {
    case dateDesc
    case sizeDesc
    case sizeAsc

    var id: String { rawValue }

    var displayText: String {
        switch self {
        case .dateDesc: L10n.tr("Date (Newest)")
        case .sizeDesc: L10n.tr("Size (Largest)")
        case .sizeAsc: L10n.tr("Size (Smallest)")
        }
    }
}

@MainActor
final class HomeViewModel: ObservableObject {
    @Published var permissionState: PhotoPermissionState = .notDetermined
    @Published var selectedFolderURL: URL?
    @Published var isFolderWritable = false
    @Published var videos: [VideoAssetSummary] = []
    @Published var isScanningVideos = false
    @Published var alertMessage: String?

    // Sorting + size metadata (M9)
    @Published var sortMode: VideoSortMode = .dateDesc {
        didSet {
            applySort()
            if sortMode != .dateDesc {
                prefetchSizesForFirstPageIfNeeded()
            }
        }
    }
    @Published private(set) var videoSizeBytesByID: [String: Int64] = [:]
    @Published private(set) var isFetchingVideoSizes = false

    // M4: manual selection
    @Published var selectedVideoIDs: Set<String> = []

    // M5: migration (minimal v1)
    @Published var isMigrating = false
    @Published var migrationProgress: MigrationProgress?
    @Published var lastMigrationResult: MigrationRunResult?

    // M7: deletion
    @Published var isDeleting = false
    @Published var isShowingDeleteConfirm = false

    // M8: history
    @Published var migrationHistory: [MigrationHistoryRecord] = []

    private(set) var hasLoadedInitialData = false

    private let photoPermissionService: PhotoPermissionServicing
    private let externalStorageService: ExternalStorageServicing
    private let videoLibraryService: VideoLibraryServicing
    private let videoMigrationService: VideoMigrating
    private let photoDeletionService: PhotoDeleting
    private let historyStore: MigrationHistoryStoring

    private var inFlightSizeAssetIDs: Set<String> = []

    init(
        photoPermissionService: PhotoPermissionServicing = PhotoPermissionService(),
        externalStorageService: ExternalStorageServicing = ExternalStorageService(),
        videoLibraryService: VideoLibraryServicing = VideoLibraryService(),
        videoMigrationService: VideoMigrating = VideoMigrationService(),
        photoDeletionService: PhotoDeleting = PhotoDeletionService(),
        historyStore: MigrationHistoryStoring = MigrationHistoryStore()
    ) {
        self.photoPermissionService = photoPermissionService
        self.externalStorageService = externalStorageService
        self.videoLibraryService = videoLibraryService
        self.videoMigrationService = videoMigrationService
        self.photoDeletionService = photoDeletionService
        self.historyStore = historyStore
    }

    func loadInitialDataIfNeeded() {
        guard !hasLoadedInitialData else { return }
        hasLoadedInitialData = true

        permissionState = photoPermissionService.currentStatus()
        loadSavedFolderIfExists()
        loadHistory()
    }

    func requestPhotoAccess() {
        Task {
            let status = await photoPermissionService.requestReadWriteAccess()
            permissionState = status
        }
    }

    func setSelectedFolder(_ folderURL: URL) {
        do {
            try externalStorageService.saveFolderBookmark(folderURL)
            selectedFolderURL = folderURL
            isFolderWritable = externalStorageService.validateFolderWritable(folderURL)
            if !isFolderWritable {
                alertMessage = ExternalStorageError.folderNotWritable.errorDescription
            }
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func rescanFolderAccess() {
        guard let selectedFolderURL else {
            loadSavedFolderIfExists()
            return
        }
        isFolderWritable = externalStorageService.validateFolderWritable(selectedFolderURL)
        if !isFolderWritable {
            alertMessage = ExternalStorageError.folderNotWritable.errorDescription
        }
    }

    func scanVideos() {
        guard permissionState.canReadLibrary else {
            alertMessage = L10n.tr("Photo access is required before scanning videos.")
            return
        }

        isScanningVideos = true
        selectedVideoIDs.removeAll()
        lastMigrationResult = nil
        videoSizeBytesByID = [:]
        inFlightSizeAssetIDs = []
        Task {
            let fetchedVideos = await videoLibraryService.fetchVideosSortedByDate(limit: nil)
            videos = fetchedVideos
            applySort()
            isScanningVideos = false

            // Preload sizes for the first page so the list can display sizes immediately.
            prefetchSizesForFirstPageIfNeeded()
        }
    }

    // MARK: - Selection (M4)

    func toggleSelection(for assetID: String) {
        if selectedVideoIDs.contains(assetID) {
            selectedVideoIDs.remove(assetID)
        } else {
            selectedVideoIDs.insert(assetID)
        }
    }

    func selectAllScannedVideos() {
        selectedVideoIDs = Set(videos.map(\.id))
    }

    func clearSelection() {
        selectedVideoIDs.removeAll()
    }

    // MARK: - Sorting + Size (M9)

    func formattedSizeText(for assetID: String) -> String {
        guard let bytes = videoSizeBytesByID[assetID] else { return "--" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    func ensureSizeLoaded(for assetID: String) {
        guard permissionState.canReadLibrary else { return }
        guard videoSizeBytesByID[assetID] == nil else { return }
        guard !inFlightSizeAssetIDs.contains(assetID) else { return }
        inFlightSizeAssetIDs.insert(assetID)

        Task {
            let sizes = await videoLibraryService.fetchVideoFileSizesBytes(assetIDs: [assetID])
            if let bytes = sizes[assetID] {
                videoSizeBytesByID[assetID] = bytes
            }
            inFlightSizeAssetIDs.remove(assetID)

            // Only re-sort automatically when sorting by size to avoid annoying reorders.
            if sortMode != .dateDesc {
                applySort()
            }
        }
    }

    private func prefetchSizesForFirstPageIfNeeded() {
        guard permissionState.canReadLibrary else { return }
        let cap = min(videos.count, 200)
        guard cap > 0 else { return }

        let ids = Array(videos.prefix(cap).map(\.id))
        let missing = ids.filter { videoSizeBytesByID[$0] == nil && !inFlightSizeAssetIDs.contains($0) }
        guard !missing.isEmpty else { return }

        isFetchingVideoSizes = true
        missing.forEach { inFlightSizeAssetIDs.insert($0) }
        Task {
            let sizes = await videoLibraryService.fetchVideoFileSizesBytes(assetIDs: missing)
            for (id, bytes) in sizes {
                videoSizeBytesByID[id] = bytes
            }
            missing.forEach { inFlightSizeAssetIDs.remove($0) }
            isFetchingVideoSizes = false

            if sortMode != .dateDesc {
                applySort()
            }
        }
    }

    private func applySort() {
        switch sortMode {
        case .dateDesc:
            videos.sort { $0.creationDate > $1.creationDate }
        case .sizeDesc:
            videos.sort { a, b in
                let sa = videoSizeBytesByID[a.id]
                let sb = videoSizeBytesByID[b.id]
                if let sa, let sb, sa != sb { return sa > sb }
                if sa != nil && sb == nil { return true }
                if sa == nil && sb != nil { return false }
                return a.creationDate > b.creationDate
            }
        case .sizeAsc:
            videos.sort { a, b in
                let sa = videoSizeBytesByID[a.id]
                let sb = videoSizeBytesByID[b.id]
                if let sa, let sb, sa != sb { return sa < sb }
                if sa != nil && sb == nil { return true }
                if sa == nil && sb != nil { return false }
                return a.creationDate > b.creationDate
            }
        }
    }

    // MARK: - Migration (M5 minimal)

    func startMigration() {
        guard !isMigrating else { return }
        guard permissionState.canReadLibrary else {
            alertMessage = L10n.tr("Photo access is required before migrating videos.")
            return
        }
        guard let folderURL = selectedFolderURL else {
            alertMessage = VideoMigrationError.noTargetFolder.errorDescription
            return
        }
        guard isFolderWritable else {
            alertMessage = VideoMigrationError.targetFolderNotWritable.errorDescription
            return
        }
        // Preserve a stable order (current scan order: date desc).
        let selected = selectedVideoIDs
        let assetIDs = videos.filter { selected.contains($0.id) }.map(\.id)
        guard !assetIDs.isEmpty else {
            alertMessage = L10n.tr("Select at least one video to migrate.")
            return
        }

        isMigrating = true
        migrationProgress = MigrationProgress(completed: 0, total: assetIDs.count, currentFilename: nil, isIndeterminate: true)
        lastMigrationResult = nil

        Task {
            let startedAt = Date()
            await videoMigrationService.migrateVideoAssetIDs(assetIDs, to: folderURL) { [weak self] progress in
                Task { @MainActor in
                    self?.migrationProgress = progress
                }
            } onResult: { [weak self] result in
                Task { @MainActor in
                    let finishedAt = Date()
                    self?.isMigrating = false
                    self?.lastMigrationResult = result
                    if result.failureCount == 0 {
                        self?.alertMessage = L10n.tr("Migration completed. (Deletion is available below.)")
                    } else {
                        self?.alertMessage = L10n.tr("Migration completed with failures: %d success, %d failed.", result.successCount, result.failureCount)
                    }

                    self?.appendHistory(startedAt: startedAt, finishedAt: finishedAt, targetFolderURL: folderURL, result: result)
                }
            }
        }
    }

    // MARK: - Deletion (M7)

    var deletableSuccessCount: Int {
        lastMigrationResult?.successCount ?? 0
    }

    func promptDeleteMigratedOriginals() {
        guard deletableSuccessCount > 0 else { return }
        isShowingDeleteConfirm = true
    }

    func deleteMigratedOriginals() {
        guard !isDeleting else { return }
        guard permissionState.canReadLibrary else {
            alertMessage = L10n.tr("Full Photos access is required to delete videos.")
            return
        }
        guard let result = lastMigrationResult, !result.successes.isEmpty else {
            alertMessage = PhotoDeletionError.nothingToDelete.errorDescription
            return
        }

        isDeleting = true
        let assetIDs = result.successes.map(\.assetID)
        Task {
            do {
                try await photoDeletionService.deleteAssets(withLocalIDs: assetIDs)
                isDeleting = false
                alertMessage = L10n.tr("Deleted %d original video(s).", assetIDs.count)
                scanVideos()
            } catch {
                isDeleting = false
                alertMessage = error.localizedDescription
            }
        }
    }

    private func loadSavedFolderIfExists() {
        do {
            if let folderURL = try externalStorageService.resolveSavedFolderURL() {
                selectedFolderURL = folderURL
                isFolderWritable = externalStorageService.validateFolderWritable(folderURL)
            }
        } catch {
            alertMessage = ExternalStorageError.invalidBookmark.errorDescription
        }
    }

    private func loadHistory() {
        do {
            migrationHistory = try historyStore.load()
        } catch {
            // Non-fatal: keep history empty
            migrationHistory = []
        }
    }

    private func appendHistory(startedAt: Date, finishedAt: Date, targetFolderURL: URL, result: MigrationRunResult) {
        let basePath = targetFolderURL.lastPathComponent.isEmpty ? targetFolderURL.path : targetFolderURL.lastPathComponent
        let items: [MigrationHistoryItem] = result.successes.map {
            MigrationHistoryItem(assetID: $0.assetID, status: .success, destinationRelativePath: $0.destinationURL.lastPathComponent, bytes: $0.bytes, errorMessage: nil)
        } + result.failures.map {
            MigrationHistoryItem(assetID: $0.assetID, status: .failure, destinationRelativePath: nil, bytes: nil, errorMessage: $0.message)
        }

        let record = MigrationHistoryRecord(
            id: UUID(),
            startedAt: startedAt,
            finishedAt: finishedAt,
            targetFolderPath: basePath,
            successes: result.successCount,
            failures: result.failureCount,
            items: items
        )

        migrationHistory.insert(record, at: 0)
        if migrationHistory.count > 20 {
            migrationHistory = Array(migrationHistory.prefix(20))
        }

        Task.detached(priority: .background) { [historyStore] in
            try? historyStore.append(record)
        }
    }
}
