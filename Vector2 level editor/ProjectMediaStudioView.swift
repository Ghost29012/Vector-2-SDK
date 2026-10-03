import AppKit
import SwiftUI

/// Shows rooms, audio, models and images with their own previews and controls.
struct ProjectMediaStudioView: View {
    let section: String
    let folder: URL
    let files: [URL]
    let onImport: () -> Void
    let onOpenTrickStudio: () -> Void
    let onOpenRoom: (String) -> Void
    let onOpenPoolBackground: () -> Void
    let onPlacePoolBackground: (URL) -> Void
    let onPlaceSceneBackground: (String) -> Void
    let onDelete: (URL) -> Void
    let onChanged: () -> Void
    @State private var pendingDelete: URL?
    @State private var backgroundZones: [(id: String, name: String)] = []
    @State private var backgroundTags: [String: (zone: String, role: String)] = [:]
    @State private var sceneBackgrounds: [(name: String, zone: String, preview: String?)] = []
    @State private var poolBackgrounds: [(file: URL, name: String, zone: String, preview: String?)] = []
    @State private var vectorBackgroundNames: [String] = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if section == "Backgrounds", !sceneBackgrounds.isEmpty { sceneBackgroundControls }
                    if section == "Backgrounds", !poolBackgrounds.isEmpty { poolBackgroundControls }
                    if section == "Backgrounds", !vectorBackgroundNames.isEmpty { vectorBackgroundControls }
                    Group {
                        if files.isEmpty && (section != "Backgrounds" || (poolBackgrounds.isEmpty && sceneBackgrounds.isEmpty)) { emptyState }
                        else if files.isEmpty { EmptyView() }
                        else if section == "Content" { roomList }
                        else if section == "Audio" { audioGrid }
                        else if section == "Models" { modelGrid }
                        else { artworkGrid }
                    }
                }.frame(maxWidth: 1240).padding(24).frame(maxWidth: .infinity)
            }.background(Color(nsColor: .windowBackgroundColor))
        }
        .alert("Delete this file?", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) { pendingDelete = nil }
            Button("Delete", role: .destructive) {
                if let file = pendingDelete {
                    onDelete(file)
                    if section == "Backgrounds" { loadBackgroundTags() }
                }
                pendingDelete = nil
            }
        } message: {
            Text("This removes it from the project. Install Changes will clean up its old game copy.")
        }
        .onAppear { if section == "Backgrounds" { loadBackgroundTags() } }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 22, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 48, height: 48).background(tint.gradient, in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 2) { Text(title).font(.system(size: 27, weight: .bold)); Text(subtitle).foregroundStyle(.secondary) }
            Spacer()
            Button("Open Folder") { NSWorkspace.shared.open(folder) }
            if section == "Tricks" {
                Button("Import Existing", action: onImport)
                Button("Open Trick Creator", action: onOpenTrickStudio).buttonStyle(.borderedProminent)
            }
            else { Button("Import \(section)", action: onImport).buttonStyle(.borderedProminent) }
        }.padding(.horizontal, 24).padding(.vertical, 16).background(Color(nsColor: .controlBackgroundColor).opacity(0.94))
    }

    private var roomList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Rooms", systemImage: "square.stack.3d.up.fill").font(.title3.bold())
            ForEach(files, id: \.path) { file in
                HStack(spacing: 14) {
                    Image(systemName: "doc.text.fill").font(.title2).foregroundStyle(.blue).frame(width: 42, height: 42).background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 11))
                    VStack(alignment: .leading, spacing: 3) { Text(file.deletingPathExtension().lastPathComponent).fontWeight(.semibold); Text(file.deletingLastPathComponent().lastPathComponent).font(.caption).foregroundStyle(.secondary) }
                    Spacer(); Text(modified(file)).font(.caption).foregroundStyle(.secondary)
                    Button("Open") { onOpenRoom(file.path) }
                    deleteButton(file)
                }.padding(13).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 15))
            }
        }
    }

    private var artworkGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 245, maximum: 340), spacing: 14)], spacing: 14) {
            ForEach(files.filter { section != "Backgrounds" || ["png", "jpg", "jpeg", "webp"].contains($0.pathExtension.lowercased()) }, id: \.path) { file in
                VStack(alignment: .leading, spacing: 9) {
                    ZStack {
                        Color(nsColor: .controlBackgroundColor)
                        if let image = NSImage(contentsOf: file) {
                            Image(nsImage: image).resizable().scaledToFill().scaleEffect(1.08).blur(radius: 15)
                            Color.black.opacity(0.12)
                            Image(nsImage: image).resizable().scaledToFit().padding(7)
                        } else { Image(systemName: symbol).font(.system(size: 42)).foregroundStyle(tint) }
                    }.frame(height: section == "Backgrounds" ? 155 : 185).clipped().clipShape(RoundedRectangle(cornerRadius: 14))
                    Text(file.deletingPathExtension().lastPathComponent).font(.headline).lineLimit(1)
                    if section == "Backgrounds" { backgroundControls(for: file) }
                    HStack { Text(file.pathExtension.uppercased()).font(.caption.bold()).foregroundStyle(.secondary); Spacer(); reveal(file); deleteButton(file) }
                }.padding(12).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 17))
            }
        }
    }

    private func backgroundControls(for file: URL) -> some View {
        let tag = backgroundTags[file.lastPathComponent]
        return HStack {
            Picker("Zone", selection: Binding(
                get: { tag?.zone ?? "" },
                set: { setBackgroundTag(file: file, zone: $0, role: tag?.role ?? "Menu") }
            )) {
                Text("Unassigned").tag("")
                ForEach(backgroundZones.map(\.id), id: \.self) { id in
                    Text(backgroundZones.first(where: { $0.id == id })?.name ?? id).tag(id)
                }
            }
            Picker("Use", selection: Binding(
                get: { tag?.role ?? "Menu" },
                set: { setBackgroundTag(file: file, zone: tag?.zone ?? "", role: $0) }
            )) {
                Text("Menu").tag("Menu")
                Text("Loading").tag("Loading")
            }.disabled(tag == nil)
        }.labelsHidden()
    }

    private func loadBackgroundTags() {
        let project = folder.deletingLastPathComponent()
        loadVectorBackgroundNames(project: project)
        let poolFolder = project.appendingPathComponent("custom_backgrounds_pool", isDirectory: true)
        poolBackgrounds = ((try? FileManager.default.contentsOfDirectory(at: poolFolder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "xml" && $0.lastPathComponent.lowercased() != "custom_backgrounds.xml" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .compactMap { file in
                guard let root = (try? XMLDocument(contentsOf: file))?.rootElement(), root.name == "Background" else { return nil }
                let artClass = ((try? root.nodes(forXPath: ".//Image | .//CustomAnimation")) ?? [])
                    .compactMap { ($0 as? XMLElement)?.attribute(forName: "ClassName")?.stringValue }.first
                let preview = artClass.flatMap { Vector2AssetCatalog.imagePath(forClassName: $0) }
                return (file: file, name: root.attribute(forName: "Name")?.stringValue ?? file.deletingPathExtension().lastPathComponent,
                        zone: root.attribute(forName: "Zone")?.stringValue ?? "Unassigned", preview: preview)
            }
        let zoneFolder = project.appendingPathComponent("custom_zones")
        let files = (try? FileManager.default.contentsOfDirectory(at: zoneFolder, includingPropertiesForKeys: nil)) ?? []
        backgroundZones = files.filter { $0.pathExtension.lowercased() == "xml" }.flatMap { url -> [(id: String, name: String)] in
            guard let xml = try? XMLDocument(contentsOf: url), let nodes = try? xml.nodes(forXPath: "//Zone") else { return [] }
            return nodes.compactMap { node in
                guard let element = node as? XMLElement, let id = element.attribute(forName: "Id")?.stringValue else { return nil }
                return (id: id, name: element.attribute(forName: "Name")?.stringValue ?? id)
            }
        }
        let sceneCatalog = folder.appendingPathComponent("custom_backgrounds.xml")
        if let sceneXML = try? XMLDocument(contentsOf: sceneCatalog) {
            sceneBackgrounds = (sceneXML.rootElement()?.elements(forName: "Background") ?? []).compactMap { item in
                guard let name = item.attribute(forName: "Name")?.stringValue else { return nil }
                let artClass = ((try? item.nodes(forXPath: ".//Image | .//CustomAnimation")) ?? [])
                    .compactMap { ($0 as? XMLElement)?.attribute(forName: "ClassName")?.stringValue }.first
                return (name: name, zone: item.attribute(forName: "Zone")?.stringValue ?? "",
                        preview: artClass.flatMap { Vector2AssetCatalog.imagePath(forClassName: $0) })
            }
        } else { sceneBackgrounds = [] }
        let manifest = folder.appendingPathComponent("zone_backgrounds.xml")
        guard let xml = try? XMLDocument(contentsOf: manifest), let root = xml.rootElement() else { return }
        backgroundTags = Dictionary(uniqueKeysWithValues: root.elements(forName: "Background").compactMap { element in
            guard let file = element.attribute(forName: "File")?.stringValue,
                  let zone = element.attribute(forName: "Zone")?.stringValue,
                  let role = element.attribute(forName: "Role")?.stringValue else { return nil }
            return (file, (zone: zone, role: role))
        })
    }

    private func loadVectorBackgroundNames(project: URL) {
        guard let projectXML = try? XMLDocument(contentsOf: project.appendingPathComponent("project.xml")),
              let metadata = projectXML.rootElement() else { vectorBackgroundNames = []; return }
        var candidates: [URL] = []
        for attribute in ["StockBackgroundLibraryPath", "GameSourcePath", "GameDataPath"] {
            let raw = metadata.attribute(forName: attribute)?.stringValue ?? ""
            guard !raw.isEmpty else { continue }
            let url = URL(fileURLWithPath: raw)
            if url.pathExtension.lowercased() == "xml" { candidates.append(url); continue }
            candidates += [
                url.appendingPathComponent("background.xml"),
                url.appendingPathComponent("run_data/libraries/background.xml"),
                url.appendingPathComponent("gamedata/run_data/libraries/background.xml"),
                url.appendingPathComponent("Resources/gamedata/run_data/libraries/background.xml"),
                url.appendingPathComponent("Assets/Resources/gamedata/run_data/libraries/background.xml")
            ]
        }
        guard let library = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
              let xml = try? XMLDocument(contentsOf: library),
              let objects = try? xml.nodes(forXPath: "/Root/Objects/Object") else {
            vectorBackgroundNames = []; return
        }
        vectorBackgroundNames = objects.compactMap { node in
            let name = (node as? XMLElement)?.attribute(forName: "Name")?.stringValue ?? ""
            return name.isEmpty || name == "placeholder_background" ? nil : name
        }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private var vectorBackgroundControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("VECTOR 2 LIBRARY").font(.caption.bold()).foregroundStyle(.secondary)
                    Text("\(vectorBackgroundNames.count) shipped backgrounds available for inspection. These stay read-only and are never installed back into Vector 2.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Browse in Zone Pool Designer", action: onOpenPoolBackground)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(vectorBackgroundNames.prefix(24), id: \.self) { name in
                        Text(name).font(.caption.weight(.medium)).padding(.horizontal, 10).padding(.vertical, 7)
                            .background(Color.secondary.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }.padding(16).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
    }

    private var poolBackgroundControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ZONE POOL BACKGROUNDS").font(.caption.bold()).foregroundStyle(.secondary)
            Text("These saved sets are installed with the project and can be picked at random in their zone.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(poolBackgrounds, id: \.file) { item in
                HStack {
                    if let path = item.preview, let image = NSImage(contentsOfFile: path) {
                        Image(nsImage: image).resizable().scaledToFit()
                            .frame(width: 88, height: 54).background(Color.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                    } else {
                        Image(systemName: "photo.stack").foregroundStyle(.purple).frame(width: 88, height: 54)
                    }
                    Text(item.name).fontWeight(.medium)
                    Text(item.zone).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Open in Designer") {
                        UserDefaults.standard.set(item.name, forKey: "vector2ZonePoolOpenName")
                        onOpenPoolBackground()
                    }
                    Button("Place in Room") { onPlacePoolBackground(item.file) }
                    Button("Delete", role: .destructive) { pendingDelete = item.file }
                }
            }
        }.padding(16).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
    }

    private var sceneBackgroundControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ROOM BACKGROUND SETS").font(.caption.bold()).foregroundStyle(.secondary)
            Text("Tag a saved scene background with a zone. The game picks one tagged set for each room in that zone.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(sceneBackgrounds.map(\.name), id: \.self) { name in
                HStack {
                    if let path = sceneBackgrounds.first(where: { $0.name == name })?.preview,
                       let image = NSImage(contentsOfFile: path) {
                        Image(nsImage: image).resizable().scaledToFit().frame(width: 88, height: 54)
                    }
                    Text(name).frame(maxWidth: .infinity, alignment: .leading)
                    Button("Place in Room") { onPlaceSceneBackground(name) }
                    Picker("Zone", selection: Binding(
                        get: { sceneBackgrounds.first(where: { $0.name == name })?.zone ?? "" },
                        set: { setSceneBackgroundZone(name: name, zone: $0) }
                    )) {
                        Text("Unassigned").tag("")
                        ForEach(backgroundZones.map(\.id), id: \.self) { id in
                            Text(backgroundZones.first(where: { $0.id == id })?.name ?? id).tag(id)
                        }
                    }.frame(width: 220)
                }
            }
        }.padding(16).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
    }

    private func setSceneBackgroundZone(name: String, zone: String) {
        let catalog = folder.appendingPathComponent("custom_backgrounds.xml")
        guard let xml = try? XMLDocument(contentsOf: catalog),
              let item = xml.rootElement()?.elements(forName: "Background").first(where: { $0.attribute(forName: "Name")?.stringValue == name }) else { return }
        item.removeAttribute(forName: "Zone")
        if !zone.isEmpty { item.addAttribute(XMLNode.attribute(withName: "Zone", stringValue: zone) as! XMLNode) }
        do {
            try xml.xmlData(options: .nodePrettyPrint).write(to: catalog, options: .atomic)
            if let index = sceneBackgrounds.firstIndex(where: { $0.name == name }) { sceneBackgrounds[index].zone = zone }
            onChanged()
        } catch { return }
    }

    private func setBackgroundTag(file: URL, zone: String, role: String) {
        if zone.isEmpty { backgroundTags.removeValue(forKey: file.lastPathComponent) }
        else { backgroundTags[file.lastPathComponent] = (zone: zone, role: role) }
        let root = XMLElement(name: "ZoneBackgrounds")
        for (filename, tag) in backgroundTags.sorted(by: { $0.key < $1.key }) {
            let item = XMLElement(name: "Background")
            for (name, value) in [("File", filename), ("Zone", tag.zone), ("Role", tag.role)] {
                item.addAttribute(XMLNode.attribute(withName: name, stringValue: value) as! XMLNode)
            }
            root.addChild(item)
        }
        let xml = XMLDocument(rootElement: root)
        do {
            try xml.xmlData(options: .nodePrettyPrint).write(to: folder.appendingPathComponent("zone_backgrounds.xml"), options: .atomic)
            onChanged()
        }
        catch { backgroundTags.removeValue(forKey: file.lastPathComponent) }
    }

    private var audioGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 14)], spacing: 14) {
            ForEach(files, id: \.path) { file in
                HStack(spacing: 14) {
                    Image(systemName: "waveform.circle.fill").font(.system(size: 40)).foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(file.deletingPathExtension().lastPathComponent).font(.headline)
                        Text("Runtime ID: \(file.deletingPathExtension().lastPathComponent)").font(.caption.weight(.medium)).foregroundStyle(.orange)
                        Text(audioDetails(file)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(); Button { NSSound(contentsOf: file, byReference: true)?.play() } label: { Image(systemName: "play.fill") }.buttonStyle(.borderedProminent); reveal(file); deleteButton(file)
                }.padding(16).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 17))
            }
        }
    }

    private var modelGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 14)], spacing: 14) {
            ForEach(files, id: \.path) { file in
                VStack(spacing: 14) {
                    ZStack { RoundedRectangle(cornerRadius: 18).fill(LinearGradient(colors: [.purple.opacity(0.18), .blue.opacity(0.06)], startPoint: .topLeading, endPoint: .bottomTrailing)); Image(systemName: "cube.transparent.fill").font(.system(size: 70)).foregroundStyle(.purple) }.frame(height: 155)
                    Text(file.deletingPathExtension().lastPathComponent).font(.headline).lineLimit(1)
                    HStack { Text(file.pathExtension.uppercased()).font(.caption.bold()).foregroundStyle(.secondary); Spacer(); reveal(file); deleteButton(file) }
                }.padding(14).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18))
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No \(section.lowercased()) yet", systemImage: symbol)
        } description: {
            Text(subtitle)
        } actions: {
            Button(section == "Tricks" ? "Open Trick Creator" : "Import \(section)", action: section == "Tricks" ? onOpenTrickStudio : onImport)
                .buttonStyle(.borderedProminent)
        }.frame(minHeight: 430)
    }

    private func reveal(_ file: URL) -> some View { Button { NSWorkspace.shared.activateFileViewerSelecting([file]) } label: { Image(systemName: "folder") }.buttonStyle(.borderless) }
    private func deleteButton(_ file: URL) -> some View {
        Button(role: .destructive) { pendingDelete = file } label: { Image(systemName: "trash") }
            .buttonStyle(.borderless)
            .help("Delete from project")
    }
    private func modified(_ file: URL) -> String { ((try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map { $0.formatted(date: .abbreviated, time: .shortened) }) ?? "—" }
    private func audioDetails(_ file: URL) -> String {
        let bytes = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return "\(file.pathExtension.uppercased()) · \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))"
    }
    private var title: String { section == "Content" ? "Room Library" : section == "Tricks" ? "Trick Library" : "\(section) Library" }
    private var subtitle: String { ["Content": "Open or import the rooms used by this project.", "Models": "View the character models in this project.", "Tricks": "Manage custom tricks and their shop cards.", "Audio": "Listen to imported music and sound effects.", "Assets": "View imported card, dialogue, and interface images.", "Backgrounds": "View the backgrounds available to chapters and zones."][section] ?? "Project files" }
    private var symbol: String { ["Content": "square.stack.3d.up.fill", "Models": "cube.transparent.fill", "Tricks": "figure.run", "Audio": "waveform", "Assets": "photo.on.rectangle.angled", "Backgrounds": "photo.fill"][section] ?? "folder.fill" }
    private var tint: Color { ["Content": Color.blue, "Models": .purple, "Tricks": .green, "Audio": .orange, "Assets": .cyan, "Backgrounds": .indigo][section] ?? .blue }
}
