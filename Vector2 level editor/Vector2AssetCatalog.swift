//
//  Vector2AssetCatalog.swift
//  Vector2 level editor
//
//  Asset browser and Vector 2 asset lookup.
//
//  Finds game and project assets, then groups them for the asset browser.
//

import SwiftUI
import AppKit
import Foundation

struct TextureAsset: Identifiable, Equatable {
    enum Kind: String, Equatable {
        case texture = "Texture"
        case libraryObject = "Library"
        case prefab = "Prefab"
    }

    let id = UUID()
    let group: String
    let kind: Kind
    let category: String
    let name: String
    let className: String
    let filePath: String
    let defaultLayer: String
    var libraryObjectName: String = ""
    var libraryOverrides: [String: String] = [:]
    var libraryVariantRootName: String = ""
    var obstaclePackagePath: String = ""

    var editorCanvasSize: (width: Int, height: Int) {
        // Placement size for raw textures. Large textures are capped so dragging
        // them into the editor does not create impossible-to-select monsters.
        guard let image = CachedImageStore.shared.image(at: filePath), image.size.width > 0, image.size.height > 0 else {
            return (220, 120)
        }

        let maxSide: CGFloat = 520
        let scale = min(1, maxSide / max(image.size.width, image.size.height))
        return (
            max(24, Int((image.size.width * scale).rounded())),
            max(24, Int((image.size.height * scale).rounded()))
        )
    }

    var nativeCanvasSize: (width: Int, height: Int) {
        // True pixel size used when we need exact image dimensions.
        guard let image = CachedImageStore.shared.image(at: filePath), image.size.width > 0, image.size.height > 0 else {
            return editorCanvasSize
        }

        return (
            max(1, Int(image.size.width.rounded())),
            max(1, Int(image.size.height.rounded()))
        )
    }

    var isCameraRelated: Bool {
        // Used to auto-select the camera tool when placing camera/zoom assets.
        let text = "\(group) \(category) \(name) \(className) \(filePath)".lowercased()
        return text.contains("camera") || text.contains("zoom")
    }
}

/// Asset browser grouping row/category.
struct TextureCategory: Identifiable, Equatable {
    var id: String { "\(group)/\(name)" }
    let group: String
    let name: String
    let assets: [TextureAsset]
}

/// Vector 2 sorting layer order used for editor draw order.
///
/// This list mirrors game-side expectations enough for layering previews. If an
/// object appears in front/behind incorrectly, check this order before touching
/// exporter logic.
enum Vector2SortingLayers {
    static let all = [
        "BgFurther",
        "BgVeryVeryFar",
        "BgVeryFar",
        "BgFar",
        "BgMiddle",
        "BgClose",
        "BgVeryClose",
        "Wall",
        "CAperture",
        "CApertureAdd",
        "CPanels",
        "CPanelsAdd",
        "CDecals",
        "CDecalsAdd",
        "CQuestDecals",
        "CQuestDecalsAdd",
        "HoloWarningSigns",
        "UnderFloorPanels",
        "CutScene",
        "Swarm",
        "Shadows",
        "StuntsLinearDodge",
        "Stunts",
        "Black",
        "BlackAdd",
        "TrapsColor",
        "TrapsBlack",
        "LaserLow1",
        "LaserLow2",
        "LaserMed",
        "LaserHigh",
        "LaserHigh2",
        "TrapsShadows",
        "Sequences",
        "Lights",
        "LightsAdd",
        "Model",
        "Items",
        "Particles",
        "Fg",
        "FgAdd",
        "Collision",
        "0",
        "Default",
        "Debug"
    ]

    static func index(of layer: String) -> Int {
        all.firstIndex(of: layer) ?? all.firstIndex(of: "Default") ?? all.count
    }
}

/// Tags shown in the inspector tag picker.
///
/// These are editor-facing labels, but exported XML still depends on node kind.
enum Vector2Tags {
    static let all = [
        "Image",
        "Object",
        "ObjectReference",
        "Platform",
        "Trapezoid",
        "Trigger",
        "Area",
        "Spawn",
        "In",
        "Out",
        "Camera",
        "Bonus",
        "Item",
        "Model",
        "Animation",
        "Particle",
        "Dynamic",
        "Swarm",
        "Waypoint",
        "Untagged"
    ]
}

// MARK: - Asset Browser / Catalog

/// Discovers textures, library XML objects, Unity prefabs, and imported folders.
///
/// This is intentionally filesystem-driven so public builds are portable. Avoid
/// hardcoded user paths here; prefer bundled resources, workspace-relative
/// discovery, environment overrides, and user-selected extra asset folders.
enum Vector2AssetCatalog {
    private static var developmentUnityAssetsRoot: String {
        firstExistingWorkspacePath("Assets") ?? environmentPath("VECTOR2_ASSETS_ROOT") ?? ""
    }

    private static var developmentRunSpritesRoot: String {
        firstExistingWorkspacePath("Assets/sprites/run")
            ?? environmentPath("VECTOR2_RUN_SPRITES_ROOT")
            ?? ""
    }

    private static var developmentRunLibrariesRoot: String {
        firstExistingWorkspacePath("Assets/Resources/gamedata/run_data/libraries")
            ?? environmentPath("VECTOR2_RUN_LIBRARIES_ROOT")
            ?? ""
    }

    private static var developmentProjectAssetsRoot: String {
        // Keep this project-local. Do not jump to a random Unity checkout here.
        // The old workspace search could resolve to unreadable external files in
        // sandboxed builds, then XMLDocument would fail with permission errors.
        environmentPath("VECTOR2_PROJECT_ASSETS_ROOT")
            ?? firstExistingWorkspacePath("ProjectAssets/Vector2")
            ?? ""
    }

    private static var developmentReleaseAssetsRoot: String {
        environmentPath("VECTOR2_RELEASE_ASSETS_ROOT") ?? ""
    }

    private static var developmentVectorierAssetsRoot: String {
        environmentPath("VECTORIER_ASSETS_ROOT") ?? ""
    }

    private static var developmentVector2EditorResourcesRoot: String {
        environmentPath("VECTOR2_EDITOR_RESOURCES_ROOT")
            ?? environmentPath("VECTOR2_RELEASE_ASSETS_ROOT").map {
                URL(fileURLWithPath: $0).appendingPathComponent("Resources").path
            }
            ?? ""
    }
    private static var cachedTexturePathByClassName: [String: String]?
    private static var cachedLibraryFilenameByObjectName: [String: [String]]?
    private static var cachedSpriteClassNameByGUID: [String: String]?
    private static var cachedAssetPathByGUID: [String: String]?
    private static var cachedSpritePivotByPath: [String: CGPoint] = [:]
    private static var activeProjectSecurityScope: URL?

    private static func environmentPath(_ key: String) -> String? {
        // Optional development override. Public builds should work without
        // these, but they are useful when testing against unpacked Unity assets.
        let value = ProcessInfo.processInfo.environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !value.isEmpty, FileManager.default.fileExists(atPath: value) else { return nil }
        return value
    }

    private static func firstExistingWorkspacePath(_ relativePath: String) -> String? {
        // Searches likely workspace roots for portable bundled/project assets.
        // Find assets relative to the project or app resources.
        let fileManager = FileManager.default
        for root in workspaceRoots() {
            let candidate = root.appendingPathComponent(relativePath)
            if fileManager.fileExists(atPath: candidate.path) {
                return candidate.path
            }
        }
        return nil
    }

    private static func workspaceRoots() -> [URL] {
        // Candidate roots include current working directory, app resources, and
        // an explicit environment override. Walking upward lets Xcode, built
        // apps, and CLI launches all resolve assets.
        let fileManager = FileManager.default
        var starts = [URL(fileURLWithPath: fileManager.currentDirectoryPath)]
        if let resourceURL = Bundle.main.resourceURL {
            starts.append(resourceURL)
        }
        if let explicitRoot = environmentPath("VECTOR2_WORKSPACE_ROOT") {
            starts.insert(URL(fileURLWithPath: explicitRoot), at: 0)
        }

        var roots: [URL] = []
        for start in starts {
            var current = start.standardizedFileURL
            for _ in 0..<10 {
                if fileManager.fileExists(atPath: current.appendingPathComponent("Assets/Resources/gamedata/run_data").path)
                    || fileManager.fileExists(atPath: current.appendingPathComponent("ProjectAssets/Vector2").path) {
                    roots.append(current)
                }
                let parent = current.deletingLastPathComponent()
                if parent.path == current.path { break }
                current = parent
            }
        }
        return uniqueURLs(roots)
    }

