import SwiftUI

struct QuickFilterView: View {
    let summaries: [MonthSummary]
    let isFetchingAllVideoSizes: Bool
    let knownSizeCount: Int
    let totalVideoCount: Int
    let onCancel: () -> Void
    let onApply: (Set<MonthKey>, Int) -> Void

    @State private var selectedMonths: Set<MonthKey> = []
    @State private var nText: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.tr("By Month")) {
                    if summaries.isEmpty {
                        Text(L10n.tr("Scan Videos"))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(summaries) { s in
                            Button {
                                toggleMonth(s.key)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(s.key.displayText)
                                        Text(verbatim: "\(s.count)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if selectedMonths.contains(s.key) {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.tint)
                                    }
                                }
                            }
                        }
                    }
                }

                Section(L10n.tr("Top N")) {
                    TextField("N", text: $nText)
                        .keyboardType(.numberPad)

                    HStack(spacing: 10) {
                        quickButton(20)
                        quickButton(50)
                        quickButton(100)
                        Button(L10n.tr("Clear")) { nText = "" }
                            .buttonStyle(.bordered)
                            .tint(.secondary)
                    }

                    if isFetchingAllVideoSizes {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text(L10n.tr("Loading video sizes..."))
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text(
                            verbatim: L10n.tr(
                                "Known sizes: %d/%d",
                                knownSizeCount,
                                totalVideoCount
                            )
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }

                    Text(L10n.tr("Tip: Top-N selects the largest locally-sized videos. iCloud-only videos may be skipped."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(L10n.tr("Quick Filter"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("Cancel")) { onCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.tr("Apply")) {
                        onApply(selectedMonths, parsedN)
                    }
                    .disabled(!hasFilter)
                }
            }
        }
    }

    private var parsedN: Int {
        Int(nText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    private var hasFilter: Bool {
        !selectedMonths.isEmpty || parsedN > 0
    }

    private func toggleMonth(_ key: MonthKey) {
        if selectedMonths.contains(key) {
            selectedMonths.remove(key)
        } else {
            selectedMonths.insert(key)
        }
    }

    private func quickButton(_ v: Int) -> some View {
        Button("\(v)") { nText = "\(v)" }
            .buttonStyle(.bordered)
    }
}

