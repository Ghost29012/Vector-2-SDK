import Foundation
import SwiftUI
import Combine

struct SaveProfileStudio: View {
    let projectRoot: URL
    let gameDataRoot: URL?
    @State private var profile = PlayerProfile.empty
    @State private var message = ""
    @State private var saveStamp: Date?
    @State private var saveURL: URL?
    @State private var editing = false
    @State private var editMoney = "0"
    @State private var editPremium = "0"
    @State private var editPoints = "0"
    @State private var editEnergy = "0"
    @State private var editCards = "0"
    @State private var editRuns = "0"
    @State private var editZone = ""
    private let refreshTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ProjectStudioShell(title: "Player Save", subtitle: "View and edit the save file used by Vector 2.", symbol: "person.crop.rectangle.stack.fill", tint: .cyan) {
            if gameDataRoot == nil {
                ContentUnavailableView("Connect Vector 2 Data", systemImage: "externaldrive.badge.questionmark", description: Text("Choose the Vector 2 data folder from Overview to show the live player save."))
            } else {
                HStack(alignment: .top, spacing: 18) {
                    playerCard
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(spacing: 12) {
                            Image(systemName: "shield.lefthalf.filled").font(.title2).foregroundStyle(.teal)
                                .frame(width: 44, height: 44).background(Color.teal.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Active Protocol").font(.caption).foregroundStyle(.secondary)
                                Text(profile.protocolName).font(.title3.bold())
                                Text("The protocol creates the run armor when Play begins.").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Text("Currently Equipped").font(.title3.bold())
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], spacing: 12) {
                            ForEach(profile.equipment) { item in
                                HStack(spacing: 12) {
                                    Image(systemName: item.symbol).font(.title2).foregroundStyle(.cyan)
                                        .frame(width: 42, height: 42).background(Color.cyan.opacity(0.1), in: RoundedRectangle(cornerRadius: 11))
                                    VStack(alignment: .leading) { Text(item.slot).font(.caption).foregroundStyle(.secondary); Text(item.name).fontWeight(.semibold).lineLimit(1) }
                                    Spacer()
                                }.padding(12).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
                            }
                        }
                        Text("Player Data").font(.title3.bold()).padding(.top, 4)
                        HStack(spacing: 12) {
                            profileStat("Credits", profile.money, "creditcard.fill", .cyan)
                            profileStat("Premium", profile.premium, "diamond.fill", .purple)
                            profileStat("Points", profile.points, "star.fill", .orange)
                            profileStat("Runs", profile.runs, "figure.run", .green)
                        }
                        HStack(spacing: 12) {
                            profileStat("Energy", profile.energy, "bolt.fill", .yellow)
                            profileStat("Cards", profile.cards, "rectangle.stack.fill", .blue)
                            profileStat("Zone", profile.zone, "map.fill", .indigo)
                        }
                        saveEditor
                        if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
                    }.frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }.onAppear(perform: load)
            .onReceive(refreshTimer) { _ in refreshIfChanged() }
    }