    /// Builds the asset browser catalog.
    ///
    /// Load order matters: real Vector 2 textures and libraries should beat
    /// placeholder/imported assets, then categories are merged by group/name.
    static func load(extraAssetFolders: [String] = []) -> [TextureCategory] {
        // Refresh is also the hand-off from Project Manager to the room editor.
        // Drop lookup caches so freshly imported artwork and freshly compiled
        // v2trap libraries become placeable without relaunching the app.
        cachedTexturePathByClassName = nil
        cachedLibraryFilenameByObjectName = nil
        var categories: [TextureCategory] = []
        for textureBankRoot in textureBankRoots() {
            categories.append(contentsOf: loadFlatTextureBank(from: textureBankRoot))
        }
        categories.append(contentsOf: loadDevelopmentRunSprites())
        categories.append(contentsOf: loadReleaseTextures())

        categories.append(contentsOf: loadLibraries())
        categories.append(contentsOf: loadPrefabs())
        categories.append(contentsOf: loadEditorPrefabs())
        categories.append(contentsOf: loadGamePrefabs())
        var importedFolders = extraAssetFolders
        if let project = activeProjectRootURL() {
            importedFolders.append(project.appendingPathComponent("custom_textures", isDirectory: true).path)
            importedFolders.append(project.appendingPathComponent("custom_backgrounds", isDirectory: true).path)
        }
        categories.append(contentsOf: loadImportedFolders(Array(Set(importedFolders))))
        categories.append(contentsOf: loadObstaclePackages())
        categories.append(contentsOf: loadCustomStunts())
        return mergeCategories(categories).filter { !$0.assets.isEmpty }
    }

    private static func loadCustomStunts() -> [TextureCategory] {
        guard let project = activeProjectRootURL() else { return [] }
        let folder = project.appendingPathComponent("custom_tricks", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        let manifests = enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension.lowercased() == "xml" }
        let assets = manifests.compactMap { file -> TextureAsset? in
            guard let document = try? XMLDocument(contentsOf: file),
                  let root = document.rootElement(), root.name == "CustomTrick" else { return nil }
            let name = root.attribute(forName: "Name")?.stringValue ?? file.deletingPathExtension().lastPathComponent
            let visualName = root.attribute(forName: "VisualName")?.stringValue ?? name
            return TextureAsset(
                group: "Project",
                kind: .libraryObject,
                category: "Custom Stunts",
                name: visualName,
                className: "Stunt",
                filePath: libraryFilename(containingObjectNamed: "Stunt") ?? "triggers.xml",
                defaultLayer: "Stunts",
                libraryObjectName: "Stunt",
                libraryOverrides: ["StuntName": name]
            )
        }
        return assets.isEmpty ? [] : [TextureCategory(group: "Project", name: "Custom Stunts", assets: assets)]
    }

