import SwiftUI
import Foundation

/// Edits the room-local pieces consumed by Vector 2's ControllerSwarm and
/// WaypointRunner. The global swarm bodies remain data-driven in swarms.xml.
struct SwarmDesignerView: View {
    @Binding var document: LevelDocument
    let gameDirectory: String
    let onClose: () -> Void
    let onStatus: (String) -> Void

    @State private var section = Section.setup
    @State private var selectedWaypointID = ""
    @State private var destinationID = ""
    @State private var edgeDelay = ""
    @State private var edgeSpeedDelta = ""
    @State private var swarmNames: [String] = []
    @State private var selectedSwarm = "Test"

    private enum Section: String, CaseIterable, Identifiable {
        case setup = "Setup"
        case path = "Path"
        case validation = "Check"
        var id: String { rawValue }
    }

    private var waypoints: [LevelNode] {
        document.root.allDescendantsIncludingSelf().filter { $0.kind == .waypoint && $0.metadata.tag == "Waypoint" }
    }

    private var selectedWaypoint: LevelNode? {
        guard let id = UUID(uuidString: selectedWaypointID) else { return nil }
        return document.root.find(id: id)
    }

    private var activators: [LevelNode] { libraryReferences(named: "SwarmActivator") }
    private var holes: [LevelNode] { libraryReferences(named: "SwarmHole") }
    private var deactivators: [LevelNode] { libraryReferences(named: "SwarmDeactivator") }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Swarm Designer").font(.system(size: 22, weight: .bold))
                    Text("Build the activator, hole, and waypoint path Vector 2 actually uses.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close", action: onClose)
            }
            .padding(20)

            Picker("Section", selection: $section) {
                ForEach(Section.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)
            .padding(.bottom, 14)

            Divider()
            ScrollView {
                Group {
                    switch section {
                    case .setup: setupView
                    case .path: pathView
                    case .validation: validationView
                    }
                }
                .padding(20)
            }
        }
        .frame(minWidth: 720, idealWidth: 820, minHeight: 600, idealHeight: 720)
        .onAppear {
            repairSwarmVisuals()
            loadSwarmCatalog()
            seedSelection()
        }
    }

    private var setupView: some View {
        VStack(alignment: .leading, spacing: 18) {
            GroupBox("Quick setup") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Creates a working SwarmHole, SwarmActivator, Start, and End. You can drag every piece on the normal canvas afterward.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    HStack {
                        Picker("Swarm", selection: $selectedSwarm) {
                            ForEach(swarmNames.isEmpty ? ["Test"] : swarmNames, id: \.self) { Text($0).tag($0) }
                        }
                        .frame(maxWidth: 280)
                        Spacer()
                        Button("Create Basic Swarm") { createBasicSwarm() }
                            .buttonStyle(.borderedProminent)
                    }
                }.padding(8)
            }

            GroupBox("Room pieces") {
                VStack(spacing: 10) {
                    pieceRow("Activator", count: activators.count, required: true)
                    pieceRow("Swarm hole", count: holes.count, required: true)
                    pieceRow("Deactivator", count: deactivators.count, required: false)
                    pieceRow("Waypoints", count: waypoints.count, required: true)
                }.padding(8)
            }

            HStack {
                Button("Add Activator") { addReference(name: "SwarmActivator", file: "triggers.xml") }
                Button("Add Swarm Hole") { addReference(name: "SwarmHole", file: "traps.xml") }
                Button("Add Deactivator") { addReference(name: "SwarmDeactivator", file: "triggers.xml") }
                Spacer()
            }
        }
    }

    private var pathView: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Waypoints").font(.headline)
                    Spacer()
                    Button("Add") { addWaypoint() }
                }
                ForEach(waypoints) { waypoint in
                    Button {
                        selectedWaypointID = waypoint.id.uuidString
                        document.select(waypoint.id)
                        seedDestination()
                    } label: {
                        HStack {
                            Image(systemName: waypoint.name == "Start" ? "play.circle.fill" : "mappin.circle")
                            Text(waypoint.name)
                            Spacer()
                            Text("\(connections(for: waypoint).count) link\(connections(for: waypoint).count == 1 ? "" : "s")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(8)
                        .background(selectedWaypointID == waypoint.id.uuidString ? Color.accentColor.opacity(0.14) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(width: 250)

            Divider()

            if let waypoint = selectedWaypoint {
                waypointEditor(waypoint)
            } else {
                ContentUnavailableView("Select a waypoint", systemImage: "point.topleft.down.to.point.bottomright.curvepath", description: Text("Add or select a waypoint to edit its route."))
            }
        }
    }

    private func waypointEditor(_ waypoint: LevelNode) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(waypoint.name).font(.title2.bold())
                Spacer()
                Button("Show on Canvas") { document.select(waypoint.id) }
            }

            GroupBox("Movement") {
                VStack(spacing: 10) {
                    editableAttributeRow("Spawn X", key: "SpawnX", node: waypoint)
                    editableAttributeRow("Spawn Y", key: "SpawnY", node: waypoint)
                    editableAttributeRow("Spawn delay", key: "SpawnDelay", node: waypoint)
                    editableMotionRow("Speed", key: "Speed", node: waypoint)
                    editableMotionRow("Start acceleration", key: "StartAccFrames", node: waypoint)
                    editableMotionRow("Stop acceleration", key: "StopAccFrames", node: waypoint)
                    editableAttributeRow("Event key", key: "WaypointKey", node: waypoint)
                }.padding(8)
            }

            GroupBox("Outgoing paths") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(connections(for: waypoint).enumerated()), id: \.offset) { index, edge in
                        HStack {
                            Image(systemName: "arrow.right")
                            Text(edge.name)
                            if !edge.delay.isEmpty { Text("delay \(edge.delay)").foregroundStyle(.secondary) }
                            if !edge.speedDelta.isEmpty { Text("speed Δ \(edge.speedDelta)").foregroundStyle(.secondary) }
                            Spacer()
                            Button(role: .destructive) { removeConnection(at: index, from: waypoint) } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                        }
                    }

                    Divider()
                    Picker("Destination", selection: $destinationID) {
                        Text("Next room").tag("next_room")
                        ForEach(waypoints.filter { $0.id != waypoint.id }) { Text($0.name).tag($0.id.uuidString) }
                    }
                    HStack {
                        TextField("Delay frames", text: $edgeDelay)
                        TextField("Speed change", text: $edgeSpeedDelta)
                        Button("Add Path") { addConnection(from: waypoint) }
                            .buttonStyle(.borderedProminent)
                            .disabled(destinationID.isEmpty)
                    }
                }.padding(8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var validationView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(validationIssues.isEmpty ? "Swarm setup looks valid" : "Found \(validationIssues.count) issue\(validationIssues.count == 1 ? "" : "s")")
                .font(.title2.bold())
            if validationIssues.isEmpty {
                Label("The room has an activator, hole, unique Start waypoint, and valid path links.", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            } else {
                ForEach(validationIssues, id: \.self) { issue in
                    Label(issue, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
            Divider()
            Text("Vector 2 follows the first enabled destination listed on a waypoint. Multiple links are branches, not simultaneous swarm copies.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    private struct Edge: Equatable { var name: String; var delay: String; var speedDelta: String }

    private var validationIssues: [String] {
        var issues: [String] = []
        if activators.isEmpty { issues.append("Missing SwarmActivator") }
        if holes.isEmpty { issues.append("Missing SwarmHole") }
        let starts = waypoints.filter { $0.name == "Start" || $0.metadata.sourceAttributes["Type"] == "Start" }
        if starts.isEmpty { issues.append("Missing Start waypoint") }
        if starts.count > 1 { issues.append("More than one Start waypoint") }
        let duplicates = Dictionary(grouping: waypoints, by: { $0.name }).filter { !$0.key.isEmpty && $0.value.count > 1 }.keys.sorted()
        if !duplicates.isEmpty { issues.append("Duplicate waypoint names: \(duplicates.joined(separator: ", "))") }
        let names = Set(waypoints.map(\.name)).union(["next_room"])
        for waypoint in waypoints {
            for edge in connections(for: waypoint) where !names.contains(edge.name) {
                issues.append("\(waypoint.name) links to missing \(edge.name)")
            }
        }
        if let start = starts.first, connections(for: start).isEmpty { issues.append("Start has no outgoing path") }
        return issues
    }

    private func pieceRow(_ title: String, count: Int, required: Bool) -> some View {
        HStack {
            Image(systemName: count > 0 ? "checkmark.circle.fill" : (required ? "exclamationmark.circle.fill" : "circle"))
                .foregroundStyle(count > 0 ? .green : (required ? .orange : .secondary))
            Text(title)
            Spacer()
            Text("\(count)").foregroundStyle(.secondary)
        }
    }

    private func libraryReferences(named name: String) -> [LevelNode] {
        document.root.allDescendantsIncludingSelf().filter {
            $0.kind == .objectReference && ($0.metadata.libraryObjectName == name || $0.name == name)
        }
    }

    private func seedSelection() {
        if selectedWaypointID.isEmpty { selectedWaypointID = waypoints.first(where: { $0.name == "Start" })?.id.uuidString ?? waypoints.first?.id.uuidString ?? "" }
        seedDestination()
    }

    private func seedDestination() {
        guard let selectedWaypoint else { destinationID = ""; return }
        destinationID = waypoints.first(where: { $0.id != selectedWaypoint.id })?.id.uuidString ?? "next_room"
    }

    /// Upgrades the placeholder references created by the old binder/designer
    /// without changing their IDs, positions, overrides, or export identity.
    private func repairSwarmVisuals() {
        let targets = document.root.allDescendantsIncludingSelf().filter { node in
            node.kind == .objectReference && ["SwarmActivator", "SwarmHole", "SwarmDeactivator"].contains(node.metadata.libraryObjectName.isEmpty ? node.name : node.metadata.libraryObjectName)
        }
        for snapshot in targets {
            let name = snapshot.metadata.libraryObjectName.isEmpty ? snapshot.name : snapshot.metadata.libraryObjectName
            let file = snapshot.metadata.filename.isEmpty ? (name == "SwarmHole" ? "traps.xml" : "triggers.xml") : snapshot.metadata.filename
            let x = snapshot.transform?.x ?? 0
            let y = snapshot.transform?.y ?? 0
            let rotation = snapshot.transform?.rotation ?? 0
            let resolved = makeReference(name: name, file: file, x: x, y: y)
            guard !resolved.previewPieces.isEmpty || !resolved.children.isEmpty || !resolved.metadata.imagePath.isEmpty else { continue }
            document.root.update(id: snapshot.id) { node in
                node.transform = resolved.transform.map { .init(x: $0.x, y: $0.y, width: $0.width, height: $0.height, rotation: rotation) }
                node.metadata.sortingLayer = resolved.metadata.sortingLayer
                node.metadata.imagePath = resolved.metadata.imagePath
                node.metadata.visualOffsetX = resolved.metadata.visualOffsetX
                node.metadata.visualOffsetY = resolved.metadata.visualOffsetY
                node.metadata.visualNativeWidth = resolved.metadata.visualNativeWidth
                node.metadata.visualNativeHeight = resolved.metadata.visualNativeHeight
                node.metadata.visualType = resolved.metadata.visualType
                node.metadata.dynamicXML = resolved.metadata.dynamicXML
                node.metadata.filename = file
                node.metadata.className = name
                node.metadata.libraryObjectName = name
                node.previewPieces = resolved.previewPieces
                node.children = resolved.children
            }
        }
    }

    private func createBasicSwarm() {
        let existingNames = Set(waypoints.map(\.name))
        let startName = uniqueName("Start", used: existingNames)
        let endName = uniqueName("End", used: existingNames.union([startName]))
        let start = makeWaypoint(name: startName, x: 300, y: -300, type: "Start", next: Edge(name: endName, delay: "", speedDelta: ""))
        let end = makeWaypoint(name: endName, x: 1000, y: -300, type: "", next: Edge(name: "next_room", delay: "", speedDelta: ""))
        var activator = makeReference(name: "SwarmActivator", file: "triggers.xml", x: 180, y: -520)
        activator.metadata.libraryOverrides["SpawnPoint"] = startName
        activator.metadata.sourceAttributes["SwarmName"] = selectedSwarm
        append([makeReference(name: "SwarmHole", file: "traps.xml", x: 300, y: 0), activator, start, end])
        selectedWaypointID = start.id.uuidString
        document.select(start.id)
        onStatus("Created basic swarm path from \(startName) to \(endName)")
        section = .path
    }

    private func addReference(name: String, file: String) {
        let offset = document.root.flattenedSceneNodes().count * 24
        let node = makeReference(name: name, file: file, x: 300 + offset, y: -500)
        append([node]); document.select(node.id); onStatus("Added \(name)")
    }

    private func addWaypoint() {
        let used = Set(waypoints.map(\.name))
        let name = uniqueName("Waypoint", used: used)
        let node = makeWaypoint(name: name, x: 500 + waypoints.count * 180, y: -300, type: "", next: nil)
        append([node]); selectedWaypointID = node.id.uuidString; document.select(node.id); seedDestination(); onStatus("Added \(name)")
    }

    private func append(_ nodes: [LevelNode]) {
        for node in nodes where !document.root.appendToFirstFactor(node) {
            document.root.children.append(LevelNode(name: "Track", kind: .track, factor: "1", transform: nil, xml: .init(), children: [LevelNode(name: "Object Factor = 1", kind: .factor, factor: "1", transform: nil, xml: .init(), children: [node])]))
        }
    }

    private func makeReference(name: String, file: String, x: Int, y: Int) -> LevelNode {
        let baseURL = document.sourcePath
            .map { URL(fileURLWithPath: $0).deletingLastPathComponent() }
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        if var resolved = Vector2LibraryObjectBuilder.reconstructReference(
            name: name,
            filename: file,
            originX: x,
            originY: y,
            baseURL: baseURL,
            settings: nil
        ) {
            resolved.name = name
            resolved.kind = .objectReference
            resolved.factor = "1"
            resolved.xml = .init(template: "ObjectReference", choice: file, variant: "Resolved")
            resolved.metadata.tag = "ObjectReference"
            resolved.metadata.filename = file
            resolved.metadata.className = name
            resolved.metadata.libraryObjectName = name
            return resolved
        }
        return LevelNode(name: name, kind: .objectReference, factor: "1", transform: .init(x: x, y: y, width: 100, height: 100), xml: .init(template: "ObjectReference", choice: file, variant: "Unresolved"), metadata: .init(tag: "ObjectReference", filename: file, className: name, libraryObjectName: name))
    }

    private func makeWaypoint(name: String, x: Int, y: Int, type: String, next: Edge?) -> LevelNode {
        var metadata = LevelNode.Metadata(tag: "Waypoint")
        metadata.sourceAttributes = ["SpawnX": "0", "SpawnY": "0", "SpawnDelay": "0"]
        if !type.isEmpty { metadata.sourceAttributes["Type"] = type }
        metadata.sourcePropertiesXML = propertiesXML(edges: next.map { [$0] } ?? [], motion: [:])
        return LevelNode(name: name, kind: .waypoint, factor: "1", transform: .init(x: x, y: y, width: 80, height: 80), xml: .init(template: "Waypoint", choice: "Swarm", variant: "Default"), metadata: metadata)
    }

    private func uniqueName(_ base: String, used: Set<String>) -> String {
        if !used.contains(base) { return base }
        var index = 2
        while used.contains("\(base)\(index)") { index += 1 }
        return "\(base)\(index)"
    }

    private func connections(for node: LevelNode) -> [Edge] {
        guard let doc = try? XMLDocument(xmlString: node.metadata.sourcePropertiesXML),
              let next = (try? doc.nodes(forXPath: "/Properties/Static/Next/Waypoint")) else { return [] }
        return next.compactMap { item in
            guard let element = item as? XMLElement, let name = element.attribute(forName: "Name")?.stringValue, !name.isEmpty else { return nil }
            return Edge(name: name, delay: element.attribute(forName: "Delay")?.stringValue ?? "", speedDelta: element.attribute(forName: "SpeedDelta")?.stringValue ?? "")
        }
    }

    private func motion(for node: LevelNode) -> [String: String] {
        guard let doc = try? XMLDocument(xmlString: node.metadata.sourcePropertiesXML),
              let element = (try? doc.nodes(forXPath: "/Properties/Static/Motion").first) as? XMLElement else { return [:] }
        return Dictionary(uniqueKeysWithValues: (element.attributes ?? []).compactMap { attribute in attribute.name.map { ($0, attribute.stringValue ?? "") } })
    }

    private func addConnection(from node: LevelNode) {
        let name: String
        if destinationID == "next_room" { name = destinationID }
        else if let id = UUID(uuidString: destinationID), let destination = document.root.find(id: id) { name = destination.name }
        else { return }
        var edges = connections(for: node)
        guard !edges.contains(where: { $0.name == name }) else { onStatus("\(node.name) already links to \(name)"); return }
        edges.append(Edge(name: name, delay: edgeDelay, speedDelta: edgeSpeedDelta))
        updateProperties(of: node, edges: edges, motion: motion(for: node))
        edgeDelay = ""; edgeSpeedDelta = ""; onStatus("Linked \(node.name) to \(name)")
    }

    private func removeConnection(at index: Int, from node: LevelNode) {
        var edges = connections(for: node)
        guard edges.indices.contains(index) else { return }
        let removed = edges.remove(at: index)
        updateProperties(of: node, edges: edges, motion: motion(for: node))
        onStatus("Removed path from \(node.name) to \(removed.name)")
    }

    private func updateProperties(of node: LevelNode, edges: [Edge], motion: [String: String]) {
        document.root.update(id: node.id) { $0.metadata.sourcePropertiesXML = propertiesXML(edges: edges, motion: motion) }
    }

    private func propertiesXML(edges: [Edge], motion: [String: String]) -> String {
        let properties = XMLElement(name: "Properties")
        let staticElement = XMLElement(name: "Static")
        let next = XMLElement(name: "Next")
        for edge in edges {
            let element = XMLElement(name: "Waypoint")
            element.addAttribute(XMLNode.attribute(withName: "Name", stringValue: edge.name) as! XMLNode)
            if !edge.delay.isEmpty { element.addAttribute(XMLNode.attribute(withName: "Delay", stringValue: edge.delay) as! XMLNode) }
            if !edge.speedDelta.isEmpty { element.addAttribute(XMLNode.attribute(withName: "SpeedDelta", stringValue: edge.speedDelta) as! XMLNode) }
            next.addChild(element)
        }
        staticElement.addChild(next)
        if !motion.isEmpty {
            let element = XMLElement(name: "Motion")
            for key in ["StartAccFrames", "StopAccFrames", "Speed"] where !(motion[key] ?? "").isEmpty {
                element.addAttribute(XMLNode.attribute(withName: key, stringValue: motion[key] ?? "") as! XMLNode)
            }
            staticElement.addChild(element)
        }
        properties.addChild(staticElement)
        return properties.xmlString(options: .nodeCompactEmptyElement)
    }

    private func editableAttributeRow(_ title: String, key: String, node: LevelNode) -> some View {
        let value = Binding(get: { document.root.find(id: node.id)?.metadata.sourceAttributes[key] ?? "" }, set: { newValue in document.root.update(id: node.id) { $0.metadata.sourceAttributes[key] = newValue } })
        return HStack { Text(title).frame(width: 150, alignment: .leading); TextField("Optional", text: value).textFieldStyle(.roundedBorder) }
    }

    private func editableMotionRow(_ title: String, key: String, node: LevelNode) -> some View {
        let value = Binding(get: { motion(for: document.root.find(id: node.id) ?? node)[key] ?? "" }, set: { newValue in var values = motion(for: document.root.find(id: node.id) ?? node); values[key] = newValue; updateProperties(of: document.root.find(id: node.id) ?? node, edges: connections(for: document.root.find(id: node.id) ?? node), motion: values) })
        return HStack { Text(title).frame(width: 150, alignment: .leading); TextField("Default", text: value).textFieldStyle(.roundedBorder) }
    }

    private func loadSwarmCatalog() {
        var candidates: [URL] = []
        if !gameDirectory.isEmpty {
            let base = URL(fileURLWithPath: gameDirectory)
            candidates += [base.appendingPathComponent("Assets/Resources/gamedata/run_data/libraries/swarms.xml"), base.appendingPathComponent("Resources/gamedata/run_data/libraries/swarms.xml")]
        }
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            if let doc = try? XMLDocument(contentsOf: url), let nodes = try? doc.nodes(forXPath: "/Root/Objects/Swarm") {
                let names = nodes.compactMap { ($0 as? XMLElement)?.attribute(forName: "Name")?.stringValue }.filter { !$0.isEmpty }
                if !names.isEmpty { swarmNames = Array(Set(names)).sorted(); selectedSwarm = swarmNames.first ?? "Test"; return }
            }
        }
        swarmNames = ["Test"]
    }
}
