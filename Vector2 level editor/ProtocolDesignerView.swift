import AppKit
import Foundation
import SwiftUI

struct ProtocolDesignerView: View {
    let projectRoot: URL
    let onStatus: (String) -> Void
    @State private var protocols: [ProjectProtocol] = []
    @State private var selectedID: UUID?
    @State private var modelItems: [CustomModelItem] = []

    private var selectedIndex: Int? { protocols.firstIndex { $0.id == selectedID } }
    private var chapters: [String] { xmlIDs(folder: "custom_chapters", element: "Chapter", attribute: "Id") }
    private var models: [String] { modelItems.map(\.id) }
    private var artwork: [String] {
        ["custom_textures", "custom_backgrounds"].flatMap { folder -> [String] in
            let root = projectRoot.appendingPathComponent(folder)
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return [] }
            return enumerator.compactMap { item -> String? in
                guard let url = item as? URL, ["png", "jpg", "jpeg", "bmp", "gif"].contains(url.pathExtension.lowercased()) else { return nil }
                return url.lastPathComponent
            }
        }.sorted()
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                catalogue.frame(minWidth: 245, idealWidth: 280, maxWidth: 325)
                if let index = selectedIndex { editor($protocols[index]).frame(minWidth: 650) }
                else { ContentUnavailableView("No protocol selected", systemImage: "shield.lefthalf.filled", description: Text("Create a protocol to set its floor button, armor and character appearance.")).frame(minWidth: 650, maxWidth: .infinity, maxHeight: .infinity) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: .vector2AssetCatalogChanged)) { _ in
            modelItems = CustomModelCatalog.load(projectRoot: projectRoot)
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "shield.lefthalf.filled").font(.system(size: 23, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 48, height: 48).background(Color.teal.gradient, in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 2) {
                Text("Protocols").font(.system(size: 27, weight: .bold))
                Text("Set the player's starting floor, armor, and character model.").foregroundStyle(.secondary)
            }
            Spacer()
            Button("Reload", systemImage: "arrow.clockwise", action: reload)
            Button("New Protocol", systemImage: "plus", action: create).buttonStyle(.borderedProminent)
        }.padding(.horizontal, 24).padding(.vertical, 16).background(Color(nsColor: .controlBackgroundColor).opacity(0.94))
    }

    private var catalogue: some View {
        ScrollView {
            LazyVStack(spacing: 9) {
                ForEach(protocols) { item in
                    Button { selectedID = item.id } label: {
                        HStack(spacing: 11) {
                            Image(systemName: "shield.fill").foregroundStyle(.teal)
                                .frame(width: 39, height: 39).background(.teal.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.name.isEmpty ? "Untitled Protocol" : item.name).fontWeight(.semibold).lineLimit(1)
                                Text("Floor \(item.startFloor) · \(item.baseProtocol)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }.padding(9).contentShape(Rectangle())
                    }.buttonStyle(.plain).background(selectedID == item.id ? Color.teal.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 11))
                }
            }.padding(12)
        }.background(Color(nsColor: .controlBackgroundColor).opacity(0.8))
    }

    private func editor(_ item: Binding<ProjectProtocol>) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                protocolPreview(item.wrappedValue)
                panel("Identity", "What players see on the chapter screen.") {
                    labeled("Protocol name") { TextField("Maintenance Recon", text: item.name).textFieldStyle(.roundedBorder) }
                    labeled("Description") { TextField("What this loadout is built for", text: item.details, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(2...4) }
                    HStack {
                        labeled("Stable ID") { TextField("maintenance_recon", text: item.stableID).textFieldStyle(.roundedBorder) }
                        labeled("Chapter") { Picker("", selection: item.chapter) { Text("Choose chapter").tag(""); ForEach(chapters, id: \.self) { Text($0).tag($0) } }.labelsHidden() }
                    }
                    labeled("Card artwork") { Picker("", selection: item.artwork) { Text("Use stock unknown card").tag("box_unknown"); ForEach(artwork, id: \.self) { Text($0).tag($0) } }.labelsHidden() }
                }
                panel("Run setup", "Choose where this protocol starts and which base armor it uses.") {
                    HStack {
                        labeled("Starting floor") { Stepper(value: item.startFloor, in: 1...999) { Text("Floor \(item.wrappedValue.startFloor)") } }
                        labeled("Menu order") { Stepper(value: item.order, in: 0...99) { Text("Position \(item.wrappedValue.order + 1)") } }
                    }
                    labeled("Base armor and stats") {
                        Picker("", selection: item.baseProtocol) {
                            Text("Basic — torso").tag("BasicProtocol")
                            Text("Standard — torso and legs").tag("StandardProtocol")
                            Text("Advanced — head, torso, hands and legs").tag("AdvancedProtocol")
                            Text("Experimental — full experimental loadout").tag("ExperimentalProtocol")
                        }.labelsHidden()
                    }
                }
                panel("Armour gameplay", "Choose one safe effect that this Protocol applies while equipped. Every option here has a real Vector 2 runtime handler.") {
                    Text("Durability by equipment slot").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], spacing: 10) {
                        durability("Helmet", item.helmetDurability)
                        durability("Torso", item.torsoDurability)
                        durability("Hands", item.handsDurability)
                        durability("Legs", item.legsDurability)
                        durability("Belt", item.beltDurability)
                    }
                    Text("A custom trap damages only its chosen slot. Reaching zero defeats the player; 0 makes that slot unprotected.")
                        .font(.caption).foregroundStyle(.secondary)
                    Divider()
                    Picker("Gameplay effect", selection: item.effectID) {
                        ForEach(GameplayEffectCatalog.effects) { effect in Text(effect.title).tag(effect.id) }
                    }.pickerStyle(.menu)
                    Text(GameplayEffectCatalog.definition(item.wrappedValue.effectID)?.explanation ?? "Unsupported effect")
                        .font(.caption).foregroundStyle(.secondary)
                    if item.wrappedValue.effectID == "RegenerateCharges" {
                        HStack {
                            labeled("Refill every") { Stepper("\(item.wrappedValue.effectInterval, specifier: "%.1f") seconds", value: item.effectInterval, in: 0.5...60, step: 0.5) }
                            labeled("Restore") { Stepper("\(item.wrappedValue.effectAmount) charges", value: item.effectAmount, in: 1...99) }
                            labeled("Stop at") { Stepper("\(item.wrappedValue.effectMaximum) charges", value: item.effectMaximum, in: 1...999) }
                        }
                    } else if item.wrappedValue.effectID == "RestoreChargesOnFloorStart" {
                        labeled("Restore each floor") { Stepper("\(item.wrappedValue.effectAmount) charges", value: item.effectAmount, in: 1...99) }
                    }
                }
                panel("Character appearance", "Choose complete custom model packages. Empty slots keep the base protocol's normal appearance.") {
                    labeled("Player model") { modelPicker(item.playerModel) }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 12)], spacing: 12) {
                        labeled("Head layer") { modelPicker(item.headModel) }
                        labeled("Torso layer") { modelPicker(item.torsoModel) }
                        labeled("Hands layer") { modelPicker(item.handsModel) }
                        labeled("Legs layer") { modelPicker(item.legsModel) }
                    }
                    if models.isEmpty { Label("Create or import a valid package in Models before assigning custom armor artwork.", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange) }
                }
                HStack {
                    Button("Delete", role: .destructive) { delete(item.wrappedValue) }
                    Spacer()
                    Button("Revert", action: reload)
                    Button("Save Protocol") { save(item.wrappedValue) }.buttonStyle(.borderedProminent).controlSize(.large)
                }
            }.frame(maxWidth: 940).padding(24).frame(maxWidth: .infinity)
        }
    }

    private func protocolPreview(_ item: ProjectProtocol) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 18) {
                ZStack {
                    RoundedRectangle(cornerRadius: 18).fill(LinearGradient(colors: [.teal.opacity(0.28), .blue.opacity(0.08)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    if let image = image(named: item.artwork) { Image(nsImage: image).resizable().scaledToFit().padding(10) }
                    else { Image(systemName: "shield.lefthalf.filled").font(.system(size: 58)).foregroundStyle(.teal) }
                }.frame(width: 180, height: 130).clipped()
                VStack(alignment: .leading, spacing: 7) {
                    Text(item.name.isEmpty ? "New Protocol" : item.name).font(.title2.bold())
                    Text(item.details.isEmpty ? "Describe what makes this loadout useful." : item.details).foregroundStyle(.secondary).lineLimit(2)
                    HStack { Label("Floor \(item.startFloor)", systemImage: "building.2"); Label(item.baseProtocol.replacingOccurrences(of: "Protocol", with: " armor"), systemImage: "tshirt.fill") }.font(.caption.weight(.semibold))
                }
                Spacer()
            }
            AnimatedCharacterPreview(projectRoot: projectRoot, modelReferences: protocolModelStack(item), accent: .teal)
                .frame(height: 330)
                .id(protocolModelStack(item).joined(separator: "|"))
        }.padding(18).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 20))
    }

    private func protocolModelStack(_ item: ProjectProtocol) -> [String] {
        let chosen = [item.playerModel, item.headModel, item.torsoModel, item.handsModel, item.legsModel]
            .filter { !$0.isEmpty }
            .map { "custom:\($0)" }
        return chosen.isEmpty ? ["1.xml"] : chosen
    }

    private func panel<Content: View>(_ title: String, _ subtitle: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) { Text(title).font(.title3.bold()); Text(subtitle).font(.caption).foregroundStyle(.secondary); Divider(); content() }
            .padding(18).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 17))
            .overlay(RoundedRectangle(cornerRadius: 17).stroke(Color.secondary.opacity(0.15)))
    }

    private func labeled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) { Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary); content() }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func modelPicker(_ selection: Binding<String>) -> some View {
        Picker("", selection: selection) {
            Text("Base game appearance").tag("")
            ForEach(modelItems) { model in Text(model.name).tag(model.id) }
            if !selection.wrappedValue.isEmpty && !models.contains(selection.wrappedValue) {
                Text("Missing model: \(selection.wrappedValue)").tag(selection.wrappedValue)
            }
        }.labelsHidden()
    }

    private func durability(_ title: String, _ value: Binding<Int>) -> some View {
        Stepper("\(title): \(value.wrappedValue)", value: value, in: 0...999, step: 10)
            .padding(10)
            .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
    }

    private func xmlIDs(folder: String, element: String, attribute: String) -> [String] {
        let root = projectRoot.appendingPathComponent(folder)
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        return enumerator.compactMap { item -> [String]? in
            guard let url = item as? URL, url.pathExtension.lowercased() == "xml", let document = try? XMLDocument(contentsOf: url) else { return nil }
            return (try? document.nodes(forXPath: "//\(element)"))?.compactMap { ($0 as? XMLElement)?.attribute(forName: attribute)?.stringValue }
        }.flatMap { $0 }.sorted()
    }

    private func image(named name: String) -> NSImage? {
        guard !name.isEmpty else { return nil }
        for folder in ["custom_textures", "custom_backgrounds"] {
            let direct = projectRoot.appendingPathComponent(folder).appendingPathComponent(name)
            if let image = NSImage(contentsOf: direct) { return image }
        }
        return nil
    }

    private func create() { let item = ProjectProtocol(); protocols.insert(item, at: 0); selectedID = item.id }
    private func reload() {
        modelItems = CustomModelCatalog.load(projectRoot: projectRoot)
        protocols = ProjectProtocol.load(projectRoot.appendingPathComponent("custom_protocols"))
        selectedID = protocols.first?.id
    }
    private func save(_ item: ProjectProtocol) {
        do { try item.write(projectRoot.appendingPathComponent("custom_protocols")); onStatus("Protocol saved. Choose Install Changes to send it to Vector 2."); reload() }
        catch { onStatus("Could not save protocol: \(error.localizedDescription)") }
    }
    private func delete(_ item: ProjectProtocol) {
        do {
            if let file = item.file { try FileManager.default.removeItem(at: file) }
            reload()
            onStatus("Protocol removed from the project. Install Changes removes its old game copy.")
        } catch {
            reload()
            onStatus("Could not delete protocol: \(error.localizedDescription)")
        }
    }
}

