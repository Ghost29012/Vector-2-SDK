//
//  Exporter.swift
//  Vector2 level editor
//
//  Vector 2 XML export.
//
//  This is the "will the game actually load it?" file. Editor-only helpers get
//  filtered here, library parents become the right ObjectReference/Object shape,
//  images keep their matrix/native size data, and trapezoids follow the Unity
//  BuildMap contract. If Windows disagrees with this file, Windows is wrong.
//

import SwiftUI
import AppKit
import Foundation

extension Color {
    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let bestMatch = appearance.bestMatch(from: [.darkAqua, .aqua])
            return bestMatch == .darkAqua ? dark : light
        })
    }

    static var platformWindowBackground: Color {
        adaptive(light: .white, dark: NSColor(calibratedRed: 0.105, green: 0.105, blue: 0.105, alpha: 1))
    }
    static var platformControlBackground: Color {
        adaptive(light: NSColor(calibratedRed: 0.972, green: 0.972, blue: 0.982, alpha: 1),
                 dark: NSColor(calibratedRed: 0.135, green: 0.135, blue: 0.135, alpha: 1))
    }
    static var editorChromeBackground: Color {
        adaptive(light: NSColor(calibratedRed: 0.965, green: 0.965, blue: 0.972, alpha: 1),
                 dark: NSColor(calibratedRed: 0.105, green: 0.105, blue: 0.105, alpha: 1))
    }
    static var editorToolbarBackground: Color {
        adaptive(light: NSColor(calibratedRed: 0.972, green: 0.972, blue: 0.982, alpha: 1),
                 dark: NSColor(calibratedRed: 0.125, green: 0.125, blue: 0.125, alpha: 1))
    }
    static var editorTabBarBackground: Color {
        adaptive(light: NSColor(calibratedRed: 0.895, green: 0.878, blue: 0.842, alpha: 1),
                 dark: NSColor(calibratedRed: 0.135, green: 0.135, blue: 0.135, alpha: 1))
    }
    static var editorSelectedTabBackground: Color {
        adaptive(light: .white, dark: NSColor(calibratedRed: 0.185, green: 0.185, blue: 0.195, alpha: 1))
    }
    static var editorUnselectedTabBackground: Color {
        adaptive(light: NSColor(calibratedRed: 0.935, green: 0.925, blue: 0.902, alpha: 1),
                 dark: NSColor(calibratedRed: 0.155, green: 0.155, blue: 0.165, alpha: 1))
    }
    static var editorCanvasBackground: Color {
        adaptive(light: .white, dark: NSColor(calibratedRed: 0.072, green: 0.078, blue: 0.088, alpha: 1))
    }
    static var editorGridLine: Color {
        adaptive(light: NSColor(calibratedRed: 0.79, green: 0.80, blue: 0.81, alpha: 1),
                 dark: NSColor(calibratedRed: 0.24, green: 0.255, blue: 0.285, alpha: 1))
    }
    static var editorPrimaryText: Color {
        adaptive(light: NSColor(calibratedWhite: 0.12, alpha: 1),
                 dark: NSColor(calibratedWhite: 0.88, alpha: 1))
    }
    static var editorSecondaryText: Color {
        adaptive(light: NSColor(calibratedWhite: 0.42, alpha: 1),
                 dark: NSColor(calibratedWhite: 0.66, alpha: 1))
    }
    static var editorHairline: Color {
        adaptive(light: NSColor(calibratedWhite: 0, alpha: 0.12),
                 dark: NSColor(calibratedWhite: 1, alpha: 0.14))
    }
    static var editorSectionHeaderBackground: Color {
        adaptive(light: NSColor(calibratedRed: 0.885, green: 0.900, blue: 0.930, alpha: 1),
                 dark: NSColor(calibratedRed: 0.150, green: 0.150, blue: 0.150, alpha: 1))
    }
    static var editorHierarchySelectionBackground: Color {
        adaptive(light: NSColor(calibratedRed: 0.840, green: 0.890, blue: 0.980, alpha: 1),
                 dark: NSColor(calibratedRed: 0.145, green: 0.215, blue: 0.340, alpha: 1))
    }
    static var editorHierarchySelectionStroke: Color {
        adaptive(light: NSColor(calibratedRed: 0.620, green: 0.710, blue: 0.880, alpha: 1),
                 dark: NSColor(calibratedRed: 0.250, green: 0.360, blue: 0.560, alpha: 1))
    }
}

extension LevelDocument {
    /// Serializes the current document into Vector 2 room XML.
    ///
    /// This is the final game contract. Everything editor-only must be filtered
    /// before it reaches this function. If a map works in the editor but not in
    /// game, compare this output against known-good Vector 2 XML first.
    func exportedXML() -> String {
        let root = XMLElement(name: "Root")
        if let structuralRoomKind {
            root.addAttribute(XMLNode.attribute(withName: "EditorStructuralRoom", stringValue: structuralRoomKind.rawValue) as! XMLNode)
        }
        if !roomLayoutOptions.isEmpty {
            // RoomWeaver normally imports one generated branch for inspection.
            // Our own rooms need every branch back when reopened for authoring.
            root.addAttribute(XMLNode.attribute(withName: "EditorRoomLayouts", stringValue: "1") as! XMLNode)
        }
        let track = XMLElement(name: "Track")
        let content = XMLElement(name: "Content")
        if let aiCharacters = exportedAICharacters() {
            root.addChild(aiCharacters)
        }
        if !playerSkinFiles.isEmpty {
            let appearance = XMLElement(name: "PlayerAppearance")
            appearance.addAttribute(XMLNode.attribute(withName: "Skins", stringValue: playerSkinFiles.joined(separator: "|")) as! XMLNode)
            root.addChild(appearance)
        }
        if let selection = exportedStructuralRoomSelectionElement() ?? exportedRoomLayoutSelectionElement() {
            let properties = XMLElement(name: "Properties")
            properties.addChild(selection)
            track.addChild(properties)
        }
        track.addChild(content)
        root.addChild(track)

        if hasCustomBackgroundAssignment,
           !customBackgroundName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            root.addAttribute(XMLNode.attribute(withName: "CustomBackground", stringValue: customBackgroundName) as! XMLNode)
        }

        let nodes = rootSceneNodesForExport()
        for node in nodes.compactMap(roomNodeForExport) {
            if let element = exportElement(for: node, parentTransform: nil) {
                content.addChild(element)
            }
        }

