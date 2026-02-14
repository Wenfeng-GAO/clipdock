import SwiftUI

struct HomeView: View {
    @StateObject private var viewModel: HomeViewModel
    @State private var isShowingFolderPicker = false
    @State private var isShowingQuickFilter = false
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

    @MainActor
    init() {
        _viewModel = StateObject(wrappedValue: HomeViewModel.makeForCurrentEnvironment())
    }

    init(viewModel: HomeViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(uiColor: .systemGroupedBackground)
                    .ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        externalStorageCard
                        scanAndSelectCard

                        if !viewModel.videos.isEmpty {
                            videosCard
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 20)
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
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
            .sheet(isPresented: $isShowingQuickFilter) {
                QuickFilterView(
                    summaries: viewModel.monthSummaries,
                    isFetchingAllVideoSizes: viewModel.isFetchingAllVideoSizes,
                    knownSizeCount: viewModel.videoSizeBytesByID.count,
                    totalVideoCount: viewModel.videos.count,
                    onCancel: {
                        isShowingQuickFilter = false
                    },
                    onApply: { months, topN in
                        viewModel.applyQuickFilter(months: months, topN: topN)
                        isShowingQuickFilter = false
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
                Button(L10n.tr("OK"), role: .cancel) {}
            } message: {
                Text(verbatim: viewModel.alertMessage ?? "")
            }
            .alert(
                L10n.tr("Delete Originals?"),
                isPresented: $viewModel.isShowingDeleteConfirm
            ) {
                Button(L10n.tr("Delete"), role: .destructive) {
                    viewModel.deleteMigratedOriginals()
                }
                Button(L10n.tr("Cancel"), role: .cancel) {}
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
                    Text(L10n.tr("ClipDock Description"))
                        .font(.callout)
                        .foregroundStyle(.secondary)

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

    private var scanAndSelectCard: some View {
        HomeCard(title: L10n.tr("Scan & Select"), systemImage: "sparkle.magnifyingglass") {
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
                .disabled(viewModel.isScanningVideos)

                VStack(alignment: .trailing, spacing: 6) {
                    HStack(spacing: 10) {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(L10n.tr("Video Count"))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Text("\(viewModel.videos.count)")
                                .font(.system(.title3, design: .rounded).weight(.semibold))
                                .monospacedDigit()
                        }
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(L10n.tr("Selected"))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Text("\(viewModel.selectedVideoIDs.count)")
                                .font(.system(.title3, design: .rounded).weight(.semibold))
                                .monospacedDigit()
                        }
                    }
                }
            }

            if viewModel.isFetchingVideoSizes {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(L10n.tr("Loading video sizes..."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if !viewModel.videos.isEmpty {
                HStack(alignment: .firstTextBaseline) {
                    Text(L10n.tr("Selected Size"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    Text(viewModel.selectedTotalSizeText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                if viewModel.selectedKnownSizeCount < viewModel.selectedVideoIDs.count {
                    Text(
                        verbatim: L10n.tr(
                            "Known sizes: %d/%d",
                            viewModel.selectedKnownSizeCount,
                            viewModel.selectedVideoIDs.count
                        )
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }

                Text(L10n.tr("Tip: tap a row to toggle selection."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)

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
                        isShowingQuickFilter = true
                    } label: {
                        Text(L10n.tr("Quick Filter"))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }

                let canClear = !viewModel.selectedVideoIDs.isEmpty
                Button {
                    viewModel.clearSelection()
                } label: {
                    Text(L10n.tr("Clear"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(canClear ? Color.accentColor : .secondary)
                .disabled(!canClear)
            }
        }
    }

    private var videosCard: some View {
        HomeCard(title: L10n.tr("Video List"), systemImage: "film") {
            let displayed = viewModel.displayedVideos

            HStack(spacing: 10) {
                Picker(L10n.tr("Sort"), selection: Binding(
                    get: { viewModel.sortField },
                    set: { viewModel.setSort(field: $0) }
                )) {
                    ForEach(VideoSortField.allCases) { field in
                        Text(field.displayText).tag(field)
                    }
                }
                .pickerStyle(.segmented)

                Button {
                    viewModel.toggleSortOrder()
                } label: {
                    Image(systemName: viewModel.isSortAscending ? "arrow.up" : "arrow.down")
                        .font(.system(.headline, design: .rounded))
                        .frame(width: 36, height: 32)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color(uiColor: .tertiarySystemGroupedBackground))
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.tr("Sort Order"))
                .accessibilityValue(viewModel.isSortAscending ? L10n.tr("Ascending") : L10n.tr("Descending"))
            }
            .padding(.bottom, 8)

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