private struct ProjectProtocol: Identifiable {
    var id = UUID(); var file: URL?; var stableID = ""; var name = ""; var details = ""; var artwork = "box_unknown"; var chapter = ""; var baseProtocol = "BasicProtocol"; var playerModel = ""; var startFloor = 1; var order = 0; var headModel = ""; var torsoModel = ""; var handsModel = ""; var legsModel = ""; var effectID = "None"; var effectInterval = 5.0; var effectAmount = 1; var effectMaximum = 12; var helmetDurability = 100; var torsoDurability = 100; var handsDurability = 100; var legsDurability = 100; var beltDurability = 100

    static func load(_ folder: URL) -> [ProjectProtocol] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        return files.filter { $0.pathExtension.lowercased() == "xml" }.compactMap { url in
            guard let document = try? XMLDocument(contentsOf: url), let node = (try? document.nodes(forXPath: "/Protocols/Protocol"))?.first as? XMLElement else { return nil }
            func value(_ name: String, _ fallback: String = "") -> String { node.attribute(forName: name)?.stringValue ?? fallback }
            func armor(_ slot: String) -> String { ((try? node.nodes(forXPath: "Armor[@Slot='\(slot)']"))?.first as? XMLElement)?.attribute(forName: "Model")?.stringValue?.replacingOccurrences(of: "custom:", with: "") ?? "" }
            let gameplay = node.elements(forName: "Gameplay").first
            func gameplayValue(_ name: String, _ fallback: String) -> String { gameplay?.attribute(forName: name)?.stringValue ?? fallback }
            let defense = node.elements(forName: "ArmourDefense").first
            func defenseValue(_ name: String, _ fallback: Int) -> Int { Int(defense?.attribute(forName: name)?.stringValue ?? "") ?? fallback }
            let legacy = defenseValue("Capacity", 100)
            return ProjectProtocol(file: url, stableID: value("Id"), name: value("Name"), details: value("Description"), artwork: value("Artwork", "box_unknown"), chapter: value("Chapter"), baseProtocol: value("BaseProtocol", "BasicProtocol"), playerModel: value("PlayerModel").replacingOccurrences(of: "custom:", with: ""), startFloor: Int(value("StartFloor")) ?? 1, order: Int(value("Order")) ?? 0, headModel: armor("Head"), torsoModel: armor("Torso"), handsModel: armor("Hands"), legsModel: armor("Legs"), effectID: gameplayValue("EffectID", "None"), effectInterval: Double(gameplayValue("Interval", "5")) ?? 5, effectAmount: Int(gameplayValue("Amount", "1")) ?? 1, effectMaximum: Int(gameplayValue("Maximum", "12")) ?? 12, helmetDurability: defenseValue("Helmet", legacy), torsoDurability: defenseValue("Torso", legacy), handsDurability: defenseValue("Hands", legacy), legsDurability: defenseValue("Legs", legacy), beltDurability: defenseValue("Belt", legacy))
        }.sorted { $0.order < $1.order }
    }

    func write(_ folder: URL) throws {
        let clean = String(stableID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().map { $0.isLetter || $0.isNumber ? $0 : Character("_") })
        guard !clean.isEmpty, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !chapter.isEmpty else { throw NSError(domain: "Protocol", code: 1, userInfo: [NSLocalizedDescriptionKey: "Name, stable ID and chapter are required."]) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let root = XMLElement(name: "Protocols"); let node = XMLElement(name: "Protocol")
        ["Id": clean, "Name": name, "Description": details, "Artwork": artwork, "Chapter": chapter, "BaseProtocol": baseProtocol, "PlayerModel": playerModel.isEmpty ? "" : "custom:\(playerModel)", "StartFloor": "\(startFloor)", "Order": "\(order)"].forEach { node.addAttribute(XMLNode.attribute(withName: $0.key, stringValue: $0.value) as! XMLNode) }
        let gameplay = XMLElement(name: "Gameplay")
        ["EffectID": effectID, "Interval": String(format: "%.2f", effectInterval), "Amount": "\(effectAmount)", "Maximum": "\(effectMaximum)"].forEach { gameplay.addAttribute(XMLNode.attribute(withName: $0.key, stringValue: $0.value) as! XMLNode) }
        node.addChild(gameplay)
        let defense = XMLElement(name: "ArmourDefense")
        ["Helmet": "\(helmetDurability)", "Torso": "\(torsoDurability)", "Hands": "\(handsDurability)", "Legs": "\(legsDurability)", "Belt": "\(beltDurability)"].forEach {
            defense.addAttribute(XMLNode.attribute(withName: $0.key, stringValue: $0.value) as! XMLNode)
        }
        node.addChild(defense)
        [("Head", headModel), ("Torso", torsoModel), ("Hands", handsModel), ("Legs", legsModel)].filter { !$0.1.isEmpty }.forEach { slot, model in let armor = XMLElement(name: "Armor"); armor.addAttribute(XMLNode.attribute(withName: "Slot", stringValue: slot) as! XMLNode); armor.addAttribute(XMLNode.attribute(withName: "Model", stringValue: "custom:\(model)") as! XMLNode); node.addChild(armor) }
        root.addChild(node); let target = file ?? folder.appendingPathComponent(clean + ".xml")
        try XMLDocument(rootElement: root).xmlData(options: .nodePrettyPrint).write(to: target, options: .atomic)
    }
}
