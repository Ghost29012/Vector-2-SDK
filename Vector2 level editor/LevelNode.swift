//
//  LevelNode.swift
//  Vector2 level editor
//
//  The shared room model.
//
//  Importer, exporter, canvas, hierarchy, inspector, and asset browser all talk
//  through these structs. A LevelNode can be real XML, an editor-only helper, or
//  a parent that owns preview pieces for a library/prefab object. If a port gets
//  transforms, parent origins, or metadata wrong here, everything downstream
//  starts drifting.
//

// Keep the model shapes and document-level actions here. Recursive LevelNode
// traversal/reparenting helpers live in LevelNodeTreeOperations.swift because
// that subsystem is complicated enough to deserve its own map.

import SwiftUI
import AppKit
import Foundation

struct EditorSession: Equatable {
    var documents: [LevelDocument]
    var selectedDocumentID: LevelDocument.ID

    var selectedDocumentIndex: Int {
        documents.firstIndex(where: { $0.id == selectedDocumentID }) ?? 0
    }

    var selectedDocument: LevelDocument {
        documents[selectedDocumentIndex]
    }

    static var workspaceOrFallback: EditorSession {
        let documents = [LevelDocument.empty(for: .vector2, index: 1)]
        let selectedID = documents.first?.id ?? UUID()
        return EditorSession(documents: documents, selectedDocumentID: selectedID)
    }

    static let sample = EditorSession(
        documents: [
            LevelDocument.sampleRoom201,
            LevelDocument.sampleTriggers,
            LevelDocument.sampleObjects
        ],
        selectedDocumentID: LevelDocument.sampleRoom201.id
    )

    mutating func createEmptyDocument(for game: GameProfile) {
        let document = LevelDocument.empty(for: game, index: documents.count + 1)
        documents.append(document)
        selectedDocumentID = document.id
    }

    mutating func replaceSelectedDocument(with document: LevelDocument) {
        documents[selectedDocumentIndex] = document
        selectedDocumentID = document.id
    }

    mutating func appendDocument(_ document: LevelDocument) {
        documents.append(document)
        selectedDocumentID = document.id
    }

    mutating func openDynamicStudio() {
        if let existing = documents.first(where: \.isDynamicStudio) {
            selectedDocumentID = existing.id
            return
        }

        let document = LevelDocument.dynamicStudio()
        documents.append(document)
        selectedDocumentID = document.id
    }

    mutating func openAIStudio() {
        if let existing = documents.first(where: \.isAIStudio) {
            selectedDocumentID = existing.id
            return
        }
        let document = LevelDocument.aiStudio()
        documents.append(document)
        selectedDocumentID = document.id
    }

    mutating func openPlayerDesigner() {
        if let existing = documents.first(where: \.isPlayerDesigner) { selectedDocumentID = existing.id; return }
        let document = LevelDocument.playerDesigner()
        documents.append(document)
        selectedDocumentID = document.id
    }

    mutating func openTriggerStudio() {
        if let existing = documents.first(where: \.isTriggerStudio) { selectedDocumentID = existing.id; return }
        let document = LevelDocument.triggerStudio()
        documents.append(document)
        selectedDocumentID = document.id
    }

    mutating func openObstacleStudio() {
        if let existing = documents.first(where: \.isObstacleStudio) { selectedDocumentID = existing.id; return }
        let document = LevelDocument.obstacleStudio()
        documents.append(document)
        selectedDocumentID = document.id
    }

    mutating func openStructuralRoomStudio(_ kind: StructuralRoomKind) {
        if let existing = documents.first(where: { $0.structuralRoomKind == kind && $0.sourcePath == nil }) {
            selectedDocumentID = existing.id
            return
        }
        let document = LevelDocument.structuralRoomStudio(kind)
        documents.append(document)
        selectedDocumentID = document.id
    }

    mutating func openHelpStudio() {
        if let existing = documents.first(where: \.isHelpStudio) { selectedDocumentID = existing.id; return }
        let document = LevelDocument.helpStudio()
        documents.append(document)
        selectedDocumentID = document.id
    }

    mutating func closeDocument(id: LevelDocument.ID) {
        guard let index = documents.firstIndex(where: { $0.id == id }) else { return }
        let closesActiveTab = selectedDocumentID == id
        documents.remove(at: index)
        if EditorTabPolicy.shouldCreateBlankDocument(afterClosingRemainingCount: documents.count) {
            let blank = LevelDocument.empty(for: .vector2, index: 1)
            documents = [blank]
            selectedDocumentID = blank.id
            return
        }
        if closesActiveTab, let replacement = documents.indices.contains(index) ? documents[index] : documents.last {
            selectedDocumentID = replacement.id
        }
    }
}

/// One tab in the editor.
///
/// A document owns a Vector 2 node tree plus selection state. `sourcePath` is
/// optional because new tabs and generated preview tabs do not always have a
/// real file yet.
struct LevelDocument: Identifiable, Equatable {
    let id = UUID()
    var name: String
    var sourcePath: String?
    var root: LevelNode {
        didSet {
            // Canvas/sidebar observers only need to know that the tree changed.
            // Comparing the full RoomWeaver hierarchy on every SwiftUI update
            // walks thousands of nodes and preview pieces even while the user
            // is only panning or zooming. A root mutation updates this cheap
            // token instead; the tree and rendering behavior stay untouched.
            renderRevision &+= 1
        }
    }
    private(set) var renderRevision: UInt64 = 0
    var selectedNodeID: LevelNode.ID?
    var selectedNodeIDs: Set<LevelNode.ID> = []
    var customBackgroundName: String = ""
    // The pool canvas remembers which saved set its artwork came from. A new
    // name must start with New Set instead of silently duplicating old art.
    var zonePoolEditingName: String = ""
    var hasCustomBackgroundAssignment = false
    var aiCharacters: [AICharacterDefinition] = []
    var aiGroups: [AIGroupDefinition] = []
    var playerSkinFiles: [String] = []
    // Room Layouts is editor state wrapped around Vector 2's existing
    // Choice/Variant system. XML determines object
    // membership; these values only remember what the creator is previewing.
    var activeRoomLayoutVariants: [RoomLayoutSection: String] = [:]
    var editingRoomLayout: RoomLayoutKey?
    var ghostInactiveRoomLayouts = true
    // A linked layout becomes a real nested Vector choice on export. We keep
    // the relationship here as well so changing it in the friendly UI is instant.
    var roomLayoutParents: [RoomLayoutKey: RoomLayoutKey] = [:]
    // Structural rooms are complete standalone levels. They are never folded
    // into a normal room or treated as Room Layout Start/Finish sections.
    var structuralRoomKind: StructuralRoomKind?
    var activeStructuralVariant: String?

    var trapValidationIssues: [String] {
        let standalone: Set<String> = [
            "BeamTrapMounted_DT", "BeamTrapMounted_TD", "BeamTrapMounted_RL", "BeamTrapMounted_LR",
            "BeamTrapFloating_DT", "BeamTrapFloating_TD", "BeamTrapFloating_RL", "BeamTrapFloating_LR",
            "TripleBomb", "TripleBomb_Shortjump", "TripleBomb_Hurdlejump",
            "Blackball", "Blackball_Shortjump", "Blackball_Hurdlejump",
            "Mine_Shortjump", "Mine_Hurdlejump", "Laser_Shortjump", "Laser_Hurdlejump",
            "Tesla_Shortjump", "Tesla_Hurdlejump", "Echo_Shortjump", "Echo_Hurdlejump",
            "Flame_Shortjump", "Flame_Hurdlejump", "Swarm_Shortjump", "Swarm_Hurdlejump"
        ]
        let internalFiles: Set<String> = ["traps_cosmetics.xml", "traps_placeholder.xml", "traps_service.xml"]
        let scene = root.flattenedSceneNodes()
        // Validate only the user's placed/imported library references. Expanded
        // previews contain internal child pieces which must not be mistaken for
        // directly placed trap helpers.
        let references = scene.filter { $0.metadata.visualType == "RoomWeaverLibraryReference" }
        var issues: [String] = []
        for node in references {
            // Imported rooms may legitimately contain internal helpers as part
            // of complete trap assemblies. Only block a newly placed helper.
            if sourcePath != nil, !node.metadata.sourceX.isEmpty { continue }
            let filename = node.metadata.filename
            let objectName = node.metadata.libraryObjectName.isEmpty ? node.name : node.metadata.libraryObjectName
            if internalFiles.contains(filename) {
                issues.append("\(objectName) is an internal trap helper and cannot be placed directly")
            } else if filename == "traps.xml", objectName != "SwarmHole", !standalone.contains(objectName) {
                issues.append("\(objectName) is not a standalone trap")
            }
        }
        if references.contains(where: {
            $0.metadata.filename == "traps.xml" && ($0.metadata.libraryObjectName == "SwarmHole" || $0.name == "SwarmHole")
        }) {
            let hasActivator = references.contains {
                $0.metadata.filename == "triggers.xml" && ($0.metadata.libraryObjectName == "SwarmActivator" || $0.name == "SwarmActivator")
            }
            let hasWaypoint = scene.contains { $0.kind == .waypoint }
            if !hasActivator || !hasWaypoint {
                issues.append("SwarmHole requires SwarmActivator and a waypoint path")
            }
        }
        return Array(Set(issues)).sorted()
    }

