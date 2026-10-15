import SwiftUI
import UIKit
import XCTest
@testable import ClipDock

/// Writes dark-mode PNGs when `CLIPDOCK_SCREENSHOT_DIR` is set.
/// xcodebuild forwards `TEST_RUNNER_CLIPDOCK_SCREENSHOT_DIR` into the test process under that name.
@MainActor
final class ScreenshotExportTests: XCTestCase {
    private let canvasSize = CGSize(width: 393, height: 852)

    func testExportsScreenshotFixturesWhenDirectoryIsSet() throws {
        let raw = ProcessInfo.processInfo.environment["CLIPDOCK_SCREENSHOT_DIR"]
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw XCTSkip("CLIPDOCK_SCREENSHOT_DIR is not set")
        }

        let directory = URL(fileURLWithPath: raw, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        export("01-home.png") { try self.exportHome(to: directory) }
        export("02-picker.png") { try self.exportPicker(to: directory) }
        export("03-migrating.png") { try self.exportMigrating(to: directory) }
        export("04-result-pending.png") {
            try self.exportResult(name: "04-result-pending.png", readings: [20_000_000_000, 20_000_000_000], to: directory)
        }
        export("05-result-freed-within.png") {
            // 13.1 GB freed against 13.4 GB expected is inside ±5%.
            try self.exportResult(
                name: "05-result-freed-within.png",
                readings: [20_000_000_000, 33_100_000_000],
                to: directory
            )
        }
        export("06-result-freed-outside.png") {
            // 10 GB freed against 13.4 GB expected is outside ±5%.
            try self.exportResult(
                name: "06-result-freed-outside.png",
                readings: [20_000_000_000, 30_000_000_000],
                to: directory
            )
        }
    }

    private func export(_ name: String, _ body: () throws -> Void) {
        do {
            try body()
        } catch {
            XCTFail("\(name) failed to render: \(error)")
        }
    }

    private func exportHome(to directory: URL) throws {
        let viewModel = makeHomeViewModel()
        viewModel.loadInitialDataIfNeeded()
        try render(HomeView(viewModel: viewModel), name: "01-home.png", to: directory)
    }

    private func exportPicker(to directory: URL) throws {
        let viewModel = makeHomeViewModel()
        viewModel.loadInitialDataIfNeeded()
        viewModel.selectLargestVideos(count: HomeLibrarySummary.defaultTopN)
        try render(
            HomeView(viewModel: viewModel, initiallyShowingPicker: true),
            name: "02-picker.png",
            to: directory
        )
    }

    private func exportMigrating(to directory: URL) throws {
        let viewModel = makeHomeViewModel()
        // `loadInitialDataIfNeeded` clears copy state while it starts the scan. Install the mid-copy session after that.
        viewModel.loadInitialDataIfNeeded()
        viewModel.copyItems = midCopyItems()
        viewModel.isMigrating = true
        viewModel.isMigrationSessionVisible = true
        viewModel.migrationProgress = MigrationProgress(
            completed: 2,
            total: 5,
            currentFilename: "IMG_1650.MOV",
            isIndeterminate: false
        )
        try render(HomeView(viewModel: viewModel), name: "03-migrating.png", to: directory)
    }

    private func exportResult(name: String, readings: [Int64?], to directory: URL) throws {
        let model = makeResultModel(readings: readings)
        try render(DeletionResultView(model: model, onClose: {}), name: name, to: directory)
    }

    private func render<Content: View>(_ content: Content, name: String, to directory: URL) throws {
        let host = try makeHost(rootView: content)
        defer { host.tearDown() }
        settleRunLoop()
        try writePNG(of: host.controller.view, name: name, to: directory)
    }

    private func makeHost<Content: View>(rootView: Content) throws -> ScreenshotHost {
        guard let scene = connectedWindowScene() else {
            throw ScreenshotExportError.missingWindowScene
        }
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: canvasSize)
        window.overrideUserInterfaceStyle = .dark
        window.backgroundColor = UIColor(red: 11.0 / 255.0, green: 13.0 / 255.0, blue: 16.0 / 255.0, alpha: 1)

