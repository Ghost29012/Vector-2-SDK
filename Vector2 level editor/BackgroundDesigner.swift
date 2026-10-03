import SwiftUI
import Foundation
import AppKit
import Combine
import UniformTypeIdentifiers

struct CustomBackgroundDefinition: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var pieces: [String]
    var zone: String? = nil
}

private struct StockBackgroundDefinition: Identifiable {
    let name: String
    let xml: String
    let libraryURL: URL
    var id: String { name }
}

@MainActor final class BackgroundDiagnostics: ObservableObject {
    static let shared = BackgroundDiagnostics()
    @Published var lines: [String] = []
    func log(_ message: String) {
        lines.append("[Background] \(message)")
        if lines.count > 300 { lines.removeFirst(lines.count - 300) }
    }
}

enum CustomBackgroundStore {
    // Pool artwork can appear in any room, so strip the editor viewport origin.
    // Room backgrounds use their own save path and are deliberately untouched.
    static func normalizedPoolCatalogData(from url: URL) throws -> Data {
        let xml = try XMLDocument(contentsOf: url)
        if let root = xml.rootElement(), root.name == "Background" {
            root.attribute(forName: "Name")?.stringValue = url.deletingPathExtension().lastPathComponent
            normalizePoolPieces(in: root)
        }
        for background in xml.rootElement()?.elements(forName: "Background") ?? [] {
            normalizePoolPieces(in: background)
        }
        return xml.xmlData(options: .nodePrettyPrint)
    }

    static func normalizedPoolPieces(_ pieces: [String]) throws -> [String] {
        let root = XMLElement(name: "Background")
        for piece in pieces {
            let xml = try XMLDocument(xmlString: piece, options: [])
            if let node = xml.rootElement() { root.addChild(node.copy() as! XMLNode) }
        }
        normalizePoolPieces(in: root)
        return root.children?.compactMap { ($0 as? XMLElement)?.xmlString(options: .nodePrettyPrint) } ?? []
    }

    static func poolFile(for name: String, in folder: URL) -> URL? {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean != ".", clean != "..", clean != "custom_backgrounds",
              !clean.contains("/"), !clean.contains("\\"), !clean.contains(":"),
              !clean.contains("\n"), !clean.contains("\r") else { return nil }
        return folder.appendingPathComponent(clean + ".xml")
    }

    static func existingPoolFile(named name: String, in folder: URL) -> URL? {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .first { $0.pathExtension.lowercased() == "xml" &&
                $0.deletingPathExtension().lastPathComponent.caseInsensitiveCompare(name) == .orderedSame }
    }

