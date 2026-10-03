//
//  XMLSceneParser.swift
//  Vector2 level editor
//
//  XML import and sample-room loading.
//
//  Runtime Graph is the "do not normalize Vector 2's weird XML" path. It keeps
//  coordinates and node shapes as close to the file as possible, then asks the
//  visual builders to make advanced library stuff visible. Windows needs to copy
//  this behavior instead of trying to be clever, because tiny coordinate changes
//  can break rooms in-game.
//

import SwiftUI
import AppKit
import Foundation

enum WorkspaceLevelSources {
    static var room201: String {
        pathForBundledOrWorkspaceAsset("Assets/Resources/gamedata/run_data/rooms/zone_2/room201.xml")
    }

    static var triggers: String {
        pathForBundledOrWorkspaceAsset("Assets/Resources/gamedata/run_data/libraries/triggers.xml")
    }

    static var objects: String {
        pathForBundledOrWorkspaceAsset("Assets/Resources/gamedata/run_data/libraries/objects_items.xml")
    }

    @MainActor
    static func defaultDocuments() -> [LevelDocument] {
        let parsed = [room201, triggers, objects].compactMap(LevelDocument.loadFromXML(at:))
        return parsed.isEmpty ? [
            .sampleRoom201,
            .sampleTriggers,
            .sampleObjects
        ] : parsed
    }

    private static func pathForBundledOrWorkspaceAsset(_ relativePath: String) -> String {
        let fileManager = FileManager.default
        for root in workspaceRoots() {
            let candidate = root.appendingPathComponent(relativePath)
            if fileManager.fileExists(atPath: candidate.path) {
                return candidate.path
            }
        }
        return relativePath
    }

    private static func workspaceRoots() -> [URL] {
        let fileManager = FileManager.default
        var starts: [URL] = [
            URL(fileURLWithPath: fileManager.currentDirectoryPath)
        ]
        if let resourceURL = Bundle.main.resourceURL {
            starts.append(resourceURL)
        }
        if let explicitRoot = ProcessInfo.processInfo.environment["VECTOR2_WORKSPACE_ROOT"], !explicitRoot.isEmpty {
            starts.insert(URL(fileURLWithPath: explicitRoot), at: 0)
        }

        var roots: [URL] = []
        for start in starts {
            var current = start.standardizedFileURL
            for _ in 0..<10 {
                if fileManager.fileExists(atPath: current.appendingPathComponent(relativePathProbe).path) {
                    roots.append(current)
                }
                let parent = current.deletingLastPathComponent()
                if parent.path == current.path { break }
                current = parent
            }
        }
        var seen: Set<String> = []
        return roots.filter { seen.insert($0.path).inserted }
    }

    private static let relativePathProbe = "Assets/Resources/gamedata/run_data"
}

// MARK: - XML Import Pipeline

/// First-pass XML loader for room/buildmap files.
///
/// This parser keeps the raw Vector 2 hierarchy understandable for editing:
/// document/track/factor containers are preserved, while gameplay elements are
/// turned into `LevelNode`s with transform, XML summary, and metadata. It does
/// not try to fully render library objects; it delegates those visual-heavy
/// cases to the builders below.
enum XMLSceneParser {
    private static let sceneTags: Set<String> = [
        "Track",
        "Objects",
        "Object",
        "ObjectReference",
        "Image",
        "CustomAnimation",
        "Platform",
        "Trapezoid",
        "Trigger",
        "Area",
        "Spawn",
        "In",
        "Out",
        "Camera",
        "Dynamic",
        "DynamicTrigger",
        "UnityModel"
    ]

