import SwiftUI
import UIKit

struct HomeView: View {
    @StateObject private var viewModel = HomeViewModel()
    @State private var isShowingFolderPicker = false
    @State private var isShowingMonthPicker = false
    @State private var isShowingTopNPicker = false

    private let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.zeroFormattingBehavior = [.pad]
        return formatter
    }()

    private var appVersionText: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    var body: some View {
        NavigationStack {
            List {
                aboutSection
                permissionsSection
                externalStorageSection
                videoScanSection

                if !viewModel.videos.isEmpty {
                    selectionSection
                    migrationSection
                    postMigrationSection
                    videoListSection
                }
            }
            .navigationTitle("ClipDock")
            .sheet(isPresented: $isShowingFolderPicker) {
                FolderPickerView {
                    viewModel.setSelectedFolder($0)
                    isShowingFolderPicker = false
                } onCancel: {
                    isShowingFolderPicker = false
                }
            }
            .sheet(isPresented: $isShowingMonthPicker) {
                MonthPickerView(
                    summaries: viewModel.monthSummaries,
                    onApply: { keys in
                        viewModel.applyMonthSelection(keys)
                    },
                    onDone: {
                        isShowingMonthPicker = false
                    }
                )
            }
            .sheet(isPresented: $isShowingTopNPicker) {
                TopNPickerView(
                    isFetchingAllVideoSizes: viewModel.isFetchingAllVideoSizes,
                    knownSizeCount: viewModel.videoSizeBytesByID.count,
                    totalVideoCount: viewModel.videos.count,
                    onApply: { n in
                        viewModel.applyTopNSelection(n)
                    },
                    onDone: {
                        isShowingTopNPicker = false
                    }
                )
            }
            .alert(
                L10n.tr("Notice"),
                isPresented: Binding(
                    get: { viewModel.alertMessage != nil },
                    set: { newValue in
                        if !newValue {
                            viewModel.alertMessage = nil
                        }
                    }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(verbatim: viewModel.alertMessage ?? "")
            }
            .alert(
                L10n.tr("Delete Originals?"),
                isPresented: $viewModel.isShowingDeleteConfirm
            ) {
                Button("Delete", role: .destructive) {
                    viewModel.deleteMigratedOriginals()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(
                    verbatim: L10n.tr(
                        "This will delete %d video(s) from Photos after they were exported to external storage.",
                        viewModel.deletableSuccessCount
                    )
                )
            }
            .onAppear {
                viewModel.loadInitialDataIfNeeded()
            }
        }
    }

    private var aboutSection: some View {
        Section(L10n.tr("About")) {
            LabeledContent(L10n.tr("App Version"), value: appVersionText)

            Link(
                L10n.tr("Privacy Policy"),
                destination: URL(string: "https://wenfeng-gao.github.io/clipdock/app-store/privacy-policy.html")!
            )
            Link(
                L10n.tr("Support"),
                destination: URL(string: "https://wenfeng-gao.github.io/clipdock/app-store/support.html")!
            )
        }
    }

    private var permissionsSection: some View {
        Section("Photos Permission") {
            LabeledContent("Status", value: viewModel.permissionState.displayText)
            Button("Grant Access") {
                viewModel.requestPhotoAccess()
            }
            .disabled(viewModel.permissionState.canReadLibrary)
        }
    }

    private var externalStorageSection: some View {
        Section("External Storage") {
            LabeledContent("Selected Folder") {
                if let selectedFolderURL = viewModel.selectedFolderURL {
                    Text(selectedFolderURL.path)
                        .font(.footnote)
                        .multilineTextAlignment(.trailing)
                } else {
                    Text("Not Selected")
                        .foregroundStyle(.secondary)
                }
            }

            LabeledContent("Writable") {
                Text(verbatim: viewModel.isFolderWritable ? L10n.tr("Yes") : L10n.tr("No"))
            }

            Button("Choose External Folder") {
                isShowingFolderPicker = true
            }

            Button("Recheck Folder Access") {
                viewModel.rescanFolderAccess()
            }
            .disabled(viewModel.selectedFolderURL == nil)
        }
    }

    private var videoScanSection: some View {
        Section("Video Scan") {
            Button {
                viewModel.scanVideos()
            } label: {
                if viewModel.isScanningVideos {
                    HStack {
                        ProgressView()
                        Text("Scanning...")
                    }
                } else {
                    Text("Scan Videos")
                }
            }
            .disabled(viewModel.isScanningVideos || !viewModel.permissionState.canReadLibrary)

            LabeledContent("Video Count", value: "\(viewModel.videos.count)")

            Picker("Sort", selection: $viewModel.sortMode) {
                ForEach(VideoSortMode.allCases) { mode in
                    Text(mode.displayText).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .disabled(viewModel.videos.isEmpty)

            if viewModel.isFetchingVideoSizes {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Loading video sizes...")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var selectionSection: some View {
        Section("Select Videos") {
            HStack {
                Text("Selected")
                Spacer()
                Text("\(viewModel.selectedVideoIDs.count)")
                    .foregroundStyle(.secondary)
            }

            Text("Tip: tap a row to toggle selection.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button("By Month...") {
                    isShowingMonthPicker = true
                }
                .buttonStyle(.bordered)

                Button("Top N...") {
                    isShowingTopNPicker = true
                }
                .buttonStyle(.bordered)
            }

            Toggle("Show Selected Only", isOn: $viewModel.showSelectedOnly)

            HStack(spacing: 12) {
                Button("Select All") {
                    viewModel.selectAllScannedVideos()
                }
                .buttonStyle(.bordered)

                Button("Clear") {
                    viewModel.clearSelection()
                }
                .buttonStyle(.bordered)
                .tint(.secondary)
                .disabled(viewModel.selectedVideoIDs.isEmpty)
            }
        }
    }

    private var videoListSection: some View {
        Section("Video List") {
            // Render a capped list for now to avoid heavy UI work on very large libraries.
            // We'll add paging/filtering next.
            let displayed = viewModel.displayedVideos
            ForEach(displayed) { video in
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(video.creationDate, format: Date.FormatStyle(date: .numeric, time: .shortened))
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                        Text(
                            verbatim: "\(L10n.tr("Duration")): \(durationFormatter.string(from: video.duration) ?? "--")  \(L10n.tr("Resolution")): \(video.resolutionText)"
                        )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(verbatim: "\(L10n.tr("Size")): \(viewModel.formattedSizeText(for: video.id))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if viewModel.selectedVideoIDs.contains(video.id) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.tint)
                    } else {
                        Image(systemName: "circle")
                            .foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    viewModel.toggleSelection(for: video.id)
                }
                .task {
                    viewModel.ensureSizeLoaded(for: video.id)
                }
            }

            if viewModel.hasMoreVideosToShow {
                Button("Load More") {
                    viewModel.loadMoreVideos()
                }
                .buttonStyle(.bordered)

                Text(
                    verbatim: L10n.tr(
                        "Showing %d items.",
                        displayed.count
                    )
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var migrationSection: some View {
        Section("Migration (Copy to External Folder)") {
            LabeledContent("Selected Videos", value: "\(viewModel.selectedVideoIDs.count)")

            Button {
                viewModel.startMigration()
            } label: {
                if viewModel.isMigrating {
                    HStack {
                        ProgressView()
                        Text("Migrating...")
                    }
                } else {
                    Text("Start Migration")
                }
            }
            .disabled(
                viewModel.isMigrating ||
                viewModel.selectedVideoIDs.isEmpty ||
                viewModel.selectedFolderURL == nil ||
                !viewModel.isFolderWritable
            )

            if let progress = viewModel.migrationProgress {
                if progress.isIndeterminate {
                    ProgressView()
                } else {
                    ProgressView(value: progress.fraction)
                }

                HStack {
                    Text("Progress")
                    Spacer()
                    Text("\(progress.completed)/\(progress.total)")
                        .foregroundStyle(.secondary)
                }

                if let name = progress.currentFilename {
                    Text(name)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Text("Note: this version copies selected videos to the external folder. Use Post-Migration to delete originals.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var postMigrationSection: some View {
        Section("Post-Migration") {
            if let result = viewModel.lastMigrationResult {
                LabeledContent("Succeeded", value: "\(result.successCount)")
                LabeledContent("Failed", value: "\(result.failureCount)")

                if result.failureCount > 0 {
                    DisclosureGroup("Failures") {
                        let maxItems = min(result.failures.count, 20)
                        ForEach(result.failures.prefix(maxItems), id: \.self) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.assetID)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Text(item.message)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(6)
                                Button("Copy Error") {
                                    UIPasteboard.general.string = "\(item.assetID)\n\(item.message)"
                                    viewModel.alertMessage = L10n.tr("Copied.")
                                }
                                .font(.caption)
                            }
                        }

                        if result.failures.count > maxItems {
                            Text(verbatim: L10n.tr("Showing first %d failures. See History for full details.", maxItems))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text("Only succeeded items can be deleted.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

            } else {
                Text("Run a migration to see results here.")
                    .foregroundStyle(.secondary)
            }

            Button {
                viewModel.promptDeleteMigratedOriginals()
            } label: {
                if viewModel.isDeleting {
                    HStack {
                        ProgressView()
                        Text("Deleting...")
                    }
                } else {
                    Text("Delete Migrated Originals")
                }
            }
            .disabled(viewModel.deletableSuccessCount == 0 || viewModel.isDeleting || viewModel.isMigrating)

            Text("Only deletes videos that passed export + validation in the last run.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    HomeView()
}
