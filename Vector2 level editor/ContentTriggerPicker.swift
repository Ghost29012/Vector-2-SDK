import SwiftUI

/// Shared trigger UI for content that needs a real reason to appear in game.
struct ContentTriggerPicker: View {
    @Binding var trigger: String
    @Binding var reference: String
    @Binding var once: Bool
    let contentName: String

    private let choices = ["Manual", "Menu Open", "Chapter Start", "Zone Selected", "Floor Start", "Custom Event"]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("When does this \(contentName) appear?", systemImage: "bolt.circle.fill").font(.title3.bold()).foregroundStyle(.indigo)
            Picker("Trigger", selection: $trigger) { ForEach(choices, id: \.self) { Text($0).tag($0) } }
                .pickerStyle(.menu)
            if needsReference {
                TextField(referencePrompt, text: $reference).textFieldStyle(.roundedBorder)
                Text(referenceHelp).font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Only show once", isOn: $once).toggleStyle(.switch)
            Text(explanation).font(.callout).foregroundStyle(.secondary)
        }.padding(20).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.indigo.opacity(0.18)))
    }

    private var needsReference: Bool { ["Chapter Start", "Zone Selected", "Floor Start", "Custom Event"].contains(trigger) }
    private var referencePrompt: String { trigger == "Floor Start" ? "Floor number (empty means every floor)" : trigger == "Custom Event" ? "Event name" : trigger == "Chapter Start" ? "Chapter ID" : "Zone ID" }
    private var referenceHelp: String { trigger == "Custom Event" ? "A room ExecuteCall action can send this exact name." : "Leave empty to match any value." }
    private var explanation: String {
        switch trigger {
        case "Manual": return "A quest or room action can call this by its ID."
        case "Menu Open": return "Runs when the main menu becomes ready."
        case "Chapter Start": return "Runs when the selected custom zone belongs to this chapter."
        case "Zone Selected": return "Runs after the player selects the matching custom zone."
        case "Floor Start": return "Runs after the gameplay scene and dialog canvas are ready."
        default: return "Runs when ExecuteCall sends the matching event name."
        }
    }
}