    static func loadPool(from folder: URL) -> [CustomBackgroundDefinition] {
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "xml" && $0.lastPathComponent.lowercased() != "custom_backgrounds.xml" }
        let individual = files.compactMap { file -> CustomBackgroundDefinition? in
            guard let xml = try? XMLDocument(contentsOf: file),
                  let root = xml.rootElement(), root.name == "Background",
                  root.attribute(forName: "Name")?.stringValue != nil else { return nil }
            // Keep Finder's filename. Older builds could write
            // a differently cased Name into the same file on macOS.
            let name = file.deletingPathExtension().lastPathComponent
            let pieces = root.children?.compactMap { ($0 as? XMLElement)?.xmlString(options: .nodePrettyPrint) } ?? []
            return .init(name: name, pieces: pieces, zone: root.attribute(forName: "Zone")?.stringValue)
        }
        // Read old pool catalogs until the user next saves; never write new sets to that file.
        let names = Set(individual.map { $0.name.lowercased() })
        return individual + load(from: folder).filter { !names.contains($0.name.lowercased()) }
    }

    static func savePool(_ definition: CustomBackgroundDefinition, to folder: URL) throws {
        guard let destination = poolFile(for: definition.name, in: folder) else { throw CocoaError(.fileWriteInvalidFileName) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let existing = existingPoolFile(named: definition.name, in: folder),
           existing.lastPathComponent != destination.lastPathComponent {
            throw CocoaError(.fileWriteFileExists)
        }
        let root = XMLElement(name: "Background")
        root.addAttribute(XMLNode.attribute(withName: "Name", stringValue: definition.name) as! XMLNode)
        if let zone = definition.zone {
            root.addAttribute(XMLNode.attribute(withName: "Zone", stringValue: zone) as! XMLNode)
        }
        for piece in definition.pieces {
            let xml = try XMLDocument(xmlString: piece, options: [])
            if let node = xml.rootElement() { root.addChild(node.copy() as! XMLNode) }
        }
        try XMLDocument(rootElement: root).xmlData(options: .nodePrettyPrint).write(to: destination, options: .atomic)
    }

    static func migrateLegacyPool(in folder: URL) throws {
        let legacy = folder.appendingPathComponent("custom_backgrounds.xml")
        guard FileManager.default.fileExists(atPath: legacy.path) else { return }
        for definition in load(from: folder) {
            guard let target = poolFile(for: definition.name, in: folder) else {
                throw CocoaError(.fileWriteInvalidFileName)
            }
            if !FileManager.default.fileExists(atPath: target.path) {
                try savePool(.init(name: definition.name,
                                   pieces: normalizedPoolPieces(definition.pieces), zone: definition.zone), to: folder)
            }
        }
        // Keep the old XML recoverable, but outside the installed pool folder.
        let backup = folder.deletingLastPathComponent().appendingPathComponent("zone_pool_legacy_\(UUID().uuidString).bak")
        try FileManager.default.moveItem(at: legacy, to: backup)
    }

    private static func normalizePoolPieces(in background: XMLElement) {
        guard let nodes = try? background.nodes(forXPath: ".//Image | .//CustomAnimation") else { return }
        let images = nodes.compactMap { $0 as? XMLElement }
        // Asset-browser Choice/Default is not a room variant. Vector treats it
        // as a gate and silently skips the image when the choice is absent.
        for image in images {
            if let selections = try? image.nodes(forXPath: "Properties/Static/Selection") {
                selections.forEach { $0.detach() }
            }
        }
        let frames = images.map { image in
            CGRect(x: Double(image.attribute(forName: "X")?.stringValue ?? "0") ?? 0,
                   y: Double(image.attribute(forName: "Y")?.stringValue ?? "0") ?? 0,
                   width: max(0, Double(image.attribute(forName: "Width")?.stringValue ?? "0") ?? 0),
                   height: max(0, Double(image.attribute(forName: "Height")?.stringValue ?? "0") ?? 0))
        }
        let layers = images.map { $0.attribute(forName: "Layer")?.stringValue ?? "" }
        let factors = images.map { Double($0.attribute(forName: "Factor")?.stringValue ?? "1") ?? 1 }
        let normalized = BackgroundPlacementPolicy.normalizedPoolFrames(frames, layerKeys: layers, factors: factors)
        for (image, frame) in zip(images, normalized) {
            setIntegerAttribute("X", Int(frame.minX.rounded()), on: image)
            setIntegerAttribute("Y", Int(frame.minY.rounded()), on: image)
        }
    }

    private static func setIntegerAttribute(_ name: String, _ value: Int, on element: XMLElement) {
        element.removeAttribute(forName: name)
        element.addAttribute(XMLNode.attribute(withName: name, stringValue: String(value)) as! XMLNode)
    }

    static func load(from folder: URL) -> [CustomBackgroundDefinition] {
        let url = folder.appendingPathComponent("custom_backgrounds.xml")
        // A folder owns its own catalog. A missing file means an empty catalog;
        // never fall back to definitions remembered from a different folder.
        guard let xml = try? XMLDocument(contentsOf: url), let root = xml.rootElement() else { return [] }
        return root.children?.compactMap { node -> CustomBackgroundDefinition? in
            guard let element = node as? XMLElement, element.name == "Background",
                  let name = element.attribute(forName: "Name")?.stringValue,
                  !name.isEmpty else { return nil }
            let pieces = element.children?.compactMap { child -> String? in
                guard let piece = child as? XMLElement else { return nil }
                return piece.xmlString(options: [.nodePrettyPrint])
            } ?? []
            return .init(
                name: name,
                pieces: pieces,
                zone: element.attribute(forName: "Zone")?.stringValue
            )
        } ?? []
    }

    static func save(_ definition: CustomBackgroundDefinition, to folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent("custom_backgrounds.xml")
        let xml = (try? XMLDocument(contentsOf: destination)) ?? XMLDocument(rootElement: XMLElement(name: "CustomBackgrounds"))
        guard let root = xml.rootElement(), root.name == "CustomBackgrounds" else { throw CocoaError(.fileReadCorruptFile) }
        let existing = root.elements(forName: "Background").first {
            $0.attribute(forName: "Name")?.stringValue?.caseInsensitiveCompare(definition.name) == .orderedSame
        }
        let background = existing ?? XMLElement(name: "Background")
        if existing == nil { root.addChild(background) }
        background.removeAttribute(forName: "Name")
        background.addAttribute(XMLNode.attribute(withName: "Name", stringValue: definition.name) as! XMLNode)
        // Windows can use this same catalog shape: Zone is only set by the pool
        // designer. Room-specific backgrounds stay untagged unless already tagged.
        if let zone = definition.zone {
            background.removeAttribute(forName: "Zone")
            background.addAttribute(XMLNode.attribute(withName: "Zone", stringValue: zone) as! XMLNode)
        }
        for child in background.children ?? [] { child.detach() }
        for piece in definition.pieces {
            let wrapper = try XMLDocument(xmlString: "<Root>\(piece)</Root>", options: [])
            for child in wrapper.rootElement()?.children ?? [] { background.addChild(child.copy() as! XMLNode) }
        }
        try xml.xmlData(options: .nodePrettyPrint).write(to: destination, options: .atomic)
    }

    static func scenePieces(in document: LevelDocument) -> [String] {
        var ids: [LevelNode.ID] = []
        func walk(_ node: LevelNode) {
            if node.kind == .image && (node.metadata.tag.caseInsensitiveCompare("Background") == .orderedSame || node.metadata.sortingLayer.hasPrefix("Bg")) {
                ids.append(node.id)
            }
            node.children.forEach(walk)
        }
        walk(document.root)
        return ids.compactMap { id -> String? in
            let exported = document.exportedSelectionXML(for: id)
            guard let xml = try? XMLDocument(xmlString: exported, options: []),
                  let element = xml.rootElement(),
                  element.name == "Image" || element.name == "CustomAnimation" else { return nil }
            // The runtime uses Matrix; this editor-only angle keeps the canvas
            // round-trip exact when a saved set is loaded for more editing.
            if let rotation = document.node(for: id)?.transform?.rotation {
                element.removeAttribute(forName: "EditorRotation")
                element.addAttribute(XMLNode.attribute(withName: "EditorRotation", stringValue: "\(rotation)") as! XMLNode)
            }
            return element.xmlString(options: .nodePrettyPrint)
        }
    }

    static func sceneDiagnostics(in document: LevelDocument) -> [String] {
        var lines: [String] = []
        func walk(_ node: LevelNode) {
            if node.kind == .image,
               let t = node.transform,
               node.metadata.tag.caseInsensitiveCompare("Background") == .orderedSame || node.metadata.sortingLayer.hasPrefix("Bg") {
                lines.append("piece \(node.name) layer=\(node.metadata.sortingLayer) pos=(\(t.x),\(t.y)) size=(\(t.width),\(t.height)) rotation=\(t.rotation)")
            }
            node.children.forEach(walk)
        }
        walk(document.root)
        return lines
    }

    private static func indent(_ text: String) -> String { text.split(separator: "\n", omittingEmptySubsequences: false).map { "    " + $0 }.joined(separator: "\n") }
    private static func escape(_ text: String) -> String { text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "<", with: "&lt;") }
}

