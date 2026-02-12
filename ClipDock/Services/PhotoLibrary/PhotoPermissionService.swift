import Photos

enum PhotoPermissionState: String {
    case notDetermined
    case restricted
    case denied
    case authorized
    case limited

    var canReadLibrary: Bool {
        self == .authorized || self == .limited
    }

    var displayText: String {
        switch self {
        case .notDetermined:
            return L10n.tr("Not Determined")
        case .restricted:
            return L10n.tr("Restricted")
        case .denied:
            return L10n.tr("Denied")
        case .authorized:
            return L10n.tr("Authorized")
        case .limited:
            return L10n.tr("Limited")
        }
    }
}

protocol PhotoPermissionServicing {
    func currentStatus() -> PhotoPermissionState
    func requestReadWriteAccess() async -> PhotoPermissionState
}

struct PhotoPermissionService: PhotoPermissionServicing {
    func currentStatus() -> PhotoPermissionState {
        Self.mapStatus(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    func requestReadWriteAccess() async -> PhotoPermissionState {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                continuation.resume(returning: Self.mapStatus(status))
            }
        }
    }

    private static func mapStatus(_ status: PHAuthorizationStatus) -> PhotoPermissionState {
        switch status {
        case .notDetermined:
            return .notDetermined
        case .restricted:
            return .restricted
        case .denied:
            return .denied
        case .authorized:
            return .authorized
        case .limited:
            return .limited
        @unknown default:
            return .denied
        }
    }
}
