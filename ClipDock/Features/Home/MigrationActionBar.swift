import SwiftUI
import UIKit

struct MigrationActionBar: View {
    @ObservedObject var viewModel: HomeViewModel

    @Binding var isShowingFailures: Bool

    var body: some View {
        VStack(spacing: 10) {
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

            HStack(spacing: 12) {
                Button {
                    viewModel.startMigration()
                } label: {
                    if viewModel.isMigrating {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text(L10n.tr("Migrating..."))
                        }
                    } else {
                        Text(L10n.tr("Start Migration"))
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    viewModel.isMigrating ||
                    viewModel.selectedVideoIDs.isEmpty ||
                    viewModel.selectedFolderURL == nil ||
                    !viewModel.isFolderWritable
                )

                Button {
                    viewModel.promptDeleteMigratedOriginals()
                } label: {
                    if viewModel.isDeleting {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text(L10n.tr("Deleting..."))
                        }
                    } else {
                        Label(L10n.tr("Delete Originals"), systemImage: "trash")
                    }
                }
                .buttonStyle(.bordered)
                .tint(.secondary)
                .disabled(viewModel.deletableSuccessCount == 0 || viewModel.isDeleting || viewModel.isMigrating)
            }
        }
        .padding(12)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .accessibilityElement(children: .contain)
    }
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
