import Foundation

@MainActor
final class HomeViewModel: ObservableObject {
    @Published var permissionState: PhotoPermissionState = .notDetermined
    @Published var selectedFolderURL: URL?
    @Published var isFolderWritable = false
    @Published var videos: [VideoAssetSummary] = []
    @Published var isScanningVideos = false
    @Published var alertMessage: String?

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
            alertMessage = "Photo access is required before scanning videos."
            return
        }

        isScanningVideos = true
        selectedVideoIDs.removeAll()
        lastMigrationResult = nil
        Task {
            let fetchedVideos = await videoLibraryService.fetchVideosSortedByDate(limit: nil)
            videos = fetchedVideos
            isScanningVideos = false
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

    // MARK: - Migration (M5 minimal)

    func startMigration() {
        guard !isMigrating else { return }
        guard permissionState.canReadLibrary else {
            alertMessage = "Photo access is required before migrating videos."
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
            alertMessage = "Select at least one video to migrate."
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
                        self?.alertMessage = "Migration completed. (Deletion is available below.)"
                    } else {
                        self?.alertMessage = "Migration completed with failures: \(result.successCount) success, \(result.failureCount) failed."
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
            alertMessage = "Full Photos access is required to delete videos."
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
                alertMessage = "Deleted \(assetIDs.count) original video(s)."
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
