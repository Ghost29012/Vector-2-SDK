import Foundation
import SwiftUI

/// Creates the card manifest used by Shop and Upgrades.
struct CommerceCardCreator: View {
    let projectRoot: URL
    let artwork: [String]
    let onCancel: () -> Void
    let onCreated: (CommerceCard) -> Void

    @State private var stableID = ""
    @State private var name = ""
    @State private var details = ""
    @State private var image = ""
    @State private var cardType = "Passive"
    @State private var category = "Custom"
    @State private var slot = "Torso"
    @State private var effectID = "None"
    @State private var error = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Create a Custom Card").font(.system(size: 28, weight: .bold))
                        Text("Add an upgrade, story note, or story item to the shop.").foregroundStyle(.secondary)
                    }
                    Spacer(); Button("Cancel", action: onCancel)
                    Button("Create Card", action: create).buttonStyle(.borderedProminent).disabled(cleanID.isEmpty || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                HStack(spacing: 12) {
                    ForEach([("Passive", "bolt.shield.fill", "Upgrade"), ("Notes", "note.text", "Story note"), ("StoryItems", "shippingbox.fill", "Story item")], id: \.0) { option in
                        Button {
                            cardType = option.0
                            category = option.0 == "Notes" ? "CustomNotes" : option.0 == "StoryItems" ? "StoryItems" : "Custom"
                            slot = option.0 == "Passive" ? "Torso" : option.0
                            effectID = option.0 == "Passive" ? "None" : option.0
                        } label: {
                            VStack(spacing: 9) { Image(systemName: option.1).font(.title); Text(option.2).fontWeight(.semibold) }.frame(maxWidth: .infinity, minHeight: 95)
                        }.buttonStyle(.plain).foregroundStyle(cardType == option.0 ? .white : .primary)
                            .background(cardType == option.0 ? Color.blue : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 15))
                    }
                }
                GroupBox("Identity") {
                    VStack(alignment: .leading, spacing: 12) {
                        labeled("Card ID", "Use a stable name such as AirDash_1", text: $stableID)
                        labeled("Player-facing name", "Shown on the card", text: $name)
                        labeled("Description", "Explain what the card unlocks or what the note says", text: $details, vertical: true)
                    }.padding(8)
                }
                GroupBox("Presentation") {
                    HStack(spacing: 18) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Artwork").font(.caption.weight(.semibold))
                            Picker("Artwork", selection: $image) { Text("No artwork yet").tag(""); ForEach(artwork, id: \.self) { Text($0).tag($0) } }.labelsHidden().pickerStyle(.menu)
                        }
                        VStack(alignment: .leading, spacing: 6) { Text("Category").font(.caption.weight(.semibold)); TextField("Category", text: $category).textFieldStyle(.roundedBorder) }
                    }.padding(8)
                }
                GroupBox("Gameplay") {
                    HStack(spacing: 18) {
                        if cardType == "Passive" {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Equipment slot").font(.caption.weight(.semibold))
                                Picker("Equipment slot", selection: $slot) {
                                    ForEach(["Head", "Torso", "Hands", "Belt", "Legs"], id: \.self) { Text($0).tag($0) }
                                }.labelsHidden().pickerStyle(.menu)
                            }
                        }
                        if cardType == "Passive" {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("What does it do?").font(.caption.weight(.semibold))
                                Picker("Player effect", selection: $effectID) {
                                    ForEach(GameplayEffectCatalog.upgradeCardEffects) { effect in Text(effect.title).tag(effect.id) }
                                }.labelsHidden().pickerStyle(.menu)
                                Text(GameplayEffectCatalog.definition(effectID)?.explanation ?? "This effect is not supported by the current runtime.")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }.padding(8)
                }
                Label("After creation, Shop controls availability and presentation; Upgrades controls every level and gameplay value.", systemImage: "arrow.triangle.branch")
                    .foregroundStyle(.secondary)
                if !error.isEmpty { Text(error).foregroundStyle(.red) }
            }.frame(maxWidth: 900).padding(24).frame(maxWidth: .infinity)
        }
    }

    private func labeled(_ title: String, _ help: String, text: Binding<String>, vertical: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 5) { Text(title).font(.caption.weight(.semibold)); Text(help).font(.caption2).foregroundStyle(.secondary); TextField(title, text: text, axis: vertical ? .vertical : .horizontal).textFieldStyle(.roundedBorder).lineLimit(vertical ? 2...5 : 1...1) }
    }

    private var cleanID: String { stableID.filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" } }

    private func create() {
        do {
            let folder = projectRoot.appendingPathComponent("custom_upgrades").appendingPathComponent(cleanID, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let manifest = folder.appendingPathComponent("card.xml")
            guard !FileManager.default.fileExists(atPath: manifest.path) else { throw CocoaError(.fileWriteFileExists) }
            let root = XMLElement(name: "CustomCard")
            let values = ["Name": cleanID, "CardName": cleanID, "VisualName": name, "Description": details, "Image": image, "Rarity": "1", "Price": "1000", "ShopEnabled": cardType == "Passive" ? "1" : "0", "Group": "CustomCards", "SetupMin": "0", "SetupMax": "99", "Weight": "1000", "WeightForUse": "1", "CardType": cardType, "Category": category, "EffectID": effectID, "Slot": slot, "MaxLevel": cardType == "Passive" ? "5" : "1"]
            for (key, value) in values { root.addAttribute(XMLNode.attribute(withName: key, stringValue: value) as! XMLNode) }
            let defaults = [(2, 100), (3, 120), (5, 145), (7, 175), (9, 210)]
            for (offset, level) in defaults.prefix(cardType == "Passive" ? 5 : 1).enumerated() {
                let node = XMLElement(name: "Level")
                var levelValues = ["Number": "\(offset + 1)", "Cards": "\(level.0)", "Points": "\(level.1)"]
                if cardType == "Passive", let effect = GameplayEffectCatalog.definition(effectID) {
                    for parameter in effect.parameters { levelValues[parameter.key] = parameter.defaultValue }
                }
                levelValues.forEach { node.addAttribute(XMLNode.attribute(withName: $0.key, stringValue: $0.value) as! XMLNode) }
                root.addChild(node)
            }
            let document = XMLDocument(rootElement: root); document.version = "1.0"; document.characterEncoding = "utf-8"
            try document.xmlData(options: .nodePrettyPrint).write(to: manifest, options: .atomic)
            guard let card = CommerceCard.load(from: projectRoot.appendingPathComponent("custom_upgrades")).first(where: { $0.manifest == manifest }) else { throw CocoaError(.fileReadCorruptFile) }
            onCreated(card)
        } catch { self.error = "Could not create card: \(error.localizedDescription)" }
    }
}