    var aiValidationIssues: [String] {
        var issues: [String] = []
        let trimmedNames = aiCharacters.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) }
        if trimmedNames.contains(where: \.isEmpty) { issues.append("Every AI needs a name") }
        let foldedNames = trimmedNames.map { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) }
        if Set(foldedNames).count != foldedNames.count { issues.append("AI names must be unique") }
        let channels = aiCharacters.map(\.aiChannel)
        if Set(channels).count != channels.count { issues.append("AI channels must be unique") }
        if aiCharacters.contains(where: { $0.bodySkin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            issues.append("Every AI needs a body model")
        }

        let characterIDs = Set(aiCharacters.map(\.id))
        let groupIDs = Set(aiGroups.map(\.id))
        for node in root.flattenedSceneNodes() where !node.metadata.aiActionTemplate.isEmpty {
            let target = node.metadata.aiTarget
            if target == "all" || target == "player" || target == "project" { continue }
            let pieces = target.split(separator: ":", maxSplits: 1).map(String.init)
            guard pieces.count == 2, let id = UUID(uuidString: pieces[1]) else {
                issues.append("Trigger \(node.name.isEmpty ? "Unnamed" : node.name) has no valid AI target")
                continue
            }
            if pieces[0] == "character" && !characterIDs.contains(id) {
                issues.append("Trigger \(node.name.isEmpty ? "Unnamed" : node.name) targets a deleted AI")
            } else if pieces[0] == "group" && !groupIDs.contains(id) {
                issues.append("Trigger \(node.name.isEmpty ? "Unnamed" : node.name) targets a deleted group")
            }
        }
        return Array(Set(issues)).sorted()
    }
}

enum AICharacterKind: String, CaseIterable, Identifiable {
    case enemy = "Enemy"
    case friendly = "Friendly"

    var id: String { rawValue }
}

struct AICharacterDefinition: Identifiable, Equatable {
    var id = UUID()
    var name: String
    var kind: AICharacterKind
    var aiChannel: Int
    var bodySkin: String
    var chestSkin: String = ""
    var helmetSkin: String = ""
    var hairSkin: String = ""
    var customLayers: [String] = []
    var birthSpawn: String = "DefaultSpawn"
    var startDelay: Double = 0

    var skinFiles: [String] {
        ([bodySkin, chestSkin, helmetSkin, hairSkin] + customLayers)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

struct AIGroupDefinition: Identifiable, Equatable {
    var id = UUID()
    var name: String
    var characterIDs: Set<AICharacterDefinition.ID> = []
}

/// Generic scene tree node.
///
/// Vector 2 XML is not a clean "one object = one rectangle" format. Library
/// objects can expand into helper children, images can have matrix transforms,
/// and some editor nodes are UI-only. `LevelNode` is the common shape that lets
/// the canvas, hierarchy, inspector, importer, and exporter talk to each other.
struct LevelNode: Identifiable, Equatable {
    enum Kind: String {
        case document = "Document"
        case track = "Track"
        case factor = "Factor"
        case image = "Image"
        case object = "Object"
        case platform = "Collision"
        case trapezoid = "Trapezoid"
        case trigger = "Trigger"
        case area = "Area"
        case comment = "Comment"
        case coin = "Bonus"
        case camera = "Camera"
        case objectReference = "Object Reference"
        case dynamic = "Dynamic"
        case waypoint = "Waypoint"
        case gateIn = "In"
        case gateOut = "Out"

        var usesVectorRectOrigin: Bool {
            switch self {
        case .image, .platform, .trapezoid, .trigger, .area, .comment:
            return true
        default:
            return false
        }
        }
    }

    struct Transform: Equatable {
        var x: Int
        var y: Int
        var width: Int
        var height: Int
        var rotation: Double = 0
    }

    struct XMLSummary: Equatable {
        struct SelectionRule: Equatable, Hashable {
            var choice: String
            var variant: String
            var parentChoice: String = ""
        }

        var template: String = ""
        var choice: String = ""
        var variant: String = ""
        var parentChoice: String = ""
        // Vector treats repeated Selection elements as OR rules. Most nodes use
        // one rule; Shared Objects groups use the additional rules so one group
        // can appear in several chosen room layouts without duplicating content.
        var additionalSelections: [SelectionRule] = []
        var blend: String = "Normal"
    }

    struct Metadata: Equatable {
        var sortingLayer: String = ""
        var tag: String = ""
        var filename: String = ""
        var className: String = ""
        var imagePath: String = ""
        var isHidden: Bool = false
        var visualOffsetX: Int = 0
        var visualOffsetY: Int = 0
        var visualNativeWidth: Int = 0
        var visualNativeHeight: Int = 0
        var visualType: String = ""
        var visualDepth: String = ""
        var tintColorHex: String = ""
        var isMirrored: Bool = false
        var isFlippedVertically: Bool = false
        var matrixA: String = ""
        var matrixB: String = ""
        var matrixC: String = ""
        var matrixD: String = ""
        var matrixTx: String = ""
        var matrixTy: String = ""
        var sourceX: String = ""
        var sourceY: String = ""
        var sourceWidth: String = ""
        var sourceHeight: String = ""
        var sourceAttributes: [String: String] = [:]
        var libraryObjectName: String = ""
        var libraryOverrides: [String: String] = [:]
        var isTransformEdited: Bool = false
        var isHierarchyAttachment: Bool = false
        var dynamicXML: String = ""
        // RoomWeaver library references can contain animation deeper inside
        // nested objects. Keep this separate from dynamicXML: dynamicXML is
        // source/export data, while these fields are preview diagnostics only.
        var resolvedDynamicCount: Int = 0
        var resolvedDynamicOwners: String = ""
        // Canvas-only link from a flattened visual child back to the imported
        // object/container whose Dynamic block owns the whole assembly.
        var roomWeaverDynamicOwnerID: UUID? = nil
        var roomWeaverDynamicOwnerIDs: [UUID] = []
        // Every sorting-layer slice produced for one imported library reference
        // points back to the same selectable source. This lets the canvas draw a
        // selection around the complete assembled visual without changing which
        // XML object movement/editing targets.
        var roomWeaverVisualOwnerID: UUID? = nil
        // Canvas children of a Shared Objects group remain individually drawn,
        // but clicking any of them should select/move the owning group.
        var roomLayoutSharedOwnerID: UUID? = nil
        var dynamicTriggerXML: String = ""
        var sourceContentXML: String = ""
        var sourcePropertiesXML: String = ""
        var aiTarget: String = ""
        var aiActionTemplate: String = ""
        var aiActionValue: String = ""
        // Additional RoomWeaver render slices share the selectable source
        // object's geometry, but must never participate in canvas input.
        var isVisualOnlyLayer: Bool = false
    }

    struct PreviewPiece: Identifiable, Equatable {
        let id = UUID()
        var imagePath: String
        var centerX: Double
        var centerY: Double
        var width: Double
        var height: Double
        var rotation: Double
        var mirrored: Bool = false
        var basisXX: Double? = nil
        var basisXY: Double? = nil
        var basisYX: Double? = nil
        var basisYY: Double? = nil
        var tintColorHex: String = ""
        var sortingLayer: String = "Default"
    }

    let id = UUID()
    var name: String
    var kind: Kind
    var factor: String
    var transform: Transform?
    var xml: XMLSummary
    var metadata: Metadata = .init()
    var previewPieces: [PreviewPiece] = []
    var children: [LevelNode] = []
}

extension LevelNode.Kind {
    /// True for simple editor rectangles that can be drawn as selectable boxes.
    /// This includes comments for editor UX, but the exporter still skips them.
    var isEditorShape: Bool {
        self == .trigger || self == .area || self == .platform || self == .trapezoid || self == .comment
    }

    /// Fallback tag used when creating nodes from toolbar tools or incomplete
    /// XML. Imported objects can override this through metadata.
    var defaultTag: String {
        switch self {
        case .image: return "Image"
        case .object, .dynamic: return "Object"
        case .platform: return "Platform"
        case .trapezoid: return "Trapezoid"
        case .trigger: return "Trigger"
        case .area: return "Area"
        case .comment: return "Comment"
        case .coin: return "Bonus"
        case .camera: return "Camera"
        case .objectReference: return "ObjectReference"
        case .waypoint: return "Waypoint"
        case .gateIn: return "In"
        case .gateOut: return "Out"
        case .track: return "Track"
        case .factor: return "Factor"
        case .document: return "Document"
        }
    }

    var toolbarSymbol: String {
        switch self {
        case .image: return "photo"
        case .object, .objectReference, .dynamic: return "cube"
        case .platform: return "rectangle"
        case .trapezoid: return "triangle"
        case .trigger, .area: return "diamond"
        case .comment: return "circle"
        case .coin: return "circle.fill"
        case .camera: return "video"
        case .waypoint: return "mappin.and.ellipse"
        case .gateIn: return "arrow.left.to.line"
        case .gateOut: return "arrow.right.to.line"
        case .track: return "list.bullet"
        case .factor: return "number"
        case .document: return "doc"
        }
    }
}

extension LevelDocument {
    /// Creates a valid starter document.
    ///
    /// The shape matters: BuildMap Vec2 wants playable content under
    /// `Track -> Factor`, so the editor always starts with that structure.
    fileprivate static func empty(for game: GameProfile, index: Int) -> LevelDocument {
        let name = game == .vector2 ? "untitled_\(index).xml" : "vector_untitled_\(index).xml"
        let inNode = Vector2SpawnPrefabVisual.node(for: .gateIn, x: 0, y: 0)
        let outNode = Vector2SpawnPrefabVisual.node(for: .gateOut, x: 2200, y: 0)
        let factor = LevelNode(
            name: "Object Factor = 1",
            kind: .factor,
            factor: "1",
            transform: nil,
            xml: .init(),
            children: [inNode, outNode]
        )
        let track = LevelNode(
            name: "Track",
            kind: .track,
            factor: "1",
            transform: nil,
            xml: .init(),
            children: [factor]
        )
        let root = LevelNode(
            name: name,
            kind: .document,
            factor: "1",
            transform: nil,
            xml: .init(),
            children: [track]
        )
        return LevelDocument(name: name, sourcePath: nil, root: root, selectedNodeID: inNode.id, selectedNodeIDs: [inNode.id])
    }

    static func zoneBackgroundCanvas() -> LevelDocument {
        var document = empty(for: .vector2, index: 1)
        document.name = "Zone Backgrounds"
        document.sourcePath = "internal://zone-background-pool"
        // This is an artwork canvas, not a playable room. The pool save path
        // exports only background images and never writes custom_rooms XML.
        document.root.children[0].children[0].children.removeAll()
        document.selectedNodeID = nil
        document.selectedNodeIDs = []
        return document
    }

    static let sampleRoom201: LevelDocument = {
        let trigger = LevelNode(
            name: "TriggerZoomMax",
            kind: .trigger,
            factor: "1",
            transform: .init(x: 5180, y: -2060, width: 100, height: 182),
            xml: .init(template: "ZoomMax", choice: "AITriggers", variant: "CommonMode")
        )

        let swarm = LevelNode(
            name: "SwarmActivator",
            kind: .trigger,
            factor: "1",
            transform: .init(x: 2420, y: -2260, width: 116, height: 154),
            xml: .init(template: "SwarmActivator", choice: "Start_Zone", variant: "BeamVert_TrapS")
        )

        let bonusA = LevelNode(
            name: "Bonus",
            kind: .coin,
            factor: "1",
            transform: .init(x: 2140, y: -3980, width: 72, height: 72),
            xml: .init(template: "Bonus", choice: "Start_Zone", variant: "Common")
        )

        let bonusB = LevelNode(
            name: "Bonus",
            kind: .coin,
            factor: "1",
            transform: .init(x: 5340, y: -4010, width: 72, height: 72),
            xml: .init(template: "Bonus", choice: "Middle_Zone", variant: "Common")
        )

        let darkness = LevelNode(
            name: "DarknessOn",
            kind: .trigger,
            factor: "1",
            transform: .init(x: 520, y: -2400, width: 44, height: 128),
            xml: .init(template: "DarknessTrigger", choice: "Zone2", variant: "Tube")
        )

        let objectRef = LevelNode(
            name: "CameraStart",
            kind: .objectReference,
            factor: "1",
            transform: .init(x: 1016, y: -1074, width: 100, height: 100),
            xml: .init(template: "CameraStart", choice: "Triggers", variant: "Camera")
        )

        let platform = LevelNode(
            name: "Collision_01",
            kind: .platform,
            factor: "1",
            transform: .init(x: 0, y: -1700, width: 500, height: 300),
            xml: .init(template: "Platform", choice: "Start_Zone", variant: "Sticky")
        )

        let room = LevelNode(
            name: "room201.xml",
            kind: .document,
            factor: "1",
            transform: nil,
            xml: .init(),
            children: [
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
                            children: [darkness, swarm, trigger, bonusA, bonusB, objectRef, platform]
                        )
                    ]
                )
            ]
        )