    private static func loadObstaclePackages() -> [TextureCategory] {
        guard let project = activeProjectRootURL() else { return [] }
        let folder = project.appendingPathComponent("custom_obstacles", isDirectory: true)
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []).filter { $0.pathExtension.lowercased() == ObstaclePackageStore.fileExtension }
        let assets = files.compactMap { file -> TextureAsset? in
            guard let package = try? ObstaclePackageStore.read(file) else { return nil }
            let search = ([package.definition.xml] + package.textureURLs.map(\.lastPathComponent)).joined(separator: " ")
            return TextureAsset(group: "Project", kind: .libraryObject, category: "Custom Obstacles", name: package.definition.name, className: package.definition.stableID, filePath: package.previewURL?.path ?? "", defaultLayer: "Object", libraryObjectName: package.definition.stableID, libraryOverrides: ["Search": search], obstaclePackagePath: file.path)
        }
        return assets.isEmpty ? [] : [TextureCategory(group: "Project", name: "Custom Obstacles", assets: assets)]
    }

    static func defaultPlacementAsset(for tool: EditorTool, in catalog: [TextureCategory]) -> TextureAsset? {
        // Chooses a sensible default asset when the user selects a tool without
        // first picking something in the asset browser.
        switch tool {
        case .cursor:
            return nil
        case .images:
            return firstTextureAsset(in: catalog, preferredCategoryFragments: ["zone2", "wall", "panel"])
        case .backgrounds:
            return firstTextureAsset(in: catalog, preferredCategoryFragments: ["bg_", "far_city", "background"])
        case .objectRef, .object:
            return nil
        default:
            return nil
        }
    }

    static func editorPrefabAsset(named name: String, categoryContaining categoryFragment: String? = nil) -> TextureAsset? {
        // Resolves an editor prefab by display name, optionally nudged toward a
        // category. Used by level import to turn ObjectReferences back into
        // richer visuals instead of green boxes.
        let matches = editorPrefabFiles()
            .filter { editorPrefabDisplayName(for: $0).caseInsensitiveCompare(name) == .orderedSame }
            .sorted { lhs, rhs in
                editorPrefabCategory(for: lhs) < editorPrefabCategory(for: rhs)
            }

        let file = matches.first { file in
            guard let categoryFragment else { return true }
            return editorPrefabCategory(for: file).localizedCaseInsensitiveContains(categoryFragment)
        } ?? matches.first

        guard let file else { return nil }
        let category = editorPrefabCategory(for: file)
        return TextureAsset(
            group: "Prefabs",
            kind: .prefab,
            category: category,
            name: editorPrefabDisplayName(for: file),
            className: editorPrefabDisplayName(for: file),
            filePath: file.path,
            defaultLayer: editorPrefabDefaultLayer(for: category)
        )
    }

    static func editorPrefabAsset(encodedStem: String) -> TextureAsset? {
        // Reverse lookup for filenames encoded as `Category__Name.prefab`.
        guard let file = editorPrefabFiles().first(where: {
            $0.deletingPathExtension().lastPathComponent == encodedStem
        }) else {
            return nil
        }

        let category = editorPrefabCategory(for: file)
        return TextureAsset(
            group: "Prefabs",
            kind: .prefab,
            category: category,
            name: editorPrefabDisplayName(for: file),
            className: editorPrefabDisplayName(for: file),
            filePath: file.path,
            defaultLayer: editorPrefabDefaultLayer(for: category)
        )
    }

    /// Resolves a Vector 2 class/sprite name to an image file path.
    ///
    /// Importer green boxes often mean this returned nil, or the class name from
    /// XML did not match any indexed texture.
    static func imagePath(forClassName className: String) -> String? {
        if cachedTexturePathByClassName == nil {
            cachedTexturePathByClassName = texturePathIndex()
        }

        let trimmed = className.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.replacingOccurrences(
            of: #"_\d+$"#,
            with: "",
            options: .regularExpression
        )
        let keys = Array(Set([trimmed, normalized])).filter { !$0.isEmpty }

        for key in keys {
            if let path = cachedTexturePathByClassName?[key] {
                return path
            }
        }

        let fallbackNames = Array(Set(keys.map { $0.components(separatedBy: ".").last ?? $0 }))
        for fallbackName in fallbackNames where !fallbackName.isEmpty {
            if let path = cachedTexturePathByClassName?.first(where: { key, _ in
                key == fallbackName || key.hasSuffix(".\(fallbackName)")
            })?.value {
                return path
            }
        }

        return nil
    }

    static func libraryFilename(containingObjectNamed objectName: String, preferredNear hint: String? = nil) -> String? {
        if cachedLibraryFilenameByObjectName == nil {
            cachedLibraryFilenameByObjectName = libraryObjectFilenameIndex()
        }

        let cleanName = objectName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return nil }

        let lookupNames = Array(Set([
            cleanName,
            cleanName.components(separatedBy: ".").last ?? cleanName
        ])).filter { !$0.isEmpty }

        let matches = lookupNames
            .compactMap { cachedLibraryFilenameByObjectName?[$0.lowercased()] }
            .flatMap { $0 }
        guard !matches.isEmpty else { return nil }

        if let hint = hint?.lowercased(), !hint.isEmpty,
           let hinted = matches.first(where: { $0.lowercased() == hint || $0.lowercased().contains(hint) }) {
            return hinted
        }

        let preferred = preferredLibraryFilenames(for: cleanName)
        for filename in preferred {
            if matches.contains(where: { $0.caseInsensitiveCompare(filename) == .orderedSame }) {
                return filename
            }
        }

        return matches.sorted().first
    }

    static func spritePivotOffset(forClassName className: String, width: Int, height: Int) -> (x: Int, y: Int) {
        // Converts Unity sprite pivot metadata into editor pixel offsets.
        guard let path = imagePath(forClassName: className) else { return (0, 0) }
        let pivot = spritePivot(forImagePath: path)
        let offsetX = Int((CGFloat(width) * pivot.x).rounded())
        let offsetY = Int((CGFloat(height) * (1 - pivot.y)).rounded())
        return (offsetX, offsetY)
    }

    private static func spritePivot(forImagePath path: String) -> CGPoint {
        // Reads Unity .meta spritePivot. Default `(0, 1)` matches the top-left
        // style Vector 2 XML often assumes.
        if let cached = cachedSpritePivotByPath[path] {
            return cached
        }

        let metaPath = path + ".meta"
        guard let text = try? String(contentsOfFile: metaPath, encoding: .utf8) else {
            let fallback = CGPoint(x: 0, y: 1)
            cachedSpritePivotByPath[path] = fallback
            return fallback
        }

        let pattern = #"spritePivot:\s*\{x:\s*([-0-9.]+),\s*y:\s*([-0-9.]+)\}"#
        if let match = text.range(of: pattern, options: .regularExpression) {
            let snippet = String(text[match])
            let values = snippet
                .replacingOccurrences(of: "spritePivot:", with: "")
                .replacingOccurrences(of: "{", with: "")
                .replacingOccurrences(of: "}", with: "")
                .split(separator: ",")
                .compactMap { part -> CGFloat? in
                    let number = part.split(separator: ":").last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    return Double(number).map(CGFloat.init)
                }
            if values.count == 2 {
                let pivot = CGPoint(x: values[0], y: values[1])
                cachedSpritePivotByPath[path] = pivot
                return pivot
            }
        }

        let fallback = CGPoint(x: 0, y: 1)
        cachedSpritePivotByPath[path] = fallback
        return fallback
    }

    static func className(forSpriteGUID guid: String) -> String? {
        // GUID -> class name lookup for Unity SpriteRenderer parsing.
        if cachedSpriteClassNameByGUID == nil {
            cachedSpriteClassNameByGUID = spriteGUIDIndex()
        }
        return cachedSpriteClassNameByGUID?[guid]
    }

    static func className(forSpriteGUID guid: String, fileID: String) -> String? {
        // Sprites packed into one texture can share GUID, so fileID disambiguates
        // sub-sprites when available.
        if cachedSpriteClassNameByGUID == nil {
            cachedSpriteClassNameByGUID = spriteGUIDIndex()
        }
        return cachedSpriteClassNameByGUID?["\(guid):\(fileID)"] ?? cachedSpriteClassNameByGUID?[guid]
    }

    static func imagePath(forSpriteGUID guid: String) -> String? {
        // GUID -> image path for prefab previews.
        if let className = className(forSpriteGUID: guid),
           let path = imagePath(forClassName: className) {
            return path
        }
        return assetURL(forGUID: guid, preferredExtensions: ["png", "jpg", "jpeg"])?.path
    }

    static func imagePath(forSpriteGUID guid: String, fileID: String) -> String? {
        // GUID + fileID -> image path for prefab previews with sprite atlas
        // awareness.
        if let className = className(forSpriteGUID: guid, fileID: fileID),
           let path = imagePath(forClassName: className) {
            return path
        }
        return assetURL(forGUID: guid, preferredExtensions: ["png", "jpg", "jpeg"])?.path
    }

    static func defaultLayerName(for className: String) -> String {
        defaultLayer(for: className)
    }

    static func libraryURL(named filename: String, relativeTo baseURL: URL? = nil) -> URL {
        // Resolve libraries from this editor project/app bundle first. Only use
        // external Unity paths when they are actually readable by the sandbox.
        let fileManager = FileManager.default

        if let projectLibrary = projectAssetsRoot?.appendingPathComponent("Libraries").appendingPathComponent(filename),
           isReadableFile(projectLibrary) {
            return projectLibrary
        }

        if let resourceURL = Bundle.main.resourceURL {
            let bundledProjectLibrary = resourceURL
                .appendingPathComponent("ProjectAssets")
                .appendingPathComponent("Vector2")
                .appendingPathComponent("Libraries")
                .appendingPathComponent(filename)
            if isReadableFile(bundledProjectLibrary) {
                return bundledProjectLibrary
            }

            // Xcode file-system-synchronized groups can flatten resource files
            // into Contents/Resources, so support that shape too.
            let flatBundledLibrary = resourceURL.appendingPathComponent(filename)
            if isReadableFile(flatBundledLibrary) {
                return flatBundledLibrary
            }
        }

        if let baseURL {
            let local = baseURL.deletingLastPathComponent().appendingPathComponent(filename)
            if isReadableFile(local) {
                return local
            }

            for ancestor in ancestors(startingAt: baseURL.deletingLastPathComponent(), maxDepth: 8) {
                for folderName in ["libraries", "Libraries"] {
                    let runDataLibrary = ancestor.appendingPathComponent(folderName).appendingPathComponent(filename)
                    if isReadableFile(runDataLibrary) {
                        return runDataLibrary
                    }
                }
            }
        }

        let developmentRunLibrary = URL(fileURLWithPath: developmentRunLibrariesRoot).appendingPathComponent(filename)
        if isReadableFile(developmentRunLibrary) {
            return developmentRunLibrary
        }

        if let baseURL {
            let fallback = baseURL.deletingLastPathComponent().appendingPathComponent(filename)
            if fileManager.fileExists(atPath: fallback.path) { return fallback }
        }
        return URL(fileURLWithPath: filename)
    }

    static func prefabURL(forGUID guid: String) -> URL? {
        // Unity prefab GUID lookup for nested prefab previews.
        assetURL(forGUID: guid, preferredExtensions: ["prefab"])
    }

    static func assetURL(forGUID guid: String, preferredExtensions: [String] = []) -> URL? {
        // Generic GUID lookup backed by .meta files.
        if cachedAssetPathByGUID == nil {
            cachedAssetPathByGUID = assetPathIndexByGUID()
        }

        guard let path = cachedAssetPathByGUID?[guid] else {
            return nil
        }

        let url = URL(fileURLWithPath: path)
        if preferredExtensions.isEmpty || preferredExtensions.contains(url.pathExtension.lowercased()) {
            return url
        }
        return nil
    }

    static func defaultLayerName(forPrefabAt url: URL) -> String {
        // Best-effort sorting layer from prefab path. It only affects editor
        // preview layering, not export schema.
        let path = url.path.lowercased()
        if path.contains("/shadows/") || path.contains("shadow") { return "Shadows" }
        if path.contains("/lasers/") || path.contains("/traps/") || path.contains("trap") { return "TrapsColor" }
        if path.contains("/underfloor/") { return "UnderFloorPanels" }
        if path.contains("/triggers/") { return "Default" }
        if path.contains("/effects/") { return "Particles" }
        if path.contains("/models/") { return "Items" }
        return "Items"
    }

    private static func firstTextureAsset(in catalog: [TextureCategory], preferredCategoryFragments: [String]) -> TextureAsset? {
        // Tool default helper that prefers useful visible textures.
        for fragment in preferredCategoryFragments {
            if let asset = catalog
                .filter({ $0.group == "Vector 2 Textures" })
                .flatMap(\.assets)
                .first(where: { $0.category.localizedCaseInsensitiveContains(fragment) }) {
                return asset
            }
        }

        return firstAsset(in: catalog, kind: .texture)
    }

    private static func firstAsset(in catalog: [TextureCategory], kind: TextureAsset.Kind) -> TextureAsset? {
        // Generic first asset lookup for fallback placement.
        catalog
            .flatMap(\.assets)
            .first { $0.kind == kind }
    }

    private static func loadDevelopmentRunSprites() -> [TextureCategory] {
        // Development-only run sprite folder loader, discovered portably.
        loadTextureFolderTree(
            from: URL(fileURLWithPath: developmentRunSpritesRoot),
            group: "Vector 2 Textures"
        )
    }

    private static func loadReleaseTextures() -> [TextureCategory] {
        // Loads texture exports from a release/game asset folder if configured.
        [
            URL(fileURLWithPath: developmentReleaseAssetsRoot).appendingPathComponent("Resources/Textures"),
            URL(fileURLWithPath: developmentReleaseAssetsRoot).appendingPathComponent("StreamingAssets/Resources/Textures")
        ].flatMap { root in
            loadFlatTextureFolder(from: root, group: "Vector 2 Editor Textures") +
            loadTextureFolderTree(from: root, group: "Vector 2 Textures")
        }
    }

    private static func loadFlatTextureFolder(from rootURL: URL, group: String) -> [TextureCategory] {
        // Loads a single folder of loose images as one browser category.
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let assets = files
            .filter { ["png", "jpg", "jpeg", "gif"].contains($0.pathExtension.lowercased()) }
            .filter { !isLowTextureAsset($0, category: rootURL.lastPathComponent) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { file in
                let stem = file.deletingPathExtension().lastPathComponent
                return TextureAsset(
                    group: group,
                    kind: .texture,
                    category: "Editor",
                    name: stem,
                    className: stem,
                    filePath: file.path,
                    defaultLayer: editorTextureDefaultLayer(for: stem)
                )
            }

        guard !assets.isEmpty else { return [] }
        return [TextureCategory(group: group, name: "Editor", assets: assets)]
    }

    private static func loadTextureFolderTree(from rootURL: URL, group: String) -> [TextureCategory] {
        // Loads one category per subfolder, e.g. TextureBank/walls/*.png.
        guard let folders = try? FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return folders
            .filter { $0.hasDirectoryPath }
            .filter { !isLowTextureCategory($0.lastPathComponent) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { folder in
                guard let files = try? FileManager.default.contentsOfDirectory(
                    at: folder,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                ) else {
                    return nil
                }

                let assets = files
                    .filter { ["png", "jpg", "jpeg", "gif"].contains($0.pathExtension.lowercased()) }
                    .filter { !isLowTextureAsset($0, category: folder.lastPathComponent) }
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
                    .map { file in
                        let category = folder.lastPathComponent
                        let stem = file.deletingPathExtension().lastPathComponent
                        return TextureAsset(
                            group: "Vector 2 Textures",
                            kind: .texture,
                            category: category,
                            name: stem,
                            className: stem.contains(".") ? stem : "\(category).\(stem)",
                            filePath: file.path,
                            defaultLayer: defaultLayer(for: category)
                        )
                    }

                guard !assets.isEmpty else { return nil }
                return TextureCategory(group: group, name: folder.lastPathComponent, assets: assets)
            }
    }

    private static func textureBankRoots() -> [URL] {
        // Ordered search for TextureBank roots. Bundled project assets win, then
        // development resources, then app bundle fallbacks.
        var roots: [URL] = []
        if let projectTextureBank = projectAssetsRoot?.appendingPathComponent("TextureBank"),
           FileManager.default.fileExists(atPath: projectTextureBank.path) {
            roots.append(projectTextureBank)
        }

        let developmentTextureBank = URL(fileURLWithPath: developmentProjectAssetsRoot)
            .appendingPathComponent("TextureBank")
        if FileManager.default.fileExists(atPath: developmentTextureBank.path) {
            roots.append(developmentTextureBank)
        }

        if let resourceURL = Bundle.main.resourceURL {
            let bundledTextureBank = resourceURL
                .appendingPathComponent("ProjectAssets")
                .appendingPathComponent("Vector2")
                .appendingPathComponent("TextureBank")
            if FileManager.default.fileExists(atPath: bundledTextureBank.path) {
                roots.append(bundledTextureBank)
            }

            let directTextureBank = resourceURL.appendingPathComponent("TextureBank")
            if FileManager.default.fileExists(atPath: directTextureBank.path) {
                roots.append(directTextureBank)
            }

            if directoryLooksLikeFlatTextureBank(resourceURL) {
                roots.append(resourceURL)
            }
        }

        var seen: Set<String> = []
        return roots.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    private static var bundledTextureBankRoot: URL? {
        textureBankRoots().first
    }

    private static func directoryLooksLikeFlatTextureBank(_ url: URL) -> Bool {
        // Detects resource folders where TextureBank files were copied flat into
        // the bundle instead of preserving subfolders.
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }
        return files.contains {
            $0.lastPathComponent.contains("__") &&
            ["png", "jpg", "jpeg"].contains($0.pathExtension.lowercased())
        }
    }

    private static func loadFlatTextureBank(from rootURL: URL) -> [TextureCategory] {
        // Loads flattened `category__name.png` texture banks generated for the
        // public editor bundle.
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let grouped = Dictionary(grouping: files.filter {
            ["png", "jpg", "jpeg"].contains($0.pathExtension.lowercased())
        }) { file in
            file.deletingPathExtension().lastPathComponent.components(separatedBy: "__").first ?? "Textures"
        }

        return grouped.keys.sorted().compactMap { category in
            guard !isLowTextureCategory(category) else { return nil }
            guard let files = grouped[category] else { return nil }
            guard !category.hasPrefix("vector1_") else { return nil }
            let group = "Vector 2 Textures"
            let assets = files
                .filter { !isLowTextureAsset($0, category: category) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
                .map { file in
                let rawStem = file.deletingPathExtension().lastPathComponent
                let displayStem = rawStem.components(separatedBy: "__").dropFirst().joined(separator: "__")
                let stem = displayStem.isEmpty ? rawStem : displayStem
                return TextureAsset(
                    group: group,
                    kind: .texture,
                    category: category,
                    name: stem,
                    className: stem.contains(".") ? stem : "\(category).\(stem)",
                    filePath: file.path,
                    defaultLayer: defaultLayer(for: category)
                )
            }

            return TextureCategory(group: group, name: category, assets: assets)
        }
    }

    private static func isLowTextureCategory(_ category: String) -> Bool {
        // Avoid low-res duplicates in the browser/import resolver when a better
        // texture exists.
        let lowercased = category.lowercased()
        return lowercased == "low" ||
        lowercased.hasSuffix("_low") ||
        lowercased.contains("_low_") ||
        lowercased.contains(" low")
    }

    private static func isLowTextureAsset(_ file: URL, category: String) -> Bool {
        // Filters individual low-res files inside otherwise valid categories.
        if isLowTextureCategory(category) {
            return true
        }

        let stem = file.deletingPathExtension().lastPathComponent.lowercased()
        return stem.hasPrefix("low__") ||
        stem.contains("__low__") ||
        stem.contains("_low__") ||
        stem.contains("__\(category.lowercased())_low.")
    }

    private static func loadLibraries() -> [TextureCategory] {
        // Loads top-level objects from library XML files such as phantoms.xml,
        // triggers.xml, obstacles.xml.
        let files = libraryFiles()
        guard !files.isEmpty else {
            return []
        }

        let currentTrapObjects = Set(activeProjectRootURL().map { CustomTrapDefinition.load(from: $0).map(\.objectName) } ?? [])
        return files
            .filter { $0.pathExtension.lowercased() == "xml" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { file in
                let assets = libraryAssets(in: file).filter {
                    CustomLibraryVisibility.shouldIndex(
                        filename: file.lastPathComponent,
                        objectName: $0.libraryObjectName.isEmpty ? $0.name : $0.libraryObjectName,
                        currentTrapObjects: currentTrapObjects
                    )
                }
                guard !assets.isEmpty else { return nil }
                return TextureCategory(group: "Library", name: file.deletingPathExtension().lastPathComponent, assets: assets)
            }
    }

    private static func loadPrefabs() -> [TextureCategory] {
        // Runtime prefab bucket. Mostly diagnostic now; editor prefabs are used
        // more heavily for placement/import visuals.
        let prefabs = prefabFiles()
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { file in
                TextureAsset(
                    group: "Runtime Prefabs",
                    kind: .prefab,
                    category: file.deletingLastPathComponent().lastPathComponent,
                    name: file.deletingPathExtension().lastPathComponent,
                    className: file.deletingPathExtension().lastPathComponent,
                    filePath: file.path,
                    defaultLayer: "Items"
                )
            }

        guard !prefabs.isEmpty else { return [] }
        return [TextureCategory(group: "Runtime Prefabs", name: "run prefabs", assets: prefabs)]
    }

    private static func loadEditorPrefabs() -> [TextureCategory] {
        // Preferred prefab browser source. These are curated for editor visuals.
        let grouped = Dictionary(grouping: editorPrefabFiles().sorted { $0.path < $1.path }) { file in
            editorPrefabCategory(for: file)
        }

        return grouped.keys.sorted().compactMap { category in
            guard let files = grouped[category] else { return nil }
            let assets = files.map { file in
                TextureAsset(
                    group: "Prefabs",
                    kind: .prefab,
                    category: category,
                    name: editorPrefabDisplayName(for: file),
                    className: editorPrefabDisplayName(for: file),
                    filePath: file.path,
                    defaultLayer: editorPrefabDefaultLayer(for: category)
                )
            }
            guard !assets.isEmpty else { return nil }
            return TextureCategory(group: "Prefabs", name: category, assets: assets)
        }
    }

    private static func loadGamePrefabs() -> [TextureCategory] {
        // Raw game prefab browser source. Useful for advanced users, less
        // curated than EditorPrefabBank.
        let grouped = Dictionary(grouping: gamePrefabFiles().sorted { $0.path < $1.path }) { file in
            bankPrefabCategory(for: file)
        }

        return grouped.keys.sorted().compactMap { category in
            guard let files = grouped[category] else { return nil }
            let assets = files.map { file in
                TextureAsset(
                    group: "Game Prefabs",
                    kind: .prefab,
                    category: category,
                    name: bankPrefabDisplayName(for: file),
                    className: bankPrefabDisplayName(for: file),
                    filePath: file.path,
                    defaultLayer: gamePrefabDefaultLayer(for: category)
                )
            }
            guard !assets.isEmpty else { return nil }
            return TextureCategory(group: "Game Prefabs", name: category, assets: assets)
        }
    }

    private static func libraryFiles() -> [URL] {
        // Finds bundled/project library XMLs. The fallback known-name list is for
        // app bundles that flatten resources.
        var discoveredFiles: [URL] = []
        for rootURL in libraryRootURLs() {
            if let files = try? FileManager.default.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) {
                discoveredFiles.append(contentsOf: files.filter { $0.pathExtension.lowercased() == "xml" })
            }
        }
        if !discoveredFiles.isEmpty {
            return uniqueURLs(discoveredFiles)
        }

        if let rootURL = projectAssetsRoot?.appendingPathComponent("Libraries"),
           let files = try? FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
           ) {
            return files.filter { $0.pathExtension.lowercased() == "xml" }
        }

        guard let resourceURL = Bundle.main.resourceURL,
              let files = try? FileManager.default.contentsOfDirectory(
                at: resourceURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
              ) else {
            return []
        }

        let knownLibraryNames: Set<String> = [
            "animated.xml", "background.xml", "black_silhouette.xml", "bonus.xml", "doors.xml",
            "doors_service.xml", "lamps.xml", "moves_new.xml", "objects_items.xml", "obstacles.xml",
            "obstacles_moving.xml", "passive_effects.xml", "phantoms.xml", "shadows.xml",
            "shiny_stuff_service.xml", "swarms.xml", "traps.xml", "traps_cosmetics.xml",
            "traps_placeholder.xml", "traps_service.xml", "triggers.xml", "underfloor.xml",
            "wall_props.xml", "z2_wall_props.xml"
        ]
        return files.filter { knownLibraryNames.contains($0.lastPathComponent) }
    }

    private static func libraryRootURLs() -> [URL] {
        var roots: [URL] = []
        // Trap Designer writes its compiled object here before installation.
        // Reading the active project directly means Tools -> Traps can place a
        // new trap immediately; installing to Vector is a separate action.
        if let project = activeProjectRootURL() {
            let projectLibraries = project
                .appendingPathComponent("custom_gamedata", isDirectory: true)
                .appendingPathComponent("run_data", isDirectory: true)
                .appendingPathComponent("libraries", isDirectory: true)
            if isReadableDirectory(projectLibraries) { roots.append(projectLibraries) }
        }
        // Libraries compiled by Trap Designer are installed here. Including the
        // runtime folder makes them appear in Tools → Traps after Refresh.
        if let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let customLibraries = support
                .appendingPathComponent("Nekki", isDirectory: true)
                .appendingPathComponent("Vector 2", isDirectory: true)
                .appendingPathComponent("custom_gamedata", isDirectory: true)
                .appendingPathComponent("run_data", isDirectory: true)
                .appendingPathComponent("libraries", isDirectory: true)
            if isReadableDirectory(customLibraries) { roots.append(customLibraries) }
        }
        if let rootURL = projectAssetsRoot?.appendingPathComponent("Libraries"),
           isReadableDirectory(rootURL) {
            roots.append(rootURL)
        }
        if let resourceURL = Bundle.main.resourceURL {
            let bundled = resourceURL
                .appendingPathComponent("ProjectAssets")
                .appendingPathComponent("Vector2")
                .appendingPathComponent("Libraries")
            if isReadableDirectory(bundled) {
                roots.append(bundled)
            }

            // Support flattened app resources.
            if isReadableDirectory(resourceURL) {
                roots.append(resourceURL)
            }
        }
        let developmentRunLibraries = URL(fileURLWithPath: developmentRunLibrariesRoot)
        if isReadableDirectory(developmentRunLibraries) {
            roots.append(developmentRunLibraries)
        }
        return uniqueURLs(roots)
    }

    static func xmlAssistantTemplateRoots(projectRoot: URL? = nil, gameDirectory: String = "") -> [URL] {
        var roots: [URL] = []
        if let project = projectRoot ?? activeProjectRootURL() {
            roots.append(project.appendingPathComponent("custom_gamedata/run_data/templates"))
            if let manifest = try? XMLDocument(contentsOf: project.appendingPathComponent("project.xml")), let root = manifest.rootElement() {
                for key in ["GameDataPath", "GameSourcePath"] {
                    if let path = root.attribute(forName: key)?.stringValue, !path.isEmpty {
                        let url = URL(fileURLWithPath: path)
                        roots += [url.appendingPathComponent("gamedata/run_data/templates"), url.appendingPathComponent("Assets/Resources/gamedata/run_data/templates"), url.appendingPathComponent("run_data/templates")]
                    }
                }
            }
        }
        if !gameDirectory.isEmpty { roots += [URL(fileURLWithPath: gameDirectory).appendingPathComponent("gamedata/run_data/templates"), URL(fileURLWithPath: gameDirectory).appendingPathComponent("run_data/templates")] }
        roots += libraryRootURLs().map { $0.deletingLastPathComponent().appendingPathComponent("templates") }
        roots += workspaceRoots().map { $0.appendingPathComponent("Assets/Resources/gamedata/run_data/templates") }
        if let bundled = Bundle.main.resourceURL { roots += [bundled.appendingPathComponent("gamedata/run_data/templates"), bundled.appendingPathComponent("ProjectAssets/Vector2/Resources/gamedata/run_data/templates")] }
        return uniqueURLs(roots).filter { isReadableDirectory($0) }
    }

    // Capture these on the UI actor before detached assistant indexing.
    static func xmlAssistantPackageRoots(projectRoot: URL? = nil, gameDirectory: String = "") -> [URL] {
        var roots = CustomModelCatalog.roots()
        if let project = projectRoot ?? activeProjectRootURL() {
            roots += [project.appendingPathComponent("custom_models"), project.appendingPathComponent("custom_tricks")]
        }
        if !gameDirectory.isEmpty {
            let game = URL(fileURLWithPath: gameDirectory, isDirectory: true)
            roots += [game.appendingPathComponent("custom_models"), game.appendingPathComponent("custom_tricks")]
        }
        if let encoded = UserDefaults.standard.string(forKey: "vector2CustomTricksDirectoryBookmark"), let data = Data(base64Encoded: encoded) {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale) { roots.append(url) }
        }
        if let path = UserDefaults.standard.string(forKey: "vector2CustomTricksDirectory"), !path.isEmpty { roots.append(URL(fileURLWithPath: path, isDirectory: true)) }
        return uniqueURLs(roots)
    }

    static func activeProjectRootURL() -> URL? {
        if let path = UserDefaults.standard.string(forKey: "projectManager.lastProjectPath"), !path.isEmpty {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            if isReadableDirectory(url) { return url }
        }
        guard let data = UserDefaults.standard.data(forKey: "projectManager.lastProjectBookmark") else { return nil }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else { return nil }
        if activeProjectSecurityScope?.standardizedFileURL != url.standardizedFileURL {
            activeProjectSecurityScope?.stopAccessingSecurityScopedResource()
            activeProjectSecurityScope = url.startAccessingSecurityScopedResource() ? url : nil
        }
        return isReadableDirectory(url) ? url : nil
    }

    private static func prefabFiles() -> [URL] {
        // Finds generic prefab files from bundled project assets or app resources.
        if let rootURL = projectAssetsRoot?.appendingPathComponent("Prefabs"),
           let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
           ) {
            return enumerator
                .compactMap { $0 as? URL }
                .filter { $0.pathExtension.lowercased() == "prefab" }
        }

        guard let resourceURL = Bundle.main.resourceURL,
              let files = try? FileManager.default.contentsOfDirectory(
                at: resourceURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
              ) else {
            return []
        }

        return files.filter { $0.pathExtension.lowercased() == "prefab" }
    }

    private static func editorPrefabFiles() -> [URL] {
        // Finds curated editor prefabs. Order matters: bundled ProjectAssets
        // first, then development resources, then app bundle fallbacks.
        var files: [URL] = []
        if let rootURL = projectAssetsRoot?.appendingPathComponent("EditorPrefabBank"),
           let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
           ) {
            files.append(contentsOf: enumerator
                .compactMap { $0 as? URL }
                .filter { $0.pathExtension.lowercased() == "prefab" })
        }

        if !files.isEmpty {
            return uniqueURLs(files)
        }

        let developmentEditorRoot = URL(fileURLWithPath: developmentVector2EditorResourcesRoot)
        if FileManager.default.fileExists(atPath: developmentEditorRoot.path),
           let enumerator = FileManager.default.enumerator(
            at: developmentEditorRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
           ) {
            files.append(contentsOf: enumerator
                .compactMap { $0 as? URL }
                .filter { $0.pathExtension.lowercased() == "prefab" })
        }

        if !files.isEmpty {
            return uniqueURLs(files)
        }

        guard let resourceURL = Bundle.main.resourceURL else {
            return []
        }

        if let enumerator = FileManager.default.enumerator(
                at: resourceURL.appendingPathComponent("EditorPrefabBank"),
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
              ) {
            files.append(contentsOf: enumerator
                .compactMap { $0 as? URL }
                .filter { $0.pathExtension.lowercased() == "prefab" })
        }

        if !files.isEmpty {
            return uniqueURLs(files)
        }

        guard let files = try? FileManager.default.contentsOfDirectory(
            at: resourceURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return files.filter {
            $0.pathExtension.lowercased() == "prefab" &&
            $0.deletingPathExtension().lastPathComponent.contains("__")
        }
    }

    private static func isReadableFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return false
        }
        // FileManager.isReadableFile can still say yes for paths a sandboxed app
        // cannot actually open. A tiny real read check prevents RoomWeaver from
        // selecting inaccessible Unity checkout files over bundled ProjectAssets.
        if let handle = try? FileHandle(forReadingFrom: url) {
            try? handle.close()
            return true
        }
        return false
    }

    private static func isReadableDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return false
        }
        return (try? FileManager.default.contentsOfDirectory(atPath: url.path)) != nil
    }

    private static func uniqueURLs(_ files: [URL]) -> [URL] {
        // Removes duplicate paths while preserving search order.
        var seen: Set<String> = []
        return files.filter { file in
            let key = file.standardizedFileURL.path
            guard !seen.contains(key) else { return false }
            seen.insert(key)
            return true
        }
    }

    private static func ancestors(startingAt url: URL, maxDepth: Int) -> [URL] {
        var result: [URL] = []
        var current = url.standardizedFileURL
        for _ in 0..<maxDepth {
            result.append(current)
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        return result
    }

    private static func gamePrefabFiles() -> [URL] {
        // Finds raw game prefab bank files.
        if let rootURL = projectAssetsRoot?.appendingPathComponent("GamePrefabBank"),
           let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
           ) {
            return enumerator
                .compactMap { $0 as? URL }
                .filter { $0.pathExtension.lowercased() == "prefab" }
        }

        guard let resourceURL = Bundle.main.resourceURL else {
            return []
        }

        if let enumerator = FileManager.default.enumerator(
            at: resourceURL.appendingPathComponent("GamePrefabBank"),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            return enumerator
                .compactMap { $0 as? URL }
                .filter { $0.pathExtension.lowercased() == "prefab" }
        }

        guard let files = try? FileManager.default.contentsOfDirectory(
            at: resourceURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return files.filter {
            let stem = $0.deletingPathExtension().lastPathComponent
            return $0.pathExtension.lowercased() == "prefab" &&
            ["models__", "effects__", "prefab__"].contains { prefix in
                stem.hasPrefix(prefix)
            }
        }
    }

    private static func editorPrefabCategory(for file: URL) -> String {
        bankPrefabCategory(for: file, fallback: "Editor Prefabs")
    }

    private static func editorPrefabDisplayName(for file: URL) -> String {
        bankPrefabDisplayName(for: file)
    }

    private static func bankPrefabCategory(for file: URL, fallback: String = "Game Prefabs") -> String {
        let stem = file.deletingPathExtension().lastPathComponent
        let encodedParts = stem.components(separatedBy: "__").dropLast()
        if !encodedParts.isEmpty {
            let prefix = encodedParts.prefix(2).joined(separator: " / ")
            return prefix.isEmpty ? fallback : prefix
        }

        return file.deletingLastPathComponent().lastPathComponent
    }

    private static func bankPrefabDisplayName(for file: URL) -> String {
        file.deletingPathExtension().lastPathComponent.components(separatedBy: "__").last ?? file.deletingPathExtension().lastPathComponent
    }

    private static func editorPrefabDefaultLayer(for category: String) -> String {
        let lowercased = category.lowercased()
        if lowercased.contains("shadow") { return "Shadows" }
        if lowercased.contains("laser") || lowercased.contains("trap") { return "TrapsColor" }
        if lowercased.contains("underfloor") { return "UnderFloorPanels" }
        if lowercased.contains("trigger") { return "Default" }
        return "Items"
    }

    private static func gamePrefabDefaultLayer(for category: String) -> String {
        let lowercased = category.lowercased()
        if lowercased.contains("effect") { return "Particles" }
        if lowercased.contains("model") { return "Model" }
        if lowercased.contains("scene") || lowercased.contains("run") { return "Items" }
        return "Items"
    }

    private static func loadImportedFolders(_ folders: [String]) -> [TextureCategory] {
        folders.compactMap { path in
            let rootURL = URL(fileURLWithPath: path)
            guard let enumerator = FileManager.default.enumerator(
                at: rootURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else {
                return nil
            }

            let assets = enumerator
                .compactMap { $0 as? URL }
                .filter { ["png", "jpg", "jpeg"].contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
                .map { file in
                    let stem = file.deletingPathExtension().lastPathComponent
                    return TextureAsset(
                        group: "Imported",
                        kind: .texture,
                        category: rootURL.lastPathComponent,
                        name: stem,
                        className: stem,
                        filePath: file.path,
                        defaultLayer: defaultLayer(for: rootURL.lastPathComponent)
                    )
                }

            guard !assets.isEmpty else { return nil }
            return TextureCategory(group: "Imported", name: rootURL.lastPathComponent, assets: assets)
        }
    }

    private static var projectAssetsRoot: URL? {
        // Prefer the app/project resources that ship with this editor. Source
        // tree paths can be outside the sandbox in Release, so they are only a
        // fallback if they are actually readable.
        if let resourceURL = Bundle.main.resourceURL {
            let bundled = resourceURL
                .appendingPathComponent("ProjectAssets")
                .appendingPathComponent("Vector2")
            if isReadableDirectory(bundled) {
                return bundled
            }
        }

        let sourceRelative = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("ProjectAssets")
            .appendingPathComponent("Vector2")
        if isReadableDirectory(sourceRelative) {
            return sourceRelative
        }

        let development = URL(fileURLWithPath: developmentProjectAssetsRoot)
        if isReadableDirectory(development) {
            return development
        }
        return nil
    }

    private static func topLevelLibraryObjects(in file: URL) -> [String] {
        guard let document = try? XMLDocument(contentsOf: file),
              let root = document.rootElement(),
              let objectsContainer = root.elements(forName: "Objects").first else {
            return []
        }

        return objectsContainer.children?
            .compactMap { $0 as? XMLElement }
            .filter { $0.name == "Object" }
            .compactMap { $0.attribute(forName: "Name")?.stringValue }
            .filter { !$0.isEmpty } ?? []
    }

    private static func libraryObjectFilenameIndex() -> [String: [String]] {
        var index: [String: Set<String>] = [:]
        for file in libraryFiles() where file.pathExtension.lowercased() == "xml" {
            for objectName in topLevelLibraryObjects(in: file) {
                let clean = objectName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !clean.isEmpty else { continue }
                index[clean.lowercased(), default: []].insert(file.lastPathComponent)
                if let shortName = clean.components(separatedBy: ".").last, shortName != clean {
                    index[shortName.lowercased(), default: []].insert(file.lastPathComponent)
                }
            }
        }

        return index.mapValues { Array($0).sorted() }
    }

    private static func preferredLibraryFilenames(for objectName: String) -> [String] {
        let lower = objectName.lowercased()
        if lower.contains("silhouette") || lower.contains("lab_corner") {
            return ["black_silhouette.xml", "obstacles.xml", "obstacles_moving.xml"]
        }
        if lower.contains("gradient") || lower.contains("niche") {
            return ["shadows.xml", "obstacles_moving.xml", "obstacles.xml"]
        }
        if lower.contains("saveme") || lower.contains("zoom") || lower.contains("darkness") || lower.contains("nowallrun") {
            return ["triggers.xml", "z2_wall_props.xml", "doors.xml"]
        }
        if lower.contains("perpetuum") || lower.contains("crankshaft") {
            return ["animated.xml", "obstacles_moving.xml"]
        }
        if lower.contains("decal") || lower.contains("panel_wrapper") || lower.contains("simple_panel") {
            return ["wall_props.xml", "z2_wall_props.xml"]
        }
        if lower.contains("bonus") {
            return ["bonus.xml", "phantoms.xml"]
        }
        if lower.contains("lift") {
            return ["obstacles_moving.xml"]
        }
        return []
    }

    private static let hiddenTrapLibraryFiles: Set<String> = [
        "traps_cosmetics.xml", "traps_placeholder.xml", "traps_service.xml"
    ]

    private static let standaloneTrapObjects: Set<String> = [
        "BeamTrapMounted_DT", "BeamTrapMounted_TD", "BeamTrapMounted_RL", "BeamTrapMounted_LR",
        "BeamTrapFloating_DT", "BeamTrapFloating_TD", "BeamTrapFloating_RL", "BeamTrapFloating_LR",
        "TripleBomb", "TripleBomb_Shortjump", "TripleBomb_Hurdlejump",
        "Blackball", "Blackball_Shortjump", "Blackball_Hurdlejump",
        "Mine_Shortjump", "Mine_Hurdlejump", "Laser_Shortjump", "Laser_Hurdlejump",
        "Tesla_Shortjump", "Tesla_Hurdlejump", "Echo_Shortjump", "Echo_Hurdlejump",
        "Flame_Shortjump", "Flame_Hurdlejump", "Swarm_Shortjump", "Swarm_Hurdlejump"
    ]

    private static func libraryAssets(in file: URL) -> [TextureAsset] {
        let filename = file.lastPathComponent
        guard !hiddenTrapLibraryFiles.contains(filename) else { return [] }
        guard let document = try? XMLDocument(contentsOf: file),
              let root = document.rootElement(),
              let objectsContainer = root.elements(forName: "Objects").first else {
            return []
        }

        return (objectsContainer.children ?? [])
            .compactMap { $0 as? XMLElement }
            .filter { $0.name == "Object" }
            .flatMap { object -> [TextureAsset] in
                guard let objectName = object.attribute(forName: "Name")?.stringValue,
                      !objectName.isEmpty else {
                    return []
                }
                if filename == "traps.xml", !standaloneTrapObjects.contains(objectName) {
                    return []
                }

                let base = TextureAsset(
                    group: "Library",
                    kind: .libraryObject,
                    category: file.lastPathComponent,
                    name: objectName,
                    className: objectName,
                    filePath: file.path,
                    defaultLayer: "Default",
                    libraryObjectName: objectName,
                    libraryOverrides: contentVariableDefaults(for: object)
                )

                // Trap booleans are runtime controls, not visual variants.
                // Turning ControllerOff/EnableArea/AllowTesla into browser cards
                // creates contradictory or disabled trap configurations.
                return filename == "traps.xml" || filename.lowercased().hasPrefix("v2trap_")
                    ? [base]
                    : [base] + libraryVariantAssets(for: object, objectName: objectName, file: file)
            }
    }

    private static func libraryVariantAssets(for object: XMLElement, objectName: String, file: URL) -> [TextureAsset] {
        guard let contentVariable = (try? object.nodes(forXPath: "./Properties/Static/ContentVariable").first) as? XMLElement else {
            return []
        }

        let boolVariables = (contentVariable.children ?? [])
            .compactMap { $0 as? XMLElement }
            .filter { $0.name == "Variable" && $0.attribute(forName: "Type")?.stringValue == "E_Bool" }
            .compactMap { variable -> (name: String, defaultValue: String)? in
                let name = variable.attribute(forName: "Name")?.stringValue ?? ""
                guard !name.isEmpty else { return nil }
                let defaultValue = variable.attribute(forName: "Default")?.stringValue ?? "0"
                return (name, defaultValue)
            }

        guard !boolVariables.isEmpty else { return [] }
        let defaultOverrides = contentVariableDefaults(for: object)
        return boolVariables.map { variableName in
            let label = libraryVariantLabel(for: variableName.name)
            var overrides = defaultOverrides
            let groupKey = directionalVariantGroupKey(for: variableName.name)
            for otherVariable in boolVariables where directionalVariantGroupKey(for: otherVariable.name) == groupKey {
                overrides[otherVariable.name] = "0"
            }
            overrides[variableName.name] = "1"
            return TextureAsset(
                group: "Library",
                kind: .libraryObject,
                category: file.lastPathComponent,
                name: "\(objectName) \(label)",
                className: objectName,
                filePath: file.path,
                defaultLayer: "Default",
                libraryObjectName: objectName,
                libraryOverrides: overrides,
                libraryVariantRootName: variableName.name
            )
        }
    }

    private static func contentVariableDefaults(for object: XMLElement) -> [String: String] {
        guard let contentVariable = (try? object.nodes(forXPath: "./Properties/Static/ContentVariable").first) as? XMLElement else {
            return [:]
        }
        return Dictionary(uniqueKeysWithValues: (contentVariable.children ?? []).compactMap { child in
            guard let element = child as? XMLElement,
                  element.name == "Variable",
                  let name = element.attribute(forName: "Name")?.stringValue,
                  !name.isEmpty else { return nil }
            return (name, element.attribute(forName: "Default")?.stringValue ?? "")
        })
    }

    private static func libraryVariantLabel(for variableName: String) -> String {
        if let directionalLabel = directionalVariantLabel(for: variableName) {
            return directionalLabel
        }
        let words = splitVariantName(variableName)
        guard !words.isEmpty else { return variableName }
        return words
            .map { $0.capitalized }
            .joined(separator: " ")
    }

    private static func directionalVariantLabel(for variableName: String) -> String? {
        let tokens = splitVariantName(variableName)
        let directionalTokens = tokens.filter { token in
            directionalVariantTokens.contains(token)
        }
        guard !directionalTokens.isEmpty else { return nil }
        return directionalTokens
            .map { $0 == "close" ? "Closed" : $0.capitalized }
            .joined(separator: " ")
    }

    private static func directionalVariantGroupKey(for variableName: String) -> String {
        splitVariantName(variableName)
            .compactMap { token -> String? in
                guard !directionalVariantTokens.contains(token) else { return nil }
                let stripped = token.replacingOccurrences(of: #"(?i)(speed|variant)?\d+$"#, with: "$1", options: .regularExpression)
                return stripped.isEmpty ? nil : stripped
            }
            .joined(separator: "_")
    }

    private static let directionalVariantTokens: Set<String> = [
        "left", "right", "top", "bottom", "up", "down",
        "upper", "lower", "ceiling", "floor",
        "inner", "outer", "open", "opened", "closed", "close"
    ]

    private static func splitVariantName(_ variableName: String) -> [String] {
        let spaced = variableName
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: #"([a-z0-9])([A-Z])"#, with: "$1 $2", options: .regularExpression)
        return spaced
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    private static func defaultLayer(for category: String) -> String {
        switch category {
        case let value where value.contains("lights"): return "Lights"
        case let value where value.contains("warning_signs"): return "HoloWarningSigns"
        case let value where value.contains("black"): return "Black"
        case let value where value.contains("zone"): return "Wall"
        default: return "CPanels"
        }
    }

    private static func editorTextureDefaultLayer(for name: String) -> String {
        let lowercased = name.lowercased()
        if lowercased.contains("trigger") || lowercased.contains("trick") {
            return "Default"
        }
        if lowercased.contains("collision") || lowercased.contains("platform") || lowercased.contains("trapezoid") {
            return "Default"
        }
        return "Editor"
    }

    private static func texturePathIndex() -> [String: String] {
        var textureCategories: [TextureCategory] = []
        for textureBankRoot in textureBankRoots() {
            textureCategories.append(contentsOf: loadFlatTextureBank(from: textureBankRoot))
        }
        textureCategories.append(contentsOf: loadDevelopmentRunSprites())
        textureCategories.append(contentsOf: loadReleaseTextures())

        // Library previews resolve their Image ClassName through this index,
        // not through the visible asset-browser categories. Keep custom art in
        // both paths or a v2trap object appears as trigger rectangles only.
        var customFolders: [String] = []
        if let project = activeProjectRootURL() {
            customFolders.append(project.appendingPathComponent("custom_textures", isDirectory: true).path)
            customFolders.append(project.appendingPathComponent("custom_backgrounds", isDirectory: true).path)
        }
        if let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let vectorRoot = support
                .appendingPathComponent("Nekki", isDirectory: true)
                .appendingPathComponent("Vector 2", isDirectory: true)
            customFolders.append(vectorRoot.appendingPathComponent("custom_textures", isDirectory: true).path)
            customFolders.append(vectorRoot.appendingPathComponent("custom_backgrounds", isDirectory: true).path)
        }
        textureCategories.append(contentsOf: loadImportedFolders(Array(Set(customFolders))))

        var index: [String: String] = [:]
        let rankedAssets = textureCategories
            .flatMap(\.assets)
            .filter { $0.kind == .texture }
            .sorted { lhs, rhs in
                textureQualityRank(lhs) < textureQualityRank(rhs)
            }

        for asset in rankedAssets {
            if index[asset.className] == nil {
                index[asset.className] = asset.filePath
            }
            if index[asset.name] == nil {
                index[asset.name] = asset.filePath
            }
        }
        return index
    }

    private static func textureQualityRank(_ asset: TextureAsset) -> Int {
        let key = "\(asset.category)/\(asset.name)/\(asset.className)".lowercased()
        if key.contains("/low/") || key.contains("_low") || key.contains(" low") {
            return 10
        }
        if key.contains("high") { return 0 }
        if key.contains("medium") { return 1 }
        if asset.group == "Vector 2 Textures" { return 0 }
        if asset.group == "Vector 2 Editor Textures" { return 1 }
        return 2
    }

    private static func mergeCategories(_ categories: [TextureCategory]) -> [TextureCategory] {
        var buckets: [String: [TextureAsset]] = [:]
        var order: [String] = []
        for category in categories {
            let key = category.id
            if buckets[key] == nil {
                buckets[key] = []
                order.append(key)
            }

            let existingPaths = Set((buckets[key] ?? []).map(\.filePath))
            buckets[key]?.append(contentsOf: category.assets.filter { !existingPaths.contains($0.filePath) })
        }

        return order.compactMap { key in
            guard let slash = key.firstIndex(of: "/"),
                  let assets = buckets[key],
                  !assets.isEmpty else {
                return nil
            }
            let group = String(key[..<slash])
            let name = String(key[key.index(after: slash)...])
            return TextureCategory(group: group, name: name, assets: assets)
        }
    }

    private static func assetPathIndexByGUID() -> [String: String] {
        let candidateRoots: [URL] = [
            projectAssetsRoot,
            existingDirectoryURL(at: developmentUnityAssetsRoot),
            existingDirectoryURL(at: developmentReleaseAssetsRoot),
            existingDirectoryURL(at: developmentVectorierAssetsRoot),
            Bundle.main.resourceURL?.appendingPathComponent("ProjectAssets").appendingPathComponent("Vector2")
        ].compactMap { $0 }

        var index: [String: String] = [:]
        for root in candidateRoots {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for case let url as URL in enumerator where url.pathExtension.lowercased() == "meta" {
                guard let text = try? String(contentsOf: url, encoding: .utf8),
                      let guidLine = text.split(separator: "\n").first(where: { $0.hasPrefix("guid: ") }) else {
                    continue
                }

                let guid = String(guidLine.dropFirst("guid: ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                if guid.isEmpty || index[guid] != nil {
                    continue
                }

                let assetURL = url.deletingPathExtension()
                if FileManager.default.fileExists(atPath: assetURL.path) {
                    index[guid] = assetURL.path
                }
            }
        }

        return index
    }

    private static func existingDirectoryURL(at path: String) -> URL? {
        let url = URL(fileURLWithPath: path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private static func spriteGUIDIndex() -> [String: String] {
        let urls: [URL] = [
            projectAssetsRoot?.appendingPathComponent("PrefabSpriteGuidMap.tsv"),
            Bundle.main.resourceURL?.appendingPathComponent("PrefabSpriteGuidMap.tsv")
        ].compactMap { $0 }

        guard let url = urls.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return [:]
        }

        var index: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                index[parts[0]] = parts[1]
            }
        }
        return index
    }
}
