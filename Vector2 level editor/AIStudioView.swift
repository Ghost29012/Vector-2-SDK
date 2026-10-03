import SwiftUI

struct AIStudioView: View {
    @Binding var document: LevelDocument
    let gameDirectory: String
    let onStatus: (String) -> Void

    @State private var selectedCharacterID: AICharacterDefinition.ID?
    @State private var skins: [TrickPreviewModelSkin] = []
    @State private var customModels: [CustomModelItem] = []
    @State private var playback: TrickPreviewPlayback?
    @State private var previewError = ""
    @State private var previewZoom: CGFloat = 3.5
    @State private var gestureStartZoom: CGFloat?

    var body: some View {
        HStack(spacing: 0) {
            characterList
            Divider()
            previewPanel
            Divider()
            configurationPanel
        }
        .background(Color.editorCanvasBackground)
        .onAppear {
            if selectedCharacterID == nil { selectedCharacterID = document.aiCharacters.first?.id }
            loadCatalog()
            rebuildPreview()
        }
        .onChange(of: selectedCharacterID) { _, _ in rebuildPreview() }
    }

    private var characterList: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("AI DESIGNER")
                        .font(.system(size: 11, weight: .black, design: .rounded))
                        .foregroundStyle(.secondary)
                    Text(document.name)
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                }
                Spacer()
                Button(action: addCharacter) { Image(systemName: "plus") }
                    .buttonStyle(.borderedProminent)
            }

            if document.aiCharacters.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "person.2.slash").font(.system(size: 30))
                    Text("No AI in this level").font(.headline)
                    Text("Add a Hunter or a friendly runner to this room.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(document.aiCharacters) { character in
                            Button {
                                selectedCharacterID = character.id
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: character.kind == .enemy ? "scope" : "figure.run")
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(character.name)
                                            .font(.system(size: 13, weight: .bold))
                                            .foregroundStyle(character.kind == .enemy ? Color.red : Color.blue)
                                        Text("AI \(character.aiChannel) - \(character.kind.rawValue)")
                                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                                .padding(10)
                                .background(
                                    RoundedRectangle(cornerRadius: 9)
                                        .fill(selectedCharacterID == character.id ? Color.accentColor.opacity(0.15) : Color.platformControlBackground)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            Divider()
            groupEditor
        }
        .padding(16)
        .frame(width: 290)
        .background(Color.editorChromeBackground)
    }

    private var previewPanel: some View {
        VStack(spacing: 12) {
            Text(selectedCharacter?.name ?? "Create an AI")
                .font(.system(size: 26, weight: .semibold, design: .default))
                .tracking(-0.4)
                .foregroundStyle(selectedCharacter?.kind == .enemy ? Color.red : Color.blue)
            Text("LIVE MODEL PREVIEW")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)

            GeometryReader { geometry in
                ZStack {
                    RoundedRectangle(cornerRadius: 18)
                        .fill(
                            LinearGradient(
                                colors: [Color.black.opacity(0.95), Color.blue.opacity(0.10)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    if let playback {
                        TrickPreviewOverlay(
                            playback: playback,
                            anchor: CGPoint(x: geometry.size.width / 2, y: geometry.size.height * 0.72),
                            zoom: previewZoom,
                            unitsPerCanvasPoint: 3,
                            showsDebugLabel: false
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                    } else {
                        VStack(spacing: 10) {
                            Image(systemName: "figure.stand")
                                .font(.system(size: 48))
                            Text(previewError.isEmpty ? "Select a character" : previewError)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                    }

                    VStack {
                        Spacer()
                        HStack(spacing: 8) {
                            Button { previewZoom = max(0.75, previewZoom - 0.5) } label: {
                                Image(systemName: "minus.magnifyingglass")
                            }
                            Slider(value: $previewZoom, in: 0.75...8)
                                .frame(width: 150)
                            Button { previewZoom = min(8, previewZoom + 0.5) } label: {
                                Image(systemName: "plus.magnifyingglass")
                            }
                            Button("Reset") { previewZoom = 3.5 }
                        }
                        .buttonStyle(.bordered)
                        .padding(10)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, 14)
                    }
                }
                .gesture(
                    MagnificationGesture()
                        .onChanged { scale in
                            let base = gestureStartZoom ?? previewZoom
                            if gestureStartZoom == nil { gestureStartZoom = previewZoom }
                            previewZoom = min(8, max(0.75, base * scale))
                        }
                        .onEnded { _ in gestureStartZoom = nil }
                )
            }
            .frame(minWidth: 430, minHeight: 520)

            Text("Uses the existing Vector 2 model stack and animation reader.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var configurationPanel: some View {
        ScrollView {
            if selectedCharacter != nil {
                VStack(alignment: .leading, spacing: 16) {
                    Text("CHARACTER")
                        .font(.system(size: 11, weight: .black, design: .rounded))
                        .foregroundStyle(.secondary)
                    TextField("Name", text: characterBinding(\.name, fallback: "AI"))
                        .textFieldStyle(.roundedBorder)
                    Picker("Type", selection: characterBinding(\.kind, fallback: .friendly)) {
                        ForEach(AICharacterKind.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Stepper("AI channel \(selectedCharacter?.aiChannel ?? 1)", value: characterBinding(\.aiChannel, fallback: 1), in: 1...999)

                    GroupBox("Spawn") {
                        VStack(alignment: .leading, spacing: 10) {
                            TextField("Spawn name", text: characterBinding(\.birthSpawn, fallback: "DefaultSpawn"))
                            Stepper(
                                "Start delay \(selectedCharacter?.startDelay ?? 0, specifier: "%.1f")s",
                                value: characterBinding(\.startDelay, fallback: 0),
                                in: 0...30,
                                step: 0.1
                            )
                        }
                        .padding(6)
                    }

                    GroupBox("Model stack") {
                        VStack(alignment: .leading, spacing: 10) {
                            skinPicker("Body", selection: characterBinding(\.bodySkin, fallback: "1.xml"), options: bodySkins, allowsNone: false)
                            skinPicker("Chest", selection: characterBinding(\.chestSkin, fallback: ""), options: chestSkins, allowsNone: true)
                            skinPicker("Helmet", selection: characterBinding(\.helmetSkin, fallback: ""), options: helmetSkins, allowsNone: true)
                            skinPicker("Hair", selection: characterBinding(\.hairSkin, fallback: ""), options: hairSkins, allowsNone: true)
                        }
                        .padding(6)
                    }

                    GroupBox("Custom model layers") {
                        VStack(alignment: .leading, spacing: 9) {
                            if customModels.isEmpty { Text("No models installed in custom_models.").font(.caption).foregroundStyle(.secondary) }
                            ForEach(customModels) { model in
                                Toggle("\(model.name) · \(model.category)", isOn: customLayerBinding(model.reference))
                            }
                        }.padding(6)
                    }

                    Button(role: .destructive, action: deleteSelectedCharacter) {
                        Label("Delete AI", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                }
                .onChange(of: selectedCharacter) { _, _ in rebuildPreview() }
            } else {
                Text("Add an AI to get started.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 330)
        .background(Color.editorChromeBackground)
    }

    private var groupEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("GROUPS")
                    .font(.system(size: 10, weight: .black, design: .rounded))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    document.aiGroups.append(.init(name: "Group \(document.aiGroups.count + 1)"))
                } label: { Image(systemName: "plus.circle") }
                .buttonStyle(.plain)
            }
            ForEach($document.aiGroups) { $group in
                DisclosureGroup {
                    ForEach(document.aiCharacters) { character in
                        Toggle(character.name, isOn: Binding(
                            get: { group.characterIDs.contains(character.id) },
                            set: { enabled in
                                if enabled { group.characterIDs.insert(character.id) }
                                else { group.characterIDs.remove(character.id) }
                            }
                        ))
                        .tint(character.kind == .enemy ? .red : .blue)
                    }
                } label: {
                    TextField("Group name", text: $group.name)
                        .textFieldStyle(.plain)
                }
            }
        }
    }

    private var selectedCharacter: AICharacterDefinition? {
        document.aiCharacters.first { $0.id == selectedCharacterID }
    }

    private func characterBinding<T>(_ keyPath: WritableKeyPath<AICharacterDefinition, T>, fallback: T) -> Binding<T> {
        Binding(
            get: { selectedCharacter?[keyPath: keyPath] ?? fallback },
            set: { value in
                guard let id = selectedCharacterID,
                      let index = document.aiCharacters.firstIndex(where: { $0.id == id }) else { return }
                document.aiCharacters[index][keyPath: keyPath] = value
            }
        )
    }

    private func skinPicker(_ title: String, selection: Binding<String>, options: [TrickPreviewModelSkin], allowsNone: Bool) -> some View {
        Picker(title, selection: selection) {
            if allowsNone { Text("None").tag("") }
            ForEach(options) { Text($0.displayName).tag($0.filename) }
        }
    }

    private var bodySkins: [TrickPreviewModelSkin] {
        skins.filter { !isAccessory($0.filename) && $0.filename != "0.xml" }
    }
    private var chestSkins: [TrickPreviewModelSkin] {
        skins.filter { ["armor", "shirt", "jacket", "shorts", "scarf"].contains(where: $0.filename.lowercased().contains) }
    }
    private var helmetSkins: [TrickPreviewModelSkin] {
        skins.filter { $0.filename.lowercased().contains("helmet") || $0.filename.lowercased().contains("cap") }
    }
    private var hairSkins: [TrickPreviewModelSkin] {
        skins.filter { $0.filename.lowercased().contains("hair") }
    }
    private func isAccessory(_ name: String) -> Bool {
        ["hair", "helmet", "cap", "armor", "gear", "shirt", "jacket", "shorts", "scarf"].contains { name.lowercased().contains($0) }
    }

    private func addCharacter() {
        let channel = (document.aiCharacters.map(\.aiChannel).max() ?? 0) + 1
        let character = AICharacterDefinition(
            name: "Friendly\(document.aiCharacters.count + 1)",
            kind: .friendly,
            aiChannel: channel,
            bodySkin: skins.contains(where: { $0.filename == "helper.xml" }) ? "helper.xml" : "1.xml",
            hairSkin: skins.contains(where: { $0.filename == "hair.xml" }) ? "hair.xml" : ""
        )
        document.aiCharacters.append(character)
        selectedCharacterID = character.id
        onStatus("Added \(character.name) to \(document.name)")
    }

    private func deleteSelectedCharacter() {
        guard let id = selectedCharacterID else { return }
        document.aiCharacters.removeAll { $0.id == id }
        for index in document.aiGroups.indices { document.aiGroups[index].characterIDs.remove(id) }
        let deletedTarget = "character:\(id.uuidString)"
        for node in document.root.flattenedSceneNodes() where node.metadata.aiTarget == deletedTarget {
            document.root.update(id: node.id) {
                $0.metadata.aiTarget = ""
                $0.metadata.aiActionTemplate = ""
                $0.metadata.aiActionValue = ""
            }
        }
        selectedCharacterID = document.aiCharacters.first?.id
        rebuildPreview()
    }

    private func loadCatalog() {
        let catalog = TrickPreviewCatalog(gameDirectory: gameDirectory)
        skins = catalog.loadModelSkins()
        customModels = CustomModelCatalog.load()
    }

    private func customLayerBinding(_ reference: String) -> Binding<Bool> {
        Binding(get: { selectedCharacter?.customLayers.contains(reference) ?? false }, set: { enabled in
            guard let id = selectedCharacterID, let index = document.aiCharacters.firstIndex(where: { $0.id == id }) else { return }
            if enabled { document.aiCharacters[index].customLayers.append(reference) }
            else { document.aiCharacters[index].customLayers.removeAll { $0 == reference } }
            rebuildPreview()
        })
    }

    private func rebuildPreview() {
        guard let character = selectedCharacter else { playback = nil; return }
        let catalog = TrickPreviewCatalog(gameDirectory: gameDirectory)
        let moves = catalog.loadMoves()
        guard let move = moves.first(where: { $0.fileName.localizedCaseInsensitiveContains("cs_swarm_idle") })
                ?? moves.first(where: { $0.name.localizedCaseInsensitiveContains("stand") })
                ?? moves.first else {
            previewError = "No preview animation found"
            playback = nil
            return
        }
        do {
            let selectedSkins = (["0.xml"] + character.skinFiles).vector2Uniqued()
            let model = try catalog.loadModel(skins: selectedSkins)
            let frames = try catalog.loadFrames(fileName: move.fileName)
            playback = TrickPreviewPlayback(
                move: move,
                model: model,
                frames: frames,
                startFrame: max(0, move.firstFrame),
                pivotIndex: model.nodeIndex(named: move.pivotNode),
                selectedSkins: selectedSkins,
                anchorNodeID: nil
            )
            previewError = ""
        } catch {
            previewError = error.localizedDescription
            playback = nil
        }
    }
}
