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

    var body: some View {
        NavigationStack {
            List {
                permissionsSection
                externalStorageSection
                videoScanSection
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

            if !viewModel.videos.isEmpty {
                ForEach(viewModel.videos.prefix(20)) { video in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(video.creationDate, format: Date.FormatStyle(date: .numeric, time: .shortened))
                            .font(.subheadline)
                        Text("Duration: \(durationFormatter.string(from: video.duration) ?? "--")  Resolution: \(video.resolutionText)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

#Preview {
    HomeView()
}
