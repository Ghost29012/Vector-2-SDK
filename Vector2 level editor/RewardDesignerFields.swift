import SwiftUI

/// Rewards are shown as the actual bundle a player receives. The large amount
/// and type choices make accidental economy edits much harder to miss.
struct RewardDesignerFields: View {
    @Binding var item: SDKDefinition
    private let types = ["Credits", "Premium Currency", "Card", "Energy", "Item"]

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(spacing: 10) {
                Image(systemName: item.rewardSymbol).font(.system(size: 54)).foregroundStyle(.orange)
                Text("×\(item.amount)").font(.system(size: 34, weight: .bold, design: .rounded))
                Text(item.type).font(.headline).multilineTextAlignment(.center)
            }
            .frame(width: 190).frame(minHeight: 215)
            .background(LinearGradient(colors: [.orange.opacity(0.18), .yellow.opacity(0.05)], startPoint: .top, endPoint: .bottom), in: RoundedRectangle(cornerRadius: 18))

            VStack(alignment: .leading, spacing: 14) {
                Label("Player Payout", systemImage: "gift.fill").font(.title3.bold()).foregroundStyle(.orange)
                Text("Choose one reward type. The game grants this through its normal reward system.").font(.caption).foregroundStyle(.secondary)
                Picker("Reward type", selection: $item.type) {
                    ForEach(types, id: \.self) { Text($0).tag($0) }
                }.pickerStyle(.menu).frame(maxWidth: 310)
                Stepper(value: $item.amount, in: 1...1_000_000) {
                    HStack { Text("Amount"); Spacer(); Text("\(item.amount)").font(.title3.bold()).foregroundStyle(.orange) }
                }
                if ["Card", "Item"].contains(item.type) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.type == "Card" ? "Card ID" : "Existing item preset ID").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        TextField("What should the game grant?", text: $item.reference).textFieldStyle(.roundedBorder)
                    }
                }
                Label("Credits, premium currency, energy and cards are supported by the game adapter.", systemImage: "checkmark.shield.fill")
                    .font(.caption).foregroundStyle(.green)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(18).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 17))
        .overlay(RoundedRectangle(cornerRadius: 17).stroke(Color.orange.opacity(0.24)))
    }
}