    private var saveEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Edit Save Data").font(.headline)
                    Text("Writes the same user.xml after creating a backup beside it.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(editing ? "Cancel" : "Edit") { editing.toggle(); if editing { populateEditor() } }
            }
            if editing {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                    saveField("Credits", $editMoney); saveField("Premium", $editPremium); saveField("Points", $editPoints)
                    saveField("Energy", $editEnergy); saveField("Cards", $editCards); saveField("Runs", $editRuns)
                }
                saveField("Current custom zone ID", $editZone)
                HStack { Spacer(); Button("Save Player Data", action: writeSave).buttonStyle(.borderedProminent) }
            }
        }.padding(14).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
    }

    private func saveField(_ title: String, _ value: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) { Text(title).font(.caption).foregroundStyle(.secondary); TextField(title, text: value).textFieldStyle(.roundedBorder) }
    }

    private var playerCard: some View {
        VStack(spacing: 16) {
            AnimatedCharacterPreview(
                projectRoot: projectRoot,
                modelReferences: ([profile.playerModel].compactMap { $0 } + profile.modelLayers).vector2Uniqued(),
                includesDefaultBody: profile.playerModel == nil,
                accent: .cyan
            )
            .frame(height: 330)
            .id(([profile.playerModel ?? "1.xml"] + profile.modelLayers).joined(separator: "|"))
            VStack(spacing: 3) {
                Text(profile.name).font(.title2.bold())
                Text(profile.zone).font(.caption).foregroundStyle(.cyan)
            }
            VStack(spacing: 3) {
                Text("Player model").font(.caption).foregroundStyle(.secondary)
                Text(profile.playerModel ?? "Default Vector body").font(.subheadline.bold()).multilineTextAlignment(.center)
                if !profile.modelLayers.isEmpty {
                    Text("Armor: " + profile.modelLayers.joined(separator: " + "))
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            }
            Button("Refresh Live Save", action: load).buttonStyle(.borderedProminent)
        }.frame(width: 300)
    }

    private func profileStat(_ title: String, _ value: String, _ icon: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 7) { Image(systemName: icon).foregroundStyle(color); Text(value).font(.title3.bold()).lineLimit(1); Text(title).font(.caption).foregroundStyle(.secondary) }
            .padding(13).frame(maxWidth: .infinity, minHeight: 92, alignment: .leading).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
    }

    private func load() {
        guard let root = gameDataRoot else { return }
        let candidates = [root.appendingPathComponent("userdata/user.xml"), root.appendingPathComponent("saved_users/user_z2_default.xml")]
        guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { message = "No player save exists in this Vector 2 data folder yet."; return }
        do { profile = try PlayerProfile.load(url, gameDataRoot: root); saveURL = url; saveStamp = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate; if editing { populateEditor() }; message = "Loaded \(url.lastPathComponent)." }
        catch { profile = .empty; message = "Could not read the player save: \(error.localizedDescription)" }
    }

    private func populateEditor() {
        editMoney = profile.money; editPremium = profile.premium; editPoints = profile.points
        editEnergy = profile.energy; editCards = profile.cards; editRuns = profile.runs
        editZone = profile.zone == "0" || profile.zone == "No zone" ? "" : profile.zone
    }

    private func writeSave() {
        guard let saveURL else { message = "No live save is loaded."; return }
        let numeric = [editMoney, editPremium, editPoints, editEnergy, editCards, editRuns]
        guard numeric.allSatisfy({ Int($0) != nil }) else { message = "Credits, premium, points, energy, cards and runs must be whole numbers."; return }
        do {
            let document = try XMLDocument(contentsOf: saveURL)
            func set(_ xpath: String, _ attribute: String, _ value: String) throws {
                guard let node = try document.nodes(forXPath: xpath).first as? XMLElement else { throw CocoaError(.fileReadCorruptFile) }
                node.removeAttribute(forName: attribute)
                node.addAttribute(XMLNode.attribute(withName: attribute, stringValue: value) as! XMLNode)
            }
            try set("/User/Items/Stash/Item[@Name='Money']/Group[@Name='Countable']", "Quantity", editMoney)
            try set("/User/Items/Stash/Item[@Name='MoneyPremium']/Group[@Name='Countable']", "Quantity", editPremium)
            try set("/User/Items/Stash/Item[@Name='Points']/Group[@Name='Countable']", "Quantity", editPoints)
            try set("/User/UserProperties/Energy", "Level", editEnergy)
            try set("/User/UserCounters/Namespace[@Name='ST_Statistics']/Counter[@Name='CardsCount']", "Value", editCards)
            try set("/User/UserCounters/Namespace[@Name='ST_Statistics']/Counter[@Name='ST_run_counter']", "Value", editRuns)
            try set("/User/UserProperties/Zones", "CurrentCustom", editZone)
            let backup = saveURL.deletingPathExtension().appendingPathExtension("before-editor.xml")
            if FileManager.default.fileExists(atPath: backup.path) { try FileManager.default.removeItem(at: backup) }
            try FileManager.default.copyItem(at: saveURL, to: backup)
            try document.xmlData(options: .nodePrettyPrint).write(to: saveURL, options: .atomic)
            editing = false; load(); message = "Saved player data. Backup: \(backup.lastPathComponent)."
        } catch { message = "Could not save player data: \(error.localizedDescription)" }
    }

    private func refreshIfChanged() {
        guard let root = gameDataRoot else { return }
        let candidates = [root.appendingPathComponent("userdata/user.xml"), root.appendingPathComponent("saved_users/user_z2_default.xml")]
        guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
              let changed = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
              changed != saveStamp else { return }
        load()
    }
}

private struct EquipmentItem: Identifiable {
    let id = UUID(); let slot: String; let name: String; let symbol: String
}

private struct PlayerProfile {
    let name: String; let zone: String; let money: String; let premium: String; let points: String; let runs: String; let energy: String; let cards: String; let protocolName: String; let playerModel: String?; let modelLayers: [String]; let equipment: [EquipmentItem]
    static let empty = PlayerProfile(name: "Player", zone: "No zone", money: "0", premium: "0", points: "0", runs: "0", energy: "0", cards: "0", protocolName: "No protocol equipped", playerModel: nil, modelLayers: [], equipment: defaultEquipment([:]))

