import SwiftUI
import UIKit

struct MigrationActionBar: View {
    @ObservedObject var viewModel: HomeViewModel

    @Binding var isShowingFailures: Bool

    var body: some View {
        let canDelete = viewModel.isDeleteEnabled
        let shouldHoldStartForDelete = canDelete
        let canStart = !viewModel.isMigrating &&
            !viewModel.selectedVideoIDs.isEmpty &&
            viewModel.selectedFolderURL != nil &&
            viewModel.isFolderWritable &&
            !shouldHoldStartForDelete

        let total = viewModel.pickerRunningTotal
        let copyLooksEnabled = canStart || viewModel.isMigrating

        VStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                HStack(spacing: 0) {
                    Text(verbatim: total.countText)
                        .font(.subheadline.weight(.semibold))
                    Text(verbatim: total.sizeSuffixText)
                        .font(.subheadline)
                }
                .foregroundStyle(PickerBarPalette.ink)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text(verbatim: total.displayText))

                Spacer(minLength: 8)

                if let driveFree = viewModel.pickerDriveFreeText {
                    Text(verbatim: driveFree)
                        .font(.subheadline)
                        .foregroundStyle(PickerBarPalette.muted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .multilineTextAlignment(.trailing)
                }
            }
            .monospacedDigit()

            if let progress = viewModel.migrationProgress, viewModel.isMigrating {
                VStack(alignment: .leading, spacing: 6) {
                    if progress.isIndeterminate {
                        ProgressView()
                    } else {
                        ProgressView(value: progress.fraction)
                    }

                    HStack {
                        Text(L10n.tr("Progress"))
                        Spacer()
                        Text("\(progress.completed)/\(progress.total)")
                            .foregroundStyle(.secondary)
                    }
                    .font(.footnote)

                    if let name = progress.currentFilename {
                        Text(name)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            } else if viewModel.copyEligibility.isVerificationComplete && viewModel.copyEligibility.mismatchCount > 0 {
                Text(verbatim: viewModel.mismatchRetentionNote)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let result = viewModel.lastMigrationResult {
                HStack(spacing: 12) {
                    Text(verbatim: "\(L10n.tr("Succeeded")): \(result.successCount)")
                    Text(verbatim: "\(L10n.tr("Failed")): \(result.failureCount)")
                        .foregroundStyle(result.failureCount > 0 ? .secondary : .secondary)
                    Spacer()

                    if result.failureCount > 0 {
                        Button(L10n.tr("View Failures")) {
                            isShowingFailures = true
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .font(.footnote)
            }

            Button {
                viewModel.startMigration()
            } label: {
                Group {
                    if viewModel.isMigrating {
                        HStack(spacing: 8) {
                            ProgressView()
                                .tint(.black)
                            Text(L10n.tr("Migrating..."))
                        }
                    } else {
                        Text(L10n.tr("Copy to Drive"))
                    }
                }
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(copyLooksEnabled ? Color.black : PickerBarPalette.disabledText)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(copyLooksEnabled ? PickerBarPalette.enabledFill : PickerBarPalette.disabledFill)
                )
            }
            .buttonStyle(.plain)
            .disabled(!canStart)

            if canDelete || viewModel.isDeleting {
                Button {
                    viewModel.promptDeleteMigratedOriginals()
                } label: {
                    if viewModel.isDeleting {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text(L10n.tr("Deleting..."))
                        }
                        .frame(maxWidth: .infinity)
                    } else {
                        Text(viewModel.deleteOriginalsButtonTitle)
                            .lineLimit(3)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.bordered)
                .tint(canDelete ? .red : .secondary)
                .disabled(!canDelete)
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity)
        .background {
            PickerBarPalette.tray
                .ignoresSafeArea(edges: .bottom)
        }
        .overlay(alignment: .top) {
            Rectangle()
                .fill(PickerBarPalette.separator)
                .frame(height: 1)
        }
        .accessibilityElement(children: .contain)
    }
}

private enum PickerBarPalette {
    static let enabledFill = Color(red: 242 / 255, green: 244 / 255, blue: 247 / 255)
    static let disabledFill = Color(red: 42 / 255, green: 47 / 255, blue: 55 / 255)
    static let disabledText = Color(red: 92 / 255, green: 101 / 255, blue: 112 / 255)
    static let ink = Color(red: 242 / 255, green: 244 / 255, blue: 247 / 255)
    static let muted = Color(red: 139 / 255, green: 147 / 255, blue: 161 / 255)
    static let tray = Color(red: 20 / 255, green: 24 / 255, blue: 30 / 255)
    static let separator = Color(red: 42 / 255, green: 47 / 255, blue: 55 / 255)
}

struct MigrationFailuresView: View {
    let failures: [MigrationItemFailure]
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            List {
                if failures.isEmpty {
                    Text(L10n.tr("No failures."))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(failures, id: \.self) { f in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(f.assetID)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Text(f.message)
                                .font(.callout)
                            Button(L10n.tr("Copy Error")) {
                                UIPasteboard.general.string = "\(f.assetID)\n\(f.message)"
                            }
                            .font(.footnote)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle(L10n.tr("Failures"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("Done")) { onDone() }
                }
            }
        }
    }
}
