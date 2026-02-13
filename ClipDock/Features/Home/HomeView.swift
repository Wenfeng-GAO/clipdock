import SwiftUI

struct HomeView: View {
    @StateObject private var viewModel = HomeViewModel()
    @State private var isShowingFolderPicker = false
    @State private var isShowingMonthPicker = false
    @State private var isShowingTopNPicker = false
    @State private var isShowingFailures = false
    @State private var isShowingAbout = false

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
            ZStack {
                Color(uiColor: .systemGroupedBackground)
                    .ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        permissionsCard
                        externalStorageCard
                        scanCard

                        if !viewModel.videos.isEmpty {
                            selectionCard
                            videosCard
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 20)
                }
            }
            .navigationTitle("ClipDock")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isShowingAbout = true
                    } label: {
                        Image(systemName: "info.circle")
                    }
                    .accessibilityLabel(L10n.tr("About"))
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !viewModel.videos.isEmpty {
                    MigrationActionBar(viewModel: viewModel, isShowingFailures: $isShowingFailures)
                }
            }
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
            .sheet(isPresented: $isShowingFailures) {
                MigrationFailuresView(failures: viewModel.lastMigrationResult?.failures ?? []) {
                    isShowingFailures = false
                }
            }
            .sheet(isPresented: $isShowingAbout) {
                aboutSheet
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

    private var aboutSheet: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent(L10n.tr("App Version"), value: appVersionText)
                }
                Section {
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
            .navigationTitle(L10n.tr("About"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("Done")) {
                        isShowingAbout = false
                    }
                }
            }
        }
    }

    private var permissionsCard: some View {
        HomeCard(title: L10n.tr("Photos Permission"), systemImage: "photo.on.rectangle") {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.tr("Status"))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Text(viewModel.permissionState.displayText)
                    .font(.callout)
                    .foregroundStyle(viewModel.permissionState.canReadLibrary ? .primary : .secondary)
            }

            Button {
                viewModel.requestPhotoAccess()
            } label: {
                Text(L10n.tr("Grant Access"))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.permissionState.canReadLibrary)
        }
    }

    private var externalStorageCard: some View {
        HomeCard(title: L10n.tr("External Storage"), systemImage: "externaldrive") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    Text(L10n.tr("Selected Folder"))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    if let url = viewModel.selectedFolderURL {
                        Text(url.path)
                            .font(.footnote)
                            .multilineTextAlignment(.trailing)
                            .lineLimit(3)
                            .textSelection(.enabled)
                    } else {
                        Text(L10n.tr("Not Selected"))
                            .foregroundStyle(.secondary)
                    }
                }

                HStack {
                    Text(L10n.tr("Writable"))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    Text(verbatim: viewModel.isFolderWritable ? L10n.tr("Yes") : L10n.tr("No"))
                        .foregroundStyle(viewModel.isFolderWritable ? .primary : .secondary)
                }
            }

            HStack(spacing: 12) {
                Button {
                    isShowingFolderPicker = true
                } label: {
                    Text(L10n.tr("Choose External Folder"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    viewModel.rescanFolderAccess()
                } label: {
                    Text(L10n.tr("Recheck Folder Access"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.secondary)
                .disabled(viewModel.selectedFolderURL == nil)
            }
        }
    }

    private var scanCard: some View {
        HomeCard(title: L10n.tr("Video Scan"), systemImage: "magnifyingglass") {
            HStack(spacing: 12) {
                Button {
                    viewModel.scanVideos()
                } label: {
                    if viewModel.isScanningVideos {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text(L10n.tr("Scanning..."))
                        }
                        .frame(maxWidth: .infinity)
                    } else {
                        Text(L10n.tr("Scan Videos"))
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isScanningVideos || !viewModel.permissionState.canReadLibrary)

                VStack(alignment: .trailing, spacing: 4) {
                    Text(L10n.tr("Video Count"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("\(viewModel.videos.count)")
                        .font(.system(.title3, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                }
            }

            Picker(L10n.tr("Sort"), selection: $viewModel.sortMode) {
                ForEach(VideoSortMode.allCases) { mode in
                    Text(mode.displayText).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .disabled(viewModel.videos.isEmpty)

            if viewModel.isFetchingVideoSizes {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(L10n.tr("Loading video sizes..."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var selectionCard: some View {
        HomeCard(title: L10n.tr("Select Videos"), systemImage: "checkmark.circle") {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.tr("Selected"))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Text("\(viewModel.selectedVideoIDs.count)")
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .foregroundStyle(.primary)
                    .monospacedDigit()
            }

            Text(L10n.tr("Tip: tap a row to toggle selection."))
                .font(.footnote)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button {
                    isShowingMonthPicker = true
                } label: {
                    Label(L10n.tr("By Month..."), systemImage: "calendar")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    isShowingTopNPicker = true
                } label: {
                    Label(L10n.tr("Top N..."), systemImage: "arrow.up.right.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }

            Toggle(L10n.tr("Show Selected Only"), isOn: $viewModel.showSelectedOnly)

            HStack(spacing: 12) {
                Button {
                    viewModel.selectAllScannedVideos()
                } label: {
                    Text(L10n.tr("Select All"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    viewModel.clearSelection()
                } label: {
                    Text(L10n.tr("Clear"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.secondary)
                .disabled(viewModel.selectedVideoIDs.isEmpty)
            }
        }
    }

    private var videosCard: some View {
        HomeCard(title: L10n.tr("Video List"), systemImage: "film") {
            let displayed = viewModel.displayedVideos

            LazyVStack(spacing: 0) {
                ForEach(displayed) { video in
                    Button {
                        viewModel.toggleSelection(for: video.id)
                    } label: {
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

                            Spacer(minLength: 8)

                            Image(systemName: viewModel.selectedVideoIDs.contains(video.id) ? "checkmark.circle.fill" : "circle")
                                .font(.system(.title3, design: .rounded))
                                .foregroundStyle(viewModel.selectedVideoIDs.contains(video.id) ? Color.accentColor : Color(uiColor: .tertiaryLabel))
                        }
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .task {
                        viewModel.ensureSizeLoaded(for: video.id)
                    }

                    if video.id != displayed.last?.id {
                        Divider()
                            .opacity(0.65)
                    }
                }
            }

            if viewModel.hasMoreVideosToShow {
                VStack(alignment: .leading, spacing: 10) {
                    Button {
                        viewModel.loadMoreVideos()
                    } label: {
                        Text(L10n.tr("Load More"))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Text(verbatim: L10n.tr("Showing %d items.", displayed.count))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 10)
            }
        }
    }
}

#Preview {
    HomeView()
}
