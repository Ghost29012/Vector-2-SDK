//
//  Vector2ReferenceVisualBuilder.swift
//  Vector2 level editor
//
//  Makes ObjectReference nodes visible without changing their XML identity.
//
//  ObjectReference is basically "spawn this thing from another file" in Vector 2.
//  The editor still needs a preview, so this bridge chooses between library XML,
//  prefab reconstruction, stunt/bonus special cases, and fallback visuals while
//  keeping export pointed at the original reference.
//

import SwiftUI
import AppKit
import Foundation

enum Vector2ReferenceVisualBuilder {
    static func reconstruct(
        from element: XMLElement,
        factor: String,
        x: Int,
        y: Int,
        baseURL: URL,
        rotation: Double = 0,
        choices: [String: String] = [:]
    ) -> LevelNode? {
        // The XML identity is preserved no matter which visual path wins below.
        guard let name = attribute("Name", on: element) else {
            RoomWeaverDiagnostics.shared.referenceVisualFailed(
                name: "-",
                filename: "-",
                reason: "ObjectReference is missing Name"
            )
            return nil
        }
        guard let filename = referenceFilename(for: name, element: element, baseURL: baseURL) else {
            RoomWeaverDiagnostics.shared.referenceVisualFailed(
                name: name,
                filename: "-",
                reason: "could not infer Filename/library file"
            )
            return nil
        }

        let libraryNode = Vector2LibraryObjectBuilder.reconstructReference(
            name: name,
            filename: filename,
            originX: x,
            originY: y,
            baseURL: baseURL,
            settings: element,
            rotation: rotation,
            choices: choices
        )

        if shouldPreferLibraryVisual(name: name, filename: filename),
           var libraryNode,
           hasDrawableLibraryVisual(libraryNode) {
            // RoomWeaver should follow the game loader: XML ObjectReference nodes
            // resolve through the libraries first. Prefabs are only a fallback for
            // truly prefab-only or visual-empty objects.
            libraryNode.name = name
            libraryNode.factor = factor
            libraryNode.xml = .init(template: "ObjectReference", choice: filename, variant: "Resolved")
            libraryNode.metadata.filename = filename
            libraryNode.metadata.className = name
            RoomWeaverDiagnostics.shared.referenceVisualPath(
                name: name,
                filename: filename,
                path: "XML library"
            )
            return libraryNode
        } else if shouldPreferLibraryVisual(name: name, filename: filename),
                  libraryNode != nil {
            RoomWeaverDiagnostics.shared.referenceVisualFailed(
                name: name,
                filename: filename,
                reason: "XML library resolved but has no drawable sprites; trying prefab fallback"
            )
        } else if shouldPreferLibraryVisual(name: name, filename: filename) {
            RoomWeaverDiagnostics.shared.referenceVisualFailed(
                name: name,
                filename: filename,
                reason: "XML library preferred but reconstruction returned nil"
            )
        }

        if let prefabAsset = editorPrefabAsset(forName: name, filename: filename),
           var prefabNode = UnityPrefabObjectBuilder.reconstruct(asset: prefabAsset, x: x, y: y) {
            prefabNode.name = name
            prefabNode.factor = factor
            prefabNode.xml = .init(template: "ObjectReference", choice: filename, variant: "Prefab")
            prefabNode.metadata.filename = filename
            prefabNode.metadata.className = name
            prefabNode.transform?.rotation = rotation
            if prefabNode.children.isEmpty,
               let libraryNode,
               !libraryNode.children.isEmpty {
                prefabNode.children = libraryNode.children
            }
            if prefabNode.previewPieces.isEmpty,
               let libraryNode,
               !libraryNode.previewPieces.isEmpty {
                prefabNode.previewPieces = libraryNode.previewPieces
                prefabNode.metadata.visualOffsetX = libraryNode.metadata.visualOffsetX
                prefabNode.metadata.visualOffsetY = libraryNode.metadata.visualOffsetY
                prefabNode.metadata.visualNativeWidth = libraryNode.metadata.visualNativeWidth
                prefabNode.metadata.visualNativeHeight = libraryNode.metadata.visualNativeHeight
                if prefabNode.metadata.imagePath.isEmpty {
                    prefabNode.metadata.imagePath = libraryNode.metadata.imagePath
                }
            }
            RoomWeaverDiagnostics.shared.referenceVisualPath(
                name: name,
                filename: filename,
                path: "Unity prefab fallback"
            )
            return prefabNode
        }

        if var libraryNode {
            libraryNode.name = name
            libraryNode.factor = factor
            libraryNode.xml = .init(template: "ObjectReference", choice: filename, variant: "Resolved")
            libraryNode.metadata.filename = filename
            libraryNode.metadata.className = name
            RoomWeaverDiagnostics.shared.referenceVisualPath(
                name: name,
                filename: filename,
                path: "XML library fallback"
            )
            return libraryNode
        }

        RoomWeaverDiagnostics.shared.referenceVisualFailed(
            name: name,
            filename: filename,
            reason: "no XML visual and no prefab fallback"
        )
        return nil
    }

    private static func shouldPreferLibraryVisual(name: String, filename: String) -> Bool {
        filename.lowercased().hasSuffix(".xml") ||
            (name.caseInsensitiveCompare("Stunt") == .orderedSame &&
             filename.caseInsensitiveCompare("triggers.xml") == .orderedSame)
    }

    private static func hasDrawableLibraryVisual(_ node: LevelNode) -> Bool {
        if !node.metadata.imagePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        if node.previewPieces.contains(where: { !$0.imagePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return true
        }
        return node.children.contains { hasDrawableLibraryVisual($0) }
    }

    private static func referenceFilename(for name: String, element: XMLElement, baseURL: URL) -> String? {
        if let filename = attribute("Filename", on: element), !filename.isEmpty {
            return filename
        }
        return Vector2AssetCatalog.libraryFilename(
            containingObjectNamed: name,
            preferredNear: baseURL.lastPathComponent
        )
    }

    private static func editorPrefabAsset(forName name: String, filename: String) -> TextureAsset? {
        // Resolve prefab references from either a direct Filename ending in
        // .prefab or a best-effort category/name lookup in the asset catalog.
        if filename.lowercased().hasSuffix(".prefab") {
            let encodedStem = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
            if let exactPrefab = Vector2AssetCatalog.editorPrefabAsset(encodedStem: encodedStem) {
                return exactPrefab
            }
        }

        if let exact = Vector2AssetCatalog.editorPrefabAsset(named: name) {
            return exact
        }

        let lowercased = filename.lowercased()
        let categoryHint: String?
        if lowercased.contains("trigger") || lowercased.contains("swarm") {
            categoryHint = "Triggers"
        } else if lowercased.contains("trap") || lowercased.contains("laser") {
            categoryHint = "Traps"
        } else if lowercased.contains("obstacle") || lowercased.contains("door") {
            categoryHint = "Obstacles"
        } else if lowercased.contains("bonus") || lowercased.contains("object") {
            categoryHint = "Objects"
        } else if lowercased.contains("shadow") {
            categoryHint = "Shadow"
        } else {
            categoryHint = nil
        }

        return Vector2AssetCatalog.editorPrefabAsset(named: name, categoryContaining: categoryHint)
    }

    private static func attribute(_ name: String, on element: XMLElement) -> String? {
        element.attribute(forName: name)?.stringValue
    }
}
