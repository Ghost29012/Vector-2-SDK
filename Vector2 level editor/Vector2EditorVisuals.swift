//
//  Vector2EditorVisuals.swift
//  Vector2 level editor
//
//  Generated editor-only visuals.
//
//  Some things are XML concepts first and art second: spawn markers, trapezoid
//  previews, and little helper textures. This file creates visuals that make
//  editing readable without adding fake gameplay data to exported rooms.
//

import SwiftUI
import AppKit
import Foundation

enum Vector2SpawnPrefabVisual {
    static func node(for kind: LevelNode.Kind, x: Int, y: Int) -> LevelNode {
        // Creates the actual spawn node placed on canvas.
        let prefabName = kind == .gateOut ? "Out" : "In"
        let template = kind == .gateOut ? "SpawnOut" : "SpawnIn"
        let filename = kind == .gateOut ? "Objects__Objects Vec2__Out.prefab" : "Objects__Objects Vec2__In.prefab"
        return LevelNode(
            name: prefabName,
            kind: kind,
            factor: "1",
            transform: .init(x: x, y: y, width: 72, height: 72),
            xml: .init(template: template, choice: "Player", variant: "Default"),
            metadata: .init(
                sortingLayer: "Default",
                tag: kind.defaultTag,
                filename: filename,
                className: prefabName,
                imagePath: ""
            )
        )
    }

    static func metadata(for kind: LevelNode.Kind) -> LevelNode.Metadata {
        // Metadata-only helper used when an existing spawn node needs refreshed
        // visual/export identity without rebuilding the whole node.
        let prefabName = kind == .gateOut ? "Out" : "In"
        return .init(
            tag: kind.defaultTag,
            filename: kind == .gateOut ? "Objects__Objects Vec2__Out.prefab" : "Objects__Objects Vec2__In.prefab",
            className: prefabName,
            imagePath: ""
        )
    }

    private static func textureBankFallbackNode(
        for kind: LevelNode.Kind,
        x: Int,
        y: Int,
        template: String,
        filename: String
    ) -> LevelNode {
        // Procedural fallback art if the real spawn assets are unavailable.
        // This keeps public builds usable even when the user has not imported
        // the full Unity project assets.
        let isOut = kind == .gateOut
        let prefabName = isOut ? "Out" : "In"
        let accentPath = Vector2AssetCatalog.imagePath(forClassName: "walls.pw_decal_light_down")
            ?? Vector2AssetCatalog.imagePath(forClassName: "walls.pw_decal_edge_down")
        let bodyPath = Vector2AssetCatalog.imagePath(forClassName: "walls.pw_decal_big_down")
            ?? Vector2AssetCatalog.imagePath(forClassName: "walls.pw_decal_edge_down")
            ?? ""
        let edgePath = Vector2AssetCatalog.imagePath(forClassName: "walls.pw_decal_edge_down") ?? bodyPath

        let width = 260
        let height = 320
        let direction: Double = isOut ? 1 : -1
        let pieces = [
            LevelNode.PreviewPiece(
                imagePath: bodyPath,
                centerX: 0,
                centerY: 26,
                width: 220,
                height: 156,
                rotation: 90 * direction
            ),
            LevelNode.PreviewPiece(
                imagePath: edgePath,
                centerX: -52 * direction,
                centerY: -72,
                width: 132,
                height: 72,
                rotation: 0
            ),
            LevelNode.PreviewPiece(
                imagePath: accentPath ?? bodyPath,
                centerX: 78 * direction,
                centerY: -74,
                width: 82,
                height: 42,
                rotation: 0
            )
        ].filter { !$0.imagePath.isEmpty }

        return LevelNode(
            name: prefabName,
            kind: kind,
            factor: "1",
            transform: .init(x: x, y: y, width: width, height: height),
            xml: .init(template: template, choice: "Player", variant: "Default"),
            metadata: .init(
                sortingLayer: "Default",
                tag: kind.defaultTag,
                filename: filename,
                className: prefabName,
                imagePath: ""
            ),
            previewPieces: pieces
        )
    }
}

/// Chooses the best visual reconstruction path for imported ObjectReference XML.
///
/// The game only needs name/filename/position, but the editor needs something
/// visible/selectable. We first build a library-derived visual, then prefer an
/// editor prefab visual when one exists because prefabs usually match the Unity
/// scene art more closely. If the prefab has missing pieces, we borrow children
/// from the library visual as a fallback.

enum Vector2EditorVisuals {
    // Small built-in visual helpers for editor-only assets such as trapezoid
    // slope previews and spawn markers. These are not authoritative game data.
    enum TrapezoidStyle {
        case left
        case right
    }

