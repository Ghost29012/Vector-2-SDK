import Foundation

// Cross-file checks live here because a valid XML file can still point at a
// chapter, model, image or room folder that does not exist. Those are the bugs
// that otherwise wait until Vector 2 is halfway through loading to introduce
// themselves.
enum ProjectIntegrationAudit {
    nonisolated static func issues(in projectRoot: URL) -> [String] {
        let chapters = definitions(in: projectRoot.appendingPathComponent("custom_chapters"), xpath: "/Chapters/Chapter", id: "Id")
        let zones = definitions(in: projectRoot.appendingPathComponent("custom_zones"), xpath: "/Zones/Zone", id: "Id")
        let models = modelIDs(in: projectRoot.appendingPathComponent("custom_models"))
        let dialogues = definitions(in: projectRoot.appendingPathComponent("custom_dialogue"), xpath: "//Dialogue", id: "Id")
        let characters = definitions(in: projectRoot.appendingPathComponent("custom_characters"), xpath: "//Character", id: "Id")
        let images = imageNames(in: projectRoot)
        var result: [String] = []

        for file in xmlFiles(below: projectRoot.appendingPathComponent("custom_quests")) {
            guard let document = try? XMLDocument(contentsOf: file), document.rootElement()?.name == "Quests" else {
                result.append("\(file.lastPathComponent): expected <Quests> as the root element.")
                continue
            }
            for quest in document.rootElement()?.elements(forName: "Quest") ?? [] {
                let id = attribute(quest, "Name")
                if id.isEmpty { result.append("\(file.lastPathComponent): quest needs a stable Name.") }
                guard let start = quest.elements(forName: "StartTrigger").first,
                      start.elements(forName: "Content").first != nil else {
                    result.append("Quest '\(id)' needs StartTrigger/Content."); continue
                }
                let loops = (try? quest.nodes(forXPath: ".//Loop"))?.compactMap { $0 as? XMLElement } ?? []
                if loops.isEmpty { result.append("Quest '\(id)' has no event loop.") }
                for loop in loops where loop.elements(forName: "Events").first == nil || loop.elements(forName: "Actions").first == nil {
                    result.append("Quest '\(id)' has a loop without Events and Actions.")
                }
                let sequence = quest.elements(forName: "Trigger").filter { attribute($0, "EditorManaged") == "Sequence" }
                if !sequence.isEmpty {
                    let events = sequence.compactMap { trigger in
                        ((try? trigger.nodes(forXPath: ".//Events/OnCall[@Name='Trigger']"))?.first as? XMLElement).map { attribute($0, "Message") }
                    }
                    if events.count != sequence.count || events.contains(where: { $0.isEmpty }) { result.append("Quest '\(id)' has a sequence step without a room event.") }
                    if Set(events.map { $0.lowercased() }).count != events.count { result.append("Quest '\(id)' repeats a sequence event, so one room event could advance multiple steps.") }
                    for (index, trigger) in sequence.enumerated() {
                        let expected = "\(index)"
                        let guardCounter = (try? trigger.nodes(forXPath: ".//Conditions/CounterRange[@Namespace='\(id)'][@Name='Step']"))?.first as? XMLElement
                        if guardCounter?.attribute(forName: "Equal")?.stringValue != expected { result.append("Quest '\(id)' step \(index + 1) has a broken order guard.") }
                    }
                    let completions = sequence.reduce(0) { count, trigger in count + ((try? trigger.nodes(forXPath: ".//Actions/QuestComplete"))?.count ?? 0) }
                    if completions != 1 { result.append("Quest '\(id)' must complete exactly once, on its final step.") }
                }
            }
        }

        for file in xmlFiles(below: projectRoot.appendingPathComponent("custom_missions")) {
            guard let mission = try? XMLDocument(contentsOf: file).rootElement(), mission.name == "CustomMission" else {
                result.append("\(file.lastPathComponent): expected <CustomMission> as the root element."); continue
            }
            let id = attribute(mission, "Id")
            let difficultyText = attribute(mission, "Difficulty")
            let difficulty = Int(difficultyText.isEmpty ? "1" : difficultyText) ?? 0
            let minimum = Int(attribute(mission, "Order")) ?? 0
            let maximum = Int(attribute(mission, "MaximumFloor")) ?? 0
            if id.isEmpty { result.append("\(file.lastPathComponent): mission needs a stable ID.") }
            if !(1...3).contains(difficulty) { result.append("Mission '\(id)' difficulty must be 1, 2 or 3.") }
            if maximum > 0 && maximum < minimum { result.append("Mission '\(id)' ends before its first available floor.") }
            if Int(attribute(mission, "Target")) ?? 0 < 1 { result.append("Mission '\(id)' needs a positive objective target.") }
            if Int(attribute(mission, "Amount")) ?? 0 < 0 { result.append("Mission '\(id)' cannot pay negative credits.") }
            let weightText = attribute(mission, "Weight")
            if (Int(weightText.isEmpty ? "100" : weightText) ?? 0) < 1 { result.append("Mission '\(id)' needs a positive selection weight.") }
        }

        for (chapterID, chapter) in chapters {
            for zone in chapter.elements(forName: "Zone") {
                let id = attribute(zone, "Id")
                if !id.isEmpty && zones[id.lowercased()] == nil {
                    result.append("Chapter '\(chapterID)' references missing zone '\(id)'.")
                }
            }
        }

        for (zoneID, zone) in zones {
            let chapter = attribute(zone, "Chapter")
            if chapter.isEmpty { result.append("Zone '\(zoneID)' has no chapter.") }
            else if chapters[chapter.lowercased()] == nil { result.append("Zone '\(zoneID)' references missing chapter '\(chapter)'.") }

            let rooms = attribute(zone, "RoomsPath")
            if rooms.isEmpty { result.append("Zone '\(zoneID)' needs its own Rooms folder so rooms cannot leak between zones.") }
            else if !safeFolderExists(rooms, below: projectRoot) { result.append("Zone '\(zoneID)' room folder '\(rooms)' does not exist.") }
            else if xmlFiles(below: projectRoot.appendingPathComponent(rooms)).isEmpty { result.append("Zone '\(zoneID)' room folder '\(rooms)' contains no XML rooms.") }

            for key in ["Artwork", "MainBackground", "LoaderBackground"] {
                let image = attribute(zone, key)
                if !image.isEmpty && !images.contains(image.lowercased()) && !images.contains(URL(fileURLWithPath: image).deletingPathExtension().lastPathComponent.lowercased()) {
                    result.append("Zone '\(zoneID)' uses missing \(key) image '\(image)'.")
                }
            }
        }

        let protocolFolder = projectRoot.appendingPathComponent("custom_protocols")
        for file in xmlFiles(below: protocolFolder) {
            guard let document = try? XMLDocument(contentsOf: file), document.rootElement()?.name == "Protocols" else {
                result.append("\(file.lastPathComponent): expected <Protocols> as the root element.")
                continue
            }
            let nodes = (try? document.nodes(forXPath: "/Protocols/Protocol"))?.compactMap { $0 as? XMLElement } ?? []
            if nodes.isEmpty { result.append("\(file.lastPathComponent): contains no protocol.") }
            for node in nodes {
                let id = attribute(node, "Id").isEmpty ? file.deletingPathExtension().lastPathComponent : attribute(node, "Id")
                let chapter = attribute(node, "Chapter")
                if chapter.isEmpty || chapters[chapter.lowercased()] == nil { result.append("Protocol '\(id)' needs an existing chapter.") }
                if Int(attribute(node, "StartFloor")) ?? 0 < 1 { result.append("Protocol '\(id)' needs a start floor of 1 or higher.") }
                for reference in [attribute(node, "PlayerModel")] + node.elements(forName: "Armor").map({ attribute($0, "Model") }) {
                    let clean = reference.replacingOccurrences(of: "custom:", with: "").lowercased()
                    if !clean.isEmpty && !models.contains(clean) { result.append("Protocol '\(id)' references missing model '\(reference)'.") }
                }
                let artwork = attribute(node, "Artwork")
                if !artwork.isEmpty && artwork != "box_unknown" && !images.contains(artwork.lowercased()) && !images.contains(URL(fileURLWithPath: artwork).deletingPathExtension().lastPathComponent.lowercased()) {
                    result.append("Protocol '\(id)' references missing artwork '\(artwork)'.")
                }
            }
        }

        for file in xmlFiles(below: projectRoot.appendingPathComponent("custom_story")) {
            guard let document = try? XMLDocument(contentsOf: file),
                  let graph = (try? document.nodes(forXPath: "//StoryGraph"))?.first as? XMLElement else {
                result.append("\(file.lastPathComponent): expected a StoryGraph.")
                continue
            }
            let graphID = attribute(graph, "Id").isEmpty ? file.deletingPathExtension().lastPathComponent : attribute(graph, "Id")
            let nodes = graph.elements(forName: "Node")
            let nodeIDs = Set(nodes.map { attribute($0, "Id").lowercased() }.filter { !$0.isEmpty })
            let start = attribute(graph, "Start")
            if start.isEmpty || !nodeIDs.contains(start.lowercased()) { result.append("Story '\(graphID)' has no valid starting block.") }
            for node in nodes {
                let type = attribute(node, "Type")
                if type == "Dialogue" {
                    let reference = attribute(node, "Dialogue")
                    if reference.isEmpty || dialogues[reference.lowercased()] == nil { result.append("Story '\(graphID)' references missing dialogue '\(reference)'.") }
                } else if type == "Entrance" {
                    let reference = attribute(node, "Speaker")
                    if reference.isEmpty || characters[reference.lowercased()] == nil { result.append("Story '\(graphID)' references missing character '\(reference)'.") }
                }
                let targets = [attribute(node, "Next"), attribute(node, "True"), attribute(node, "False")]
                    + node.elements(forName: "Choice").map { attribute($0, "Next") }
                for target in targets where !target.isEmpty && !nodeIDs.contains(target.lowercased()) {
                    result.append("Story '\(graphID)' points to missing block '\(target)'.")
                }
            }
        }

        for file in xmlFiles(below: projectRoot.appendingPathComponent("custom_traps")).filter({ $0.lastPathComponent == "manifest.xml" }) {
            guard let document = try? XMLDocument(contentsOf: file), let trap = document.rootElement(), trap.name == "CustomTrap" else {
                result.append("\(file.deletingLastPathComponent().lastPathComponent): expected a CustomTrap manifest.")
                continue
            }
            let id = attribute(trap, "ID")
            let library = attribute(trap, "Library")
            let object = attribute(trap, "Object")
            if id.isEmpty { result.append("A custom trap has no stable ID.") }
            if !library.hasPrefix("v2trap_") || !library.hasSuffix(".xml") { result.append("Trap '\(id)' has an unsafe generated library name.") }
            let compiled = projectRoot.appendingPathComponent("custom_gamedata/run_data/libraries").appendingPathComponent(library)
            guard let compiledDocument = try? XMLDocument(contentsOf: compiled), compiledDocument.rootElement()?.name == "Root" else {
                result.append("Trap '\(id)' needs to be saved and compiled again.")
                continue
            }
            let matches = (try? compiledDocument.nodes(forXPath: "/Root/Objects/Object[@Name='\(object)']")) ?? []
            if object.isEmpty || matches.isEmpty { result.append("Trap '\(id)' compiled without its runtime object.") }
            let artwork = attribute(trap, "Artwork")
            if !artwork.isEmpty && !images.contains(artwork.lowercased()) && !images.contains(URL(fileURLWithPath: artwork).deletingPathExtension().lastPathComponent.lowercased()) {
                result.append("Trap '\(id)' references missing artwork '\(artwork)'.")
            }
        }

        return Array(Set(result)).sorted()
    }

