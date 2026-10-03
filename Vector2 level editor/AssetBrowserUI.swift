//
//  AssetBrowserUI.swift
//  Vector2 level editor
//
//  Asset discovery belongs to Vector2AssetCatalog. Everything a human clicks
//  after discovery lives here: thumbnails, browser window, and asset settings.
//  That split matters because changing UI layout should never risk changing
//  which Vector 2 files/classes/variants the catalog actually discovers.
//

import AppKit
import Foundation
import SwiftUI

/// Small shared NSImage cache for thumbnails/canvas previews.
///
/// Without this, scrolling the asset browser and canvas would repeatedly decode
/// the same PNGs and feel way slower.
final class CachedImageStore {
    static let shared = CachedImageStore()
    private let cache = NSCache<NSString, NSImage>()
    private let thumbnailCache = NSCache<NSString, NSImage>()

    private init() {
        cache.countLimit = 1_400
        thumbnailCache.countLimit = 900
    }

    func image(at path: String) -> NSImage? {
        guard !path.isEmpty else { return nil }
        let key = path as NSString
        if let image = cache.object(forKey: key) {
            return image
        }
        let image: NSImage?
        if path.hasPrefix("asset://") {
            image = NSImage(named: String(path.dropFirst("asset://".count)))
        } else {
            image = NSImage(contentsOfFile: path)
        }
        guard let image else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    func thumbnail(at path: String, maxPixelSize: CGFloat = 256) -> NSImage? {
        guard let image = image(at: path), image.size.width > 0, image.size.height > 0 else { return nil }
        let key = "\(path)|thumb|\(Int(maxPixelSize))" as NSString
        if let cached = thumbnailCache.object(forKey: key) {
            return cached
        }
        let scale = min(1, maxPixelSize / max(image.size.width, image.size.height))
        let targetSize = NSSize(width: max(1, image.size.width * scale), height: max(1, image.size.height * scale))
        let thumbnail = NSImage(size: targetSize)
        thumbnail.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: targetSize),
                   from: NSRect(origin: .zero, size: image.size),
                   operation: .copy,
                   fraction: 1)
        thumbnail.unlockFocus()
        thumbnailCache.setObject(thumbnail, forKey: key)
        return thumbnail
    }
}

/// Separate asset browser window content.
///
/// Asset cards call `onPlace`; the main editor decides whether the selected tool
/// can place that asset as an image, background, object reference, or object.
struct AssetBrowserSheet: View {
    let catalog: [TextureCategory]
    let onPlace: (TextureAsset) -> Void
    @State private var selectedGroup = "Vector 2 Textures"
    @State private var selectedCategory = ""
    @State private var query = ""

    private var visibleCatalog: [TextureCategory] {
        catalog.filter { category in
            !category.assets.allSatisfy { $0.kind == .prefab }
        }
    }

    private var groups: [String] {
        Array(Set(visibleCatalog.map(\.group))).sorted { lhs, rhs in
            groupSortOrder(lhs) < groupSortOrder(rhs)
        }
    }

    private var groupAssetCounts: [String: Int] {
        Dictionary(grouping: visibleCatalog, by: \.group)
            .mapValues { categories in categories.reduce(0) { $0 + $1.assets.count } }
    }

    private var visibleCategories: [TextureCategory] {
        visibleCatalog.filter { $0.group == selectedGroup }
    }