        let document = XMLDocument(rootElement: root)
        document.version = "1.0"
        document.characterEncoding = "utf-8"
        let xml = document.xmlString(options: [.nodePrettyPrint])
        RoomWeaverDiagnostics.shared.auditExport(
            documentName: name,
            nodes: self.root.allDescendantsIncludingSelf(),
            xml: xml
        )
        return xml
    }

    private func exportedAICharacters() -> XMLElement? {
        guard !aiCharacters.isEmpty || !aiGroups.isEmpty else { return nil }
        let container = XMLElement(name: "AICharacters")
        for character in aiCharacters {
            let element = XMLElement(name: "AICharacter")
            element.addAttribute(XMLNode.attribute(withName: "EditorID", stringValue: character.id.uuidString) as! XMLNode)
            element.addAttribute(XMLNode.attribute(withName: "Name", stringValue: character.name) as! XMLNode)
            element.addAttribute(XMLNode.attribute(withName: "Kind", stringValue: character.kind.rawValue) as! XMLNode)
            element.addAttribute(XMLNode.attribute(withName: "AI", stringValue: "\(character.aiChannel)") as! XMLNode)
            element.addAttribute(XMLNode.attribute(withName: "BirthSpawn", stringValue: character.birthSpawn) as! XMLNode)
            element.addAttribute(XMLNode.attribute(withName: "Time", stringValue: String(format: "%.3f", character.startDelay)) as! XMLNode)
            element.addAttribute(XMLNode.attribute(withName: "Skins", stringValue: character.skinFiles.joined(separator: "|")) as! XMLNode)
            let waitsForSpawnTrigger = root.flattenedSceneNodes().contains { node in
                node.kind == .trigger
                    && node.metadata.aiActionTemplate == "Spawn"
                    && resolvedAITargets(node.metadata.aiTarget).contains(where: { $0.id == character.id })
            }
            element.addAttribute(XMLNode.attribute(
                withName: "SpawnOnStart",
                stringValue: waitsForSpawnTrigger ? "0" : "1"
            ) as! XMLNode)
            container.addChild(element)
        }
        if !aiGroups.isEmpty {
            let groups = XMLElement(name: "Groups")
            for group in aiGroups {
                let element = XMLElement(name: "Group")
                element.addAttribute(XMLNode.attribute(withName: "EditorID", stringValue: group.id.uuidString) as! XMLNode)
                element.addAttribute(XMLNode.attribute(withName: "Name", stringValue: group.name) as! XMLNode)
                element.addAttribute(XMLNode.attribute(withName: "Members", stringValue: group.characterIDs.map(\.uuidString).sorted().joined(separator: "|")) as! XMLNode)
                groups.addChild(element)
            }
            container.addChild(groups)
        }
        return container
    }

    /// Serializes just one selected node for the Raw XML panel.
    ///
    /// This is a preview/debug helper, not a separate exporter. It uses the same
    /// `exportElement` routing so the inspector shows what the real export would
    /// write for that node.
    func exportedSelectionXML(for id: LevelNode.ID) -> String {
        guard let node = root.find(id: id), let element = exportElement(for: node, parentTransform: nil) else {
            return "<!-- Nothing selected -->"
        }
        return element.xmlString(options: [.nodePrettyPrint])
    }

    /// Finds gameplay nodes under Document/Track/Factor wrappers.
    ///
    /// The editor keeps the XML hierarchy for sanity, but the final room output
    /// needs the actual scene elements. This unwrap keeps BuildMap Vec2 layout
    /// stable when opening/exporting edited files.
    private func rootSceneNodesForExport() -> [LevelNode] {
        if root.kind == .document {
            let tracks = root.children.filter { $0.kind == .track }
            if !tracks.isEmpty {
                return tracks.flatMap { track in
                    track.children.flatMap { factorNode in
                        factorNode.kind == .factor ? factorNode.children : [factorNode]
                    }
                }
            }
        }
        return root.children
    }

    /// Assigned custom backgrounds live in custom_backgrounds.xml. Keep their
    /// scene nodes editable, but do not bake a second copy into the room XML.
    private func roomNodeForExport(_ node: LevelNode) -> LevelNode? {
        guard hasCustomBackgroundAssignment else { return node }
        let assignment = customBackgroundName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !assignment.isEmpty, assignment.caseInsensitiveCompare("none") != .orderedSame else { return node }
        if node.kind == .image,
           (node.metadata.tag.caseInsensitiveCompare("Background") == .orderedSame
            || node.metadata.sortingLayer.hasPrefix("Bg")) {
            return nil
        }
        var filtered = node
        filtered.children = node.children.compactMap(roomNodeForExport)
        return filtered
    }

    /// Routes a `LevelNode` to the matching Vector 2 XML element.
    ///
    /// Returning nil means "editor/container only". That is why Comment boxes
    /// are safe: they are useful on canvas but never become game data.
    private func exportElement(for node: LevelNode, parentTransform: LevelNode.Transform?) -> XMLElement? {
        if shouldCenterDynamicRotation(for: node) {
            return exportCenteredDynamicNode(node, parentTransform: parentTransform)
        }
        if shouldWrapAttachedChildren(for: node) {
            return exportNodeWithAttachedChildren(node, parentTransform: parentTransform)
        }

        switch node.kind {
        case .document, .track, .factor, .comment:
            return nil
        case .image:
            return exportImage(node, parentTransform: parentTransform)
        case .platform:
            return exportPlatform(node, parentTransform: parentTransform)
        case .trapezoid:
            return exportTrapezoid(node, parentTransform: parentTransform)
        case .trigger:
            return exportTrigger(node, parentTransform: parentTransform)
        case .area:
            return exportArea(node, parentTransform: parentTransform)
        case .gateIn:
            return exportGate(node, name: "In", parentTransform: parentTransform)
        case .gateOut:
            return exportGate(node, name: "Out", parentTransform: parentTransform)
        case .objectReference, .coin:
            return exportObjectReference(node, parentTransform: parentTransform)
        case .camera:
            guard let transform = localizedTransform(for: node, parentTransform: parentTransform) else { return nil }
            let element = XMLElement(name: "Camera")
            addImportedAttributes(from: node, to: element, excluding: ["Name", "X", "Y", "Zoom"])
            addIfNotEmpty("Name", value: node.name, to: element)
            addTransformAttributes(to: element, transform: transform, includeSize: false)
            element.addAttribute(XMLNode.attribute(withName: "Zoom", stringValue: node.metadata.sourceAttributes["Zoom"] ?? "0") as! XMLNode)
            return element
        case .waypoint:
            return exportWaypoint(node, parentTransform: parentTransform)
        case .object, .dynamic:
            if shouldExportAsObjectReference(node) {
                return exportObjectReference(node, parentTransform: parentTransform)
            }
            return exportObject(node, parentTransform: parentTransform)
        }
    }

    /// Vector 2 applies RotationInterval around the XML runner's origin, while
    /// the editor rotates selection bounds around their center. A lightweight
    /// Object wrapper puts the runtime origin at that same visual center. The
    /// actual node remains offset inside it, so its static pose and children do
    /// not change.
    private func shouldCenterDynamicRotation(for node: LevelNode) -> Bool {
        guard let transform = node.transform, transform.width > 0, transform.height > 0 else { return false }
        guard !node.metadata.visualType.hasPrefix("RoomWeaver") else { return false }
        // Imported runners already own their runtime pivot. New editor objects
        // have no source coordinates, so their rotation timeline uses the
        // editor's center-pivot wrapper without saving a second private timeline.
        guard node.metadata.sourceX.isEmpty && node.metadata.sourceY.isEmpty else { return false }
        return node.metadata.dynamicXML.range(
            of: "<RotationInterval",
            options: [.caseInsensitive]
        ) != nil
    }

    private func exportCenteredDynamicNode(_ node: LevelNode, parentTransform: LevelNode.Transform?) -> XMLElement? {
        guard let baseTransform = exportBaseTransform(for: node),
              let localized = localizedTransform(for: node, parentTransform: parentTransform) else { return nil }

        let wrapper = XMLElement(name: "Object")
        addIfNotEmpty("Name", value: node.name.isEmpty ? "DynamicPivot" : "\(node.name)_DynamicPivot", to: wrapper)
        wrapper.addAttribute(XMLNode.attribute(withName: "X", stringValue: "\(localized.x + localized.width / 2)") as! XMLNode)
        wrapper.addAttribute(XMLNode.attribute(withName: "Y", stringValue: "\(localized.y + localized.height / 2)") as! XMLNode)

        var pivotTransform = baseTransform
        pivotTransform.x += baseTransform.width / 2
        pivotTransform.y += baseTransform.height / 2

        var contentNode = node
        contentNode.metadata.dynamicXML = ""
        contentNode.metadata.dynamicTriggerXML = ""
        // Force the cloned node through the current transform path. Imported
        // source coordinates describe the old parent and would bypass the new
        // centered wrapper.
        contentNode.metadata.sourceX = ""
        contentNode.metadata.sourceY = ""
        contentNode.metadata.sourceWidth = ""
        contentNode.metadata.sourceHeight = ""
        contentNode.metadata.isTransformEdited = true

        let content = XMLElement(name: "Content")
        if let child = exportElement(for: contentNode, parentTransform: pivotTransform) {
            content.addChild(child)
        }
        wrapper.addChild(content)
        addDynamicProperties(to: wrapper, node: node)
        return wrapper
    }

    private func attachedExportChildren(for node: LevelNode) -> [LevelNode] {
        node.children.filter { child in
            child.metadata.isHierarchyAttachment && !child.metadata.isHidden
        }
    }

    private func shouldWrapAttachedChildren(for node: LevelNode) -> Bool {
        guard !attachedExportChildren(for: node).isEmpty else { return false }

        // Plain Object/Dynamic nodes already export nested Content correctly.
        // Everything else needs an Object wrapper or its manually-parented
        // children get dropped by XML tags that cannot legally own Content.
        if node.kind == .object || node.kind == .dynamic {
            return shouldExportAsObjectReference(node)
        }
        return node.kind != .document && node.kind != .track && node.kind != .factor && node.kind != .comment
    }

    private func exportNodeWithAttachedChildren(_ node: LevelNode, parentTransform: LevelNode.Transform?) -> XMLElement? {
        guard let transform = localizedTransform(for: node, parentTransform: parentTransform) else { return nil }
        let wrapper = XMLElement(name: "Object")
        addIfNotEmpty("Name", value: node.name.isEmpty ? node.kind.defaultTag : node.name, to: wrapper)
        wrapper.addAttribute(XMLNode.attribute(withName: "X", stringValue: "\(transform.x)") as! XMLNode)
        wrapper.addAttribute(XMLNode.attribute(withName: "Y", stringValue: "\(transform.y)") as! XMLNode)

        let content = XMLElement(name: "Content")
        if let wrappedSelf = exportWrappedSelf(node) {
            content.addChild(wrappedSelf)
        }

        for child in attachedExportChildren(for: node) {
            if let childElement = exportElement(for: child, parentTransform: exportBaseTransform(for: node)) {
                content.addChild(childElement)
            }
        }

        if content.childCount > 0 {
            wrapper.addChild(content)
        }
        addDynamicProperties(to: wrapper, node: node)
        return wrapper
    }

    private func exportWrappedSelf(_ node: LevelNode) -> XMLElement? {
        var localNode = node
        localNode.children = []
        localNode.metadata.dynamicXML = ""
        localNode.metadata.dynamicTriggerXML = ""
        if var transform = localNode.transform {
            transform.x = 0
            transform.y = 0
            localNode.transform = transform
        }

        switch node.kind {
        case .image:
            return exportImage(localNode, parentTransform: nil)
        case .platform:
            return exportPlatform(localNode, parentTransform: nil)
        case .trapezoid:
            return exportTrapezoid(localNode, parentTransform: nil)
        case .trigger:
            return exportTrigger(localNode, parentTransform: nil)
        case .area:
            return exportArea(localNode, parentTransform: nil)
        case .gateIn:
            return exportGate(localNode, name: "In", parentTransform: nil)
        case .gateOut:
            return exportGate(localNode, name: "Out", parentTransform: nil)
        case .objectReference, .coin, .camera:
            return exportObjectReference(localNode, parentTransform: nil)
        case .object, .dynamic:
            return shouldExportAsObjectReference(localNode)
                ? exportObjectReference(localNode, parentTransform: nil)
                : exportObject(localNode, parentTransform: nil)
        case .document, .track, .factor, .comment, .waypoint:
            return nil
        }
    }

    private func shouldExportAsObjectReference(_ node: LevelNode) -> Bool {
        guard !node.metadata.filename.isEmpty else { return false }
        if node.xml.template == "LibraryObject" || node.xml.template == "EditorPrefab" || node.xml.template == "EditorPrefabPhantom" {
            return true
        }
        return node.xml.variant == "Resolved" || node.xml.variant == "Prefab"
    }

    /// Exports texture/background image nodes.
    ///
    /// Images use Vector 2 matrix data when needed. This is where rotated images
    /// differ from simple rectangles, so do not replace this with generic
    /// X/Y/Width/Height export.
    private func exportImage(_ node: LevelNode, parentTransform: LevelNode.Transform?) -> XMLElement? {
        guard let transform = localizedTransform(for: node, parentTransform: parentTransform) else { return nil }
        let gifName = URL(fileURLWithPath: node.metadata.imagePath).pathExtension.lowercased() == "gif"
            ? URL(fileURLWithPath: node.metadata.imagePath).deletingPathExtension().lastPathComponent
            : nil
        let isGIF = gifName != nil || node.metadata.sourceAttributes["EditorSourceGIF"] != nil
        let element = XMLElement(name: isGIF ? "CustomAnimation" : "Image")
        let importedMatrix = node.metadata.isTransformEdited ? nil : importedImageMatrixElement(for: node)
        if importedMatrix != nil {
            addIfNotEmpty("X", value: node.metadata.sourceX.isEmpty ? "\(transform.x)" : node.metadata.sourceX, to: element)
            addIfNotEmpty("Y", value: node.metadata.sourceY.isEmpty ? "\(transform.y)" : node.metadata.sourceY, to: element)
            addIfNotEmpty("Width", value: node.metadata.sourceWidth.isEmpty ? "\(transform.width)" : node.metadata.sourceWidth, to: element)
            addIfNotEmpty("Height", value: node.metadata.sourceHeight.isEmpty ? "\(transform.height)" : node.metadata.sourceHeight, to: element)
        } else {
            addTransformAttributes(to: element, transform: imageXMLTransform(for: node, transform: transform), includeSize: true)
        }
        if isGIF {
            let source = node.metadata.sourceAttributes["EditorSourceGIF"] ?? URL(fileURLWithPath: node.metadata.imagePath).lastPathComponent
            let manifest = node.metadata.sourceAttributes["ClassName"] ?? "gif_\(gifName ?? URL(fileURLWithPath: source).deletingPathExtension().lastPathComponent).xml"
            element.addAttribute(XMLNode.attribute(withName: "ClassName", stringValue: manifest) as! XMLNode)
            element.addAttribute(XMLNode.attribute(withName: "EditorSourceGIF", stringValue: source) as! XMLNode)
            element.addAttribute(XMLNode.attribute(withName: "Speed", stringValue: "30") as! XMLNode)
            element.addAttribute(XMLNode.attribute(withName: "Iterations", stringValue: "-1") as! XMLNode)
        } else if !node.metadata.className.isEmpty {
            element.addAttribute(XMLNode.attribute(withName: "ClassName", stringValue: node.metadata.className) as! XMLNode)
        }
        addIfNotEmpty("Layer", value: node.metadata.sortingLayer, to: element)
        addIfNotEmpty("Factor", value: node.factor, to: element)
        addIfNotEmpty("Tag", value: node.metadata.tag, to: element)
        addIfNotEmpty("Type", value: node.metadata.visualType.isEmpty ? "3" : node.metadata.visualType, to: element)
        addIfNotEmpty("Depth", value: node.metadata.visualDepth.isEmpty ? "0" : node.metadata.visualDepth, to: element)
        let nativeSize = nativeImageSize(for: node, fallback: transform)
        addIfNotEmpty("NativeX", value: "\(nativeSize.width)", to: element)
        addIfNotEmpty("NativeY", value: "\(nativeSize.height)", to: element)

        addImportedAttributes(
            from: node,
            to: element,
            excluding: ["X", "Y", "Width", "Height", "ClassName", "EditorSourceGIF", "Speed", "Iterations", "Layer", "Factor", "Tag", "Type", "Depth", "NativeX", "NativeY"]
        )
        let properties = sourcePropertiesElement(for: node) ?? XMLElement(name: "Properties")
        let staticNode = properties.elements(forName: "Static").first ?? XMLElement(name: "Static")
        if staticNode.parent == nil { properties.addChild(staticNode) }
        removeChildren(named: ["Matrix", "Selection", "BlendMode"], from: staticNode)
        staticNode.addChild(importedMatrix ?? matrixElement(for: node, transform: transform))
        if shouldExportImageSelection(node) {
            appendSelectionElements(from: node, to: staticNode)
        }
        if node.xml.blend != "Normal" {
            let blend = XMLElement(name: "BlendMode")
            addIfNotEmpty("Mode", value: node.xml.blend, to: blend)
            staticNode.addChild(blend)
        }
        addDynamicProperties(toProperties: properties, node: node)
        element.addChild(properties)
        return element
    }

    private func imageXMLTransform(for node: LevelNode, transform: LevelNode.Transform) -> LevelNode.Transform {
        let pivotOffset = Vector2AssetCatalog.spritePivotOffset(
            forClassName: node.metadata.className,
            width: transform.width,
            height: transform.height
        )
        guard pivotOffset.x != 0 || pivotOffset.y != 0 else { return transform }
        var xmlTransform = transform
        xmlTransform.x += pivotOffset.x
        xmlTransform.y += pivotOffset.y
        return xmlTransform
    }

    private func shouldExportImageSelection(_ node: LevelNode) -> Bool {
        let choice = node.xml.choice.trimmingCharacters(in: .whitespacesAndNewlines)
        let variant = node.xml.variant.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !choice.isEmpty || !variant.isEmpty || !node.xml.additionalSelections.isEmpty else { return false }

        // Plain room images in Vector 2 are identified by ClassName/Layer/Type/Depth.
        // Browser categories like Choice="black" Variant="Default" are editor-side noise
        // for direct images and can make exported custom rooms diverge from Nekki XML.
        if node.xml.template == "Image",
           variant.localizedCaseInsensitiveCompare("Default") == .orderedSame {
            return false
        }
        return true
    }

    /// Exports collision platforms.
    ///
    /// Axis-aligned platforms are simple `<Platform>` nodes. Rotated platforms
    /// have to be wrapped as an object/matrix form because the game treats
    /// rotated collision differently from normal rectangle XML.
    private func exportPlatform(_ node: LevelNode, parentTransform: LevelNode.Transform?) -> XMLElement? {
        guard let transform = localizedTransform(for: node, parentTransform: parentTransform) else { return nil }
        if abs(transform.rotation) > 0.001 {
            return exportRotatedPlatform(node, transform: transform)
        }
        let element = XMLElement(name: "Platform")
        addImportedAttributes(from: node, to: element, excluding: ["X", "Y", "Width", "Height", "Sticky"])
        addTransformAttributes(to: element, transform: transform, includeSize: true)
        if node.xml.variant.localizedCaseInsensitiveContains("sticky") || node.metadata.sourceAttributes["Sticky"] == "1" {
            element.addAttribute(XMLNode.attribute(withName: "Sticky", stringValue: "1") as! XMLNode)
        }
        addStaticSelection(to: element, from: node)
        addDynamicProperties(to: element, node: node)
        return element
    }

    private func exportRotatedPlatform(_ node: LevelNode, transform: LevelNode.Transform) -> XMLElement {
        let object = XMLElement(name: "Object")
        addIfNotEmpty("Name", value: node.name.isEmpty ? "Platform" : node.name, to: object)
        object.addAttribute(XMLNode.attribute(withName: "X", stringValue: "\(transform.x)") as! XMLNode)
        object.addAttribute(XMLNode.attribute(withName: "Y", stringValue: "\(transform.y)") as! XMLNode)

        let content = XMLElement(name: "Content")
        let platform = XMLElement(name: "Platform")
        platform.addAttribute(XMLNode.attribute(withName: "X", stringValue: "0") as! XMLNode)
        platform.addAttribute(XMLNode.attribute(withName: "Y", stringValue: "0") as! XMLNode)
        platform.addAttribute(XMLNode.attribute(withName: "Width", stringValue: "\(transform.width)") as! XMLNode)
        platform.addAttribute(XMLNode.attribute(withName: "Height", stringValue: "\(transform.height)") as! XMLNode)
        if node.xml.variant.localizedCaseInsensitiveContains("sticky") {
            platform.addAttribute(XMLNode.attribute(withName: "Sticky", stringValue: "1") as! XMLNode)
        }
        content.addChild(platform)
        object.addChild(content)

        let properties = XMLElement(name: "Properties")
        let staticNode = XMLElement(name: "Static")
        staticNode.addChild(rectRotationMatrixElement(width: transform.width, height: transform.height, rotation: transform.rotation, scaled: false))
        properties.addChild(staticNode)
        addDynamicProperties(toProperties: properties, node: node)
        object.addChild(properties)
        addStaticSelection(to: object, from: node)
        return object
    }

    /// Exports trapezoid/slope collision.
    ///
    /// Vector 2's `Element.CreateTrapezoid` only consumes X/Y/Width/Height/Type.
    /// It derives the short side internally as `Height - Width / 2`; old BuildMap
    /// also omits Height1. Keep export on that contract or slopes grow wildly.
    private func exportTrapezoid(_ node: LevelNode, parentTransform: LevelNode.Transform?) -> XMLElement? {
        guard let rawTransform = localizedTransform(for: node, parentTransform: parentTransform) else { return nil }
        let transform = validTrapezoidTransform(rawTransform)
        let type = trapezoidType(for: node)
        let element = XMLElement(name: "Trapezoid")
        addTransformAttributes(to: element, transform: transform, includeSize: false)
        element.addAttribute(XMLNode.attribute(withName: "Width", stringValue: "\(transform.width)") as! XMLNode)
        element.addAttribute(XMLNode.attribute(withName: "Height", stringValue: formattedTrapezoidHeight(for: transform, type: type)) as! XMLNode)
        addIfNotEmpty("Name", value: node.name, to: element)
        element.addAttribute(XMLNode.attribute(withName: "Type", stringValue: type) as! XMLNode)
        addStaticSelection(to: element, from: node)
        addDynamicProperties(to: element, node: node)
        return element
    }

    private func validTrapezoidTransform(_ transform: LevelNode.Transform) -> LevelNode.Transform {
        let minimumHeight = max(1, transform.width / 2 + 1)
        guard transform.height < minimumHeight else { return transform }
        var adjusted = transform
        adjusted.height = minimumHeight
        return adjusted
    }

    private func formattedTrapezoidHeight(for transform: LevelNode.Transform, type: String) -> String {
        formatTrapezoidNumber(Double(max(1, transform.height)))
    }

    private func formatTrapezoidNumber(_ value: Double) -> String {
        if value.rounded() == value {
            return "\(Int(value))"
        }
        return String(format: "%.3f", value)
            .trimmingCharacters(in: CharacterSet(charactersIn: "0"))
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    private func trapezoidType(for node: LevelNode) -> String {
        let variant = node.xml.variant.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let name = node.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let imagePath = node.metadata.imagePath.lowercased()
        let importedType = node.metadata.visualType.trimmingCharacters(in: .whitespacesAndNewlines)
        let isType2 = variant.contains("type2")
            || variant.contains("right")
            || name.contains("type2")
            || imagePath.contains("trapezoid_type2")
            || importedType == "2"
        return isType2 ? "2" : "1"
    }

    /// Exports trigger rectangles.
    ///
    /// Most stunt/camera/gameplay helpers are object references, but plain
    /// trigger regions still serialize as `<Trigger>`.
    private func exportTrigger(_ node: LevelNode, parentTransform: LevelNode.Transform?) -> XMLElement? {
        guard let transform = localizedTransform(for: node, parentTransform: parentTransform) else { return nil }
        // Early editor builds exposed RunInhibition as a Trigger action. Keep
        // those saved rooms working by exporting that old choice as the Area
        // Vector 2 actually reads.
        if let areaName = AnimationAreaPolicy.legacyAreaName(forTriggerTemplate: node.metadata.aiActionTemplate) {
            var areaNode = node
            areaNode.kind = .area
            areaNode.name = areaName
            areaNode.metadata.sourceAttributes.removeValue(forKey: "EditorAITarget")
            areaNode.metadata.sourceAttributes.removeValue(forKey: "EditorAIAction")
            areaNode.metadata.sourceAttributes.removeValue(forKey: "EditorAIValue")
            return exportArea(areaNode, parentTransform: parentTransform)
        }
        if node.metadata.aiTarget == "player",
           !node.metadata.aiActionTemplate.isEmpty,
           (!["Trick", "Animation"].contains(node.metadata.aiActionTemplate)
            || !node.metadata.aiActionValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
            return exportPlayerAnimationTrigger(node, transform: transform)
        }
        if node.metadata.aiTarget == "project",
           node.metadata.aiActionTemplate == "Send Event",
           !node.metadata.aiActionValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return exportProjectEventTrigger(node, transform: transform)
        }
        let aiTargets = resolvedAITargets(node.metadata.aiTarget)
        if !node.metadata.aiActionTemplate.isEmpty,
           (aiTargets.count > 1 || ["Spawn", "Respawn"].contains(node.metadata.aiActionTemplate)) {
            let wrapper = XMLElement(name: "Object")
            wrapper.addAttribute(XMLNode.attribute(withName: "Name", stringValue: node.name.isEmpty ? "AIGroupTrigger" : node.name) as! XMLNode)
            wrapper.addAttribute(XMLNode.attribute(withName: "EditorAITarget", stringValue: node.metadata.aiTarget) as! XMLNode)
            wrapper.addAttribute(XMLNode.attribute(withName: "EditorAIAction", stringValue: node.metadata.aiActionTemplate) as! XMLNode)
            wrapper.addAttribute(XMLNode.attribute(withName: "EditorAIValue", stringValue: node.metadata.aiActionValue) as! XMLNode)
            wrapper.addAttribute(XMLNode.attribute(withName: "X", stringValue: "\(transform.x)") as! XMLNode)
            wrapper.addAttribute(XMLNode.attribute(withName: "Y", stringValue: "\(transform.y)") as! XMLNode)
            let content = XMLElement(name: "Content")
            for target in aiTargets {
                let local = LevelNode.Transform(x: 0, y: 0, width: transform.width, height: transform.height)
                if ["Spawn", "Respawn"].contains(node.metadata.aiActionTemplate),
                   node.metadata.aiActionValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let spawnX = max(0, transform.width / 2)
                    let spawnY = max(0, transform.height / 2)
                    let spawn = XMLElement(name: "Spawn")
                    spawn.addAttribute(XMLNode.attribute(withName: "Name", stringValue: generatedAISpawnName(node: node, target: target)) as! XMLNode)
                    // The spawn marker is the trigger's center, so designers can
                    // place the character directly instead of compensating for
                    // the trigger's height.
                    spawn.addAttribute(XMLNode.attribute(withName: "X", stringValue: "\(spawnX)") as! XMLNode)
                    spawn.addAttribute(XMLNode.attribute(withName: "Y", stringValue: "\(spawnY)") as! XMLNode)
                    spawn.addAttribute(XMLNode.attribute(withName: "Animation", stringValue: "RunForward|0") as! XMLNode)
                    content.addChild(spawn)
                }
                content.addChild(exportAITrigger(node, transform: local, target: target))
            }
            wrapper.addChild(content)
            return wrapper
        }
        let element = XMLElement(name: "Trigger")
        addImportedAttributes(from: node, to: element, excluding: ["Name", "X", "Y", "Width", "Height", "EditorAITarget", "EditorAIAction", "EditorAIValue"])
        addIfNotEmpty("Name", value: node.name, to: element)
        addTransformAttributes(to: element, transform: transform, includeSize: true)

        if !node.metadata.aiActionTemplate.isEmpty, let target = aiTargets.first {
            return exportAITrigger(node, transform: transform, target: target)
        }

        if let sourceContent = sourceContentElement(for: node) {
            element.addChild(sourceContent)
            addDynamicProperties(to: element, node: node)
            return element
        }

        let content = XMLElement(name: "Content")
        let initNode = XMLElement(name: "Init")
        for (name, type, value) in [("$AI", "AI", "0"), ("$Active", "Bool", "1"), ("$Node", "Node", "COM")] {
            let variable = XMLElement(name: "SetVariable")
            variable.addAttribute(XMLNode.attribute(withName: "Name", stringValue: name) as! XMLNode)
            variable.addAttribute(XMLNode.attribute(withName: "Type", stringValue: type) as! XMLNode)
            variable.addAttribute(XMLNode.attribute(withName: "Value", stringValue: value) as! XMLNode)
            initNode.addChild(variable)
        }
        content.addChild(initNode)

        let hasDynamicLoop = !node.metadata.dynamicTriggerXML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // "Trigger" is the editor palette's generic placeholder, not an actual
        // Vector 2 trigger template. Exporting `<Template Name="Trigger">`
        // makes TriggerRunner resolve a missing template and crash ParseLoops,
        // taking down the whole room before Player or AI can spawn.
        if !node.xml.template.isEmpty,
           node.xml.template.caseInsensitiveCompare("Trigger") != .orderedSame,
           !hasDynamicLoop {
            let template = XMLElement(name: "Template")
            template.addAttribute(XMLNode.attribute(withName: "Name", stringValue: node.xml.template) as! XMLNode)
            content.addChild(template)
        }

        if let dynamicLoop = dynamicTriggerLoopElement(for: node) {
            content.addChild(dynamicLoop)
        }

        element.addChild(content)
        addDynamicProperties(to: element, node: node)
        return element
    }

    private func exportPlayerAnimationTrigger(_ node: LevelNode, transform: LevelNode.Transform) -> XMLElement {
        let trigger = XMLElement(name: "Trigger")
        trigger.addAttribute(XMLNode.attribute(withName: "Name", stringValue: node.name.isEmpty ? "PlayerTrick" : node.name) as! XMLNode)
        trigger.addAttribute(XMLNode.attribute(withName: "EditorAITarget", stringValue: "player") as! XMLNode)
        trigger.addAttribute(XMLNode.attribute(withName: "EditorAIAction", stringValue: node.metadata.aiActionTemplate) as! XMLNode)
        trigger.addAttribute(XMLNode.attribute(withName: "EditorAIValue", stringValue: node.metadata.aiActionValue) as! XMLNode)
        addTransformAttributes(to: trigger, transform: transform, includeSize: true)

        let content = XMLElement(name: "Content")
        let initNode = XMLElement(name: "Init")
        for (name, value) in [("$AI", "0"), ("$Active", "1"), ("$Node", "COM")] {
            let variable = XMLElement(name: "SetVariable")
            variable.addAttribute(XMLNode.attribute(withName: "Name", stringValue: name) as! XMLNode)
            variable.addAttribute(XMLNode.attribute(withName: "Value", stringValue: value) as! XMLNode)
            initNode.addChild(variable)
        }
        content.addChild(initNode)

        let loop = XMLElement(name: "Loop")
        let events = XMLElement(name: "Events")
        events.addChild(XMLElement(name: "Enter"))
        loop.addChild(events)
        let actions = XMLElement(name: "Actions")
        let template = node.metadata.aiActionTemplate
        let value = node.metadata.aiActionValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let movement = MovementTriggerPolicy.enterAction(for: template) {
            addControlAction(model: "Player", enabled: movement.controlEnabled, to: actions)
            addPressAction(key: movement.pressedKey, model: "Player", to: actions)
        } else {
            addForceAnimationAction(name: value, frame: template == "Trick" ? -1 : 0, model: "Player", to: actions)
        }
        loop.addChild(actions)
        content.addChild(loop)
        if template == "StopMoveRun" {
            let exitLoop = XMLElement(name: "Loop")
            let exitEvents = XMLElement(name: "Events")
            exitEvents.addChild(XMLElement(name: "Exit"))
            exitLoop.addChild(exitEvents)
            let exitActions = XMLElement(name: "Actions")
            addControlAction(model: "Player", enabled: true, to: exitActions)
            exitLoop.addChild(exitActions)
            content.addChild(exitLoop)
        }
        trigger.addChild(content)
        return trigger
    }

    private func addControlAction(model: String, enabled: Bool, to actions: XMLElement) {
        let control = XMLElement(name: "Control")
        control.addAttribute(XMLNode.attribute(withName: "Model", stringValue: model) as! XMLNode)
        control.addAttribute(XMLNode.attribute(withName: "Switch", stringValue: enabled ? "On" : "Off") as! XMLNode)
        actions.addChild(control)
    }

    private func addPressAction(key: String, model: String, to actions: XMLElement) {
        let press = XMLElement(name: "Press")
        press.addAttribute(XMLNode.attribute(withName: "Key", stringValue: key) as! XMLNode)
        press.addAttribute(XMLNode.attribute(withName: "Model", stringValue: model) as! XMLNode)
        actions.addChild(press)
    }

    private func addForceAnimationAction(name: String, frame: Int, model: String, to actions: XMLElement) {
        let force = XMLElement(name: "ForceAnimation")
        force.addAttribute(XMLNode.attribute(withName: "Name", stringValue: name) as! XMLNode)
        force.addAttribute(XMLNode.attribute(withName: "Model", stringValue: model) as! XMLNode)
        force.addAttribute(XMLNode.attribute(withName: "Frame", stringValue: "\(frame)") as! XMLNode)
        force.addAttribute(XMLNode.attribute(withName: "Reversed", stringValue: "0") as! XMLNode)
        actions.addChild(force)
    }

    private func exportProjectEventTrigger(_ node: LevelNode, transform: LevelNode.Transform) -> XMLElement {
        let trigger = XMLElement(name: "Trigger")
        trigger.addAttribute(XMLNode.attribute(withName: "Name", stringValue: node.name.isEmpty ? "ProjectEvent" : node.name) as! XMLNode)
        trigger.addAttribute(XMLNode.attribute(withName: "EditorAITarget", stringValue: "project") as! XMLNode)
        trigger.addAttribute(XMLNode.attribute(withName: "EditorAIAction", stringValue: "Send Event") as! XMLNode)
        trigger.addAttribute(XMLNode.attribute(withName: "EditorAIValue", stringValue: node.metadata.aiActionValue) as! XMLNode)
        addTransformAttributes(to: trigger, transform: transform, includeSize: true)

        let content = XMLElement(name: "Content")
        let initNode = XMLElement(name: "Init")
        for (name, type, value) in [("$AI", "AI", "0"), ("$Active", "Bool", "1"), ("$Node", "Node", "COM")] {
            let variable = XMLElement(name: "SetVariable")
            variable.addAttribute(XMLNode.attribute(withName: "Name", stringValue: name) as! XMLNode)
            variable.addAttribute(XMLNode.attribute(withName: "Type", stringValue: type) as! XMLNode)
            variable.addAttribute(XMLNode.attribute(withName: "Value", stringValue: value) as! XMLNode)
            initNode.addChild(variable)
        }
        content.addChild(initNode)

        let loop = XMLElement(name: "Loop")
        let events = XMLElement(name: "Events")
        events.addChild(XMLElement(name: "Enter"))
        loop.addChild(events)
        let actions = XMLElement(name: "Actions")
        let call = XMLElement(name: "ExecuteCall")
        call.addAttribute(XMLNode.attribute(withName: "Message", stringValue: node.metadata.aiActionValue.trimmingCharacters(in: .whitespacesAndNewlines)) as! XMLNode)
        actions.addChild(call)
        loop.addChild(actions)
        content.addChild(loop)
        trigger.addChild(content)
        return trigger
    }

    private func resolvedAITargets(_ token: String) -> [AICharacterDefinition] {
        if token == "all" { return aiCharacters }
        let pieces = token.split(separator: ":", maxSplits: 1).map(String.init)
        guard pieces.count == 2, let id = UUID(uuidString: pieces[1]) else { return [] }
        if pieces[0] == "character" {
            return aiCharacters.filter { $0.id == id }
        }
        if pieces[0] == "group", let group = aiGroups.first(where: { $0.id == id }) {
            return aiCharacters.filter { group.characterIDs.contains($0.id) }
        }
        return []
    }

    private func exportAITrigger(
        _ node: LevelNode,
        transform: LevelNode.Transform,
        target: AICharacterDefinition
    ) -> XMLElement {
        let trigger = XMLElement(name: "Trigger")
        trigger.addAttribute(XMLNode.attribute(withName: "Name", stringValue: node.name.isEmpty ? "AI_\(node.metadata.aiActionTemplate)" : node.name) as! XMLNode)
        trigger.addAttribute(XMLNode.attribute(withName: "EditorAITarget", stringValue: node.metadata.aiTarget) as! XMLNode)
        trigger.addAttribute(XMLNode.attribute(withName: "EditorAIAction", stringValue: node.metadata.aiActionTemplate) as! XMLNode)
        trigger.addAttribute(XMLNode.attribute(withName: "EditorAIValue", stringValue: node.metadata.aiActionValue) as! XMLNode)
        addTransformAttributes(to: trigger, transform: transform, includeSize: true)

        let content = XMLElement(name: "Content")
        let initNode = XMLElement(name: "Init")
        let activatingAI = (["Spawn", "Activate Spawn", "Respawn"].contains(node.metadata.aiActionTemplate))
            ? 0
            : target.aiChannel
        for (name, value) in [("$AI", "\(activatingAI)"), ("$Active", "1"), ("$Node", "COM")] {
            let variable = XMLElement(name: "SetVariable")
            variable.addAttribute(XMLNode.attribute(withName: "Name", stringValue: name) as! XMLNode)
            variable.addAttribute(XMLNode.attribute(withName: "Value", stringValue: value) as! XMLNode)
            initNode.addChild(variable)
        }
        content.addChild(initNode)

        let loop = XMLElement(name: "Loop")
        let events = XMLElement(name: "Events")
        events.addChild(XMLElement(name: "Enter"))
        loop.addChild(events)
        let actions = XMLElement(name: "Actions")
        let template = node.metadata.aiActionTemplate
        let value = node.metadata.aiActionValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if template == "WallJump" {
            for (key, frames) in [("Up", ""), (value == "Right" ? "Right" : "Left", "3")] {
                if !frames.isEmpty {
                    let wait = XMLElement(name: "Wait")
                    wait.addAttribute(XMLNode.attribute(withName: "Frames", stringValue: frames) as! XMLNode)
                    actions.addChild(wait)
                }
                let action = XMLElement(name: "Press")
                action.addAttribute(XMLNode.attribute(withName: "Key", stringValue: key) as! XMLNode)
                action.addAttribute(XMLNode.attribute(withName: "Model", stringValue: target.name) as! XMLNode)
                actions.addChild(action)
            }
        } else if ["RunForward", "Jump", "Slide", "Turn"].contains(template) {
            let keyByTemplate = ["RunForward": "Right", "Jump": "Up", "Slide": "Down", "Turn": "Left"]
            let action = XMLElement(name: "Press")
            action.addAttribute(XMLNode.attribute(withName: "Key", stringValue: keyByTemplate[template] ?? "Right") as! XMLNode)
            action.addAttribute(XMLNode.attribute(withName: "Model", stringValue: "_$Model") as! XMLNode)
            actions.addChild(action)
        } else if let movement = MovementTriggerPolicy.enterAction(for: template) {
            addControlAction(model: target.name, enabled: movement.controlEnabled, to: actions)
            addPressAction(key: movement.pressedKey, model: target.name, to: actions)
        } else if (template == "Trick" || template == "Animation") && !value.isEmpty {
            if template == "Trick" {
                // Vector 2 trick animations expect an airborne model. Give the
                // bot the same short jump setup it gets naturally at obstacles.
                let jump = XMLElement(name: "Press")
                jump.addAttribute(XMLNode.attribute(withName: "Key", stringValue: "Up") as! XMLNode)
                jump.addAttribute(XMLNode.attribute(withName: "Model", stringValue: target.name) as! XMLNode)
                actions.addChild(jump)
                let wait = XMLElement(name: "Wait")
                wait.addAttribute(XMLNode.attribute(withName: "Frames", stringValue: "3") as! XMLNode)
                actions.addChild(wait)
            }
            let action = XMLElement(name: "ForceAnimation")
            action.addAttribute(XMLNode.attribute(withName: "Name", stringValue: value) as! XMLNode)
            action.addAttribute(XMLNode.attribute(withName: "Frame", stringValue: "-1") as! XMLNode)
            action.addAttribute(XMLNode.attribute(withName: "Reversed", stringValue: "0") as! XMLNode)
            action.addAttribute(XMLNode.attribute(withName: "Model", stringValue: target.name) as! XMLNode)
            actions.addChild(action)
        } else if let move = Self.aiMoveTemplate(for: template) {
            let action = XMLElement(name: "ForceAnimation")
            action.addAttribute(XMLNode.attribute(withName: "Name", stringValue: move.name) as! XMLNode)
            action.addAttribute(XMLNode.attribute(withName: "Frame", stringValue: "\(move.firstFrame)") as! XMLNode)
            action.addAttribute(XMLNode.attribute(withName: "Reversed", stringValue: "0") as! XMLNode)
            action.addAttribute(XMLNode.attribute(withName: "Model", stringValue: target.name) as! XMLNode)
            actions.addChild(action)
        } else if template == "Activate Spawn", !value.isEmpty {
            let action = XMLElement(name: "Activate")
            action.addAttribute(XMLNode.attribute(withName: "ActionID", stringValue: generatedAISpawnActionID(nodeID: value)) as! XMLNode)
            actions.addChild(action)
        } else if template == "Ragdoll" {
            let action = XMLElement(name: "Kill")
            action.addAttribute(XMLNode.attribute(withName: "Model", stringValue: target.name) as! XMLNode)
            actions.addChild(action)
        } else if template == "Exit" {
            let action = XMLElement(name: "ExitAI")
            action.addAttribute(XMLNode.attribute(withName: "Model", stringValue: target.name) as! XMLNode)
            actions.addChild(action)
        } else if template == "Spawn" || template == "Respawn" {
            let action = XMLElement(name: "Spawn")
            let spawnName = ["Spawn", "Respawn"].contains(template) && value.isEmpty
                ? generatedAISpawnName(node: node, target: target)
                : (value.isEmpty ? target.birthSpawn : value)
            action.addAttribute(XMLNode.attribute(withName: "Spawn", stringValue: spawnName) as! XMLNode)
            action.addAttribute(XMLNode.attribute(withName: "Model", stringValue: target.name) as! XMLNode)
            if template == "Respawn" {
                action.addAttribute(XMLNode.attribute(withName: "AllowDeadAI", stringValue: "1") as! XMLNode)
            } else {
                action.addAttribute(XMLNode.attribute(withName: "OnlyIfDisabledAI", stringValue: "1") as! XMLNode)
            }
            actions.addChild(action)
            if template == "Spawn" {
                let run = XMLElement(name: "Press")
                run.addAttribute(XMLNode.attribute(withName: "Key", stringValue: "Right") as! XMLNode)
                run.addAttribute(XMLNode.attribute(withName: "Model", stringValue: target.name) as! XMLNode)
                actions.addChild(run)
            }
        }
        loop.addChild(actions)
        content.addChild(loop)
        if template == "StopMoveRun" {
            let exitLoop = XMLElement(name: "Loop")
            let exitEvents = XMLElement(name: "Events")
            exitEvents.addChild(XMLElement(name: "Exit"))
            exitLoop.addChild(exitEvents)
            let exitActions = XMLElement(name: "Actions")
            let control = XMLElement(name: "Control")
            control.addAttribute(XMLNode.attribute(withName: "Model", stringValue: target.name) as! XMLNode)
            control.addAttribute(XMLNode.attribute(withName: "Switch", stringValue: "On") as! XMLNode)
            exitActions.addChild(control)
            exitLoop.addChild(exitActions)
            content.addChild(exitLoop)
        }
        if template == "Spawn" || template == "Respawn" {
            let activationLoop = XMLElement(name: "Loop")
            let activationEvents = XMLElement(name: "Events")
            activationEvents.addChild(XMLElement(name: "Activate"))
            activationLoop.addChild(activationEvents)
            let conditions = XMLElement(name: "Conditions")
            let equal = XMLElement(name: "Equal")
            equal.addAttribute(XMLNode.attribute(withName: "Value1", stringValue: "_$ActionID") as! XMLNode)
            equal.addAttribute(XMLNode.attribute(withName: "Value2", stringValue: generatedAISpawnActionID(nodeID: node.id.uuidString)) as! XMLNode)
            conditions.addChild(equal)
            activationLoop.addChild(conditions)
            activationLoop.addChild(actions.copy() as! XMLElement)
            content.addChild(activationLoop)
        }
        trigger.addChild(content)
        return trigger
    }

    private func generatedAISpawnName(node: LevelNode, target: AICharacterDefinition) -> String {
        "EditorAISpawn_\(node.id.uuidString)_\(target.id.uuidString)"
    }

    private func generatedAISpawnActionID(nodeID: String) -> String {
        "EditorAISpawnTrigger_\(nodeID)"
    }

    private static let aiMoveFrames = [
        "DivingKong": 16, "DivingKongFly": 16, "SpeedVault": 11,
        "MonkeyVault": 13, "DashVault": 9, "PopVaultStart": 7,
        "HurdleJump": 5, "RunFast": 0
    ]

    private static func aiMoveTemplate(for template: String) -> (name: String, firstFrame: Int)? {
        let prefixes = ["Trick: ", "Vault: ", "Jump: "]
        let prefix = prefixes.first { template.hasPrefix($0) }
        let name = prefix.map { String(template.dropFirst($0.count)) } ?? template
        guard let firstFrame = aiMoveFrames[name] else { return nil }
        return (name, firstFrame)
    }

    /// Exports area rectangles such as RunFast.
    ///
    /// This must stay separate from Comment. Area is real game XML; Comment is a
    /// red editor note that intentionally returns nil in `exportElement`.
    private func exportArea(_ node: LevelNode, parentTransform: LevelNode.Transform?) -> XMLElement? {
        guard let transform = localizedTransform(for: node, parentTransform: parentTransform) else { return nil }
        let element = XMLElement(name: "Area")
        addImportedAttributes(from: node, to: element, excluding: ["Name", "X", "Y", "Width", "Height", "Type"])
        addIfNotEmpty("Name", value: AnimationAreaPolicy.exportName(for: node.name), to: element)
        addTransformAttributes(to: element, transform: transform, includeSize: true)
        element.addAttribute(XMLNode.attribute(withName: "Type", stringValue: "Animation") as! XMLNode)
        addDynamicProperties(to: element, node: node)
        return element
    }

    private func exportGate(_ node: LevelNode, name: String, parentTransform: LevelNode.Transform?) -> XMLElement? {
        guard let transform = localizedTransform(for: node, parentTransform: parentTransform) else { return nil }
        var exportNode = node
        // Legacy spawn/browser templates tagged ordinary gates Player/Default
        // without defining that choice. Vector filters those gates out and then
        // crashes at room.Ins[0]. Genuine Room Layout rules remain untouched.
        if exportNode.xml.choice.caseInsensitiveCompare("Player") == .orderedSame,
           exportNode.xml.variant.caseInsensitiveCompare("Default") == .orderedSame {
            exportNode.xml.choice = ""
            exportNode.xml.variant = ""
            exportNode.xml.parentChoice = ""
        }
        let element = XMLElement(name: name)
        addImportedAttributes(from: exportNode, to: element, excluding: ["Name", "X", "Y"])
        addIfNotEmpty("Name", value: exportNode.name, to: element)
        addTransformAttributes(to: element, transform: transform, includeSize: false)
        addStaticSelection(to: element, from: exportNode)
        addDynamicProperties(to: element, node: exportNode)
        return element
    }

    private func exportWaypoint(_ node: LevelNode, parentTransform: LevelNode.Transform?) -> XMLElement? {
        guard let transform = localizedTransform(for: node, parentTransform: parentTransform) else { return nil }
        if node.metadata.sourceAttributes["EditorElement"] == "Spawn" {
            let element = XMLElement(name: "Spawn")
            addIfNotEmpty("Name", value: node.name.isEmpty ? "DefaultSpawn" : node.name, to: element)
            addTransformAttributes(to: element, transform: transform, includeSize: false)
            addIfNotEmpty("Animation", value: node.metadata.sourceAttributes["Animation"] ?? "", to: element)
            addStaticSelection(to: element, from: node)
            return element
        }
        let element = XMLElement(name: "Waypoint")
        addImportedAttributes(from: node, to: element, excluding: ["Name", "X", "Y", "SpawnX", "SpawnY", "SpawnDelay", "Type"])
        addIfNotEmpty("Name", value: node.name.isEmpty ? "Start" : node.name, to: element)
        addTransformAttributes(to: element, transform: transform, includeSize: false)
        element.addAttribute(XMLNode.attribute(withName: "SpawnX", stringValue: node.metadata.sourceAttributes["SpawnX"] ?? "0") as! XMLNode)
        element.addAttribute(XMLNode.attribute(withName: "SpawnY", stringValue: node.metadata.sourceAttributes["SpawnY"] ?? "0") as! XMLNode)
        element.addAttribute(XMLNode.attribute(withName: "SpawnDelay", stringValue: node.metadata.sourceAttributes["SpawnDelay"] ?? "0") as! XMLNode)
        let waypointType = node.metadata.sourceAttributes["Type"] ?? (node.name == "Start" ? "Start" : "")
        if !waypointType.isEmpty {
            element.addAttribute(XMLNode.attribute(withName: "Type", stringValue: waypointType) as! XMLNode)
        }
        let properties: XMLElement
        if let sourceProperties = sourcePropertiesElement(for: node) {
            properties = sourceProperties
        } else {
            properties = XMLElement(name: "Properties")
            let staticNode = XMLElement(name: "Static")
            staticNode.addChild(XMLElement(name: "Next"))
            properties.addChild(staticNode)
        }
        addDynamicProperties(toProperties: properties, node: node)
        element.addChild(properties)
        return element
    }

    /// Exports library/prefab object references.
    ///
    /// Expanded children/previews are editor visualization only. The runtime
    /// still wants a compact `<ObjectReference>` pointing at the original
    /// library file/class with the proper transform.
    private func exportObjectReference(_ node: LevelNode, parentTransform: LevelNode.Transform?) -> XMLElement? {
        guard let transform = localizedTransform(for: node, parentTransform: parentTransform) else { return nil }
        let element = XMLElement(name: "ObjectReference")
        let exportsAsStunt = node.metadata.filename == "phantoms.xml"
        let referenceName = node.metadata.libraryObjectName.isEmpty ? node.name : node.metadata.libraryObjectName
        let isStuntReference = exportsAsStunt || (referenceName == "Stunt" && node.metadata.filename == "triggers.xml")
        addIfNotEmpty("Name", value: exportsAsStunt ? "Stunt" : referenceName, to: element)
        addImportedAttributes(from: node, to: element, excluding: ["Name", "X", "Y", "Rotation", "Filename", "Factor"])
        addTransformAttributes(to: element, transform: transform, includeSize: false)
        addIfNotEmpty("Filename", value: exportsAsStunt ? "triggers.xml" : node.metadata.filename, to: element)
        addIfNotEmpty("Factor", value: node.factor, to: element)
        if exportsAsStunt {
            let properties = XMLElement(name: "Properties")
            let staticNode = XMLElement(name: "Static")
            let overrideVariable = XMLElement(name: "OverrideVariable")
            let variable = XMLElement(name: "Variable")
            variable.addAttribute(XMLNode.attribute(withName: "Name", stringValue: "StuntName") as! XMLNode)
            variable.addAttribute(XMLNode.attribute(withName: "Type", stringValue: "E_AreaTrick") as! XMLNode)
            variable.addAttribute(XMLNode.attribute(withName: "Value", stringValue: node.name) as! XMLNode)
            overrideVariable.addChild(variable)
            staticNode.addChild(overrideVariable)
            properties.addChild(staticNode)
            element.addChild(properties)
        } else if isStuntReference {
            let properties = StuntReferenceExportPolicy.propertiesForExport(
                sourcePropertiesElement(for: node) ?? XMLElement(name: "Properties"),
                referenceName: referenceName,
                filename: node.metadata.filename
            )
            if !node.metadata.libraryOverrides.isEmpty {
                let staticNode = properties.elements(forName: "Static").first ?? XMLElement(name: "Static")
                if staticNode.parent == nil { properties.addChild(staticNode) }
                removeChildren(named: ["OverrideVariable"], from: staticNode)
                addLibraryOverrides(node.metadata.libraryOverrides, to: staticNode)
            }
            if properties.childCount > 0 { element.addChild(properties) }
        } else if !hasEditorFlip(node), let sourceProperties = sourcePropertiesElement(for: node) {
            // Imported ObjectReferences keep their untouched Properties block for
            // lossless round-tripping. Trap controls edit the parsed override map,
            // though, so replace the old override section with that live map before
            // exporting or reopened-room edits would appear to save but do nothing.
            if !node.metadata.libraryOverrides.isEmpty {
                let staticNode = sourceProperties.elements(forName: "Static").first ?? XMLElement(name: "Static")
                if staticNode.parent == nil { sourceProperties.addChild(staticNode) }
                removeChildren(named: ["OverrideVariable"], from: staticNode)
                addLibraryOverrides(node.metadata.libraryOverrides, to: staticNode)
            }
            element.addChild(sourceProperties)
        } else if let matrix = objectReferenceMatrixElement(for: node, transform: transform) ?? importedObjectReferenceMatrixElement(for: node, transform: transform) {
            let properties = XMLElement(name: "Properties")
            let staticNode = XMLElement(name: "Static")
            staticNode.addChild(matrix)
            addLibraryOverrides(node.metadata.libraryOverrides, to: staticNode)
            properties.addChild(staticNode)
            element.addChild(properties)
        } else if !node.metadata.libraryOverrides.isEmpty {
            let properties = XMLElement(name: "Properties")
            let staticNode = XMLElement(name: "Static")
            addLibraryOverrides(node.metadata.libraryOverrides, to: staticNode)
            properties.addChild(staticNode)
            element.addChild(properties)
        }
        applyObjectReferenceSelection(node, to: element)
        addDynamicProperties(to: element, node: node)
        return element
    }

    /// Library objects export as compact ObjectReferences instead of their
    /// editor-only preview children. Keep the room-layout guard on that runtime
    /// reference or the object appears in every Start/Middle/Finish/Dynamic option.
    private func applyObjectReferenceSelection(_ node: LevelNode, to element: XMLElement) {
        let choice = node.xml.choice.trimmingCharacters(in: .whitespacesAndNewlines)
        let variant = node.xml.variant.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasRoomLayoutRule = (RoomLayoutSection.matching(choice: choice) != nil && !variant.isEmpty)
            || node.xml.additionalSelections.contains { RoomLayoutSection.matching(choice: $0.choice) != nil }
        guard hasRoomLayoutRule else { return }

        let properties = element.elements(forName: "Properties").first ?? XMLElement(name: "Properties")
        if properties.parent == nil { element.addChild(properties) }
        let staticNode = properties.elements(forName: "Static").first ?? XMLElement(name: "Static")
        if staticNode.parent == nil { properties.addChild(staticNode) }
        removeChildren(named: ["Selection"], from: staticNode)
        appendSelectionElements(from: node, to: staticNode)
    }

    private func addLibraryOverrides(_ overrides: [String: String], to staticNode: XMLElement) {
        guard !overrides.isEmpty else { return }
        let overrideVariable = XMLElement(name: "OverrideVariable")
        for (name, value) in overrides.sorted(by: { $0.key < $1.key }) {
            let variable = XMLElement(name: "Variable")
            variable.addAttribute(XMLNode.attribute(withName: "Name", stringValue: name) as! XMLNode)
            variable.addAttribute(XMLNode.attribute(withName: "Value", stringValue: value) as! XMLNode)
            overrideVariable.addChild(variable)
        }
        staticNode.addChild(overrideVariable)
    }

    private func addImportedAttributes(from node: LevelNode, to element: XMLElement, excluding: Set<String>) {
        for (name, value) in node.metadata.sourceAttributes.sorted(by: { $0.key < $1.key }) where !excluding.contains(name) {
            element.addAttribute(XMLNode.attribute(withName: name, stringValue: value) as! XMLNode)
        }
    }

    private func exportObject(_ node: LevelNode, parentTransform: LevelNode.Transform?) -> XMLElement? {
        guard let transform = localizedTransform(for: node, parentTransform: parentTransform) else { return nil }
        let element = XMLElement(name: "Object")
        addIfNotEmpty("Name", value: node.name, to: element)
        addImportedAttributes(from: node, to: element, excluding: ["Name", "X", "Y", "Rotation", "Factor"])
        addIfNotEmpty("Factor", value: node.factor, to: element)
        var matrixNode = node
        if node.metadata.isTransformEdited, let basis = Self.roomWeaverAffineBasis(for: node) {
            matrixNode.metadata.matrixA = "\(basis.a)"
            matrixNode.metadata.matrixB = "\(basis.b)"
            matrixNode.metadata.matrixC = "\(basis.c)"
            matrixNode.metadata.matrixD = "\(basis.d)"
            // Tx/Ty are already included in the editable container origin.
            matrixNode.metadata.matrixTx = "0"
            matrixNode.metadata.matrixTy = "0"
        }
        let importedMatrix = !node.metadata.isTransformEdited || Self.roomWeaverAffineBasis(for: node) != nil
            ? importedMatrixElement(for: matrixNode) : nil
        if importedMatrix != nil {
            addIfNotEmpty("X", value: node.metadata.isTransformEdited || node.metadata.sourceX.isEmpty ? "\(transform.x)" : node.metadata.sourceX, to: element)
            addIfNotEmpty("Y", value: node.metadata.isTransformEdited || node.metadata.sourceY.isEmpty ? "\(transform.y)" : node.metadata.sourceY, to: element)
        } else {
            addTransformAttributes(to: element, transform: transform, includeSize: false)
        }

        let content = XMLElement(name: "Content")
        let childParentTransform = node.keepsChildrenInLocalRoomWeaverSpace ? nil : exportBaseTransform(for: node)
        for child in node.children {
            if let childElement = exportElement(for: child, parentTransform: childParentTransform) {
                content.addChild(childElement)
            }
        }
        if content.childCount > 0 {
            element.addChild(content)
        }

        let hasSelection = !node.xml.choice.isEmpty || !node.xml.variant.isEmpty || !node.xml.additionalSelections.isEmpty
        let sourceProperties = sourcePropertiesElement(for: node)
        if importedMatrix != nil || hasSelection || sourceProperties != nil {
            let properties = sourceProperties ?? XMLElement(name: "Properties")
            let staticNode = properties.elements(forName: "Static").first ?? XMLElement(name: "Static")
            if staticNode.parent == nil { properties.addChild(staticNode) }
            removeChildren(named: ["Matrix", "Selection"], from: staticNode)
            if let importedMatrix {
                staticNode.addChild(importedMatrix)
            }
            if hasSelection {
                appendSelectionElements(from: node, to: staticNode)
            }
            addDynamicProperties(toProperties: properties, node: node)
            element.addChild(properties)
        } else {
            addDynamicProperties(to: element, node: node)
        }

        return element
    }

    /// Converts child transforms into parent-local coordinates for export.
    ///
    /// Visualizer children can be stored globally in the editor, but nested XML
    /// expects local values. This keeps parented objects from drifting in output.
    private func localizedTransform(for node: LevelNode, parentTransform: LevelNode.Transform?) -> LevelNode.Transform? {
        guard var transform = exportBaseTransform(for: node) else { return nil }
        guard let parentTransform else { return transform }
        if isImportedLocalTransform(node) {
            return transform
        }

        transform.x -= parentTransform.x
        transform.y -= parentTransform.y
        return transform
    }

    private func isImportedLocalTransform(_ node: LevelNode) -> Bool {
        !node.metadata.sourceX.isEmpty
            || !node.metadata.sourceY.isEmpty
            || !node.metadata.sourceWidth.isEmpty
            || !node.metadata.sourceHeight.isEmpty
    }

    private func exportBaseTransform(for node: LevelNode) -> LevelNode.Transform? {
        // Dynamic Studio commits frame zero onto the node when Save is pressed.
        // Export that visible pose directly; reading a second baseline from the
        // timeline made stale JSON shift animated objects only in-game.
        node.transform
    }

    private func addTransformAttributes(to element: XMLElement, transform: LevelNode.Transform, includeSize: Bool) {
        element.addAttribute(XMLNode.attribute(withName: "X", stringValue: "\(transform.x)") as! XMLNode)
        element.addAttribute(XMLNode.attribute(withName: "Y", stringValue: "\(transform.y)") as! XMLNode)
        if includeSize {
            element.addAttribute(XMLNode.attribute(withName: "Width", stringValue: "\(transform.width)") as! XMLNode)
            element.addAttribute(XMLNode.attribute(withName: "Height", stringValue: "\(transform.height)") as! XMLNode)
        }
        if abs(transform.rotation) > 0.001 {
            element.addAttribute(XMLNode.attribute(withName: "Rotation", stringValue: "\(Int(transform.rotation.rounded()))") as! XMLNode)
        }
    }

    private func nativeImageSize(for node: LevelNode, fallback transform: LevelNode.Transform) -> (width: Int, height: Int) {
        if node.metadata.className == "black.v_black" {
            return (50, 50)
        }

        if node.metadata.visualNativeWidth > 0, node.metadata.visualNativeHeight > 0 {
            return (node.metadata.visualNativeWidth, node.metadata.visualNativeHeight)
        }

        if let image = CachedImageStore.shared.image(at: node.metadata.imagePath), image.size.width > 0, image.size.height > 0 {
            let width = max(1, Int(image.size.width.rounded()))
            let height = max(1, Int(image.size.height.rounded()))
            if width <= 16 && height <= 16 {
                return (50, 50)
            }
            return (width, height)
        }

        return (transform.width, transform.height)
    }

    private func addIfNotEmpty(_ name: String, value: String, to element: XMLElement) {
        guard !value.isEmpty else { return }
        element.addAttribute(XMLNode.attribute(withName: name, stringValue: value) as! XMLNode)
    }

    /// Selection is legal on ordinary gameplay elements too, including stock
    /// Platforms and gates. Dropping it here made alternate artwork switch while
    /// collision from every route remained active.
    private func addStaticSelection(to element: XMLElement, from node: LevelNode) {
        var runtimeNode = node
        let originalChoice = runtimeNode.xml.choice.trimmingCharacters(in: .whitespacesAndNewlines)
        let originalVariant = runtimeNode.xml.variant.trimmingCharacters(in: .whitespacesAndNewlines)
        if isEditorPaletteSelection(choice: originalChoice, variant: originalVariant, parent: runtimeNode.xml.parentChoice) {
            runtimeNode.xml.choice = ""
            runtimeNode.xml.variant = ""
            runtimeNode.xml.parentChoice = ""
        }
        runtimeNode.xml.additionalSelections.removeAll {
            isEditorPaletteSelection(choice: $0.choice, variant: $0.variant, parent: $0.parentChoice)
        }

        let choice = runtimeNode.xml.choice.trimmingCharacters(in: .whitespacesAndNewlines)
        let variant = runtimeNode.xml.variant.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceProperties = sourcePropertiesElement(for: runtimeNode)
        guard !choice.isEmpty || !variant.isEmpty || !runtimeNode.xml.additionalSelections.isEmpty || sourceProperties != nil else { return }

        let properties = element.elements(forName: "Properties").first
            ?? sourceProperties
            ?? XMLElement(name: "Properties")
        if properties.parent == nil { element.addChild(properties) }
        let staticNode = properties.elements(forName: "Static").first ?? XMLElement(name: "Static")
        if staticNode.parent == nil { properties.insertChild(staticNode, at: 0) }
        removeChildren(named: ["Selection"], from: staticNode)
        guard !choice.isEmpty || !variant.isEmpty || !runtimeNode.xml.additionalSelections.isEmpty else { return }
        appendSelectionElements(from: runtimeNode, to: staticNode)
    }

    /// Tool-palette categories describe how an item was created; they are not
    /// Vector generator choices. Older builds stored both in XMLSummary, which
    /// silently disabled primitives whenever no Room Layout catalogue existed.
    private func isEditorPaletteSelection(choice: String, variant: String, parent: String) -> Bool {
        guard parent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              RoomLayoutSection.matching(choice: choice) == nil else { return false }
        let key = choice.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let value = variant.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        switch key {
        case "player": return value == "default"
        case "collision": return ["default", "slope", "slopetype2"].contains(value)
        case "images", "backgrounds", "objects", "dynamic", "swarm": return value == "default"
        case "triggers": return value == "default" || value == "start"
        case "areas": return value == "default" || value == "animation"
        default: return false
        }
    }

    private func appendSelectionElements(from node: LevelNode, to staticNode: XMLElement) {
        var rules: [LevelNode.XMLSummary.SelectionRule] = []
        let choice = node.xml.choice.trimmingCharacters(in: .whitespacesAndNewlines)
        let variant = node.xml.variant.trimmingCharacters(in: .whitespacesAndNewlines)
        if !choice.isEmpty, !variant.isEmpty {
            rules.append(.init(choice: choice, variant: variant, parentChoice: node.xml.parentChoice))
        }
        for rule in node.xml.additionalSelections where !rules.contains(rule) {
            rules.append(rule)
        }
        for rule in rules {
            let selection = XMLElement(name: "Selection")
            addIfNotEmpty("Choice", value: rule.choice, to: selection)
            addIfNotEmpty("Variant", value: rule.variant, to: selection)
            addIfNotEmpty("Parent", value: rule.parentChoice, to: selection)
            staticNode.addChild(selection)
        }
    }

    private func addDynamicProperties(to element: XMLElement, node: LevelNode) {
        let dynamics = dynamicElements(for: node)
        guard !dynamics.isEmpty else { return }
        if let properties = element.elements(forName: "Properties").first {
            dynamics.forEach(properties.addChild)
        } else {
            let properties = XMLElement(name: "Properties")
            dynamics.forEach(properties.addChild)
            element.addChild(properties)
        }
    }

    private func addDynamicProperties(toProperties properties: XMLElement, node: LevelNode) {
        dynamicElements(for: node).forEach(properties.addChild)
    }

    private func dynamicElements(for node: LevelNode) -> [XMLElement] {
        let rawXML = node.metadata.dynamicXML.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawXML.isEmpty else { return [] }
        let wrappedXML = rawXML.hasPrefix("<Dynamic") ? "<Root>\(rawXML)</Root>" : "<Root><Dynamic>\(rawXML)</Dynamic></Root>"
        guard let document = try? XMLDocument(xmlString: wrappedXML, options: []) else { return [] }
        return document.rootElement()?.elements(forName: "Dynamic").compactMap { $0.copy() as? XMLElement } ?? []
    }

    private func dynamicTriggerLoopElement(for node: LevelNode) -> XMLElement? {
        let rawXML = node.metadata.dynamicTriggerXML.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawXML.isEmpty else { return nil }
        let wrappedXML = "<Root>\(rawXML)</Root>"
        guard let document = try? XMLDocument(xmlString: wrappedXML, options: []),
              let loop = document.rootElement()?.children?.compactMap({ $0.copy() as? XMLElement }).first else {
            return nil
        }
        return loop
    }

    private func sourceContentElement(for node: LevelNode) -> XMLElement? {
        let rawXML = node.metadata.sourceContentXML.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawXML.isEmpty,
              let document = try? XMLDocument(xmlString: rawXML, options: []),
              let content = document.rootElement()?.copy() as? XMLElement,
              content.name == "Content" else {
            return nil
        }
        return content
    }

    private func sourcePropertiesElement(for node: LevelNode) -> XMLElement? {
        let rawXML = node.metadata.sourcePropertiesXML.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawXML.isEmpty,
              let document = try? XMLDocument(xmlString: rawXML, options: []),
              let properties = document.rootElement()?.copy() as? XMLElement,
              properties.name == "Properties" else {
            return nil
        }
        if !node.metadata.dynamicXML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            for dynamic in properties.elements(forName: "Dynamic") {
                dynamic.detach()
            }
        }
        return properties
    }

    private func removeChildren(named names: Set<String>, from parent: XMLElement) {
        for child in (parent.children ?? []).compactMap({ $0 as? XMLElement }) where names.contains(child.name ?? "") {
            child.detach()
        }
    }

    private func matrixElement(for node: LevelNode, transform: LevelNode.Transform) -> XMLElement {
        rectRotationMatrixElement(
            width: transform.width,
            height: transform.height,
            rotation: transform.rotation,
            scaled: true,
            flipHorizontal: node.metadata.isMirrored,
            flipVertical: node.metadata.isFlippedVertically
        )
    }

    private func hasEditorFlip(_ node: LevelNode) -> Bool {
        node.metadata.isMirrored || node.metadata.isFlippedVertically
    }

    private func importedImageMatrixElement(for node: LevelNode) -> XMLElement? {
        importedMatrixElement(for: node)
    }

    private func importedMatrixElement(for node: LevelNode) -> XMLElement? {
        let values = [
            node.metadata.matrixA,
            node.metadata.matrixB,
            node.metadata.matrixC,
            node.metadata.matrixD,
            node.metadata.matrixTx,
            node.metadata.matrixTy
        ]
        guard values.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            return nil
        }

        let matrix = XMLElement(name: "Matrix")
        matrix.addAttribute(XMLNode.attribute(withName: "A", stringValue: node.metadata.matrixA) as! XMLNode)
        matrix.addAttribute(XMLNode.attribute(withName: "B", stringValue: node.metadata.matrixB) as! XMLNode)
        matrix.addAttribute(XMLNode.attribute(withName: "C", stringValue: node.metadata.matrixC) as! XMLNode)
        matrix.addAttribute(XMLNode.attribute(withName: "D", stringValue: node.metadata.matrixD) as! XMLNode)
        matrix.addAttribute(XMLNode.attribute(withName: "Tx", stringValue: node.metadata.matrixTx) as! XMLNode)
        matrix.addAttribute(XMLNode.attribute(withName: "Ty", stringValue: node.metadata.matrixTy) as! XMLNode)
        return matrix
    }

    private func importedObjectReferenceMatrixElement(for node: LevelNode, transform: LevelNode.Transform) -> XMLElement? {
        guard let matrix = importedMatrixElement(for: node) else { return nil }
        let nativeWidth = max(1, node.metadata.visualNativeWidth)
        let nativeHeight = max(1, node.metadata.visualNativeHeight)
        let scaleChanged = abs(Double(transform.width) / Double(nativeWidth) - 1) > 0.001
            || abs(Double(transform.height) / Double(nativeHeight) - 1) > 0.001
        let rotationChanged = abs(transform.rotation) > 0.001
        return (scaleChanged || rotationChanged) ? nil : matrix
    }

    private func rectRotationMatrixElement(
        width: Int,
        height: Int,
        rotation: Double,
        scaled: Bool,
        flipHorizontal: Bool = false,
        flipVertical: Bool = false
    ) -> XMLElement {
        // SwiftUI's screen space is Y-down; Vector/Unity matrix rotation is Y-up.
        // Export the inverse angle and compensate Tx/Ty so editor-center rotation
        // lands in Vector's origin-based matrix space.
        let radians = -rotation * .pi / 180
        let cosine = cos(radians)
        let sine = sin(radians)
        let widthValue = width.double
        let heightValue = height.double
        let xScale = (scaled ? widthValue : 1) * (flipHorizontal ? -1 : 1)
        let yScale = (scaled ? heightValue : 1) * (flipVertical ? -1 : 1)
        let a = xScale * cosine
        let b = -xScale * sine
        let c = yScale * sine
        let d = yScale * cosine
        let tx: Double
        let ty: Double
        if scaled {
            tx = widthValue / 2 - (a * 0.5 + c * 0.5)
            ty = heightValue / 2 - (b * 0.5 + d * 0.5)
        } else {
            tx = widthValue / 2 - (a * widthValue / 2 + c * heightValue / 2)
            ty = heightValue / 2 - (b * widthValue / 2 + d * heightValue / 2)
        }

        let matrix = XMLElement(name: "Matrix")
        matrix.addAttribute(XMLNode.attribute(withName: "A", stringValue: pretty(a)) as! XMLNode)
        matrix.addAttribute(XMLNode.attribute(withName: "B", stringValue: pretty(b)) as! XMLNode)
        matrix.addAttribute(XMLNode.attribute(withName: "C", stringValue: pretty(c)) as! XMLNode)
        matrix.addAttribute(XMLNode.attribute(withName: "D", stringValue: pretty(d)) as! XMLNode)
        matrix.addAttribute(XMLNode.attribute(withName: "Tx", stringValue: pretty(tx)) as! XMLNode)
        matrix.addAttribute(XMLNode.attribute(withName: "Ty", stringValue: pretty(ty)) as! XMLNode)
        return matrix
    }

    private func objectReferenceMatrixElement(for node: LevelNode, transform: LevelNode.Transform) -> XMLElement? {
        let nativeWidth = max(1, node.metadata.visualNativeWidth)
        let nativeHeight = max(1, node.metadata.visualNativeHeight)
        let scaleX = Double(transform.width) / Double(nativeWidth) * (node.metadata.isMirrored ? -1 : 1)
        let scaleY = Double(transform.height) / Double(nativeHeight) * (node.metadata.isFlippedVertically ? -1 : 1)
        let hasScale = abs(scaleX - 1) > 0.001 || abs(scaleY - 1) > 0.001
        let hasRotation = abs(transform.rotation) > 0.001
        guard hasScale || hasRotation else { return nil }

        let radians = -transform.rotation * .pi / 180
        let cosine = cos(radians)
        let sine = sin(radians)
        let pivotX = Double(node.metadata.visualOffsetX)
        let pivotY = Double(node.metadata.visualOffsetY)
        let tx = pivotX - (scaleX * cosine * pivotX + scaleY * sine * pivotY)
        let ty = pivotY - (-scaleX * sine * pivotX + scaleY * cosine * pivotY)
        let matrix = XMLElement(name: "Matrix")
        matrix.addAttribute(XMLNode.attribute(withName: "A", stringValue: pretty(scaleX * cosine)) as! XMLNode)
        matrix.addAttribute(XMLNode.attribute(withName: "B", stringValue: pretty(-scaleX * sine)) as! XMLNode)
        matrix.addAttribute(XMLNode.attribute(withName: "C", stringValue: pretty(scaleY * sine)) as! XMLNode)
        matrix.addAttribute(XMLNode.attribute(withName: "D", stringValue: pretty(scaleY * cosine)) as! XMLNode)
        matrix.addAttribute(XMLNode.attribute(withName: "Tx", stringValue: pretty(tx)) as! XMLNode)
        matrix.addAttribute(XMLNode.attribute(withName: "Ty", stringValue: pretty(ty)) as! XMLNode)
        return matrix
    }

    private func pretty(_ value: Double) -> String {
        let rounded = (value * 1000).rounded() / 1000
        return String(rounded)
    }
}

extension Int {
    var double: Double { Double(self) }
}

extension Color {
    init(rgbaHex: String) {
        let cleaned = rgbaHex.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
        guard cleaned.count == 8, let value = UInt32(cleaned, radix: 16) else {
            self = .clear
            return
        }

        let red = Double((value >> 24) & 0xFF) / 255.0
        let green = Double((value >> 16) & 0xFF) / 255.0
        let blue = Double((value >> 8) & 0xFF) / 255.0
        let alpha = Double(value & 0xFF) / 255.0
        self = Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }
}

#Preview {
    ContentView()
}
