//
//  TrapCatalog.swift
//  Vector2 level editor
//
//  Friendly trap definitions layered over Vector 2's tested library objects.
//  Stock and future custom traps intentionally share this small descriptor
//  shape so the placement UI does not need to be replaced later.
//

import SwiftUI
import Foundation

enum TrapFamily: String, CaseIterable, Identifiable {
    case beam = "Beams"
    case ball = "Ball hazards"
    case mine = "Mines"
    case run = "Run hazards"
    case custom = "Custom"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .beam: return "scope"
        case .ball: return "circle.dotted"
        case .mine: return "burst.fill"
        case .run: return "figure.run"
        case .custom: return "wand.and.stars"
        }
    }

    var tint: Color {
        switch self {
        case .beam: return .cyan
        case .ball: return .orange
        case .mine: return .red
        case .run: return .green
        case .custom: return .purple
        }
    }

    var hint: String {
        switch self {
        case .beam: return "Directional emitters"
        case .ball: return "Rolling and triple balls"
        case .mine: return "Jump-height mines"
        case .run: return "Laser, Tesla, flame and swarm"
        case .custom: return "Your compiled project traps"
        }
    }
}

struct TrapPreset: Identifiable, Equatable {
    enum Source: Equatable {
        case stockLibrary(filename: String, objectName: String)
        case customDefinition(id: String, filename: String)
    }

    let id: String
    let family: TrapFamily
    let title: String
    let subtitle: String
    let source: Source

    init(family: TrapFamily, title: String, subtitle: String, objectName: String, filename: String = "traps.xml") {
        self.id = "\(filename)/\(objectName)"
        self.family = family
        self.title = title
        self.subtitle = subtitle
        self.source = .stockLibrary(filename: filename, objectName: objectName)
    }

    init(customID: String, title: String, filename: String, objectName: String) {
        self.id = "\(filename)/\(objectName)"
        self.family = .custom
        self.title = title
        self.subtitle = "Project trap"
        self.source = .customDefinition(id: objectName, filename: filename)
    }

    var objectName: String {
        switch source {
        case let .stockLibrary(_, objectName): return objectName
        case let .customDefinition(id, _): return id
        }
    }

    var filename: String {
        switch source {
        case let .stockLibrary(filename, _): return filename
        case let .customDefinition(_, filename): return filename
        }
    }
}

struct TrapGuideRegion: Identifiable, Equatable {
    enum Kind: String {
        case danger
        case activation
    }

    let id: String
    let kind: Kind
    let offsetX: Int
    let offsetY: Int
    let width: Int
    let height: Int
}