        let controller = UIHostingController(rootView: rootView)
        controller.overrideUserInterfaceStyle = .dark
        controller.view.frame = CGRect(origin: .zero, size: canvasSize)
        controller.view.backgroundColor = window.backgroundColor
        window.rootViewController = controller
        window.makeKeyAndVisible()
        pinCanvas(window)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        return ScreenshotHost(window: window, controller: controller, previousKeyWindow: previousKeyWindow)
    }

    private func pinCanvas(_ window: UIWindow) {
        window.frame = CGRect(origin: .zero, size: canvasSize)
        window.rootViewController?.view.frame = CGRect(origin: .zero, size: canvasSize)
    }

    /// About 1.2s in short turns so `onAppear` and measurement tasks can finish.
    private func settleRunLoop() {
        let deadline = Date().addingTimeInterval(1.2)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }

    private func writePNG(of view: UIView, name: String, to directory: URL) throws {
        if let window = view.window {
            pinCanvas(window)
        }
        view.bounds = CGRect(origin: .zero, size: canvasSize)
        view.frame = CGRect(origin: .zero, size: canvasSize)
        view.setNeedsLayout()
        view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: canvasSize, format: format)
        let rect = CGRect(origin: .zero, size: canvasSize)
        var drew = false
        let image = renderer.image { _ in
            drew = view.drawHierarchy(in: rect, afterScreenUpdates: true)
        }
        guard drew else {
            throw ScreenshotExportError.drawFailed(name)
        }
        guard let data = image.pngData(), !data.isEmpty, image.size.width > 0, image.size.height > 0 else {
            throw ScreenshotExportError.emptyImage(name)
        }
        try data.write(to: directory.appendingPathComponent(name), options: .atomic)
    }

    private func connectedWindowScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let active = scenes.first(where: { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive }) {
            return active
        }
        return scenes.first
    }

    private func makeHomeViewModel() -> HomeViewModel {
        let permission = MockPhotoPermissionService()
        permission.status = .authorized

        let storage = MockExternalStorageService()
        storage.validateWritableResult = true
        let folder = URL(fileURLWithPath: "/Volumes/SanDisk/ClipDock")
        storage.resolvedURL = folder

        let library = MockVideoLibraryService()
        let videos = fixtureVideos()
        library.fetchVideosResult = videos.map { $0.summary }
        library.fetchSizesResult = Dictionary(uniqueKeysWithValues: videos.map { ($0.summary.id, $0.bytes) })

        let deviceURL = URL(fileURLWithPath: "/tmp/clipdock-screenshot-device")
        let reader = MockVolumeCapacityReader()
        reader.snapshotByPath[deviceURL.path] = VolumeCapacitySnapshot(
            name: "iPhone",
            totalBytes: 128_000_000_000,
            availableBytes: 18_000_000_000
        )
        reader.snapshotByPath[folder.path] = VolumeCapacitySnapshot(
            name: "SanDisk",
            totalBytes: 256_000_000_000,
            availableBytes: 212_000_000_000
        )

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let summaryDate = calendar.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 12))
            ?? Date(timeIntervalSince1970: 1_791_763_200)
        let store = MockLastMigrationSummaryStore(
            stored: LastMigrationSummary(
                date: summaryDate,
                copiedCount: 12,
                verifiedCount: 12,
                totalCount: 12
            )
        )

        let viewModel = HomeViewModel(
            photoPermissionService: permission,
            externalStorageService: storage,
            videoLibraryService: library,
            videoMigrationService: MockVideoMigrationService(),
            photoDeletionService: MockPhotoDeletionService(),
            volumeCapacityReader: reader,
            deviceVolumeURL: deviceURL,
            lastMigrationSummaryStore: store
        )
        viewModel.setSelectedFolder(folder)
        return viewModel
    }

    private func makeResultModel(readings: [Int64?]) -> DeletionResultViewModel {
        let model = DeletionResultViewModel(
            snapshot: DeletionResultSnapshot(
                copiedCount: 5,
                verifiedMatchCount: 5,
                verifiedTotalCount: 5,
                pendingReleaseBytes: 13_400_000_000
            ),
            freeSpaceMonitor: ScreenshotFreeSpaceMonitor(readings),
            reviewRequester: ScreenshotReviewRequester(),
            photosOpener: ScreenshotPhotosOpener(),
            remeasureDelayNanoseconds: 0,
            sleep: { _ in
                await Task.yield()
            }
        )
        model.openPhotos()
        model.handleScenePhase(.background)
        model.handleScenePhase(.active)
        return model
    }

    /// Twelve library videos whose known sizes sum to 21.4 GB.
    private func fixtureVideos() -> [(summary: VideoAssetSummary, bytes: Int64)] {
        let specs: [(String, TimeInterval, Int64)] = [
            ("v01", 252, 3_800_000_000),
            ("v02", 220, 3_100_000_000),
            ("v03", 178, 2_600_000_000),
            ("v04", 361, 2_200_000_000),
            ("v05", 115, 1_900_000_000),
            ("v06", 150, 1_700_000_000),
            ("v07", 81, 1_400_000_000),
            ("v08", 70, 1_200_000_000),
            ("v09", 62, 1_000_000_000),
            ("v10", 58, 900_000_000),
            ("v11", 51, 800_000_000),
            ("v12", 47, 800_000_000),
        ]
        let base = Date(timeIntervalSince1970: 1_735_689_600)
        return specs.enumerated().map { index, spec in
            let summary = VideoAssetSummary(
                id: spec.0,
                creationDate: base.addingTimeInterval(TimeInterval(-index * 86_400)),
                duration: spec.1,
                pixelWidth: 1920,
                pixelHeight: 1080
            )
            return (summary, spec.2)
        }
    }

    private func midCopyItems() -> [CopyItemState] {
        [
            CopyItemState(
                assetID: "IMG_2041",
                displayName: "IMG_2041.MOV",
                expectedBytes: 3_800_000_000,
                actualBytes: 3_800_000_000,
                status: .verified
            ),
            CopyItemState(
                assetID: "IMG_1877",
                displayName: "IMG_1877.MOV",
                expectedBytes: 3_100_000_000,
                actualBytes: 3_100_000_000,
                status: .verified
            ),
            CopyItemState(
                assetID: "IMG_1650",
                displayName: "IMG_1650.MOV",
                expectedBytes: 2_600_000_000,
                status: .copying
            ),
            CopyItemState(
                assetID: "IMG_1502",
                displayName: "IMG_1502.MOV",
                expectedBytes: 2_200_000_000,
                status: .pending
            ),
            CopyItemState(
                assetID: "IMG_0998",
                displayName: "IMG_0998.MOV",
                expectedBytes: 1_700_000_000,
                status: .pending
            ),
        ]
    }
}

