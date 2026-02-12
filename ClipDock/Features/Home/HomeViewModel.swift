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

    private(set) var hasLoadedInitialData = false

    private let photoPermissionService: PhotoPermissionServicing
    private let externalStorageService: ExternalStorageServicing
    private let videoLibraryService: VideoLibraryServicing
    private let videoMigrationService: VideoMigrating
    private let photoDeletionService: PhotoDeleting

    init(
        photoPermissionService: PhotoPermissionServicing = PhotoPermissionService(),
        externalStorageService: ExternalStorageServicing = ExternalStorageService(),
        videoLibraryService: VideoLibraryServicing = VideoLibraryService(),
        videoMigrationService: VideoMigrating = VideoMigrationService(),
        photoDeletionService: PhotoDeleting = PhotoDeletionService()
    ) {
        self.photoPermissionService = photoPermissionService
        self.externalStorageService = externalStorageService
        self.videoLibraryService = videoLibraryService
        self.videoMigrationService = videoMigrationService
        self.photoDeletionService = photoDeletionService
    }

    func loadInitialDataIfNeeded() {
        guard !hasLoadedInitialData else { return }
        hasLoadedInitialData = true

        permissionState = photoPermissionService.currentStatus()
        loadSavedFolderIfExists()
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
            await videoMigrationService.migrateVideoAssetIDs(assetIDs, to: folderURL) { [weak self] progress in
                Task { @MainActor in
                    self?.migrationProgress = progress
                }
            } onResult: { [weak self] result in
                Task { @MainActor in
                    self?.isMigrating = false
                    self?.lastMigrationResult = result
                    if result.failureCount == 0 {
                        self?.alertMessage = "Migration completed. (Deletion is available below.)"
                    } else {
                        self?.alertMessage = "Migration completed with failures: \(result.successCount) success, \(result.failureCount) failed."
                    }
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
        guard permissionState == .authorized else {
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
}
