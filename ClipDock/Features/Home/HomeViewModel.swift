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
    /// Per-file copy + size-check state for the latest batch. Empty before the first run.
    @Published var copyItems: [CopyItemState] = []
    @Published var isMigrationSessionVisible = false
    /// When the current copy session began. Replaced on every start and re-copy.
    private var copySessionStartedAt: Date?

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
    private var migrationTask: Task<Void, Never>?
    private var migrationGeneration = 0
    private let now: @Sendable () -> Date

    init(
        photoPermissionService: PhotoPermissionServicing = PhotoPermissionService(),
        externalStorageService: ExternalStorageServicing = ExternalStorageService(),
        videoLibraryService: VideoLibraryServicing = VideoLibraryService(),
        videoMigrationService: VideoMigrating = VideoMigrationService(),
        photoDeletionService: PhotoDeleting = PhotoDeletionService(),
        selectionRulesService: SelectionRulesServicing = SelectionRulesService(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.photoPermissionService = photoPermissionService
        self.externalStorageService = externalStorageService
        self.videoLibraryService = videoLibraryService
        self.videoMigrationService = videoMigrationService
        self.photoDeletionService = photoDeletionService
        self.selectionRulesService = selectionRulesService
        self.now = now
    }

    @MainActor
    static func makeForCurrentEnvironment() -> HomeViewModel {
        return HomeViewModel()
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
        guard !isScanningVideos else { return }

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
        copyItems = []
        copySessionStartedAt = nil
        isMigrationSessionVisible = false
        migrationGeneration += 1
        migrationTask?.cancel()
        migrationTask = nil
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
        guard !isMigrating, !isDeleting else { return }
        guard permissionState.canReadLibrary else {
            alertMessage = L10n.tr("Photo access is required before migrating videos.")
            return
        }
        guard selectedFolderURL != nil else {
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

        copyItems = assetIDs.map { id in
            CopyItemState(
                assetID: id,
                displayName: id,
                expectedBytes: videoSizeBytesByID[id] ?? 0,
                status: .pending
            )
        }
        isMigrationSessionVisible = true
        lastMigrationResult = nil
        runMigration(assetIDs: assetIDs)
    }

    /// Copies only size-mismatched items, then size-checks those copies again.
    /// IDs that are not currently mismatches are ignored.
    func recopyMismatchedFiles(assetIDs: [String]? = nil) {
        guard !isMigrating, !isDeleting else { return }
        guard permissionState.canReadLibrary else {
            alertMessage = L10n.tr("Photo access is required before migrating videos.")
            return
        }
        guard selectedFolderURL != nil else {
            alertMessage = VideoMigrationError.noTargetFolder.errorDescription
            return
        }
        guard isFolderWritable else {
            alertMessage = VideoMigrationError.targetFolderNotWritable.errorDescription
            return
        }

        let mismatched = CopyDeletionPolicy.mismatchAssetIDs(in: copyItems)
        let requested = assetIDs ?? mismatched
        let ids = requested.filter { mismatched.contains($0) }
        guard !ids.isEmpty else { return }

        isMigrationSessionVisible = true
        removeCopiedFiles(for: ids)
        let idSet = Set(ids)
        for index in copyItems.indices where idSet.contains(copyItems[index].assetID) {
            copyItems[index].status = .pending
            copyItems[index].actualBytes = nil
        }
        runMigration(assetIDs: ids)
    }

    /// Drops the previous mismatched copies so the next export can write a fresh file under the same name.
    private func removeCopiedFiles(for assetIDs: [String]) {
        guard let folderURL = selectedFolderURL else { return }
        let started = folderURL.startAccessingSecurityScopedResource()
        defer {
            if started {
                folderURL.stopAccessingSecurityScopedResource()
            }
        }
        let folderPath = folderURL.standardizedFileURL.path
        let ids = Set(assetIDs)
        for item in copyItems where ids.contains(item.assetID) {
            guard let destinationURL = item.destinationURL else { continue }
            let path = destinationURL.standardizedFileURL.path
            // Only remove a file we previously wrote inside the chosen folder.
            guard path == folderPath || path.hasPrefix(folderPath + "/") else { continue }
            try? FileManager.default.removeItem(at: destinationURL)
        }
    }

    func stopMigration() {
        guard isMigrating else { return }
        migrationGeneration += 1
        migrationTask?.cancel()
        migrationTask = nil
        isMigrating = false
        for index in copyItems.indices {
            if case .copying = copyItems[index].status {
                copyItems[index].status = .pending
            }
        }
    }

    func postponeOriginalDeletion() {
        guard !isMigrating, !isDeleting else { return }
        isMigrationSessionVisible = false
    }

    var shouldShowMigrationSession: Bool {
        isMigrationSessionVisible || isMigrating
    }

    var copyEligibility: CopyDeletionEligibility {
        CopyDeletionPolicy.eligibility(for: copyItems)
    }

    var sessionStats: CopySessionStats {
        CopySessionStats.make(items: copyItems, isMigrating: isMigrating)
    }

    /// Byte progress while copying. Appends a remaining-time estimate once throughput is known.
    var copyingByteSubtitle: String {
        let stats = sessionStats
        let ratio = "\(ByteCountText.string(fromBytes: stats.copiedBytes)) / \(ByteCountText.string(fromBytes: stats.totalBytes))"
        guard let copySessionStartedAt else { return ratio }
        let elapsed = now().timeIntervalSince(copySessionStartedAt)
        guard let remaining = CopyTimeEstimator.remainingSeconds(
            copiedBytes: stats.copiedBytes,
            totalBytes: stats.totalBytes,
            elapsed: elapsed
        ) else {
            return ratio
        }
        return "\(ratio) · \(CopyTimeEstimator.minutesText(remaining))"
    }

    var deleteOriginalsButtonTitle: String {
        if !copyItems.isEmpty {
            let eligibility = copyEligibility
            // Stay on the unavailable label for the whole copy, including files already size-checked.
            if !isMigrating, eligibility.isVerificationComplete, eligibility.verifiedCount > 0 {
                return L10n.tr(
                    "Delete %d originals · %@",
                    eligibility.verifiedCount,
                    ByteCountText.string(fromBytes: eligibility.deletableBytes)
                )
            }
            return L10n.tr("Delete originals (available after verification)")
        }
        if let result = lastMigrationResult, result.successCount > 0 {
            return L10n.tr("Delete Originals")
        }
        return L10n.tr("Delete originals (available after verification)")
    }

    /// Footnote under a finished batch that still has size mismatches.
    var mismatchRetentionNote: String {
        let verified = copyEligibility.verifiedCount
        if copyEligibility.mismatchCount == 1 {
            return L10n.tr(
                "Only the %d verified items can be deleted. The mismatched one stays on the phone.",
                verified
            )
        }
        return L10n.tr(
            "Only the %d verified items can be deleted. Mismatched items stay on the phone.",
            verified
        )
    }

    private func runMigration(assetIDs: [String]) {
        guard let folderURL = selectedFolderURL else { return }
        guard !assetIDs.isEmpty else { return }

        migrationTask?.cancel()
        migrationGeneration += 1
        let generation = migrationGeneration
        copySessionStartedAt = now()
        isMigrating = true
        migrationProgress = MigrationProgress(
            completed: 0,
            total: max(copyItems.count, assetIDs.count),
            currentFilename: nil,
            isIndeterminate: true
        )

        migrationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.videoMigrationService.migrateVideoAssetIDs(assetIDs, to: folderURL) { [weak self] progress in
                Task { @MainActor in
                    guard let self, self.migrationGeneration == generation else { return }
                    self.applyMigrationProgress(progress)
                }
            } onResult: { [weak self] result in
                Task { @MainActor in
                    guard let self, self.migrationGeneration == generation else { return }
                    self.finishMigration(result, scopedAssetIDs: assetIDs)
                }
            }
        }
    }

    private func applyMigrationProgress(_ progress: MigrationProgress) {
        migrationProgress = progress
        for file in progress.files {
            updateCopyItem(file.assetID) { item in
                if item.status.isFinished && !file.status.isFinished {
                    return
                }
                item.status = file.status
                if !file.displayName.isEmpty && file.displayName != file.assetID {
                    item.displayName = file.displayName
                }
                if file.expectedBytes > 0 {
                    item.expectedBytes = file.expectedBytes
                }
                if let actualBytes = file.actualBytes {
                    item.actualBytes = actualBytes
                }
                if let destinationURL = file.destinationURL {
                    item.destinationURL = destinationURL
                }
            }
        }
    }

    private func finishMigration(_ result: MigrationRunResult, scopedAssetIDs: [String]) {
        let allowed = Set(scopedAssetIDs)
        for success in result.successes where allowed.contains(success.assetID) {
            updateCopyItem(success.assetID) { item in
                item.status = .verified
                item.destinationURL = success.destinationURL
                item.actualBytes = success.bytes
                let source = success.sourceBytes ?? success.bytes
                if source > 0 {
                    item.expectedBytes = source
                }
                if item.displayName == item.assetID {
                    let name = success.destinationURL.lastPathComponent
                    if !name.isEmpty {
                        item.displayName = name
                    }
                }
            }
        }
        for mismatch in result.sizeMismatches where allowed.contains(mismatch.assetID) {
            updateCopyItem(mismatch.assetID) { item in
                item.status = .mismatch(expected: mismatch.expectedBytes, actual: mismatch.actualBytes)
                item.destinationURL = mismatch.destinationURL
                item.expectedBytes = mismatch.expectedBytes
                item.actualBytes = mismatch.actualBytes
                if item.displayName == item.assetID {
                    let name = mismatch.destinationURL.lastPathComponent
                    if !name.isEmpty {
                        item.displayName = name
                    }
                }
            }
        }
        for failure in result.failures where allowed.contains(failure.assetID) {
            updateCopyItem(failure.assetID) { item in
                item.status = .failed(failure.message)
            }
        }

        isMigrating = false
        migrationTask = nil
        rebuildLastMigrationResult()

        if result.failureCount > 0 {
            alertMessage = L10n.tr(
                "Migration completed with failures: %d success, %d failed.",
                result.successCount,
                result.failureCount
            )
        }
    }

    private func rebuildLastMigrationResult() {
        var successes: [MigrationItemSuccess] = []
        var failures: [MigrationItemFailure] = []
        var mismatches: [MigrationSizeMismatch] = []
        successes.reserveCapacity(copyItems.count)

        for item in copyItems {
            switch item.status {
            case .verified:
                let bytes = item.actualBytes ?? item.expectedBytes
                let url = item.destinationURL ?? URL(fileURLWithPath: "/")
                successes.append(.init(assetID: item.assetID, destinationURL: url, bytes: bytes, sourceBytes: item.expectedBytes))
            case .mismatch(let expected, let actual):
                let url = item.destinationURL ?? URL(fileURLWithPath: "/")
                mismatches.append(.init(
                    assetID: item.assetID,
                    destinationURL: url,
                    expectedBytes: expected,
                    actualBytes: actual,
                    fileWasMissing: false
                ))
            case .failed(let message):
                failures.append(.init(assetID: item.assetID, message: message))
            case .pending, .copying:
                break
            }
        }

        lastMigrationResult = MigrationRunResult(successes: successes, failures: failures, sizeMismatches: mismatches)
    }

    private func updateCopyItem(_ assetID: String, _ body: (inout CopyItemState) -> Void) {
        guard let index = copyItems.firstIndex(where: { $0.assetID == assetID }) else { return }
        body(&copyItems[index])
    }

    // MARK: - Deletion (M7)

    var deletableAssetIDs: [String] {
        if !copyItems.isEmpty {
            return copyEligibility.deletableAssetIDs
        }
        return lastMigrationResult?.successes.map(\.assetID) ?? []
    }

    var deletableSuccessCount: Int {
        deletableAssetIDs.count
    }

    /// Delete stays off until every file in the batch has finished size verification, and at least one file matched.
    var isDeleteEnabled: Bool {
        if isDeleting || isMigrating { return false }
        if !copyItems.isEmpty {
            return copyEligibility.isDeleteEnabled
        }
        return (lastMigrationResult?.successCount ?? 0) > 0
    }

    func promptDeleteMigratedOriginals() {
        guard isDeleteEnabled else { return }
        isShowingDeleteConfirm = true
    }

    func deleteMigratedOriginals() {
        guard !isDeleting else { return }
        guard permissionState.canDeleteFromLibrary else {
            alertMessage = L10n.tr("Full Photos access is required to delete videos.")
            return
        }

        let assetIDs: [String]
        if !copyItems.isEmpty {
            guard copyEligibility.isDeleteEnabled else { return }
            assetIDs = copyEligibility.deletableAssetIDs
        } else if let result = lastMigrationResult {
            assetIDs = result.successes.map(\.assetID)
        } else {
            assetIDs = []
        }

        guard !assetIDs.isEmpty else {
            alertMessage = PhotoDeletionError.nothingToDelete.errorDescription
            return
        }

        isDeleting = true
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
