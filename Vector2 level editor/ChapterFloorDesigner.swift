import SwiftUI

/// Controls the real start-floor buttons used by a custom chapter.
struct ChapterFloorDesigner: View {
    @Binding var floors: [Int]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Starting floors", systemImage: "play.square.stack.fill").font(.title3.bold()).foregroundStyle(.blue)
            Text("Choose how many start buttons appear in Vector 2, then set the floor each button begins from.")
                .font(.callout).foregroundStyle(.secondary)
            Stepper("\(floors.count) menu button\(floors.count == 1 ? "" : "s")", value: Binding(get: { floors.count }, set: resize), in: 1...12)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 10)], spacing: 10) {
                ForEach(floors.indices, id: \.self) { index in
                    Stepper(value: $floors[index], in: 1...999) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Start option \(index + 1)").font(.caption).foregroundStyle(.secondary)
                            Text("Floor \(floors[index])").font(.headline)
                        }
                    }.padding(12).background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }.padding(20).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.blue.opacity(0.15)))
    }

    private func resize(_ count: Int) {
        if count < floors.count { floors.removeLast(floors.count - count) }
        else { while floors.count < count { floors.append((floors.last ?? 0) + 1) } }
    }
}
