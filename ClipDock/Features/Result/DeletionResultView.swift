import SwiftUI

struct DeletionResultView: View {
    @ObservedObject var model: DeletionResultViewModel
    let onClose: () -> Void

    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        checklist
                        pendingCard
                        stepsCard
                        openPhotosButton
                        footnote
                        Spacer(minLength: 12)
                        if let freedBytes = model.freedBytes {
                            freedCard(freedBytes)
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 4)
                    .padding(.bottom, 18)
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .top)
                }
                .scrollBounceBehavior(.basedOnSize)
                .background(ResultPalette.background)
            }
            .background(ResultPalette.background.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.tr("Done"), action: onClose)
                        .tint(ResultPalette.muted)
                }
            }
            .toolbarBackground(ResultPalette.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .preferredColorScheme(.dark)
            .onChange(of: scenePhase) { _, newPhase in
                switch newPhase {
                case .active:
                    model.handleScenePhase(.active)
                case .inactive:
                    model.handleScenePhase(.inactive)
                case .background:
                    model.handleScenePhase(.background)
                @unknown default:
                    break
                }
            }
        }
    }

    private var checklist: some View {
        VStack(alignment: .leading, spacing: 8) {
            checkRow(L10n.tr("Copied to USB · %d", model.snapshot.copiedCount))
            checkRow(L10n.tr(
                "Size verified · %d/%d match",
                model.snapshot.verifiedMatchCount,
                model.snapshot.verifiedTotalCount
            ))
            checkRow(L10n.tr("Originals moved to Recently Deleted"))
        }
    }

    private var pendingCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.tr("Pending Release"))
                .font(.system(size: 13))
                .foregroundStyle(ResultPalette.muted)
            Text(verbatim: ByteCountText.string(fromBytes: model.snapshot.pendingReleaseBytes))
                .font(.system(size: 44, weight: .bold))
                .tracking(-1)
                .foregroundStyle(ResultPalette.text)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(L10n.tr("Space is freed only after emptying Recently Deleted"))
                .font(.system(size: 13))
                .foregroundStyle(ResultPalette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ResultPalette.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var stepsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            stepRow(1, L10n.tr("Open Photos → Albums → Recently Deleted at the bottom"))
            stepRow(2, L10n.tr("Top right Select → Delete All"))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ResultPalette.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var openPhotosButton: some View {
        Button {
            model.openPhotos()
        } label: {
            Text(L10n.tr("Open Photos"))
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(ResultPalette.buttonFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var footnote: some View {
        Text(verbatim: L10n.tr("After emptying, return here to see the space actually freed (±5%)."))
            .font(.system(size: 12))
            .foregroundStyle(ResultPalette.muted)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func freedCard(_ bytes: Int64) -> some View {
        let amount = ByteCountText.string(fromBytes: bytes)
        let title = model.isFreedWithinTolerance
            ? L10n.tr("Back · Freed %@ ✓", amount)
            : L10n.tr("Back · Freed %@", amount)
        return Text(verbatim: title)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(ResultPalette.ok)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(ResultPalette.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(ResultPalette.freedBorder, lineWidth: 1)
            )
    }

    private func checkRow(_ text: String) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(ResultPalette.ok)
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.black)
                    .accessibilityHidden(true)
            }
            .frame(width: 22, height: 22)
            Text(verbatim: text)
                .font(.system(size: 14))
                .foregroundStyle(ResultPalette.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private func stepRow(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(verbatim: "\(number)")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(ResultPalette.muted)
                .frame(width: 20, height: 20)
                .overlay(
                    Circle()
                        .strokeBorder(ResultPalette.stepBorder, lineWidth: 1)
                )
                .accessibilityHidden(true)
            Text(verbatim: text)
                .font(.system(size: 13))
                .foregroundStyle(ResultPalette.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

private enum ResultPalette {
    static let background = Color(red: 11.0 / 255, green: 13.0 / 255, blue: 16.0 / 255)
    static let card = Color(red: 20.0 / 255, green: 24.0 / 255, blue: 30.0 / 255)
    static let muted = Color(red: 139.0 / 255, green: 147.0 / 255, blue: 161.0 / 255)
    static let text = Color(red: 242.0 / 255, green: 244.0 / 255, blue: 247.0 / 255)
    static let ok = Color(red: 52.0 / 255, green: 199.0 / 255, blue: 89.0 / 255)
    static let buttonFill = Color(red: 242.0 / 255, green: 244.0 / 255, blue: 247.0 / 255)
    static let stepBorder = Color(red: 92.0 / 255, green: 101.0 / 255, blue: 112.0 / 255)
    static let freedBorder = Color(red: 31.0 / 255, green: 81.0 / 255, blue: 48.0 / 255)
}

#Preview {
    DeletionResultView(
        model: DeletionResultViewModel.live(
            snapshot: DeletionResultSnapshot(deletedSuccesses: [
                MigrationItemSuccess(assetID: "a", destinationURL: URL(fileURLWithPath: "/tmp/a"), bytes: 3_800_000_000),
                MigrationItemSuccess(assetID: "b", destinationURL: URL(fileURLWithPath: "/tmp/b"), bytes: 3_100_000_000),
                MigrationItemSuccess(assetID: "c", destinationURL: URL(fileURLWithPath: "/tmp/c"), bytes: 2_600_000_000),
                MigrationItemSuccess(assetID: "d", destinationURL: URL(fileURLWithPath: "/tmp/d"), bytes: 2_200_000_000),
                MigrationItemSuccess(assetID: "e", destinationURL: URL(fileURLWithPath: "/tmp/e"), bytes: 1_700_000_000),
            ])
        ),
        onClose: {}
    )
}
