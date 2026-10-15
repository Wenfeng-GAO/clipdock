import SwiftUI

struct HomeView: View {
    @StateObject private var viewModel: HomeViewModel
    @State private var isShowingFolderPicker = false
    @State private var isShowingFailures = false
    @State private var isShowingAbout = false
    @State private var isShowingPicker = false
    @State private var isShowingDriveDetails = false
    @State private var showFolderPickerAfterDetails = false
    @State private var didRevealInitialPicker = false
    @State private var thumbnailProvider = PhotoKitVideoThumbnailProvider()
    private let showsPickerOnFirstAppear: Bool

    private var appVersionText: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    @MainActor
    init() {
        _viewModel = StateObject(wrappedValue: HomeViewModel.makeForCurrentEnvironment())
        showsPickerOnFirstAppear = false
    }

    init(viewModel: HomeViewModel) {
        self.init(viewModel: viewModel, initiallyShowingPicker: false)
    }

    /// `initiallyShowingPicker` defaults to false via `init(viewModel:)`.
    init(viewModel: HomeViewModel, initiallyShowingPicker: Bool) {
        _viewModel = StateObject(wrappedValue: viewModel)
        _isShowingPicker = State(initialValue: initiallyShowingPicker)
        showsPickerOnFirstAppear = initiallyShowingPicker
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
        .fullScreenCover(
            isPresented: Binding(
                get: { viewModel.deletionResultModel != nil },
                set: { isPresented in
                    if !isPresented {
                        viewModel.dismissDeletionResult()
                    }
                }
            )
        ) {
            if let model = viewModel.deletionResultModel {
                DeletionResultView(model: model) {
                    viewModel.dismissDeletionResult()
                }
            }
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
            // Navigation may ignore a destination that starts presented. Flip once so the picker is on screen.
            guard showsPickerOnFirstAppear, !didRevealInitialPicker else { return }
            didRevealInitialPicker = true
            isShowingPicker = false
            Task { @MainActor in
                isShowingPicker = true
            }
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
            pickerBrowser
        }
    }

    /// One content header (title + sort). The navigation bar stays empty so the title is not repeated.
    private var pickerBrowser: some View {
        ZStack {
            HomePalette.background
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 14) {
                pickerHeader
                pickerChips

                ScrollView {
                    if viewModel.isScanningVideos && viewModel.videos.isEmpty {
                        HStack(spacing: 8) {
                            ProgressView()
                                .tint(HomePalette.text)
                            Text(L10n.tr("Scanning..."))
                                .font(.system(size: 13))
                                .foregroundStyle(HomePalette.muted)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 24)
                        .accessibilityLabel(L10n.tr("Scanning..."))
                    } else {
                        VideoPickerGrid(
                            viewModel: viewModel,
                            videos: viewModel.pickerVisibleVideos(calendar: .current),
                            thumbnailProvider: thumbnailProvider
                        )
                        .padding(.bottom, 8)
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(HomePalette.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            MigrationActionBar(viewModel: viewModel, isShowingFailures: $isShowingFailures)
        }
    }

    private var pickerHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(L10n.tr("Pick Videos"))
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(HomePalette.text)
            Spacer(minLength: 12)
            pickerSortMenu
        }
    }

    private var pickerSortMenu: some View {
        Menu {
            ForEach(VideoSortMode.allCases) { mode in
                Button {
                    viewModel.sortMode = mode
                } label: {
                    if viewModel.sortMode == mode {
                        Label(mode.displayText, systemImage: "checkmark")
                    } else {
                        Text(mode.displayText)
                    }
                }
            }
        } label: {
            Text(verbatim: viewModel.sortMode.pickerMenuLabel)
                .font(.system(size: 13))
                .foregroundStyle(HomePalette.muted)
        }
        .menuOrder(.fixed)
        .accessibilityLabel(L10n.tr("Sort"))
        .accessibilityValue(viewModel.sortMode.displayText)
    }

    private var pickerChips: some View {
        HStack(spacing: 6) {
            ForEach(PickerFilterChip.allCases) { chip in
                pickerChip(chip)
            }
            Spacer(minLength: 0)
        }
    }

    private func pickerChip(_ chip: PickerFilterChip) -> some View {
        let isActive = viewModel.pickerFilter == chip
        return Button {
            viewModel.selectPickerChip(chip)
        } label: {
            Text(verbatim: chip.title)
                .font(.system(size: 12))
                .foregroundStyle(isActive ? Color.black : HomePalette.muted)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    isActive ? HomePalette.text : HomePalette.secondaryButton,
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isActive ? .isSelected : AccessibilityTraits())
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
