import SwiftUI

/// Copy progress and size-check result (mock screens 04a / 04b / 04c).
struct CopyVerificationSessionView: View {
    @ObservedObject var viewModel: HomeViewModel

    private let bannerColor = Color(red: 212.0 / 255.0, green: 160.0 / 255.0, blue: 23.0 / 255.0)
    private let mismatchColor = Color(red: 214.0 / 255.0, green: 69.0 / 255.0, blue: 69.0 / 255.0)

    var body: some View {
        let stats = viewModel.sessionStats
        let eligibility = stats.eligibility

        VStack(alignment: .leading, spacing: 14) {
            Text(viewModel.isMigrating || !eligibility.isVerificationComplete
                 ? L10n.tr("Copying to USB drive")
                 : L10n.tr("Copied to USB drive"))
                .font(.headline)

            Text("\(stats.numerator) / \(stats.totalCount)")
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.6)
                .lineLimit(1)

            subtitle(stats: stats, eligibility: eligibility)

            CopyRatioBar(
                isMigrating: viewModel.isMigrating,
                inProgressFraction: stats.inProgressFraction,
                verifiedFraction: stats.verifiedFraction,
                mismatchFraction: stats.mismatchFraction
            )

            if viewModel.isMigrating {
                Text(L10n.tr("Keep ClipDock in the foreground; locking or switching apps pauses the copy"))
                    .font(.subheadline)
                    .foregroundStyle(bannerColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(bannerColor.opacity(0.16))
                    )
                    .accessibilityAddTraits(.isStaticText)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(viewModel.copyItems) { item in
                        fileRow(item)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color(uiColor: .secondarySystemGroupedBackground))
                )
            }

            footnote(eligibility)
            actions(eligibility)
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private func subtitle(stats: CopySessionStats, eligibility: CopyDeletionEligibility) -> some View {
        if viewModel.isMigrating {
            if stats.totalBytes > 0 {
                Text(verbatim: "\(ByteCountText.string(fromBytes: stats.copiedBytes)) / \(ByteCountText.string(fromBytes: stats.totalBytes))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        } else if eligibility.mismatchCount > 0 {
            Text(verbatim: L10n.tr("%d size mismatch(es) were not deleted", eligibility.mismatchCount))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(mismatchColor)
        } else if eligibility.isVerificationComplete && eligibility.verifiedCount > 0 {
            Text(eligibility.verifiedCount == stats.totalCount
                 ? L10n.tr("Size verified · All match")
                 : L10n.tr("Size verified"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.green)
        }
    }

    @ViewBuilder
    private func footnote(_ eligibility: CopyDeletionEligibility) -> some View {
        if !viewModel.isMigrating && eligibility.isVerificationComplete {
            if eligibility.mismatchCount > 0 {
                Text(verbatim: viewModel.mismatchRetentionNote)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if eligibility.verifiedCount > 0 {
                Text(L10n.tr("After deletion, originals go to Recently Deleted and can be restored for 30 days."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func actions(_ eligibility: CopyDeletionEligibility) -> some View {
        VStack(spacing: 10) {
            Button {
                viewModel.promptDeleteMigratedOriginals()
            } label: {
                Group {
                    if viewModel.isDeleting {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text(L10n.tr("Deleting..."))
                        }
                    } else {
                        Text(viewModel.deleteOriginalsButtonTitle)
                            .multilineTextAlignment(.center)
                    }
                }
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!viewModel.isDeleteEnabled)

            if viewModel.isMigrating {
                secondaryButton(title: L10n.tr("Stop")) {
                    viewModel.stopMigration()
                }
            } else if eligibility.mismatchCount > 0 {
                secondaryButton(title: L10n.tr("Re-copy %d mismatched", eligibility.mismatchCount)) {
                    viewModel.recopyMismatchedFiles()
                }
            } else {
                secondaryButton(title: L10n.tr("Don't Delete Yet")) {
                    viewModel.postponeOriginalDeletion()
                }
            }
        }
    }

    private func secondaryButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }

    private func fileRow(_ item: CopyItemState) -> some View {
        HStack(alignment: .center, spacing: 10) {
            StatusDot(status: item.status, mismatchColor: mismatchColor)

            HStack(spacing: 4) {
                Text(item.displayName)
                    .lineLimit(1)
                if item.displayBytes > 0 {
                    Text(verbatim: "·")
                        .foregroundStyle(.secondary)
                    Text(ByteCountText.string(fromBytes: item.displayBytes))
                        .monospacedDigit()
                        .layoutPriority(1)
                }
            }
            .font(.subheadline)

            Spacer(minLength: 8)

            trailingLabel(for: item)
        }
    }

    @ViewBuilder
    private func trailingLabel(for item: CopyItemState) -> some View {
        switch item.status {
        case .verified:
            if viewModel.isMigrating {
                Text(L10n.tr("Size verified"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .copying:
            Text(L10n.tr("Copying"))
                .font(.caption)
                .foregroundStyle(.secondary)
        case .mismatch:
            if !viewModel.isMigrating {
                Button(L10n.tr("Re-copy")) {
                    viewModel.recopyMismatchedFiles(assetIDs: [item.assetID])
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(mismatchColor)
                .buttonStyle(.plain)
            }
        case .failed(let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(mismatchColor)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
        case .pending:
            EmptyView()
        }
    }
}

private struct StatusDot: View {
    let status: CopyFileStatus
    let mismatchColor: Color

    var body: some View {
        ZStack {
            Circle().fill(fill)
            if let systemName {
                Image(systemName: systemName)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(iconColor)
            } else if isCopying {
                Text(verbatim: "…")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 22, height: 22)
        .overlay {
            if isPending {
                Circle().strokeBorder(Color.secondary.opacity(0.45), lineWidth: 1)
            }
        }
    }

    private var isPending: Bool {
        if case .pending = status { return true }
        return false
    }

    private var isCopying: Bool {
        if case .copying = status { return true }
        return false
    }

    private var systemName: String? {
        switch status {
        case .verified:
            return "checkmark"
        case .mismatch:
            return "exclamationmark"
        case .failed:
            return "xmark"
        case .pending, .copying:
            return nil
        }
    }

    private var fill: Color {
        switch status {
        case .verified:
            return .green
        case .mismatch, .failed:
            return mismatchColor
        case .pending, .copying:
            return Color.primary.opacity(0.08)
        }
    }

    private var iconColor: Color {
        switch status {
        case .verified:
            return .black
        case .mismatch, .failed:
            return .white
        case .pending, .copying:
            return .secondary
        }
    }
}

private struct CopyRatioBar: View {
    let isMigrating: Bool
    let inProgressFraction: Double
    let verifiedFraction: Double
    let mismatchFraction: Double

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            HStack(spacing: 0) {
                if isMigrating {
                    Rectangle()
                        .fill(Color.primary)
                        .frame(width: width * inProgressFraction)
                } else {
                    Rectangle()
                        .fill(Color.green)
                        .frame(width: width * verifiedFraction)
                    Rectangle()
                        .fill(Color.red)
                        .frame(width: width * mismatchFraction)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: 8)
        .background(Color.primary.opacity(0.12))
        .clipShape(Capsule())
    }
}
