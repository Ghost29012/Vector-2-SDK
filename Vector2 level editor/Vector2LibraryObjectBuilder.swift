//
//  Vector2LibraryObjectBuilder.swift
//  Vector2 level editor
//
//  Rebuilds library XML into editor-visible nodes.
//
//  Vector 2 library objects are not one simple sprite. They can contain nested
//  Objects, Images, ObjectReferences, variables, phantom fallbacks, and weird
//  class-name aliases. This builder is why imported levels show actual fans,
//  tricks, swarm stuff, and props instead of placeholder boxes.
//

import SwiftUI
import AppKit
import Foundation

enum Vector2LibraryObjectBuilder {
    private struct LibraryFileVersion: Equatable {
        let size: Int
        let modifiedAt: Date?
    }

    private struct LibraryFileIndex {
        let directObjects: [String: XMLElement]
        let allObjects: [String: XMLElement]
        let sampleNames: String
    }

    private enum LibraryFileResult {
        case index(LibraryFileIndex)
        case failure(String)
    }

    private struct LibraryFileCacheEntry {
        let version: LibraryFileVersion
        let result: LibraryFileResult
    }

    // RoomWeaver can resolve hundreds of references from the same giant XML
    // library. Index the file once, then clone individual objects as needed.
    private static var libraryFileCache: [String: LibraryFileCacheEntry] = [:]
    private static let libraryFileCacheLock = NSLock()
    // Bump this whenever preview rasterization logic changes; otherwise old
    // cached thumbnails can make fixed phantoms look broken.
    private static let previewCacheVersion = "library-preview-v34-4096"
    // Keep a finite ceiling so malformed or cyclic library references cannot
    // recurse forever. This is independent of the authored hierarchy depth in
    // the runtime dump, which includes generated Unity support transforms.
    private static let maximumVisualReferenceDepth = 32
    typealias ChoiceMap = [String: String]

    /// Small, renderer-independent visual fragment.
    ///
    /// A `Piece` can come from an Image, Platform, Trigger, Area, Comment, or
    /// UnityModel marker. Later stages either turn pieces into child nodes or
    /// bake them into a cached preview image.
    private struct Piece {
        let name: String
        let kind: LevelNode.Kind
        let x: Int
        let y: Int
        let width: Int
        let height: Int
        let rotation: Double
        let layer: String
        let className: String
        let imagePath: String
        let filename: String
        let tintColorHex: String
        var mirrored: Bool = false
        var basisXX: Double? = nil
        var basisXY: Double? = nil
        var basisYX: Double? = nil
        var basisYY: Double? = nil
        var trapezoidType: Int = 0

        var isEditorVisual: Bool {
            !imagePath.isEmpty
                || filename == "__comment__"
                || filename == "__unitymodel__"
                || kind.isEditorShape
        }

        /// World-space polygon corners used for preview bounds.
        ///
        /// Matrix-based images keep a full basis so rotated/mirrored pieces
        /// don't get measured as a bogus axis-aligned blob.
        var corners: [CGPoint] {
            if let basisXX, let basisXY, let basisYX, let basisYY {
                let ax = CGFloat(basisXX)
                let ay = CGFloat(basisXY)
                let bx = CGFloat(basisYX)
                let by = CGFloat(basisYY)
                let origin = CGPoint(x: CGFloat(x), y: CGFloat(y))
                return [
                    origin,
                    CGPoint(x: origin.x + ax, y: origin.y + ay),
                    CGPoint(x: origin.x + ax + bx, y: origin.y + ay + by),
                    CGPoint(x: origin.x + bx, y: origin.y + by)
                ]
            }

            return [
                CGPoint(x: CGFloat(x), y: CGFloat(y)),
                CGPoint(x: CGFloat(x + width), y: CGFloat(y)),
                CGPoint(x: CGFloat(x + width), y: CGFloat(y + height)),
                CGPoint(x: CGFloat(x), y: CGFloat(y + height))
            ]
        }
    }

    /// Lightweight affine transform used while walking nested library XML.
    ///
    /// Vector 2 objects can nest matrices inside library references. This keeps
    /// parent transforms separate from screen/canvas transforms.
    private struct AffineContext {
        let x: Double
        let y: Double
        let basisXX: Double
        let basisXY: Double
        let basisYX: Double
        let basisYY: Double

        static let identity = AffineContext(
            x: 0,
            y: 0,
            basisXX: 1,
            basisXY: 0,
            basisYX: 0,
            basisYY: 1
        )

        /// Converts a local point into accumulated world coordinates.
        func point(x localX: Double, y localY: Double) -> (x: Double, y: Double) {
            (
                x: x + localX * basisXX + localY * basisYX,
                y: y + localX * basisXY + localY * basisYY
            )
        }

        /// Converts a local vector/basis axis without applying translation.
        func vector(x localX: Double, y localY: Double) -> (x: Double, y: Double) {
            (
                x: localX * basisXX + localY * basisYX,
                y: localX * basisXY + localY * basisYY
            )
        }
    }

    static var importPipeline: Vector2ImportPipeline {
        Vector2ImportPipeline.current
    }

    /// Builds a placed library object from an asset-browser card.
    ///
    /// The returned node still exports as the original object reference, but it
    /// can contain preview children so the editor resembles the game.
    static func reconstruct(asset: TextureAsset, x: Int, y: Int) -> LevelNode? {
        let objectName = asset.libraryObjectName.isEmpty ? asset.name : asset.libraryObjectName
        let settings = overrideSettingsElement(from: asset.libraryOverrides)
        let choices = activeChoices(for: settings)
        guard let object = resolvedLibraryObject(
            named: objectName,
            in: URL(fileURLWithPath: asset.filePath),
            settings: settings,
            choices: choices
        ) else {
            return phantomVisual(for: asset, x: x, y: y)
        }

        let pieces = collectPieces(
            from: object,
            context: combinedContext(
                parent: .identity,
                localPositionX: Double(x),
                localPositionY: Double(y),
                matrixElement: nil
            ),
            baseURL: URL(fileURLWithPath: asset.filePath),
            depth: 0,
            choices: choices
        )

        guard !pieces.isEmpty else { return nil }
        let includeShapePlaceholders = shouldRasterizePlaceholderPieces(
            pieces,
            filename: URL(fileURLWithPath: asset.filePath).lastPathComponent
        )
        let rawRenderPieces = phantomRenderPieces(
            for: pieces,
            assetName: objectName,
            enabled: includeShapePlaceholders
        )
        let rawVisualPieces = renderPiecesForBounds(from: rawRenderPieces)
        let rawBounds = boundingBox(for: rawVisualPieces.isEmpty ? rawRenderPieces : rawVisualPieces)
        let renderPieces = normalizedVariantPieces(
            rawRenderPieces,
            bounds: rawBounds,
            asset: asset,
            anchorX: x,
            anchorY: y
        )
        let visualPieces = renderPiecesForBounds(from: renderPieces)
        let bounds = boundingBox(for: visualPieces.isEmpty ? renderPieces : visualPieces)
        let previewPath = rasterizedPreviewPath(
            for: asset,
            pieces: renderPieces,
            bounds: bounds,
            includeShapePlaceholders: shouldBakeShapePlaceholders(from: renderPieces, filename: URL(fileURLWithPath: asset.filePath).lastPathComponent)
        )
        let children = makeChildNodes(from: renderPieces, variant: "Library", parentOriginX: x, parentOriginY: y)
        let previewLayer = previewSortingLayer(for: renderPieces, filename: URL(fileURLWithPath: asset.filePath).lastPathComponent)

        return LevelNode(
            name: asset.name,
            kind: .object,
            factor: "1",
            transform: .init(
                x: x,
                y: y,
                width: max(24, bounds.width),
                height: max(24, bounds.height)
            ),
            xml: .init(template: "LibraryObject", choice: asset.category, variant: "Expanded"),
            metadata: .init(
                sortingLayer: previewLayer,
                tag: LevelNode.Kind.object.defaultTag,
                filename: URL(fileURLWithPath: asset.filePath).lastPathComponent,
                className: objectName,
                imagePath: previewPath ?? "",
                visualOffsetX: bounds.centerX - x,
                visualOffsetY: bounds.centerY - y,
                visualNativeWidth: max(24, bounds.width),
                visualNativeHeight: max(24, bounds.height),
                visualType: "RoomWeaverLibraryReference",
                libraryObjectName: objectName,
                libraryOverrides: asset.libraryOverrides
            ),
            previewPieces: makePreviewPieces(from: visualPieces.isEmpty ? renderPieces : visualPieces, bounds: bounds),
            children: children
        )
    }

    private static func normalizedVariantPieces(
        _ pieces: [Piece],
        bounds: (centerX: Int, centerY: Int, width: Int, height: Int),
        asset: TextureAsset,
        anchorX: Int,
        anchorY: Int
    ) -> [Piece] {
        // Hidden XML variants are real assets, but some are just enable switches
        // inside a huge wrapper. Show them, but clamp their editor footprint.
        guard !asset.libraryVariantRootName.isEmpty else { return pieces }
        guard asset.libraryObjectName.caseInsensitiveCompare("Fan") != .orderedSame else { return pieces }
        let maxSide = max(bounds.width, bounds.height)
        guard maxSide > 1400 else { return pieces }

        let scale = min(1, 900.0 / Double(maxSide))
        return pieces.map { piece in
            let normalizedX = Double(anchorX) + (Double(piece.x) - Double(bounds.centerX)) * scale
            let normalizedY = Double(anchorY) + (Double(piece.y) - Double(bounds.centerY)) * scale
            return Piece(
                name: piece.name,
                kind: piece.kind,
                x: Int(normalizedX.rounded()),
                y: Int(normalizedY.rounded()),
                width: max(1, Int((Double(piece.width) * scale).rounded())),
                height: max(1, Int((Double(piece.height) * scale).rounded())),
                rotation: piece.rotation,
                layer: piece.layer,
                className: piece.className,
                imagePath: piece.imagePath,
                filename: piece.filename,
                tintColorHex: piece.tintColorHex,
                mirrored: piece.mirrored,
                basisXX: piece.basisXX.map { $0 * scale },
                basisXY: piece.basisXY.map { $0 * scale },
                basisYX: piece.basisYX.map { $0 * scale },
                basisYY: piece.basisYY.map { $0 * scale }
            )
        }
    }

    private static func overrideSettingsElement(from overrides: [String: String]) -> XMLElement? {
        guard !overrides.isEmpty else { return nil }
        let object = XMLElement(name: "Object")
        let properties = XMLElement(name: "Properties")
        let staticNode = XMLElement(name: "Static")
        let overrideVariable = XMLElement(name: "OverrideVariable")

        for (name, value) in overrides.sorted(by: { $0.key < $1.key }) {
            let variable = XMLElement(name: "Variable")
            variable.addAttribute(XMLNode.attribute(withName: "Name", stringValue: name) as! XMLNode)
            variable.addAttribute(XMLNode.attribute(withName: "Value", stringValue: value) as! XMLNode)
            overrideVariable.addChild(variable)
        }

        staticNode.addChild(overrideVariable)
        properties.addChild(staticNode)
        object.addChild(properties)
        return object
    }

