//
//  LevelNodeTreeOperations.swift
//  Vector2 level editor
//
//  LevelNode is the data. This file is how we safely walk and mutate its tree.
//  Selection ownership, RoomWeaver parent space, duplication, reparenting, and
//  descendant transforms all meet here, so please do not "simplify" one path
//  without testing imported complex objects as well as plain editor shapes.
//

import CoreGraphics
import Foundation

extension LevelNode {
    var firstFactorChildren: [LevelNode] {
        if kind == .factor { return children }
        for child in children { let found = child.firstFactorChildren; if !found.isEmpty { return found } }
        return []
    }

    mutating func offsetTree(x: Int, y: Int) {
        if var transform { transform.x += x; transform.y += y; self.transform = transform }
        for index in children.indices { children[index].offsetTree(x: x, y: y) }
    }
}
import SwiftUI

extension LevelNode {
    func hierarchyPath(to targetID: ID) -> [ID]? {
        if id == targetID { return [id] }
        for child in children {
            if let path = child.hierarchyPath(to: targetID) { return [id] + path }
        }
        return nil
    }

    var keepsChildrenInLocalRoomWeaverSpace: Bool {
        metadata.visualType == "RoomWeaverLibraryReference"
            || metadata.visualType == "RoomWeaverContainer"
    }

    /// Aligns a wrapper with its one visible shape child.
    ///
    /// Some imported/library objects are represented as a runtime wrapper plus a
    /// single editor-shape child. This keeps resize/move selection from making
    /// the child visually drift away from the owning wrapper.
    mutating func syncSingleShapeWrapperChildIfNeeded() {
        guard !keepsChildrenInLocalRoomWeaverSpace,
              transform != nil,
              metadata.imagePath.isEmpty,
              previewPieces.isEmpty,
              kind == .object || kind == .objectReference else {
            return
        }

        let visibleShapeIndices = children.indices.filter {
            !children[$0].metadata.isHidden && children[$0].kind.isEditorShape
        }
        guard visibleShapeIndices.count == 1,
              children.indices.allSatisfy({ visibleShapeIndices.contains($0) || children[$0].metadata.isHidden }),
              let wrapperTransform = transform else {
            return
        }

        // Runtime XML still belongs to the wrapper. This child only draws the
        // editor visualizer, so keep it aligned when the wrapper gets resized.
        children[visibleShapeIndices[0]].transform = wrapperTransform
    }

