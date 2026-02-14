import SwiftUI

struct MonthPickerView: View {
    let summaries: [MonthSummary]
    let initialSelection: Set<MonthKey>
    let onApply: (Set<MonthKey>) -> Void
    let onDone: () -> Void

    @State private var selection: Set<MonthKey>

    init(
        summaries: [MonthSummary],
        initialSelection: Set<MonthKey> = [],
        onApply: @escaping (Set<MonthKey>) -> Void,
        onDone: @escaping () -> Void
    ) {
        self.summaries = summaries
        self.initialSelection = initialSelection
        self.onApply = onApply
        self.onDone = onDone
        _selection = State(initialValue: initialSelection)
    }

    var body: some View {
        NavigationStack {
            List {
                if summaries.isEmpty {
                    Text(L10n.tr("Scan Videos"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(summaries) { s in
                        Button {
                            toggle(s.key)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(s.key.displayText)
                                    Text(verbatim: "\(s.count)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if selection.contains(s.key) {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(L10n.tr("Select by Month"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("Cancel")) {
                        onDone()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.tr("Apply")) {
                        onApply(selection)
                        onDone()
                    }
                    .disabled(selection.isEmpty)
                }
            }
        }
    }

    private func toggle(_ key: MonthKey) {
        if selection.contains(key) {
            selection.remove(key)
        } else {
            selection.insert(key)
        }
    }
}
