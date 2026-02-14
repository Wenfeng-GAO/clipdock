import Foundation

enum VideoSortMode: String, CaseIterable, Identifiable {
    case dateDesc
    case dateAsc
    case sizeDesc
    case sizeAsc

    var id: String { rawValue }

    var displayText: String {
        switch self {
        case .dateDesc: L10n.tr("Date (Newest)")
        case .dateAsc: L10n.tr("Date (Oldest)")
        case .sizeDesc: L10n.tr("Size (Largest)")
        case .sizeAsc: L10n.tr("Size (Smallest)")
        }
    }
}

enum VideoSortField: String, CaseIterable, Identifiable {
    case date
    case size

    var id: String { rawValue }

    var displayText: String {
        switch self {
        case .date: L10n.tr("Date")
        case .size: L10n.tr("Size")
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
            if sortMode == .sizeAsc || sortMode == .sizeDesc {
                // To make size sorting deterministic, ensure sizes are prepared for the whole scan.
                Task { await prefetchSizesForAllScannedVideosIfNeeded() }
            }
        }
    }
    @Published private(set) var videoSizeBytesByID: [String: Int64] = [:]
    @Published private(set) var isFetchingVideoSizes = false
    @Published private(set) var isFetchingAllVideoSizes = false

    // 1.0 rule selection
    @Published private(set) var monthSummaries: [MonthSummary] = []

    // List rendering controls (M10)
    @Published var listVisibleLimit: Int = 20
    @Published var showSelectedOnly: Bool = false {
        didSet {
            // Keep best-effort sizes visible as the visible set changes.
            prefetchSizesForVisibleRangeIfNeeded()
        }
    }

    // M4: manual selection
    @Published var selectedVideoIDs: Set<String> = []
    @Published private(set) var selectedKnownSizeCount: Int = 0
    @Published private(set) var selectedTotalKnownBytes: Int64 = 0

    // M5: migration (minimal v1)
    @Published var isMigrating = false
    @Published var migrationProgress: MigrationProgress?
    @Published var lastMigrationResult: MigrationRunResult?

    // M7: deletion
    @Published var isDeleting = false
    @Published var isShowingDeleteConfirm = false

    // M8: history
    // 1.0: no History UI (keep only last-run result in-memory).

    private(set) var hasLoadedInitialData = false

    private let photoPermissionService: PhotoPermissionServicing
    private let externalStorageService: ExternalStorageServicing
    private let videoLibraryService: VideoLibraryServicing
    private let videoMigrationService: VideoMigrating
    private let photoDeletionService: PhotoDeleting
    private let selectionRulesService: SelectionRulesServicing

    private var inFlightSizeAssetIDs: Set<String> = []
    private var monthIndex: [MonthKey: [String]] = [:]

    init(
        photoPermissionService: PhotoPermissionServicing = PhotoPermissionService(),
        externalStorageService: ExternalStorageServicing = ExternalStorageService(),
        videoLibraryService: VideoLibraryServicing = VideoLibraryService(),
        videoMigrationService: VideoMigrating = VideoMigrationService(),
        photoDeletionService: PhotoDeleting = PhotoDeletionService(),
        selectionRulesService: SelectionRulesServicing = SelectionRulesService()
    ) {
        self.photoPermissionService = photoPermissionService
        self.externalStorageService = externalStorageService
        self.videoLibraryService = videoLibraryService
        self.videoMigrationService = videoMigrationService
        self.photoDeletionService = photoDeletionService
        self.selectionRulesService = selectionRulesService
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
        if permissionState == .notDetermined {
            Task {
                let status = await photoPermissionService.requestReadWriteAccess()
                permissionState = status
                guard permissionState.canReadLibrary else {
                    alertMessage = L10n.tr("Photo access is required before scanning videos.")
                    return
                }
                beginScan()
            }
            return
        }

        guard permissionState.canReadLibrary else {
            alertMessage = L10n.tr("Photo access is required before scanning videos.")
            return
        }

        beginScan()
    }

    private func beginScan() {
        isScanningVideos = true
        listVisibleLimit = 20
        showSelectedOnly = false
        selectedVideoIDs.removeAll()
        selectedKnownSizeCount = 0
        selectedTotalKnownBytes = 0
        lastMigrationResult = nil
        videoSizeBytesByID = [:]
        inFlightSizeAssetIDs = []
        monthSummaries = []
        monthIndex = [:]

        Task {
            let fetchedVideos = await videoLibraryService.fetchVideosSortedByDate(limit: nil)
            videos = fetchedVideos
            applySort()
            isScanningVideos = false
            rebuildMonthIndex()

            // Prepare sizes in the background so "Sort by Size" works immediately and correctly.
            await prefetchSizesForAllScannedVideosIfNeeded()
        }
    }

    // MARK: - Selection (M4)