    /// Factory for left-rail primitive tools.
    ///
    /// Asset-browser objects are built elsewhere because they need catalog data.
    /// This function answers the simple question: "If the user clicks the canvas
    /// with this tool selected, what node appears?"
    static func makePlacementNode(for tool: EditorTool, x: Int, y: Int, alternateVariant: Bool = false) -> LevelNode? {
        switch tool {
        case .cursor:
            return nil
        case .images:
            return LevelNode(name: "NewImage", kind: .image, factor: "1", transform: .init(x: x, y: y, width: 240, height: 140), xml: .init(template: "Image", choice: "Images", variant: "Default"), metadata: .init(sortingLayer: "Wall", tag: Kind.image.defaultTag, className: "zone2.panel_brown1"))
        case .backgrounds:
            return LevelNode(name: "Background", kind: .image, factor: "0", transform: .init(x: x, y: y, width: 420, height: 220), xml: .init(template: "Background", choice: "Backgrounds", variant: "Default"), metadata: .init(sortingLayer: "Wall", tag: Kind.image.defaultTag, className: "zone2.panel_brown1"))
        case .trapezoid:
            let style: Vector2EditorVisuals.TrapezoidStyle = alternateVariant ? .right : .left
            return LevelNode(
                name: alternateVariant ? "TrapezoidType2" : "Trapezoid",
                kind: .trapezoid,
                factor: "1",
                transform: .init(x: x, y: y, width: 180, height: 90),
                xml: .init(template: "Trapezoid", choice: "Collision", variant: alternateVariant ? "SlopeType2" : "Slope"),
                metadata: .init(sortingLayer: "Collision", tag: Kind.trapezoid.defaultTag, imagePath: Vector2EditorVisuals.trapezoidTexturePath(style: style) ?? "")
            )
        case .collision:
            return LevelNode(name: "Platform", kind: .platform, factor: "1", transform: .init(x: x, y: y, width: 220, height: 100), xml: .init(template: "Platform", choice: "Collision", variant: "Default"), metadata: .init(sortingLayer: "Collision", tag: Kind.platform.defaultTag))
        case .trigger:
            return LevelNode(name: "Trigger", kind: .trigger, factor: "1", transform: .init(x: x, y: y, width: 100, height: 240), xml: .init(template: "Trigger", choice: "Triggers", variant: "Default"), metadata: .init(tag: Kind.trigger.defaultTag))
        case .area:
            return LevelNode(
                name: AnimationAreaPolicy.defaultName,
                kind: .area,
                factor: "1",
                transform: .init(x: x, y: y, width: 350, height: 300),
                xml: .init(template: AnimationAreaPolicy.defaultName, choice: "Areas", variant: "Animation"),
                metadata: .init(tag: Kind.area.defaultTag, className: AnimationAreaPolicy.defaultName)
            )
        case .comment:
            return LevelNode(
                name: "Comment",
                kind: .comment,
                factor: "1",
                transform: .init(x: x, y: y, width: 240, height: 140),
                xml: .init(template: "Comment", choice: "-", variant: "EditorOnly"),
                metadata: .init(sortingLayer: "Debug", tag: "Comment")
            )
        case .coin:
            // Vector 2 does not use a literal bonus prefab for this left-rail
            // button. In real rooms this is a stunt-trigger reference with
            // StuntName=Bonus, so keep the editor node simple but mark it as a
            // phantom/stunt export. Otherwise the prefab resolver can grab the
            // wrong black-ball looking object and the exported room is cooked.
            return LevelNode(
                name: "Bonus",
                kind: .coin,
                factor: "1",
                transform: .init(x: x, y: y, width: 72, height: 72),
                xml: .init(template: "ObjectReference", choice: "phantoms.xml", variant: "Bonus"),
                metadata: .init(tag: Kind.coin.defaultTag, filename: "phantoms.xml", className: "Bonus")
            )
        case .camera:
            return LevelNode(name: "CameraStart", kind: .camera, factor: "1", transform: .init(x: x, y: y, width: 100, height: 100), xml: .init(template: "Camera", choice: "Triggers", variant: "Start"), metadata: .init(tag: Kind.camera.defaultTag, filename: "triggers.xml"))
        case .objectRef, .object:
            return LevelNode(name: "ObjectRef", kind: .objectReference, factor: "1", transform: .init(x: x, y: y, width: 100, height: 100), xml: .init(template: "ObjectReference", choice: "Objects", variant: "Default"), metadata: .init(tag: Kind.objectReference.defaultTag, filename: "objects_items.xml"))
        case .dynamic:
            return LevelNode(name: "Dynamic", kind: .dynamic, factor: "1", transform: .init(x: x, y: y, width: 160, height: 120), xml: .init(template: "Dynamic", choice: "Dynamic", variant: "Default"), metadata: .init(tag: Kind.dynamic.defaultTag))
        case .playerIn:
            return Vector2SpawnPrefabVisual.node(for: .gateIn, x: x, y: y)
        case .playerOut:
            return Vector2SpawnPrefabVisual.node(for: .gateOut, x: x, y: y)
        case .runFast:
            return LevelNode(
                name: "RunFast",
                kind: .area,
                factor: "1",
                transform: .init(x: x, y: y, width: 2158, height: 150),
                xml: .init(template: "RunFast", choice: "Areas", variant: "Animation"),
                metadata: .init(tag: Kind.area.defaultTag, className: "RunFast")
            )
        case .swarm:
            return LevelNode(
                name: "SwarmActivator",
                kind: .objectReference,
                factor: "1",
                transform: .init(x: x, y: y, width: 100, height: 360),
                xml: .init(template: "SwarmActivator", choice: "Swarm", variant: "Default"),
                metadata: .init(tag: Kind.objectReference.defaultTag, filename: "triggers.xml", libraryObjectName: "SwarmActivator")
            )
        case .waypoint:
            return LevelNode(name: "Start", kind: .waypoint, factor: "1", transform: .init(x: x, y: y, width: 80, height: 80), xml: .init(template: "Waypoint", choice: "Swarm", variant: "Default"), metadata: .init(tag: "Waypoint"))
        case .mask:
            return nil
        }
    }

    func duplicated(offsetX: Int, offsetY: Int) -> LevelNode {
        var clone = self
        if var transform = clone.transform {
            transform.x += offsetX
            transform.y += offsetY
            clone.transform = transform
        }
        clone = LevelNode(
            name: clone.name,
            kind: clone.kind,
            factor: clone.factor,
            transform: clone.transform,
            xml: clone.xml,
            metadata: clone.metadata,
            previewPieces: clone.previewPieces,
            children: clone.children.map { $0.duplicated(offsetX: 0, offsetY: 0) }
        )
        return clone
    }

