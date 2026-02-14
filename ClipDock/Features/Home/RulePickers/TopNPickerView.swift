import SwiftUI

struct TopNPickerView: View {
    let isFetchingAllVideoSizes: Bool
    let knownSizeCount: Int
    let totalVideoCount: Int
    let onApply: (Int) -> Void
    let onDone: () -> Void

    @State private var nText: String = "20"

    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.tr("Top N")) {
                    TextField("N", text: $nText)
                        .keyboardType(.numberPad)

                    HStack(spacing: 10) {
                        quickButton(20)
                        quickButton(50)
                        quickButton(100)
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
            .navigationTitle(L10n.tr("Select Top N"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("Cancel")) {
                        onDone()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.tr("Apply")) {
                        onApply(parsedN)
                        onDone()
                    }
                    .disabled(parsedN <= 0)
                }
            }
        }
    }

    private var parsedN: Int {
        Int(nText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    private func quickButton(_ v: Int) -> some View {
        Button("\(v)") {
            nText = "\(v)"
        }
        .buttonStyle(.bordered)
    }
}