    nonisolated private static func definitions(in folder: URL, xpath: String, id: String) -> [String: XMLElement] {
        var result: [String: XMLElement] = [:]
        for file in xmlFiles(below: folder) {
            guard let document = try? XMLDocument(contentsOf: file) else { continue }
            for node in (try? document.nodes(forXPath: xpath)) ?? [] {
                guard let element = node as? XMLElement else { continue }
                let key = attribute(element, id).lowercased()
                if !key.isEmpty { result[key] = element }
            }
        }
        return result
    }

    nonisolated private static func modelIDs(in folder: URL) -> Set<String> {
        Set(xmlFiles(below: folder).compactMap { file in
            guard file.lastPathComponent == "manifest.xml", let document = try? XMLDocument(contentsOf: file), let root = document.rootElement(), root.name == "CustomModel" else { return nil }
            return root.attribute(forName: "ID")?.stringValue?.lowercased()
        })
    }

    nonisolated private static func imageNames(in root: URL) -> Set<String> {
        var names = Set<String>()
        for folder in ["custom_textures", "custom_backgrounds"] {
            for file in files(below: root.appendingPathComponent(folder)) {
                names.insert(file.lastPathComponent.lowercased())
                names.insert(file.deletingPathExtension().lastPathComponent.lowercased())
            }
        }
        return names
    }

    nonisolated private static func safeFolderExists(_ relative: String, below root: URL) -> Bool {
        let clean = relative.replacingOccurrences(of: "\\", with: "/").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !clean.split(separator: "/").contains("..") else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: root.appendingPathComponent(clean).path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    nonisolated private static func xmlFiles(below folder: URL) -> [URL] { files(below: folder).filter { $0.pathExtension.lowercased() == "xml" } }
    nonisolated private static func files(below folder: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
    }
    nonisolated private static func attribute(_ element: XMLElement, _ name: String) -> String { element.attribute(forName: name)?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
}