    /// Reads a room XML file and creates an editable document.
    ///
    /// Coordinate correctness lives here. If an imported level is shifted,
    /// flipped, or using green placeholders, check `parseNode`, metadata
    /// resolution, and the library/prefab builders called from this path.
    static func parseDocument(at path: String) -> LevelDocument? {
        let fileURL = URL(fileURLWithPath: path)
        guard let xml = try? XMLDocument(contentsOf: fileURL, options: []),
              let rootElement = xml.rootElement() else {
            return nil
        }

        let documentName = fileURL.lastPathComponent
        let rootNode = LevelNode(
            name: documentName,
            kind: .document,
            factor: "1",
            transform: nil,
            xml: .init(),
            children: canonicalDocumentChildren(
                from: collectSceneChildren(from: rootElement, inheritedFactor: "1", baseURL: fileURL)
            )
        )

        let selected = rootNode.flattenedSceneNodes().first?.id
        var document = LevelDocument(name: documentName, sourcePath: path, root: rootNode, selectedNodeID: selected, selectedNodeIDs: selected.map { [$0] } ?? [])
        document.customBackgroundName = customBackgroundMarker(in: rootElement)
        document.hasCustomBackgroundAssignment = !document.customBackgroundName.isEmpty
        document.aiCharacters = parseAICharacters(in: rootElement)
        document.aiGroups = parseAIGroups(in: rootElement)
        document.playerSkinFiles = parsePlayerAppearance(in: rootElement)
        if let rawKind = rootElement.attribute(forName: "EditorStructuralRoom")?.stringValue,
           let kind = StructuralRoomKind(rawValue: rawKind) {
            document.structuralRoomKind = kind
        } else if fileURL.pathComponents.contains("start_rooms") {
            document.structuralRoomKind = .entrance
        } else if fileURL.pathComponents.contains("finish_rooms") {
            document.structuralRoomKind = .exit
        }
        if document.structuralRoomKind != nil {
            document.showAllStructuralRoomVariants()
        }
        document.prepareRoomLayouts()
        return document
    }

    private static func parsePlayerAppearance(in root: XMLElement) -> [String] {
        guard let element = (try? root.nodes(forXPath: "./PlayerAppearance"))?.first as? XMLElement else { return [] }
        return (element.attribute(forName: "Skins")?.stringValue ?? "").split(separator: "|").map(String.init)
    }

    private static func parseAICharacters(in root: XMLElement) -> [AICharacterDefinition] {
        let nodes = (try? root.nodes(forXPath: "./AICharacters/AICharacter")) ?? []
        return nodes.compactMap { node in
            guard let element = node as? XMLElement else { return nil }
            let id = UUID(uuidString: element.attribute(forName: "EditorID")?.stringValue ?? "") ?? UUID()
            let kind = AICharacterKind(rawValue: element.attribute(forName: "Kind")?.stringValue ?? "Friendly") ?? .friendly
            let channel = Int(element.attribute(forName: "AI")?.stringValue ?? "") ?? 1
            let skins = (element.attribute(forName: "Skins")?.stringValue ?? "1.xml")
                .split(separator: "|").map(String.init)
            return AICharacterDefinition(
                id: id,
                name: element.attribute(forName: "Name")?.stringValue ?? "AI_\(channel)",
                kind: kind,
                aiChannel: channel,
                bodySkin: skins.indices.contains(0) ? skins[0] : "1.xml",
                chestSkin: skins.indices.contains(1) ? skins[1] : "",
                helmetSkin: skins.indices.contains(2) ? skins[2] : "",
                hairSkin: skins.indices.contains(3) ? skins[3] : "",
                customLayers: skins.count > 4 ? Array(skins.dropFirst(4)) : [],
                birthSpawn: element.attribute(forName: "BirthSpawn")?.stringValue ?? "DefaultSpawn",
                startDelay: Double(element.attribute(forName: "Time")?.stringValue ?? "") ?? 0
            )
        }
    }

    private static func parseAIGroups(in root: XMLElement) -> [AIGroupDefinition] {
        let nodes = (try? root.nodes(forXPath: "./AICharacters/Groups/Group")) ?? []
        return nodes.compactMap { node in
            guard let element = node as? XMLElement else { return nil }
            let members = (element.attribute(forName: "Members")?.stringValue ?? "")
                .split(separator: "|").compactMap { UUID(uuidString: String($0)) }
            return AIGroupDefinition(
                id: UUID(uuidString: element.attribute(forName: "EditorID")?.stringValue ?? "") ?? UUID(),
                name: element.attribute(forName: "Name")?.stringValue ?? "AI Group",
                characterIDs: Set(members)
            )
        }
    }