    static func load(_ url: URL, gameDataRoot: URL) throws -> PlayerProfile {
        let document = try XMLDocument(contentsOf: url)
        guard let root = document.rootElement() else { throw CocoaError(.fileReadCorruptFile) }
        func attr(_ path: String, _ name: String) -> String {
            let nodes = (try? document.nodes(forXPath: path)) ?? []
            return (nodes.first as? XMLElement)?.attribute(forName: name)?.stringValue ?? "0"
        }
        func currency(_ item: String) -> String { attr("/User/Items/Stash/Item[@Name='\(item)']/Group[@Name='Countable']", "Quantity") }
        var equipped: [String: String] = [:]
        var protocols: [String] = []
        var modelLayers: [String] = []
        for case let item as XMLElement in (try? document.nodes(forXPath: "/User/Items/Equipped/Item")) ?? [] {
            let slot = item.attribute(forName: "Name")?.stringValue ?? "Gear"
            if item.attribute(forName: "ItemType")?.stringValue == "StarterPack" { protocols.append(slot); continue }
            let groups = item.elements(forName: "Group")
            if let model = groups.first(where: { $0.attribute(forName: "Name")?.stringValue == "ST_Model" })?.attribute(forName: "ST_File")?.stringValue { modelLayers.append(model) }
            let equipmentSlot = groups.first(where: { $0.attribute(forName: "Name")?.stringValue == "ST_MyGadgets" })?.attribute(forName: "ST_Slot")?.stringValue ?? slot
            equipped[equipmentSlot] = slot
        }
        let customZone = attr("/User/UserProperties/Zones", "CurrentCustom")
        let zone = customZone == "0" ? attr("/User/UserProperties/Zones", "Current") : customZone
        let protocolInfo = installedProtocol(in: gameDataRoot, zone: customZone, baseNames: protocols)
        return PlayerProfile(name: root.attribute(forName: "Name")?.stringValue ?? "Player", zone: zone, money: currency("Money"), premium: currency("MoneyPremium"), points: currency("Points"), runs: attr("/User/UserCounters/Namespace[@Name='ST_Statistics']/Counter[@Name='ST_run_counter']", "Value"), energy: attr("/User/UserProperties/Energy", "Level"), cards: attr("/User/UserCounters/Namespace[@Name='ST_Statistics']/Counter[@Name='CardsCount']", "Value"), protocolName: protocolInfo.name ?? (protocols.isEmpty ? "No protocol equipped" : protocols.joined(separator: ", ")), playerModel: protocolInfo.playerModel, modelLayers: modelLayers, equipment: defaultEquipment(equipped))
    }

    private static func installedProtocol(in gameDataRoot: URL, zone: String, baseNames: [String]) -> (name: String?, playerModel: String?) {
        guard zone != "0", !zone.isEmpty, !baseNames.isEmpty else { return (nil, nil) }
        let chapter = firstAttribute(in: gameDataRoot.appendingPathComponent("custom_zones"), xpath: "//Zone[@Id='\(zone)']", name: "Chapter")
        guard let chapter, !chapter.isEmpty else { return (nil, nil) }
        let folder = gameDataRoot.appendingPathComponent("custom_protocols")
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return (nil, nil) }
        for case let file as URL in enumerator where file.pathExtension.lowercased() == "xml" {
            guard let document = try? XMLDocument(contentsOf: file) else { continue }
            for case let node as XMLElement in (try? document.nodes(forXPath: "/Protocols/Protocol")) ?? [] {
                let nodeChapter = node.attribute(forName: "Chapter")?.stringValue ?? ""
                let base = node.attribute(forName: "BaseProtocol")?.stringValue ?? "BasicProtocol"
                guard nodeChapter.caseInsensitiveCompare(chapter) == .orderedSame,
                      baseNames.contains(where: { $0.caseInsensitiveCompare(base) == .orderedSame }) else { continue }
                let playerModel = node.attribute(forName: "PlayerModel")?.stringValue
                return (node.attribute(forName: "Name")?.stringValue,
                        playerModel?.isEmpty == false ? playerModel : nil)
            }
        }
        return (nil, nil)
    }

    private static func firstAttribute(in folder: URL, xpath: String, name: String) -> String? {
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return nil }
        for case let file as URL in enumerator where file.pathExtension.lowercased() == "xml" {
            guard let document = try? XMLDocument(contentsOf: file), let node = (try? document.nodes(forXPath: xpath))?.first as? XMLElement else { continue }
            return node.attribute(forName: name)?.stringValue
        }
        return nil
    }

    private static func defaultEquipment(_ values: [String: String]) -> [EquipmentItem] {
        [("Head", "person.crop.circle"), ("Torso", "tshirt.fill"), ("Hands", "hand.raised.fill"), ("Legs", "figure.walk"), ("Belt", "circle.dotted")].map { EquipmentItem(slot: $0.0, name: values[$0.0] ?? "Empty", symbol: $0.1) }
    }
}
