//
//  UnityPrefabObjectBuilder.swift
//  Vector2 level editor
//
//  Unity prefab YAML -> editor preview pieces.
//
//  We do not run Unity here. We parse just enough prefab YAML to find transforms,
//  sprite renderers, nested prefab instances, sorting, and sprite GUIDs, then
//  bake that into preview nodes. This is preview-only; the XML export should
//  still preserve the original library/prefab reference.
//

import SwiftUI
import AppKit
import Foundation

enum UnityPrefabObjectBuilder {
    // Only the prefab YAML fields needed to build the editor preview.
    private struct GameObjectData {
        let name: String
        let tag: String
        let isActive: Bool
    }

    private struct TransformData {
        let id: String
        let gameObjectID: String
        let parentTransformID: String
        let localX: Double
        let localY: Double
        let scaleX: Double
        let scaleY: Double
        let rotationX: Double
        let rotationY: Double
        let rotationZ: Double
        let rotationW: Double
        let rotation: Double
    }

    private struct RendererData {
        let gameObjectID: String
        let spriteGUID: String
        let spriteFileID: String
        let sizeX: Double
        let sizeY: Double
        let sortingOrder: Int
    }

    private struct WorldTransform {
        let x: Double
        let y: Double
        let basisXX: Double
        let basisXY: Double
        let basisYX: Double
        let basisYY: Double

        static let identity = WorldTransform(
            x: 0,
            y: 0,
            basisXX: 1,
            basisXY: 0,
            basisYX: 0,
            basisYY: 1
        )
    }

    private struct SpritePiece {
        let name: String
        let imagePath: String
        let x: Int
        let y: Int
        let width: Int
        let height: Int
        let rotation: Double
        let sortingLayer: String
        let className: String
    }

    private struct PrefabInstanceData {
        let id: String
        let parentTransformID: String
        let sourcePrefabGUID: String
        let propertyValuesByTargetID: [String: [String: String]]
    }

    private struct ParsedPrefab {
        let gameObjects: [String: GameObjectData]
        let transforms: [String: TransformData]
        let renderers: [RendererData]
        let prefabInstances: [PrefabInstanceData]
        let rootTransformID: String?
    }

    private static var parsedPrefabCache: [String: ParsedPrefab] = [:]
    private static var localPieceCache: [String: [SpritePiece]] = [:]

    /// Converts a prefab asset browser card into a `LevelNode` with image pieces.
    /// The export path still keeps the object reference; this is visual/editor
    /// fidelity only.
    static func reconstruct(asset: TextureAsset, x: Int, y: Int, includeInactiveVisuals: Bool = false) -> LevelNode? {
        let localPieces = localSpritePieces(
            forPrefabAt: asset.filePath,
            defaultLayer: asset.defaultLayer,
            includeInactiveVisuals: includeInactiveVisuals,
            depth: 0
        )
        let spritePieces = translate(localPieces, x: x, y: y)
        guard !spritePieces.isEmpty else {
            return phantomFallback(for: asset, x: x, y: y)
        }
        let bounds = boundingBox(for: spritePieces)
        if isUnhelpfulPrefabPreview(bounds: bounds),
           let phantom = phantomFallback(for: asset, x: x, y: y) {
            return phantom
        }
        let previewPath = rasterizedPreviewPath(for: asset, pieces: spritePieces, bounds: bounds)
        let children = spritePieces.map { piece in
            LevelNode(
                name: piece.name,
                kind: .image,
                factor: "1",
                transform: .init(x: piece.x, y: piece.y, width: piece.width, height: piece.height, rotation: piece.rotation),
                xml: .init(template: "Image", choice: asset.category, variant: "Prefab"),
                metadata: .init(
                    sortingLayer: piece.sortingLayer,
                    tag: LevelNode.Kind.image.defaultTag,
                    filename: URL(fileURLWithPath: asset.filePath).lastPathComponent,
                    className: piece.className,
                    imagePath: piece.imagePath
                )
            )
        }
        return LevelNode(
            name: asset.name,
            kind: .objectReference,
            factor: "1",
            transform: .init(x: x, y: y, width: bounds.width, height: bounds.height),
            xml: .init(template: "EditorPrefab", choice: asset.category, variant: "Visual"),
            metadata: .init(
                sortingLayer: asset.defaultLayer,
                tag: LevelNode.Kind.objectReference.defaultTag,
                filename: URL(fileURLWithPath: asset.filePath).lastPathComponent,
                className: asset.className,
                imagePath: previewPath ?? "",
                visualOffsetX: bounds.centerX - x,
                visualOffsetY: bounds.centerY - y,
                visualNativeWidth: bounds.width,
                visualNativeHeight: bounds.height
            ),
            previewPieces: spritePieces.map { piece in
                LevelNode.PreviewPiece(
                    imagePath: piece.imagePath,
                    centerX: Double(piece.x - bounds.centerX),
                    centerY: Double(piece.y - bounds.centerY),
                    width: Double(piece.width),
                    height: Double(piece.height),
                    rotation: piece.rotation
                )
            },
            children: children
        )
    }