    func toggleSelection(for assetID: String) {
        if selectedVideoIDs.contains(assetID) {
            selectedVideoIDs.remove(assetID)
            if let bytes = videoSizeBytesByID[assetID] {
                selectedTotalKnownBytes -= bytes
                selectedKnownSizeCount = max(0, selectedKnownSizeCount - 1)
            }
        } else {
            selectedVideoIDs.insert(assetID)
            if let bytes = videoSizeBytesByID[assetID] {
                selectedTotalKnownBytes += bytes
                selectedKnownSizeCount += 1
            }
        }
    }

    func selectAllScannedVideos() {
        selectedVideoIDs = Set(videos.map(\.id))
        recomputeSelectedSizeTotals()
    }

    func clearSelection() {
        selectedVideoIDs.removeAll()
        selectedKnownSizeCount = 0
        selectedTotalKnownBytes = 0
    }

    // MARK: - Sorting + Size (M9)

    var sortField: VideoSortField {
        switch sortMode {
        case .dateDesc, .dateAsc:
            return .date
        case .sizeDesc, .sizeAsc:
            return .size
        }
    }

    var isSortAscending: Bool {
        switch sortMode {
        case .dateAsc, .sizeAsc:
            return true
        case .dateDesc, .sizeDesc:
            return false
        }
    }

    func setSort(field: VideoSortField) {
        let ascending = isSortAscending
        switch field {
        case .date:
            sortMode = ascending ? .dateAsc : .dateDesc
        case .size:
            sortMode = ascending ? .sizeAsc : .sizeDesc
        }
    }

    func toggleSortOrder() {
        switch sortMode {
        case .dateDesc:
            sortMode = .dateAsc
        case .dateAsc:
            sortMode = .dateDesc
        case .sizeDesc:
            sortMode = .sizeAsc
        case .sizeAsc:
            sortMode = .sizeDesc
        }
    }