    func containsDescendant(id targetID: UUID) -> Bool {
        children.contains { child in
            child.id == targetID || child.containsDescendant(id: targetID)
        }
    }

    func find(id: UUID) -> LevelNode? {
        if self.id == id {
            return self
        }

        for child in children {
            if let match = child.find(id: id) {
                return match
            }
        }

        return nil
    }

    func localRoomWeaverParent(for targetID: UUID) -> LevelNode? {
        localRoomWeaverParent(for: targetID, currentParent: nil)
    }

    /// Returns the nearest local RoomWeaver parent composed into canvas space.
    /// The raw nearest parent may itself be local to another container.
    func localRoomWeaverDisplayParent(for targetID: UUID) -> LevelNode? {
        localRoomWeaverDisplayParent(for: targetID, activeParent: nil)
    }

    private func localRoomWeaverDisplayParent(for targetID: UUID, activeParent: LevelNode?) -> LevelNode? {
        var nextParent = activeParent
        if keepsChildrenInLocalRoomWeaverSpace {
            var displayed = self
            if let local = transform, let parent = activeParent, let parentTransform = parent.transform {
                let parentBasis = LevelDocument.roomWeaverAffineBasis(for: parent) ?? {
                    let radians = parentTransform.rotation * .pi / 180
                    return (cos(radians), sin(radians), -sin(radians), cos(radians))
                }()
                let localBasis: (a: Double, b: Double, c: Double, d: Double)
                if let basis = LevelDocument.roomWeaverAffineBasis(for: self) {
                    localBasis = basis
                } else {
                    let radians = local.rotation * .pi / 180
                    localBasis = (cos(radians), sin(radians), -sin(radians), cos(radians))
                }
                let x = Double(local.x) * parentBasis.a + Double(local.y) * parentBasis.c
                let y = Double(local.x) * parentBasis.b + Double(local.y) * parentBasis.d
                let worldA = parentBasis.a * localBasis.a + parentBasis.c * localBasis.b
                let worldB = parentBasis.b * localBasis.a + parentBasis.d * localBasis.b
                let worldC = parentBasis.a * localBasis.c + parentBasis.c * localBasis.d
                let worldD = parentBasis.b * localBasis.c + parentBasis.d * localBasis.d
                displayed.transform = .init(
                    x: parentTransform.x + Int(x.rounded()),
                    y: parentTransform.y + Int(y.rounded()),
                    width: local.width,
                    height: local.height,
                    rotation: atan2(worldB, worldA) * 180 / .pi
                )
                displayed.metadata.matrixA = String(worldA)
                displayed.metadata.matrixB = String(worldB)
                displayed.metadata.matrixC = String(worldC)
                displayed.metadata.matrixD = String(worldD)
                displayed.metadata.isTransformEdited = false
            }
            nextParent = displayed
        }
        for child in children {
            if child.id == targetID { return nextParent }
            if let found = child.localRoomWeaverDisplayParent(for: targetID, activeParent: nextParent) { return found }
        }
        return nil
    }

    func canvasTransform(for targetID: UUID, localTransform: Transform) -> Transform {
        guard let parent = localRoomWeaverDisplayParent(for: targetID) else { return localTransform }
        return LevelDocument.displayTransform(fromLocalTransform: localTransform, under: parent,
            usesRectOrigin: find(id: targetID)?.kind.usesVectorRectOrigin ?? false)
    }

    private func localRoomWeaverParent(for targetID: UUID, currentParent: LevelNode?) -> LevelNode? {
        let nextParent = keepsChildrenInLocalRoomWeaverSpace ? self : currentParent
        for child in children {
            if child.id == targetID {
                return nextParent
            }
            if let match = child.localRoomWeaverParent(for: targetID, currentParent: nextParent) {
                return match
            }
        }
        return nil
    }

    mutating func update(id: UUID, mutate: (inout LevelNode) -> Void) {
        if self.id == id {
            mutate(&self)
            return
        }

        for index in children.indices {
            children[index].update(id: id, mutate: mutate)
        }
    }

    mutating func replace(id targetID: UUID, with replacement: LevelNode) -> Bool {
        if let index = children.firstIndex(where: { $0.id == targetID }) {
            children[index] = replacement
            return true
        }

        for index in children.indices {
            if children[index].replace(id: targetID, with: replacement) {
                return true
            }
        }

        return false
    }