    private static func phantomRenderPieces(for pieces: [Piece], assetName: String, enabled: Bool) -> [Piece] {
        // Comment-only phantoms have no art. When enabled, replace that empty
        // visual pile with the best matching stunt icon so browser cards and
        // placed tricks are readable instead of gray/green placeholders.
        guard enabled, !pieces.contains(where: { !$0.imagePath.isEmpty }) else {
            return pieces
        }

        let bounds = boundingBox(for: pieces)
        guard let stuntIcon = stuntIconPiece(for: assetName, bounds: bounds) else {
            return pieces
        }

        return [stuntIcon]
    }

    private static func renderPiecesForBounds(from pieces: [Piece]) -> [Piece] {
        // Prefer real images for bounds; if none exist, fall back to placeholder
        // shapes/comments so comment-only phantoms still get a sane rectangle.
        let imagePieces = pieces.filter { !$0.imagePath.isEmpty }
        if !imagePieces.isEmpty {
            return imagePieces
        }
        return pieces.filter(\.isEditorVisual)
    }

    private static func shouldBakeShapePlaceholders(from pieces: [Piece], filename: String) -> Bool {
        // Baking placeholders makes invisible/comment-only library objects show
        // up in the browser, but only when there is no real art to preserve.
        pieces.allSatisfy { $0.imagePath.isEmpty } && shouldRasterizePlaceholderPieces(pieces, filename: filename)
    }

    private static func stuntIconPiece(
        for assetName: String,
        bounds: (centerX: Int, centerY: Int, width: Int, height: Int)
    ) -> Piece? {
        // Stunt icons live in texture classes, not directly in phantoms.xml.
        // This resolves a trick name like WallHop into the actual texture class
        // names Nekki used for stunt preview cards.
        let token = stuntIconToken(for: assetName)
        let classNames = [
            "stunts_run.track_trick_\(token)",
            "stunts_run.track_trick_\(token)_0",
            "stunts_run_low.track_trick_\(token)",
            "stunts_run_low.track_trick_\(token)_0"
        ]

        guard let match = classNames.compactMap({ className -> (className: String, path: String)? in
            guard let path = Vector2AssetCatalog.imagePath(forClassName: className) else { return nil }
            return (className, path)
        }).first else {
            return nil
        }

        let maxWidth = max(72, bounds.width)
        let maxHeight = max(72, bounds.height)
        let imageSize = CachedImageStore.shared.image(at: match.path)?.size ?? NSSize(width: maxWidth, height: maxHeight)
        let imageWidth = max(1, imageSize.width)
        let imageHeight = max(1, imageSize.height)
        let scale = min(CGFloat(maxWidth) / imageWidth, CGFloat(maxHeight) / imageHeight)
        let width = max(24, Int((imageWidth * scale).rounded()))
        let height = max(24, Int((imageHeight * scale).rounded()))

        return Piece(
            name: assetName,
            kind: .image,
            x: bounds.centerX - width / 2,
            y: bounds.centerY - height / 2,
            width: width,
            height: height,
            rotation: 0,
            layer: "Debug",
            className: match.className,
            imagePath: match.path,
            filename: "",
            tintColorHex: ""
        )
    }

    private static func stuntIconToken(for assetName: String) -> String {
        // Normalizes weird stunt naming differences between library object names
        // and texture class names. Add aliases here when a trick shows the
        // generic stunt logo instead of its actual card art.
        let normalized = assetName
            .lowercased()
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()

        let aliases: [String: String] = [
            "airbomb": "airbomb",
            "airspin": "airspin",
            "backflip": "backflip",
            "barjump": "barjump",
            "barjumpsaltoless": "barjumpsaltoless",
            "boomboomsh": "boomboomshhuh",
            "boomboomshhuh": "boomboomshhuh",
            "cheatgainer": "cheatgainer",
            "coolswing": "coolswing",
            "dashtofrontflip": "dashtofrontflip",
            "divedown": "divedown",
            "diveroll": "diveroll",
            "doubleback": "doubleback",
            "doublejumproll": "doublejumproll",
            "doublekong": "doublekong",
            "doublespinvault": "doublespinvault",
            "flyingarrow": "flyingarrow",
            "wallhop": "wallhop360",
            "wallhop360": "wallhop360",
            "wallcling": "360wallcling",
            "wallclingspin": "360wallcling",
            "wallcling360": "360wallcling",
            "360wallcling": "360wallcling",
            "wallspeedvault": "wallspeedvault",
            "wallbackroll": "wallbackroll",
            "vertvault": "vertvault",
            "sideflip": "sideflip",
            "sidebomb": "sidebomb",
            "spin": "spin360",
            "spin360": "spin360",
            "spinbicycle": "spinbicycle",
            "spinvault": "spinvault",
            "spinningvault": "spinningvault",
            "splitone": "splitone",
            "swallow": "swallow",
            "swallow400": "swallow",
            "jumpwheel": "jumpwheel",
            "jumpobstacle": "jumpobstacle",
            "jumpdownroll": "jumpdownroll",
            "jumpspinvault": "jumpspinvault",
            "jumptumble": "jumptumble",
            "obstaclefrontflip": "obstaclefrontflip",
            "barrelvault": "barrelvault",
            "dashvault": "dashvault",
            "gatevault": "gatevault",
            "handspring": "handspring",
            "handspringtoroll": "handspringtoroll",
            "longcircle": "longcircle",
            "longjumptobarrel": "longjumptobarrel",
            "monkeytobackflip": "monkeytobackflip",
            "monkeytobomb": "monkeytobomb",
            "monkeyvault": "monkeyvault",
            "railflipvault": "railflipvault",
            "railflip": "railflipvault",
            "reversevault": "reversevault",
            "rocketvault": "rocketvault",
            "rolltostraightlegsflip": "rolltostraightlegsflip",
            "screwdriver": "screwdriver",
            "slowspin": "slowspin",
            "thiefvault": "thiefvault",
            "triplehit": "triplehit",
            "tripleswing": "tripleswing",
            "tripletricktoswallow": "tripletricktoswallow",
            "underbar": "underbar",
            "webster": "webster",
            "websterwithsalto": "websterwithsalto",
            "frontfliptwolegs": "frontfliplegsup",
            "frontfliplegsup": "frontfliplegsup",
            "doublespinroll": "doublespintoroll",
            "doublespintoroll": "doublespintoroll",
            "kingkongjumpoff": "kingkongjump",
            "kingkongjump": "kingkongjump",
            "kingkongtobend": "kingkongtobend"
        ]

        return aliases[normalized] ?? normalized
    }

    /// Special visual path for phantoms/tricks.
    ///
    /// Many phantom XML entries are comment-only or placeholder-heavy, so this
    /// creates a usable editor preview from whatever pieces exist. Stunt icon
    /// fallbacks are handled here instead of the generic placeholder path.
    private static func phantomVisual(for asset: TextureAsset, x: Int, y: Int) -> LevelNode? {
        let sourceURL = URL(fileURLWithPath: asset.filePath)
        guard sourceURL.lastPathComponent != "phantoms.xml" else {
            return nil
        }

        for phantomName in phantomCandidates(for: asset.name) {
            guard var node = reconstructReference(
                name: phantomName,
                filename: "phantoms.xml",
                originX: x,
                originY: y,
                baseURL: sourceURL,
                settings: nil
            ) else {
                continue
            }

            node.name = asset.name
            node.kind = .object
            node.xml = .init(template: "LibraryObjectPhantom", choice: asset.category, variant: phantomName)
            node.metadata.filename = sourceURL.lastPathComponent
            node.metadata.className = asset.className
            node.metadata.tag = LevelNode.Kind.object.defaultTag
            return node
        }

        return nil
    }

    static func reconstructReference(
        name: String,
        filename: String,
        originX: Int,
        originY: Int,
        baseURL: URL,
        settings: XMLElement?,
        rotation: Double = 0,
        choices inheritedChoices: [String: String] = [:]
    ) -> LevelNode? {
        // Used for imported `<ObjectReference>` nodes. It keeps the export
        // identity compact while creating visual children/previews for editing.
        let referencedURL = Vector2AssetCatalog.libraryURL(named: filename, relativeTo: baseURL)
        let choices = mergedChoices(inheritedChoices, activeChoices(for: settings))
        guard let object = resolvedLibraryObject(named: name, in: referencedURL, settings: settings, choices: choices) else {
            RoomWeaverDiagnostics.shared.libraryResolveFailed(
                name: name,
                filename: filename,
                reason: "object missing or library XML unreadable",
                context: "path=\(referencedURL.path)"
            )
            return nil
        }
        let dynamicXML = dynamicXML(from: object)
        let resolvedDynamics = resolvedDynamics(in: object, baseURL: referencedURL, choices: choices)

        let placementContext = placedReferenceContext(
            originX: originX,
            originY: originY,
            settings: settings,
            rotation: rotation
        )
        var pieces = collectLibraryInstancePieces(
            from: object,
            context: placementContext,
            baseURL: referencedURL,
            depth: 0,
            choices: choices
        )
        let strictWasEmpty = pieces.isEmpty
        if pieces.isEmpty {
            RoomWeaverDiagnostics.shared.libraryStrictRetry(
                name: name,
                filename: filename,
                context: "mode=ObjectReference \(choiceSummary(choices))"
            )
            pieces = collectLibraryInstancePieces(
                from: object,
                context: placementContext,
                baseURL: referencedURL,
                depth: 0,
                choices: choices,
                strict: false
            )
            if !pieces.isEmpty {
                RoomWeaverDiagnostics.shared.libraryResolvedAfterLooseRetry(
                    name: name,
                    filename: filename,
                    summary: pieceSummary(pieces)
                )
            }
        }

        guard !pieces.isEmpty else {
            RoomWeaverDiagnostics.shared.libraryResolveFailed(
                name: name,
                filename: filename,
                reason: "library object exists but produced 0 pieces",
                context: "mode=ObjectReference strictEmpty=\(strictWasEmpty) \(choiceSummary(choices))"
            )
            return nil
        }
        let asset = TextureAsset(
            group: "Library",
            kind: .libraryObject,
            category: filename,
            name: name,
            className: name,
            filePath: referencedURL.path,
            defaultLayer: "Default"
        )
        let visualPieces = renderPiecesForBounds(from: pieces)
        let bounds = boundingBox(for: visualPieces.isEmpty ? pieces : visualPieces)
        let previewPath = rasterizedPreviewPath(
            for: asset,
            pieces: pieces,
            bounds: bounds,
            includeShapePlaceholders: shouldBakeShapePlaceholders(from: pieces, filename: filename)
        )
        let children = makeChildNodes(from: pieces, variant: "Library", parentOriginX: originX, parentOriginY: originY)
        let previewLayer = previewSortingLayer(for: pieces, filename: filename)
        RoomWeaverDiagnostics.shared.libraryResolved(
            name: name,
            filename: filename,
            mode: "ObjectReference",
            summary: pieceSummary(pieces, previewPath: previewPath, children: children, dynamicXML: dynamicXML)
        )

        return LevelNode(
            name: name,
            kind: .objectReference,
            factor: "1",
            transform: .init(
                x: originX,
                y: originY,
                width: max(24, bounds.width),
                height: max(24, bounds.height)
            ),
            xml: .init(template: "ObjectReference", choice: filename, variant: "Resolved"),
            metadata: .init(
                sortingLayer: previewLayer,
                tag: LevelNode.Kind.objectReference.defaultTag,
                filename: filename,
                className: name,
                imagePath: previewPath ?? "",
                visualOffsetX: bounds.centerX - originX,
                visualOffsetY: bounds.centerY - originY,
                visualNativeWidth: max(24, bounds.width),
                visualNativeHeight: max(24, bounds.height),
                visualType: "RoomWeaverLibraryReference",
                dynamicXML: dynamicXML,
                resolvedDynamicCount: resolvedDynamics.count,
                resolvedDynamicOwners: resolvedDynamics.owners.joined(separator: ", ")
            ),
            previewPieces: makePreviewPieces(from: visualPieces.isEmpty ? pieces : visualPieces, bounds: bounds),
            children: children
        )
    }

