import Foundation

enum ExternalStorageError: LocalizedError {
    case missingBookmark
    case invalidBookmark
    case folderNotWritable

    var errorDescription: String? {
        switch self {
        case .missingBookmark:
            return "No external folder selected yet."
        case .invalidBookmark:
            return "Saved external folder permission expired. Please select the folder again."
        case .folderNotWritable:
            return "Selected external folder is not writable."
        }
    }
}

protocol ExternalStorageServicing {
    func saveFolderBookmark(_ folderURL: URL) throws
    func resolveSavedFolderURL() throws -> URL?
    func validateFolderWritable(_ folderURL: URL) -> Bool
}

final class ExternalStorageService: ExternalStorageServicing {
    private let bookmarkKey = "clipdock.external.folder.bookmark"
    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func saveFolderBookmark(_ folderURL: URL) throws {
        let bookmarkData = try folderURL.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        userDefaults.set(bookmarkData, forKey: bookmarkKey)
    }

    func resolveSavedFolderURL() throws -> URL? {
        guard let bookmarkData = userDefaults.data(forKey: bookmarkKey) else {
            return nil
        }

        var isStale = false
        let folderURL = try URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )

        if isStale {
            try saveFolderBookmark(folderURL)
        }

        return folderURL
    }

    func validateFolderWritable(_ folderURL: URL) -> Bool {
        do {
            return try withSecurityScopedAccess(to: folderURL) {
                let fileManager = FileManager.default
                let probeURL = folderURL.appendingPathComponent(".clipdock_write_probe_\(UUID().uuidString)")
                let data = Data("probe".utf8)
                try data.write(to: probeURL, options: .atomic)
                try fileManager.removeItem(at: probeURL)
                return true
            }
        } catch {
            return false
        }
    }

    private func withSecurityScopedAccess<T>(to folderURL: URL, _ action: () throws -> T) throws -> T {
        let started = folderURL.startAccessingSecurityScopedResource()
        defer {
            if started {
                folderURL.stopAccessingSecurityScopedResource()
            }
        }
        return try action()
    }
}
