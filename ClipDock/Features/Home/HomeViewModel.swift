import Foundation

@MainActor
final class HomeViewModel: ObservableObject {
    @Published var permissionState: PhotoPermissionState = .notDetermined
    @Published var selectedFolderURL: URL?
    @Published var isFolderWritable = false
    @Published var videos: [VideoAssetSummary] = []
    @Published var isScanningVideos = false
    @Published var alertMessage: String?

    private(set) var hasLoadedInitialData = false

    private let photoPermissionService: PhotoPermissionServicing
    private let externalStorageService: ExternalStorageServicing
    private let videoLibraryService: VideoLibraryServicing

    init(
        photoPermissionService: PhotoPermissionServicing = PhotoPermissionService(),
        externalStorageService: ExternalStorageServicing = ExternalStorageService(),
        videoLibraryService: VideoLibraryServicing = VideoLibraryService()
    ) {
        self.photoPermissionService = photoPermissionService
        self.externalStorageService = externalStorageService
        self.videoLibraryService = videoLibraryService
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
        Task {
            let fetchedVideos = await videoLibraryService.fetchVideosSortedByDate(limit: nil)
            videos = fetchedVideos
            isScanningVideos = false
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