    private var selectedAssets: [TextureAsset] {
        let categories = selectedCategory.isEmpty
            ? visibleCategories
            : visibleCategories.filter { $0.name == selectedCategory }
        let assets = categories.flatMap(\.assets)
        guard !query.isEmpty else { return assets }
        return assets.filter {
            $0.name.localizedCaseInsensitiveContains(query) ||
            $0.className.localizedCaseInsensitiveContains(query) ||
            $0.category.localizedCaseInsensitiveContains(query) ||
            ($0.libraryOverrides["Search"]?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Asset Browser")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("\(assetCount(for: "Vector 2 Textures")) Vector 2 textures · \(assetCount(for: "Library")) library objects")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.68))
                }
                Spacer()
                Button {
                    NotificationCenter.default.post(name: .vector2ClearImportedAssetsRequested, object: nil)
                } label: {
                    Label("Clear Imports", systemImage: "trash")
                }
                .help("Forget imported asset folders without deleting their files")
                TextField("Search assets", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
            }
            .padding(16)
            .background(Color(red: 0.13, green: 0.14, blue: 0.15))

            Divider()

            HStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(groups, id: \.self) { group in
                            Button {
                                selectedGroup = group
                                selectedCategory = ""
                            } label: {
                                HStack {
                                    Text(group)
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(Color.editorPrimaryText.opacity(0.82))
                                    Spacer()
                                    Text("\(groupAssetCounts[group] ?? 0)")
                                        .font(.system(size: 10))
                                        .foregroundStyle(Color.editorSecondaryText)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(selectedGroup == group && selectedCategory.isEmpty ? Color.accentColor.opacity(0.16) : Color.clear)
                                .cornerRadius(6)
                            }
                            .buttonStyle(.plain)
                        }

                        Divider().padding(.vertical, 4)

                        ForEach(visibleCategories) { category in
                            Button {
                                selectedCategory = category.name
                            } label: {
                                HStack {
                                    Text(category.name)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(Color.editorPrimaryText.opacity(0.78))
                                    Spacer()
                                    Text("\(category.assets.count)")
                                        .font(.system(size: 10))
                                        .foregroundStyle(Color.editorSecondaryText)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(selectedCategory == category.name ? Color.accentColor.opacity(0.12) : Color.clear)
                                .cornerRadius(6)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(12)
                }
                .frame(width: 220)
                .background(Color.platformControlBackground)

                Divider()

                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 14)], spacing: 14) {
                        ForEach(selectedAssets) { asset in
                            Button {
                                onPlace(asset)
                            } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    AssetThumbnail(asset: asset)
                                        .frame(height: 96)
                                        .frame(maxWidth: .infinity)
                                        .background(Color.editorSecondaryText.opacity(0.10))
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                    Text(asset.kind.rawValue.uppercased())
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(Color.accentColor)
                                    Text(asset.name)
                                        .font(.system(size: 11, weight: .semibold))
                                        .lineLimit(2)
                                        .foregroundStyle(Color.editorPrimaryText.opacity(0.86))
                                    Text(asset.className)
                                        .font(.system(size: 10, design: .monospaced))
                                        .lineLimit(1)
                                        .foregroundStyle(Color.editorSecondaryText)
                                }
                                .padding(10)
                                .background(Color.platformControlBackground)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(Color.editorHairline, lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(minWidth: 760, minHeight: 480)
        .onAppear {
            if !groups.contains(selectedGroup) {
                selectedGroup = groups.first ?? ""
            }
        }
    }

    private func groupSortOrder(_ group: String) -> String {
        switch group {
        case "Vector 2 Textures": return "0"
        case "Library": return "2"
        case "Prefabs": return "3"
        case "Runtime Prefabs": return "4"
        case "Game Prefabs": return "5"
        case "Imported": return "6"
        default: return "9\(group)"
        }
    }

    private func assetCount(for group: String) -> Int {
        groupAssetCounts[group] ?? 0
    }
}

/// Thumbnail card preview.
///
/// Uses real texture paths when available; otherwise tries generated library
/// previews. Gray placeholders mean the resolver could not build a visual.
@MainActor
private enum AssetThumbnailPreviewCache {
    private struct Preview {
        let path: String?
    }

    private static var previews: [String: Preview] = [:]

    static func previewPath(for asset: TextureAsset) -> String? {
        let key = "\(asset.kind.rawValue)|\(asset.filePath)|\(asset.name)|\(asset.className)|\(asset.libraryObjectName)|\(asset.libraryVariantRootName)"
        if let cached = previews[key] {
            return cached.path
        }
		let preview: String?
		if !asset.obstaclePackagePath.isEmpty, !asset.filePath.isEmpty {
			// Obstacle packages already carry the exact preview rendered by their
			// author. Their stable IDs are not stock library objects and therefore
			// cannot be reconstructed by the Vector 2 library resolver.
			preview = asset.filePath
			previews[key] = Preview(path: preview)
			return preview
		}
		switch asset.kind {
        case .texture:
            preview = asset.filePath
        case .libraryObject:
            preview = Vector2LibraryObjectBuilder.reconstruct(asset: asset, x: 0, y: 0)?.metadata.imagePath
        case .prefab:
            preview = UnityPrefabObjectBuilder.reconstruct(asset: asset, x: 0, y: 0)?.metadata.imagePath
        }
        previews[key] = Preview(path: preview)
        return preview
    }
}

struct AssetThumbnail: View {
    let asset: TextureAsset
    @State private var resolvedPreviewPath: String?

    var body: some View {
        Group {
            if asset.kind == .texture, let image = CachedImageStore.shared.image(at: asset.filePath) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .padding(8)
            } else if let previewPath = previewPath,
                      let image = CachedImageStore.shared.image(at: previewPath) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .padding(8)
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.18))
                    .overlay(
                        VStack(spacing: 6) {
                            Image(systemName: asset.kind == .prefab ? "shippingbox" : "doc.richtext")
                                .font(.system(size: 26))
                            Text(asset.kind.rawValue)
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundStyle(.secondary)
                )
            }
        }
        .task(id: asset.id) {
            await Task.yield()
            resolvedPreviewPath = AssetThumbnailPreviewCache.previewPath(for: asset)
        }
    }