    static func reconstructSceneObject(
        name: String,
        filename: String,
        originX: Int,
        originY: Int,
        baseURL: URL,
        settings: XMLElement?,
        rotation: Double = 0,
        choices inheritedChoices: [String: String] = [:]
    ) -> LevelNode? {
        // Used for `<Object Template=LibraryObject>` shapes. These look like
        // objects in XML but behave like references into a library file.
        let libraryURL = Vector2AssetCatalog.libraryURL(named: filename, relativeTo: baseURL)
        let choices = mergedChoices(inheritedChoices, activeChoices(for: settings))
        guard let object = resolvedLibraryObject(named: name, in: libraryURL, settings: settings, choices: choices) else {
            RoomWeaverDiagnostics.shared.libraryResolveFailed(
                name: name,
                filename: filename,
                reason: "object missing or library XML unreadable",
                context: "path=\(libraryURL.path)"
            )
            return nil
        }
        let dynamicXML = dynamicXML(from: object)
        let resolvedDynamics = resolvedDynamics(in: object, baseURL: libraryURL, choices: choices)
        let asset = TextureAsset(
            group: "Library",
            kind: .libraryObject,
            category: libraryURL.lastPathComponent,
            name: name,
            className: name,
            filePath: libraryURL.path,
            defaultLayer: "Default"
        )
        let placementContext = placedReferenceContext(
            originX: originX,
            originY: originY,
            settings: settings,
            rotation: rotation
        )
        var pieces = collectLibraryInstancePieces(
            from: object,
            context: placementContext,
            baseURL: libraryURL,
            depth: 0,
            choices: choices
        )
        let strictWasEmpty = pieces.isEmpty
        if pieces.isEmpty {
            RoomWeaverDiagnostics.shared.libraryStrictRetry(
                name: name,
                filename: filename,
                context: "mode=LibraryObject \(choiceSummary(choices))"
            )
            pieces = collectLibraryInstancePieces(
                from: object,
                context: placementContext,
                baseURL: libraryURL,
                depth: 0,
                choices: choices,
                strict: false
            )
            if !pieces.isEmpty {
                RoomWeaverDiagnostics.shared.libraryResolvedAfterLooseRetry(
                    name: name,
                    filename: filename,
                    summary: pieceSummary(pieces)
                )
            }
        }

        guard !pieces.isEmpty else {
            RoomWeaverDiagnostics.shared.libraryResolveFailed(
                name: name,
                filename: filename,
                reason: "library object exists but produced 0 pieces",
                context: "mode=LibraryObject strictEmpty=\(strictWasEmpty) \(choiceSummary(choices))"
            )
            return nil
        }
        let visualPieces = renderPiecesForBounds(from: pieces)
        let bounds = boundingBox(for: visualPieces.isEmpty ? pieces : visualPieces)
        let previewPath = rasterizedPreviewPath(
            for: asset,
            pieces: pieces,
            bounds: bounds,
            includeShapePlaceholders: shouldBakeShapePlaceholders(from: pieces, filename: filename)
        )
        let children = makeChildNodes(from: pieces, variant: "Library", parentOriginX: originX, parentOriginY: originY)
        let previewLayer = previewSortingLayer(for: pieces, filename: filename)
        RoomWeaverDiagnostics.shared.libraryResolved(
            name: name,
            filename: filename,
            mode: "LibraryObject",
            summary: pieceSummary(pieces, previewPath: previewPath, children: children, dynamicXML: dynamicXML)
        )

        return LevelNode(
            name: name,
            kind: .object,
            factor: "1",
            transform: .init(
                x: originX,
                y: originY,
                width: max(24, bounds.width),
                height: max(24, bounds.height)
            ),
            xml: .init(template: "LibraryObject", choice: filename, variant: "Expanded"),
            metadata: .init(
                sortingLayer: previewLayer,
                tag: LevelNode.Kind.object.defaultTag,
                filename: filename,
                className: name,
                imagePath: previewPath ?? "",
                visualOffsetX: bounds.centerX - originX,
                visualOffsetY: bounds.centerY - originY,
                visualNativeWidth: max(24, bounds.width),
                visualNativeHeight: max(24, bounds.height),
                visualType: "RoomWeaverLibraryReference",
                dynamicXML: dynamicXML,
                resolvedDynamicCount: resolvedDynamics.count,
                resolvedDynamicOwners: resolvedDynamics.owners.joined(separator: ", ")
            ),
            previewPieces: makePreviewPieces(from: visualPieces.isEmpty ? pieces : visualPieces, bounds: bounds),
            children: children
        )
    }

    static func reconstructInlineObject(
        from object: XMLElement,
        name: String,
        originX: Int,
        originY: Int,
        baseURL: URL,
        choices inheritedChoices: [String: String] = [:]
    ) -> LevelNode? {
        // Used when a room embeds object content directly. We still build a
        // wrapper node so the user can move it as one thing on the canvas.
        let choices = mergedChoices(inheritedChoices, activeChoices(for: object))
        let dynamicXML = dynamicXML(from: object)
        let resolvedDynamics = resolvedDynamics(in: object, baseURL: baseURL, choices: choices)
        var pieces = collectPieces(
            from: object,
            context: combinedContext(
                parent: .identity,
                localPositionX: Double(originX),
                localPositionY: Double(originY),
                matrixElement: nil
            ),
            baseURL: baseURL,
            depth: 0,
            choices: choices
        )
        let strictWasEmpty = pieces.isEmpty
        if pieces.isEmpty {
            RoomWeaverDiagnostics.shared.libraryStrictRetry(
                name: name,
                filename: baseURL.lastPathComponent,
                context: "mode=InlineObject \(choiceSummary(choices))"
            )
            pieces = collectPieces(
                from: object,
                context: combinedContext(
                    parent: .identity,
                    localPositionX: Double(originX),
                    localPositionY: Double(originY),
                    matrixElement: nil
                ),
                baseURL: baseURL,
                depth: 0,
                choices: choices,
                strict: false
            )
            if !pieces.isEmpty {
                RoomWeaverDiagnostics.shared.libraryResolvedAfterLooseRetry(
                    name: name,
                    filename: baseURL.lastPathComponent,
                    summary: pieceSummary(pieces)
                )
            }
        }

        guard !pieces.isEmpty else {
            RoomWeaverDiagnostics.shared.libraryResolveFailed(
                name: name,
                filename: baseURL.lastPathComponent,
                reason: "inline object produced 0 pieces",
                context: "strictEmpty=\(strictWasEmpty) \(choiceSummary(choices))"
            )
            return nil
        }

        let visualPieces = renderPiecesForBounds(from: pieces)
        let bounds = boundingBox(for: visualPieces.isEmpty ? pieces : visualPieces)
        let asset = TextureAsset(
            group: "Library",
            kind: .libraryObject,
            category: baseURL.lastPathComponent,
            name: name,
            className: name,
            filePath: baseURL.path,
            defaultLayer: "Default"
        )
        let previewPath = rasterizedPreviewPath(
            for: asset,
            pieces: pieces,
            bounds: bounds,
            includeShapePlaceholders: shouldBakeShapePlaceholders(from: pieces, filename: baseURL.lastPathComponent)
        )
        let children = makeChildNodes(from: pieces, variant: "Inline")
        RoomWeaverDiagnostics.shared.libraryResolved(
            name: name,
            filename: baseURL.lastPathComponent,
            mode: "InlineObject",
            summary: pieceSummary(pieces, previewPath: previewPath, children: children, dynamicXML: dynamicXML)
        )

        return LevelNode(
            name: name,
            kind: .object,
            factor: "1",
            transform: .init(
                x: originX,
                y: originY,
                width: max(24, bounds.width),
                height: max(24, bounds.height)
            ),
            xml: .init(template: "InlineObject", choice: baseURL.lastPathComponent, variant: "Expanded"),
            metadata: .init(
                sortingLayer: "Default",
                tag: LevelNode.Kind.object.defaultTag,
                filename: baseURL.lastPathComponent,
                className: name,
                imagePath: previewPath ?? "",
                visualOffsetX: bounds.centerX - originX,
                visualOffsetY: bounds.centerY - originY,
                visualNativeWidth: max(24, bounds.width),
                visualNativeHeight: max(24, bounds.height),
                dynamicXML: dynamicXML,
                resolvedDynamicCount: resolvedDynamics.count,
                resolvedDynamicOwners: resolvedDynamics.owners.joined(separator: ", ")
            ),
            previewPieces: makePreviewPieces(from: visualPieces.isEmpty ? pieces : visualPieces, bounds: bounds),
            children: children
        )
    }