        return LevelDocument(name: "room201.xml", sourcePath: nil, root: room, selectedNodeID: trigger.id, selectedNodeIDs: [trigger.id])
    }()

    static let sampleTriggers: LevelDocument = {
        let root = LevelNode(
            name: "triggers.xml",
            kind: .document,
            factor: "1",
            transform: nil,
            xml: .init(),
            children: [
                LevelNode(
                    name: "Objects",
                    kind: .object,
                    factor: "1",
                    transform: nil,
                    xml: .init(),
                    children: [
                        LevelNode(
                            name: "TriggerCameraStart",
                            kind: .trigger,
                            factor: "1",
                            transform: .init(x: 0, y: 0, width: 100, height: 100),
                            xml: .init(template: "CameraZoom", choice: "Camera", variant: "Start")
                        ),
                        LevelNode(
                            name: "ZoomMax",
                            kind: .trigger,
                            factor: "1",
                            transform: .init(x: 0, y: 0, width: 100, height: 100),
                            xml: .init(template: "CameraZoom", choice: "Camera", variant: "Max")
                        )
                    ]
                )
            ]
        )

        let selected = root.children.first?.children.first?.id
        return LevelDocument(name: "triggers.xml", sourcePath: nil, root: root, selectedNodeID: selected, selectedNodeIDs: selected.map { [$0] } ?? [])
    }()

    static let sampleObjects: LevelDocument = {
        let root = LevelNode(
            name: "objects.xml",
            kind: .document,
            factor: "1",
            transform: nil,
            xml: .init(),
            children: [
                LevelNode(
                    name: "Objects",
                    kind: .object,
                    factor: "1",
                    transform: nil,
                    xml: .init(),
                    children: [
                        LevelNode(
                            name: "Lift",
                            kind: .objectReference,
                            factor: "1",
                            transform: .init(x: 1808, y: -1700, width: 100, height: 100),
                            xml: .init(template: "Lift", choice: "Obstacles", variant: "Moving")
                        ),
                        LevelNode(
                            name: "DarknessTrigger",
                            kind: .objectReference,
                            factor: "1",
                            transform: .init(x: 46, y: -1340, width: 100, height: 100),
                            xml: .init(template: "DarknessTrigger", choice: "Zone2", variant: "Default")
                        )
                    ]
                )
            ]
        )

        let selected = root.children.first?.children.first?.id
        return LevelDocument(name: "objects.xml", sourcePath: nil, root: root, selectedNodeID: selected, selectedNodeIDs: selected.map { [$0] } ?? [])
    }()
}

extension LevelDocument {
    static let dynamicStudioSourcePath = "internal://dynamic-studio"
    static let aiStudioSourcePath = "internal://ai-studio"
    static let playerDesignerSourcePath = "internal://player-designer"
    static let triggerStudioSourcePath = "internal://trigger-studio"
    static let obstacleStudioSourcePath = "internal://obstacle-studio"
    static let helpStudioSourcePath = "internal://help"

    var isDynamicStudio: Bool {
        sourcePath == Self.dynamicStudioSourcePath
    }

    var isAIStudio: Bool {
        sourcePath == Self.aiStudioSourcePath
    }

    var isPlayerDesigner: Bool { sourcePath == Self.playerDesignerSourcePath }
    var isTriggerStudio: Bool { sourcePath == Self.triggerStudioSourcePath }
    var isObstacleStudio: Bool { sourcePath == Self.obstacleStudioSourcePath }
    var isHelpStudio: Bool { sourcePath == Self.helpStudioSourcePath }
    var isStructuralRoomStudio: Bool { structuralRoomKind != nil }
    var isHelperStudio: Bool { isDynamicStudio || isAIStudio || isPlayerDesigner || isTriggerStudio || isObstacleStudio || isHelpStudio }

    static func dynamicStudio() -> LevelDocument {
        LevelDocument(
            name: "Dynamic Studio",
            sourcePath: Self.dynamicStudioSourcePath,
            root: LevelNode(
                name: "Dynamic Studio",
                kind: .dynamic,
                factor: "1",
                transform: nil,
                xml: .init()
            )
        )
    }

    static func aiStudio() -> LevelDocument {
        LevelDocument(
            name: "AI Designer",
            sourcePath: Self.aiStudioSourcePath,
            root: LevelNode(name: "AI Designer", kind: .document, factor: "1", transform: nil, xml: .init())
        )
    }


    static func playerDesigner() -> LevelDocument {
        LevelDocument(name: "Player Designer", sourcePath: Self.playerDesignerSourcePath, root: LevelNode(name: "Player Designer", kind: .document, factor: "1", transform: nil, xml: .init()))
    }

    static func triggerStudio() -> LevelDocument {
        LevelDocument(name: "Trigger Designer", sourcePath: Self.triggerStudioSourcePath, root: LevelNode(name: "Trigger Designer", kind: .document, factor: "1", transform: nil, xml: .init()))
    }

    static func obstacleStudio() -> LevelDocument {
        let factor = LevelNode(name: "Obstacle", kind: .factor, factor: "1", transform: nil, xml: .init())
        return LevelDocument(name: "Obstacle Designer", sourcePath: Self.obstacleStudioSourcePath, root: LevelNode(name: "Obstacle", kind: .document, factor: "1", transform: nil, xml: .init(), children: [LevelNode(name: "Track", kind: .track, factor: "1", transform: nil, xml: .init(), children: [factor])]))
    }

    static func structuralRoomStudio(_ kind: StructuralRoomKind) -> LevelDocument {
        let factor = LevelNode(name: "Object Factor = 1", kind: .factor, factor: "1", transform: nil, xml: .init())
        var document = LevelDocument(
            name: kind.defaultFilename,
            sourcePath: nil,
            root: LevelNode(
                name: kind.defaultFilename,
                kind: .document,
                factor: "1",
                transform: nil,
                xml: .init(),
                children: [LevelNode(name: "Track", kind: .track, factor: "1", transform: nil, xml: .init(), children: [factor])]
            )
        )
        document.structuralRoomKind = kind
        document.addStructuralRoomEssentials()
        return document
    }

    static func helpStudio() -> LevelDocument {
        LevelDocument(name: "Help", sourcePath: Self.helpStudioSourcePath, root: LevelNode(name: "Help", kind: .document, factor: "1", transform: nil, xml: .init()))
    }

    /// Loads an XML file through the selected/current Vector 2 importer.
    ///
    /// If imported levels show green boxes, inspect the parser/builders called
    /// from here first. Green boxes mean the XML node loaded, but the visual
    /// resolver could not find a matching texture/library/prefab preview.
    static func loadFromXML(at path: String) -> LevelDocument? {
        switch Vector2ImportPipeline.current {
        case .roomWeaver:
            if RoomWeaverImporter.canImportRoom(at: path) {
                return RoomWeaverImporter.parseDocument(at: path)
            }
            return XMLSceneParser.parseDocument(at: path)
        case .runtimeGraph, .convertXmlObject2:
            return XMLSceneParser.parseDocument(at: path)
        }
    }

