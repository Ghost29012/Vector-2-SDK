import SwiftUI

/// Edits tutorial steps in the order players will see them.
struct TutorialDesignerFields: View {
    @Binding var item: SDKDefinition

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Text("\(item.tutorialSteps.count)").font(.title.bold()).foregroundStyle(.white).frame(width: 58, height: 58).background(.indigo.gradient, in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text("Tutorial Steps").font(.title3.bold())
                    Text("Add the messages in the order the player should see them.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(item.tutorialSteps.count) step\(item.tutorialSteps.count == 1 ? "" : "s")").foregroundStyle(.secondary)
            }
            Divider()
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("When it appears").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Picker("When it appears", selection: $item.type) {
                        ForEach(["Menu Open", "Chapter Start", "Zone Selected", "Floor Start", "Custom Event"], id: \.self) { Text($0).tag($0) }
                    }.labelsHidden().pickerStyle(.menu)
                    if ["Chapter Start", "Zone Selected", "Floor Start", "Custom Event"].contains(item.type) {
                        TextField(item.type == "Floor Start" ? "Floor number" : item.type == "Custom Event" ? "Event name" : item.type == "Chapter Start" ? "Chapter ID" : "Zone ID", text: $item.reference).textFieldStyle(.roundedBorder)
                    }
                    Toggle("Only show once", isOn: $item.once).toggleStyle(.switch)
                }.frame(width: 240, alignment: .leading)
                VStack(alignment: .leading, spacing: 10) {
                    HStack { Text("Lesson steps").font(.caption.weight(.semibold)).foregroundStyle(.secondary); Spacer(); Button { item.tutorialSteps.append(.init(instruction: "", portrait: "")) } label: { Label("Add Step", systemImage: "plus") } }
                    ForEach(Array(item.tutorialSteps.indices), id: \.self) { index in
                        HStack(alignment: .top, spacing: 10) {
                            Text("\(index + 1)").font(.headline).foregroundStyle(.white).frame(width: 32, height: 32).background(.indigo, in: Circle())
                            VStack(spacing: 7) {
                                TextField("Instruction shown to the player", text: $item.tutorialSteps[index].instruction, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(2...5)
                                TextField("Optional portrait / image ID", text: $item.tutorialSteps[index].portrait).textFieldStyle(.roundedBorder)
                            }
                            Button(role: .destructive) { item.tutorialSteps.remove(at: index) } label: { Image(systemName: "trash") }.disabled(item.tutorialSteps.count == 1)
                        }.padding(12).background(.indigo.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                    }
                }.frame(maxWidth: .infinity)
            }
            Label("This trigger is connected to the game. Manual room actions can still play it by stable ID.", systemImage: "checkmark.shield.fill")
                .font(.caption).foregroundStyle(.green)
        }
        .padding(18).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 17))
        .overlay(RoundedRectangle(cornerRadius: 17).stroke(Color.indigo.opacity(0.22)))
    }
}
