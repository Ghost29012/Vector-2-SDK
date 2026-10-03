import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum StructuralRoomKind: String, CaseIterable, Identifiable {
    case entrance = "Entrance"
    case exit = "Exit"

    var id: String { rawValue }
    var folderName: String { self == .entrance ? "start_rooms" : "finish_rooms" }
    var defaultFilename: String { self == .entrance ? "custom_start_room.xml" : "custom_finish_room.xml" }
    var systemImage: String { self == .entrance ? "figure.run.square.stack" : "door.right.hand.open" }
    var anchorHint: String {
        self == .entrance
            ? "Build a complete opening room with In, Out, DefaultSpawn, camera and your own triggers."
            : "Build a complete ending room with In, Out and your own finish sequence triggers."
    }
}

struct StructuralRoomVariant: Identifiable {
    let id: LevelNode.ID
    let name: String
}

extension LevelDocument {
    var structuralRoomVariants: [StructuralRoomVariant] {
        root.allDescendantsIncludingSelf().compactMap { node in
            guard node.kind == .object,
                  node.xml.choice == "Graphics",
                  !node.xml.variant.isEmpty else { return nil }
            return StructuralRoomVariant(id: node.id, name: node.xml.variant)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func exportedStructuralRoomSelectionElement() -> XMLElement? {
        guard structuralRoomKind != nil else { return nil }
        let names = Array(Set(structuralRoomVariants.map(\.name))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        guard !names.isEmpty else { return nil }
        let selection = XMLElement(name: "Selection")
        let choice = XMLElement(name: "Choice")
        choice.addAttribute(XMLNode.attribute(withName: "Name", stringValue: "Graphics") as! XMLNode)
        choice.addAttribute(XMLNode.attribute(withName: "Visual", stringValue: "1") as! XMLNode)
        for name in names {
            let variant = XMLElement(name: "Variant")
            variant.addAttribute(XMLNode.attribute(withName: "Name", stringValue: name) as! XMLNode)
            choice.addChild(variant)
        }
        selection.addChild(choice)
        return selection
    }

    mutating func createStructuralRoomVariant(named rawName: String) -> String? {
        guard let structuralRoomKind else { return "Open Entrance or Exit Designer first." }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "_")
            .filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
        guard !name.isEmpty else { return "Give this variant a name." }
        guard !structuralRoomVariants.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            return "A variant named \(name) already exists."
        }
        // Gates and the player spawn belong to the room itself. Putting them in
        // Graphics variants creates duplicate gates and changes which Out the
        // runtime uses to attach the next room.
        let ids = Set(movableSelectedNodeIDs).subtracting(unassignedStructuralEssentialIDs(for: structuralRoomKind))
        guard !ids.isEmpty else {
            return "Select the entrance or exit artwork and floor. Gates and spawn stay outside variants."
        }

        var children: [LevelNode] = []
        root.extract(ids: ids, into: &children)
        guard !children.isEmpty else { return "The selected objects could not be moved into the variant." }
        let frames = children.compactMap(\.transform)
        let minX = frames.map(\.x).min() ?? 0
        let minY = frames.map(\.y).min() ?? 0
        let maxX = frames.map { $0.x + $0.width }.max() ?? minX
        let maxY = frames.map { $0.y + $0.height }.max() ?? minY
        children = children.map { source in
            var node = source
            node.markHierarchyAttachment(false)
            return node
        }

        var xml = LevelNode.XMLSummary(template: "Object")
        xml.choice = "Graphics"
        xml.variant = name
        var metadata = LevelNode.Metadata()
        metadata.tag = "Object"
        metadata.visualType = "StructuralRoomVariant"
        metadata.sourceAttributes["EditorStructuralVariant"] = "1"
        let wrapper = LevelNode(
            name: name,
            kind: .object,
            factor: "1",
            transform: .init(
                x: (minX + maxX) / 2,
                y: (minY + maxY) / 2,
                width: maxX - minX,
                height: maxY - minY
            ),
            xml: xml,
            metadata: metadata,
            children: children
        )
        guard root.appendToFirstFactor(wrapper) else {
            for child in children { _ = root.appendToFirstFactor(child) }
            return "This structural room has no scene container."
        }
        activateStructuralRoomVariant(name)
        return nil
    }

    mutating func activateStructuralRoomVariant(_ name: String) {
        activeStructuralVariant = name
        let variants = structuralRoomVariants
        for variant in variants {
            root.update(id: variant.id) { $0.metadata.isHidden = variant.name != name }
        }
        if let selected = variants.first(where: { $0.name == name }) {
            setSelected(ids: [selected.id])
        }
    }

    mutating func showAllStructuralRoomVariants() {
        activeStructuralVariant = nil
        for variant in structuralRoomVariants {
            root.update(id: variant.id) { $0.metadata.isHidden = false }
        }
    }

    mutating func deleteStructuralRoomVariant(_ variant: StructuralRoomVariant) {
        setSelected(ids: [variant.id])
        _ = deleteSelectedNode()
        if activeStructuralVariant == variant.name { activeStructuralVariant = nil }
        showAllStructuralRoomVariants()
    }

    mutating func repairLegacyStructuralMarkers() {
        let topLevel = root.children.flatMap { track in
            track.children.flatMap { child in child.kind == .factor ? child.children : [child] }
        }
        let names = Set(topLevel.map(\.name))
        for variant in structuralRoomVariants {
            root.update(id: variant.id) { wrapper in
                wrapper.children.removeAll { child in
                    names.contains(child.name) &&
                    (child.kind == .gateIn || child.kind == .gateOut ||
                     child.name == "DefaultSpawn" || child.name == "CameraStart" || child.kind == .camera)
                }
            }
        }
    }

    mutating func addStructuralRoomEssentials() {
        guard let kind = structuralRoomKind else { return }
        let existing = unassignedStructuralEssentialIDs(for: kind)
        if !existing.isEmpty {
            setSelected(ids: Array(existing))
            return
        }
        var nodes: [LevelNode] = [
            LevelNode(name: "In", kind: .gateIn, factor: "1", transform: .init(x: 0, y: 0, width: 72, height: 72), xml: .init()),
            LevelNode(name: "Out", kind: .gateOut, factor: "1", transform: .init(x: 2000, y: 0, width: 72, height: 72), xml: .init()),
            LevelNode(name: "Platform", kind: .platform, factor: "1", transform: .init(x: 0, y: 36, width: 2050, height: 860), xml: .init())
        ]
        if kind == .entrance {
            var spawnMetadata = LevelNode.Metadata()
            spawnMetadata.sourceAttributes = ["EditorElement": "Spawn", "Animation": "JumpOff|18"]
            nodes.append(LevelNode(
                name: "DefaultSpawn", kind: .waypoint, factor: "1",
                transform: .init(x: 120, y: -124, width: 72, height: 72),
                xml: .init(), metadata: spawnMetadata
            ))
            nodes.append(LevelNode(name: "", kind: .camera, factor: "1",
                transform: .init(x: 920, y: -44, width: 72, height: 72), xml: .init()))
            nodes.append(structuralReference(name: "CameraStart", x: 680, y: -354))
        } else {
            nodes.append(structuralReference(name: "PauseTimer", x: 1450, y: -120))
            nodes.append(structuralReference(name: "CtrlOut", x: 1580, y: -120))
            nodes.append(structuralReference(name: "Victory", x: 1720, y: -120))
        }
        var inserted: [LevelNode.ID] = []
        for node in nodes {
            if root.appendToFirstFactor(node) { inserted.append(node.id) }
        }
        setSelected(ids: inserted)
    }

    mutating func repairEntranceCamera() {
        guard structuralRoomKind == .entrance else { return }
        let topLevel = root.children.flatMap { track in
            track.children.flatMap { child in child.kind == .factor ? child.children : [child] }
        }
        let originalSpawn = topLevel.first(where: { $0.name == "DefaultSpawn" })?.transform
        if let spawnNode = topLevel.first(where: { $0.name == "DefaultSpawn" }),
           spawnNode.metadata.sourceAttributes["Animation"] == "RunForward|0" {
            root.update(id: spawnNode.id) { $0.metadata.sourceAttributes["Animation"] = "JumpOff|18" }
        }
        var adjustedSpawn = originalSpawn
        if let spawn = originalSpawn,
           let floor = topLevel.compactMap({ node -> LevelNode.Transform? in
               guard node.kind == .platform, let frame = node.transform,
                     spawn.x >= frame.x, spawn.x <= frame.x + frame.width,
                     spawn.y > frame.y - 120, spawn.y < frame.y + frame.height else { return nil }
               return frame
           }).min(by: { abs($0.y - spawn.y) < abs($1.y - spawn.y) }),
           let spawnNode = topLevel.first(where: { $0.name == "DefaultSpawn" }) {
            let safeY = floor.y - 160
            root.update(id: spawnNode.id) { $0.transform?.y = safeY }
            adjustedSpawn?.y = safeY
        }
        let startX = adjustedSpawn?.x ?? 120
        let startY = adjustedSpawn?.y ?? 0
        if !topLevel.contains(where: { $0.kind == .camera }) {
            let camera = LevelNode(name: "", kind: .camera, factor: "1",
                transform: .init(x: startX + 800, y: startY + 80, width: 72, height: 72), xml: .init())
            _ = root.appendToFirstFactor(camera)
        }
        for camera in topLevel where camera.kind == .camera {
            guard let spawn = originalSpawn, let frame = camera.transform,
                  abs(frame.x - spawn.x) < 120, abs(frame.y - spawn.y) < 120 else { continue }
            root.update(id: camera.id) {
                $0.transform?.x = startX + 800
                $0.transform?.y = startY + 80
            }
        }
        for reference in topLevel where reference.name == "CameraStart" && reference.metadata.filename == "triggers.xml" {
            root.update(id: reference.id) { node in
                if let spawn = originalSpawn, let frame = node.transform,
                   abs(frame.x - spawn.x) < 120, abs(frame.y - spawn.y) < 120 {
                    node.transform?.x = startX + 560
                    node.transform?.y = startY - 230
                }
                // Older entrance templates accidentally enlarged this trigger 100-fold.
                guard node.metadata.sourcePropertiesXML.contains("A=\"100"),
                      node.metadata.sourcePropertiesXML.contains("D=\"100") else { return }
                node.metadata.sourcePropertiesXML = ""
                node.metadata.visualNativeWidth = node.transform?.width ?? 100
                node.metadata.visualNativeHeight = node.transform?.height ?? 100
            }
        }
    }

    func structuralRoomExportIssue() -> String? {
        guard let kind = structuralRoomKind else { return nil }
        guard let xml = try? XMLDocument(xmlString: exportedXML(), options: []),
              let track = xml.rootElement()?.elements(forName: "Track").first,
              let content = track.elements(forName: "Content").first else {
            return "The room XML could not be checked."
        }
        let direct = content.children?.compactMap { $0 as? XMLElement } ?? []
        let ins = direct.filter { $0.name == "In" }
        let outs = direct.filter { $0.name == "Out" }
        guard ins.count == 1, outs.count == 1 else {
            return "Keep exactly one In and one Out at the top level. Delete duplicate markers before saving."
        }
        let nested = try? content.nodes(forXPath: ".//Object/Content//In | .//Object/Content//Out")
        if (nested?.count ?? 0) > 0 {
            return "An In or Out is inside an object. Move it to the top level so rooms join correctly."
        }
        if kind == .entrance,
           ((try? content.nodes(forXPath: ".//Spawn[@Name='DefaultSpawn']"))?.count ?? 0) != 1 {
            return "The entrance needs exactly one DefaultSpawn."
        }
        let floors = (try? content.nodes(forXPath: ".//Platform | .//Trapezoid"))?.count ?? 0
        guard floors > 0 else { return "Add a floor platform before saving. The current room only has markers, so it appears empty in game." }
        return nil
    }

    var structuralRoomHasVisibleArtwork: Bool {
        guard let xml = try? XMLDocument(xmlString: exportedXML(), options: []),
              let content = try? xml.nodes(forXPath: "/Root/Track/Content").first else { return false }
        return ((try? content.nodes(forXPath: ".//Image | .//ObjectReference[not(@Filename='triggers.xml')]"))?.count ?? 0) > 0
    }

    private func unassignedStructuralEssentialIDs(for kind: StructuralRoomKind) -> Set<LevelNode.ID> {
        let required: Set<String> = kind == .entrance
            ? ["In", "Out", "DefaultSpawn", "CameraStart"]
            : ["In", "Out", "PauseTimer", "CtrlOut", "Victory"]
        let topLevel = root.children.flatMap { track in
            track.children.flatMap { child in child.kind == .factor ? child.children : [child] }
        }
        return Set(topLevel.filter { required.contains($0.name) }.map(\.id))
    }

    private func structuralReference(name: String, x: Int, y: Int) -> LevelNode {
        var metadata = LevelNode.Metadata()
        metadata.filename = "triggers.xml"
        metadata.libraryObjectName = name
        metadata.visualType = "RoomWeaverLibraryReference"
        metadata.visualNativeWidth = 100
        metadata.visualNativeHeight = 100
        var xml = LevelNode.XMLSummary(template: "LibraryObject")
        xml.choice = "triggers.xml"
        xml.variant = "Resolved"
        return LevelNode(
            name: name,
            kind: .objectReference,
            factor: "1",
            transform: .init(x: x, y: y, width: 100, height: 100),
            xml: xml,
            metadata: metadata
        )
    }
}

struct StructuralRoomStudioBar: View {
    @Binding var document: LevelDocument
    let saveRequest: Int
    let onStatus: (String) -> Void
    @State private var selectedZoneID = ""
    @State private var zones: [ZoneDestination] = []
    @State private var confirmNew = false
    @State private var confirmOverwrite = false
    @State private var saveFeedback = ""