    private static func makeChildNodes(
        from pieces: [Piece],
        variant: String,
        parentOriginX: Int? = nil,
        parentOriginY: Int? = nil
    ) -> [LevelNode] {
        // Turns collected visual pieces into selectable children. For image
        // pieces we keep the visible art as previewPieces so the selection box
        // can remain stable even when the art has matrix/basis data.
        pieces.map { piece in
            let bounds = boundingBox(for: [piece])
            var transform: LevelNode.Transform
            let previewPieces: [LevelNode.PreviewPiece]
            var metadata: LevelNode.Metadata

            if piece.kind == .image && !piece.imagePath.isEmpty {
                transform = .init(
                    x: parentOriginX.map { bounds.centerX - $0 } ?? bounds.centerX,
                    y: parentOriginY.map { bounds.centerY - $0 } ?? bounds.centerY,
                    width: max(1, bounds.width),
                    height: max(1, bounds.height),
                    rotation: 0
                )
                previewPieces = makePreviewPieces(from: [piece], bounds: bounds)
                metadata = .init(
                    sortingLayer: piece.layer,
                    tag: piece.kind.defaultTag,
                    filename: piece.filename,
                    className: piece.className,
                    imagePath: "",
                    isHidden: true,
                    visualNativeWidth: max(1, bounds.width),
                    visualNativeHeight: max(1, bounds.height)
                )
            } else {
                transform = .init(
                    x: parentOriginX.map { piece.x - $0 } ?? piece.x,
                    y: parentOriginY.map { piece.y - $0 } ?? piece.y,
                    width: piece.width,
                    height: piece.height,
                    rotation: piece.rotation
                )
                previewPieces = []
                metadata = .init(
                    sortingLayer: piece.layer,
                    tag: piece.kind.defaultTag,
                    filename: piece.filename,
                    className: piece.className,
                    imagePath: piece.imagePath
                )
            }

            if piece.kind == .trapezoid {
                let type = piece.trapezoidType == 2 ? 2 : 1
                let style: Vector2EditorVisuals.TrapezoidStyle = type == 2 ? .right : .left
                metadata.imagePath = Vector2EditorVisuals.trapezoidTexturePath(style: style) ?? ""
                metadata.visualType = String(type)
            }

            return LevelNode(
                name: displayName(for: piece),
                kind: piece.kind,
                factor: "1",
                transform: transform,
                xml: .init(
                    template: piece.kind.rawValue,
                    choice: piece.layer,
                    variant: piece.kind == .trapezoid
                        ? (piece.trapezoidType == 2 ? "SlopeType2" : "Slope")
                        : variant
                ),
                metadata: metadata,
                previewPieces: previewPieces
            )
        }
    }

    private static func displayName(for piece: Piece) -> String {
        let candidates = [
            piece.name,
            piece.className,
            piece.filename,
            piece.kind.rawValue
        ]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return candidates.first(where: { !$0.isEmpty }) ?? "Library Child"
    }

    private static func previewSortingLayer(for pieces: [Piece], filename: String) -> String {
        let visuals = pieces.filter { !$0.imagePath.isEmpty && !$0.layer.isEmpty }
        guard !visuals.isEmpty else {
            return "Default"
        }

        // A library object is currently represented by one cached bitmap in
        // the editor. Its layer therefore needs to describe the body of the
        // object, not whichever tiny glow/decal happens to be furthest forward.
        // Vector's runtime keeps those child layers independently; choosing the
        // maximum layer promoted complete wall panels to Lights/CPanelsAdd.
        let effectTokens = ["add", "light", "decal", "holo", "particle"]
        let structural = visuals.filter { piece in
            let layer = piece.layer.lowercased()
            return !effectTokens.contains(where: layer.contains)
        }
        let candidates = structural.isEmpty ? visuals : structural

        var coveredAreaByLayer: [String: Double] = [:]
        var pieceCountByLayer: [String: Int] = [:]
        for piece in candidates {
            let area = Double(max(1, piece.width)) * Double(max(1, piece.height))
            coveredAreaByLayer[piece.layer, default: 0] += area
            pieceCountByLayer[piece.layer, default: 0] += 1
        }

        return coveredAreaByLayer.keys.max { lhs, rhs in
            let leftArea = coveredAreaByLayer[lhs, default: 0]
            let rightArea = coveredAreaByLayer[rhs, default: 0]
            if leftArea != rightArea { return leftArea < rightArea }
            let leftCount = pieceCountByLayer[lhs, default: 0]
            let rightCount = pieceCountByLayer[rhs, default: 0]
            if leftCount != rightCount { return leftCount < rightCount }
            return Vector2SortingLayers.index(of: lhs) < Vector2SortingLayers.index(of: rhs)
        } ?? "Default"
    }

    private static func pieceSummary(
        _ pieces: [Piece],
        previewPath: String? = nil,
        children: [LevelNode]? = nil,
        dynamicXML: String? = nil
    ) -> String {
        let imagePieces = pieces.filter { !$0.imagePath.isEmpty }.count
        let missingImageAliases = pieces
            .filter { $0.kind == .image && $0.imagePath.isEmpty && !$0.className.isEmpty }
            .map(\.className)
        let shapePieces = pieces.filter { $0.kind.isEditorShape }.count
        let commentPieces = pieces.filter { $0.filename == "__comment__" }.count
        let unityModelPieces = pieces.filter { $0.filename == "__unitymodel__" }.count
        let blankPieces = max(0, pieces.count - imagePieces - shapePieces - commentPieces - unityModelPieces)

        var parts = [
            "pieces=\(pieces.count)",
            "images=\(imagePieces)",
            "shapes=\(shapePieces)",
            "comments=\(commentPieces)",
            "unityModels=\(unityModelPieces)",
            "blank=\(blankPieces)"
        ]
        if let previewPath {
            parts.append(previewPath.isEmpty ? "raster=no" : "raster=yes")
        }
        if let children {
            parts.append("children=\(children.count)")
        }
        if let dynamicXML {
            parts.append(dynamicXML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "dynamic=no" : "dynamic=yes")
        }
        if !missingImageAliases.isEmpty {
            parts.append("missingImageAliases=\(Array(Set(missingImageAliases)).sorted().prefix(8).joined(separator: ","))")
        }
        return parts.joined(separator: " ")
    }