enum TrapCatalog {
    static let presets: [TrapPreset] = [
        .init(family: .beam, title: "Mounted →", subtitle: "Shoots right", objectName: "BeamTrapMounted_LR"),
        .init(family: .beam, title: "Mounted ←", subtitle: "Shoots left", objectName: "BeamTrapMounted_RL"),
        .init(family: .beam, title: "Mounted ↓", subtitle: "Shoots down", objectName: "BeamTrapMounted_TD"),
        .init(family: .beam, title: "Mounted ↑", subtitle: "Shoots up", objectName: "BeamTrapMounted_DT"),
        .init(family: .beam, title: "Floating →", subtitle: "Free-standing emitter", objectName: "BeamTrapFloating_LR"),
        .init(family: .beam, title: "Floating ←", subtitle: "Free-standing emitter", objectName: "BeamTrapFloating_RL"),
        .init(family: .beam, title: "Floating ↓", subtitle: "Free-standing emitter", objectName: "BeamTrapFloating_TD"),
        .init(family: .beam, title: "Floating ↑", subtitle: "Free-standing emitter", objectName: "BeamTrapFloating_DT"),

        .init(family: .ball, title: "Rolling ball", subtitle: "Single launcher", objectName: "Blackball"),
        .init(family: .ball, title: "Triple ball", subtitle: "Three-ball launcher", objectName: "TripleBomb"),
        .init(family: .ball, title: "Short-jump ball", subtitle: "Ready-made short route", objectName: "Blackball_Shortjump"),
        .init(family: .ball, title: "Hurdle ball", subtitle: "Ready-made hurdle route", objectName: "Blackball_Hurdlejump"),

        .init(family: .mine, title: "Short-jump mine", subtitle: "Placed for a short jump", objectName: "Mine_Shortjump"),
        .init(family: .mine, title: "Hurdle mine", subtitle: "Placed for a hurdle jump", objectName: "Mine_Hurdlejump"),

        .init(family: .run, title: "Short laser", subtitle: "Short-jump laser", objectName: "Laser_Shortjump"),
        .init(family: .run, title: "Hurdle laser", subtitle: "Hurdle-height laser", objectName: "Laser_Hurdlejump"),
        .init(family: .run, title: "Short Tesla", subtitle: "Short-jump electricity", objectName: "Tesla_Shortjump"),
        .init(family: .run, title: "Hurdle Tesla", subtitle: "Hurdle-height electricity", objectName: "Tesla_Hurdlejump"),
        .init(family: .run, title: "Short echo", subtitle: "Short-jump echo hazard", objectName: "Echo_Shortjump"),
        .init(family: .run, title: "Hurdle echo", subtitle: "Hurdle-height echo hazard", objectName: "Echo_Hurdlejump"),
        .init(family: .run, title: "Short flame", subtitle: "Short-jump flame", objectName: "Flame_Shortjump"),
        .init(family: .run, title: "Hurdle flame", subtitle: "Hurdle-height flame", objectName: "Flame_Hurdlejump"),
        .init(family: .run, title: "Short swarm", subtitle: "Short-jump swarm strike", objectName: "Swarm_Shortjump"),
        .init(family: .run, title: "Hurdle swarm", subtitle: "Hurdle-height swarm strike", objectName: "Swarm_Hurdlejump")
    ]

    static func presets(in family: TrapFamily, catalog: [TextureCategory] = []) -> [TrapPreset] {
        if family == .custom { return customPresets(in: catalog) }
        return presets.filter { $0.family == family }
    }

    static func preset(for node: LevelNode?, catalog: [TextureCategory] = []) -> TrapPreset? {
        guard let node, isTrap(node) else { return nil }
        let name = node.metadata.libraryObjectName.isEmpty ? node.name : node.metadata.libraryObjectName
        return (presets + customPresets(in: catalog)).first { $0.objectName == name && $0.filename == node.metadata.filename }
    }

    static func isTrap(_ node: LevelNode?) -> Bool {
        guard let node else { return false }
        let filename = node.metadata.filename.lowercased()
        guard filename == "traps.xml" || filename == "custom_traps.xml" || filename.hasPrefix("v2trap_") else { return false }
        let name = node.metadata.libraryObjectName.isEmpty ? node.name : node.metadata.libraryObjectName
        return filename == "custom_traps.xml" || filename.hasPrefix("v2trap_") || presets.contains { $0.objectName == name }
    }

    static func asset(for preset: TrapPreset, in catalog: [TextureCategory]) -> TextureAsset? {
        let stock = catalog
            .flatMap(\.assets)
            .first {
                $0.kind == .libraryObject &&
                URL(fileURLWithPath: $0.filePath).lastPathComponent == preset.filename &&
                ($0.libraryObjectName.isEmpty ? $0.name : $0.libraryObjectName) == preset.objectName
            }
        guard var asset = stock else { return nil }
        if preset.filename.lowercased().hasPrefix("v2trap_") {
            return asset
        }
        asset.libraryOverrides = defaultOverrides(for: preset.objectName)
        return asset
    }