    func node(for id: LevelNode.ID?) -> LevelNode? {
        guard let id else { return nil }
        return root.find(id: id)
    }

    var selectedNode: LevelNode? {
        node(for: selectedNodeID)
    }

    var selectedNodes: [LevelNode] {
        selectedNodeIDs.compactMap { node(for: $0) }
    }

    var effectiveSelectedNodeIDs: [LevelNode.ID] {
        let ids = selectedNodeIDs.isEmpty ? (selectedNodeID.map { Set([$0]) } ?? []) : selectedNodeIDs
        // Keep the raw multi-selection intact. The canvas can select runtime children
        // under their parent for inspection/moving; pruning descendants here made
        // phantom/object groups feel like their owner node was eating the children.
        return ids.filter { root.find(id: $0) != nil }
    }

    var movableSelectedNodeIDs: [LevelNode.ID] {
        let ids = Array(effectiveSelectedNodeIDs)
        return ids.filter { id in
            !ids.contains { other in
                other != id && root.containsDescendant(id, under: other)
            }
        }
    }

    func reloadedFromSource() -> LevelDocument? {
        guard let sourcePath else { return nil }
        return Self.loadFromXML(at: sourcePath)
    }

    mutating func select(_ id: LevelNode.ID) {
        selectedNodeID = id
        selectedNodeIDs = [id]
    }

    mutating func setSelected(ids: [LevelNode.ID]) {
        let unique = Set(ids)
        selectedNodeIDs = unique
        selectedNodeID = ids.first ?? unique.first
    }

    mutating func toggleSelected(_ id: LevelNode.ID) {
        if selectedNodeIDs.contains(id) {
            selectedNodeIDs.remove(id)
            selectedNodeID = selectedNodeIDs.first
        } else {
            selectedNodeIDs.insert(id)
            selectedNodeID = id
        }
    }

    mutating func updateSelectedTransform(
        x: Int? = nil,
        y: Int? = nil,
        width: Int? = nil,
        height: Int? = nil,
        rotation: Double? = nil
    ) {
        let targetIDs = effectiveSelectedNodeIDs
        guard !targetIDs.isEmpty else { return }
        for targetID in targetIDs {
            root.update(id: targetID) { node in
                guard let current = node.transform else { return }
                let originalTransform = current
                if let x { node.transform?.x = x }
                if let y { node.transform?.y = y }
                if let width { node.transform?.width = width }
                if let height { node.transform?.height = height }
                if let rotation { node.transform?.rotation = rotation }
                if node.transform != originalTransform {
                    node.metadata.isTransformEdited = true
                }
                if let updated = node.transform, !node.keepsChildrenInLocalRoomWeaverSpace {
                    node.transformDescendants(from: current, to: updated)
                }
                node.syncSingleShapeWrapperChildIfNeeded()
            }
        }
    }

    mutating func updateSelectedCanvasTransform(
        x: Int? = nil,
        y: Int? = nil,
        width: Int? = nil,
        height: Int? = nil,
        rotation: Double? = nil
    ) {
        let targetIDs = effectiveSelectedNodeIDs
        guard !targetIDs.isEmpty else { return }
        for targetID in targetIDs {
            let parent = root.localRoomWeaverDisplayParent(for: targetID)
            root.update(id: targetID) { node in
                guard let current = node.transform else { return }
                let currentDisplay = parent.map {
                    Self.displayTransform(fromLocalTransform: current, under: $0, usesRectOrigin: node.kind.usesVectorRectOrigin)
                } ?? current
                let proposedDisplay = LevelNode.Transform(
                    x: x ?? currentDisplay.x,
                    y: y ?? currentDisplay.y,
                    width: width ?? currentDisplay.width,
                    height: height ?? currentDisplay.height,
                    rotation: rotation ?? currentDisplay.rotation
                )
                let proposedLocal = parent.map {
                    Self.localTransform(fromDisplayTransform: proposedDisplay, under: $0, usesRectOrigin: node.kind.usesVectorRectOrigin)
                } ?? proposedDisplay
                if !Self.applyImportedMatrixTranslation(to: &node, from: current, to: proposedLocal) {
                    node.transform = proposedLocal
                    if proposedLocal != current {
                        node.metadata.isTransformEdited = true
                    }
                }
                if !node.keepsChildrenInLocalRoomWeaverSpace {
                    node.transformDescendants(from: currentDisplay, to: proposedDisplay)
                }
                node.syncSingleShapeWrapperChildIfNeeded()
            }
        }
    }

    mutating func updateCanvasTransform(
        for targetID: LevelNode.ID,
        x: Int? = nil,
        y: Int? = nil,
        width: Int? = nil,
        height: Int? = nil,
        rotation: Double? = nil
    ) {
        let parent = root.localRoomWeaverDisplayParent(for: targetID)
        root.update(id: targetID) { node in
            guard let current = node.transform else { return }
            let currentDisplay = parent.map {
                Self.displayTransform(fromLocalTransform: current, under: $0, usesRectOrigin: node.kind.usesVectorRectOrigin)
            } ?? current
            let proposedDisplay = LevelNode.Transform(
                x: x ?? currentDisplay.x,
                y: y ?? currentDisplay.y,
                width: width ?? currentDisplay.width,
                height: height ?? currentDisplay.height,
                rotation: rotation ?? currentDisplay.rotation
            )
            let proposedLocal = parent.map {
                Self.localTransform(fromDisplayTransform: proposedDisplay, under: $0, usesRectOrigin: node.kind.usesVectorRectOrigin)
            } ?? proposedDisplay
            if !Self.applyImportedMatrixTranslation(to: &node, from: current, to: proposedLocal) {
                node.transform = proposedLocal
                if proposedLocal != current {
                    node.metadata.isTransformEdited = true
                }
            }
            if !node.keepsChildrenInLocalRoomWeaverSpace {
                node.transformDescendants(from: currentDisplay, to: proposedDisplay)
            }
            node.syncSingleShapeWrapperChildIfNeeded()
        }
    }

    mutating func flipSelectedNodes(horizontal: Bool, vertical: Bool) -> Bool {
        let targetIDs = effectiveSelectedNodeIDs
        guard !targetIDs.isEmpty else { return false }
        var didFlip = false
        for targetID in targetIDs {
            root.update(id: targetID) { node in
                guard node.kind != .document, node.kind != .track, node.kind != .factor else { return }
                if horizontal {
                    node.metadata.isMirrored.toggle()
                }
                if vertical {
                    node.metadata.isFlippedVertically.toggle()
                }
                node.metadata.isTransformEdited = true
                didFlip = true
            }
        }
        return didFlip
    }

    // Shared with LevelNodeTreeOperations.swift. This is module-internal on
    // purpose: tree helpers need the exact same RoomWeaver coordinate math.
    static func displayTransform(
        fromLocalTransform local: LevelNode.Transform,
        under parent: LevelNode,
        usesRectOrigin: Bool = false
    ) -> LevelNode.Transform {
        guard let parentTransform = parent.transform else { return local }
        let basis = canvasParentBasis(for: parent)
        let angle = local.rotation * .pi / 180
        let axisX = CGPoint(x: basis.a * cos(angle) + basis.c * sin(angle),
                            y: basis.b * cos(angle) + basis.d * sin(angle))
        let axisY = CGPoint(x: -basis.a * sin(angle) + basis.c * cos(angle),
                            y: -basis.b * sin(angle) + basis.d * cos(angle))
        let width = max(1, Int((Double(local.width) * hypot(axisX.x, axisX.y)).rounded()))
        let height = max(1, Int((Double(local.height) * hypot(axisY.x, axisY.y)).rounded()))
        let anchorX = Double(local.x) + (usesRectOrigin ? Double(local.width) / 2 : 0)
        let anchorY = Double(local.y) + (usesRectOrigin ? Double(local.height) / 2 : 0)
        return .init(
            x: Int((Double(parentTransform.x) + basis.a * anchorX + basis.c * anchorY
                - (usesRectOrigin ? Double(width) / 2 : 0)).rounded()),
            y: Int((Double(parentTransform.y) + basis.b * anchorX + basis.d * anchorY
                - (usesRectOrigin ? Double(height) / 2 : 0)).rounded()),
            width: width, height: height, rotation: atan2(axisX.y, axisX.x) * 180 / .pi
        )
    }

    private static func canvasParentBasis(for parent: LevelNode) -> (a: Double, b: Double, c: Double, d: Double) {
        guard let transform = parent.transform else { return (1, 0, 0, 1) }
        if let affine = roomWeaverAffineBasis(for: parent) {
            return affine
        }
        let scaleX = parent.metadata.visualNativeWidth > 0
            ? Double(transform.width) / Double(parent.metadata.visualNativeWidth)
            : 1
        let scaleY = parent.metadata.visualNativeHeight > 0
            ? Double(transform.height) / Double(parent.metadata.visualNativeHeight)
            : 1
        let angle = transform.rotation * .pi / 180
        return (cos(angle) * scaleX, sin(angle) * scaleX, -sin(angle) * scaleY, cos(angle) * scaleY)
    }

