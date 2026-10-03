import SwiftUI
import Foundation
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

struct CustomModelItem: Identifiable, Equatable {
    let id: String
    let name: String
    let category: String
    let author: String
    let modelURL: URL
    var reference: String { "custom:\(id)" }
}

enum CustomModelCatalog {
    static func writableRoot() throws -> URL {
        guard let encoded = UserDefaults.standard.string(forKey: "vector2CustomModelsDirectoryBookmark"),
              let data = Data(base64Encoded: encoded) else {
            throw NSError(domain: "CustomModels", code: 4, userInfo: [NSLocalizedDescriptionKey: "Choose the custom_models destination folder first."])
        }
        var stale = false
#if os(macOS)
        let options: URL.BookmarkResolutionOptions = .withSecurityScope
#else
        let options: URL.BookmarkResolutionOptions = .withoutUI
#endif
        let root = try URL(resolvingBookmarkData: data, options: options, relativeTo: nil, bookmarkDataIsStale: &stale)
        guard root.hasDirectoryPath else {
            throw NSError(domain: "CustomModels", code: 5, userInfo: [NSLocalizedDescriptionKey: "The selected custom_models destination is not a folder."])
        }
        return root
    }

    static func roots() -> [URL] {
        var result: [URL] = []
        if let encoded = UserDefaults.standard.string(forKey: "vector2CustomModelsDirectoryBookmark"), let data = Data(base64Encoded: encoded) {
            var stale = false
#if os(macOS)
            let options: URL.BookmarkResolutionOptions = .withSecurityScope
#else
            let options: URL.BookmarkResolutionOptions = .withoutUI
#endif
            if let url = try? URL(resolvingBookmarkData: data, options: options, relativeTo: nil, bookmarkDataIsStale: &stale) { result.append(url) }
        }
        if let path = UserDefaults.standard.string(forKey: "vector2CustomModelsDirectory"), !path.isEmpty { result.append(URL(fileURLWithPath: path, isDirectory: true)) }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        result.append(support
            .appendingPathComponent("Nekki", isDirectory: true)
            .appendingPathComponent("Vector 2", isDirectory: true)
            .appendingPathComponent("custom_models", isDirectory: true))
        var seen = Set<String>(); return result.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    static func load(projectRoot: URL? = nil) -> [CustomModelItem] {
        var items: [CustomModelItem] = []
        let modelRoots = projectRoot.map { [$0.appendingPathComponent("custom_models")] } ?? []
        for root in modelRoots + roots() {
            let access = root.startAccessingSecurityScopedResource(); defer { if access { root.stopAccessingSecurityScopedResource() } }
            for relative in ((try? FileManager.default.subpathsOfDirectory(atPath: root.path)) ?? []).filter({ $0.hasSuffix("manifest.xml") }) {
                let manifestURL = root.appendingPathComponent(relative)
                guard let document = try? XMLDocument(contentsOf: manifestURL), let node = document.rootElement(), node.name == "CustomModel",
                      let id = node.attribute(forName: "ID")?.stringValue,
                      let file = node.attribute(forName: "FileName")?.stringValue else { continue }
                items.append(.init(id: id, name: node.attribute(forName: "Name")?.stringValue ?? id, category: node.attribute(forName: "Category")?.stringValue ?? "Accessory", author: node.attribute(forName: "Author")?.stringValue ?? "Unknown", modelURL: manifestURL.deletingLastPathComponent().appendingPathComponent(file)))
            }
        }
        return Dictionary(grouping: items, by: \.id).compactMap(\.value.first).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func document(for reference: String) -> XMLDocument? {
        let wanted = reference.dropFirst("custom:".count).replacingOccurrences(of: ".xml", with: "")
        for root in roots() {
            let access = root.startAccessingSecurityScopedResource(); defer { if access { root.stopAccessingSecurityScopedResource() } }
            for relative in ((try? FileManager.default.subpathsOfDirectory(atPath: root.path)) ?? []).filter({ $0.hasSuffix("manifest.xml") }) {
                let manifestURL = root.appendingPathComponent(relative)
                guard let manifest = try? XMLDocument(contentsOf: manifestURL), let node = manifest.rootElement(),
                      node.attribute(forName: "ID")?.stringValue?.localizedCaseInsensitiveCompare(wanted) == .orderedSame,
                      let file = node.attribute(forName: "FileName")?.stringValue else { continue }
                return try? XMLDocument(contentsOf: manifestURL.deletingLastPathComponent().appendingPathComponent(file), options: [.nodePreserveWhitespace])
            }
        }
        return nil
    }
}

struct PlayerDesignerView: View {
    @Binding var document: LevelDocument
    let gameDirectory: String
    let onClose: () -> Void
    let onStatus: (String) -> Void
    @State private var models: [CustomModelItem] = []
    @State private var inGameModels: [TrickPreviewModelSkin] = []
    @State private var playback: TrickPreviewPlayback?
    @State private var zoom: CGFloat = 3.5
    @State private var previewAnimation = "default"
    @State private var importingModel = false
    @State private var choosingFolder = false
    @State private var pendingData: Data?
    @State private var pendingName = ""
    @State private var category = "Accessory"
    @State private var author = ""
    @State private var message = "Import XML model layers or apply installed layers to this level."
    @State private var confirmingClearModels = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Custom Models").font(.title3.weight(.semibold))
                Button("Import Model XML") { importingModel = true }.buttonStyle(.borderedProminent).disabled(!hasModelDestination)
                Button("Choose custom_models Folder", action: beginChooseModelFolder)
                Text(modelDestinationLabel).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                if pendingData != nil {
                    TextField("Model name", text: $pendingName)
                    Picker("Category", selection: $category) { ForEach(["Body", "Chest", "Headwear", "Hair", "Face", "Feet", "Accessory"], id: \.self) { Text($0).tag($0) } }
                    TextField("Author", text: $author)
                    Button("Install Model", action: installPending).disabled(pendingName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Divider()
                Button {
                    document.playerSkinFiles = []
                    rebuild()
                } label: {
                    Label("Default · Equipped Appearance", systemImage: document.playerSkinFiles.isEmpty ? "checkmark.circle.fill" : "circle")
                }
                .buttonStyle(.plain)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("IN-GAME MODEL LAYERS").font(.caption.bold()).foregroundStyle(.secondary)
                        ForEach(inGameModels.filter { $0.filename != "0.xml" }) { skin in
                            Toggle(skin.filename == "1.xml" ? "Default Body" : skin.displayName, isOn: builtInBinding(skin.filename))
                        }
                        Divider()
                        Text("IMPORTED MODEL LAYERS").font(.caption.bold()).foregroundStyle(.secondary)
                        if models.isEmpty { Text("No imported models installed.").font(.caption).foregroundStyle(.secondary) }
                        ForEach(models) { model in
                            HStack {
                                Toggle(isOn: Binding(get: { document.playerSkinFiles.contains(model.reference) }, set: { enabled in toggle(model, enabled); rebuild() })) {
                                    VStack(alignment: .leading) { Text(model.name); Text("\(model.category) · \(model.author)").font(.caption).foregroundStyle(.secondary) }
                                }
                                Button(role: .destructive) { remove(model) } label: { Image(systemName: "trash") }
                                    .buttonStyle(.borderless)
                                    .help("Remove imported model")
                            }
                        }
                        if !models.isEmpty {
                            Button("Clear Imported Models", role: .destructive) { confirmingClearModels = true }
                        }
                    }
                }
                Button("Restore Default", role: .destructive) { document.playerSkinFiles = []; rebuild() }
                Spacer(); Text(message).font(.caption).foregroundStyle(.secondary)
            }.padding(18).frame(width: 310)
            Divider()
            VStack(spacing: 12) {
                HStack { VStack(alignment: .leading) { Text("Player Designer").font(.title2.weight(.semibold)); Text("LEVEL-LOCAL APPEARANCE").font(.caption.monospaced()).foregroundStyle(.secondary) }; Spacer(); Picker("Animation", selection: $previewAnimation) { Text("Default").tag("default"); Text("Run").tag("run"); Text("Example Vault").tag("vault") }.frame(width: 190); Button("Close", action: onClose) }
                GeometryReader { proxy in
                    ZStack { LinearGradient(colors: [.black, .blue.opacity(0.12)], startPoint: .top, endPoint: .bottom)
                        if let playback { TrickPreviewOverlay(playback: playback, anchor: CGPoint(x: proxy.size.width / 2, y: proxy.size.height * 0.72), zoom: zoom, unitsPerCanvasPoint: 3, showsDebugLabel: false) }
                    }.clipShape(RoundedRectangle(cornerRadius: 18))
                }
                HStack { Image(systemName: "minus.magnifyingglass"); Slider(value: $zoom, in: 0.75...8).frame(width: 220); Image(systemName: "plus.magnifyingglass") }
            }.padding(22)
        }
        .fileImporter(isPresented: $importingModel, allowedContentTypes: [.xml], allowsMultipleSelection: false) { result in receiveModel(result) }
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in receiveFolder(result) }
        .onAppear { refresh() }
        .onChange(of: document.playerSkinFiles) { _, _ in rebuild() }
        .onChange(of: previewAnimation) { _, _ in rebuild() }
        .confirmationDialog("Remove every imported model?", isPresented: $confirmingClearModels) {
            Button("Clear Imported Models", role: .destructive, action: clearImportedModels)
            Button("Cancel", role: .cancel) {}
        } message: { Text("This deletes their packages from custom_models and removes them from this level.") }
    }

    private func refresh() { let catalog = TrickPreviewCatalog(gameDirectory: gameDirectory); inGameModels = catalog.loadModelSkins(); models = CustomModelCatalog.load(); rebuild() }
    private var hasModelDestination: Bool { UserDefaults.standard.string(forKey: "vector2CustomModelsDirectoryBookmark")?.isEmpty == false }
    private var modelDestinationLabel: String { UserDefaults.standard.string(forKey: "vector2CustomModelsDirectory").map { "Destination: \($0)" } ?? "Choose a destination before importing." }
    private func builtInBinding(_ filename: String) -> Binding<Bool> { Binding(get: { document.playerSkinFiles.contains(filename) }, set: { enabled in if enabled { document.playerSkinFiles.append(filename) } else { document.playerSkinFiles.removeAll { $0 == filename } }; rebuild() }) }
    private func toggle(_ model: CustomModelItem, _ enabled: Bool) { if enabled { document.playerSkinFiles.append(model.reference) } else { document.playerSkinFiles.removeAll { $0 == model.reference } }; onStatus("Updated player model for \(document.name)") }
    private func remove(_ model: CustomModelItem) {
        do {
            let package = model.modelURL.deletingLastPathComponent()
            let access = package.startAccessingSecurityScopedResource(); defer { if access { package.stopAccessingSecurityScopedResource() } }
            try FileManager.default.removeItem(at: package)
            document.playerSkinFiles.removeAll { $0 == model.reference }
            refresh(); message = "Removed \(model.name)."; onStatus(message)
        } catch { message = "Remove failed: \(error.localizedDescription)" }
    }
    private func clearImportedModels() {
        let installed = models
        var failed: [String] = []
        for model in installed {
            do { try FileManager.default.removeItem(at: model.modelURL.deletingLastPathComponent()) }
            catch { failed.append(model.name) }
        }
        let references = Set(installed.map(\.reference))
        document.playerSkinFiles.removeAll { references.contains($0) }
        refresh()
        message = failed.isEmpty ? "Cleared all imported models." : "Could not remove: \(failed.joined(separator: ", "))."
        onStatus(message)
    }
    private func rebuild() {
        let catalog = TrickPreviewCatalog(gameDirectory: gameDirectory), moves = catalog.loadMoves()
        let move: TrickPreviewMove?
        switch previewAnimation {
        case "run": move = moves.first { $0.name.caseInsensitiveCompare("RunForward") == .orderedSame }
        case "vault": move = moves.first { $0.name.caseInsensitiveCompare("MonkeyVault") == .orderedSame }
        default: move = moves.first { $0.fileName.localizedCaseInsensitiveContains("cs_swarm_idle") }
        }
        guard let move = move ?? moves.first else { return }
        do { let skins = document.playerSkinFiles.isEmpty ? ["0.xml", "1.xml"] : (["0.xml"] + document.playerSkinFiles).vector2Uniqued(); let model = try catalog.loadModel(skins: skins); let frames = try catalog.loadFrames(fileName: move.fileName); playback = .init(move: move, model: model, frames: frames, startFrame: max(0, move.firstFrame), pivotIndex: model.nodeIndex(named: move.pivotNode), selectedSkins: skins, anchorNodeID: nil) } catch { message = error.localizedDescription; playback = nil }
    }
    private func receiveModel(_ result: Result<[URL], Error>) { do { guard let url = try result.get().first else { return }; let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }; let data = try Data(contentsOf: url); let xml = try XMLDocument(data: data); guard xml.rootElement()?.name == "Scene", !(try xml.nodes(forXPath: "/Scene/Nodes/*")).isEmpty else { throw NSError(domain: "CustomModels", code: 1, userInfo: [NSLocalizedDescriptionKey: "Model XML must contain a Scene with nodes."]) }; let name = url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_", with: " "); pendingData = data; pendingName = name; install(data: data, modelName: name) } catch { message = error.localizedDescription } }
    private func beginChooseModelFolder() {
#if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose custom_models"
        if panel.runModal() == .OK, let url = panel.url { rememberModelFolder(url) }
#else
        choosingFolder = true
#endif
    }
    private func receiveFolder(_ result: Result<[URL], Error>) { do { guard let url = try result.get().first else { return }; let options: URL.BookmarkCreationOptions = {
#if os(macOS)
            return .withSecurityScope
#else
            return .minimalBookmark
#endif
        }(); let data = try url.bookmarkData(options: options, includingResourceValuesForKeys: nil, relativeTo: nil); UserDefaults.standard.set(url.path, forKey: "vector2CustomModelsDirectory"); UserDefaults.standard.set(data.base64EncodedString(), forKey: "vector2CustomModelsDirectoryBookmark"); message = "Connected custom_models: \(url.path)"; refresh() } catch { message = "Folder permission failed: \(error.localizedDescription)" } }
    private func rememberModelFolder(_ url: URL) {
        do {
            let data = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(url.path, forKey: "vector2CustomModelsDirectory")
            UserDefaults.standard.set(data.base64EncodedString(), forKey: "vector2CustomModelsDirectoryBookmark")
            message = "Connected custom_models: \(url.path)"
            refresh()
        } catch { message = "Folder permission failed: \(error.localizedDescription)" }
    }
    private func installPending() { guard let data = pendingData else { return }; install(data: data, modelName: pendingName) }
    private func install(data: Data, modelName: String) { do { let root = try CustomModelCatalog.writableRoot(); let access = root.startAccessingSecurityScopedResource(); defer { if access { root.stopAccessingSecurityScopedResource() } }; guard access else { throw NSError(domain: "CustomModels", code: 6, userInfo: [NSLocalizedDescriptionKey: "Permission to write custom_models was denied. Choose the destination folder again."]) }; let id = modelName.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "_" }.reduce("") { $0 + String($1) }; let package = root.appendingPathComponent(id, isDirectory: true); try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true); try data.write(to: package.appendingPathComponent("model.xml"), options: .atomic); let node = XMLElement(name: "CustomModel"); ["ID": id, "Name": modelName, "Category": category, "Author": author.isEmpty ? "Unknown" : author, "FileName": "model.xml", "Skeleton": "VectorHuman46"].forEach { node.addAttribute(XMLNode.attribute(withName: $0.key, stringValue: $0.value) as! XMLNode) }; try XMLDocument(rootElement: node).xmlData(options: [.nodePrettyPrint]).write(to: package.appendingPathComponent("manifest.xml"), options: .atomic); let reference = "custom:\(id)"; if !document.playerSkinFiles.contains(reference) { document.playerSkinFiles.append(reference) }; pendingData = nil; refresh(); message = "Installed \(modelName) into \(root.path)."; onStatus(message) } catch { message = "Install failed: \(error.localizedDescription)" } }
}