struct BackgroundDesignerOverlay: View {
    @Binding var document: LevelDocument
    @Binding var directoryPath: String
    @Binding var customTexturesDirectory: String
    let importedTexturesDirectories: [String]
    let projectRoot: URL?
    let onBrowseAssets: () -> Void
    let onPoolSaved: (String) -> Void
    let onInstallPool: () -> Void
    let onClose: () -> Void
    @State private var name = ""
    @State private var definitions: [CustomBackgroundDefinition] = []
    @State private var showConsole = false
    @State private var pendingRoomAssignment: String?
    @State private var poolDefinitions: [CustomBackgroundDefinition] = []
    @AppStorage("vector2ZonePoolDraftName") private var poolName = ""
    @AppStorage("vector2ZonePoolDraftZone") private var poolZoneID = ""
    @State private var selectedPoolName = ""
    @State private var zoneChoices: [(id: String, name: String)] = []
    @State private var confirmPoolDelete = false
    @State private var confirmPoolClear = false
    @State private var stockBackgrounds: [StockBackgroundDefinition] = []
    @State private var showStockBackgroundPicker = false

    private let backgroundLayers = ["BgFurther", "BgVeryVeryFar", "BgVeryFar", "BgFar", "BgMiddle", "BgClose", "BgVeryClose"]
    private var isPoolCanvas: Bool { document.sourcePath == "internal://zone-background-pool" }
    private var poolFolder: URL? { projectRoot?.appendingPathComponent("custom_backgrounds_pool", isDirectory: true) }

    private var selectedImage: LevelNode? {
        guard let node = document.selectedNode, node.kind == .image else { return nil }
        return node
    }