    private static var bundledVector2AssetsRoot: URL {
        // Resolves relative to this Swift file so no user-specific hardcoded path
        // leaks into public builds.
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("ProjectAssets")
            .appendingPathComponent("Vector2")
    }

    static func trapezoidTexturePath(style: TrapezoidStyle) -> String? {
        // Finds the bundled trapezoid preview image. Type 1 and Type 2 share the
        // same export schema idea but need different editor art.
        let fileManager = FileManager.default
        let assetName = style == .left ? "EditorTrapezoidType1" : "EditorTrapezoidType2"
        if NSImage(named: assetName) != nil {
            return "asset://\(assetName)"
        }
        let fileName = style == .left ? "trapezoid_type1.png" : "trapezoid_type2.png"
        var candidates: [String] = [
            bundledVector2AssetsRoot
                .appendingPathComponent("TextureBank")
                .appendingPathComponent("editor_prefab__\(fileName)")
                .path,
            bundledVector2AssetsRoot
                .appendingPathComponent("TextureBank")
                .appendingPathComponent(fileName)
                .path
        ]
        if let bundled = Bundle.main.resourceURL?
                .appendingPathComponent("ProjectAssets")
                .appendingPathComponent("Vector2")
                .appendingPathComponent("TextureBank")
                .appendingPathComponent("editor_prefab__\(fileName)")
                .path {
            candidates.append(bundled)
        }
        for candidate in candidates where fileManager.fileExists(atPath: candidate) {
            return candidate
        }
        return nil
    }

    static func spawnTexturePath(isOut: Bool) -> String {
        // Generates a tiny cached spawn icon. This is editor art only, not a
        // runtime texture dependency.
        let fileName = isOut ? "vector2_spawn_out_visual_v3.png" : "vector2_spawn_in_visual_v3.png"
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: outputURL.path) {
            return outputURL.path
        }

        let size = NSSize(width: 192, height: 192)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: size).fill()

        let accent = isOut
            ? NSColor(calibratedRed: 0.08, green: 0.36, blue: 0.95, alpha: 1)
            : NSColor(calibratedRed: 0.08, green: 0.58, blue: 0.20, alpha: 1)
        let fill = accent.withAlphaComponent(0.14)
        let playerBounds = NSRect(x: 58, y: 24, width: 76, height: 138)

        fill.setFill()
        NSBezierPath(roundedRect: playerBounds, xRadius: 18, yRadius: 18).fill()
        accent.setStroke()
        let boundsPath = NSBezierPath(roundedRect: playerBounds, xRadius: 18, yRadius: 18)
        boundsPath.lineWidth = 5
        boundsPath.stroke()

        let ground = NSBezierPath()
        ground.move(to: NSPoint(x: 38, y: 26))
        ground.line(to: NSPoint(x: 154, y: 26))
        accent.withAlphaComponent(0.8).setStroke()
        ground.lineWidth = 6
        ground.lineCapStyle = .round
        ground.stroke()

        let centerLine = NSBezierPath()
        centerLine.move(to: NSPoint(x: 96, y: 24))
        centerLine.line(to: NSPoint(x: 96, y: 162))
        accent.withAlphaComponent(0.32).setStroke()
        centerLine.lineWidth = 2
        centerLine.stroke()

        let spawnDot = NSBezierPath(ovalIn: NSRect(x: 86, y: 16, width: 20, height: 20))
        NSColor.white.setFill()
        spawnDot.fill()
        accent.setStroke()
        spawnDot.lineWidth = 4
        spawnDot.stroke()

        let arrow = NSBezierPath()
        if isOut {
            arrow.move(to: NSPoint(x: 38, y: 170))
            arrow.line(to: NSPoint(x: 142, y: 170))
            arrow.move(to: NSPoint(x: 118, y: 188))
            arrow.line(to: NSPoint(x: 148, y: 170))
            arrow.line(to: NSPoint(x: 118, y: 152))
        } else {
            arrow.move(to: NSPoint(x: 154, y: 170))
            arrow.line(to: NSPoint(x: 50, y: 170))
            arrow.move(to: NSPoint(x: 74, y: 188))
            arrow.line(to: NSPoint(x: 44, y: 170))
            arrow.line(to: NSPoint(x: 74, y: 152))
        }
        accent.setStroke()
        arrow.lineWidth = 12
        arrow.lineCapStyle = .round
        arrow.lineJoinStyle = .round
        arrow.stroke()

        let text = isOut ? "OUT" : "IN"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 24),
            .foregroundColor: accent
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        attributed.draw(at: NSPoint(x: isOut ? 72 : 82, y: 2))

        image.unlockFocus()
        if let tiff = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff),
           let data = bitmap.representation(using: .png, properties: [:]) {
            try? data.write(to: outputURL)
        }
        return outputURL.path
    }
}
