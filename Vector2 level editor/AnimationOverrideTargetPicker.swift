import SwiftUI

struct AnimationOverrideTargetPicker: View {
    let moves: [TrickPreviewMove]
    let selectedName: String
    let onSelect: (TrickPreviewMove) -> Void
    let onCancel: () -> Void
    @State private var search = ""

    private var filteredMoves: [TrickPreviewMove] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return moves }
        return moves.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            List(filteredMoves) { move in
                Button {
                    onSelect(move)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(move.name).foregroundStyle(.primary)
                            Text("Frames \(move.firstFrame)...\(move.endFrame) • \(move.pivotNode)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if move.name == selectedName { Image(systemName: "checkmark.circle.fill").foregroundStyle(.blue) }
                    }
                }
                .buttonStyle(.plain)
            }
            .searchable(text: $search, prompt: "Search animations")
            .navigationTitle("Override Animation")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel) } }
        }
        .frame(minWidth: 520, minHeight: 560)
    }
}
