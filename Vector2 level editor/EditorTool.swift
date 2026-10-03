//
//  EditorTool.swift
//  Vector2 level editor
//
//  Tool definitions for the left rail and toolbar.
//
//  This file is the shared contract for tool names, ordering and shortcuts.
//  Keep the tools in this order; the sidebar and shortcut list use it.
//

import SwiftUI
import AppKit
import Foundation

enum GameProfile: String, CaseIterable, Identifiable {
    case vector2 = "Vector 2"
    case vector1 = "Vector"

    var id: String { rawValue }
}

enum RightSidebarTab: String, CaseIterable {
    case hierarchy = "Hierarchy"
    case properties = "Properties"
    case xml = "Raw XML"
}

// MARK: - Top UI / Tools

/// Left-rail tools in display order.
///
/// The order is user-facing: number keys use the first nine tools, Q+scroll
/// cycles through this array, and the toolbar renders exactly this order.
enum EditorTool: String, CaseIterable, Identifiable {
    case cursor = "Select"
    case images = "Images"
    case backgrounds = "Backgrounds"
    case trapezoid = "Trapezoid"
    case collision = "Collision"
    case trigger = "Trigger"
    case area = "Area"
    case comment = "Comment"
    case coin = "Coins"
    case camera = "Camera"
    case mask = "Mask"
    case objectRef = "Object Ref"
    case object = "Object"
    case dynamic = "Dynamic"
    case playerIn = "IN"
    case playerOut = "OUT"
    case runFast = "RunFast"
    case swarm = "S"
    case waypoint = "W"

    static let allCases: [EditorTool] = [
        .cursor,
        .images,
        .backgrounds,
        .trapezoid,
        .collision,
        .trigger,
        .area,
        .coin,
        .camera,
        .comment,
        .objectRef,
        .object,
        .dynamic,
        .playerIn,
        .playerOut,
        .runFast,
        .swarm,
        .waypoint
    ]

    var id: String { rawValue }

    static func tool(forNumberKey key: String) -> EditorTool? {
        guard let number = Int(key), number > 0 else { return nil }
        let tools = Array(allCases.prefix(9))
        return tools.indices.contains(number - 1) ? tools[number - 1] : nil
    }

    func cycled(by direction: Int) -> EditorTool {
        guard let index = Self.allCases.firstIndex(of: self), !Self.allCases.isEmpty else {
            return self
        }
        let count = Self.allCases.count
        let next = (index + direction + count) % count
        return Self.allCases[next]
    }

    /// True when clicking empty canvas can create a built-in primitive.
    /// Asset tools return false because they need the asset browser selection.
    var canPlaceDirectlyOnCanvas: Bool {
        switch self {
        case .cursor, .images, .backgrounds, .mask, .objectRef, .object:
            return false
        default:
            return true
        }
    }

    func canPlace(asset: TextureAsset) -> Bool {
        switch (self, asset.kind) {
        case (.images, .texture), (.backgrounds, .texture):
            return true
        case (.camera, .libraryObject), (.camera, .prefab):
            return asset.isCameraRelated
        case (.objectRef, .libraryObject), (.object, .libraryObject), (.objectRef, .prefab), (.object, .prefab):
            return true
        default:
            return false
        }
    }
}

/// Icon toolbar commands. Keep command identity separate from button UI so menu,
/// shortcuts, and toolbar can all call the same dispatcher.
enum ToolbarAction: String, CaseIterable, Identifiable {
    case new = "New"
    case open = "Open"
    case importXML = "Import"
    case save = "Save"
    case export = "Export"
    case copy = "Copy"
    case flipHorizontal = "Flip H"
    case flipVertical = "Flip V"
    case delete = "Delete"
    case play = "Play"
    case trickPreview = "Trick"
    case refresh = "Refresh"
    case undo = "Undo"
    case redo = "Redo"
    case browser = "Browser"
    case settings = "Settings"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .new: "doc.badge.plus"
        case .open: "folder"
        case .importXML: "square.and.arrow.down"
        case .save: "square.and.arrow.down.on.square"
        case .export: "square.and.arrow.up"
        case .copy: "doc.on.doc"
        case .flipHorizontal: "arrow.left.and.right"
        case .flipVertical: "arrow.up.and.down"
        case .delete: "trash"
        case .play: "play.fill"
        case .trickPreview: "figure.run"
        case .refresh: "arrow.clockwise"
        case .undo: "arrow.uturn.backward"
        case .redo: "arrow.uturn.forward"
        case .browser: "square.grid.2x2"
        case .settings: "gearshape"
        }
    }
}

/// Lightweight app menu row.
///
/// It is SwiftUI, not the macOS menu bar, because the app uses a custom compact
/// top strip used throughout the editor. The File menu delegates to the
/// same toolbar command dispatcher so behavior stays consistent.
