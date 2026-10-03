import SwiftUI

/// Mission goal, unlock condition and reward fields.
struct MissionDesignerFields: View {
    @Binding var item: SDKDefinition
    private let objectives = [
        ("Points", "Score", "star.fill"), ("Money", "Coins", "circle.hexagongrid.fill"),
        ("StuntsCount", "Tricks", "figure.run"), ("ContexCombo", "Combo", "link"),
        ("MaxPoints", "Best trick", "bolt.fill"), ("RedCoinsCount", "Red tokens", "diamond.fill")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Objective Board", systemImage: "scope").font(.title3.bold()).foregroundStyle(.red)
            Text("Pick a goal and set how much the player needs to do.").font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 135), spacing: 10)], spacing: 10) {
                ForEach(objectives, id: \.0) { objective in
                    Button {
                        item.type = objective.0
                    } label: {
                        VStack(spacing: 8) {
                            Image(systemName: objective.2).font(.title2)
                            Text(objective.1).fontWeight(.semibold)
                        }.frame(maxWidth: .infinity, minHeight: 74)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(item.type == objective.0 ? .white : .primary)
                    .background(item.type == objective.0 ? Color.red : Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 13))
                }
            }
            Divider()
            HStack(spacing: 14) {
                numberCard("Target", value: $item.target, range: 1...100_000, icon: "flag.checkered")
                numberCard("Available from floor", value: $item.order, range: 0...999, icon: "building.2")
            }
            HStack(spacing: 14) {
                numberCard("Difficulty", value: $item.difficulty, range: 1...3, icon: "gauge.with.dots.needle.50percent")
                numberCard("Selection weight", value: $item.weight, range: 1...1000, icon: "dice")
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Protocol filter").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                TextField("Any, or an exact protocol ID", text: $item.protocolID).textFieldStyle(.roundedBorder)
                Text("Any allows all protocols. Enter an ID to limit this mission to that protocol's three mission slots.").font(.caption2).foregroundStyle(.secondary)
            }
            HStack {
                Text("Last available floor").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Stepper(item.maximumFloor == 0 ? "No limit" : "Floor \(item.maximumFloor)", value: $item.maximumFloor, in: 0...999)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Credits payout").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Stepper("\(item.amount) credits", value: $item.amount, in: 0...100_000)
                Text("The game pays these credits when the floor ends.").font(.caption2).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Additional reward ID").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                TextField("Optional custom reward", text: $item.reference).textFieldStyle(.roundedBorder)
                Text("Optional extra reward from your reward list. Credit rewards won't be paid twice.").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(18).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 17))
        .overlay(RoundedRectangle(cornerRadius: 17).stroke(Color.red.opacity(0.2)))
    }

    private func numberCard(_ title: String, value: Binding<Int>, range: ClosedRange<Int>, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(title, systemImage: icon).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack { Text("\(value.wrappedValue)").font(.system(size: 26, weight: .bold, design: .rounded)); Spacer(); Stepper("", value: value, in: range).labelsHidden() }
        }.padding(14).frame(maxWidth: .infinity).background(Color.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 13))
    }

}