    private struct ZoneDestination: Identifiable {
        let id: String
        let name: String
        let roomsPath: String
    }

    private var kind: StructuralRoomKind { document.structuralRoomKind ?? .entrance }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Label("\(kind.rawValue) Designer", systemImage: kind.systemImage)
                    .font(.system(size: 13, weight: .bold))
                Text("Build the whole room on this canvas. In and Out join it to the run.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                TextField("File name", text: $document.name)
                    .textFieldStyle(.roundedBorder).frame(width: 190)
                if zones.count > 1 {
                    Picker("Zone", selection: $selectedZoneID) {
                        Text("Choose zone").tag("")
                        ForEach(zones) { zone in Text(zone.name).tag(zone.id) }
                    }
                    .frame(width: 190)
                }
                Button("New Room") { confirmNew = true }
                Button("Open…", action: openStructuralRoom)
                Button("Save to Zone") { saveToProject() }.buttonStyle(.borderedProminent)
                    .disabled(selectedZoneID.isEmpty)
            }
            .padding(.horizontal, 14).frame(height: 42)
            Divider()
            HStack(spacing: 10) {
                Text(zones.count > 1 ? "1. Choose a zone   2. Draw the route and add art   3. Save to Zone" : "Draw the route and add art, then save to the game.")
                    .font(.caption).foregroundStyle(.secondary)
                if !saveFeedback.isEmpty {
                    Text(saveFeedback).font(.caption).lineLimit(2)
                        .foregroundStyle(saveFeedback.hasPrefix("Installed") ? .green : .orange)
                }
                Spacer()
                if !document.structuralRoomVariants.isEmpty {
                    Text("Older variant room opened; its gates must be outside variant objects.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 14).frame(height: 48)
        }
        .background(Color.editorChromeBackground)
        .onAppear {
            zones = loadZones()
            if zones.count == 1 { selectedZoneID = zones[0].id }
            if let path = document.sourcePath,
               let match = zones.first(where: { path.contains("/\($0.roomsPath)/") }) { selectedZoneID = match.id }
        }
        .onChange(of: saveRequest) { _, _ in saveToProject() }
        .confirmationDialog("Replace the existing \(kind.rawValue.lowercased()) room?", isPresented: $confirmOverwrite) {
            Button("Replace Room", role: .destructive) { saveToProject(replacingExisting: true) }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("A room with this filename already exists in the selected zone. Replacing it updates both the project and the connected game copy.")
        }
        .confirmationDialog("Start a new \(kind.rawValue.lowercased()) room?", isPresented: $confirmNew) {
            Button("New Room") { document = .structuralRoomStudio(kind) }
        } message: {
            Text("This replaces the current unsaved canvas. Saved room files stay in the project.")
        }
    }

    private func projectRoot() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: "projectManager.lastProjectBookmark") else { return nil }
        var stale = false
        return try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
    }