    mutating func appendToFirstFactor(_ node: LevelNode) -> Bool {
        if kind == .factor {
            children.append(node)
            return true
        }

        for index in children.indices {
            if children[index].appendToFirstFactor(node) {
                return true
            }
        }

        return false
    }

    mutating func append(children newChildren: [LevelNode], to targetID: UUID) -> Bool {
        if id == targetID {
            children.append(contentsOf: newChildren)
            return true
        }

        for index in children.indices {
            if children[index].append(children: newChildren, to: targetID) {
                return true
            }
        }

        return false
    }

    mutating func remove(id targetID: UUID) -> Bool {
        if let index = children.firstIndex(where: { $0.id == targetID }) {
            children.remove(at: index)
            return true
        }

        for index in children.indices {
            if children[index].remove(id: targetID) {
                return true
            }
        }

        return false
    }

    func containsDescendant(_ descendantID: UUID, under ancestorID: UUID) -> Bool {
        guard let ancestor = find(id: ancestorID) else { return false }
        return ancestor.children.contains { child in
            child.id == descendantID || child.containsDescendant(descendantID, under: child.id)
        }
    }

    mutating func extract(ids targetIDs: Set<UUID>, into extracted: inout [LevelNode]) {
        var kept: [LevelNode] = []
        for var child in children {
            if targetIDs.contains(child.id) {
                extracted.append(child)
            } else {
                child.extract(ids: targetIDs, into: &extracted)
                kept.append(child)
            }
        }
        children = kept
    }

    mutating func translateDescendants(byX deltaX: Int, y deltaY: Int) {
        guard deltaX != 0 || deltaY != 0 else { return }
        for index in children.indices {
            if children[index].transform != nil {
                children[index].transform?.x += deltaX
                children[index].transform?.y += deltaY
            }
            children[index].translateDescendants(byX: deltaX, y: deltaY)
        }
    }

    /// Carries world-space children with a parent transform.
    ///
    /// Imported RoomWeaver containers keep true local children and therefore
    /// do not use this path. Editor-parented groups store child transforms in
    /// scene space, so both translation and rotation must be applied manually.
    mutating func transformDescendants(from oldParent: Transform, to newParent: Transform) {
        guard !children.isEmpty else { return }
        let oldAnchor = hierarchyTransformAnchor(for: oldParent)
        let newAnchor = hierarchyTransformAnchor(for: newParent)
        let scaleX = CGFloat(newParent.width) / CGFloat(max(1, oldParent.width))
        let scaleY = CGFloat(newParent.height) / CGFloat(max(1, oldParent.height))
        let rotationDelta = newParent.rotation - oldParent.rotation
        let radians = rotationDelta * .pi / 180
        let cosine = cos(radians)
        let sine = sin(radians)
        let translationX = newAnchor.x - oldAnchor.x
        let translationY = newAnchor.y - oldAnchor.y

        guard abs(translationX) > 0.001 || abs(translationY) > 0.001 || abs(rotationDelta) > 0.001 || abs(scaleX - 1) > 0.001 || abs(scaleY - 1) > 0.001 else { return }

        for index in children.indices {
            guard let oldChild = children[index].transform else {
                children[index].transformDescendants(from: oldParent, to: newParent)
                continue
            }

            let oldChildAnchor = children[index].hierarchyTransformAnchor(for: oldChild)
            let relativeX = (oldChildAnchor.x - oldAnchor.x) * scaleX
            let relativeY = (oldChildAnchor.y - oldAnchor.y) * scaleY
            let rotatedAnchor = CGPoint(
                x: newAnchor.x + relativeX * cosine - relativeY * sine,
                y: newAnchor.y + relativeX * sine + relativeY * cosine
            )

            var newChild = oldChild
            newChild.width = max(1, Int((CGFloat(oldChild.width) * abs(scaleX)).rounded()))
            newChild.height = max(1, Int((CGFloat(oldChild.height) * abs(scaleY)).rounded()))
            let offsetX = CGFloat(children[index].metadata.visualOffsetX)
            let offsetY = CGFloat(children[index].metadata.visualOffsetY)
            let baseCenterX = rotatedAnchor.x - offsetX
            let baseCenterY = rotatedAnchor.y - offsetY
            if children[index].kind.usesVectorRectOrigin {
                newChild.x = Int((baseCenterX - CGFloat(newChild.width) / 2).rounded())
                newChild.y = Int((baseCenterY - CGFloat(newChild.height) / 2).rounded())
            } else {
                newChild.x = Int(baseCenterX.rounded())
                newChild.y = Int(baseCenterY.rounded())
            }
            newChild.rotation = oldChild.rotation + rotationDelta
            children[index].transform = newChild
            children[index].metadata.isTransformEdited = true
            children[index].transformDescendants(from: oldChild, to: newChild)
        }
    }