    /// Parses XML pasted into the Raw XML panel.
    ///
    /// Users paste either a single node or a small fragment. We wrap fragments
    /// in a temporary `<Root>` so Foundation XML can parse them, then pick the
    /// first known Vector 2 scene element.
    static func parseNodeXML(_ xmlString: String, baseURL: URL) -> LevelNode? {
        let trimmed = xmlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let wrapped = "<Root>\(trimmed)</Root>"
        let document = (try? XMLDocument(xmlString: trimmed, options: []))
            ?? (try? XMLDocument(xmlString: wrapped, options: []))
        guard let root = document?.rootElement() else { return nil }

        let element: XMLElement
        if let tag = root.name, sceneTags.contains(tag) {
            element = root
        } else if let firstScene = childElements(of: root).first(where: { sceneTags.contains($0.name ?? "") }) {
            element = firstScene
        } else {
            return nil
        }

        var node = parseNode(from: element, inheritedFactor: attribute("Factor", on: element) ?? "1", baseURL: baseURL)
        // The Raw XML editor is an authoring path, so a pasted trigger must keep
        // its real Init/Loop/Action body instead of becoming an empty rectangle.
        if node.kind == .trigger {
            node.metadata.sourceContentXML = element.elements(forName: "Content").first?.xmlString(options: .nodeCompactEmptyElement) ?? ""
            node.metadata.sourcePropertiesXML = element.elements(forName: "Properties").first?.xmlString(options: .nodeCompactEmptyElement) ?? ""
        }
        return node
    }

