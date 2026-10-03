//
//  RoomWeaverSceneImporter.swift
//  Vector2 level editor
//
//  This is the part that turns real room XML into editor nodes. Diagnostics and
//  console UI are deliberately elsewhere so logging changes cannot quietly
//  alter import behavior. When a room imports wrong, trace choices -> elements
//  -> LevelNode creation in this file before touching rendering.
//

import AppKit
import Foundation

struct RoomWeaverChoiceOption: Identifiable, Equatable {
    let id: String
    let name: String
    let description: String
    let variants: [String]
}

enum RoomWeaverImporter {
    private typealias ChoiceMap = [String: String]

    private static let sceneTags: Set<String> = [
        "Track",
        "Objects",
        "Object",
        "ObjectReference",
        "Image",
        "Platform",
        "Trapezoid",
        "Trigger",
        "Area",
        "In",
        "Out",
        "Camera",
        "Spawn",
        "SoundSource",
        "Item",
        "Placeholder",
        "Sensor",
        "Lightning",
        "Waypoint",
        "Particle",
        "Animation",
        "CustomAnimation",
        "Dynamic",
        "DynamicTrigger",
        "UnityModel"
    ]

    static func canImportRoom(at path: String) -> Bool {
        let fileURL = URL(fileURLWithPath: path)
        guard let rootElement = RoomWeaverSourceCache.rootElement(at: fileURL) else {
            return false
        }
        return rootElement.name == "Track"
            || !rootElement.elements(forName: "Track").isEmpty
            || ((try? rootElement.nodes(forXPath: ".//Track/Content"))?.isEmpty == false)
    }

    static func choiceOptions(at path: String) -> [RoomWeaverChoiceOption] {
        let fileURL = URL(fileURLWithPath: path)
        guard let rootElement = RoomWeaverSourceCache.rootElement(at: fileURL) else {
            return []
        }

        return V2LayoutEngine.choiceOptions(in: rootElement)
    }

    static func parseDocument(at path: String, selectedVariants: [String: String]? = nil) -> LevelDocument? {
        let diagnostics = RoomWeaverDiagnostics.shared
        diagnostics.beginImport(path: path)

        let fileURL = URL(fileURLWithPath: path)
        guard let rootElement = RoomWeaverSourceCache.rootElement(at: fileURL) else {
            diagnostics.failImport(path: path)
            return nil
        }

        let documentName = fileURL.lastPathComponent
        let roomName = fileURL.deletingPathExtension().lastPathComponent
        let roomChoices = V2LayoutEngine.roomChoiceMap(
            in: rootElement,
            roomName: roomName,
            selectedVariants: selectedVariants ?? [:]
        )
        diagnostics.selectedChoices(roomChoices)
        let roomChildren = roomContentElement(in: rootElement).map {
            parseContentChildren(from: $0, inheritedFactor: "0", baseURL: fileURL, choices: roomChoices)
        } ?? collectSceneChildren(from: rootElement, inheritedFactor: "0", baseURL: fileURL, choices: roomChoices)

        let rootNode = LevelNode(
            name: documentName,
            kind: .document,
            factor: "1",
            transform: nil,
            xml: .init(),
            children: canonicalDocumentChildren(from: roomChildren, roomName: roomName)
        )

        let selected = rootNode.flattenedSceneNodes().first?.id
        var document = LevelDocument(
            name: documentName,
            sourcePath: path,
            root: rootNode,
            selectedNodeID: selected,
            selectedNodeIDs: selected.map { [$0] } ?? []
        )
        document.customBackgroundName = customBackgroundMarker(in: rootElement)
        document.hasCustomBackgroundAssignment = !document.customBackgroundName.isEmpty
        document.aiCharacters = parseAICharacters(in: rootElement)
        document.aiGroups = parseAIGroups(in: rootElement)
        document.playerSkinFiles = parsePlayerAppearance(in: rootElement)
        diagnostics.finishImport(document: document)
        return document
    }