@MainActor
private struct ScreenshotHost {
    let window: UIWindow
    let controller: UIViewController
    let previousKeyWindow: UIWindow?

    func tearDown() {
        window.isHidden = true
        window.rootViewController = nil
        previousKeyWindow?.makeKeyAndVisible()
    }
}

private enum ScreenshotExportError: LocalizedError {
    case missingWindowScene
    case drawFailed(String)
    case emptyImage(String)

    var errorDescription: String? {
        switch self {
        case .missingWindowScene:
            return "No connected UIWindowScene"
        case .drawFailed(let name):
            return "drawHierarchy returned false for \(name)"
        case .emptyImage(let name):
            return "Empty PNG for \(name)"
        }
    }
}

@MainActor
private final class ScreenshotFreeSpaceMonitor: DeviceFreeSpaceMeasuring {
    private let readings: [Int64?]
    private var index = 0

    init(_ readings: [Int64?]) {
        self.readings = readings
    }

    func availableCapacityBytes() -> Int64? {
        let value: Int64?
        if readings.isEmpty {
            value = nil
        } else if index < readings.count {
            value = readings[index]
        } else {
            value = readings[readings.count - 1]
        }
        index += 1
        return value
    }
}

@MainActor
private final class ScreenshotReviewRequester: ReviewRequesting {
    func requestReview() {}
}

@MainActor
private final class ScreenshotPhotosOpener: PhotosAppOpening {
    func openPhotosApp() {}
}