    private var poolControls: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("ZONE BACKGROUND POOL").font(.caption.bold()).foregroundStyle(.secondary)
            Text("Place and resize artwork on the main canvas. This saves a random-pool option, not a room assignment.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Background name", text: $poolName)
            Picker("Zone", selection: $poolZoneID) {
                Text("Choose a zone").tag("")
                ForEach(zoneChoices, id: \.id) { zone in Text(zone.name).tag(zone.id) }
            }
            HStack {
                Picker("Saved set", selection: $selectedPoolName) {
                    Text("Choose a saved set").tag("")
                    ForEach(poolDefinitions) { definition in
                        Text("\(definition.name) · \(definition.zone ?? "Unknown zone")").tag(definition.name)
                    }
                }
                Button("Load on Canvas", action: loadPoolSet).disabled(selectedPoolName.isEmpty)
                Button("Delete Saved", role: .destructive) { confirmPoolDelete = true }
                    .disabled(selectedPoolName.isEmpty)
            }
            HStack {
                Button("New Set") { confirmPoolClear = true }
                Button("Add from Assets", action: onBrowseAssets)
                Button("Import Texture", action: importTexture)
                stockBackgroundMenu
                Spacer()
                Button("Save to Zone Pool", action: savePoolBackground)
                Button("Install to Game", action: onInstallPool).buttonStyle(.borderedProminent)
            }
            Text("Every saved set for this zone stays in the random pool. Delete old sets here if you don't want the game to pick them.")
                .font(.caption2).foregroundStyle(.secondary)
        }.frame(minWidth: 430, maxWidth: .infinity, alignment: .leading)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(isPoolCanvas ? "Background Designer · Zone Pool" : "Background Designer", systemImage: "photo.on.rectangle.angled").font(.headline)
                Text(selectedImage.map { "Editing \($0.name)" } ?? "Select an image on the canvas").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { showConsole.toggle() } label: { Label("Console", systemImage: "terminal") }
                Button(action: onClose) { Image(systemName: "xmark") }.help("Close Background Designer")
            }
            .padding(.horizontal, 14).frame(height: 42).background(Color.platformControlBackground)
            Divider()

            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("SELECTED IMAGE").font(.caption.bold()).foregroundStyle(.secondary)
                    if let image = selectedImage {
                        Toggle("Include in background", isOn: includeBinding(for: image))
                        Toggle("Parallax", isOn: parallaxBinding(for: image))
                        Picker("Depth", selection: layerBinding(for: image)) {
                            ForEach(backgroundLayers, id: \.self) { Text($0).tag($0) }
                        }
                        HStack {
                            Text("Factor")
                            Slider(value: factorBinding(for: image), in: 0.05...0.95, step: 0.05)
                            Text(currentFactorText(for: image)).monospacedDigit().frame(width: 38, alignment: .trailing)
                        }.disabled(!isParallaxEnabled(image))
                        if isParallaxEnabled(image),
                           let factor = Double(document.node(for: image.id)?.factor ?? image.factor),
                           !BackgroundPlacementPolicy.isStockLikeParallaxFactor(factor) {
                            Label("Strong parallax. Stock Vector backgrounds use 0.65–0.95.", systemImage: "exclamationmark.triangle")
                                .font(.caption2).foregroundStyle(.orange)
                                .lineLimit(nil)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Button("Fit to Vector Size", systemImage: "arrow.down.right.and.arrow.up.left") {
                            fitToVectorSize(image)
                        }
                        .help("Scale this image down proportionally to Vector 2's largest shipped background-image bounds.")
                        Button("Reset Values", systemImage: "arrow.counterclockwise") {
                            resetValues(for: image)
                        }
                        Text("Higher factors move less against the camera. Vector 2 calculates vertical parallax from this value and the selected Bg layer.")
                            .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Pick an Image node, then enable background and parallax here.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.frame(width: 300, alignment: .leading)

                Divider()

                if isPoolCanvas {
                    poolControls
                } else { VStack(alignment: .leading, spacing: 9) {
                    Text("BACKGROUND SET").font(.caption.bold()).foregroundStyle(.secondary)
                    TextField("Background name", text: $name)
                    if !definitions.isEmpty {
                        Picker("Saved set", selection: $name) {
                            Text("Choose a background").tag("")
                            ForEach(definitions) { definition in
                                Text(definition.name).tag(definition.name)
                            }
                        }
                    }
                    HStack {
                        Button("Backgrounds Folder", action: chooseFolder)
                        Button("Textures Folder", action: chooseTexturesFolder)
                        Button("Import Texture", action: importTexture)
                        Button("Add from Assets", action: onBrowseAssets)
                        stockBackgroundMenu
                    }
                    HStack {
                        Button("Save Background", action: saveBackground).buttonStyle(.borderedProminent)
                        Button("Re-import into Editor", action: reimportBackground)
                            .disabled(selectedDefinition == nil)
                        Button("Assign to Room") { requestRoomAssignment(name) }
                        Button("None") { requestRoomAssignment("none") }
                    }
                    Text(directoryPath.isEmpty ? "Choose the shared custom_backgrounds folder." : "Custom backgrounds folder selected")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }.frame(minWidth: 390, maxWidth: .infinity, alignment: .leading) }

                if showConsole {
                    Divider()
                    BackgroundConsoleView().frame(width: 320)
                }
            }
            .padding(14)
        }
        // This is a control surface over the canvas. Its empty areas must eat clicks too.
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.editorHairline))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        .onAppear { loadStockBackgroundCatalog() }
        .frame(maxWidth: .infinity, maxHeight: 280)
        .contentShape(Rectangle())
        .alert("Replace room background?", isPresented: Binding(
            get: { pendingRoomAssignment != nil },
            set: { if !$0 { pendingRoomAssignment = nil } }
        )) {
            Button("Cancel", role: .cancel) { pendingRoomAssignment = nil }
            Button("Replace") {
                if let pendingRoomAssignment { assignToRoom(pendingRoomAssignment) }
                pendingRoomAssignment = nil
            }
        } message: {
            Text(roomAssignmentPrompt)
        }
        .onAppear {
            reloadSharedCatalog()
            reloadPoolCatalog()
            if isPoolCanvas,
               let requested = UserDefaults.standard.string(forKey: "vector2ZonePoolOpenName") {
                UserDefaults.standard.removeObject(forKey: "vector2ZonePoolOpenName")
                selectedPoolName = requested
                loadPoolSet()
            }
        }
        .onChange(of: directoryPath) { _, _ in reloadSharedCatalog() }
        .confirmationDialog("Clear this zone background canvas?", isPresented: $confirmPoolClear) {
            Button("Clear Canvas", role: .destructive, action: clearPoolCanvas)
        } message: { Text("Saved backgrounds stay in the project. Unsaved canvas edits will be lost.") }
        .confirmationDialog("Delete saved zone background?", isPresented: $confirmPoolDelete) {
            Button("Delete \(selectedPoolName)", role: .destructive, action: deletePoolSet)
        } message: { Text("This removes the selected set from the project pool. Install Changes updates the game copy.") }
        .sheet(isPresented: $showStockBackgroundPicker) {
            stockBackgroundPicker
        }
    }

    private var stockBackgroundMenu: some View {
        Menu("Vector Library") {
            if stockBackgrounds.isEmpty {
                Button("Choose background.xml…", action: chooseStockBackgroundLibrary)
            } else {
                Button("Browse \(stockBackgrounds.count) backgrounds…") { showStockBackgroundPicker = true }
                Divider()
                Button("Choose another background.xml…", action: chooseStockBackgroundLibrary)
            }
        }
        .help("Load one of Vector 2's shipped backgrounds onto this canvas so you can inspect its layers, scale and parallax values.")
    }

    private var stockBackgroundPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Vector 2 Backgrounds").font(.title2.bold())
                    Text("Load a shipped background onto this canvas to inspect how the game built it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { showStockBackgroundPicker = false }
            }
            List(stockBackgrounds) { background in
                Button {
                    loadStockBackground(background)
                    showStockBackgroundPicker = false
                } label: {
                    HStack {
                        Image(systemName: "photo.on.rectangle")
                        Text(background.name)
                        Spacer()
                        Image(systemName: "arrow.down.to.line")
                    }.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(18).frame(minWidth: 520, minHeight: 390)
    }

    private func loadStockBackgroundCatalog() {
        var candidates: [URL] = []
        if let projectRoot,
           let projectXML = try? XMLDocument(contentsOf: projectRoot.appendingPathComponent("project.xml")),
           let project = projectXML.rootElement() {
            for attribute in ["GameSourcePath", "GameDataPath"] {
                let value = project.attribute(forName: attribute)?.stringValue ?? ""
                guard !value.isEmpty else { continue }
                let root = URL(fileURLWithPath: value, isDirectory: true)
                candidates.append(contentsOf: [
                    root.appendingPathComponent("background.xml"),
                    root.appendingPathComponent("run_data/libraries/background.xml"),
                    root.appendingPathComponent("gamedata/run_data/libraries/background.xml"),
                    root.appendingPathComponent("Resources/gamedata/run_data/libraries/background.xml"),
                    root.appendingPathComponent("Assets/Resources/gamedata/run_data/libraries/background.xml")
                ])
            }
        }
        if !directoryPath.isEmpty {
            let root = URL(fileURLWithPath: directoryPath, isDirectory: true)
            candidates.append(root.appendingPathComponent("../run_data/libraries/background.xml").standardizedFileURL)
        }
        if let library = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            readStockBackgroundLibrary(library, showPicker: false)
        }
    }

    private func chooseStockBackgroundLibrary() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.xml]
        panel.allowsMultipleSelection = false
        panel.message = "Choose Vector 2's run_data/libraries/background.xml"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        rememberStockBackgroundLibrary(url)
        readStockBackgroundLibrary(url, showPicker: true)
    }

    private func rememberStockBackgroundLibrary(_ url: URL) {
        guard let projectRoot else { return }
        let metadataURL = projectRoot.appendingPathComponent("project.xml")
        guard let xml = try? XMLDocument(contentsOf: metadataURL), let root = xml.rootElement() else { return }
        root.removeAttribute(forName: "StockBackgroundLibraryPath")
        root.addAttribute(XMLNode.attribute(withName: "StockBackgroundLibraryPath", stringValue: url.path) as! XMLNode)
        try? xml.xmlData(options: .nodePrettyPrint).write(to: metadataURL, options: .atomic)
    }

    private func readStockBackgroundLibrary(_ url: URL, showPicker: Bool) {
        guard let xml = try? XMLDocument(contentsOf: url),
              let objects = try? xml.nodes(forXPath: "/Root/Objects/Object") else {
            BackgroundDiagnostics.shared.log("Could not read Vector background library at \(url.path)")
            return
        }
        stockBackgrounds = objects.compactMap { node in
            guard let object = node as? XMLElement else { return nil }
            let name = object.attribute(forName: "Name")?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !name.isEmpty, name != "placeholder_background" else { return nil }
            return StockBackgroundDefinition(name: name, xml: object.xmlString(options: .nodePrettyPrint), libraryURL: url)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        BackgroundDiagnostics.shared.log("Loaded \(stockBackgrounds.count) shipped backgrounds for inspection")
        if showPicker && !stockBackgrounds.isEmpty { showStockBackgroundPicker = true }
    }

    private func loadStockBackground(_ background: StockBackgroundDefinition) {
        let baseURL = background.libraryURL.deletingLastPathComponent()
        guard var node = XMLSceneParser.parseNodeXML(background.xml, baseURL: baseURL) else {
            BackgroundDiagnostics.shared.log("Could not parse \(background.name)")
            return
        }
        func mark(_ item: inout LevelNode) {
            if item.kind == .image {
                item.metadata.tag = "Background"
                if !item.metadata.sortingLayer.hasPrefix("Bg") { item.metadata.sortingLayer = "BgMiddle" }
            }
            for index in item.children.indices { mark(&item.children[index]) }
        }
        mark(&node)
        var backgroundIDs = Set<LevelNode.ID>()
        func collect(_ item: LevelNode) {
            if item.kind == .image && isIncluded(item) { backgroundIDs.insert(item.id) }
            item.children.forEach(collect)
        }
        collect(document.root)
        var removed: [LevelNode] = []
        document.root.extract(ids: backgroundIDs, into: &removed)
        guard document.root.appendToFirstFactor(node) else { return }
        document.setSelected(ids: [node.id])
        BackgroundDiagnostics.shared.log("Loaded stock \(background.name). Inspect each child for the game's authored size, layer and parallax factor.")
    }

    private func isIncluded(_ node: LevelNode) -> Bool {
        node.metadata.tag.caseInsensitiveCompare("Background") == .orderedSame || node.metadata.sortingLayer.hasPrefix("Bg")
    }

    private func isParallaxEnabled(_ node: LevelNode) -> Bool {
        (Double(node.factor) ?? 0) > 0
    }

    private func includeBinding(for node: LevelNode) -> Binding<Bool> {
        Binding(get: { isIncluded(document.node(for: node.id) ?? node) }, set: { enabled in
            document.root.update(id: node.id) { target in
                target.metadata.tag = enabled ? "Background" : "Image"
                if enabled && !target.metadata.sortingLayer.hasPrefix("Bg") { target.metadata.sortingLayer = "BgMiddle" }
                if !enabled && target.metadata.sortingLayer.hasPrefix("Bg") { target.metadata.sortingLayer = "Wall" }
            }
            BackgroundDiagnostics.shared.log("\(node.name) background=\(enabled)")
        })
    }

    private func parallaxBinding(for node: LevelNode) -> Binding<Bool> {
        Binding(get: { isParallaxEnabled(document.node(for: node.id) ?? node) }, set: { enabled in
            document.root.update(id: node.id) { $0.factor = enabled ? defaultFactor(for: $0.metadata.sortingLayer) : "0" }
            BackgroundDiagnostics.shared.log("\(node.name) parallax=\(enabled)")
        })
    }

    private func factorBinding(for node: LevelNode) -> Binding<Double> {
        Binding(get: { Double(document.node(for: node.id)?.factor ?? node.factor) ?? 0.75 }, set: { value in
            document.root.update(id: node.id) { $0.factor = String(format: "%.2g", value) }
        })
    }

    private func layerBinding(for node: LevelNode) -> Binding<String> {
        Binding(get: { document.node(for: node.id)?.metadata.sortingLayer ?? node.metadata.sortingLayer }, set: { layer in
            document.root.update(id: node.id) { target in
                target.metadata.sortingLayer = layer
                target.metadata.tag = "Background"
                if !isParallaxEnabled(target) { target.factor = defaultFactor(for: layer) }
            }
            BackgroundDiagnostics.shared.log("\(node.name) layer=\(layer)")
        })
    }

    private func defaultFactor(for layer: String) -> String {
        ["BgVeryVeryFar": "0.9", "BgVeryFar": "0.85", "BgFar": "0.8", "BgFurther": "0.8", "BgMiddle": "0.75", "BgClose": "0.7", "BgVeryClose": "0.65"][layer] ?? "0.75"
    }

    private func currentFactorText(for node: LevelNode) -> String {
        let value = Double(document.node(for: node.id)?.factor ?? node.factor) ?? 0
        return String(format: "%.2f", value)
    }

    private func resetValues(for node: LevelNode) {
        document.root.update(id: node.id) { target in
            target.metadata.tag = "Background"
            target.metadata.sortingLayer = "BgMiddle"
            target.factor = defaultFactor(for: "BgMiddle")
        }
        BackgroundDiagnostics.shared.log("Reset \(node.name) to BgMiddle, factor 0.75")
    }

    private func fitToVectorSize(_ node: LevelNode) {
        guard let transform = document.node(for: node.id)?.transform ?? node.transform else { return }
        let size = BackgroundPlacementPolicy.clampedBackgroundSize(width: transform.width, height: transform.height)
        document.updateCanvasTransform(for: node.id, width: size.width, height: size.height)
        BackgroundDiagnostics.shared.log("\(node.name) fitted to \(size.width)x\(size.height)")
    }

    private func saveBackground() {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !directoryPath.isEmpty else { BackgroundDiagnostics.shared.log("Name and folder are required"); return }
        let pieces = CustomBackgroundStore.scenePieces(in: document)
        guard !pieces.isEmpty else { BackgroundDiagnostics.shared.log("No Background/Bg* image pieces found"); return }
        CustomBackgroundStore.sceneDiagnostics(in: document).forEach(BackgroundDiagnostics.shared.log)
        let folder = URL(fileURLWithPath: directoryPath, isDirectory: true)
        let activeDefinition = CustomBackgroundDefinition(name: clean, pieces: pieces)
        do {
            try CustomBackgroundStore.save(activeDefinition, to: folder)
            definitions = [activeDefinition]
            BackgroundDiagnostics.shared.log("Replaced custom_backgrounds.xml with \(clean): \(pieces.count) pieces")
        } catch { BackgroundDiagnostics.shared.log("Save failed: \(error.localizedDescription)") }
    }

    private func reloadPoolCatalog() {
        guard let projectRoot, let poolFolder else { poolDefinitions = []; zoneChoices = []; return }
        do { try CustomBackgroundStore.migrateLegacyPool(in: poolFolder) }
        catch { BackgroundDiagnostics.shared.log("Old pool migration failed: \(error.localizedDescription)") }
        poolDefinitions = CustomBackgroundStore.loadPool(from: poolFolder)
        let zonesFolder = projectRoot.appendingPathComponent("custom_zones", isDirectory: true)
        zoneChoices = ((try? FileManager.default.contentsOfDirectory(at: zonesFolder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "xml" }
            .flatMap { url -> [(id: String, name: String)] in
                guard let xml = try? XMLDocument(contentsOf: url), let nodes = try? xml.nodes(forXPath: "//Zone") else { return [] }
                return nodes.compactMap { node in
                    guard let element = node as? XMLElement,
                          let id = element.attribute(forName: "Id")?.stringValue, !id.isEmpty else { return nil }
                    return (id, element.attribute(forName: "Name")?.stringValue ?? id)
                }
            }
        if zoneChoices.count == 1 && poolZoneID.isEmpty { poolZoneID = zoneChoices[0].id }
    }

    private func savePoolBackground() {
        guard let poolFolder else { BackgroundDiagnostics.shared.log("Open a project to save zone backgrounds"); return }
        let clean = poolName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, zoneChoices.contains(where: { $0.id == poolZoneID }) else {
            BackgroundDiagnostics.shared.log("Name this background and choose its project zone"); return
        }
        let pieces = CustomBackgroundStore.scenePieces(in: document)
        guard !pieces.isEmpty else { BackgroundDiagnostics.shared.log("Place at least one background image on the canvas"); return }
        if !document.zonePoolEditingName.isEmpty && document.zonePoolEditingName != clean {
            let message = "This canvas is editing \(document.zonePoolEditingName). Use New Set before creating a different background."
            BackgroundDiagnostics.shared.log(message); onPoolSaved(message); return
        }
        if let existing = CustomBackgroundStore.existingPoolFile(named: clean, in: poolFolder) {
            let savedName = existing.deletingPathExtension().lastPathComponent
            if savedName != clean {
                let message = "\(savedName).xml already exists. macOS treats \(clean).xml as the same file; choose a different name."
                BackgroundDiagnostics.shared.log(message); onPoolSaved(message); return
            }
            if document.zonePoolEditingName != clean {
                let message = "\(clean) already exists. Load that set to edit it, or choose a new name for this canvas."
                BackgroundDiagnostics.shared.log(message); onPoolSaved(message); return
            }
        }
        do {
            try CustomBackgroundStore.migrateLegacyPool(in: poolFolder)
            try CustomBackgroundStore.savePool(.init(name: clean, pieces: CustomBackgroundStore.normalizedPoolPieces(pieces), zone: poolZoneID), to: poolFolder)
            document.zonePoolEditingName = clean
            selectedPoolName = clean
            reloadPoolCatalog()
            BackgroundDiagnostics.shared.log("Saved \(clean) to \(poolZoneID)'s random pool: \(pieces.count) piece(s)")
            onPoolSaved("Zone background saved. Click Install to Game to update Vector 2.")
        } catch {
            let message = "Pool save failed: \(error.localizedDescription)"
            BackgroundDiagnostics.shared.log(message)
            onPoolSaved(message)
        }
    }

    private func loadPoolSet() {
        guard let definition = poolDefinitions.first(where: { $0.name == selectedPoolName }),
              let projectRoot, let poolFolder else { return }
        let searchDirectories = [projectRoot.appendingPathComponent("custom_textures"), poolFolder,
                                 projectRoot.appendingPathComponent("custom_backgrounds")]
            + importedTexturesDirectories.filter { !$0.isEmpty }.map { URL(fileURLWithPath: $0, isDirectory: true) }
        let texturePaths = backgroundTexturePaths(in: searchDirectories)
        var restored: [LevelNode] = []
        for piece in definition.pieces {
            guard var node = XMLSceneParser.parseNodeXML(piece, baseURL: searchDirectories[0]) else { continue }
            node.metadata.tag = "Background"
            if !node.metadata.sortingLayer.hasPrefix("Bg") { node.metadata.sortingLayer = "BgMiddle" }
            if let xml = try? XMLDocument(xmlString: piece, options: []),
               let angle = Double(xml.rootElement()?.attribute(forName: "EditorRotation")?.stringValue ?? "") {
                node.transform?.rotation = angle
            }
            restoreBackgroundTexture(in: &node, from: texturePaths)
            restored.append(node)
        }
        guard !restored.isEmpty else { BackgroundDiagnostics.shared.log("That saved set has no readable images"); return }
        var backgroundIDs = Set<LevelNode.ID>()
        func collect(_ node: LevelNode) {
            if node.kind == .image && isIncluded(node) { backgroundIDs.insert(node.id) }
            node.children.forEach(collect)
        }
        collect(document.root)
        var removed: [LevelNode] = []
        document.root.extract(ids: backgroundIDs, into: &removed)
        var inserted: [LevelNode.ID] = []
        for node in restored where document.root.appendToFirstFactor(node) { inserted.append(node.id) }
        document.setSelected(ids: inserted)
        poolName = definition.name
        document.zonePoolEditingName = definition.name
        poolZoneID = definition.zone ?? ""
        BackgroundDiagnostics.shared.log("Loaded \(inserted.count) piece(s) onto the zone background canvas")
    }

    private func clearPoolCanvas() {
        guard isPoolCanvas else { return }
        var ids = Set<LevelNode.ID>()
        func collect(_ node: LevelNode) {
            if node.kind == .image && isIncluded(node) { ids.insert(node.id) }
            node.children.forEach(collect)
        }
        collect(document.root)
        var removed: [LevelNode] = []
        document.root.extract(ids: ids, into: &removed)
        document.setSelected(ids: [])
        poolName = ""; selectedPoolName = ""
        document.zonePoolEditingName = ""
        BackgroundDiagnostics.shared.log("New blank zone background canvas")
    }

    private func deletePoolSet() {
        guard let poolFolder, !selectedPoolName.isEmpty else { return }
        do {
            try CustomBackgroundStore.migrateLegacyPool(in: poolFolder)
            guard let file = CustomBackgroundStore.poolFile(for: selectedPoolName, in: poolFolder) else { return }
            let removedName = selectedPoolName
            try FileManager.default.removeItem(at: file)
            selectedPoolName = ""; poolName = ""
            reloadPoolCatalog()
            onPoolSaved("Deleted \(removedName) from the project zone pool. Install Changes updates Vector 2.")
        } catch { BackgroundDiagnostics.shared.log("Could not delete pool set: \(error.localizedDescription)") }
    }

    private var selectedDefinition: CustomBackgroundDefinition? {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return definitions.first { $0.name.caseInsensitiveCompare(clean) == .orderedSame }
    }

    /// Restores the editable image nodes stored in custom_backgrounds.xml.
    /// Assignment alone intentionally keeps those images out of room XML, so
    /// opening an imported room needs this explicit editor-side reconstruction.
    private func reimportBackground() {
        guard let definition = selectedDefinition else {
            BackgroundDiagnostics.shared.log("Choose a saved background set first")
            return
        }

        let searchDirectories = ([customTexturesDirectory] + importedTexturesDirectories + [directoryPath])
            .filter { !$0.isEmpty }
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        let baseURL = searchDirectories.first
            ?? URL(fileURLWithPath: directoryPath, isDirectory: true)
        let texturePaths = backgroundTexturePaths(in: searchDirectories)
        var restored = definition.pieces.compactMap { piece -> LevelNode? in
            guard var node = XMLSceneParser.parseNodeXML(piece, baseURL: baseURL) else { return nil }
            if let xml = try? XMLDocument(xmlString: piece, options: []),
               let angle = Double(xml.rootElement()?.attribute(forName: "EditorRotation")?.stringValue ?? "") {
                node.transform?.rotation = angle
            }
            return node
        }
        for index in restored.indices {
            restored[index].metadata.tag = "Background"
            if !restored[index].metadata.sortingLayer.hasPrefix("Bg") {
                restored[index].metadata.sortingLayer = "BgMiddle"
            }
            restoreBackgroundTexture(in: &restored[index], from: texturePaths)
        }
        guard !restored.isEmpty else {
            BackgroundDiagnostics.shared.log("Re-import failed: the saved set contains no readable Image nodes")
            return
        }

        var backgroundIDs: Set<LevelNode.ID> = []
        func collectBackgroundIDs(_ node: LevelNode) {
            if node.kind == .image && isIncluded(node) {
                backgroundIDs.insert(node.id)
            }
            node.children.forEach(collectBackgroundIDs)
        }
        collectBackgroundIDs(document.root)
        var removed: [LevelNode] = []
        document.root.extract(ids: backgroundIDs, into: &removed)

        var insertedIDs: [LevelNode.ID] = []
        for node in restored where document.root.appendToFirstFactor(node) {
            insertedIDs.append(node.id)
        }
        document.customBackgroundName = definition.name
        document.hasCustomBackgroundAssignment = true
        document.setSelected(ids: insertedIDs)
        BackgroundDiagnostics.shared.log(
            "Re-imported \(insertedIDs.count) piece(s) from \(definition.name); replaced \(removed.count) editable background piece(s)"
        )
    }

    /// Saved background XML stores the runtime class name, not an editor-only
    /// absolute path. Resolve it against both user asset locations so a set can
    /// be reopened after restarting the editor or moving the project.
    private func backgroundTexturePaths(in directories: [URL]) -> [String: String] {
        let extensions = Set(["png", "jpg", "jpeg", "gif"])
        var paths: [String: String] = [:]
        for directory in directories {
            guard let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let file as URL in enumerator where extensions.contains(file.pathExtension.lowercased()) {
                let filename = file.lastPathComponent.lowercased()
                let stem = file.deletingPathExtension().lastPathComponent.lowercased()
                // Earlier folders win: custom textures before imported assets.
                paths[filename] = paths[filename] ?? file.path
                paths[stem] = paths[stem] ?? file.path
            }
        }
        return paths
    }

    private func restoreBackgroundTexture(in node: inout LevelNode, from paths: [String: String]) {
        if node.kind == .image,
           node.metadata.imagePath.isEmpty || !FileManager.default.fileExists(atPath: node.metadata.imagePath) {
            let className = node.metadata.className.trimmingCharacters(in: .whitespacesAndNewlines)
            let filename = node.metadata.filename.trimmingCharacters(in: .whitespacesAndNewlines)
            let candidates = [node.metadata.sourceAttributes["EditorSourceGIF"] ?? "", className, filename].flatMap { value in
                let leaf = URL(fileURLWithPath: value).lastPathComponent
                let stem = URL(fileURLWithPath: leaf).deletingPathExtension().lastPathComponent
                return [value.lowercased(), leaf.lowercased(), stem.lowercased()]
            }
            if let resolved = candidates.compactMap({ paths[$0] }).first {
                node.metadata.imagePath = resolved
            } else {
                BackgroundDiagnostics.shared.log("Missing texture for \(node.name) (class \(className))")
            }
        }
        for index in node.children.indices {
            restoreBackgroundTexture(in: &node.children[index], from: paths)
        }
    }

    private func requestRoomAssignment(_ value: String) {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { BackgroundDiagnostics.shared.log("Enter a background name first"); return }
        pendingRoomAssignment = clean
    }

    private func assignToRoom(_ value: String) {
        document.customBackgroundName = value
        document.hasCustomBackgroundAssignment = true
        let label = value.caseInsensitiveCompare("none") == .orderedSame ? "stock backgrounds disabled" : value
        BackgroundDiagnostics.shared.log("Assigned \(label) to \(document.name)")
    }

    private func displayAssignment(_ value: String) -> String {
        value.caseInsensitiveCompare("none") == .orderedSame ? "no background" : value
    }

    private var roomAssignmentPrompt: String {
        let requested = displayAssignment(pendingRoomAssignment ?? "")
        let current = document.customBackgroundName.trimmingCharacters(in: .whitespacesAndNewlines)
        if current.isEmpty {
            return "Use \(requested) for \(document.name)?"
        }
        return "\(document.name) currently uses \(displayAssignment(current)). Replace it with \(requested)?"
    }

    private func chooseFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.identifier = NSUserInterfaceItemIdentifier("vector2.background-designer-folder-picker")
        if !directoryPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: directoryPath, isDirectory: true)
        }
        if panel.runModal() == .OK, let url = panel.url {
            directoryPath = url.path
            adoptBackgroundFolder(url)
        }
    }

    private func reloadSharedCatalog() {
        guard !directoryPath.isEmpty else {
            definitions = []
            name = ""
            return
        }
        adoptBackgroundFolder(URL(fileURLWithPath: directoryPath, isDirectory: true))
    }

    private func adoptBackgroundFolder(_ folder: URL) {
        let loaded = CustomBackgroundStore.load(from: folder)
        definitions = loaded

        let assigned = document.customBackgroundName.trimmingCharacters(in: .whitespacesAndNewlines)
        if assigned.caseInsensitiveCompare("none") != .orderedSame,
           loaded.contains(where: { $0.name.caseInsensitiveCompare(assigned) == .orderedSame }) {
            name = assigned
        } else {
            // The name field is folder-scoped too. Do not resurrect a room name
            // from a catalog that is not present in the selected destination.
            name = ""
        }
        BackgroundDiagnostics.shared.log("Background folder loaded: \(loaded.count) saved set(s)")
    }

    private func chooseTexturesFolder() {
        let preservedBackgroundsDirectory = directoryPath
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.identifier = NSUserInterfaceItemIdentifier("vector2.background-designer-textures-picker")
        if !customTexturesDirectory.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: customTexturesDirectory, isDirectory: true)
        }
        if panel.runModal() == .OK, let url = panel.url {
            customTexturesDirectory = url.path
            BackgroundDiagnostics.shared.log("Custom textures folder selected")
        }
        if directoryPath != preservedBackgroundsDirectory {
            directoryPath = preservedBackgroundsDirectory
        }
    }

    private func importTexture() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.png, .jpeg, .gif]; panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        let textures: URL?
        if isPoolCanvas { textures = projectRoot?.appendingPathComponent("custom_textures", isDirectory: true) }
        else { textures = customTexturesDirectory.isEmpty ? nil : URL(fileURLWithPath: customTexturesDirectory, isDirectory: true) }
        guard let textures else {
            BackgroundDiagnostics.shared.log("Open a project or choose a custom textures folder before importing")
            return
        }
        try? FileManager.default.createDirectory(at: textures, withIntermediateDirectories: true)
        var imported = 0
        for source in panel.urls {
            let access = source.startAccessingSecurityScopedResource()
            defer { if access { source.stopAccessingSecurityScopedResource() } }
            let target = textures.appendingPathComponent(source.lastPathComponent)
            if FileManager.default.fileExists(atPath: target.path) {
                BackgroundDiagnostics.shared.log("Already imported: \(source.lastPathComponent). Existing artwork was kept.")
                continue
            }
            do { try FileManager.default.copyItem(at: source, to: target); imported += 1 }
            catch { BackgroundDiagnostics.shared.log("Could not import \(source.lastPathComponent): \(error.localizedDescription)") }
        }
        BackgroundDiagnostics.shared.log("Imported \(imported) texture(s) to custom_textures. Pick them from Add from Assets.")
    }
}

struct BackgroundConsoleView: View {
    @ObservedObject private var diagnostics = BackgroundDiagnostics.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text("Parallax Console").font(.headline); Spacer(); Button("Clear") { diagnostics.lines.removeAll() } }
            ScrollView { Text(diagnostics.lines.joined(separator: "\n")).font(.system(size: 11, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                .frame(maxHeight: 170)
        }.padding(14).background(Color.black.opacity(0.88)).foregroundStyle(.white)
    }
}