    private static func localTransform(
        fromDisplayTransform display: LevelNode.Transform,
        under parent: LevelNode,
        usesRectOrigin: Bool = false
    ) -> LevelNode.Transform {
        guard let parentTransform = parent.transform else { return display }
        let basis = canvasParentBasis(for: parent)
        let determinant = basis.a * basis.d - basis.b * basis.c
        guard abs(determinant) > 0.0001 else { return display }
        let angle = display.rotation * .pi / 180
        let localAngle = atan2((-basis.b * cos(angle) + basis.a * sin(angle)) / determinant,
                               (basis.d * cos(angle) - basis.c * sin(angle)) / determinant)
        let widthScale = hypot(basis.a * cos(localAngle) + basis.c * sin(localAngle),
                               basis.b * cos(localAngle) + basis.d * sin(localAngle))
        let heightScale = hypot(-basis.a * sin(localAngle) + basis.c * cos(localAngle),
                                -basis.b * sin(localAngle) + basis.d * cos(localAngle))
        let width = max(1, Int((Double(display.width) / max(0.0001, widthScale)).rounded()))
        let height = max(1, Int((Double(display.height) / max(0.0001, heightScale)).rounded()))
        let deltaX = Double(display.x - parentTransform.x) + (usesRectOrigin ? Double(display.width) / 2 : 0)
        let deltaY = Double(display.y - parentTransform.y) + (usesRectOrigin ? Double(display.height) / 2 : 0)
        return .init(
            x: Int(((basis.d * deltaX - basis.c * deltaY) / determinant
                - (usesRectOrigin ? Double(width) / 2 : 0)).rounded()),
            y: Int(((-basis.b * deltaX + basis.a * deltaY) / determinant
                - (usesRectOrigin ? Double(height) / 2 : 0)).rounded()),
            width: width, height: height, rotation: localAngle * 180 / .pi
        )
    }

    /// A pure move must not flatten an imported affine transform. Vector 2
    /// stores the rectangle origin separately from its matrix, so translating
    /// that origin preserves rotation, mirroring, and skew exactly.
    @discardableResult
    private static func applyImportedMatrixTranslation(
        to node: inout LevelNode,
        from current: LevelNode.Transform,
        to proposed: LevelNode.Transform
    ) -> Bool {
        guard !node.metadata.matrixA.isEmpty,
              !node.metadata.matrixB.isEmpty,
              !node.metadata.matrixC.isEmpty,
              !node.metadata.matrixD.isEmpty,
              !node.metadata.isTransformEdited,
              current.width == proposed.width,
              current.height == proposed.height,
              abs(current.rotation - proposed.rotation) < 0.0001,
              let sourceX = Double(node.metadata.sourceX),
              let sourceY = Double(node.metadata.sourceY) else { return false }

        let translatedX = sourceX + Double(proposed.x - current.x)
        let translatedY = sourceY + Double(proposed.y - current.y)
        let sourceXString = importedCoordinateString(translatedX)
        let sourceYString = importedCoordinateString(translatedY)
        node.transform = proposed
        node.metadata.sourceX = sourceXString
        node.metadata.sourceY = sourceYString
        node.metadata.sourceAttributes["X"] = sourceXString
        node.metadata.sourceAttributes["Y"] = sourceYString
        return true
    }

    private static func importedCoordinateString(_ value: Double) -> String {
        let rounded = value.rounded()
        if abs(value - rounded) < 0.000001 {
            return String(Int(rounded))
        }
        return String(value)
    }

    // Shared with LevelNodeTreeOperations.swift; do not duplicate this math.
    static func roomWeaverAffineBasis(for node: LevelNode) -> (a: Double, b: Double, c: Double, d: Double)? {
        guard node.metadata.visualType == "RoomWeaverContainer",
              let a = Double(node.metadata.matrixA), let b = Double(node.metadata.matrixB),
              let c = Double(node.metadata.matrixC), let d = Double(node.metadata.matrixD) else { return nil }
        // Imported containers store their source angle in the matrix; edits
        // store an extra angle in the transform. Compose it once for every path.
        let angle = node.metadata.isTransformEdited ? (node.transform?.rotation ?? 0) * .pi / 180 : 0
        let cosine = cos(angle), sine = sin(angle)
        let scaleX = node.metadata.isTransformEdited && node.metadata.visualNativeWidth > 0
            ? Double(node.transform?.width ?? node.metadata.visualNativeWidth) / Double(node.metadata.visualNativeWidth) : 1
        let scaleY = node.metadata.isTransformEdited && node.metadata.visualNativeHeight > 0
            ? Double(node.transform?.height ?? node.metadata.visualNativeHeight) / Double(node.metadata.visualNativeHeight) : 1
        return ((cosine * a - sine * b) * scaleX, (sine * a + cosine * b) * scaleX,
                (cosine * c - sine * d) * scaleY, (sine * c + cosine * d) * scaleY)
    }

    private static func rotate(vector: CGPoint, degrees: Double) -> CGPoint {
        let radians = degrees * .pi / 180
        let cosine = CGFloat(Foundation.cos(radians))
        let sine = CGFloat(Foundation.sin(radians))
        return CGPoint(
            x: vector.x * cosine - vector.y * sine,
            y: vector.x * sine + vector.y * cosine
        )
    }

    private static func inverseRotate(vector: CGPoint, degrees: Double) -> CGPoint {
        let radians = -degrees * .pi / 180
        let cosine = CGFloat(Foundation.cos(radians))
        let sine = CGFloat(Foundation.sin(radians))
        return CGPoint(
            x: vector.x * cosine - vector.y * sine,
            y: vector.x * sine + vector.y * cosine
        )
    }

    mutating func updateTransform(
        for id: LevelNode.ID,
        x: Int? = nil,
        y: Int? = nil,
        width: Int? = nil,
        height: Int? = nil,
        rotation: Double? = nil
    ) {
        root.update(id: id) { node in
            guard node.transform != nil else { return }
            let originalTransform = node.transform
            if let x { node.transform?.x = x }
            if let y { node.transform?.y = y }
            if let width { node.transform?.width = width }
            if let height { node.transform?.height = height }
            if let rotation { node.transform?.rotation = rotation }
            if node.transform != originalTransform {
                node.metadata.isTransformEdited = true
            }
            node.syncSingleShapeWrapperChildIfNeeded()
        }
    }

    mutating func updateSelectedText(
        name: String? = nil,
        factor: String? = nil,
        sortingLayer: String? = nil,
        tag: String? = nil,
        filename: String? = nil,
        className: String? = nil,
        template: String? = nil,
        choice: String? = nil,
        variant: String? = nil
    ) {
        guard let selectedNodeID else { return }
        root.update(id: selectedNodeID) { node in
            if let name { node.name = name }
            if let factor { node.factor = factor }
            if let sortingLayer { node.metadata.sortingLayer = sortingLayer }
            if let tag { node.metadata.tag = tag }
            if let filename { node.metadata.filename = filename }
            if let className { node.metadata.className = className }
            if let template { node.xml.template = template }
            if let choice { node.xml.choice = choice }
            if let variant { node.xml.variant = variant }
        }
    }

    /// Flattened nodes the canvas should draw/edit.
    ///
    /// This unwraps document/track/factor containers so users click gameplay
    /// objects, not XML bookkeeping nodes.
    var canvasNodes: [LevelNode] {
        root.flattenedSceneNodes()
    }

    mutating func clearSelection() {
        selectedNodeID = nil
        selectedNodeIDs.removeAll()
    }

    mutating func deleteSelectedNode() -> Bool {
        let targetIDs = effectiveSelectedNodeIDs
        guard !targetIDs.isEmpty else { return false }
        var removedAny = false
        for id in targetIDs {
            if root.remove(id: id) {
                removedAny = true
            }
        }
        if removedAny {
            self.selectedNodeID = root.flattenedSceneNodes().first?.id
            self.selectedNodeIDs = selectedNodeID.map { [$0] } ?? []
        }
        return removedAny
    }

