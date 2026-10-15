import UIKit

/// `photos-redirect://` only launches the Photos app.
/// It does not deep-link into Recently Deleted.
enum PhotosRedirect {
    static let url = URL(string: "photos-redirect://")!
}

@MainActor
protocol PhotosAppOpening {
    func openPhotosApp()
}

@MainActor
struct PhotosAppOpener: PhotosAppOpening {
    func openPhotosApp() {
        UIApplication.shared.open(PhotosRedirect.url, options: [:], completionHandler: nil)
    }
}