    private static func choiceSummary(_ choices: ChoiceMap) -> String {
        guard !choices.isEmpty else { return "choices=none" }
        let summary = choices
            .filter { !$0.key.hasPrefix("__") }
            .sorted { $0.key < $1.key }
            .prefix(8)
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ",")
        return summary.isEmpty ? "choices=\(choices.count)" : "choices=\(summary)"
    }

    /// Recursively collects visual pieces from resolved library XML.
    ///
    /// This is where image nodes, platform/trigger placeholders, comments, and
    /// nested library references become `Piece`s that can later be child nodes or
    /// a rasterized preview.
    private static func collectPieces(
        from object: XMLElement,
        context: AffineContext,
        baseURL: URL,
        depth: Int,
        choices: ChoiceMap,
        strict: Bool = true
    ) -> [Piece] {
        guard depth < maximumVisualReferenceDepth else {
            RoomWeaverDiagnostics.shared.layoutDebug(
                kind: "depth-cutoff",
                name: attribute("Name", on: object) ?? object.name ?? "Object",
                detail: "depth=\(depth) max=\(maximumVisualReferenceDepth) file=\(baseURL.lastPathComponent)"
            )
            return []
        }
        let includePhantomVisualizers = baseURL.lastPathComponent == "phantoms.xml"
        if strict {
            guard shouldIncludeElement(object, choices: choices, includePhantomVisualizers: includePhantomVisualizers) else { return [] }
        }

        let localX = parseDouble(attribute("X", on: object)) ?? 0
        let localY = parseDouble(attribute("Y", on: object)) ?? 0
        let current = combinedContext(
            parent: context,
            localPositionX: localX,
            localPositionY: localY,
            matrixElement: firstElement(fromXPath: "./Properties/Static/Matrix", on: object)
        )

        var pieces: [Piece] = []
        for child in childElements(of: object) {
            if child.name == "Content" {
                pieces.append(contentsOf: collectPieces(fromContent: child, context: current, baseURL: baseURL, depth: depth, choices: choices, strict: strict))
            }
        }
        return pieces
    }

    private static func collectLibraryInstancePieces(
        from object: XMLElement,
        context: AffineContext,
        baseURL: URL,
        depth: Int,
        choices: ChoiceMap,
        strict: Bool = true
    ) -> [Piece] {
        // Entry point for a resolved referenced library object. Phantoms get a
        // special allowance because their useful visualizer bits are sometimes
        // marked differently from normal selectable library content.
        guard depth < maximumVisualReferenceDepth else {
            RoomWeaverDiagnostics.shared.layoutDebug(
                kind: "depth-cutoff",
                name: attribute("Name", on: object) ?? object.name ?? "Object",
                detail: "depth=\(depth) max=\(maximumVisualReferenceDepth) file=\(baseURL.lastPathComponent)"
            )
            return []
        }
        let isExplicitPhantomVisualizer = baseURL.lastPathComponent == "phantoms.xml"
            && attribute("Phantom", on: object) == "1"
        if strict {
            guard isExplicitPhantomVisualizer || shouldIncludeElement(object, choices: choices) else { return [] }
        }

        // A library object's X/Y is its authored pivot, not metadata. Many
        // Vector 2 prefabs intentionally cancel that pivot with negative child
        // coordinates (for example manipulator_Charlie_1 is rooted at 680,190
        // while its primary image begins at -680,-190). Dropping this position
        // tears nested/grouped objects apart even though every sprite resolves.
        let localX = parseDouble(attribute("X", on: object)) ?? 0
        let localY = parseDouble(attribute("Y", on: object)) ?? 0
        let current = combinedContext(
            parent: context,
            localPositionX: localX,
            localPositionY: localY,
            matrixElement: firstElement(fromXPath: "./Properties/Static/Matrix", on: object)
        )
        var pieces: [Piece] = []
        for child in childElements(of: object) where child.name == "Content" {
            pieces.append(contentsOf: collectPieces(fromContent: child, context: current, baseURL: baseURL, depth: depth, choices: choices, strict: strict))
        }
        return pieces
    }

    private static func collectPieces(
        fromContent content: XMLElement,
        context: AffineContext,
        baseURL: URL,
        depth: Int,
        choices: ChoiceMap,
        strict: Bool = true
    ) -> [Piece] {
        // Dispatch table for child XML tags inside library Content. If a new
        // Vector 2 tag imports as a green box, add a case here or teach one of
        // the existing piece builders how to interpret it.
        var pieces: [Piece] = []
        for child in childElements(of: content) {
            let includePhantomVisualizers = baseURL.lastPathComponent == "phantoms.xml"
            if strict {
                guard shouldIncludeElement(child, choices: choices, includePhantomVisualizers: includePhantomVisualizers) else { continue }
            }
            switch child.name {
            case "Image", "Animation", "CustomAnimation":
                // Vector 2 places animated visuals through the same image
                // transform/layer contract. RoomWeaver only needs a static
                // editor preview here; keeping the original XML on the node
                // preserves the runtime animation when the level is exported.
                if let piece = imagePiece(from: child, context: context) {
                    pieces.append(piece)
                }
            case "UnityModel":
                if let piece = unityModelPiece(from: child, context: context) {
                    pieces.append(piece)
                }
            case "Object":
                pieces.append(contentsOf: collectPieces(from: child, context: context, baseURL: baseURL, depth: depth + 1, choices: choices, strict: strict))
            case "ObjectReference":
                pieces.append(contentsOf: collectReferencedPieces(from: child, context: context, baseURL: baseURL, depth: depth + 1, choices: choices, strict: strict))
            case "Trigger", "Area", "Platform", "Trapezoid":
                if let piece = simpleShapePiece(from: child, context: context) {
                    pieces.append(piece)
                }
            case "Spawn", "SoundSource", "Item", "Placeholder", "Sensor", "Lightning", "Waypoint":
                if let piece = simpleShapePiece(from: child, context: context) {
                    pieces.append(piece)
                }
            case "Comment":
                if let piece = commentPiece(from: child, context: context) {
                    pieces.append(piece)
                }
            default:
                break
            }
        }
        return pieces
    }

    private static func imagePiece(from element: XMLElement, context: AffineContext) -> Piece? {
        // Converts a library Image into a visual piece, preserving matrix basis
        // so rotated/mirrored art stays placed like the game.
        guard let className = attribute("ClassName", on: element) else { return nil }
        let rawX = parseDouble(attribute("X", on: element)) ?? 0
        let rawY = parseDouble(attribute("Y", on: element)) ?? 0
        let fallbackWidth = parseInteger(attribute("Width", on: element)) ?? 120
        let fallbackHeight = parseInteger(attribute("Height", on: element)) ?? 120
        let localTransform = imageTransform(from: element, x: Int(rawX.rounded()), y: Int(rawY.rounded()))
            ?? .init(x: Int(rawX.rounded()), y: Int(rawY.rounded()), width: fallbackWidth, height: fallbackHeight, rotation: 0)
        let localBasis = imageBasis(from: element, fallbackWidth: fallbackWidth, fallbackHeight: fallbackHeight, rotation: localTransform.rotation)
        let worldAnchor = context.point(x: Double(localTransform.x), y: Double(localTransform.y))
        let worldBasisX = context.vector(x: localBasis.xx, y: localBasis.xy)
        let worldBasisY = context.vector(x: localBasis.yx, y: localBasis.yy)
        let width = max(1, Int(hypot(worldBasisX.x, worldBasisX.y).rounded()))
        let height = max(1, Int(hypot(worldBasisY.x, worldBasisY.y).rounded()))
        let rotation = atan2(worldBasisX.y, worldBasisX.x) * 180 / .pi
        RoomWeaverDiagnostics.shared.layoutDebug(
            kind: "image",
            name: className,
            detail: "local=(\(Int(rawX.rounded())),\(Int(rawY.rounded())),\(fallbackWidth),\(fallbackHeight)) world=(\(Int(worldAnchor.x.rounded())),\(Int(worldAnchor.y.rounded())),\(width),\(height),r=\(formatDebug(rotation))) basisX=(\(formatDebug(worldBasisX.x)),\(formatDebug(worldBasisX.y))) basisY=(\(formatDebug(worldBasisY.x)),\(formatDebug(worldBasisY.y)))"
        )

        let tintColorHex = whiteSourceTintColor(for: className, element: element)
        return Piece(
            name: className,
            kind: .image,
            x: Int(worldAnchor.x.rounded()),
            y: Int(worldAnchor.y.rounded()),
            width: width,
            height: height,
            rotation: rotation,
            layer: attribute("Layer", on: element) ?? Vector2AssetCatalog.defaultLayerName(for: className),
            className: className,
            imagePath: Vector2AssetCatalog.imagePath(forClassName: className) ?? "",
            filename: "",
            tintColorHex: tintColorHex,
            mirrored: (worldBasisX.x * worldBasisY.y - worldBasisX.y * worldBasisY.x) < 0,
            basisXX: worldBasisX.x,
            basisXY: worldBasisX.y,
            basisYX: worldBasisY.x,
            basisYY: worldBasisY.y
        )
    }

    private static func whiteSourceTintColor(for className: String, element: XMLElement) -> String {
        // Some Vector 2 shadows are literally a white helper texture plus a
        // color. Tint only those white-source helpers; tinting all StartColor
        // images turns z2 gradients pink in the editor.
        let lowered = className.lowercased()
        guard lowered.contains(".v_white") else { return "" }
        return firstAttribute("Color", fromXPath: ["./Properties/Static/StartColor"], on: element) ?? ""
    }

    private static func unityModelPiece(from element: XMLElement, context: AffineContext) -> Piece? {
        // UnityModel is a marker, not directly drawable art. We represent it as
        // a bounded placeholder so advanced objects still show their footprint.
        let name = attribute("Name", on: element) ?? "UnityModel"
        let width = min(260, max(72, (parseInteger(attribute("Width", on: element)) ?? 1200) / 8))
        let height = min(260, max(72, (parseInteger(attribute("Height", on: element)) ?? 1200) / 8))
        let localX = parseDouble(attribute("X", on: element)) ?? 0
        let localY = parseDouble(attribute("Y", on: element)) ?? 0
        let world = context.point(x: localX, y: localY)
        return Piece(
            name: name,
            kind: .objectReference,
            x: Int(world.x.rounded()),
            y: Int(world.y.rounded()),
            width: width,
            height: height,
            rotation: 0,
            layer: attribute("Layer", on: element) ?? "Items",
            className: name,
            imagePath: "",
            filename: "__unitymodel__",
            tintColorHex: ""
        )
    }

    private static func shouldRasterizePlaceholderPieces(_ pieces: [Piece], filename: String) -> Bool {
        // Some Nekki editor helpers are not sprites at all: phantoms, UnityModel
        // markers, and comment-only stunts. Rasterize those so the browser and
        // load-back view never fall through to the useless green placeholder box.
        filename == "phantoms.xml" || pieces.allSatisfy { $0.imagePath.isEmpty }
    }

    private static func simpleShapePiece(from element: XMLElement, context: AffineContext) -> Piece? {
        // Shape pieces make trigger/area/platform/trapezoid children visible
        // inside expanded objects without pretending they are texture art.
        let width = parseInteger(attribute("Width", on: element)) ?? 100
        let height = parseInteger(attribute("Height", on: element)) ?? 100
        let tag = element.name ?? "Object"
        let localX = parseDouble(attribute("X", on: element)) ?? 0
        let localY = parseDouble(attribute("Y", on: element)) ?? 0
        let shapeContext = combinedContext(
            parent: context,
            localPositionX: localX,
            localPositionY: localY,
            matrixElement: firstElement(fromXPath: "./Properties/Static/Matrix", on: element)
        )
        let trapezoidType = tag == "Trapezoid" ? (parseInteger(attribute("Type", on: element)) ?? 1) : 0
        // CreateTrapezoid shifts Type 1 internally, then its point math shifts
        // the short edge back. Its final bounding rectangle still starts at the
        // original XML X/Y, so applying Width/2 here displaced nested slopes.
        let world = shapeContext.point(x: 0, y: 0)
        let basisX = shapeContext.vector(x: Double(width), y: 0)
        let basisY = shapeContext.vector(x: 0, y: Double(height))
        let worldWidth = max(1, Int(hypot(basisX.x, basisX.y).rounded()))
        let worldHeight = max(1, Int(hypot(basisY.x, basisY.y).rounded()))
        let rotation = atan2(basisX.y, basisX.x) * 180 / .pi
        let name = attribute("Name", on: element) ?? tag
        RoomWeaverDiagnostics.shared.layoutDebug(
            kind: "shape",
            name: name,
            detail: "local=(\(formatDebug(localX)),\(formatDebug(localY)),\(width),\(height)) world=(\(Int(world.x.rounded())),\(Int(world.y.rounded())),\(worldWidth),\(worldHeight),r=\(formatDebug(rotation))) basisX=(\(formatDebug(basisX.x)),\(formatDebug(basisX.y))) basisY=(\(formatDebug(basisY.x)),\(formatDebug(basisY.y)))"
        )
        return Piece(
            name: name,
            kind: kind(for: tag),
            x: Int(world.x.rounded()),
            y: Int(world.y.rounded()),
            width: worldWidth,
            height: worldHeight,
            rotation: rotation + Double(parseInteger(attribute("Rotation", on: element)) ?? 0),
            layer: attribute("Layer", on: element) ?? "",
            className: "",
            imagePath: "",
            filename: "",
            tintColorHex: "",
            basisXX: basisX.x,
            basisXY: basisX.y,
            basisYX: basisY.x,
            basisYY: basisY.y,
            trapezoidType: trapezoidType
        )
    }

    private static func commentPiece(from element: XMLElement, context: AffineContext) -> Piece? {
        // Nekki uses Comment nodes as labels/visual hints in library data.
        // They are useful for previews but must never become exported gameplay.
        let width = parseInteger(attribute("Width", on: element)) ?? 100
        let height = parseInteger(attribute("Height", on: element)) ?? 100
        let localX = parseDouble(attribute("X", on: element)) ?? 0
        let localY = parseDouble(attribute("Y", on: element)) ?? 0
        let commentContext = combinedContext(
            parent: context,
            localPositionX: localX,
            localPositionY: localY,
            matrixElement: firstElement(fromXPath: "./Properties/Static/Matrix", on: element)
        )
        let world = commentContext.point(x: 0, y: 0)
        let basisX = commentContext.vector(x: Double(width), y: 0)
        let basisY = commentContext.vector(x: 0, y: Double(height))
        let worldWidth = max(1, Int(hypot(basisX.x, basisX.y).rounded()))
        let worldHeight = max(1, Int(hypot(basisY.x, basisY.y).rounded()))
        let rotation = atan2(basisX.y, basisX.x) * 180 / .pi
        return Piece(
            name: attribute("Text", on: element) ?? attribute("Name", on: element) ?? "Comment",
            kind: .comment,
            x: Int(world.x.rounded()),
            y: Int(world.y.rounded()),
            width: worldWidth,
            height: worldHeight,
            rotation: rotation,
            layer: attribute("Layer", on: element) ?? "Debug",
            className: "",
            imagePath: "",
            filename: "__comment__",
            tintColorHex: "",
            basisXX: basisX.x,
            basisXY: basisX.y,
            basisYX: basisY.x,
            basisYY: basisY.y
        )
    }

    private static func collectReferencedPieces(
        from element: XMLElement,
        context: AffineContext,
        baseURL: URL,
        depth: Int,
        choices: ChoiceMap,
        strict: Bool = true
    ) -> [Piece] {
        // Handles nested ObjectReference nodes. This is what lets a complex
        // object like WallJump/phantoms pull in pieces from another XML file.
        guard let name = attribute("Name", on: element),
              !name.isEmpty,
              let filename = referenceFilename(for: name, element: element, baseURL: baseURL) else {
            return []
        }

        let referencedURL = Vector2AssetCatalog.libraryURL(named: filename, relativeTo: baseURL)
        let referenceChoices = mergedChoices(choices, activeChoices(for: element))
        guard let object = resolvedLibraryObject(named: name, in: referencedURL, settings: element, choices: referenceChoices) else {
            RoomWeaverDiagnostics.shared.libraryResolveFailed(
                name: name,
                filename: filename,
                reason: "nested reference object missing or library XML unreadable",
                context: "path=\(referencedURL.path)"
            )
            return []
        }

        let localX = parseDouble(attribute("X", on: element)) ?? 0
        let localY = parseDouble(attribute("Y", on: element)) ?? 0
        let referenceContext = combinedContext(
            parent: context,
            localPositionX: localX,
            localPositionY: localY,
            matrixElement: firstElement(fromXPath: "./Properties/Static/Matrix", on: element)
        )
        var pieces = collectLibraryInstancePieces(
            from: object,
            context: referenceContext,
            baseURL: referencedURL,
            depth: depth,
            choices: referenceChoices,
            strict: strict
        )
        if pieces.isEmpty && strict {
            RoomWeaverDiagnostics.shared.libraryStrictRetry(
                name: name,
                filename: filename,
                context: "mode=NestedReference \(choiceSummary(referenceChoices))"
            )
            pieces = collectLibraryInstancePieces(
                from: object,
                context: referenceContext,
                baseURL: referencedURL,
                depth: depth,
                choices: referenceChoices,
                strict: false
            )
            if !pieces.isEmpty {
                RoomWeaverDiagnostics.shared.libraryResolvedAfterLooseRetry(
                    name: name,
                    filename: filename,
                    summary: pieceSummary(pieces)
                )
            }
        }
        if pieces.isEmpty {
            RoomWeaverDiagnostics.shared.libraryResolveFailed(
                name: name,
                filename: filename,
                reason: "nested reference produced 0 pieces",
                context: "strict=\(strict) \(choiceSummary(referenceChoices))"
            )
        }
        return pieces
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

    private static func resolvedLibraryObject(named name: String, in file: URL, settings: XMLElement?, choices: ChoiceMap) -> XMLElement? {
        // Returns a cloned XML object with variable substitution applied. We
        // clone because applying variables mutates attributes recursively.
        guard let object = rawLibraryObject(named: name, in: file),
              let clone = object.copy() as? XMLElement else {
            return nil
        }

        let values = resolvedVariables(for: object, settings: settings, choices: choices)
        if !values.isEmpty {
            applyVariableSubstitution(to: clone, values: values)
        }
        return clone
    }

    private static func rawLibraryObject(named name: String, in file: URL) -> XMLElement? {
        switch cachedLibraryFile(at: file) {
        case .failure(let reason):
            RoomWeaverDiagnostics.shared.libraryResolveFailed(
                name: name,
                filename: file.lastPathComponent,
                reason: reason,
                context: "path=\(file.path)"
            )
            return nil
        case .index(let index):
            if let object = index.directObjects[name] {
                return object
            }
            if let object = index.allObjects[name] {
                RoomWeaverDiagnostics.shared.libraryResolvedAfterLooseRetry(
                    name: name,
                    filename: file.lastPathComponent,
                    summary: "recursive nested object lookup"
                )
                return object
            }
            RoomWeaverDiagnostics.shared.libraryResolveFailed(
                name: name,
                filename: file.lastPathComponent,
                reason: "object name not found in readable library",
                context: "path=\(file.path) sample=\(index.sampleNames)"
            )
            return nil
        }
    }

    private static func cachedLibraryFile(at file: URL) -> LibraryFileResult {
        let normalizedURL = file.standardizedFileURL
        let key = normalizedURL.path
        let values = try? normalizedURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let version = LibraryFileVersion(size: values?.fileSize ?? -1, modifiedAt: values?.contentModificationDate)

        libraryFileCacheLock.lock()
        defer { libraryFileCacheLock.unlock() }
        if let cached = libraryFileCache[key], cached.version == version {
            return cached.result
        }

        let document: XMLDocument
        do {
            document = try XMLDocument(contentsOf: normalizedURL)
        } catch {
            guard let xml = try? String(contentsOf: normalizedURL, encoding: .utf8),
                  let fallback = try? XMLDocument(xmlString: xml) else {
                let result = LibraryFileResult.failure("XML read/parse failed: \(error.localizedDescription)")
                libraryFileCache[key] = .init(version: version, result: result)
                return result
            }
            document = fallback
        }

        let root = document.rootElement()
        guard let objects = childElements(of: root ?? XMLElement(name: "Root")).first(where: {
            ($0.localName ?? $0.name ?? "") == "Objects"
        }) ?? root?.elements(forName: "Objects").first else {
            let result = LibraryFileResult.failure("library XML has no Objects container")
            libraryFileCache[key] = .init(version: version, result: result)
            return result
        }

        var direct: [String: XMLElement] = [:]
        for object in childElements(of: objects) where (object.localName ?? object.name ?? "") == "Object" {
            if let name = attribute("Name", on: object), direct[name] == nil {
                direct[name] = object
            }
        }
        var all: [String: XMLElement] = [:]
        indexLibraryObjects(in: objects, into: &all)
        let index = LibraryFileIndex(
            directObjects: direct,
            allObjects: all,
            sampleNames: direct.keys.sorted().prefix(8).joined(separator: ",")
        )
        let result = LibraryFileResult.index(index)
        libraryFileCache[key] = .init(version: version, result: result)
        return result
    }

    private static func indexLibraryObjects(in element: XMLElement, into index: inout [String: XMLElement]) {
        for child in childElements(of: element) {
            if (child.localName ?? child.name ?? "") == "Object",
               let name = attribute("Name", on: child),
               index[name] == nil {
                index[name] = child
            }
            indexLibraryObjects(in: child, into: &index)
        }
    }

    private static func dynamicXML(from object: XMLElement) -> String {
        guard let properties = firstElement(fromXPath: "./Properties", on: object) else { return "" }
        return childElements(of: properties)
            .filter { $0.name == "Dynamic" }
            .map { $0.xmlString(options: .nodeCompactEmptyElement) }
            .joined(separator: "\n")
    }

    private static func resolvedDynamics(
        in object: XMLElement,
        baseURL: URL,
        choices: ChoiceMap
    ) -> (count: Int, owners: [String]) {
        let maximumReferenceDepth = 64
        let rootOwner = attribute("Name", on: object) ?? ""
        var count = 0
        var owners: [String] = []
        // This is an active recursion stack, not a global dedupe set. Repeated
        // instances of the same moving prefab are separate dynamics and must
        // each be counted; only an actual library-reference cycle is skipped.
        var activeReferences: Set<String> = []

        func isStationaryAnimatedService(_ name: String) -> Bool {
            let folded = name.lowercased()
            // These assemblies animate internally but are not movable room
            // geometry. Their lamp pulses, door panels, and trap effects must
            // not promote the placed reference into a DYNAMIC editor object.
            return folded.contains("swarmhole")
                || folded.contains("lamp")
                || folded.contains("light")
                || folded.contains("door")
        }

        func visit(_ element: XMLElement, owner: String, sourceURL: URL, depth: Int, currentChoices: ChoiceMap) {
            guard depth < maximumReferenceDepth else { return }
            let elementName = element.localName ?? element.name ?? ""
            let nextOwner: String
            if ["Object", "ObjectReference", "Image", "Shape"].contains(elementName) {
                nextOwner = attribute("Name", on: element)
                    ?? attribute("Class", on: element)
                    ?? owner
            } else {
                nextOwner = owner
            }

            // A nested dynamic is an editor-movable assembly only when its
            // owning object directly owns physical geometry. Looking through
            // every descendant promoted controller wrappers such as
            // ActiveDoorWithLoss merely because a referenced door eventually
            // contains a platform. Real moving image assemblies and lifts own
            // spatial intervals on their own geometry and qualify here;
            // trapezoid collision slopes intentionally do not.
            let owningObject = element.parent as? XMLElement
            let ownsPhysicalGeometry: Bool = {
                guard let owningObject else { return false }
                let ownerTag = owningObject.localName ?? owningObject.name ?? ""
                return ownerTag == "Image"
                    || ownerTag == "Animation"
                    || ownerTag == "CustomAnimation"
                    || ownerTag == "Platform"
                    || ownerTag == "Collision"
                    || firstElement(fromXPath: "./Content/Image", on: owningObject) != nil
                    || firstElement(fromXPath: "./Content/Animation", on: owningObject) != nil
                    || firstElement(fromXPath: "./Content/CustomAnimation", on: owningObject) != nil
                    || firstElement(fromXPath: "./Content/Platform", on: owningObject) != nil
                    || firstElement(fromXPath: "./Content/Collision", on: owningObject) != nil
            }()
            if elementName == "Properties", ownsPhysicalGeometry {
                let localCount = childElements(of: element).filter { child in
                    guard (child.localName ?? child.name ?? "") == "Dynamic" else { return false }
                    // The badge represents spatially dynamic scene geometry.
                    // Texture frames, colors, particles, and lamps can animate
                    // without the owning object moving on the canvas.
                    // FoundationXML's relative XPath can escape the intended
                    // subtree for nodes retained from cached documents. Read
                    // this exact block instead; ActiveDoorWithLoss contains
                    // only ActivationInterval and must not become a dynamic
                    // canvas assembly because a sibling door visual moves.
                    let block = child.xmlString(options: .nodeCompactEmptyElement)
                    return block.contains("<MoveInterval")
                        || block.contains("<RotationInterval")
                        || block.contains("<SizeInterval")
                }.count
                if localCount > 0 {
                    count += localCount
                    let label = nextOwner.isEmpty ? "unnamed" : nextOwner
                    if !owners.contains(label) {
                        owners.append(label)
                    }
                }
            }

            // Nested library references are where most doors, manipulators,
            // trap assemblies, and grouped room dynamics actually live.
            if elementName == "ObjectReference",
               let referenceName = attribute("Name", on: element),
               !referenceName.isEmpty,
               let filename = referenceFilename(for: referenceName, element: element, baseURL: sourceURL) {
                // SwarmHole contains animated/moving implementation pieces, but the
                // placed hole itself is a stationary trap endpoint in Vector 2. Do
                // not promote those internal intervals into an editor DYNAMIC badge.
                if isStationaryAnimatedService(referenceName) {
                    return
                }
                let referencedURL = Vector2AssetCatalog.libraryURL(named: filename, relativeTo: sourceURL)
                let referenceChoices = mergedChoices(currentChoices, activeChoices(for: element))
                let referenceKey = "\(referencedURL.standardizedFileURL.path)|\(referenceName)|\(choiceSummary(referenceChoices))"
                if !activeReferences.contains(referenceKey),
                   let referencedObject = resolvedLibraryObject(
                       named: referenceName,
                       in: referencedURL,
                       settings: element,
                       choices: referenceChoices
                   ) {
                    activeReferences.insert(referenceKey)
                    visit(
                        referencedObject,
                        owner: referenceName,
                        sourceURL: referencedURL,
                        depth: depth + 1,
                        currentChoices: referenceChoices
                    )
                    activeReferences.remove(referenceKey)
                }
            }

            for child in childElements(of: element) {
                visit(child, owner: nextOwner, sourceURL: sourceURL, depth: depth + 1, currentChoices: currentChoices)
            }
        }

        if !isStationaryAnimatedService(rootOwner) {
            visit(
                object,
                owner: rootOwner,
                sourceURL: baseURL,
                depth: 0,
                currentChoices: choices
            )
        }
        return (count, owners)
    }

    private static func makePreviewPieces(
        from pieces: [Piece],
        bounds: (centerX: Int, centerY: Int, width: Int, height: Int)
    ) -> [LevelNode.PreviewPiece] {
        // Converts absolute library pieces into parent-relative preview pieces.
        // The canvas can then resize/move the parent while keeping children
        // visually attached.
        pieces
            .filter { !$0.imagePath.isEmpty }
            .map { piece in
                let hasBasis = piece.basisXX != nil
                    && piece.basisXY != nil
                    && piece.basisYX != nil
                    && piece.basisYY != nil
                return LevelNode.PreviewPiece(
                    imagePath: piece.imagePath,
                    centerX: hasBasis
                        ? Double(piece.x - bounds.centerX)
                        : Double(piece.x + piece.width / 2 - bounds.centerX),
                    centerY: hasBasis
                        ? Double(piece.y - bounds.centerY)
                        : Double(piece.y + piece.height / 2 - bounds.centerY),
                    width: Double(piece.width),
                    height: Double(piece.height),
                    rotation: piece.rotation,
                    mirrored: piece.mirrored,
                    basisXX: piece.basisXX,
                    basisXY: piece.basisXY,
                    basisYX: piece.basisYX,
                    basisYY: piece.basisYY,
                    tintColorHex: piece.tintColorHex,
                    sortingLayer: piece.layer.isEmpty ? "Default" : piece.layer
                )
            }
    }

    private static func rasterizedPreviewPath(
        for asset: TextureAsset,
        pieces: [Piece],
        bounds: (centerX: Int, centerY: Int, width: Int, height: Int),
        includeShapePlaceholders: Bool = false
    ) -> String? {
        // Bakes complex library/phantom visuals into a temporary PNG for asset
        // browser cards and single-image canvas previews. This is cache-only;
        // exported XML still uses the original object reference.
        let drawablePieces = pieces.enumerated()
            .filter {
                !$0.element.imagePath.isEmpty
                    || (includeShapePlaceholders && ($0.element.filename == "__comment__" || $0.element.filename == "__unitymodel__" || $0.element.kind.isEditorShape || $0.element.kind == .objectReference))
            }
            .sorted { lhs, rhs in
                let lhsLayer = Vector2SortingLayers.index(of: lhs.element.layer)
                let rhsLayer = Vector2SortingLayers.index(of: rhs.element.layer)
                if lhsLayer == rhsLayer {
                    // Unity preserves sibling/XML order inside one sorting
                    // layer. Alphabetical sorting made pieces such as the
                    // room201 wall skin draw over its chain.
                    return lhs.offset < rhs.offset
                }
                return lhsLayer < rhsLayer
            }
            .map(\.element)

        guard !drawablePieces.isEmpty else {
            return nil
        }

        let cacheRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Vector2LevelEditorLibraryPreviews", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)

        let namePrefix = asset.name
            .replacingOccurrences(of: #"[^A-Za-z0-9_-]"#, with: "_", options: .regularExpression)
            .prefix(48)
        let cacheMode = includeShapePlaceholders ? "shapes" : "images"
        let pieceSignature = drawablePieces.map { piece in
            [
                piece.name,
                piece.kind.rawValue,
                String(piece.x),
                String(piece.y),
                String(piece.width),
                String(piece.height),
                String(format: "%.4f", piece.rotation),
                piece.layer,
                piece.className,
                piece.imagePath,
                piece.filename,
                piece.tintColorHex,
                piece.mirrored ? "1" : "0",
                piece.basisXX.map { String(format: "%.4f", $0) } ?? "",
                piece.basisXY.map { String(format: "%.4f", $0) } ?? "",
                piece.basisYX.map { String(format: "%.4f", $0) } ?? "",
                piece.basisYY.map { String(format: "%.4f", $0) } ?? ""
            ].joined(separator: "|")
        }.joined(separator: "||")
        let cacheKey = [
            asset.filePath,
            previewCacheVersion,
            cacheMode,
            "\(bounds.centerX),\(bounds.centerY),\(bounds.width),\(bounds.height)",
            pieceSignature
        ].joined(separator: "::")
        let outputURL = cacheRoot.appendingPathComponent("\(namePrefix)_\(stableHash(cacheKey)).png")
        if FileManager.default.fileExists(atPath: outputURL.path) {
            return outputURL.path
        }

        // Large assemblies need enough detail to stay readable when zoomed in.
        // Leave smaller previews alone so they do not waste extra memory.
        let maxSide: CGFloat = 4096
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

        for piece in drawablePieces {
            let graphics = NSGraphicsContext.current
            graphics?.saveGraphicsState()
            if let sprite = CachedImageStore.shared.image(at: piece.imagePath),
               let basisXX = piece.basisXX,
               let basisXY = piece.basisXY,
               let basisYX = piece.basisYX,
               let basisYY = piece.basisYY,
               sprite.size.width > 0,
               sprite.size.height > 0 {
                let scaledBasisXX = CGFloat(basisXX) * scale
                let scaledBasisXY = CGFloat(basisXY) * scale
                let scaledBasisYX = CGFloat(basisYX) * scale
                let scaledBasisYY = CGFloat(basisYY) * scale
                let topLeftX = (CGFloat(piece.x) - minX) * scale
                let topLeftY = (maxY - CGFloat(piece.y)) * scale
                let bottomLeft = NSPoint(
                    x: topLeftX + scaledBasisYX,
                    y: topLeftY - scaledBasisYY
                )
                let transform = NSAffineTransform()
                transform.transformStruct = NSAffineTransformStruct(
                    m11: scaledBasisXX / sprite.size.width,
                    m12: -scaledBasisXY / sprite.size.width,
                    m21: -scaledBasisYX / sprite.size.height,
                    m22: scaledBasisYY / sprite.size.height,
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
                applyTint(piece.tintColorHex, in: NSRect(origin: .zero, size: sprite.size))
            } else if let sprite = CachedImageStore.shared.image(at: piece.imagePath) {
                let drawSize = NSSize(
                    width: max(1, CGFloat(piece.width) * scale),
                    height: max(1, CGFloat(piece.height) * scale)
                )
                let anchor = NSPoint(
                    x: (CGFloat(piece.x) - minX) * scale,
                    y: (maxY - CGFloat(piece.y + piece.height)) * scale
                )
                let transform = NSAffineTransform()
                transform.translateX(by: anchor.x, yBy: anchor.y)
                transform.rotate(byDegrees: -piece.rotation)
                if piece.mirrored {
                    transform.scaleX(by: -1, yBy: 1)
                    transform.translateX(by: -drawSize.width, yBy: 0)
                }
                transform.concat()
                sprite.draw(
                    in: NSRect(origin: .zero, size: drawSize),
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1,
                    respectFlipped: true,
                    hints: [.interpolation: NSImageInterpolation.high]
                )
                applyTint(piece.tintColorHex, in: NSRect(origin: .zero, size: drawSize))
            } else {
                let drawSize = NSSize(
                    width: max(1, CGFloat(piece.width) * scale),
                    height: max(1, CGFloat(piece.height) * scale)
                )
                let anchor = NSPoint(
                    x: (CGFloat(piece.x) - minX) * scale,
                    y: (maxY - CGFloat(piece.y + piece.height)) * scale
                )
                let transform = NSAffineTransform()
                transform.translateX(by: anchor.x, yBy: anchor.y)
                transform.rotate(byDegrees: -piece.rotation)
                transform.concat()

                let rect = NSRect(origin: .zero, size: drawSize)
                previewFillColor(for: piece.kind).setFill()
                rect.fill()
                previewStrokeColor(for: piece.kind).setStroke()
                NSBezierPath(rect: rect).stroke()

                if piece.filename == "__comment__", drawSize.width > 20, drawSize.height > 12 {
                    let paragraph = NSMutableParagraphStyle()
                    paragraph.lineBreakMode = .byTruncatingTail
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: NSFont.systemFont(ofSize: max(7, min(13, drawSize.height * 0.16)), weight: .medium),
                        .foregroundColor: NSColor.black.withAlphaComponent(0.72),
                        .paragraphStyle: paragraph
                    ]
                    NSString(string: piece.name).draw(
                        in: rect.insetBy(dx: 4, dy: 4),
                        withAttributes: attrs
                    )
                }
            }
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

    private static func applyTint(_ rgbaHex: String, in rect: NSRect) {
        guard let color = NSColor(rgbaHex: rgbaHex), color.alphaComponent > 0 else { return }
        color.setFill()
        rect.fill(using: .sourceAtop)
    }

    private static func previewFillColor(for kind: LevelNode.Kind) -> NSColor {
        // Placeholder colors match the canvas overlay language: triggers yellow,
        // areas red, platforms blue, generic object refs green.
        switch kind {
        case .trigger:
            return NSColor(calibratedRed: 1, green: 1, blue: 0, alpha: 0.25)
        case .area:
            return NSColor(calibratedRed: 1, green: 0, blue: 0, alpha: 0.25)
        case .platform, .trapezoid:
            return NSColor(calibratedRed: 0, green: 0, blue: 1, alpha: 0.25)
        default:
            return NSColor(calibratedRed: 0.55, green: 1, blue: 0.68, alpha: 0.42)
        }
    }

    private static func previewStrokeColor(for kind: LevelNode.Kind) -> NSColor {
        // Stroke colors pair with `previewFillColor` so baked placeholder cards
        // read like the editor canvas.
        switch kind {
        case .trigger:
            return NSColor(calibratedRed: 0.81, green: 0.49, blue: 0.08, alpha: 1)
        case .area:
            return NSColor(calibratedRed: 0.5, green: 0, blue: 0, alpha: 1)
        case .platform, .trapezoid:
            return NSColor(calibratedRed: 0, green: 0, blue: 1, alpha: 1)
        default:
            return NSColor(calibratedRed: 0.16, green: 0.55, blue: 0.28, alpha: 1)
        }
    }

    private static func boundingBox(for pieces: [Piece]) -> (centerX: Int, centerY: Int, width: Int, height: Int) {
        // Bounds all visual pieces including rotated/affine corners. This fixes
        // the "phantom stretched into Narnia" class of bugs by using true
        // geometry instead of raw parent size guesses.
        let corners = pieces.flatMap(\.corners)
        let minX = Int((corners.map(\.x).min() ?? 0).rounded(.down))
        let maxX = Int((corners.map(\.x).max() ?? 0).rounded(.up))
        let minY = Int((corners.map(\.y).min() ?? 0).rounded(.down))
        let maxY = Int((corners.map(\.y).max() ?? 0).rounded(.up))
        return ((minX + maxX) / 2, (minY + maxY) / 2, maxX - minX, maxY - minY)
    }

    private static func kind(for tag: String) -> LevelNode.Kind {
        // Maps Vector 2 XML tags to editor node kinds. Unknown tags stay as
        // object references so we do not accidentally export the wrong schema.
        switch tag {
        case "Trigger": return .trigger
        case "Area", "Sensor": return .area
        case "Platform": return .platform
        case "Trapezoid": return .trapezoid
        case "Waypoint", "Spawn", "SoundSource", "Placeholder", "Item", "Lightning": return .waypoint
        default: return .objectReference
        }
    }

    private static func parseInteger(_ raw: String?) -> Int? {
        // Safe numeric parser used after variable substitution. Values still
        // containing unresolved XML expressions are ignored.
        guard let raw, !raw.isEmpty, !raw.contains("~"), !raw.contains("{") else { return nil }
        return Int((Double(raw.replacingOccurrences(of: ",", with: ".")) ?? 0).rounded())
    }

    private static func parseDouble(_ raw: String?) -> Double? {
        // Same as `parseInteger`, but preserves decimal precision for matrices.
        guard let raw, !raw.isEmpty, !raw.contains("~"), !raw.contains("{") else { return nil }
        return Double(raw.replacingOccurrences(of: ",", with: "."))
    }

    private static func formatDebug(_ value: Double) -> String {
        if abs(value.rounded() - value) < 0.0001 {
            return String(Int(value.rounded()))
        }
        return String(format: "%.3f", value)
    }

    private static func imageTransform(from element: XMLElement, x: Int, y: Int) -> LevelNode.Transform? {
        // Reads a Vector 2 Matrix into the editor's center-size-rotation model.
        // This is import-only; export writes the XML transform contract back out
        // through `LevelDocument.exportedXML()`.
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

        // Scene import finishes matrix placement at X + Tx, Y + Ty
        // in XML-space. Do not add half the image size here or visuals drift.
        let centerX = Double(x) + tx
        let centerY = Double(y) + ty
        return .init(
            x: Int(centerX.rounded()),
            y: Int(centerY.rounded()),
            width: max(1, Int(hypot(a, b).rounded())),
            height: max(1, Int(hypot(c, d).rounded())),
            rotation: atan2(b, a) * 180 / .pi
        )
    }

    private static func imageBasis(
        from element: XMLElement,
        fallbackWidth: Int,
        fallbackHeight: Int,
        rotation: Double
    ) -> (xx: Double, xy: Double, yx: Double, yy: Double) {
        // Returns the affine basis for a sprite. When Matrix is missing, rebuild
        // the basis from editor width/height/rotation so preview rendering still
        // has enough geometry.
        if let matrixElement = firstElement(fromXPath: "./Properties/Static/Matrix", on: element),
           let a = parseDouble(attribute("A", on: matrixElement)),
           let b = parseDouble(attribute("B", on: matrixElement)),
           let c = parseDouble(attribute("C", on: matrixElement)),
           let d = parseDouble(attribute("D", on: matrixElement)) {
            return (a, b, c, d)
        }

        let radians = rotation * .pi / 180
        let cosine = Foundation.cos(radians)
        let sine = Foundation.sin(radians)
        let width = Double(fallbackWidth)
        let height = Double(fallbackHeight)
        return (
            width * cosine,
            -width * sine,
            height * sine,
            height * cosine
        )
    }

    private static func combinedContext(
        parent: AffineContext,
        localPositionX: Double,
        localPositionY: Double,
        matrixElement: XMLElement?
    ) -> AffineContext {
        // Composes nested library object transforms. This is the core math that
        // keeps child triggers/platforms attached to parent phantoms and prefabs.
        let tx = parseDouble(matrixElement.flatMap { attribute("Tx", on: $0) }) ?? 0
        let ty = parseDouble(matrixElement.flatMap { attribute("Ty", on: $0) }) ?? 0
        let localBasisXX = parseDouble(matrixElement.flatMap { attribute("A", on: $0) }) ?? 1
        let localBasisXY = parseDouble(matrixElement.flatMap { attribute("B", on: $0) }) ?? 0
        let localBasisYX = parseDouble(matrixElement.flatMap { attribute("C", on: $0) }) ?? 0
        let localBasisYY = parseDouble(matrixElement.flatMap { attribute("D", on: $0) }) ?? 1
        let local = AffineContext(
            x: localPositionX + tx,
            y: localPositionY + ty,
            basisXX: localBasisXX,
            basisXY: localBasisXY,
            basisYX: localBasisYX,
            basisYY: localBasisYY
        )
        return AffineContext(
            x: parent.x + local.x * parent.basisXX + local.y * parent.basisYX,
            y: parent.y + local.x * parent.basisXY + local.y * parent.basisYY,
            basisXX: parent.basisXX * local.basisXX + parent.basisYX * local.basisXY,
            basisXY: parent.basisXY * local.basisXX + parent.basisYY * local.basisXY,
            basisYX: parent.basisXX * local.basisYX + parent.basisYX * local.basisYY,
            basisYY: parent.basisXY * local.basisYX + parent.basisYY * local.basisYY
        )
    }

    private static func placedReferenceContext(
        originX: Int,
        originY: Int,
        settings: XMLElement?,
        rotation: Double
    ) -> AffineContext {
        let referenceName = settings.flatMap { attribute("Name", on: $0) } ?? "-"
        if let matrixElement = settings.flatMap({ firstElement(fromXPath: "./Properties/Static/Matrix", on: $0) }) {
            let context = combinedContext(
                parent: .identity,
                localPositionX: Double(originX),
                localPositionY: Double(originY),
                matrixElement: matrixElement
            )
            RoomWeaverDiagnostics.shared.layoutDebug(
                kind: "reference",
                name: referenceName,
                detail: "origin=(\(originX),\(originY)) matrix=A\(formatDebug(context.basisXX)) B\(formatDebug(context.basisXY)) C\(formatDebug(context.basisYX)) D\(formatDebug(context.basisYY)) offset=(\(formatDebug(context.x)),\(formatDebug(context.y)))"
            )
            return context
        }

        guard abs(rotation) > 0.0001 else {
            return combinedContext(
                parent: .identity,
                localPositionX: Double(originX),
                localPositionY: Double(originY),
                matrixElement: nil
            )
        }

        let radians = rotation * .pi / 180
        let context = AffineContext(
            x: Double(originX),
            y: Double(originY),
            basisXX: Foundation.cos(radians),
            basisXY: -Foundation.sin(radians),
            basisYX: Foundation.sin(radians),
            basisYY: Foundation.cos(radians)
        )
        RoomWeaverDiagnostics.shared.layoutDebug(
            kind: "reference",
            name: referenceName,
            detail: "origin=(\(originX),\(originY)) rotation=\(formatDebug(rotation))"
        )
        return context
    }

    private static func imageMirrored(from element: XMLElement) -> Bool {
        // Negative matrix determinant means the sprite is mirrored. The canvas
        // needs this so flipped Unity/XML sprites do not appear backwards.
        guard let matrixElement = firstElement(fromXPath: "./Properties/Static/Matrix", on: element),
              let a = parseDouble(attribute("A", on: matrixElement)),
              let b = parseDouble(attribute("B", on: matrixElement)),
              let c = parseDouble(attribute("C", on: matrixElement)),
              let d = parseDouble(attribute("D", on: matrixElement)) else {
            return false
        }
        return (a * d - b * c) < 0
    }

    static func firstElement(fromXPath xpath: String, on element: XMLElement) -> XMLElement? {
        // Small XML helper to keep XPath call sites readable.
        (try? element.nodes(forXPath: xpath).first) as? XMLElement
    }

    private static func firstAttribute(_ attributeName: String, fromXPath xpaths: [String], on element: XMLElement) -> String? {
        for xpath in xpaths {
            if let target = firstElement(fromXPath: xpath, on: element),
               let value = attribute(attributeName, on: target),
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
        }
        return nil
    }

    private static func stableHash(_ text: String) -> String {
        // Stable non-cryptographic cache key. Do not use Swift `hashValue`;
        // Swift intentionally randomizes it between launches.
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    private static func phantomCandidates(for name: String) -> [String] {
        // Bridges editor prefab names to phantoms.xml names. Nekki uses several
        // naming dialects, so this tries exact, direction-stripped, and known
        // aliases before giving up.
        let baseName = name
            .replacingOccurrences(of: #" \([^)]*\)"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var candidates: [String] = []

        if baseName.localizedCaseInsensitiveContains("Blackball") {
            if baseName.localizedCaseInsensitiveContains("High") {
                candidates.append("High")
            } else if baseName.localizedCaseInsensitiveContains("Medium") {
                candidates.append("Medium")
            } else if baseName.localizedCaseInsensitiveContains("Low") {
                candidates.append("Low")
            } else if baseName.localizedCaseInsensitiveContains("Hurdle") {
                candidates.append("Ball_hurdle")
            } else if baseName.localizedCaseInsensitiveContains("Short") {
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

    static func childElements(of element: XMLElement) -> [XMLElement] {
        // Foundation XML exposes children as XMLNode; this keeps callers typed.
        (element.children ?? []).compactMap { $0 as? XMLElement }
    }

    static func attribute(_ name: String, on element: XMLElement) -> String? {
        // Typed wrapper around Foundation's attribute lookup.
        element.attribute(forName: name)?.stringValue
    }
}

private extension NSColor {
    convenience init?(rgbaHex: String) {
        let cleaned = rgbaHex
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        guard cleaned.count == 8, let value = UInt32(cleaned, radix: 16) else {
            return nil
        }
        let red = CGFloat((value >> 24) & 0xFF) / 255
        let green = CGFloat((value >> 16) & 0xFF) / 255
        let blue = CGFloat((value >> 8) & 0xFF) / 255
        let alpha = CGFloat(value & 0xFF) / 255
        self.init(calibratedRed: red, green: green, blue: blue, alpha: alpha)
    }
}