    /// Places one of the built-in left-rail tools.
    ///
    /// Asset-browser placement uses `appendAsset`; this function is only for
    /// built-in primitives such as platforms, triggers, comments, gates, RunFast,
    /// waypoints, and trapezoids. `alternateVariant` is the Y-key Type 2
    /// trapezoid path.
    mutating func appendNodeForPlacement(tool: EditorTool, x: Int, y: Int, alternateVariant: Bool = false) {
        guard tool.canPlaceDirectlyOnCanvas else { return }
        let useAlternatePlacement = tool == .trapezoid && alternateVariant
        guard let newNode = LevelNode.makePlacementNode(for: tool, x: x, y: y, alternateVariant: useAlternatePlacement) else { return }
        let insertedID = newNode.id

        if !root.appendToFirstFactor(newNode) {
            root.children.append(
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
                            children: [newNode]
                        )
                    ]
                )
            )
        }

        selectedNodeID = insertedID
        selectedNodeIDs = [insertedID]
        applyEditingRoomLayoutToSelection()
    }

    mutating func duplicateSelectedNode(offsetX: Int = 240, offsetY: Int = -140) {
        guard let selectedNode, selectedNode.kind != .document, selectedNode.kind != .track, selectedNode.kind != .factor else { return }
        let duplicated = selectedNode.duplicated(offsetX: offsetX, offsetY: offsetY)
        if root.appendToFirstFactor(duplicated) {
            selectedNodeID = duplicated.id
            selectedNodeIDs = [duplicated.id]
        }
    }

    mutating func pasteNode(_ node: LevelNode, offsetX: Int = 240, offsetY: Int = -140) {
        guard node.kind != .document, node.kind != .track, node.kind != .factor else { return }
        let pasted = node.duplicated(offsetX: offsetX, offsetY: offsetY)
        if root.appendToFirstFactor(pasted) {
            selectedNodeID = pasted.id
            selectedNodeIDs = [pasted.id]
        }
    }

    mutating func moveSelectedNodes(byX deltaX: Int, y deltaY: Int) {
        let targetIDs = movableSelectedNodeIDs
        for id in targetIDs {
            let parent = root.localRoomWeaverDisplayParent(for: id)
            root.update(id: id) { node in
                guard let current = node.transform else { return }
                let currentDisplay = parent.map {
                    Self.displayTransform(fromLocalTransform: current, under: $0, usesRectOrigin: node.kind.usesVectorRectOrigin)
                } ?? current
                let proposedDisplay = LevelNode.Transform(
                    x: currentDisplay.x + deltaX,
                    y: currentDisplay.y + deltaY,
                    width: currentDisplay.width,
                    height: currentDisplay.height,
                    rotation: currentDisplay.rotation
                )
                let proposedLocal = parent.map {
                    Self.localTransform(fromDisplayTransform: proposedDisplay, under: $0, usesRectOrigin: node.kind.usesVectorRectOrigin)
                } ?? proposedDisplay
                if !Self.applyImportedMatrixTranslation(to: &node, from: current, to: proposedLocal) {
                    node.transform = proposedLocal
                    node.metadata.isTransformEdited = true
                }
                if !node.keepsChildrenInLocalRoomWeaverSpace {
                    node.transformDescendants(from: currentDisplay, to: proposedDisplay)
                }
            }
        }
    }

    /// Drag-move selected nodes from frozen drag-start transforms.
    ///
    /// This is why group movement is okay: every selected top-level node gets
    /// translated by the same delta, and descendants are translated with their
    /// parent. Group resizing is intentionally not implemented the same way
    /// because scaling nested Vector 2 visualizers was corrupting layouts.
    mutating func moveSelectedNodes(from origins: [LevelNode.ID: LevelNode.Transform], byX deltaX: Int, y deltaY: Int) {
        let targetIDs = movableSelectedNodeIDs
        for id in targetIDs {
            guard let origin = origins[id] else { continue }
            let parent = root.localRoomWeaverDisplayParent(for: id)
            root.update(id: id) { node in
                guard node.transform != nil else { return }
                let oldTransform = node.transform!
                let proposedDisplay = LevelNode.Transform(
                    x: origin.x + deltaX, y: origin.y + deltaY,
                    width: origin.width, height: origin.height, rotation: origin.rotation
                )
                let proposedLocal = parent.map { Self.localTransform(fromDisplayTransform: proposedDisplay, under: $0, usesRectOrigin: node.kind.usesVectorRectOrigin) } ?? proposedDisplay
                if !Self.applyImportedMatrixTranslation(to: &node, from: oldTransform, to: proposedLocal) {
                    node.transform = proposedLocal
                    node.metadata.isTransformEdited = true
                }
                if !node.keepsChildrenInLocalRoomWeaverSpace {
                    node.transformDescendants(from: oldTransform, to: node.transform!)
                }
            }
        }
    }

    mutating func moveNode(from origin: LevelNode.Transform?, id: LevelNode.ID, byX deltaX: Int, y deltaY: Int) {
        guard let origin else { return }
        let previousSelection = selectedNodeIDs
        selectedNodeIDs = [id]
        moveSelectedNodes(from: [id: origin], byX: deltaX, y: deltaY)
        selectedNodeIDs = previousSelection
    }

    func selectedTransformSnapshots() -> [LevelNode.ID: LevelNode.Transform] {
        Dictionary(
            uniqueKeysWithValues: movableSelectedNodeIDs.compactMap { id in
                guard let transform = root.find(id: id)?.transform else { return nil }
                // Use the same composed canvas transform as RoomWeaver rendering.
                // Reconstructing only the nearest parent here caused nested imported
                // assemblies to jump when a drag began.
                return (id, root.canvasTransform(for: id, localTransform: transform))
            }
        )
    }

    func rotationHandleOrigins(for nodeID: LevelNode.ID, selectionFrame: LevelNode.Transform,
                               isGroup: Bool) -> [LevelNode.ID: LevelNode.Transform] {
        // The handle's frame is presentation geometry, never editable XML data.
        selectedTransformSnapshots()
    }

    static func projectVisualEdit(_ visual: LevelNode.Transform, usesRectOrigin: Bool,
                                  from origin: LevelNode.Transform, to preview: LevelNode.Transform,
                                  ownerUsesRectOrigin: Bool) -> LevelNode.Transform {
        let oldX = Double(origin.x) + (ownerUsesRectOrigin ? Double(origin.width) / 2 : 0)
        let oldY = Double(origin.y) + (ownerUsesRectOrigin ? Double(origin.height) / 2 : 0)
        let newX = Double(preview.x) + (ownerUsesRectOrigin ? Double(preview.width) / 2 : 0)
        let newY = Double(preview.y) + (ownerUsesRectOrigin ? Double(preview.height) / 2 : 0)
        let sx = Double(preview.width) / Double(max(1, origin.width))
        let sy = Double(preview.height) / Double(max(1, origin.height))
        let x = (Double(visual.x) + (usesRectOrigin ? Double(visual.width) / 2 : 0) - oldX) * sx
        let y = (Double(visual.y) + (usesRectOrigin ? Double(visual.height) / 2 : 0) - oldY) * sy
        let angle = (preview.rotation - origin.rotation) * .pi / 180
        let width = max(1, Int((Double(visual.width) * sx).rounded()))
        let height = max(1, Int((Double(visual.height) * sy).rounded()))
        return .init(x: Int((newX + x * cos(angle) - y * sin(angle) - (usesRectOrigin ? Double(width) / 2 : 0)).rounded()),
            y: Int((newY + x * sin(angle) + y * cos(angle) - (usesRectOrigin ? Double(height) / 2 : 0)).rounded()),
            width: width, height: height, rotation: visual.rotation + preview.rotation - origin.rotation)
    }

    /// Combined selection rectangle used for outlines/handles.
    ///
    /// This should stay as display math. Do not treat it as a real parent
    /// transform unless the port implements a proper group transform model.
    func selectedBounds(from origins: [LevelNode.ID: LevelNode.Transform]? = nil) -> LevelNode.Transform? {
        let targetIDs = movableSelectedNodeIDs
        var rects: [CGRect] = []
        for id in targetIDs {
            guard let node = root.find(id: id),
                  let transform = origins?[id] ?? node.transform else { continue }
            rects.append(visualBoundsRect(for: node, transform: transform))
        }
        guard var bounds = rects.first else { return nil }
        for rect in rects.dropFirst() {
            bounds = bounds.union(rect)
        }
        return LevelNode.Transform(
            x: Int(bounds.minX.rounded()),
            y: Int(bounds.minY.rounded()),
            width: max(1, Int(bounds.width.rounded())),
            height: max(1, Int(bounds.height.rounded())),
            rotation: 0
        )
    }

    /// Bounding frame expressed in the shared rotation of the selected nodes.
    /// This is display-only math for the multi-selection outline.
    func selectedBounds(
        alignedTo rotation: Double,
        from origins: [LevelNode.ID: LevelNode.Transform]? = nil
    ) -> LevelNode.Transform? {
        let radians = -rotation * .pi / 180
        let cosine = CGFloat(Foundation.cos(radians))
        let sine = CGFloat(Foundation.sin(radians))
        var alignedBounds: CGRect?

        for id in movableSelectedNodeIDs {
            guard let node = root.find(id: id),
                  let transform = origins?[id] ?? node.transform else { continue }
            let nodeBounds = boundsRect(for: node, transform: transform)
            let center = CGPoint(x: nodeBounds.midX, y: nodeBounds.midY)
            let alignedCenter = CGPoint(
                x: center.x * cosine - center.y * sine,
                y: center.x * sine + center.y * cosine
            )
            let rect = CGRect(
                x: alignedCenter.x - nodeBounds.width / 2,
                y: alignedCenter.y - nodeBounds.height / 2,
                width: nodeBounds.width,
                height: nodeBounds.height
            )
            alignedBounds = alignedBounds.map { $0.union(rect) } ?? rect
        }

        guard let alignedBounds else { return nil }
        let inverseRadians = rotation * .pi / 180
        let inverseCosine = CGFloat(Foundation.cos(inverseRadians))
        let inverseSine = CGFloat(Foundation.sin(inverseRadians))
        let alignedCenter = CGPoint(x: alignedBounds.midX, y: alignedBounds.midY)
        let worldCenter = CGPoint(
            x: alignedCenter.x * inverseCosine - alignedCenter.y * inverseSine,
            y: alignedCenter.x * inverseSine + alignedCenter.y * inverseCosine
        )
        let width = max(1, Int(alignedBounds.width.rounded()))
        let height = max(1, Int(alignedBounds.height.rounded()))
        return LevelNode.Transform(
            x: Int((worldCenter.x - CGFloat(width) / 2).rounded()),
            y: Int((worldCenter.y - CGFloat(height) / 2).rounded()),
            width: width,
            height: height,
            rotation: rotation
        )
    }

    func commonMovableSelectionRotation(from origins: [LevelNode.ID: LevelNode.Transform]? = nil) -> Double? {
        let rotations = movableSelectedNodeIDs.compactMap { id -> Double? in
            origins?[id]?.rotation ?? root.find(id: id)?.transform?.rotation
        }
        guard let first = rotations.first else { return nil }
        let normalizedFirst = normalizedRotation(first)
        guard rotations.allSatisfy({ abs(normalizedRotation($0) - normalizedFirst) < 0.001 }) else {
            return nil
        }
        return first
    }

    mutating func applyTransforms(_ transforms: [LevelNode.ID: LevelNode.Transform]) {
        for (id, transform) in transforms {
            let parent = root.localRoomWeaverDisplayParent(for: id)
            root.update(id: id) { node in
                guard let current = node.transform else { return }
                let proposed = parent.map { Self.localTransform(fromDisplayTransform: transform, under: $0, usesRectOrigin: node.kind.usesVectorRectOrigin) } ?? transform
                node.transform = proposed
                if CanvasTransformEditPolicy.shouldMarkEdited(current: current, proposed: proposed) {
                    // Imported matrix art keeps using its source matrix until a
                    // real resize/rotation turns it into an editable transform.
                    node.metadata.isTransformEdited = true
                }
                node.syncSingleShapeWrapperChildIfNeeded()
            }
        }
    }

    /// Legacy group-resize mutator.
    ///
    /// Keep this documented because it is tempting to call from UI code, but it
    /// is unsafe for complex Vector 2 groups. Library objects often contain
    /// trigger/platform/image children that are not true local-transform children,
    /// so scaling the parent selection can stretch the internals into nonsense.
    /// Prefer single-node resize from `CanvasArea.resizeGesture`.
    mutating func resizeSelectedNodes(
        from origins: [LevelNode.ID: LevelNode.Transform],
        originalBounds: LevelNode.Transform,
        to newBounds: LevelNode.Transform
    ) {
        let scaleX = Double(newBounds.width) / Double(max(1, originalBounds.width))
        let scaleY = Double(newBounds.height) / Double(max(1, originalBounds.height))
        let targetIDs = effectiveSelectedNodeIDs

        for id in targetIDs {
            guard let origin = origins[id],
                  let originalNode = root.find(id: id) else { continue }
            let oldCenter = centerPoint(for: originalNode, transform: origin)
            let newCenterX = Double(newBounds.x) + (Double(oldCenter.x) - Double(originalBounds.x)) * scaleX
            let newCenterY = Double(newBounds.y) + (Double(oldCenter.y) - Double(originalBounds.y)) * scaleY
            let newWidth = max(1, Int((Double(origin.width) * scaleX).rounded()))
            let newHeight = max(1, Int((Double(origin.height) * scaleY).rounded()))

            root.update(id: id) { node in
                guard node.transform != nil else { return }
                if node.kind.usesVectorRectOrigin {
                    node.transform?.x = Int((newCenterX - Double(newWidth) / 2).rounded())
                    node.transform?.y = Int((newCenterY - Double(newHeight) / 2).rounded())
                } else {
                    node.transform?.x = Int(newCenterX.rounded())
                    node.transform?.y = Int(newCenterY.rounded())
                }
                node.transform?.width = newWidth
                node.transform?.height = newHeight
                node.syncSingleShapeWrapperChildIfNeeded()
            }
        }
    }

    /// Pure transform version of the legacy group-resize math.
    ///
    /// Useful for experiments/previews, but same warning as above: this is not a
    /// complete Affinity/Photoshop group transform model.
    func resizedSelectedTransforms(
        from origins: [LevelNode.ID: LevelNode.Transform],
        originalBounds: LevelNode.Transform,
        to newBounds: LevelNode.Transform
    ) -> [LevelNode.ID: LevelNode.Transform] {
        let scaleX = Double(newBounds.width) / Double(max(1, originalBounds.width))
        let scaleY = Double(newBounds.height) / Double(max(1, originalBounds.height))
        let originalCenter = CGPoint(
            x: CGFloat(originalBounds.x) + CGFloat(originalBounds.width) / 2,
            y: CGFloat(originalBounds.y) + CGFloat(originalBounds.height) / 2
        )
        let newCenter = CGPoint(
            x: CGFloat(newBounds.x) + CGFloat(newBounds.width) / 2,
            y: CGFloat(newBounds.y) + CGFloat(newBounds.height) / 2
        )

        var result: [LevelNode.ID: LevelNode.Transform] = [:]
        for id in effectiveSelectedNodeIDs {
            guard let origin = origins[id],
                  let node = root.find(id: id) else { continue }
            let oldCenter = centerPoint(for: node, transform: origin)
            let transformedCenter = CGPoint(
                x: newCenter.x + (oldCenter.x - originalCenter.x) * CGFloat(scaleX),
                y: newCenter.y + (oldCenter.y - originalCenter.y) * CGFloat(scaleY)
            )
            let newWidth = max(1, Int((Double(origin.width) * scaleX).rounded()))
            let newHeight = max(1, Int((Double(origin.height) * scaleY).rounded()))
            result[id] = transform(
                for: node,
                centeredAt: transformedCenter,
                width: newWidth,
                height: newHeight,
                rotation: origin.rotation
            )
        }
        return result
    }

    static func libraryArtworkOffset(for node: LevelNode, transform: LevelNode.Transform) -> CGPoint {
        let sx = node.metadata.visualNativeWidth > 0 ? Double(transform.width) / Double(node.metadata.visualNativeWidth) : 1
        let sy = node.metadata.visualNativeHeight > 0 ? Double(transform.height) / Double(node.metadata.visualNativeHeight) : 1
        let x = Double(node.metadata.visualOffsetX) * sx
        let y = Double(node.metadata.visualOffsetY) * sy
        let angle = transform.rotation * .pi / 180
        return CGPoint(x: x * cos(angle) - y * sin(angle), y: x * sin(angle) + y * cos(angle))
    }

    static func libraryHelperCenter(localCenter: CGPoint, root: LevelNode, transform: LevelNode.Transform,
                                    scaleX: Double, scaleY: Double) -> CGPoint {
        let x = localCenter.x * scaleX
        let y = localCenter.y * scaleY
        let angle = transform.rotation * .pi / 180
        return CGPoint(x: CGFloat(transform.x) + x * cos(angle) - y * sin(angle),
                       y: CGFloat(transform.y) + x * sin(angle) + y * cos(angle))
    }

    func rotatedSelectedTransforms(
        from origins: [LevelNode.ID: LevelNode.Transform],
        around center: CGPoint,
        by degrees: Double
    ) -> [LevelNode.ID: LevelNode.Transform] {
        var result: [LevelNode.ID: LevelNode.Transform] = [:]
        for id in movableSelectedNodeIDs {
            guard let origin = origins[id],
                  let node = root.find(id: id) else { continue }
            // Library artwork and its XML origin use one matrix in both render paths.
            let oldCenter = node.metadata.visualType == "RoomWeaverLibraryReference"
                ? centerPoint(for: node, transform: origin)
                : rotationAnchorPoint(for: node, transform: origin)
            let newCenter = rotate(point: oldCenter, around: center, degrees: degrees)
            result[id] = transform(for: node, movingVisualCenterFrom: oldCenter, to: newCenter, origin: origin, rotation: origin.rotation + degrees)
        }
        return result
    }

    private func rotationAnchorPoint(for node: LevelNode, transform: LevelNode.Transform) -> CGPoint {
        var center = centerPoint(for: node, transform: transform)
        if node.metadata.visualOffsetX != 0 || node.metadata.visualOffsetY != 0 {
            center.x += CGFloat(node.metadata.visualOffsetX)
            center.y += CGFloat(node.metadata.visualOffsetY)
        }
        return center
    }

    private func visualBoundsRect(for node: LevelNode, transform: LevelNode.Transform) -> CGRect {
        let childRects = node.children.compactMap { child -> CGRect? in
            guard !child.metadata.isHidden, let childTransform = child.transform else { return nil }
            return visualBoundsRect(for: child, transform: childTransform)
        }
        guard var bounds = childRects.first else {
            return boundsRect(for: node, transform: transform)
        }
        for rect in childRects.dropFirst() {
            bounds = bounds.union(rect)
        }
        return bounds
    }

    private func boundsRect(for node: LevelNode, transform: LevelNode.Transform) -> CGRect {
        if node.kind.usesVectorRectOrigin {
            return CGRect(x: transform.x, y: transform.y, width: transform.width, height: transform.height)
        }
        return CGRect(
            x: transform.x - transform.width / 2,
            y: transform.y - transform.height / 2,
            width: transform.width,
            height: transform.height
        )
    }

    private func visualCenterPoint(for node: LevelNode, transform: LevelNode.Transform) -> CGPoint {
        let bounds = visualBoundsRect(for: node, transform: transform)
        return CGPoint(x: bounds.midX, y: bounds.midY)
    }

    private func centerPoint(for node: LevelNode, transform: LevelNode.Transform) -> CGPoint {
        if node.kind.usesVectorRectOrigin {
            return CGPoint(x: CGFloat(transform.x) + CGFloat(transform.width) / 2, y: CGFloat(transform.y) + CGFloat(transform.height) / 2)
        }
        return CGPoint(x: CGFloat(transform.x), y: CGFloat(transform.y))
    }

    private func transform(
        for node: LevelNode,
        centeredAt center: CGPoint,
        width: Int,
        height: Int,
        rotation: Double
    ) -> LevelNode.Transform {
        if node.kind.usesVectorRectOrigin {
            return LevelNode.Transform(
                x: Int((center.x - CGFloat(width) / 2).rounded()),
                y: Int((center.y - CGFloat(height) / 2).rounded()),
                width: width,
                height: height,
                rotation: rotation
            )
        }
        return LevelNode.Transform(
            x: Int(center.x.rounded()),
            y: Int(center.y.rounded()),
            width: width,
            height: height,
            rotation: rotation
        )
    }

    private func transform(
        for node: LevelNode,
        movingVisualCenterFrom oldCenter: CGPoint,
        to newCenter: CGPoint,
        origin: LevelNode.Transform,
        rotation: Double
    ) -> LevelNode.Transform {
        LevelNode.Transform(
            x: Int((CGFloat(origin.x) + newCenter.x - oldCenter.x).rounded()),
            y: Int((CGFloat(origin.y) + newCenter.y - oldCenter.y).rounded()),
            width: origin.width,
            height: origin.height,
            rotation: rotation
        )
    }

    private func rotate(point: CGPoint, around center: CGPoint, degrees: Double) -> CGPoint {
        let radians = degrees * .pi / 180
        let translatedX = point.x - center.x
        let translatedY = point.y - center.y
        let cosine = CGFloat(Foundation.cos(radians))
        let sine = CGFloat(Foundation.sin(radians))
        return CGPoint(
            x: center.x + translatedX * cosine - translatedY * sine,
            y: center.y + translatedX * sine + translatedY * cosine
        )
    }

    private func normalizedRotation(_ rotation: Double) -> Double {
        var value = rotation.truncatingRemainder(dividingBy: 360)
        if value < 0 { value += 360 }
        return value
    }

    func prunedSelectionIDs(_ ids: [LevelNode.ID]) -> [LevelNode.ID] {
        ids.filter { id in
            guard let node = root.find(id: id) else { return false }
            if node.kind == .trigger || node.kind == .area || node.kind == .platform || node.kind == .trapezoid {
                return true
            }
            return !ids.contains { other in
                other != id && root.containsDescendant(id, under: other)
            }
        }
    }

    func prunedMarqueeSelectionIDs(_ ids: [LevelNode.ID]) -> [LevelNode.ID] {
        var unique: [LevelNode.ID] = []
        var seen: Set<LevelNode.ID> = []
        for id in ids where root.find(id: id) != nil && !seen.contains(id) {
            unique.append(id)
            seen.insert(id)
        }
        return unique.filter { id in
            !unique.contains { other in
                other != id && root.containsDescendant(id, under: other)
            }
        }
    }

    mutating func setHidden(_ hidden: Bool, for id: LevelNode.ID) {
        root.update(id: id) { node in
            node.metadata.isHidden = hidden
        }
    }

    mutating func replaceSelectedNode(with replacement: LevelNode) {
        guard let selectedNodeID else { return }
        if root.replace(id: selectedNodeID, with: replacement) {
            self.selectedNodeID = replacement.id
            self.selectedNodeIDs = [replacement.id]
        }
    }

    mutating func reparentSelectedNodes(to parentID: LevelNode.ID) {
        let targetIDs = selectedNodeIDs.isEmpty ? (selectedNodeID.map { [$0] } ?? []) : Array(selectedNodeIDs)
        guard !targetIDs.isEmpty else { return }
        guard !targetIDs.contains(parentID) else { return }
        guard !targetIDs.contains(where: { root.find(id: $0)?.containsDescendant(id: parentID) == true }) else { return }

        var extracted: [LevelNode] = []
        root.extract(ids: Set(targetIDs), into: &extracted)
        guard !extracted.isEmpty else { return }
        extracted = extracted.map { node in
            var node = node
            node.markHierarchyAttachment(true)
            return node
        }
        if !root.append(children: extracted, to: parentID) {
            for child in extracted {
                _ = root.appendToFirstFactor(child)
            }
        }
        selectedNodeID = extracted.first?.id
        selectedNodeIDs = Set(extracted.map(\.id))
    }

    mutating func reparentSelectedNodesToSceneRoot() {
        let targetIDs = selectedNodeIDs.isEmpty ? (selectedNodeID.map { [$0] } ?? []) : Array(selectedNodeIDs)
        guard !targetIDs.isEmpty else { return }

        var extracted: [LevelNode] = []
        root.extract(ids: Set(targetIDs), into: &extracted)
        guard !extracted.isEmpty else { return }

        extracted = extracted.map { node in
            var node = node
            node.markHierarchyAttachment(false)
            return node
        }
        for child in extracted {
            _ = root.appendToFirstFactor(child)
        }
        selectedNodeID = extracted.first?.id
        selectedNodeIDs = Set(extracted.map(\.id))
    }

    mutating func appendAsset(_ asset: TextureAsset, tool: EditorTool = .images, x: Int? = nil, y: Int? = nil) {
        switch asset.kind {
        case .texture:
            appendImageAsset(asset, x: x, y: y, asBackground: tool == .backgrounds)
        case .libraryObject, .prefab:
            appendObjectReferenceAsset(asset, x: x, y: y)
        }
    }

    private mutating func appendImageAsset(_ asset: TextureAsset, x requestedX: Int? = nil, y requestedY: Int? = nil, asBackground: Bool = false) {
        let insertIndex = canvasNodes.count
        let x = requestedX ?? (600 + (insertIndex % 6) * 220)
        let y = requestedY ?? (-600 - (insertIndex / 6) * 180)
        let imageSize = asset.editorCanvasSize
        let node = LevelNode(
            name: asBackground ? "Background" : asset.name,
            kind: .image,
            factor: "0",
            transform: .init(x: x, y: y, width: imageSize.width, height: imageSize.height),
            xml: .init(template: asBackground ? "Background" : "Image", choice: asset.category, variant: "Default"),
            metadata: .init(
                sortingLayer: asBackground ? "BgFar" : asset.defaultLayer,
                tag: asBackground ? "Background" : LevelNode.Kind.image.defaultTag,
                filename: "",
                className: asset.className,
                imagePath: asset.filePath,
                visualNativeWidth: imageSize.width,
                visualNativeHeight: imageSize.height
            )
        )
        if root.appendToFirstFactor(node) {
            selectedNodeID = node.id
            selectedNodeIDs = [node.id]
            applyEditingRoomLayoutToSelection()
        }
    }

    private mutating func appendObjectReferenceAsset(_ asset: TextureAsset, x requestedX: Int? = nil, y requestedY: Int? = nil) {
        let insertIndex = canvasNodes.count
        let x = requestedX ?? (600 + (insertIndex % 6) * 220)
        let y = requestedY ?? (-600 - (insertIndex / 6) * 180)
        if !asset.obstaclePackagePath.isEmpty,
           let loaded = try? ObstaclePackageStore.read(URL(fileURLWithPath: asset.obstaclePackagePath)),
           let source = LevelDocument.loadFromXML(at: loaded.extractionRoot.appendingPathComponent("obstacle.xml").path) {
            var nodes = source.root.firstFactorChildren
            let minX = nodes.compactMap { $0.transform?.x }.min() ?? 0
            let minY = nodes.compactMap { $0.transform?.y }.min() ?? 0
            nodes = nodes.map { value in var value = value; value.offsetTree(x: x - minX, y: y - minY); return value }
            for node in nodes { _ = root.appendToFirstFactor(node) }
            selectedNodeID = nodes.first?.id; selectedNodeIDs = Set(nodes.map(\.id)); applyEditingRoomLayoutToSelection()
            return
        }
        if asset.kind == .libraryObject,
           let reconstructed = Vector2LibraryObjectBuilder.reconstruct(asset: asset, x: x, y: y) {
            if root.appendToFirstFactor(reconstructed) {
                selectedNodeID = reconstructed.id
                selectedNodeIDs = [reconstructed.id]
                applyEditingRoomLayoutToSelection()
            }
            return
        }
        if asset.kind == .prefab,
           let reconstructed = UnityPrefabObjectBuilder.reconstruct(asset: asset, x: x, y: y) {
            if root.appendToFirstFactor(reconstructed) {
                selectedNodeID = reconstructed.id
                selectedNodeIDs = [reconstructed.id]
                applyEditingRoomLayoutToSelection()
            }
            return
        }

        let node = LevelNode(
            name: asset.name,
            kind: .objectReference,
            factor: "1",
            transform: .init(x: x, y: y, width: 120, height: 120),
            xml: .init(template: asset.kind.rawValue, choice: asset.category, variant: "Default"),
            metadata: .init(
                sortingLayer: asset.defaultLayer,
                tag: LevelNode.Kind.objectReference.defaultTag,
                filename: asset.filePath.isEmpty ? asset.category : URL(fileURLWithPath: asset.filePath).lastPathComponent,
                className: asset.className,
                libraryObjectName: asset.libraryObjectName,
                libraryOverrides: asset.libraryOverrides
            )
        )
        if root.appendToFirstFactor(node) {
            selectedNodeID = node.id
            selectedNodeIDs = [node.id]
            applyEditingRoomLayoutToSelection()
        }
    }

    /// Rebuilds already-placed custom traps after Trap Designer changes their
    /// art or geometry. Preserve placement/layout ownership, but refresh the
    /// generated visual, footprint and compiler-owned defaults.
    mutating func refreshCustomTrapPreviews(using catalog: [TextureCategory]) -> Int {
        let candidates = root.allDescendantsIncludingSelf().filter {
            $0.metadata.filename.lowercased().hasPrefix("v2trap_")
        }
        var refreshed = 0
        for snapshot in candidates {
            guard let transform = snapshot.transform else { continue }
            let objectName = snapshot.metadata.libraryObjectName.isEmpty ? snapshot.name : snapshot.metadata.libraryObjectName
            guard let asset = catalog.flatMap(\.assets).first(where: {
                $0.kind == .libraryObject &&
                URL(fileURLWithPath: $0.filePath).lastPathComponent.caseInsensitiveCompare(snapshot.metadata.filename) == .orderedSame &&
                ($0.libraryObjectName.isEmpty ? $0.name : $0.libraryObjectName).caseInsensitiveCompare(objectName) == .orderedSame
            }), var rebuilt = Vector2LibraryObjectBuilder.reconstruct(asset: asset, x: transform.x, y: transform.y) else {
                continue
            }

            rebuilt.transform?.rotation = transform.rotation
            let userControls = snapshot.metadata.libraryOverrides.filter { ["isDeadly", "EnableArea"].contains($0.key) }
            root.update(id: snapshot.id) { node in
                guard let rebuiltTransform = rebuilt.transform else { return }
                node.name = rebuilt.name
                node.kind = rebuilt.kind
                node.transform = rebuiltTransform
                node.previewPieces = rebuilt.previewPieces
                node.children = rebuilt.children
                node.metadata.sortingLayer = rebuilt.metadata.sortingLayer
                node.metadata.className = rebuilt.metadata.className
                node.metadata.imagePath = rebuilt.metadata.imagePath
                node.metadata.visualOffsetX = rebuilt.metadata.visualOffsetX
                node.metadata.visualOffsetY = rebuilt.metadata.visualOffsetY
                node.metadata.visualNativeWidth = rebuilt.metadata.visualNativeWidth
                node.metadata.visualNativeHeight = rebuilt.metadata.visualNativeHeight
                node.metadata.visualType = rebuilt.metadata.visualType
                node.metadata.libraryObjectName = rebuilt.metadata.libraryObjectName
                node.metadata.libraryOverrides = rebuilt.metadata.libraryOverrides.merging(userControls) { _, userValue in userValue }
            }
            refreshed += 1
        }
        return refreshed
    }
}
