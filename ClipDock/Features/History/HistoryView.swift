import SwiftUI

struct HistoryView: View {
    let records: [MigrationHistoryRecord]

    var body: some View {
        List {
            if records.isEmpty {
                Text("No history yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(records) { r in
                    NavigationLink {
                        HistoryDetailView(record: r)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(r.finishedAt, format: Date.FormatStyle(date: .numeric, time: .shortened))
                                .font(.headline)
                            Text(verbatim: "\(L10n.tr("Target")): \(r.targetFolderPath)")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Text(verbatim: "\(L10n.tr("Succeeded")): \(r.successes)  \(L10n.tr("Failed")): \(r.failures)")
                                .font(.subheadline)
                        }
                    }
                }
            }
        }
        .navigationTitle("History")
    }
}

private struct HistoryDetailView: View {
    let record: MigrationHistoryRecord

    var body: some View {
        List {
            Section("Summary") {
                LabeledContent("Finished", value: record.finishedAt.formatted(date: .numeric, time: .shortened))
                LabeledContent("Target", value: record.targetFolderPath)
                LabeledContent("Succeeded", value: "\(record.successes)")
                LabeledContent("Failed", value: "\(record.failures)")
            }

            Section("Items") {
                ForEach(record.items, id: \.self) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.assetID)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text(verbatim: item.status == .success ? L10n.tr("Succeeded") : L10n.tr("Failed"))
                            .font(.caption)
                            .foregroundStyle(item.status == .success ? .green : .red)
                        if let path = item.destinationRelativePath {
                            Text(path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        if let msg = item.errorMessage {
                            Text(msg)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(4)
                        }
                    }
                }
            }
        }
        .navigationTitle("Run Details")
    }
}
