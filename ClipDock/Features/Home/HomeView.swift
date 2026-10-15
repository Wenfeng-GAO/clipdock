import SwiftUI

struct HomeView: View {
    @StateObject private var viewModel: HomeViewModel
    @State private var isShowingFolderPicker = false
    @State private var isShowingQuickFilter = false
    @State private var isShowingFailures = false
    @State private var isShowingAbout = false
    @State private var isShowingPicker = false
    @State private var isShowingDriveDetails = false
    @State private var showFolderPickerAfterDetails = false

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
                if viewModel.shouldShowMigrationSession {
                    copyVerificationScreen
                } else {
                    dashboard
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationDestination(isPresented: $isShowingPicker) {
                pickerScreen
            }
        }
        .preferredColorScheme(.dark)
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
        .sheet(isPresented: $isShowingDriveDetails) {
            driveDetailsSheet
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(HomePalette.background)
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
        .onChange(of: isShowingDriveDetails) { _, isShowing in
            guard !isShowing, showFolderPickerAfterDetails else { return }
            showFolderPickerAfterDetails = false
            // Let the details sheet finish dismissing before presenting the folder picker.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 350_000_000)
                isShowingFolderPicker = true
            }
        }
        .onAppear {
            viewModel.loadInitialDataIfNeeded()
            viewModel.refreshCapacitySnapshots()
        }
    }

    private var copyVerificationScreen: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground)
                .ignoresSafeArea()

            CopyVerificationSessionView(viewModel: viewModel)
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
    }

    private var dashboard: some View {
        ZStack {
            HomePalette.background
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    wordmark
                    headline
                    storageSection
                    pickButtons
                    driveCard
                    if let summary = viewModel.lastMigrationSummary {
                        lastMigrationCard(summary)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
    }

    private var wordmark: some View {
        HStack(alignment: .center) {
            Text(L10n.tr("ClipDock"))
                .font(.system(size: 13))
                .foregroundStyle(HomePalette.muted)
            Spacer(minLength: 12)
            Button {
                isShowingAbout = true
            } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 15))
                    .foregroundStyle(HomePalette.muted)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.tr("About"))
        }
    }

    private var headline: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(L10n.tr("Videos to free"))
                .font(.system(size: 13))
                .foregroundStyle(HomePalette.muted)

            if viewModel.isScanningVideos && viewModel.videos.isEmpty {
                HStack {
                    ProgressView()
                        .tint(HomePalette.text)
                        .controlSize(.large)
                    Spacer(minLength: 0)
                }
                .frame(height: 52)
                .accessibilityLabel(L10n.tr("Scanning..."))
            } else {
                Text(viewModel.reclaimableSizeText)
                    .font(.system(size: 44, weight: .bold))
                    .tracking(-1)
                    .foregroundStyle(HomePalette.text)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }

            Text(headlineSubline)
                .font(.system(size: 13))
                .foregroundStyle(HomePalette.muted)
                .fixedSize(horizontal: false, vertical: true)

            if viewModel.isFetchingAllVideoSizes && !viewModel.videos.isEmpty {
                Text(L10n.tr("Loading video sizes..."))
                    .font(.system(size: 12))
                    .foregroundStyle(HomePalette.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var headlineSubline: String {
        if viewModel.isScanningVideos && viewModel.videos.isEmpty {
            return L10n.tr("Scanning...")
        }
        return viewModel.librarySublineText
    }

    private var storageSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            StorageBar(fractions: viewModel.storageBarFractions)
                .frame(height: 8)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(viewModel.storageLegendText)

            HStack(spacing: 12) {
                legendItem(color: HomePalette.video, title: L10n.tr("Videos"))
                legendItem(color: HomePalette.other, title: L10n.tr("Other"))
                legendItem(
                    color: HomePalette.available,
                    title: L10n.tr(
                        "Available %@ / %@",
                        viewModel.capacityAvailableText,
                        viewModel.capacityTotalText
                    ),
                    outlined: true
                )
            }
            .font(.system(size: 12))
            .foregroundStyle(HomePalette.muted)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(viewModel.storageLegendText)
        }
    }

    private func legendItem(color: Color, title: String, outlined: Bool = false) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(color)
                .overlay {
                    if outlined {
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .strokeBorder(HomePalette.other, lineWidth: 1)
                    }
                }
                .frame(width: 8, height: 8)
            Text(title)
        }
    }

    private var pickButtons: some View {
        VStack(spacing: 14) {
            Button {
                viewModel.selectLargestVideos(count: HomeLibrarySummary.defaultTopN)
                openPickerIfAllowed()
            } label: {
                Text(L10n.tr("Pick the %d largest videos", HomeLibrarySummary.defaultTopN))
            }
            .buttonStyle(HomeFillButtonStyle(fill: HomePalette.text, foreground: .black))

            Button {
                viewModel.prepareManualPick()
                openPickerIfAllowed()
            } label: {
                Text(L10n.tr("Choose myself"))
            }
            .buttonStyle(HomeFillButtonStyle(fill: HomePalette.secondaryButton, foreground: HomePalette.text))
        }
    }

    private var driveCard: some View {
        HStack(alignment: .center, spacing: 12) {
            Button {
                if viewModel.selectedFolderURL == nil {
                    isShowingFolderPicker = true
                } else {
                    isShowingDriveDetails = true
                }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(viewModel.driveTitleText)
                        .font(.system(size: 15))
                        .foregroundStyle(HomePalette.text)
                        .lineLimit(1)
                    Text(viewModel.driveStatusText)
                        .font(.system(size: 13))
                        .foregroundStyle(driveStatusColor)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                isShowingFolderPicker = true
            } label: {
                Text(L10n.tr("Change ›"))
                    .font(.system(size: 13))
                    .foregroundStyle(HomePalette.muted)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(HomePalette.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// Mirrors the drive card (mock 01). 「历史 ›」 is shown for layout parity but is disabled:
    /// 1.1 has no history screen yet, so it is not a tappable control.
    private func lastMigrationCard(_ summary: LastMigrationSummary) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.tr("Last Migration"))
                    .font(.system(size: 15))
                    .foregroundStyle(HomePalette.text)
                    .lineLimit(1)
                Text(LastMigrationSummaryText.line(for: summary))
                    .font(.system(size: 13))
                    .foregroundStyle(HomePalette.muted)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(L10n.tr("History ›"))
                .font(.system(size: 13))
                .foregroundStyle(HomePalette.muted)
                .accessibilityHidden(true)
        }
        .padding(14)
        .background(HomePalette.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var driveStatusColor: Color {
        if viewModel.selectedFolderURL != nil && !viewModel.isFolderWritable {
            return HomePalette.warning
        }
        return HomePalette.muted
    }

    private var driveDetailsSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(viewModel.driveTitleText)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(HomePalette.text)
                    Text(viewModel.driveStatusText)
                        .font(.system(size: 15))
                        .foregroundStyle(driveStatusColor)

                    if let path = viewModel.driveFolderPath {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(L10n.tr("Selected Folder"))
                                .font(.footnote)
                                .foregroundStyle(HomePalette.muted)
                            Text(path)
                                .font(.footnote)
                                .foregroundStyle(HomePalette.text)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Button {
                        viewModel.rescanFolderAccess()
                    } label: {
                        Text(L10n.tr("Recheck Folder Access"))
                    }
                    .buttonStyle(HomeFillButtonStyle(fill: HomePalette.secondaryButton, foreground: HomePalette.text))
                    .disabled(viewModel.selectedFolderURL == nil)

                    Button {
                        showFolderPickerAfterDetails = true
                        isShowingDriveDetails = false
                    } label: {
                        Text(L10n.tr("Change ›"))
                    }
                    .buttonStyle(HomeFillButtonStyle(fill: HomePalette.text, foreground: .black))
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(HomePalette.background)
            .navigationTitle(L10n.tr("External Storage"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("Done")) {
                        isShowingDriveDetails = false
                    }
                }
            }
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
    }

    private func openPickerIfAllowed() {
        switch viewModel.permissionState {
        case .denied, .restricted:
            return
        case .notDetermined, .authorized, .limited:
            isShowingPicker = true
        }
    }

    @ViewBuilder
    private var pickerScreen: some View {
        if viewModel.shouldShowMigrationSession {
            copyVerificationScreen
        } else {
            pickerList
        }
    }

    private var pickerList: some View {
        ZStack {
            HomePalette.background
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
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
        .navigationTitle(L10n.tr("Select Videos"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(HomePalette.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .safeAreaInset(edge: .bottom) {
            if !viewModel.videos.isEmpty {
                MigrationActionBar(viewModel: viewModel, isShowingFailures: $isShowingFailures)
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

private enum HomePalette {
    static let background = Color(red: 11.0 / 255.0, green: 13.0 / 255.0, blue: 16.0 / 255.0)
    static let card = Color(red: 20.0 / 255.0, green: 24.0 / 255.0, blue: 30.0 / 255.0)
    static let text = Color(red: 242.0 / 255.0, green: 244.0 / 255.0, blue: 247.0 / 255.0)
    static let muted = Color(red: 139.0 / 255.0, green: 147.0 / 255.0, blue: 161.0 / 255.0)
    static let video = Color(red: 242.0 / 255.0, green: 244.0 / 255.0, blue: 247.0 / 255.0)
    static let other = Color(red: 92.0 / 255.0, green: 101.0 / 255.0, blue: 112.0 / 255.0)
    static let available = Color(red: 42.0 / 255.0, green: 47.0 / 255.0, blue: 55.0 / 255.0)
    static let barTrack = Color(red: 28.0 / 255.0, green: 34.0 / 255.0, blue: 43.0 / 255.0)
    static let secondaryButton = Color(red: 28.0 / 255.0, green: 34.0 / 255.0, blue: 43.0 / 255.0)
    static let warning = Color(red: 214.0 / 255.0, green: 69.0 / 255.0, blue: 69.0 / 255.0)
}

private struct HomeFillButtonStyle: ButtonStyle {
    var fill: Color
    var foreground: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}

private struct StorageBar: View {
    let fractions: StorageBarFractions

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                segment(HomePalette.video, width: proxy.size.width * CGFloat(fractions.videos))
                segment(HomePalette.other, width: proxy.size.width * CGFloat(fractions.other))
                segment(HomePalette.available, width: proxy.size.width * CGFloat(fractions.available))
            }
        }
        .background(HomePalette.barTrack)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    private func segment(_ color: Color, width: CGFloat) -> some View {
        Rectangle()
            .fill(color)
            .frame(width: max(CGFloat(0), width))
    }
}

#Preview {
    HomeView()
}