    private func hierarchyTransformAnchor(for transform: Transform) -> CGPoint {
        let baseX: CGFloat
        let baseY: CGFloat
        if kind.usesVectorRectOrigin {
            baseX = CGFloat(transform.x) + CGFloat(transform.width) / 2
            baseY = CGFloat(transform.y) + CGFloat(transform.height) / 2
        } else {
            baseX = CGFloat(transform.x)
            baseY = CGFloat(transform.y)
        }
        return CGPoint(
            x: baseX + CGFloat(metadata.visualOffsetX),
            y: baseY + CGFloat(metadata.visualOffsetY)
        )
    }

    mutating func markHierarchyAttachment(_ isAttached: Bool) {
        metadata.isHierarchyAttachment = isAttached
        for index in children.indices {
            children[index].markHierarchyAttachment(isAttached)
        }
    }

    func flattenedSceneNodes() -> [LevelNode] {
        if metadata.isHidden {
            return []
        }
        if metadata.visualType == "RoomWeaverContainer" {
            return children.flatMap { $0.flattenedSceneNodes() }
        }
        if transform != nil {
            if rendersAsRuntimeGraph {
                return [self]
            }
            if metadata.visualType == "RoomWeaverLibraryReference" {
                return [self]
            }
            if !children.isEmpty && metadata.imagePath.isEmpty {
                return children.flatMap { $0.flattenedSceneNodes() }
            }
            return [self]
        }
        return children.flatMap { $0.flattenedSceneNodes() }
    }

    func allDescendantsIncludingSelf() -> [LevelNode] {
        [self] + children.flatMap { $0.allDescendantsIncludingSelf() }
    }

    var rendersAsRuntimeGraph: Bool {
        switch kind {
        case .object, .objectReference, .dynamic:
            return !children.isEmpty
        default:
            return false
        }
    }

    var canvasColor: Color {
        switch kind {
        case .trigger: Color(rgbaHex: Vector2RuntimeSettings.triggerFillHex)
        case .area: Color(rgbaHex: Vector2RuntimeSettings.areaFillHex)
        case .comment: Color(rgbaHex: "FF000030")
        case .coin: Color.green
        case .platform, .trapezoid: Color(rgbaHex: Vector2RuntimeSettings.platformFillHex)
        case .objectReference: Color.green
        case .waypoint: Color(rgbaHex: Vector2RuntimeSettings.cameraFillHex)
        case .camera: Color(rgbaHex: Vector2RuntimeSettings.cameraFillHex)
        case .gateIn, .gateOut: Color(rgbaHex: Vector2RuntimeSettings.spawnFillHex)
        default: Color.orange
        }
    }

    var canvasOutlineColor: Color {
        switch kind {
        case .trigger: Color(rgbaHex: Vector2RuntimeSettings.triggerOutlineHex)
        case .area: Color(rgbaHex: Vector2RuntimeSettings.areaOutlineHex)
        case .comment: Color(rgbaHex: "CC0000FF")
        case .platform, .trapezoid: Color(rgbaHex: Vector2RuntimeSettings.platformOutlineHex)
        case .camera: Color(rgbaHex: Vector2RuntimeSettings.cameraOutlineHex)
        case .gateIn, .gateOut: Color(rgbaHex: Vector2RuntimeSettings.spawnOutlineHex)
        case .waypoint: Color(rgbaHex: Vector2RuntimeSettings.cameraOutlineHex)
        default: canvasColor.opacity(0.9)
        }
    }

    var canvasOpacity: Double {
        switch kind {
        case .trigger, .area, .comment, .platform, .trapezoid, .camera, .gateIn, .gateOut: 1
        default: 0.45
        }
    }

    var exportElementName: String {
        switch kind {
        case .platform: return "Platform"
        case .trapezoid: return "Trapezoid"
        case .trigger: return "Trigger"
        case .area: return "Area"
        case .comment: return "Comment"
        case .coin: return "ObjectReference"
        case .camera: return "ObjectReference"
        case .objectReference: return "ObjectReference"
        case .waypoint: return "Waypoint"
        case .dynamic: return "Object"
        case .gateIn: return "In"
        case .gateOut: return "Out"
        case .image: return "Image"
        case .object: return "Object"
        case .track: return "Track"
        case .factor: return "Object"
        case .document: return "Root"
        }
    }
}