    private var previewPath: String? {
        guard let resolvedPreviewPath, !resolvedPreviewPath.isEmpty else {
            return nil
        }
        return resolvedPreviewPath
    }

}

final class AssetBrowserWindowController: NSObject, NSWindowDelegate {
    private static var shared: AssetBrowserWindowController?
    private var window: NSWindow?

    static func show(catalog: [TextureCategory], onPlace: @escaping (TextureAsset) -> Void) {
        if let shared {
            shared.window?.makeKeyAndOrderFront(nil)
            return
        }

        let controller = AssetBrowserWindowController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Asset Browser"
        window.center()
        window.minSize = NSSize(width: 760, height: 480)
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: AssetBrowserSheet(catalog: catalog, onPlace: onPlace))
        window.delegate = controller
        controller.window = window
        shared = controller
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window?.contentView = nil
        window = nil
        Self.shared = nil
    }
}

/// Settings modal.
///
/// Stores paths/bookmarks for the Vector 2 app, custom_rooms folder, importer
/// strategy, and extra asset folders. These settings are intentionally user-
/// selected so the app can later survive Windows paths and public installs.
struct SettingsSheet: View {
    @Binding var selectedImportPipelineRaw: String
    let assetCatalog: [TextureCategory]
    let currentDocumentName: String
    @Binding var gameDirectory: String
    @Binding var customRoomsDirectory: String
    @Binding var customBackgroundsDirectory: String
    @Binding var customTexturesDirectory: String
    @Binding var gameDirectoryBookmark: String
    @Binding var customRoomsDirectoryBookmark: String
    @Binding var extraAssetFoldersData: String
    let onRefreshAssets: () -> Void
    @AppStorage("vector2.snapToGrid") private var snapToGrid = true
    @AppStorage("vector2RoomWeaverConsoleEnabled") private var roomWeaverConsoleEnabled = false
    @AppStorage("vector2RoomWeaverVerboseDiagnostics") private var roomWeaverVerboseDiagnostics = false
    @AppStorage("vector2TrickPreviewConsoleEnabled") private var trickPreviewConsoleEnabled = false
    @AppStorage("vector2TrickPreviewShowSkeletonPoints") private var trickPreviewShowSkeletonPoints = true
    @AppStorage("vector2TrickPreviewShowDetectorDots") private var trickPreviewShowDetectorDots = true
    @AppStorage("vector2TrickPreviewShowModelNodeSpheres") private var trickPreviewShowModelNodeSpheres = true
    @AppStorage("vector2TrickPreviewShowModelSphereOutlines") private var trickPreviewShowModelSphereOutlines = true
    @AppStorage("vector2TrickPreviewBatterySaver") private var trickPreviewBatterySaver = false
    @AppStorage("vector2.editorDarkMode") private var editorDarkMode = false
    @AppStorage("vector2.showLibraryHelperOverlays") private var showLibraryHelperOverlays = true
    @AppStorage("vector2.showDynamicBadges") private var showDynamicBadges = true
    @AppStorage("vector2.trapezoidVisualizer") private var trapezoidVisualizer = "image"
    @AppStorage("vector2.triggerPredictiveCoding") private var triggerPredictiveCoding = true
    @AppStorage("vector2.fullLiveRotationPreview") private var fullLiveRotationPreview = false
    @AppStorage("vector2.hierarchyFollowsSelection") private var hierarchyFollowsSelection = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Settings")
                        .font(.system(size: 24, weight: .semibold))
                    Text("Appearance, imports, canvas controls and game folders.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                settingsSection("Appearance") {
                    Toggle("Dark mode", isOn: $editorDarkMode)
                        .toggleStyle(.checkbox)
                    Text("Use a dark theme. Turn this off for light mode.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                settingsSection("Import") {
                    Picker("XML Loader", selection: $selectedImportPipelineRaw) {
                        ForEach(Vector2ImportPipeline.allCases) { pipeline in
                            Text(pipeline.title).tag(pipeline.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text(importPipelineDescription)
                        .font(.system(size: 12))
                        .foregroundStyle(selectedImportPipelineRaw == Vector2ImportPipeline.convertXmlObject2.rawValue ? Color.orange : Color.secondary)

                    Toggle("Show RoomWeaver import console", isOn: $roomWeaverConsoleEnabled)
                        .toggleStyle(.checkbox)
                    Text("Keeps the summary at the top and adds resolver/layout detail below it.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    Toggle("Verbose RoomWeaver diagnostics", isOn: $roomWeaverVerboseDiagnostics)
                        .toggleStyle(.checkbox)
                    Text("Adds import breakdowns and named slow-operation timings. Work over 16.67 ms is marked as a frame-budget warning.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                }

                settingsSection("Trick Preview") {
                    Toggle("Show Trick Preview console", isOn: $trickPreviewConsoleEnabled)
                        .toggleStyle(.checkbox)
                    Text("Shows model, animation, and selected-trick lookup details while building trick previews.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    Toggle("Trick Preview battery saver", isOn: $trickPreviewBatterySaver)
                        .toggleStyle(.checkbox)
                    Text("Runs the preview at a lighter refresh rate only when you choose it. Useful when battery or heat matters.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                settingsSection("Model Display") {
                    Toggle("Show trick skeleton points", isOn: $trickPreviewShowSkeletonPoints)
                        .toggleStyle(.checkbox)
                    Text("Turns the small white raw animation points on or off.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    Toggle("Show trick detector dot", isOn: $trickPreviewShowDetectorDots)
                        .toggleStyle(.checkbox)
                    Text("Turns the orange pivot/detector point on or off separately from the skeleton points.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    Toggle("Show trick model joint spheres", isOn: $trickPreviewShowModelNodeSpheres)
                        .toggleStyle(.checkbox)
                    Text("Turns the model's own black sphere nodes on or off.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    Toggle("Show trick model highlights", isOn: $trickPreviewShowModelSphereOutlines)
                        .toggleStyle(.checkbox)
                    Text("Draws the faint white rim and limb highlight strokes. Turn it off for a clean black model silhouette.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                settingsSection("Canvas") {
                    Toggle("Hierarchy follows selection", isOn: $hierarchyFollowsSelection)
                        .toggleStyle(.checkbox)
                    Text("Expands the selected object's parents and scrolls to its row. Turn it off to keep your place in the hierarchy.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Toggle("Snap movement and resizing to 10 Vector units", isOn: $snapToGrid)
                        .toggleStyle(.checkbox)
                    Text("Hold V while dragging or resizing to snap corners to nearby object corners.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    Toggle("Full live rotation preview", isOn: $fullLiveRotationPreview)
                        .toggleStyle(.checkbox)
                    Text("Uses the old full-rate behavior where the object, selection box, and rotation handle move together on every pointer update. Leave it off for smoother rotation in packed rooms.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    Toggle("Show library trigger and area helper boxes", isOn: $showLibraryHelperOverlays)
                        .toggleStyle(.checkbox)
                    Text("Imported helper boxes stay editable/visible. Turn this off only when inspecting huge rooms.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    Toggle("Show dynamic tags", isOn: $showDynamicBadges)
                        .toggleStyle(.checkbox)
                    Text("Shows the cyan DYNAMIC badges on movable imported assemblies. Turning this off changes only the editor overlay.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    Picker("Trapezoid visualizer", selection: $trapezoidVisualizer) {
                        Text("Image").tag("image")
                        Text("Polygon").tag("polygon")
                    }
                    .pickerStyle(.segmented)
                    Text("Switches only the editor preview. Export still writes Vector 2 trapezoid XML.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                settingsSection("Trigger Designer") {
                    Toggle("Predict trigger XML", isOn: $triggerPredictiveCoding)
                        .toggleStyle(.checkbox)
                    Text("Shows game-backed event, condition and action suggestions beside the trigger XML editor. Validation stays enabled either way.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                settingsSection("Project") {
                    Text("Current Document: \(currentDocumentName)")
                    Text("Texture Categories Loaded: \(assetCatalog.count)")
                    Text("XML Loader: \(Vector2ImportPipeline(rawValue: selectedImportPipelineRaw)?.title ?? Vector2ImportPipeline.roomWeaver.title)")
                    Text("BuildMap Vec2 coordinates stay locked to the XML contract.")
                        .foregroundStyle(.secondary)
                }

                settingsSection("Paths") {
                    pathRow(
                        title: "Vector 2 Game Directory",
                        value: gameDirectory.isEmpty ? "Not set" : gameDirectory,
                        buttonTitle: "Choose...",
                        action: chooseGameDirectory
                    )
                    pathRow(
                        title: "Vector 2 Custom Rooms Folder",
                        value: customRoomsDirectory.isEmpty ? "Default Vector 2 custom_rooms folder" : customRoomsDirectory,
                        buttonTitle: "Choose...",
                        action: chooseCustomRoomsDirectory
                    )
                    pathRow(
                        title: "Vector 2 Custom Backgrounds Folder",
                        value: customBackgroundsDirectory.isEmpty ? "Choose the shared custom_backgrounds folder" : customBackgroundsDirectory,
                        buttonTitle: "Choose...",
                        action: chooseCustomBackgroundsDirectory
                    )
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Imported Asset Folders")
                            .font(.system(size: 12, weight: .semibold))
                        Text(extraAssetFoldersData.isEmpty ? "No extra folders imported" : extraAssetFoldersData)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(4)
                            .truncationMode(.middle)
                        HStack {
                            Button("Add Image Folder...") {
                                addAssetFolder()
                            }
                            Button("Refresh Assets") {
                                onRefreshAssets()
                            }
                            Button("Clear Imported Assets", role: .destructive) {
                                extraAssetFoldersData = ""
                                onRefreshAssets()
                            }
                            .disabled(extraAssetFoldersData.isEmpty)
                        }
                    }
                }
            }
            .padding(24)
        }
        .frame(width: 720, height: 560)
    }

    private func settingsSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) {
                content()
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.platformControlBackground, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.editorHairline))
        }
    }

    private func pathRow(title: String, value: String, buttonTitle: String, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
            HStack {
                Text(value)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(buttonTitle, action: action)
            }
        }
    }

    private var importPipelineDescription: String {
        switch Vector2ImportPipeline(rawValue: selectedImportPipelineRaw) ?? .roomWeaver {
        case .roomWeaver:
            return "Best for real Vector 2 rooms. Resolves room choices, library XML, helper triggers, and game-style visual layout."
        case .runtimeGraph:
            return "Stable graph loader. Best for inspecting raw XML structure without RoomWeaver's room/layout expansion."
        case .convertXmlObject2:
            return "Experimental variable resolver. Not recommended for normal editing; use it only when debugging tricky library variables."
        }
    }

    private func chooseGameDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            gameDirectory = url.path
            gameDirectoryBookmark = Self.securityScopedBookmarkString(for: url)
        }
    }

    private func chooseCustomRoomsDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            customRoomsDirectory = url.path
            customRoomsDirectoryBookmark = Self.securityScopedBookmarkString(for: url)
        }
    }

    private func chooseCustomBackgroundsDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.identifier = NSUserInterfaceItemIdentifier("vector2.custom-backgrounds-folder-picker")
        if !customBackgroundsDirectory.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: customBackgroundsDirectory, isDirectory: true)
        }
        if panel.runModal() == .OK, let url = panel.url {
            customBackgroundsDirectory = url.path
        }
    }

    private func chooseCustomTexturesDirectory() {
        let preservedBackgroundsDirectory = customBackgroundsDirectory
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.identifier = NSUserInterfaceItemIdentifier("vector2.custom-textures-folder-picker")
        if !customTexturesDirectory.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: customTexturesDirectory, isDirectory: true)
        }
        if panel.runModal() == .OK, let url = panel.url {
            customTexturesDirectory = url.path
        }
        // NSOpenPanel keeps process-wide navigation state. This picker owns only
        // the texture path, so never allow a modal refresh to leak into the
        // independently persisted custom-backgrounds binding.
        if customBackgroundsDirectory != preservedBackgroundsDirectory {
            customBackgroundsDirectory = preservedBackgroundsDirectory
        }
    }

    private func addAssetFolder() {
        let preservedBackgroundsDirectory = customBackgroundsDirectory
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.identifier = NSUserInterfaceItemIdentifier("vector2.extra-assets-folder-picker")
        if panel.runModal() == .OK {
            let existing = Set(extraAssetFoldersData.split(separator: "\n").map(String.init))
            let additions = panel.urls.map(\.path).filter { !existing.contains($0) }
            extraAssetFoldersData = (Array(existing).sorted() + additions).joined(separator: "\n")
            onRefreshAssets()
        }
        if customBackgroundsDirectory != preservedBackgroundsDirectory {
            customBackgroundsDirectory = preservedBackgroundsDirectory
        }
    }

    private static func securityScopedBookmarkString(for url: URL) -> String {
        guard let data = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else {
            return ""
        }
        return data.base64EncodedString()
    }
}
