import SwiftUI

struct HomeView: View {
    @StateObject private var viewModel = HomeViewModel()
    @State private var isShowingFolderPicker = false

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
            .alert(
                "Notice",
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
                Text(viewModel.alertMessage ?? "")
            }
            .onAppear {
                viewModel.loadInitialDataIfNeeded()
            }
        }
    }

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("App Version", value: appVersionText)
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

            LabeledContent("Writable", value: viewModel.isFolderWritable ? "Yes" : "No")

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
        Section("Video Scan (Date Desc)") {
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
            let cap = min(viewModel.videos.count, 200)
            ForEach(viewModel.videos.prefix(cap)) { video in
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(video.creationDate, format: Date.FormatStyle(date: .numeric, time: .shortened))
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                        Text("Duration: \(durationFormatter.string(from: video.duration) ?? "--")  Resolution: \(video.resolutionText)")
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
            }

            if viewModel.videos.count > cap {
                Text("Showing first \(cap) items. (Paging/filter will be added next.)")
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

            Text("Note: this version copies selected videos to the external folder. Deleting originals will be added next.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    HomeView()
}
