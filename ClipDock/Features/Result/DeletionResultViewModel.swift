import Combine
import Foundation

enum ResultScenePhase: Equatable {
    case active
    case inactive
    case background
}

/// Holds the in-flight re-measure so `deinit` can cancel it without touching main-actor state.
private final class RemeasureTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    func store(_ task: Task<Void, Never>) {
        lock.lock()
        let previous = self.task
        self.task = task
        lock.unlock()
        previous?.cancel()
    }

    func cancel() {
        lock.lock()
        let previous = task
        task = nil
        lock.unlock()
        previous?.cancel()
    }
}

/// Result shown after originals move to Recently Deleted.
/// Records free space before opening Photos, then compares again when the scene returns to active.
@MainActor
final class DeletionResultViewModel: ObservableObject {
    /// Second sample after a return. iOS updates free space lazily once Recently Deleted is emptied.
    static let remeasureDelayNanoseconds: UInt64 = 3_000_000_000

    let snapshot: DeletionResultSnapshot

    /// Positive free-space delta since Photos was opened. Nil hides the freed-space line.
    @Published private(set) var freedBytes: Int64?

    private let freeSpaceMonitor: DeviceFreeSpaceMeasuring
    private let reviewRequester: ReviewRequesting
    private let photosOpener: PhotosAppOpening
    private let remeasureDelayNanoseconds: UInt64
    private let sleep: @Sendable (UInt64) async -> Void

    private var baselineFreeBytes: Int64?
    private var isArmed = false
    private var didLeaveForeground = false
    private var didRequestReview = false
    private var remeasureGeneration = 0
    private nonisolated let remeasureTasks = RemeasureTaskBox()

    init(
        snapshot: DeletionResultSnapshot,
        freeSpaceMonitor: DeviceFreeSpaceMeasuring,
        reviewRequester: ReviewRequesting,
        photosOpener: PhotosAppOpening,
        remeasureDelayNanoseconds: UInt64 = DeletionResultViewModel.remeasureDelayNanoseconds,
        sleep: @escaping @Sendable (UInt64) async -> Void = { nanoseconds in
            try? await Task.sleep(nanoseconds: nanoseconds)
        }
    ) {
        self.snapshot = snapshot
        self.freeSpaceMonitor = freeSpaceMonitor
        self.reviewRequester = reviewRequester
        self.photosOpener = photosOpener
        self.remeasureDelayNanoseconds = remeasureDelayNanoseconds
        self.sleep = sleep
    }

    deinit {
        remeasureTasks.cancel()
    }

    static func live(snapshot: DeletionResultSnapshot) -> DeletionResultViewModel {
        DeletionResultViewModel(
            snapshot: snapshot,
            freeSpaceMonitor: DeviceFreeSpaceMonitor(),
            reviewRequester: StoreReviewRequester(),
            photosOpener: PhotosAppOpener()
        )
    }

    var showsFreedSpace: Bool {
        freedBytes != nil
    }

    /// Shown freed space is within ±5% of the bytes moved to Recently Deleted.
    var isFreedWithinTolerance: Bool {
        guard let freedBytes else { return false }
        return FreedSpaceTolerance.withinTolerance(freed: freedBytes, expected: pendingReleaseBytes)
    }

    var pendingReleaseBytes: Int64 {
        snapshot.pendingReleaseBytes
    }

    /// Samples free space, then opens Photos. The sample is the baseline for the return delta.
    func openPhotos() {
        cancelRemeasure()
        baselineFreeBytes = freeSpaceMonitor.availableCapacityBytes()
        isArmed = true
        didLeaveForeground = false
        photosOpener.openPhotosApp()
    }

    /// Measures only after the scene has left the foreground and come back to `.active`.
    /// Each return measures immediately and schedules exactly one follow-up sample.
    func handleScenePhase(_ phase: ResultScenePhase) {
        guard isArmed else { return }
        switch phase {
        case .active:
            guard didLeaveForeground else { return }
            didLeaveForeground = false
            evaluateReturn()
            scheduleRemeasure()
        case .inactive, .background:
            didLeaveForeground = true
            cancelRemeasure()
        }
    }

    /// Drops a scheduled re-measure when the result screen is dismissed.
    func cancelPendingRemeasure() {
        cancelRemeasure()
    }

    private func scheduleRemeasure() {
        remeasureGeneration += 1
        let generation = remeasureGeneration
        let delay = remeasureDelayNanoseconds
        let pause = sleep
        let task = Task { @MainActor [weak self] in
            await pause(delay)
            guard !Task.isCancelled else { return }
            guard let self else { return }
            guard self.remeasureGeneration == generation else { return }
            guard !self.didLeaveForeground else { return }
            self.evaluateReturn()
        }
        remeasureTasks.store(task)
    }

    private func cancelRemeasure() {
        remeasureGeneration += 1
        remeasureTasks.cancel()
    }

    private func evaluateReturn() {
        guard let before = baselineFreeBytes else { return }
        guard let after = freeSpaceMonitor.availableCapacityBytes() else { return }
        guard let freed = FreedSpaceDelta.freedBytes(before: before, after: after) else { return }
        freedBytes = freed
        guard ReviewPromptPolicy.shouldRequestReview(
            withinTolerance: isFreedWithinTolerance,
            alreadyRequested: didRequestReview
        ) else {
            return
        }
        didRequestReview = true
        reviewRequester.requestReview()
    }
}