    private static func phantomFallback(for asset: TextureAsset, x: Int, y: Int) -> LevelNode? {
        // If a prefab cannot produce useful sprite pieces, fall back to the
        // matching phantoms.xml visual. This keeps advanced objects visible even
        // when Unity prefab YAML is missing/too custom to parse.
        for phantomName in phantomCandidates(for: asset.name) {
            guard var node = Vector2LibraryObjectBuilder.reconstructReference(
                name: phantomName,
                filename: "phantoms.xml",
                originX: x,
                originY: y,
                baseURL: URL(fileURLWithPath: asset.filePath),
                settings: nil
            ) else {
                continue
            }

            node.name = asset.name
            node.kind = .objectReference
            node.xml = .init(template: "EditorPrefabPhantom", choice: asset.category, variant: phantomName)
            node.metadata.filename = URL(fileURLWithPath: asset.filePath).lastPathComponent
            node.metadata.className = asset.className
            node.metadata.tag = LevelNode.Kind.objectReference.defaultTag
            return node
        }

        return nil
    }

    private static func isUnhelpfulPrefabPreview(bounds: (centerX: Int, centerY: Int, width: Int, height: Int)) -> Bool {
        // Tiny previews are usually "we parsed only a helper sprite", not a real
        // object. Falling back avoids blank/green placeholder assets.
        bounds.width < 48 || bounds.height < 48
    }