    private static func customPresets(in catalog: [TextureCategory]) -> [TrapPreset] {
        // Read manifests here. The cached asset catalogue can still contain
        // a trap after its package has been removed from the project.
        if let project = Vector2AssetCatalog.activeProjectRootURL() {
            return CustomTrapDefinition.load(from: project).map { trap in
                TrapPreset(
                    customID: trap.id,
                    title: trap.name,
                    filename: trap.libraryFilename,
                    objectName: trap.objectName
                )
            }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }

        // No active project: retain a live-file fallback for installed content.
        var seen = Set<String>()
        return catalog.flatMap(\.assets).compactMap { asset in
            guard asset.kind == .libraryObject else { return nil }
            let filename = URL(fileURLWithPath: asset.filePath).lastPathComponent
            guard filename.lowercased().hasPrefix("v2trap_") else { return nil }
            // The canvas asset catalogue is cached for speed. Deleted custom
            // libraries must not remain as ghost placement cards until restart.
            guard FileManager.default.fileExists(atPath: asset.filePath) else { return nil }
            let object = asset.libraryObjectName.isEmpty ? asset.name : asset.libraryObjectName
            // A cached TextureAsset can outlive an object that was replaced
            // inside a still-existing library file. Confirm the object itself
            // is present, then collapse duplicate project/game copies.
            guard let document = try? XMLDocument(contentsOf: URL(fileURLWithPath: asset.filePath)),
                  document.rootElement()?.elements(forName: "Objects").first?.elements(forName: "Object").contains(where: {
                      $0.attribute(forName: "Name")?.stringValue == object
                  }) == true else { return nil }
            let identity = "\(filename.lowercased())/\(object.lowercased())"
            guard seen.insert(identity).inserted else { return nil }
            let display = object.replacingOccurrences(of: "V2Trap_", with: "").replacingOccurrences(of: "_", with: " ").capitalized
            return TrapPreset(customID: object, title: display, filename: filename, objectName: object)
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    static func supports(_ key: String, node: LevelNode) -> Bool {
        let name = node.metadata.libraryObjectName.isEmpty ? node.name : node.metadata.libraryObjectName
        switch key {
        case "isDeadly": return isTrap(node)
        case "GlobalTimer":
            return name.contains("BeamTrap") || name.contains("Blackball") || name.contains("TripleBomb") ||
                name.contains("Laser_") || name.contains("Tesla_") || name.contains("Echo_") || name.contains("Flame_")
        case "EnableArea":
            return name.contains("Blackball") || name.contains("TripleBomb") || name.contains("Mine_") ||
                name.contains("Laser_") || name.contains("Tesla_") || name.contains("Echo_") || name.contains("Flame_")
        case "ToFly":
            return name.contains("Blackball") || name.contains("TripleBomb") || name.contains("Mine_") ||
                name.contains("Laser_") || name.contains("Tesla_") || name.contains("Echo_") || name.contains("Flame_")
        case "LaserReachDistance":
            return name.contains("BeamTrap") || name == "Laser_Hurdlejump" || name.contains("Tesla_") || name.contains("Echo_")
        case "Type": return name == "Blackball" || name == "TripleBomb"
        default: return false
        }
    }

    static func value(_ key: String, node: LevelNode) -> String {
        node.metadata.libraryOverrides[key] ?? defaultValue(key, objectName: node.metadata.libraryObjectName.isEmpty ? node.name : node.metadata.libraryObjectName)
    }

    static func defaultOverrides(for objectName: String) -> [String: String] {
        var result: [String: String] = ["isDeadly": "0"]
        for key in ["GlobalTimer", "EnableArea", "ToFly", "LaserReachDistance", "Type"] {
            let value = defaultValue(key, objectName: objectName)
            if !value.isEmpty { result[key] = value }
        }
        return result
    }

    static func guideRegions(for node: LevelNode) -> [TrapGuideRegion] {
        guard isTrap(node) else { return [] }
        let name = node.metadata.libraryObjectName.isEmpty ? node.name : node.metadata.libraryObjectName
        if node.metadata.filename.lowercased().hasPrefix("v2trap_") {
            let dangerX = integerValue("DangerX", node: node, fallback: -90)
            let dangerY = integerValue("DangerY", node: node, fallback: -180)
            let dangerWidth = max(10, integerValue("DangerWidth", node: node, fallback: 180))
            let dangerHeight = max(10, integerValue("DangerHeight", node: node, fallback: 180))
            var customRegions = [TrapGuideRegion(
                id: "danger", kind: .danger,
                offsetX: dangerX + dangerWidth / 2, offsetY: dangerY + dangerHeight / 2,
                width: dangerWidth, height: dangerHeight
            )]
            if value("EnableArea", node: node) != "0" {
                let activationX = integerValue("ActivationX", node: node, fallback: -260)
                let activationY = integerValue("ActivationY", node: node, fallback: -260)
                let activationWidth = max(10, integerValue("ActivationWidth", node: node, fallback: 520))
                let activationHeight = max(10, integerValue("ActivationHeight", node: node, fallback: 300))
                customRegions.insert(.init(
                    id: "activation", kind: .activation,
                    offsetX: activationX + activationWidth / 2, offsetY: activationY + activationHeight / 2,
                    width: activationWidth, height: activationHeight
                ), at: 0)
            }
            return customRegions
        }
        let triggerX = integerValue("TriggerActivatorX", node: node, fallback: -400)
        let triggerY = integerValue("TriggerActivatorY", node: node, fallback: -100)
        let triggerHeight = max(120, integerValue("TriggerActivatorH", node: node, fallback: 500))
        let activationWidth = max(240, integerValue("AreaWidth", node: node, fallback: 500))
        var regions: [TrapGuideRegion] = []

        if supports("EnableArea", node: node), value("EnableArea", node: node) != "0" {
            regions.append(.init(
                id: "activation",
                kind: .activation,
                offsetX: triggerX + activationWidth / 2,
                offsetY: triggerY + triggerHeight / 2,
                width: activationWidth,
                height: triggerHeight
            ))
        }

        if name.contains("BeamTrap") {
            let reach = max(60, integerValue("LaserReachDistance", node: node, fallback: 400))
            let direction = directionSuffix(in: name)
            let horizontal = direction == "LR" || direction == "RL"
            let offsetX = direction == "LR" ? reach / 2 : (direction == "RL" ? -reach / 2 : 0)
            let offsetY = direction == "TD" ? reach / 2 : (direction == "DT" ? -reach / 2 : 0)
            regions.append(.init(
                id: "danger",
                kind: .danger,
                offsetX: offsetX,
                offsetY: offsetY,
                width: horizontal ? reach : 54,
                height: horizontal ? 54 : reach
            ))
        } else {
            let width = name.contains("Hurdle") ? 300 : 220
            let height = name.contains("Hurdle") ? 420 : 240
            regions.append(.init(id: "danger", kind: .danger, offsetX: 0, offsetY: -height / 2, width: width, height: height))
        }
        return regions
    }

    private static func defaultValue(_ key: String, objectName: String) -> String {
        switch key {
        case "isDeadly": return "0"
        case "GlobalTimer": return objectName.contains("Swarm_") ? "" : "0"
        case "EnableArea":
            if objectName == "Blackball" || objectName == "TripleBomb" { return "0" }
            return objectName.contains("BeamTrap") || objectName.contains("Swarm_") ? "" : "1"
        case "ToFly":
            return objectName.contains("BeamTrap") || objectName.contains("Swarm_") ? "" : "0"
        case "LaserReachDistance":
            if objectName.contains("BeamTrap") { return "400" }
            if objectName == "Laser_Hurdlejump" { return "60" }
            if objectName.contains("Tesla_") || objectName.contains("Echo_") { return "10" }
            return ""
        case "Type": return (objectName == "Blackball" || objectName == "TripleBomb") ? "Low" : ""
        default: return ""
        }
    }

    private static func integerValue(_ key: String, node: LevelNode, fallback: Int) -> Int {
        Int(value(key, node: node)) ?? fallback
    }

    private static func directionSuffix(in objectName: String) -> String {
        ["LR", "RL", "TD", "DT"].first { objectName.hasSuffix("_\($0)") } ?? "LR"
    }
}

extension LevelDocument {
    mutating func updateTrapOverride(_ key: String, value: String) {
        guard let selectedNodeID, let node = root.find(id: selectedNodeID), TrapCatalog.isTrap(node) else { return }
        root.update(id: selectedNodeID) { trap in
            trap.metadata.libraryOverrides[key] = value
        }
    }
}
