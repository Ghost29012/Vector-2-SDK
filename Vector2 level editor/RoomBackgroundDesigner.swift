import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Per-room background controls. The Project Manager pool has its own view.
struct RoomBackgroundDesignerOverlay: View {
    @Binding var document: LevelDocument
    @Binding var directoryPath: String
    @Binding var texturesPath: String
    let onClose: () -> Void
    @State private var name = ""
    @State private var message = ""
    @State private var pendingAssignment: String?
    @AppStorage("roomBackgroundDirectoryBookmark") private var directoryBookmark = ""
    @AppStorage("roomBackgroundTexturesBookmark") private var texturesBookmark = ""
    private let layers = ["BgFurther", "BgVeryVeryFar", "BgVeryFar", "BgFar", "BgMiddle", "BgClose", "BgVeryClose"]
    private var image: LevelNode? {
        guard let selected = document.selectedNode, selected.kind == .image else { return nil }
        return selected
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Background Designer · This Room", systemImage: "photo.on.rectangle.angled").font(.headline)
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark") }
            }.padding(12)
            Divider()
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("SELECTED IMAGE").font(.caption.bold()).foregroundStyle(.secondary)
                        if let image {
                            Text(image.name).font(.subheadline.bold())
                            Toggle("Background", isOn: Binding(get: { included(image) }, set: { enabled in
                                document.root.update(id: image.id) {
                                    $0.metadata.tag = enabled ? "Background" : "Image"
                                    if enabled && !$0.metadata.sortingLayer.hasPrefix("Bg") { $0.metadata.sortingLayer = "BgMiddle" }
                                    if !enabled && $0.metadata.sortingLayer.hasPrefix("Bg") { $0.metadata.sortingLayer = "Wall" }
                                }
                            }))
                            Toggle("Parallax", isOn: Binding(get: { factor(image) > 0 }, set: { enabled in
                                document.root.update(id: image.id) {
                                    if enabled {
                                        $0.metadata.tag = "Background"
                                        if !$0.metadata.sortingLayer.hasPrefix("Bg") { $0.metadata.sortingLayer = "BgMiddle" }
                                    }
                                    $0.factor = enabled ? defaultFactor($0.metadata.sortingLayer) : "0"
                                }
                            }))
                            Picker("Depth", selection: Binding(get: { image.metadata.sortingLayer }, set: { layer in
                                document.root.update(id: image.id) {
                                    $0.metadata.sortingLayer = layer; $0.metadata.tag = "Background"
                                    if (Double($0.factor) ?? 0) == 0 { $0.factor = defaultFactor(layer) }
                                }
                            })) {
                                ForEach(layers.contains(image.metadata.sortingLayer) ? layers : [image.metadata.sortingLayer] + layers, id: \.self) { Text($0).tag($0) }
                            }
                            HStack {
                                Text("Factor")
                                Slider(value: Binding(get: { factor(image) }, set: { value in
                                    document.root.update(id: image.id) { $0.factor = String(format: "%.2g", value) }
                                }), in: 0.05...0.95, step: 0.05)
                                Text(String(format: "%.2f", factor(image))).monospacedDigit()
                            }.disabled(factor(image) == 0)
                            Button("Reset Values") {
                                document.root.update(id: image.id) { $0.metadata.tag = "Background"; $0.metadata.sortingLayer = "BgMiddle"; $0.factor = "0.75" }
                            }
                        } else { Text("Select an image on the canvas.").font(.caption).foregroundStyle(.secondary) }
                    }.frame(width: 270, alignment: .leading)
                    Divider()
                    VStack(alignment: .leading, spacing: 9) {
                        Text("ROOM BACKGROUND").font(.caption.bold()).foregroundStyle(.secondary)
                        TextField("Background name", text: $name).textFieldStyle(.roundedBorder)
                        HStack {
                            Button("Folder", action: chooseFolder)
                            Button("Images", action: importImages)
                            Button("Save", action: save).buttonStyle(.borderedProminent)
                            Button("Assign") { requestAssignment(name) }
                            Button("None") { requestAssignment("none") }
                        }
                        Text(directoryPath.isEmpty ? "Choose the custom_backgrounds folder." : "Custom backgrounds folder selected.")
                            .font(.caption2).foregroundStyle(.secondary)
                        if !message.isEmpty { Text(message).font(.caption).fixedSize(horizontal: false, vertical: true) }
                    }.frame(width: 440, alignment: .leading)
                }.padding(12)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onAppear { loadRoomName() }
        .onChange(of: document.id) { _, _ in loadRoomName() }
        .alert("Replace room background?", isPresented: Binding(get: { pendingAssignment != nil }, set: { if !$0 { pendingAssignment = nil } })) {
            Button("Cancel", role: .cancel) { pendingAssignment = nil }
            Button("Replace") {
                if let pendingAssignment {
                    document.customBackgroundName = pendingAssignment
                    document.hasCustomBackgroundAssignment = true
                }
                pendingAssignment = nil
            }
        } message: { Text("Assign \(pendingAssignment ?? "") to \(document.name)?") }
    }

    private func loadRoomName() {
        name = document.customBackgroundName.caseInsensitiveCompare("none") == .orderedSame ? "" : document.customBackgroundName
        message = ""
    }
    private func included(_ node: LevelNode) -> Bool { node.metadata.tag.caseInsensitiveCompare("Background") == .orderedSame || node.metadata.sortingLayer.hasPrefix("Bg") }
    private func factor(_ node: LevelNode) -> Double { Double(node.factor) ?? 0 }
    private func defaultFactor(_ layer: String) -> String {
        ["BgVeryVeryFar": "0.9", "BgVeryFar": "0.85", "BgFar": "0.8", "BgFurther": "0.8", "BgMiddle": "0.75", "BgClose": "0.7", "BgVeryClose": "0.65"][layer] ?? "0.75"
    }
    private func requestAssignment(_ value: String) {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { message = "Enter a background name first."; return }
        if clean.caseInsensitiveCompare("none") != .orderedSame {
            do {
                var bookmark = directoryBookmark
                guard let folder = try authorizedFolder(path: directoryPath, bookmark: &bookmark, purpose: "custom_backgrounds") else { return }
                guard folder.lastPathComponent != "custom_backgrounds_pool" else {
                    message = "Room backgrounds must come from custom_backgrounds, not the zone pool."
                    return
                }
                directoryBookmark = bookmark
                directoryPath = folder.path
                let access = folder.startAccessingSecurityScopedResource()
                defer { if access { folder.stopAccessingSecurityScopedResource() } }
                guard CustomBackgroundStore.load(from: folder).contains(where: { $0.name.caseInsensitiveCompare(clean) == .orderedSame }) else {
                    message = "Save this background in the room folder before assigning it."
                    return
                }
            } catch { message = "Couldn't open the room background folder: \(error.localizedDescription)"; return }
        }
        pendingAssignment = clean
    }
    private func chooseFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.message = "Choose the per-room custom_backgrounds folder."
        if !directoryPath.isEmpty { panel.directoryURL = URL(fileURLWithPath: directoryPath, isDirectory: true) }
        if panel.runModal() == .OK, let url = panel.url {
            do {
                directoryBookmark = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil).base64EncodedString()
                directoryPath = url.path
                message = ""
            } catch { message = "Couldn't keep folder access: \(error.localizedDescription)" }
        }
    }
    private func authorizedFolder(path: String, bookmark: inout String, purpose: String) throws -> URL? {
        if let data = Data(base64Encoded: bookmark), !data.isEmpty {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale),
               url.standardizedFileURL.path == URL(fileURLWithPath: path).standardizedFileURL.path {
                if !stale { return url }
            }
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose \(purpose) to grant the editor permission."
        if !path.isEmpty { panel.directoryURL = URL(fileURLWithPath: path, isDirectory: true) }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        bookmark = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil).base64EncodedString()
        return url
    }
    private func save() {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !directoryPath.isEmpty else { message = "Choose a folder and enter a name first."; return }
        guard URL(fileURLWithPath: directoryPath).lastPathComponent != "custom_backgrounds_pool" else {
            message = "Choose custom_backgrounds for this room, not the zone-pool folder."
            return
        }
        let pieces = CustomBackgroundStore.scenePieces(in: document)
        guard !pieces.isEmpty else { message = "Mark at least one image as Background first."; return }
        do {
            var bookmark = directoryBookmark
            guard let folder = try authorizedFolder(path: directoryPath, bookmark: &bookmark, purpose: "custom_backgrounds") else {
                message = "Save cancelled. The room background wasn't changed."
                return
            }
            guard folder.lastPathComponent != "custom_backgrounds_pool" else {
                message = "Choose custom_backgrounds, not the zone-pool folder."
                return
            }
            directoryBookmark = bookmark
            directoryPath = folder.path
            let access = folder.startAccessingSecurityScopedResource()
            defer { if access { folder.stopAccessingSecurityScopedResource() } }
            try RoomBackgroundFile.replace(name: clean, pieces: pieces, in: folder)
            document.customBackgroundName = clean
            document.hasCustomBackgroundAssignment = true
            message = "Saved and assigned \(clean) to this room. Save the room XML to keep the change."
        } catch { message = "Couldn't save: \(error.localizedDescription)" }
    }
    private func importImages() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.png, .jpeg, .gif]; panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        do {
            var bookmark = texturesBookmark
            guard let destination = try authorizedFolder(path: texturesPath, bookmark: &bookmark, purpose: "custom_textures") else { return }
            texturesBookmark = bookmark
            texturesPath = destination.path
            let destinationAccess = destination.startAccessingSecurityScopedResource()
            defer { if destinationAccess { destination.stopAccessingSecurityScopedResource() } }
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            var count = 0
            for source in panel.urls {
                let access = source.startAccessingSecurityScopedResource()
                defer { if access { source.stopAccessingSecurityScopedResource() } }
                let target = destination.appendingPathComponent(source.lastPathComponent)
                if FileManager.default.fileExists(atPath: target.path) { continue }
                try FileManager.default.copyItem(at: source, to: target); count += 1
            }
            message = "Imported \(count) image(s). Refresh Assets to place them on the canvas."
        } catch { message = "Couldn't import: \(error.localizedDescription)" }
    }
}