    private func loadZones() -> [ZoneDestination] {
        guard let root = projectRoot() else { return [] }
        let folder = root.appendingPathComponent("custom_zones")
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return [] }
        return files.filter { $0.pathExtension.lowercased() == "xml" }.flatMap { file -> [ZoneDestination] in
            guard let xml = try? XMLDocument(contentsOf: file),
                  let nodes = try? xml.nodes(forXPath: "//Zone") else { return [] }
            return nodes.compactMap { node -> ZoneDestination? in
                guard let item = node as? XMLElement,
                      let id = item.attribute(forName: "Id")?.stringValue,
                      !id.isEmpty else { return nil }
                let rawPath = item.attribute(forName: "RoomsPath")?.stringValue ?? ""
                let path = rawPath.isEmpty ? "custom_rooms/\(id)" : rawPath
                let parts = path.replacingOccurrences(of: "\\", with: "/").split(separator: "/")
                guard parts.first == "custom_rooms", !parts.contains("..") else { return nil }
                let name = item.attribute(forName: "Name")?.stringValue ?? id
                return ZoneDestination(id: id, name: name, roomsPath: parts.joined(separator: "/"))
            }
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func saveToProject(replacingExisting: Bool = false) {
        func report(_ message: String) {
            saveFeedback = message
            onStatus(message)
        }
        document.repairEntranceCamera()
        if let issue = document.structuralRoomExportIssue() {
            report(issue)
            return
        }
        guard let root = projectRoot() else {
            report("Open a project in Project Manager first.")
            return
        }
        let scoped = root.startAccessingSecurityScopedResource()
        defer { if scoped { root.stopAccessingSecurityScopedResource() } }
        guard let zone = zones.first(where: { $0.id == selectedZoneID }) else {
            report("Choose the zone this room belongs to.")
            return
        }
        let roomPool = root.appendingPathComponent(zone.roomsPath, isDirectory: true)
        let folder = roomPool
            .appendingPathComponent(kind.folderName, isDirectory: true)
        let safeName = URL(fileURLWithPath: document.name).lastPathComponent
        let filename = safeName.lowercased().hasSuffix(".xml") ? safeName : safeName + ".xml"
        let target = folder.appendingPathComponent(filename)
        do {
            if FileManager.default.fileExists(atPath: target.path),
               document.sourcePath != target.path,
               !replacingExisting {
                confirmOverwrite = true
                return
            }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try document.exportedXML().write(to: target, atomically: true, encoding: .utf8)
            document.name = target.lastPathComponent
            document.sourcePath = target.path
            let projectSettings = try? XMLDocument(contentsOf: root.appendingPathComponent("project.xml"))
            guard let gamePath = projectSettings?.rootElement()?.attribute(forName: "GameDataPath")?.stringValue,
                  !gamePath.isEmpty else {
                report("Saved to project, but this project has no Vector 2 Data folder. Connect it in Project Manager.")
                return
            }
            let configuredGameRoot = URL(fileURLWithPath: gamePath, isDirectory: true).standardizedFileURL
            let gameRoot: URL
            if let data = UserDefaults.standard.data(forKey: "projectManager.gameDataBookmark") {
                var stale = false
                let bookmarked = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
                if let bookmarked, !stale, bookmarked.standardizedFileURL.path == configuredGameRoot.path {
                    gameRoot = bookmarked
                } else {
                    guard let selected = reauthorizeConfiguredGameRoot(configuredGameRoot, report: report) else { return }
                    gameRoot = selected
                }
            } else {
                guard let selected = reauthorizeConfiguredGameRoot(configuredGameRoot, report: report) else { return }
                gameRoot = selected
            }
            guard gameRoot.standardizedFileURL.path == configuredGameRoot.path,
                  (FileManager.default.fileExists(atPath: gameRoot.appendingPathComponent("userdata").path)
                    || FileManager.default.fileExists(atPath: gameRoot.appendingPathComponent("gamedata").path)
                    || FileManager.default.fileExists(atPath: gameRoot.appendingPathComponent("custom_rooms").path)) else {
                report("Saved to project, but the configured game folder is no longer valid. Reconnect Vector 2 Data in Project Manager.")
                return
            }
            let gameScoped = gameRoot.startAccessingSecurityScopedResource()
            guard gameScoped else {
                report("Saved to project, but macOS denied access to the configured Vector 2 Data folder. Reconnect it in Project Manager: \(configuredGameRoot.path)")
                return
            }
            defer { if gameScoped { gameRoot.stopAccessingSecurityScopedResource() } }
            do {
                let relative = "\(zone.roomsPath)/\(kind.folderName)/\(filename)"
                let gameTarget = try StructuralRoomGameInstaller.install(room: target, projectRoot: root, gameRoot: gameRoot, relativePath: relative)
                let artworkWarning = document.structuralRoomHasVisibleArtwork ? "" : " No visible artwork yet; the room may look empty in game."
                report("Installed \(filename) in Vector 2 Data: \(gameTarget.path).\(artworkWarning)")
            } catch {
                report("Saved to project, but game install failed: \(error.localizedDescription)")
            }
        } catch {
            report("Could not save structural room: \(error.localizedDescription)")
        }
    }

    private func reauthorizeConfiguredGameRoot(_ expected: URL, report: (String) -> Void) -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Reconnect Vector 2 Data"
        panel.message = "Select the same Vector 2 Data folder configured in this project so the room can be installed there."
        panel.prompt = "Allow Game Install"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = expected
        guard panel.runModal() == .OK, let selected = panel.url else {
            report("Saved to project, but game install needs access to: \(expected.path)")
            return nil
        }
        guard selected.standardizedFileURL.path == expected.path else {
            report("Saved to project, but that is not this project's configured Vector 2 Data folder: \(expected.path)")
            return nil
        }
        guard let bookmark = try? selected.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) else {
            report("Saved to project, but macOS did not grant access to: \(expected.path)")
            return nil
        }
        UserDefaults.standard.set(bookmark, forKey: "projectManager.gameDataBookmark")
        return selected
    }

    private func openStructuralRoom() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.xml]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        if let root = projectRoot() {
            if let zone = zones.first(where: { $0.id == selectedZoneID }) {
                panel.directoryURL = root.appendingPathComponent(zone.roomsPath).appendingPathComponent(kind.folderName)
            }
        }
        guard panel.runModal() == .OK, let url = panel.url,
              var loaded = LevelDocument.loadFromXML(at: url.path) else { return }
        loaded.structuralRoomKind = kind
        loaded.name = url.lastPathComponent
        loaded.sourcePath = url.path
        loaded.repairLegacyStructuralMarkers()
        loaded.repairEntranceCamera()
        loaded.showAllStructuralRoomVariants()
        document = loaded
        if let zone = zones.first(where: { url.path.contains("/\($0.roomsPath)/") }) { selectedZoneID = zone.id }
        onStatus("Opened \(url.lastPathComponent) in \(kind.rawValue) Designer.")
    }
}