    private static func phantomCandidates(for name: String) -> [String] {
        // Same alias idea as the library builder, but tuned for prefab names.
        // Example: BeamTrapMounted -> BeamMounted in phantoms.xml.
        let baseName = name
            .replacingOccurrences(of: #" \([^)]*\)"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var candidates: [String] = []

        if name.localizedCaseInsensitiveContains("Blackball") {
            if name.localizedCaseInsensitiveContains("High") {
                candidates.append("High")
            } else if name.localizedCaseInsensitiveContains("Medium") {
                candidates.append("Medium")
            } else if name.localizedCaseInsensitiveContains("Low") {
                candidates.append("Low")
            } else if name.localizedCaseInsensitiveContains("Hurdle") {
                candidates.append("Ball_hurdle")
            } else if name.localizedCaseInsensitiveContains("Short") {
                candidates.append("Ball_short")
            }
        }

        if baseName.localizedCaseInsensitiveContains("BeamTrapFloating") {
            candidates.append("BeamFloating")
        }
        if baseName.localizedCaseInsensitiveContains("BeamTrapMounted") {
            candidates.append("BeamMounted")
        }

        let withoutDirection = baseName.replacingOccurrences(
            of: #"_(LR|RL|TD|DT)$"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        candidates.append(contentsOf: [baseName, withoutDirection])

        var seen: Set<String> = []
        return candidates.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private static func localSpritePieces(forPrefabAt path: String, defaultLayer: String, includeInactiveVisuals: Bool, depth: Int) -> [SpritePiece] {
        // Parses one prefab and returns sprite pieces in local prefab space.
        // Nested prefabs are followed recursively with a depth cap to avoid
        // cycles or huge Unity asset graphs freezing the editor.
        guard depth < 5 else { return [] }
        let cacheKey = "\(path)#\(defaultLayer)#inactive:\(includeInactiveVisuals)"
        if let cached = localPieceCache[cacheKey] {
            return cached
        }

        guard let parsed = parsedPrefab(at: path) else {
            return []
        }

        var worldCache: [String: WorldTransform] = [:]
        let transformIDByGameObject = Dictionary(uniqueKeysWithValues: parsed.transforms.values.map { ($0.gameObjectID, $0.id) })

        // SpriteRenderer sections become visual pieces. We intentionally sort by
        // Unity sorting order so editor layering matches the game more closely.
        var pieces: [SpritePiece] = parsed.renderers
            .filter { includeInactiveVisuals || parsed.gameObjects[$0.gameObjectID]?.isActive != false }
            .sorted { lhs, rhs in
                if lhs.sortingOrder == rhs.sortingOrder {
                    return lhs.gameObjectID < rhs.gameObjectID
                }
                return lhs.sortingOrder < rhs.sortingOrder
            }
            .prefix(256)
            .compactMap { renderer in
                guard let transformID = transformIDByGameObject[renderer.gameObjectID],
                      let world = worldTransform(
                        for: transformID,
                        transforms: parsed.transforms,
                        cache: &worldCache
                      ),
                      let imagePath = Vector2AssetCatalog.imagePath(
                        forSpriteGUID: renderer.spriteGUID,
                        fileID: renderer.spriteFileID
                      )
                else {
                    return nil
                }

                let nativeSize = CachedImageStore.shared.image(at: imagePath).map { image in
                    CGSize(width: max(1, image.size.width), height: max(1, image.size.height))
                } ?? .zero
                let widthScale = hypot(world.basisXX, world.basisXY)
                let heightScale = hypot(world.basisYX, world.basisYY)
                let width = max(8, Int(((renderer.sizeX > 0 ? renderer.sizeX : nativeSize.width / 100) * widthScale * 100).rounded()))
                let height = max(8, Int(((renderer.sizeY > 0 ? renderer.sizeY : nativeSize.height / 100) * heightScale * 100).rounded()))
                let className = Vector2AssetCatalog.className(forSpriteGUID: renderer.spriteGUID, fileID: renderer.spriteFileID)
                    ?? URL(fileURLWithPath: imagePath).deletingPathExtension().lastPathComponent

                return SpritePiece(
                    name: className,
                    imagePath: imagePath,
                    x: Int((world.x * 100).rounded()),
                    y: -Int((world.y * 100).rounded()),
                    width: width,
                    height: height,
                    rotation: -atan2(world.basisXY, world.basisXX) * 180 / .pi,
                    sortingLayer: defaultLayer,
                    className: className
                )
            }

        if !parsed.prefabInstances.isEmpty {
            // Unity prefabs can nest other prefabs through PrefabInstance
            // sections. We resolve the referenced prefab, apply property
            // overrides, and compose it into this prefab's local transform.
            for instance in parsed.prefabInstances {
                guard let sourceURL = Vector2AssetCatalog.prefabURL(forGUID: instance.sourcePrefabGUID) else {
                    continue
                }
                let sourceLayer = Vector2AssetCatalog.defaultLayerName(forPrefabAt: sourceURL)
                let sourcePieces = localSpritePieces(
                    forPrefabAt: sourceURL.path,
                    defaultLayer: sourceLayer,
                    includeInactiveVisuals: includeInactiveVisuals,
                    depth: depth + 1
                )
                guard !sourcePieces.isEmpty else { continue }

                let sourceParsed = parsedPrefab(at: sourceURL.path)
                guard instanceIsActive(instance, sourceParsed: sourceParsed) else {
                    continue
                }

                let parentWorld: WorldTransform
                if instance.parentTransformID == "0" {
                    parentWorld = .identity
                } else {
                    parentWorld = worldTransform(
                        for: instance.parentTransformID,
                        transforms: parsed.transforms,
                        cache: &worldCache
                    ) ?? .identity
                }

                let delta = deltaTransform(
                    for: instance,
                    sourceParsed: sourceParsed
                )
                let combined = combine(parent: parentWorld, local: delta)
                pieces.append(contentsOf: sourcePieces.map { transform($0, by: combined) })
            }
        }

        localPieceCache[cacheKey] = pieces
        return pieces
    }

    private static func parsedPrefab(at path: String) -> ParsedPrefab? {
        // Cached YAML parse. Prefabs are shared by many browser cards/imported
        // nodes, so reparsing every frame would be cooked.
        if let cached = parsedPrefabCache[path] {
            return cached
        }
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            return nil
        }
        let parsed = parsePrefab(text)
        parsedPrefabCache[path] = parsed
        return parsed
    }

    private static func parsePrefab(_ text: String) -> ParsedPrefab {
        // Minimal Unity YAML parser. It extracts just enough from GameObject,
        // Transform, SpriteRenderer, PrefabInstance, and Prefab sections to draw
        // an editor preview. Do not put gameplay assumptions here.
        var gameObjects: [String: GameObjectData] = [:]
        var transforms: [String: TransformData] = [:]
        var renderers: [RendererData] = []
        var prefabInstances: [PrefabInstanceData] = []
        var explicitRootGameObjectID: String?

        for section in prefabSections(text) {
            if hasUnitySection("GameObject", in: section.body) {
                gameObjects[section.id] = GameObjectData(
                    name: lineValue("m_Name", in: section.body) ?? section.id,
                    tag: lineValue("m_TagString", in: section.body) ?? "Untagged",
                    isActive: lineValue("m_IsActive", in: section.body) != "0"
                )
            } else if hasUnitySection("Transform", in: section.body) || hasUnitySection("RectTransform", in: section.body) {
                guard let gameObjectID = fileIDValue("m_GameObject", in: section.body) else { continue }
                let rotationValues = lineMap("m_LocalRotation", in: section.body)
                let rotation = quaternionZRotation(rotationValues)
                let position = lineMap("m_LocalPosition", in: section.body)
                let scale = lineMap("m_LocalScale", in: section.body)
                transforms[section.id] = TransformData(
                    id: section.id,
                    gameObjectID: gameObjectID,
                    parentTransformID: fileIDValue("m_Father", in: section.body) ?? "0",
                    localX: position["x"] ?? 0,
                    localY: position["y"] ?? 0,
                    scaleX: scale["x"] ?? 1,
                    scaleY: scale["y"] ?? 1,
                    rotationX: rotationValues["x"] ?? 0,
                    rotationY: rotationValues["y"] ?? 0,
                    rotationZ: rotationValues["z"] ?? 0,
                    rotationW: rotationValues["w"] ?? 1,
                    rotation: rotation
                )
            } else if hasUnitySection("SpriteRenderer", in: section.body) {
                guard let gameObjectID = fileIDValue("m_GameObject", in: section.body),
                      lineValue("m_Enabled", in: section.body) != "0",
                      let guid = guidValue("m_Sprite", in: section.body),
                      let fileID = fileIDValue("m_Sprite", in: section.body) else { continue }
                let size = lineMap("m_Size", in: section.body)
                renderers.append(RendererData(
                    gameObjectID: gameObjectID,
                    spriteGUID: guid,
                    spriteFileID: fileID,
                    sizeX: size["x"] ?? 0,
                    sizeY: size["y"] ?? 0,
                    sortingOrder: Int(lineValue("m_SortingOrder", in: section.body) ?? "0") ?? 0
                ))
            } else if hasUnitySection("PrefabInstance", in: section.body) {
                // PrefabInstance stores overrides separately from the referenced
                // source prefab. `modificationValues` groups those overrides by
                // target fileID so `deltaTransform` can apply them later.
                guard let sourcePrefabGUID = guidValue("m_SourcePrefab", in: section.body) else { continue }
                prefabInstances.append(
                    PrefabInstanceData(
                        id: section.id,
                        parentTransformID: fileIDValue("m_TransformParent", in: section.body) ?? "0",
                        sourcePrefabGUID: sourcePrefabGUID,
                        propertyValuesByTargetID: modificationValues(in: section.body)
                    )
                )
            } else if hasUnitySection("Prefab", in: section.body) {
                explicitRootGameObjectID = fileIDValue("m_RootGameObject", in: section.body)
            }
        }

        let transformIDByGameObject = Dictionary(uniqueKeysWithValues: transforms.values.map { ($0.gameObjectID, $0.id) })
        let rootTransformID = explicitRootGameObjectID.flatMap { transformIDByGameObject[$0] }
            ?? transforms.values
                .sorted { $0.id < $1.id }
                .first(where: { $0.parentTransformID == "0" })?
                .id

        return ParsedPrefab(
            gameObjects: gameObjects,
            transforms: transforms,
            renderers: renderers,
            prefabInstances: prefabInstances,
            rootTransformID: rootTransformID
        )
    }

    private static func hasUnitySection(_ name: String, in body: String) -> Bool {
        // Unity YAML sections begin with e.g. `GameObject:` after the `--- !u!`
        // header. This helper avoids brittle exact-line parsing.
        body.hasPrefix("\(name):") || body.contains("\n\(name):")
    }

    private static func prefabSections(_ text: String) -> [(id: String, body: String)] {
        // Splits a .prefab YAML file into `(fileID, body)` chunks. FileIDs are
        // how Unity connects GameObjects, Transforms, Renderers, and overrides.
        text.components(separatedBy: "--- !u!")
            .dropFirst()
            .compactMap { chunk in
                let lines = chunk.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
                guard let header = lines.first,
                      let ampersand = header.firstIndex(of: "&"),
                      lines.count > 1 else {
                    return nil
                }
                let id = String(header[header.index(after: ampersand)...]).trimmingCharacters(in: .whitespaces)
                return (id, String(lines[1]))
            }
    }

    private static func worldTransform(
        for id: String,
        transforms: [String: TransformData],
        cache: inout [String: WorldTransform]
    ) -> WorldTransform? {
        // Recursively composes parent transforms to produce local prefab-space
        // coordinates. Cached because many renderers share ancestors.
        if let cached = cache[id] {
            return cached
        }
        guard let transform = transforms[id] else {
            return nil
        }

        let local = localWorldTransform(for: transform)

        guard transform.parentTransformID != "0",
              let parent = worldTransform(for: transform.parentTransformID, transforms: transforms, cache: &cache) else {
            cache[id] = local
            return local
        }

        let world = combine(parent: parent, local: local)
        cache[id] = world
        return world
    }

    private static func instanceIsActive(_ instance: PrefabInstanceData, sourceParsed: ParsedPrefab?) -> Bool {
        // Respects root active-state overrides on nested prefabs so hidden visual
        // groups do not show in the editor.
        guard let sourceParsed,
              let rootTransformID = sourceParsed.rootTransformID,
              let rootTransform = sourceParsed.transforms[rootTransformID],
              let baseGameObject = sourceParsed.gameObjects[rootTransform.gameObjectID] else {
            return true
        }

        if let override = instance.propertyValuesByTargetID[rootTransform.gameObjectID]?["m_IsActive"] {
            return override != "0"
        }
        return baseGameObject.isActive
    }

    private static func deltaTransform(for instance: PrefabInstanceData, sourceParsed: ParsedPrefab?) -> WorldTransform {
        // Converts Unity prefab override properties into a transform delta from
        // the source prefab root. This is how nested prefabs move into place.
        guard let sourceParsed,
              let rootTransformID = sourceParsed.rootTransformID,
              let sourceRoot = sourceParsed.transforms[rootTransformID] else {
            return .identity
        }

        let properties = instance.propertyValuesByTargetID[rootTransformID] ?? [:]

        let modifiedX = properties["m_LocalPosition.x"].flatMap(Double.init) ?? sourceRoot.localX
        let modifiedY = properties["m_LocalPosition.y"].flatMap(Double.init) ?? sourceRoot.localY
        let modifiedScaleX = properties["m_LocalScale.x"].flatMap(Double.init) ?? sourceRoot.scaleX
        let modifiedScaleY = properties["m_LocalScale.y"].flatMap(Double.init) ?? sourceRoot.scaleY

        return WorldTransform(
            x: modifiedX - sourceRoot.localX,
            y: modifiedY - sourceRoot.localY,
            basisXX: sourceRoot.scaleX == 0 ? modifiedScaleX : modifiedScaleX / sourceRoot.scaleX,
            basisXY: 0,
            basisYX: 0,
            basisYY: sourceRoot.scaleY == 0 ? modifiedScaleY : modifiedScaleY / sourceRoot.scaleY
        )
    }

    private static func modificationValues(in body: String) -> [String: [String: String]] {
        // Parses PrefabInstance `m_Modification` blocks into
        // target-fileID -> property-path -> value. Unity stores overrides in
        // this indirect format instead of mutating the source prefab YAML.
        var values: [String: [String: String]] = [:]
        var currentTargetID: String?
        var currentPropertyPath: String?

        for rawLine in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("- target:") {
                currentTargetID = capture(in: String(line), pattern: #"fileID:\s*(-?\d+)"#)
                currentPropertyPath = nil
            } else if line.hasPrefix("propertyPath:") {
                currentPropertyPath = String(line.dropFirst("propertyPath:".count)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("value:"),
                      let targetID = currentTargetID,
                      let propertyPath = currentPropertyPath {
                let rawValue = String(line.dropFirst("value:".count)).trimmingCharacters(in: .whitespaces)
                values[targetID, default: [:]][propertyPath] = rawValue
                currentPropertyPath = nil
            }
        }

        return values
    }

    private static func transform(_ piece: SpritePiece, by world: WorldTransform) -> SpritePiece {
        // Applies a nested prefab transform to one sprite piece. Coordinates are
        // Unity units converted to Vector 2 editor units by the x100 convention.
        let localX = Double(piece.x) / 100
        let localY = Double(-piece.y) / 100
        let transformedX = world.x + localX * world.basisXX + localY * world.basisYX
        let transformedY = world.y + localX * world.basisXY + localY * world.basisYY
        let widthScale = hypot(world.basisXX, world.basisXY)
        let heightScale = hypot(world.basisYX, world.basisYY)
        let rotation = atan2(world.basisXY, world.basisXX) * 180 / .pi

        return SpritePiece(
            name: piece.name,
            imagePath: piece.imagePath,
            x: Int((transformedX * 100).rounded()),
            y: -Int((transformedY * 100).rounded()),
            width: max(8, Int((Double(piece.width) * widthScale).rounded())),
            height: max(8, Int((Double(piece.height) * heightScale).rounded())),
            rotation: piece.rotation - rotation,
            sortingLayer: piece.sortingLayer,
            className: piece.className
        )
    }

    private static func translate(_ pieces: [SpritePiece], x: Int, y: Int) -> [SpritePiece] {
        // Places local prefab pieces at the requested world/editor position.
        pieces.map { piece in
            SpritePiece(
                name: piece.name,
                imagePath: piece.imagePath,
                x: piece.x + x,
                y: piece.y + y,
                width: piece.width,
                height: piece.height,
                rotation: piece.rotation,
                sortingLayer: piece.sortingLayer,
                className: piece.className
            )
        }
    }

    private static func combine(parent: WorldTransform, local: WorldTransform) -> WorldTransform {
        // Compose parent * local so nested pieces keep their position and basis.
        return WorldTransform(
            x: parent.x + local.x * parent.basisXX + local.y * parent.basisYX,
            y: parent.y + local.x * parent.basisXY + local.y * parent.basisYY,
            basisXX: parent.basisXX * local.basisXX + parent.basisYX * local.basisXY,
            basisXY: parent.basisXY * local.basisXX + parent.basisYY * local.basisXY,
            basisYX: parent.basisXX * local.basisYX + parent.basisYX * local.basisYY,
            basisYY: parent.basisXY * local.basisYX + parent.basisYY * local.basisYY
        )
    }

    private static func localWorldTransform(for transform: TransformData) -> WorldTransform {
        // Converts one Unity Transform into a 2D affine basis. Vector 2 levels
        // are 2D, but Unity still stores rotations as quaternions.
        let basis = projectedBasis(
            x: transform.rotationX,
            y: transform.rotationY,
            z: transform.rotationZ,
            w: transform.rotationW,
            scaleX: transform.scaleX,
            scaleY: transform.scaleY
        )
        return WorldTransform(
            x: transform.localX,
            y: transform.localY,
            basisXX: basis.xx,
            basisXY: basis.xy,
            basisYX: basis.yx,
            basisYY: basis.yy
        )
    }

    private static func projectedBasis(
        x: Double,
        y: Double,
        z: Double,
        w: Double,
        scaleX: Double,
        scaleY: Double
    ) -> (xx: Double, xy: Double, yx: Double, yy: Double) {
        // Projects Unity's quaternion+scale into the 2D basis used by our editor
        // preview renderer.
        let xx = (1 - 2 * (y * y + z * z)) * scaleX
        let xy = (2 * (x * y + z * w)) * scaleX
        let yx = (2 * (x * y - z * w)) * scaleY
        let yy = (1 - 2 * (x * x + z * z)) * scaleY
        return (xx, xy, yx, yy)
    }

    private static func lineValue(_ key: String, in body: String) -> String? {
        // Reads a simple YAML `key: value` line. Good enough for Unity's stable
        // prefab text format used by this project.
        body.split(separator: "\n")
            .first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("\(key):") }
            .flatMap { line in
                line.split(separator: ":", maxSplits: 1).last.map {
                    String($0).trimmingCharacters(in: .whitespaces)
                }
            }
    }

    private static func lineMap(_ key: String, in body: String) -> [String: Double] {
        // Reads inline Unity maps like `{x: 1, y: 2, z: 0}`.
        guard let raw = lineValue(key, in: body),
              raw.hasPrefix("{"),
              raw.hasSuffix("}") else {
            return [:]
        }

        var values: [String: Double] = [:]
        let trimmed = raw.dropFirst().dropLast()
        for part in trimmed.split(separator: ",") {
            let pieces = part.split(separator: ":", maxSplits: 1).map {
                String($0).trimmingCharacters(in: .whitespaces)
            }
            if pieces.count == 2 {
                values[pieces[0]] = Double(pieces[1])
            }
        }
        return values
    }

    private static func fileIDValue(_ key: String, in body: String) -> String? {
        // Extracts Unity's `{fileID: ...}` references.
        guard let raw = lineValue(key, in: body) else { return nil }
        return capture(in: raw, pattern: #"fileID:\s*(-?\d+)"#)
    }

    private static func guidValue(_ key: String, in body: String) -> String? {
        // Extracts Unity asset GUID references from YAML lines.
        guard let raw = lineValue(key, in: body) else { return nil }
        return capture(in: raw, pattern: #"guid:\s*([A-Fa-f0-9]+)"#)
    }

    private static func capture(in text: String, pattern: String) -> String? {
        // Regex capture helper used by prefab YAML parsing.
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[range])
    }

    private static func quaternionZRotation(_ values: [String: Double]) -> Double {
        // Fast path for common 2D sprite rotations where only quaternion z/w
        // matter. Full basis math above handles more complex cases.
        let z = values["z"] ?? 0
        let w = values["w"] ?? 1
        return Foundation.atan2(2 * w * z, 1 - 2 * z * z) * 180 / .pi
    }

    private static func boundingBox(for pieces: [SpritePiece]) -> (centerX: Int, centerY: Int, width: Int, height: Int) {
        // Computes a rotated bounds rectangle for prefab previews.
        let corners = pieces.flatMap { piece -> [CGPoint] in
            let halfW = CGFloat(piece.width) / 2
            let halfH = CGFloat(piece.height) / 2
            return [
                CGPoint(x: -halfW, y: -halfH),
                CGPoint(x: halfW, y: -halfH),
                CGPoint(x: halfW, y: halfH),
                CGPoint(x: -halfW, y: halfH)
            ].map { point in
                let radians = piece.rotation * .pi / 180
                let cosine = CGFloat(Foundation.cos(radians))
                let sine = CGFloat(Foundation.sin(radians))
                return CGPoint(
                    x: CGFloat(piece.x) + point.x * cosine - point.y * sine,
                    y: CGFloat(piece.y) + point.x * sine + point.y * cosine
                )
            }
        }
        let minX = Int((corners.map(\.x).min() ?? 0).rounded(.down))
        let maxX = Int((corners.map(\.x).max() ?? 0).rounded(.up))
        let minY = Int((corners.map(\.y).min() ?? 0).rounded(.down))
        let maxY = Int((corners.map(\.y).max() ?? 0).rounded(.up))
        return ((minX + maxX) / 2, (minY + maxY) / 2, max(24, maxX - minX), max(24, maxY - minY))
    }

    private static func rasterizedPreviewPath(
        for asset: TextureAsset,
        pieces: [SpritePiece],
        bounds: (centerX: Int, centerY: Int, width: Int, height: Int)
    ) -> String? {
        // Bakes prefab sprite pieces into one temporary PNG for cheap rendering
        // in browser cards/canvas. The node still keeps individual child pieces
        // when we need inspection or fallback behavior.
        let cacheRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Vector2LevelEditorPrefabPreviews", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)

        let namePrefix = asset.name
            .replacingOccurrences(of: #"[^A-Za-z0-9_-]"#, with: "_", options: .regularExpression)
            .prefix(48)
        let outputURL = cacheRoot.appendingPathComponent("\(namePrefix)_\(stableHash(asset.filePath + ":root-pivot-v6")).png")
        if FileManager.default.fileExists(atPath: outputURL.path) {
            return outputURL.path
        }

        let maxSide: CGFloat = 512
        let scale = min(1, maxSide / CGFloat(max(bounds.width, bounds.height)))
        let canvasSize = NSSize(
            width: max(16, CGFloat(bounds.width) * scale),
            height: max(16, CGFloat(bounds.height) * scale)
        )
        let minX = CGFloat(bounds.centerX - bounds.width / 2)
        let maxY = CGFloat(bounds.centerY + bounds.height / 2)

        let image = NSImage(size: canvasSize)
        image.lockFocus()
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: canvasSize).fill()

        for piece in pieces {
            guard let sprite = CachedImageStore.shared.image(at: piece.imagePath) else { continue }
            let drawSize = NSSize(
                width: max(1, CGFloat(piece.width) * scale),
                height: max(1, CGFloat(piece.height) * scale)
            )
            let center = NSPoint(
                x: (CGFloat(piece.x) - minX) * scale,
                y: (maxY - CGFloat(piece.y)) * scale
            )

            let graphics = NSGraphicsContext.current
            graphics?.saveGraphicsState()
            let transform = NSAffineTransform()
            transform.translateX(by: center.x, yBy: center.y)
            transform.rotate(byDegrees: -piece.rotation)
            transform.translateX(by: -drawSize.width / 2, yBy: -drawSize.height / 2)
            transform.concat()
            sprite.draw(
                in: NSRect(origin: .zero, size: drawSize),
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.none]
            )
            graphics?.restoreGraphicsState()
        }

        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .png, properties: [:]) else {
            return nil
        }
        try? data.write(to: outputURL)
        return outputURL.path
    }

    private static func stableHash(_ text: String) -> String {
        // Stable cache key for baked prefab PNGs.
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

}

/// Builds spawn markers for In/Out tools.
///
/// In/Out are special because their exported XML is spawn metadata, while their
/// editor visual comes from generated prefab-style art used during placement.