    private static func roomContentElement(in rootElement: XMLElement) -> XMLElement? {
        for xpath in ["./Track/Content", "./Content", ".//Track/Content"] {
            if let content = firstElement(fromXPath: xpath, on: rootElement) {
                return content
            }
        }
        return nil
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

    private static func parsePlayerAppearance(in root: XMLElement) -> [String] {
        guard let element = firstElement(fromXPath: "./PlayerAppearance", on: root) else { return [] }
        return (attribute("Skins", on: element) ?? "")
            .split(separator: "|")
            .map(String.init)
    }

    private static func parseAICharacters(in root: XMLElement) -> [AICharacterDefinition] {
        let nodes = (try? root.nodes(forXPath: "./AICharacters/AICharacter")) ?? []
        return nodes.compactMap { node in
            guard let element = node as? XMLElement else { return nil }
            let id = UUID(uuidString: attribute("EditorID", on: element) ?? "") ?? UUID()
            let kind = AICharacterKind(rawValue: attribute("Kind", on: element) ?? "Friendly") ?? .friendly
            let channel = Int(attribute("AI", on: element) ?? "") ?? 1
            let skins = (attribute("Skins", on: element) ?? "1.xml")
                .split(separator: "|")
                .map(String.init)
            return AICharacterDefinition(
                id: id,
                name: attribute("Name", on: element) ?? "AI_\(channel)",
                kind: kind,
                aiChannel: channel,
                bodySkin: skins.indices.contains(0) ? skins[0] : "1.xml",
                chestSkin: skins.indices.contains(1) ? skins[1] : "",
                helmetSkin: skins.indices.contains(2) ? skins[2] : "",
                hairSkin: skins.indices.contains(3) ? skins[3] : "",
                customLayers: skins.count > 4 ? Array(skins.dropFirst(4)) : [],
                birthSpawn: attribute("BirthSpawn", on: element) ?? "DefaultSpawn",
                startDelay: Double(attribute("Time", on: element) ?? "") ?? 0
            )
        }
    }

    private static func parseAIGroups(in root: XMLElement) -> [AIGroupDefinition] {
        let nodes = (try? root.nodes(forXPath: "./AICharacters/Groups/Group")) ?? []
        return nodes.compactMap { node in
            guard let element = node as? XMLElement else { return nil }
            let members = (attribute("Members", on: element) ?? "")
                .split(separator: "|")
                .compactMap { UUID(uuidString: String($0)) }
            return AIGroupDefinition(
                id: UUID(uuidString: attribute("EditorID", on: element) ?? "") ?? UUID(),
                name: attribute("Name", on: element) ?? "AI Group",
                characterIDs: Set(members)
            )
        }
    }

    private static func collectSceneChildren(from element: XMLElement, inheritedFactor: String, baseURL: URL, choices: ChoiceMap) -> [LevelNode] {
        if element.name == "Content" {
            return parseContentChildren(from: element, inheritedFactor: inheritedFactor, baseURL: baseURL, choices: choices)
        }
        if let content = element.elements(forName: "Content").first {
            return parseContentChildren(from: content, inheritedFactor: inheritedFactor, baseURL: baseURL, choices: choices)
        }
        return childElements(of: element).compactMap { child in
            guard let tag = child.name, sceneTags.contains(tag) else { return nil }
            guard V2LayoutEngine.shouldIncludeElement(child, choices: choices) else { return nil }
            return parseNode(from: child, inheritedFactor: inheritedFactor, baseURL: baseURL, choices: choices)
        }
    }

    private static func parseContentChildren(from content: XMLElement, inheritedFactor: String, baseURL: URL, choices: ChoiceMap) -> [LevelNode] {
        childElements(of: content).compactMap { child in
            guard let tag = child.name, sceneTags.contains(tag) else { return nil }
            guard V2LayoutEngine.shouldIncludeElement(child, choices: choices) else { return nil }
            return parseNode(from: child, inheritedFactor: inheritedFactor, baseURL: baseURL, choices: choices)
        }
    }

    private static func canonicalDocumentChildren(from parsedChildren: [LevelNode], roomName: String) -> [LevelNode] {
        [
            LevelNode(
                name: "Track",
                kind: .track,
                factor: "0",
                transform: nil,
                xml: .init(),
                children: [
                    LevelNode(
                        name: roomName,
                        kind: .factor,
                        factor: "0",
                        transform: nil,
                        xml: .init(),
                        children: parsedChildren
                    )
                ]
            )
        ]
    }

    private static func parseNode(from element: XMLElement, inheritedFactor: String, baseURL: URL, choices: ChoiceMap) -> LevelNode {
        let tag = element.name ?? "Node"
        if tag == "Object", let aiWrapper = parseEditorAIWrapper(from: element, inheritedFactor: inheritedFactor) {
            return aiWrapper
        }
        let kind = levelKind(for: tag)
        let name = attribute("Name", on: element)
            ?? attribute("ClassName", on: element)
            ?? attribute("Filename", on: element)
            ?? tag
        let factor = attribute("Factor", on: element) ?? inheritedFactor
        let transform = parseTransform(from: element)
        // Room Weaver has already resolved the room's selected variant before
        // creating editor nodes. Keeping the source Selection on those nodes
        // makes the runtime evaluate the same condition a second time, but the
        // flattened export intentionally has no room-level choice table. That
        // can filter out the selected In/Out branch and crash room generation.
        let xml = parseSummary(from: element, preserveSelection: false)

        if tag == "Object", transform == nil, attribute("Factor", on: element) != nil {
            return LevelNode(
                name: "Object Factor = \(factor)",
                kind: .factor,
                factor: factor,
                transform: nil,
                xml: xml,
                children: collectSceneChildren(from: element, inheritedFactor: factor, baseURL: baseURL, choices: choices)
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
            baseURL: baseURL,
            rotation: transform.rotation,
            choices: choices
           ) {
            var node = reconstructed
            let sourceMetadata = parseMetadata(from: element, kind: kind)
            node.name = name
            node.factor = factor
            node.xml = xml
            node.metadata.sortingLayer = sourceMetadata.sortingLayer.isEmpty ? node.metadata.sortingLayer : sourceMetadata.sortingLayer
            node.metadata.tag = sourceMetadata.tag.isEmpty ? node.metadata.tag : sourceMetadata.tag
            node.metadata.sourceX = sourceMetadata.sourceX
            node.metadata.sourceY = sourceMetadata.sourceY
            node.metadata.sourceWidth = sourceMetadata.sourceWidth
            node.metadata.sourceHeight = sourceMetadata.sourceHeight
            node.metadata.sourceAttributes = sourceMetadata.sourceAttributes
            node.metadata.matrixA = sourceMetadata.matrixA
            node.metadata.matrixB = sourceMetadata.matrixB
            node.metadata.matrixC = sourceMetadata.matrixC
            node.metadata.matrixD = sourceMetadata.matrixD
            node.metadata.matrixTx = sourceMetadata.matrixTx
            node.metadata.matrixTy = sourceMetadata.matrixTy
            node.metadata.sourcePropertiesXML = sourceMetadata.sourcePropertiesXML
            node.metadata.libraryOverrides = sourceMetadata.libraryOverrides
            node.metadata.dynamicXML = mergedDynamicXML(node.metadata.dynamicXML, sourceMetadata.dynamicXML)
            node.metadata.visualType = "RoomWeaverLibraryReference"
            return node
        }

        if kind == .object, hasContent(element) {
            var metadata = parseMetadata(from: element, kind: kind)
            metadata.visualType = "RoomWeaverContainer"
            metadata.imagePath = ""
            metadata.visualOffsetX = 0
            metadata.visualOffsetY = 0
            metadata.visualNativeWidth = transform?.width ?? 0
            metadata.visualNativeHeight = transform?.height ?? 0

            return LevelNode(
                name: name,
                kind: kind,
                factor: factor,
                transform: transform,
                xml: xml,
                metadata: metadata,
                children: element.elements(forName: "Content").first.map {
                    parseContentChildren(from: $0, inheritedFactor: factor, baseURL: baseURL, choices: choices)
                } ?? []
            )
        }

        if kind == .object,
           let transform,
           xml.template == "LibraryObject",
           let libraryFilename = libraryFilename(forObjectNamed: name, xml: xml, baseURL: baseURL),
           let reconstructed = Vector2LibraryObjectBuilder.reconstructSceneObject(
            name: name,
            filename: libraryFilename,
            // `reconstructSceneObject` consumes this element's Matrix itself.
            // `parseTransform` has already folded Matrix Tx/Ty into `transform`,
            // so passing that value applied translation twice to library art.
            originX: parseInteger(attribute("X", on: element)) ?? transform.x,
            originY: parseInteger(attribute("Y", on: element)) ?? transform.y,
            baseURL: baseURL,
            settings: element,
            rotation: transform.rotation,
            choices: choices
           ) {
            var node = reconstructed
            let sourceMetadata = parseMetadata(from: element, kind: kind)
            node.factor = factor
            node.xml = xml
            node.metadata.sortingLayer = sourceMetadata.sortingLayer.isEmpty ? node.metadata.sortingLayer : sourceMetadata.sortingLayer
            node.metadata.tag = sourceMetadata.tag.isEmpty ? node.metadata.tag : sourceMetadata.tag
            node.metadata.sourceX = sourceMetadata.sourceX
            node.metadata.sourceY = sourceMetadata.sourceY
            node.metadata.sourceWidth = sourceMetadata.sourceWidth
            node.metadata.sourceHeight = sourceMetadata.sourceHeight
            node.metadata.sourceAttributes = sourceMetadata.sourceAttributes
            node.metadata.matrixA = sourceMetadata.matrixA
            node.metadata.matrixB = sourceMetadata.matrixB
            node.metadata.matrixC = sourceMetadata.matrixC
            node.metadata.matrixD = sourceMetadata.matrixD
            node.metadata.matrixTx = sourceMetadata.matrixTx
            node.metadata.matrixTy = sourceMetadata.matrixTy
            node.metadata.sourcePropertiesXML = sourceMetadata.sourcePropertiesXML
            node.metadata.libraryOverrides = sourceMetadata.libraryOverrides
            node.metadata.dynamicXML = mergedDynamicXML(node.metadata.dynamicXML, sourceMetadata.dynamicXML)
            node.metadata.visualType = "RoomWeaverLibraryReference"
            return node
        } else if kind == .object, xml.template == "LibraryObject" {
            RoomWeaverDiagnostics.shared.missingLibraryObject(name: name, filename: xml.choice)
        }

        if kind == .image {
            let metadata = parseMetadata(from: element, kind: kind)
            return LevelNode(
                name: name,
                kind: kind,
                factor: factor,
                transform: transform,
                xml: xml,
                metadata: metadata,
                children: []
            )
        }

        return LevelNode(
            name: name,
            kind: kind,
            factor: factor,
            transform: transform,
            xml: xml,
            metadata: parseMetadata(from: element, kind: kind),
            children: element.elements(forName: "Content").first.map {
                parseContentChildren(from: $0, inheritedFactor: factor, baseURL: baseURL, choices: choices)
            } ?? []
        )
    }

    /// Spawn and group AI actions are exported as an Object wrapper containing
    /// runtime Trigger/Spawn children. Reimport that runtime package as the one
    /// editor trigger it originally represented instead of duplicating every
    /// implementation child on the canvas.
    private static func parseEditorAIWrapper(from element: XMLElement, inheritedFactor: String) -> LevelNode? {
        guard let action = attribute("EditorAIAction", on: element), !action.isEmpty else { return nil }
        let wrapperX = parseInteger(attribute("X", on: element)) ?? 0
        let wrapperY = parseInteger(attribute("Y", on: element)) ?? 0
        let runtimeTrigger = firstElement(fromXPath: "./Content/Trigger", on: element)
        let localX = runtimeTrigger.flatMap { parseInteger(attribute("X", on: $0)) } ?? 0
        let localY = runtimeTrigger.flatMap { parseInteger(attribute("Y", on: $0)) } ?? 0
        let width = runtimeTrigger.flatMap { parseInteger(attribute("Width", on: $0)) } ?? 100
        let height = runtimeTrigger.flatMap { parseInteger(attribute("Height", on: $0)) } ?? 240
        var metadata = parseMetadata(from: element, kind: .trigger)
        metadata.aiActionTemplate = action
        metadata.sourceContentXML = ""
        metadata.sourcePropertiesXML = ""
        metadata.sourceX = ""
        metadata.sourceY = ""
        metadata.sourceWidth = ""
        metadata.sourceHeight = ""
        metadata.sourceAttributes = [:]
        return LevelNode(
            name: attribute("Name", on: element) ?? "AI_\(action)",
            kind: .trigger,
            factor: attribute("Factor", on: element) ?? inheritedFactor,
            transform: .init(x: wrapperX + localX, y: wrapperY + localY, width: width, height: height),
            xml: .init(),
            metadata: metadata,
            children: []
        )
    }

    private static func hasContent(_ element: XMLElement) -> Bool {
        element.elements(forName: "Content").isEmpty == false
    }

    private static func libraryFilename(forObjectNamed name: String, xml: LevelNode.XMLSummary, baseURL: URL) -> String? {
        if !xml.choice.isEmpty {
            return xml.choice
        }
        return Vector2AssetCatalog.libraryFilename(
            containingObjectNamed: name,
            preferredNear: baseURL.lastPathComponent
        )
    }

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
           let parsedX,
           let parsedY,
           let matrix = objectMatrixTransform(from: element, x: parsedX, y: parsedY) {
            return matrix
        }

        return .init(
            x: parsedX ?? 0,
            y: parsedY ?? 0,
            width: parsedWidth ?? defaultWidth(for: element.name),
            height: parsedHeight ?? defaultHeight(for: element.name),
            rotation: parsedRotation
        )
    }

    static func objectMatrixTransform(from element: XMLElement, x: Int, y: Int) -> LevelNode.Transform? {
        guard let matrixElement = firstElement(fromXPath: "./Properties/Static/Matrix", on: element) else {
            return nil
        }

        let tx = parseDouble(attribute("Tx", on: matrixElement)) ?? 0
        let ty = parseDouble(attribute("Ty", on: matrixElement)) ?? 0
        return .init(
            x: Int((Double(x) + tx).rounded()),
            y: Int((Double(y) + ty).rounded()),
            width: defaultWidth(for: element.name),
            height: defaultHeight(for: element.name),
            // The complete matrix is retained in metadata and composed by the
            // RoomWeaver renderer. Baking its angle here made grouped objects
            // receive the same rotation twice.
            rotation: 0
        )
    }

    private static func parseSummary(from element: XMLElement, preserveSelection: Bool = true) -> LevelNode.XMLSummary {
        if element.name == "Trapezoid" {
            let type = attribute("Type", on: element) ?? "1"
            return .init(
                template: "Trapezoid",
                choice: "Collision",
                variant: type == "2" ? "SlopeType2" : "Slope",
                blend: "Normal"
            )
        }

        return .init(
            template: firstAttribute("Name", fromXPath: ["./Content/Template", ".//Template"], on: element) ?? "",
            choice: preserveSelection ? (firstAttribute("Choice", fromXPath: ["./Properties/Static/Selection", ".//Selection"], on: element) ?? "") : "",
            variant: preserveSelection ? (firstAttribute("Variant", fromXPath: ["./Properties/Static/Selection", ".//Selection"], on: element) ?? "") : "",
            blend: firstAttribute("Mode", fromXPath: ["./Properties/Static/BlendMode", ".//BlendMode"], on: element) ?? "Normal"
        )
    }

    static func parseMetadata(from element: XMLElement, kind: LevelNode.Kind) -> LevelNode.Metadata {
        var metadata = LevelNode.Metadata(
            sortingLayer: attribute("Layer", on: element) ?? "",
            tag: attribute("Tag", on: element) ?? kind.defaultTag,
            filename: attribute("Filename", on: element) ?? "",
            className: attribute("ClassName", on: element) ?? ""
        )

        metadata.sourceX = attribute("X", on: element) ?? ""
        metadata.sourceY = attribute("Y", on: element) ?? ""
        metadata.sourceWidth = attribute("Width", on: element) ?? ""
        metadata.sourceHeight = attribute("Height", on: element) ?? ""
        for sourceAttribute in element.attributes ?? [] {
            if let name = sourceAttribute.name {
                metadata.sourceAttributes[name] = sourceAttribute.stringValue ?? ""
            }
        }
        if kind == .trigger,
           let content = firstElement(fromXPath: "./Content", on: element) {
            metadata.sourceContentXML = content.xmlString(options: .nodeCompactEmptyElement)
        }
        // Editor-authored AI actions are ordinary Trigger XML at runtime. Keep
        // their editor identity when a room is imported again so the target,
        // template, and value remain configurable instead of degrading into a
        // generic trigger box.
        metadata.aiTarget = attribute("EditorAITarget", on: element) ?? ""
        metadata.aiActionTemplate = attribute("EditorAIAction", on: element) ?? ""
        metadata.aiActionValue = attribute("EditorAIValue", on: element) ?? ""
        if metadata.aiActionTemplate == "Wall Jump" { metadata.aiActionTemplate = "WallJump" }
        if metadata.aiActionTemplate == "Run" { metadata.aiActionTemplate = "RunForward" }
        if let properties = firstElement(fromXPath: "./Properties", on: element) {
            metadata.sourcePropertiesXML = flattenedPropertiesXML(properties)
            metadata.dynamicXML = childElements(of: properties)
                .filter { $0.name == "Dynamic" }
                .map { $0.xmlString(options: .nodeCompactEmptyElement) }
                .joined(separator: "\n")
        }
        if let matrixElement = firstElement(fromXPath: "./Properties/Static/Matrix", on: element) {
            metadata.matrixA = attribute("A", on: matrixElement) ?? ""
            metadata.matrixB = attribute("B", on: matrixElement) ?? ""
            metadata.matrixC = attribute("C", on: matrixElement) ?? ""
            metadata.matrixD = attribute("D", on: matrixElement) ?? ""
            metadata.matrixTx = attribute("Tx", on: matrixElement) ?? ""
            metadata.matrixTy = attribute("Ty", on: matrixElement) ?? ""
        }
        for variable in ((try? element.nodes(forXPath: "./Properties/Static/OverrideVariable/Variable")) ?? []).compactMap({ $0 as? XMLElement }) {
            guard let name = attribute("Name", on: variable), !name.isEmpty else { continue }
            metadata.libraryOverrides[name] = attribute("Value", on: variable) ?? ""
        }

        if kind == .image {
            metadata.visualType = attribute("Type", on: element) ?? ""
            metadata.visualDepth = attribute("Depth", on: element) ?? ""
            metadata.tintColorHex = firstAttribute("Color", fromXPath: ["./Properties/Static/StartColor"], on: element) ?? ""
            metadata.isMirrored = isMirroredMatrixImage(element)
            if let path = Vector2AssetCatalog.imagePath(forClassName: metadata.className) {
                metadata.imagePath = path
            } else {
                RoomWeaverDiagnostics.shared.missingTexture(className: metadata.className)
                metadata.visualType = "RoomWeaverUnresolvedImage"
            }
            metadata.visualNativeWidth = parseInteger(attribute("NativeX", on: element)) ?? 0
            metadata.visualNativeHeight = parseInteger(attribute("NativeY", on: element)) ?? 0
        }

        if (kind == .platform || kind == .trapezoid), metadata.sortingLayer.isEmpty {
            metadata.sortingLayer = "Collision"
        }

        if kind == .trapezoid, metadata.imagePath.isEmpty {
            let isType2 = attribute("Type", on: element) == "2"
            let style: Vector2EditorVisuals.TrapezoidStyle = isType2 ? .right : .left
            metadata.imagePath = Vector2EditorVisuals.trapezoidTexturePath(style: style) ?? ""
            metadata.visualType = attribute("Type", on: element) ?? ""
            // Element.CreateTrapezoid temporarily shifts Type 1 while building
            // its points, but TrapezoidRunner.CalcPoints folds that shift back
            // into the generated vertices. The final rendered bounds start at
            // the XML Y for both variants; applying Width / 2 here displaced the
            // purple editor preview while Play mode remained correct.
        }

        if kind == .gateIn || kind == .gateOut {
            let spawnVisual = Vector2SpawnPrefabVisual.metadata(for: kind)
            metadata.filename = metadata.filename.isEmpty ? spawnVisual.filename : metadata.filename
            metadata.className = metadata.className.isEmpty ? spawnVisual.className : metadata.className
            metadata.imagePath = spawnVisual.imagePath
        }

        return metadata
    }

    /// The importer keeps only the active room variant, so conditions inside
    /// preserved Properties must become unconditional too. This especially
    /// matters for library references whose raw Properties are reused verbatim
    /// by the exporter.
    private static func flattenedPropertiesXML(_ properties: XMLElement) -> String {
        guard let copy = properties.copy() as? XMLElement else {
            return properties.xmlString(options: .nodeCompactEmptyElement)
        }
        let selections = (try? copy.nodes(forXPath: ".//Selection")) ?? []
        for selection in selections {
            selection.detach()
        }
        return copy.xmlString(options: .nodeCompactEmptyElement)
    }

    private static func mergedDynamicXML(_ existing: String, _ imported: String) -> String {
        [existing, imported]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private static func isMirroredMatrixImage(_ element: XMLElement) -> Bool {
        guard let matrixElement = firstElement(fromXPath: "./Properties/Static/Matrix", on: element),
              let a = parseDouble(attribute("A", on: matrixElement)),
              let b = parseDouble(attribute("B", on: matrixElement)),
              let c = parseDouble(attribute("C", on: matrixElement)),
              let d = parseDouble(attribute("D", on: matrixElement)) else {
            return false
        }
        return (a * d - b * c) < 0
    }

    private static func imageMatrixTransform(from element: XMLElement, x: Int, y: Int) -> LevelNode.Transform? {
        guard let matrixElement = firstElement(fromXPath: "./Properties/Static/Matrix", on: element),
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

    private static func rasterizedImageMatrixPath(from element: XMLElement, imagePath: String, className: String) -> String? {
        // Imported Nekki rooms use negative and rotated image matrices all over
        // the place. Bake those import-only transforms once so the SwiftUI
        // canvas can draw a stable rectangle instead of hundreds of live affine
        // image views that drift while scrolling.
        guard let x = parseDouble(attribute("X", on: element)),
              let y = parseDouble(attribute("Y", on: element)),
              let matrixElement = firstElement(fromXPath: "./Properties/Static/Matrix", on: element),
              let a = parseDouble(attribute("A", on: matrixElement)),
              let b = parseDouble(attribute("B", on: matrixElement)),
              let c = parseDouble(attribute("C", on: matrixElement)),
              let d = parseDouble(attribute("D", on: matrixElement)),
              let sprite = CachedImageStore.shared.image(at: imagePath),
              sprite.size.width > 0,
              sprite.size.height > 0 else {
            return nil
        }

        let tx = parseDouble(attribute("Tx", on: matrixElement)) ?? 0
        let ty = parseDouble(attribute("Ty", on: matrixElement)) ?? 0
        let originX = x + tx
        let originY = y + ty
        let corners = [
            (originX, originY),
            (originX + a, originY + b),
            (originX + a + c, originY + b + d),
            (originX + c, originY + d)
        ]
        let minX = corners.map { $0.0 }.min() ?? originX
        let maxX = corners.map { $0.0 }.max() ?? originX
        let minY = corners.map { $0.1 }.min() ?? originY
        let maxY = corners.map { $0.1 }.max() ?? originY
        let width = max(1, Int((maxX - minX).rounded(.up)))
        let height = max(1, Int((maxY - minY).rounded(.up)))

        let cacheRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Vector2LevelEditorRoomImagePreviews", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        let signature = [
            "room-image-matrix-v4-4096",
            className,
            imagePath,
            pretty(x),
            pretty(y),
            pretty(a),
            pretty(b),
            pretty(c),
            pretty(d),
            pretty(tx),
            pretty(ty),
            "\(width)x\(height)"
        ].joined(separator: "|")
        let filename = className
            .replacingOccurrences(of: #"[^A-Za-z0-9_-]"#, with: "_", options: .regularExpression)
            .prefix(48)
        let outputURL = cacheRoot.appendingPathComponent("\(filename)_\(stableHash(signature)).png")
        if FileManager.default.fileExists(atPath: outputURL.path) {
            return outputURL.path
        }

        // Give large imported walls more detail when zooming in. Keep smaller
        // previews at their original size; extra pixels cost memory quickly.
        let maxSide: CGFloat = 4096
        let scale = min(1, maxSide / CGFloat(max(width, height)))
        let canvasSize = NSSize(
            width: max(1, CGFloat(width) * scale),
            height: max(1, CGFloat(height) * scale)
        )
        let image = NSImage(size: canvasSize)
        image.lockFocus()
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: canvasSize).fill()

        let graphics = NSGraphicsContext.current
        graphics?.saveGraphicsState()
        let topLeftX = CGFloat(originX - minX) * scale
        let topLeftY = CGFloat(maxY - originY) * scale
        let scaledA = CGFloat(a) * scale
        let scaledB = CGFloat(b) * scale
        let scaledC = CGFloat(c) * scale
        let scaledD = CGFloat(d) * scale
        let bottomLeft = NSPoint(
            x: topLeftX + scaledC,
            y: topLeftY - scaledD
        )
        let transform = NSAffineTransform()
        transform.transformStruct = NSAffineTransformStruct(
            m11: scaledA / sprite.size.width,
            m12: -scaledB / sprite.size.width,
            m21: -scaledC / sprite.size.height,
            m22: scaledD / sprite.size.height,
            tX: bottomLeft.x,
            tY: bottomLeft.y
        )
        transform.concat()
        sprite.draw(
            in: NSRect(origin: .zero, size: sprite.size),
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
        graphics?.restoreGraphicsState()
        image.unlockFocus()

        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .png, properties: [:]) else {
            return nil
        }
        try? data.write(to: outputURL)
        return outputURL.path
    }

    private static func levelKind(for tag: String) -> LevelNode.Kind {
        switch tag {
        case "Track": .track
        case "Objects": .object
        case "Object": .object
        case "Image": .image
        case "UnityModel", "Particle", "Animation", "CustomAnimation": .image
        case "Platform": .platform
        case "Trapezoid": .trapezoid
        case "Trigger", "DynamicTrigger": .trigger
        case "Area", "Sensor": .area
        case "ObjectReference": .objectReference
        case "Waypoint", "Spawn", "SoundSource", "Placeholder", "Item", "Lightning": .waypoint
        case "In": .gateIn
        case "Out": .gateOut
        case "Camera": .camera
        case "Dynamic": .dynamic
        default: .object
        }
    }

    private static func defaultWidth(for tag: String?) -> Int {
        switch tag {
        case "In", "Out": 72
        case "ObjectReference", "Object": 100
        case "Image", "UnityModel": 120
        default: 100
        }
    }

    private static func defaultHeight(for tag: String?) -> Int {
        switch tag {
        case "In", "Out": 72
        case "ObjectReference", "Object": 100
        case "Image", "UnityModel": 120
        default: 100
        }
    }

    private static func parseInteger(_ raw: String?) -> Int? {
        guard let raw, !raw.isEmpty else { return nil }
        guard let number = Double(raw.replacingOccurrences(of: ",", with: ".")) else { return nil }
        return Int(number.rounded())
    }

    private static func parseDouble(_ raw: String?) -> Double? {
        guard let raw, !raw.isEmpty else { return nil }
        return Double(raw.replacingOccurrences(of: ",", with: "."))
    }

    private static func pretty(_ value: Double) -> String {
        let rounded = (value * 10_000).rounded() / 10_000
        if abs(rounded.rounded() - rounded) < 0.0001 {
            return "\(Int(rounded.rounded()))"
        }
        return String(format: "%.4f", rounded)
            .replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\.$"#, with: "", options: .regularExpression)
    }

    private static func stableHash(_ text: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    private static func childElements(of element: XMLElement) -> [XMLElement] {
        (element.children ?? []).compactMap { $0 as? XMLElement }
    }

    private static func firstElement(fromXPath xpath: String, on element: XMLElement) -> XMLElement? {
        (try? element.nodes(forXPath: xpath).first) as? XMLElement
    }

    private static func attribute(_ name: String, on element: XMLElement) -> String? {
        element.attribute(forName: name)?.stringValue
    }

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