    func formattedSizeText(for assetID: String) -> String {
        guard let bytes = videoSizeBytesByID[assetID] else { return "--" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    var selectedTotalSizeText: String {
        guard selectedKnownSizeCount > 0 else { return "--" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: selectedTotalKnownBytes)
    }

    func ensureSizeLoaded(for assetID: String) {
        guard permissionState.canReadLibrary else { return }
        // Avoid duplicate per-row fetches when we are already prefetching sizes for the full library.
        guard !isFetchingAllVideoSizes else { return }
        guard videoSizeBytesByID[assetID] == nil else { return }
        guard !inFlightSizeAssetIDs.contains(assetID) else { return }
        inFlightSizeAssetIDs.insert(assetID)

        Task {
            let sizes = await videoLibraryService.fetchVideoFileSizesBytes(assetIDs: [assetID])
            if let bytes = sizes[assetID] {
                let wasMissing = (videoSizeBytesByID[assetID] == nil)
                videoSizeBytesByID[assetID] = bytes
                if wasMissing, selectedVideoIDs.contains(assetID) {
                    selectedTotalKnownBytes += bytes
                    selectedKnownSizeCount += 1
                }
            }
            inFlightSizeAssetIDs.remove(assetID)

            // Only re-sort automatically when sorting by size to avoid annoying reorders.
            if sortMode != .dateDesc && sortMode != .dateAsc {
                applySort()
            }
        }
    }

    private func prefetchSizesForVisibleRangeIfNeeded() {
        guard permissionState.canReadLibrary else { return }
        let ids = Array(displayedVideos.map(\.id))
        guard !ids.isEmpty else { return }

        let missing = ids.filter { videoSizeBytesByID[$0] == nil && !inFlightSizeAssetIDs.contains($0) }
        guard !missing.isEmpty else { return }

        isFetchingVideoSizes = true
        missing.forEach { inFlightSizeAssetIDs.insert($0) }
        Task {
            let sizes = await videoLibraryService.fetchVideoFileSizesBytes(assetIDs: missing)
            for (id, bytes) in sizes {
                let wasMissing = (videoSizeBytesByID[id] == nil)
                videoSizeBytesByID[id] = bytes
                if wasMissing, selectedVideoIDs.contains(id) {
                    selectedTotalKnownBytes += bytes
                    selectedKnownSizeCount += 1
                }
            }
            missing.forEach { inFlightSizeAssetIDs.remove($0) }
            isFetchingVideoSizes = false

            if sortMode != .dateDesc && sortMode != .dateAsc {
                applySort()
            }
        }
    }

    private func prefetchSizesForAllScannedVideosIfNeeded() async {
        guard permissionState.canReadLibrary else { return }
        guard !isFetchingAllVideoSizes else { return }
        let allIDs = videos.map(\.id)
        // Don't exclude in-flight IDs here. Full prefetch should attempt all unknown sizes at least once.
        let missing = allIDs.filter { videoSizeBytesByID[$0] == nil }
        guard !missing.isEmpty else { return }

        isFetchingAllVideoSizes = true
        isFetchingVideoSizes = true
        let sizes = await videoLibraryService.fetchVideoFileSizesBytes(assetIDs: missing)
        for (id, bytes) in sizes {
            let wasMissing = (videoSizeBytesByID[id] == nil)
            videoSizeBytesByID[id] = bytes
            if wasMissing, selectedVideoIDs.contains(id) {
                selectedTotalKnownBytes += bytes
                selectedKnownSizeCount += 1
            }
        }
        isFetchingVideoSizes = false
        isFetchingAllVideoSizes = false

        if sortMode != .dateDesc && sortMode != .dateAsc {
            applySort()
        }
    }

    private func rebuildMonthIndex() {
        monthIndex = selectionRulesService.buildMonthIndex(videos: videos)
        monthSummaries = selectionRulesService.monthSummaries(from: monthIndex)
    }

    func applyMonthSelection(_ months: Set<MonthKey>) {
        let ids = selectionRulesService.assetIDs(for: months, in: monthIndex)
        addToSelection(ids)
    }

    func applyTopNSelection(_ n: Int) {
        guard n > 0 else { return }
        guard permissionState.canReadLibrary else {
            alertMessage = L10n.tr("Photo access is required before scanning videos.")
            return
        }

        Task {
            await prefetchSizesForAllScannedVideosIfNeeded()
            let ids = selectionRulesService.topNAssetIDsBySize(n: n, videos: videos, sizesBytesByID: videoSizeBytesByID)
            addToSelection(Set(ids))

            if ids.count < n {
                alertMessage = L10n.tr(
                    "Selected %d item(s). Some videos may not have a local size available (iCloud-only).",
                    ids.count
                )
            }
        }
    }

    func applyQuickFilter(months: Set<MonthKey>, topN: Int) {
        guard permissionState.canReadLibrary else {
            alertMessage = L10n.tr("Photo access is required before scanning videos.")
            return
        }

        Task {
            let candidates: [VideoAssetSummary]
            if months.isEmpty {
                candidates = videos
            } else {
                let ids = selectionRulesService.assetIDs(for: months, in: monthIndex)
                candidates = videos.filter { ids.contains($0.id) }
            }

            var selectedIDs: [String] = []
            if topN > 0 {
                await prefetchSizesForAllScannedVideosIfNeeded()
                selectedIDs = selectionRulesService.topNAssetIDsBySize(
                    n: topN,
                    videos: candidates,
                    sizesBytesByID: videoSizeBytesByID
                )
                if selectedIDs.count < topN {
                    alertMessage = L10n.tr(
                        "Selected %d item(s). Some videos may not have a local size available (iCloud-only).",
                        selectedIDs.count
                    )
                }
            } else {
                selectedIDs = candidates.map(\.id)
            }

            selectedVideoIDs = Set(selectedIDs)
            recomputeSelectedSizeTotals()
        }
    }

    private func applySort() {
        switch sortMode {
        case .dateDesc:
            videos.sort { $0.creationDate > $1.creationDate }
        case .dateAsc:
            videos.sort { $0.creationDate < $1.creationDate }
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

    // MARK: - List display (M10)

    var displayedVideos: [VideoAssetSummary] {
        let base = showSelectedOnly ? videos.filter { selectedVideoIDs.contains($0.id) } : videos
        let cap = min(base.count, listVisibleLimit)
        return Array(base.prefix(cap))
    }

    var hasMoreVideosToShow: Bool {
        let total = showSelectedOnly ? videos.filter { selectedVideoIDs.contains($0.id) }.count : videos.count
        return displayedVideos.count < total
    }

    func loadMoreVideos() {
        let total = showSelectedOnly ? videos.filter { selectedVideoIDs.contains($0.id) }.count : videos.count
        listVisibleLimit = min(listVisibleLimit + 20, total)
        prefetchSizesForVisibleRangeIfNeeded()
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
            await videoMigrationService.migrateVideoAssetIDs(assetIDs, to: folderURL) { [weak self] progress in
                Task { @MainActor in
                    self?.migrationProgress = progress
                }
            } onResult: { [weak self] result in
                Task { @MainActor in
                    self?.isMigrating = false
                    self?.lastMigrationResult = result
                    if result.failureCount == 0 {
                        self?.alertMessage = L10n.tr("Migration completed. (Deletion is available below.)")
                    } else {
                        self?.alertMessage = L10n.tr("Migration completed with failures: %d success, %d failed.", result.successCount, result.failureCount)
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
        guard permissionState.canDeleteFromLibrary else {
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

    private func addToSelection(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        for id in ids where !selectedVideoIDs.contains(id) {
            selectedVideoIDs.insert(id)
            if let bytes = videoSizeBytesByID[id] {
                selectedTotalKnownBytes += bytes
                selectedKnownSizeCount += 1
            }
        }
    }

    private func recomputeSelectedSizeTotals() {
        var total: Int64 = 0
        var known = 0
        for id in selectedVideoIDs {
            if let bytes = videoSizeBytesByID[id] {
                total += bytes
                known += 1
            }
        }
        selectedTotalKnownBytes = total
        selectedKnownSizeCount = known
    }
}