    private static func customBackgroundMarker(in root: XMLElement) -> String {
        let attribute = root.attribute(forName: "CustomBackground")?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !attribute.isEmpty { return attribute }
        let prefix = "Vector2EditorBackground:"
        for node in (try? root.nodes(forXPath: ".//comment()")) ?? [] {
            let value = (node.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if value.lowercased().hasPrefix(prefix.lowercased()) {
                return String(value.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return ""
    }

    /// Walks arbitrary XML containers until it finds scene tags.
    ///
    /// Real Vector 2 files contain wrappers like Root/Track/Content/Objects.
    /// This keeps the parser tolerant instead of requiring one exact shape.
    private static func collectSceneChildren(from element: XMLElement, inheritedFactor: String, baseURL: URL) -> [LevelNode] {
        childElements(of: element).flatMap { child in
            let factor = attribute("Factor", on: child) ?? inheritedFactor

            if let tag = child.name, sceneTags.contains(tag) {
                return [parseNode(from: child, inheritedFactor: factor, baseURL: baseURL)]
            }

            return collectSceneChildren(from: child, inheritedFactor: factor, baseURL: baseURL)
        }
    }

    /// Imported files can be shaped a few different ways:
    ///
    /// - old/simple rooms: `<Track><Object Factor="1">...</Object></Track>`
    /// - current preview rooms: `<Root><Track><Content>...</Content></Track></Root>`
    /// - pasted/debug files: direct scene nodes under the root.
    ///
    /// Editing code expects one stable shape: Document -> Track -> Object Factor.
    /// Without this, new placements can get appended into a second Track and then
    /// play/export ignores them. That is the "imported level looks editable but
    /// the game loads the wrong stuff" bug.
    private static func canonicalDocumentChildren(from parsedChildren: [LevelNode]) -> [LevelNode] {
        var tracks = parsedChildren.filter { $0.kind == .track }
        let looseSceneNodes = parsedChildren.filter { $0.kind != .track }

        if tracks.isEmpty {
            return [
                LevelNode(
                    name: "Track",
                    kind: .track,
                    factor: "1",
                    transform: nil,
                    xml: .init(),
                    children: [
                        LevelNode(
                            name: "Object Factor = 1",
                            kind: .factor,
                            factor: "1",
                            transform: nil,
                            xml: .init(),
                            children: looseSceneNodes
                        )
                    ]
                )
            ]
        }

        tracks = tracks.map { track in
            var track = track
            let existingFactors = track.children.filter { $0.kind == .factor }
            let directSceneNodes = track.children.filter { $0.kind != .factor }

            if existingFactors.isEmpty {
                track.children = [
                    LevelNode(
                        name: "Object Factor = 1",
                        kind: .factor,
                        factor: "1",
                        transform: nil,
                        xml: .init(),
                        children: directSceneNodes
                    )
                ]
            } else if !directSceneNodes.isEmpty {
                track.children = existingFactors + [
                    LevelNode(
                        name: "Object Factor = 1",
                        kind: .factor,
                        factor: "1",
                        transform: nil,
                        xml: .init(),
                        children: directSceneNodes
                    )
                ]
            }

            return track
        }

        if !looseSceneNodes.isEmpty {
            tracks[0].children.append(
                LevelNode(
                    name: "Object Factor = 1",
                    kind: .factor,
                    factor: "1",
                    transform: nil,
                    xml: .init(),
                    children: looseSceneNodes
                )
            )
        }

        return tracks
    }

    /// Converts one XML element into one editor node.
    ///
    /// This is the runtime graph importer core. It keeps raw XML coordinates and
    /// only swaps in richer visual nodes when we can safely reconstruct the
    /// object without changing the exported XML contract.
    private static func parseNode(from element: XMLElement, inheritedFactor: String, baseURL: URL) -> LevelNode {
        let tag = element.name ?? "Node"
        let kind = levelKind(for: tag)
        let name = attribute("Name", on: element)
            ?? attribute("ClassName", on: element)
            ?? attribute("Filename", on: element)
            ?? tag
        let factor = attribute("Factor", on: element) ?? inheritedFactor
        let transform = parseTransform(from: element)
        let xml = parseSummary(from: element)

        if tag == "Object", transform == nil, attribute("Factor", on: element) != nil {
            return LevelNode(
                name: "Object Factor = \(factor)",
                kind: .factor,
                factor: factor,
                transform: nil,
                xml: xml,
                children: collectSceneChildren(from: element, inheritedFactor: factor, baseURL: baseURL)
            )
        }

        if (kind == .gateIn || kind == .gateOut), let transform {
            var node = Vector2SpawnPrefabVisual.node(for: kind, x: transform.x, y: transform.y)
            node.name = name
            node.factor = factor
            node.xml = xml
            node.transform?.rotation = transform.rotation
            return node
        }

        if kind == .objectReference,
           let transform,
           let reconstructed = Vector2ReferenceVisualBuilder.reconstruct(
            from: element,
            factor: factor,
            x: transform.x,
            y: transform.y,
            baseURL: baseURL
           ) {
            var node = reconstructed
            node.name = name
            node.factor = factor
            node.xml = xml
            return node
        }

        if kind == .object,
           let transform,
           (attribute("EditorSharedObjects", on: element) == "1" || name.hasPrefix("Shared Objects")) {
            var sharedTransform = transform
            if let width = parseDouble(attribute("EditorSharedWidth", on: element)) {
                sharedTransform.width = max(1, Int(width.rounded()))
            }
            if let height = parseDouble(attribute("EditorSharedHeight", on: element)) {
                sharedTransform.height = max(1, Int(height.rounded()))
            }
            var node = LevelNode(
                name: name,
                kind: kind,
                factor: factor,
                transform: sharedTransform,
                xml: xml,
                metadata: parseMetadata(from: element, kind: kind),
                children: collectSceneChildren(from: element, inheritedFactor: factor, baseURL: baseURL)
            )
            let localOrigin = LevelNode.Transform(
                x: 0,
                y: 0,
                width: sharedTransform.width,
                height: sharedTransform.height,
                rotation: 0
            )
            node.transformDescendants(from: localOrigin, to: sharedTransform)
            return markRoomLayoutSharedGroup(node)
        }

        if kind == .object,
           let transform,
           hasContent(element) {
            // Inline objects keep their children local, just like Room Weaver.
            // Flattening them here made an edited image shift on reimport.
            var metadata = parseMetadata(from: element, kind: kind)
            metadata.visualType = "RoomWeaverContainer"
            metadata.imagePath = ""
            metadata.visualOffsetX = 0
            metadata.visualOffsetY = 0
            metadata.visualNativeWidth = transform.width
            metadata.visualNativeHeight = transform.height
            let node = LevelNode(name: name, kind: kind, factor: factor,
                transform: transform, xml: xml, metadata: metadata,
                children: collectSceneChildren(from: element, inheritedFactor: factor, baseURL: baseURL))
            return markRoomLayoutSharedGroup(node)
        }

        if kind == .object,
           let transform,
           xml.template == "LibraryObject",
           let reconstructed = Vector2LibraryObjectBuilder.reconstructSceneObject(
            name: name,
            filename: xml.choice,
            originX: transform.x,
            originY: transform.y,
            baseURL: baseURL,
            settings: element
           ) {
            var node = reconstructed
            node.factor = factor
            node.xml = xml
            let sourceMetadata = parseMetadata(from: element, kind: kind)
            if !sourceMetadata.sortingLayer.isEmpty {
                node.metadata.sortingLayer = sourceMetadata.sortingLayer
            }
            if !sourceMetadata.tag.isEmpty {
                node.metadata.tag = sourceMetadata.tag
            }
            node.transform?.rotation = transform.rotation
            return node
        }

        var metadata = parseMetadata(from: element, kind: kind)
        if tag == "Spawn" {
            metadata.sourceAttributes["EditorElement"] = "Spawn"
            metadata.sourceAttributes["Animation"] = attribute("Animation", on: element) ?? ""
        }
        if kind == .trigger {
            metadata.sourceContentXML = element.elements(forName: "Content").first?
                .xmlString(options: .nodeCompactEmptyElement) ?? ""
            metadata.sourcePropertiesXML = element.elements(forName: "Properties").first?
                .xmlString(options: .nodeCompactEmptyElement) ?? ""
        }

        let parsed = LevelNode(
            name: name,
            kind: kind,
            factor: factor,
            transform: transform,
            xml: xml,
            metadata: metadata,
            children: collectSceneChildren(from: element, inheritedFactor: factor, baseURL: baseURL)
        )
        return markRoomLayoutSharedGroup(parsed)
    }

    private static func markRoomLayoutSharedGroup(_ source: LevelNode) -> LevelNode {
        guard source.kind == .object,
              (source.metadata.sourceAttributes["EditorSharedObjects"] == "1"
                || source.name.hasPrefix("Shared Objects")) else { return source }
        var node = source
        node.metadata.visualType = "RoomLayoutSharedGroup"
        node.metadata.sourceAttributes["EditorSharedObjects"] = "1"
        return node
    }

    /// Some `<Object>` nodes contain their own children inline instead of being
    /// a compact library reference. Inline content gets reconstructed visually
    /// but must still export back as nested object content.
    private static func hasContent(_ element: XMLElement) -> Bool {
        element.elements(forName: "Content").isEmpty == false
    }

    /// Extracts editor-space transform from XML attributes/matrix data.
    ///
    /// Images are special because Vector 2 stores their rotation/scale in a
    /// Matrix. Most other nodes use plain X/Y/Width/Height.
    private static func parseTransform(from element: XMLElement) -> LevelNode.Transform? {
        let parsedX = parseInteger(attribute("X", on: element))
        let parsedY = parseInteger(attribute("Y", on: element))
        let parsedWidth = parseInteger(attribute("Width", on: element))
        let parsedHeight = parseInteger(attribute("Height", on: element))
        let parsedRotation = Double(attribute("Rotation", on: element) ?? "0") ?? 0

        guard parsedX != nil || parsedY != nil || parsedWidth != nil || parsedHeight != nil else {
            return nil
        }

        if element.name == "Image",
           let parsedX,
           let parsedY,
           let matrix = imageMatrixTransform(from: element, x: parsedX, y: parsedY) {
            return matrix
        }

        if element.name == "Object",
           let matrix = RoomWeaverImporter.objectMatrixTransform(from: element,
                x: parsedX ?? 0, y: parsedY ?? 0) {
            return matrix
        }

        let width = parsedWidth ?? defaultWidth(for: element.name)
        let height = parsedHeight ?? defaultHeight(for: element.name)
        let x = parsedX ?? 0
        let y = parsedY ?? 0
        return .init(x: x, y: y, width: width, height: height, rotation: parsedRotation)
    }

    /// Pulls XML identity metadata used by the inspector/exporter.
    ///
    /// Template/Choice/Variant are not visual properties; they tell BuildMap and
    /// the runtime which library/template behavior this node originally used.
    private static func parseSummary(from element: XMLElement) -> LevelNode.XMLSummary {
        let directSelections = element.elements(forName: "Properties").first?
            .elements(forName: "Static").first?
            .elements(forName: "Selection") ?? []
        let parsedSelections = directSelections.compactMap { selection -> LevelNode.XMLSummary.SelectionRule? in
            guard let choice = selection.attribute(forName: "Choice")?.stringValue,
                  let variant = selection.attribute(forName: "Variant")?.stringValue,
                  !choice.isEmpty, !variant.isEmpty else { return nil }
            return .init(
                choice: choice,
                variant: variant,
                parentChoice: selection.attribute(forName: "Parent")?.stringValue ?? ""
            )
        }
        let template = firstAttribute(
            "Name",
            fromXPath: [
                "./Content/Template",
                ".//Template"
            ],
            on: element
        ) ?? ""

        let choice = firstAttribute(
            "Choice",
            fromXPath: [
                "./Properties/Static/Selection",
                ".//Selection"
            ],
            on: element
        ) ?? ""

        let variant = firstAttribute(
            "Variant",
            fromXPath: [
                "./Properties/Static/Selection",
                ".//Selection"
            ],
            on: element
        ) ?? ""

        let parentChoice = firstAttribute(
            "Parent",
            fromXPath: [
                "./Properties/Static/Selection",
                ".//Selection"
            ],
            on: element
        ) ?? ""

        let blend = firstAttribute(
            "Mode",
            fromXPath: [
                "./Properties/Static/BlendMode",
                ".//BlendMode"
            ],
            on: element
        ) ?? "Normal"

        return .init(
            template: template,
            choice: parsedSelections.first?.choice ?? choice,
            variant: parsedSelections.first?.variant ?? variant,
            parentChoice: parsedSelections.first?.parentChoice ?? parentChoice,
            additionalSelections: Array(parsedSelections.dropFirst()),
            blend: blend
        )
    }

    /// Pulls rendering/import metadata for the editor.
    ///
    /// This is where class names become texture paths. If imported library
    /// objects show green boxes, the class/file info here or in the catalog
    /// resolver is usually the first place to inspect.
    private static func parseMetadata(from element: XMLElement, kind: LevelNode.Kind) -> LevelNode.Metadata {
        var metadata = RoomWeaverImporter.parseMetadata(from: element, kind: kind)
        // Direct room shapes and images own dynamics too. Library references
        // already preserve this block in their reconstruction path.
        if kind != .trapezoid,
           let properties = firstElement(fromXPath: "./Properties", on: element) {
            metadata.dynamicXML = properties.elements(forName: "Dynamic")
                .map { $0.xmlString(options: .nodeCompactEmptyElement) }
                .joined(separator: "\n")
        }
        metadata.aiTarget = attribute("EditorAITarget", on: element) ?? ""
        metadata.aiActionTemplate = attribute("EditorAIAction", on: element) ?? ""
        if metadata.aiActionTemplate == "Wall Jump" { metadata.aiActionTemplate = "WallJump" }
        if metadata.aiActionTemplate == "Run" { metadata.aiActionTemplate = "RunForward" }
        metadata.aiActionValue = attribute("EditorAIValue", on: element) ?? ""

        if kind == .image {
            let sourceGIF = attribute("EditorSourceGIF", on: element)
            let previewClass = sourceGIF.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? metadata.className
            metadata.imagePath = Vector2AssetCatalog.imagePath(forClassName: previewClass) ?? ""
            metadata.visualNativeWidth = parseInteger(attribute("NativeX", on: element)) ?? 0
            metadata.visualNativeHeight = parseInteger(attribute("NativeY", on: element)) ?? 0
            metadata.visualType = attribute("Type", on: element) ?? ""
            metadata.visualDepth = attribute("Depth", on: element) ?? ""
        }

        if (kind == .platform || kind == .trapezoid), metadata.sortingLayer.isEmpty {
            metadata.sortingLayer = "Collision"
        }

        if kind == .trapezoid, metadata.imagePath.isEmpty {
            let style: Vector2EditorVisuals.TrapezoidStyle = attribute("Type", on: element) == "2" ? .right : .left
            metadata.imagePath = Vector2EditorVisuals.trapezoidTexturePath(style: style) ?? ""
        }

        if kind == .gateIn || kind == .gateOut {
            let spawnVisual = Vector2SpawnPrefabVisual.metadata(for: kind)
            metadata.filename = metadata.filename.isEmpty ? spawnVisual.filename : metadata.filename
            metadata.className = metadata.className.isEmpty ? spawnVisual.className : metadata.className
            metadata.imagePath = spawnVisual.imagePath
        }

        return metadata
    }

    /// Converts Vector 2 image matrix data into the same editable rectangle used
    /// by the room importer and canvas. Keeping one conversion here matters:
    /// switching import routes must not change the object's pivot or angle.
    private static func imageMatrixTransform(from element: XMLElement, x: Int, y: Int) -> LevelNode.Transform? {
        guard let matrixElement = firstElement(
            fromXPath: "./Properties/Static/Matrix",
            on: element
        ),
              let a = parseDouble(attribute("A", on: matrixElement)),
              let b = parseDouble(attribute("B", on: matrixElement)),
              let c = parseDouble(attribute("C", on: matrixElement)),
              let d = parseDouble(attribute("D", on: matrixElement)) else {
            return nil
        }

        let tx = parseDouble(attribute("Tx", on: matrixElement)) ?? 0
        let ty = parseDouble(attribute("Ty", on: matrixElement)) ?? 0
        let editable = ImportedAffineRectPolicy.editableRect(
            x: Double(x), y: Double(y),
            a: a, b: b, c: c, d: d,
            tx: tx, ty: ty
        )
        return .init(
            x: editable.x,
            y: editable.y,
            width: editable.width,
            height: editable.height,
            rotation: editable.rotation
        )
    }

    /// Marker for tags that behave like rectangles in XML.
    ///
    /// This is intentionally conservative; not every object with X/Y can be
    /// safely treated as a resizeable rectangle.
    private static func usesRectXMLOrigin(_ tag: String?) -> Bool {
        switch tag {
        case "Image", "CustomAnimation", "UnityModel", "Platform", "Trapezoid", "Trigger", "DynamicTrigger", "Area":
            return true
        default:
            return false
        }
    }

    /// Maps raw XML tag names to editor node kinds.
    ///
    /// Unknown XML defaults to `.object` so the editor preserves something
    /// selectable instead of dropping content on import.
    private static func levelKind(for tag: String) -> LevelNode.Kind {
        switch tag {
        case "Track": .track
        case "Objects": .object
        case "Object": .object
        case "Image", "CustomAnimation", "UnityModel": .image
        case "Platform": .platform
        case "Trapezoid": .trapezoid
        case "Trigger", "DynamicTrigger": .trigger
        case "Area": .area
        case "ObjectReference": .objectReference
        case "Waypoint", "Spawn": .waypoint
        case "In": .gateIn
        case "Out": .gateOut
        case "Camera": .camera
        case "Dynamic": .dynamic
        default: .object
        }
    }

    /// Fallback width for XML nodes that do not declare one.
    ///
    /// These values are display defaults only; if a node exports without size,
    /// the exporter decides whether size should be written.
    private static func defaultWidth(for tag: String?) -> Int {
        switch tag {
        case "In", "Out": 72
        case "ObjectReference", "Object": 100
        case "Image", "UnityModel": 120
        default: 100
        }
    }

    /// Fallback height partner to `defaultWidth`.
    private static func defaultHeight(for tag: String?) -> Int {
        switch tag {
        case "In", "Out": 72
        case "ObjectReference", "Object": 100
        case "Image", "UnityModel": 120
        default: 100
        }
    }

    /// Parses Vector XML numbers that sometimes arrive as floats or comma
    /// decimals, then rounds to editor integer coordinates.
    private static func parseInteger(_ raw: String?) -> Int? {
        guard let raw, !raw.isEmpty else { return nil }
        let cleaned = raw.replacingOccurrences(of: ",", with: ".")
        guard let number = Double(cleaned) else { return nil }
        return Int(number.rounded())
    }

    /// Parses a Vector XML decimal while accepting comma decimal separators from
    /// Nekki/Russian-authored data files.
    private static func parseDouble(_ raw: String?) -> Double? {
        guard let raw, !raw.isEmpty else { return nil }
        return Double(raw.replacingOccurrences(of: ",", with: "."))
    }

    /// Child element helper that filters text/comment nodes out of Foundation's
    /// generic XML child list.
    private static func childElements(of element: XMLElement) -> [XMLElement] {
        (element.children ?? []).compactMap { $0 as? XMLElement }
    }

    /// Tiny XPath helper for XML shapes where the child is optional.
    private static func firstElement(fromXPath xpath: String, on element: XMLElement) -> XMLElement? {
        (try? element.nodes(forXPath: xpath).first) as? XMLElement
    }

    /// Safe attribute lookup.
    private static func attribute(_ name: String, on element: XMLElement) -> String? {
        element.attribute(forName: name)?.stringValue
    }

    /// Looks for the first matching attribute across several possible XML paths.
    ///
    /// Vector files are inconsistent: some data is directly under Properties,
    /// some is nested deeper by templates. This keeps the parser forgiving.
    private static func firstAttribute(_ attributeName: String, fromXPath xpaths: [String], on element: XMLElement) -> String? {
        for xpath in xpaths {
            if let target = try? element.nodes(forXPath: xpath).first as? XMLElement,
               let value = target.attribute(forName: attributeName)?.stringValue,
               !value.isEmpty {
                return value
            }
        }

        return nil
    }
}

/// Import strategy switch shown in Settings.
///
/// Runtime Graph keeps BuildMap Vec2 coordinates as-is. ConvertXmlObject2 is
/// the deeper object expansion path inspired by Vision's converter work. Keep
/// this enum small and explicit so ports can expose the same behavior clearly.
enum Vector2ImportPipeline: String, CaseIterable, Identifiable {
    // Standalone room importer. This is intentionally not a wrapper around
    // XMLSceneParser so Runtime Graph can remain stable.
    case roomWeaver = "roomWeaver"
    // Safe/default path: import the scene as a graph that mirrors the game's
    // room XML. This is the public mode because it avoids coordinate cleanup.
    case runtimeGraph = "runtimeGraph"
    // Experimental/deeper path: resolves more content variables like Vision's
    // ConvertXmlObject2 work. Useful for debugging advanced objects, but riskier
    // because expansion can change visuals if Nekki XML has odd template logic.
    case convertXmlObject2 = "convertXmlObject2"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .roomWeaver:
            return "RoomWeaver"
        case .runtimeGraph:
            return "Runtime Graph"
        case .convertXmlObject2:
            return "ConvertXmlObject2"
        }
    }

    static var current: Vector2ImportPipeline {
        Vector2ImportPipeline(rawValue: UserDefaults.standard.string(forKey: "vector2ImportPipeline") ?? "") ?? .roomWeaver
    }
}

/// Reconstructs Vector 2 `LibraryObject` references into editor visuals.
///
/// This is the "advanced library stuff" system. It reads library XML files,
/// applies object settings/choices/variables, collects child image/shape pieces,
/// and either creates editable child nodes or a baked preview image. Missing
/// pieces here are why users see green boxes instead of real object previews.
