import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

struct CustomTrickStudioView: View {
    let gameDirectory: String
    var projectTricksDirectory: URL? = nil
    let onClose: () -> Void
    let onStatus: (String) -> Void

    @AppStorage("vector2CustomTricksDirectory") private var folderPath = ""
    @AppStorage("vector2CustomTricksDirectoryBookmark") private var folderBookmark = ""
    @State private var bytesName = ""
    @State private var bytesData: Data?
    @State private var frames: [TrickPreviewFrame] = []
    @State private var playback: TrickPreviewPlayback?
    @State private var trickName = ""
    @State private var visualName = ""
    @State private var trickDescription = ""
    @State private var cardImage = ""
    @State private var cardRarity = 1
    @State private var cardPrice = 1100
    @State private var frame = 0.0
    @State private var playing = false
    @State private var entry = 0
    @State private var safeStart = 0
    @State private var safeEnd = 0
    @State private var exitFrame = 1
    @State private var exitAnimation = "RunForward"
    @State private var chainAnimations: [TrickPreviewMove] = []
    @State private var chainsToAnotherAnimation = false
    @State private var installMode: AnimationInstallMode = .newAnimation
    @State private var overrideTarget = ""
    @State private var choosingOverrideTarget = false
    @State private var pivot = "DetectorH"
    @State private var zoom: CGFloat = 3.5
    @State private var previewOffset: CGSize = .zero
    @GestureState private var previewDrag: CGSize = .zero
    @State private var message = "Import a Vector .bytes animation to begin."
    @State private var importing = false
    @State private var choosingFolder = false
    @State private var player: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Custom Animations")
                        .font(.system(.title3, design: .default, weight: .semibold))
                    Text(bytesName.isEmpty ? "No animation imported" : bytesName).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Import .bytes", action: beginImport).buttonStyle(.borderedProminent)
                Button("Close", action: onClose).buttonStyle(.bordered)
            }.padding(16)
            Divider()
            HStack(spacing: 0) {
                preview
                Divider()
                setup.frame(width: 320)
            }
            Divider()
            Text(message).font(.caption).frame(maxWidth: .infinity, alignment: .leading).padding(10)
        }
        .frame(minWidth: 900, minHeight: 650)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data], allowsMultipleSelection: false, onCompletion: receiveBytes)
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder], allowsMultipleSelection: false, onCompletion: receiveFolder)
        .sheet(isPresented: $choosingOverrideTarget) {
            AnimationOverrideTargetPicker(
                moves: chainAnimations,
                selectedName: overrideTarget,
                onSelect: { move in
                    overrideTarget = move.name
                    pivot = move.pivotNode
                    chainsToAnotherAnimation = false
                    choosingOverrideTarget = false
                    rebuildPlayback(resetFrame: true)
                },
                onCancel: { choosingOverrideTarget = false }
            )
        }
        .onAppear {
            if let projectTricksDirectory { folderPath = projectTricksDirectory.path }
            refreshChainAnimations()
        }
        .onChange(of: chainsToAnotherAnimation) { _, _ in rebuildPlayback(resetFrame: true) }
        .onChange(of: exitAnimation) { _, _ in rebuildPlayback(resetFrame: true) }
        .onChange(of: exitFrame) { _, _ in rebuildPlayback(resetFrame: true) }
        .onChange(of: safeEnd) { _, _ in if chainsToAnotherAnimation { rebuildPlayback(resetFrame: true) } }
        .onDisappear { player?.cancel() }
    }

    private var preview: some View {
        VStack(spacing: 12) {
            GeometryReader { proxy in
                let livePan = CGSize(
                    width: previewOffset.width + previewDrag.width,
                    height: previewOffset.height + previewDrag.height
                )
                ZStack {
                    LinearGradient(colors: [.black, .blue.opacity(0.12)], startPoint: .top, endPoint: .bottom)
                    CanvasGrid(panOffset: livePan, zoom: max(0.25, zoom / 3.5))
                        .opacity(0.22)
                    if let playback {
                        TrickPreviewOverlay(
                            playback: playback,
                            anchor: CGPoint(
                                x: proxy.size.width / 2 + livePan.width,
                                y: proxy.size.height / 2 + livePan.height
                            ),
                            zoom: zoom,
                            unitsPerCanvasPoint: 3,
                            showsDebugLabel: false,
                            fixedFrame: Int(frame),
                            centersVisibleModel: true
                        )
                    } else {
                        VStack(spacing: 10) { Image(systemName: "figure.run").font(.system(size: 48)); Text("Import an animation to preview it").foregroundStyle(.secondary) }
                    }
#if os(macOS)
                    CanvasInputCatcher(
                        panOffset: $previewOffset,
                        zoom: $zoom,
                        onDeleteSelection: {},
                        onClearFocus: {},
                        onShiftSelectClick: nil,
                        onShiftSelectDragStart: nil,
                        onShiftSelectDragChange: nil,
                        onShiftSelectDragEnd: nil,
                        onToolScroll: nil,
                        onAlternatePlacementChanged: nil
                    )
#endif
                }
                .contentShape(Rectangle())
                .gesture(DragGesture().updating($previewDrag) { value, state, _ in state = value.translation }.onEnded { value in previewOffset.width += value.translation.width; previewOffset.height += value.translation.height })
                .clipShape(RoundedRectangle(cornerRadius: 18))
            }
            HStack {
                Button { togglePlay() } label: { Image(systemName: playing ? "pause.fill" : "play.fill") }
                Button { frame = max(0, frame - 1) } label: { Image(systemName: "backward.frame.fill") }
                Slider(value: $frame, in: 0...Double(max(1, previewFrameCount - 1)), step: 1)
                Button { frame = min(Double(max(0, previewFrameCount - 1)), frame + 1) } label: { Image(systemName: "forward.frame.fill") }
                Text("\(Int(frame)) / \(max(0, previewFrameCount - 1))").font(.system(.caption, design: .monospaced)).frame(width: 82)
            }.buttonStyle(.bordered).disabled(frames.isEmpty)
            HStack { Image(systemName: "minus.magnifyingglass"); Slider(value: $zoom, in: 0.4...10); Image(systemName: "plus.magnifyingglass"); Button("Reset view") { previewOffset = .zero; zoom = 3.5 } }.frame(maxWidth: 380)
            Text(chainsToAnotherAnimation ? "Drag or middle-drag to pan; scroll to zoom. Preview includes the transition into \(exitAnimation)." : "Drag or middle-drag to pan the viewport; scroll to zoom.").font(.caption).foregroundStyle(.secondary)
        }.padding(20)
    }

    private var setup: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Animation Setup")
                    .font(.system(.headline, design: .default, weight: .semibold))
                Text("Install as")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Picker("Install as", selection: $installMode) {
                    Text("New Animation").tag(AnimationInstallMode.newAnimation)
                    Text("Override Animation").tag(AnimationInstallMode.overrideAnimation)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .onChange(of: installMode) { _, mode in
                    if mode == .overrideAnimation { chainsToAnotherAnimation = false }
                    rebuildPlayback(resetFrame: true)
                }
                if installMode == .newAnimation {
                    TextField("Animation name", text: $trickName).textFieldStyle(.roundedBorder)
                    Picker("Pivot", selection: $pivot) { Text("Horizontal").tag("DetectorH"); Text("Vertical").tag("DetectorV"); Text("Center").tag("COM") }
                        .onChange(of: pivot) { _, _ in rebuildPlayback() }
                    GroupBox("Shop card") {
                        VStack(alignment: .leading, spacing: 10) {
                            TextField("Display name", text: $visualName).textFieldStyle(.roundedBorder)
                            TextField("Description", text: $trickDescription, axis: .vertical).lineLimit(2...4).textFieldStyle(.roundedBorder)
                            Picker("Card image", selection: $cardImage) {
                                Text("Default trick image").tag("")
                                ForEach(availableCardImages, id: \.self) { Text($0).tag($0) }
                            }.pickerStyle(.menu)
                            Picker("Rarity", selection: $cardRarity) {
                                Text("Common").tag(1); Text("Rare").tag(2); Text("Epic").tag(3)
                            }.pickerStyle(.segmented)
                            Stepper("Shop price: \(cardPrice)", value: $cardPrice, in: 0...100_000, step: 100)
                            Text("The game adds this to the Stunts cards.")
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(6)
                    }
                } else {
                    GroupBox("Target") {
                        VStack(alignment: .leading, spacing: 9) {
                            Button(overrideTarget.isEmpty ? "Choose animation…" : overrideTarget) { choosingOverrideTarget = true }
                                .buttonStyle(.borderedProminent)
                            if let target = selectedOverrideMove {
                                Text("Keeps \(target.name)'s original movement, collisions, reactions, intervals, and pivot.")
                                    .font(.caption).foregroundStyle(.secondary)
                                Label(overrideCompatibilityText, systemImage: overrideIsCompatible ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                    .font(.caption)
                                    .foregroundStyle(overrideIsCompatible ? .green : .orange)
                                Button("Restore Default", role: .destructive, action: restoreDefault)
                            } else {
                                Text("Select any move loaded from moves_new.xml.").font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding(6)
                    }
                }
                if installMode == .newAnimation {
                    GroupBox("Timeline") {
                    VStack(alignment: .leading, spacing: 10) {
                        frameStepper("Entry", $entry)
                        frameStepper("Safe start", $safeStart)
                        frameStepper("Safe end", $safeEnd)
                        Picker("Finish", selection: $chainsToAnotherAnimation) {
                            Text("Regular").tag(false)
                            Text("Chain").tag(true)
                        }.pickerStyle(.segmented)
                        if chainsToAnotherAnimation {
                            HStack {
                                TextField("End animation", text: $exitAnimation).textFieldStyle(.roundedBorder)
                                Menu("Choose") {
                                    ForEach(chainAnimations) { move in Button(move.name) { exitAnimation = move.name; exitFrame = min(exitFrame, maxExitFrame) } }
                                }
                            }
                            Stepper("Start next at frame: \(exitFrame)", value: $exitFrame, in: 0...maxExitFrame)
                            Text("Chains this animation into another built-in or custom animation.").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("Regular returns to RunForward automatically.").font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(6)
                    }
                }
                if projectTricksDirectory == nil {
                    GroupBox("Install location") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(folderPath.isEmpty ? "Choose Vector 2's custom_tricks folder." : folderPath).font(.caption).lineLimit(3)
                            Button("Choose custom_tricks folder", action: beginChooseFolder)
                        }.padding(6)
                    }
                } else {
                    Label("Saves into this project and Live Sync installs it into Vector 2.", systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.green)
                }
                Button(installMode == .newAnimation ? "Create Custom Animation" : "Install Override", action: save)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
                Text(installMode == .newAnimation ? "The .bytes and trick.xml stay separate inside this animation's own folder." : "The original game animation is never edited. Removing this override restores the default.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(16)
        }
    }

    private func frameStepper(_ title: String, _ value: Binding<Int>) -> some View {
        Stepper("\(title): \(value.wrappedValue)", value: value, in: 0...max(0, frames.count - 1))
    }

    private var maxExitFrame: Int {
        guard let move = chainAnimations.first(where: { $0.name == exitAnimation }) else { return 10_000 }
        return max(0, move.endFrame > 0 ? move.endFrame : 10_000)
    }

    private var selectedOverrideMove: TrickPreviewMove? {
        chainAnimations.first { $0.name == overrideTarget }
    }

    private var overrideIsCompatible: Bool {
        guard let target = selectedOverrideMove, !frames.isEmpty else { return false }
        return frames.count > max(target.firstFrame, target.endFrame)
    }

    private var overrideCompatibilityText: String {
        guard let target = selectedOverrideMove else { return "Choose a target animation." }
        let needed = max(target.firstFrame, target.endFrame) + 1
        return overrideIsCompatible ? "Compatible: imported \(frames.count) frames; target needs at least \(needed)." : "Needs at least \(needed) frames; imported file has \(frames.count)."
    }

    private var canSave: Bool {
        guard bytesData != nil, !folderPath.isEmpty else { return false }
        return installMode == .newAnimation ? !xmlName.isEmpty : !overrideTarget.isEmpty && overrideIsCompatible
    }

    private func refreshChainAnimations() {
        chainAnimations = TrickPreviewCatalog(gameDirectory: gameDirectory).loadMoves().sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var xmlName: String {
        var clean = trickName.filter { $0.isLetter || $0.isNumber || $0 == "_" }
        if let first = clean.first, first.isNumber { clean = "Trick_" + clean }
        return clean
    }

    private func beginImport() {
        #if os(macOS)
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.data]; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { load(url) }
        #else
        importing = true
        #endif
    }

    private func receiveBytes(_ result: Result<[URL], Error>) {
        if case .success(let urls) = result, let url = urls.first { load(url) }
        else if case .failure(let error) = result { message = error.localizedDescription }
    }

    private func load(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let catalog = TrickPreviewCatalog(gameDirectory: gameDirectory)
            frames = try catalog.loadFrames(data: data, source: url.lastPathComponent)
            guard !frames.isEmpty, frames.allSatisfy({ $0.points.count == 46 }) else { throw StudioError("Not a valid 46-node Vector animation") }
            bytesData = data; bytesName = url.lastPathComponent
            trickName = url.deletingPathExtension().lastPathComponent.split(separator: "_").map { $0.capitalized }.joined()
            visualName = trickName
            trickDescription = "Custom trick: \(trickName)"
            frame = 0; entry = 0; safeStart = 0; safeEnd = max(0, frames.count - 2); exitFrame = min(1, frames.count - 1)
            rebuildPlayback()
            message = "Valid Vector animation: \(frames.count) frames and 46 nodes per frame."
        } catch { bytesData = nil; frames = []; playback = nil; message = "Import failed: \(error.localizedDescription)" }
    }

    private var previewFrameCount: Int { playback?.frames.count ?? frames.count }

    private func rebuildPlayback(resetFrame: Bool = false) {
        guard !frames.isEmpty else { return }
        do {
            let catalog = TrickPreviewCatalog(gameDirectory: gameDirectory), model = try catalog.loadModel(skins: ["0.xml", "1.xml"])
            var previewFrames = frames
            if chainsToAnotherAnimation,
               let next = chainAnimations.first(where: { $0.name == exitAnimation }),
               next.name != xmlName {
                let nextFrames = try catalog.loadFrames(fileName: next.fileName)
                let sourceEnd = min(max(0, safeEnd), max(0, frames.count - 1))
                let nextStart = min(max(0, exitFrame), max(0, nextFrames.count - 1))
                let sourcePivot = model.pivotPoint(named: pivot, pose: frames[sourceEnd].points)
                let nextPivotName = next.pivotNode.isEmpty ? pivot : next.pivotNode
                let nextPivot = model.pivotPoint(named: nextPivotName, pose: nextFrames[nextStart].points)
                let alignment = CGSize(
                    width: sourcePivot.x - nextPivot.x,
                    height: sourcePivot.y - nextPivot.y
                )
                let alignedNextFrames = nextFrames.dropFirst(nextStart).map { nextFrame in
                    TrickPreviewFrame(points: nextFrame.points.map { point in
                        CGPoint(x: point.x + alignment.width, y: point.y + alignment.height)
                    })
                }
                previewFrames = Array(frames.prefix(sourceEnd + 1)) + alignedNextFrames
            }
            let move = TrickPreviewMove(name: xmlName, fileName: bytesName, firstFrame: 0, endFrame: previewFrames.count - 1, midFrames: 1, loops: false, pivotNode: pivot, isTrick: true, parts: "")
            playback = TrickPreviewPlayback(move: move, model: model, frames: previewFrames, startFrame: 0, pivotIndex: model.nodeIndex(named: pivot), selectedSkins: ["0.xml", "1.xml"], anchorNodeID: nil)
            if resetFrame { frame = 0 }
        } catch { playback = nil; message = "Preview failed: \(error.localizedDescription)" }
    }

    private func togglePlay() {
        playing.toggle(); player?.cancel(); guard playing else { return }
        player = Task { @MainActor in
            while !Task.isCancelled && playing {
                try? await Task.sleep(nanoseconds: 33_000_000)
                frame = frame >= Double(max(0, previewFrameCount - 1)) ? 0 : frame + 1
            }
        }
    }

    private func beginChooseFolder() {
        #if os(macOS)
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url { remember(url) }
        #else
        choosingFolder = true
        #endif
    }

    private func receiveFolder(_ result: Result<[URL], Error>) {
        if case .success(let urls) = result, let url = urls.first { remember(url) }
        else if case .failure(let error) = result { message = error.localizedDescription }
    }

    private func remember(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try url.bookmarkData(options: creationOptions, includingResourceValuesForKeys: nil, relativeTo: nil)
            folderPath = url.path; folderBookmark = data.base64EncodedString(); message = "Custom tricks folder connected."
        } catch { message = "Folder permission failed: \(error.localizedDescription)" }
    }

    private var creationOptions: URL.BookmarkCreationOptions {
        #if os(macOS)
        .withSecurityScope
        #else
        .minimalBookmark
        #endif
    }
    private var resolutionOptions: URL.BookmarkResolutionOptions {
        #if os(macOS)
        .withSecurityScope
        #else
        .withoutUI
        #endif
    }

    private func save() {
        guard let bytesData else { return }
        do {
            let root = try tricksRoot()
            let access = projectTricksDirectory == nil && root.startAccessingSecurityScopedResource()
            defer { if access { root.stopAccessingSecurityScopedResource() } }
            if installMode == .overrideAnimation {
                try saveOverride(bytesData: bytesData, root: root)
                return
            }
            let package = root.appendingPathComponent(xmlName, isDirectory: true)
            let isUpdate = FileManager.default.fileExists(atPath: package.appendingPathComponent("trick.xml").path)
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
            let installedBytesName = xmlName + ".bytes"
            try bytesData.write(to: package.appendingPathComponent(installedBytesName), options: .atomic)
            let element = XMLElement(name: "CustomTrick")
            let requestedExit = exitAnimation.trimmingCharacters(in: .whitespacesAndNewlines)
            let chainedExit = chainsToAnotherAnimation && !requestedExit.isEmpty ? requestedExit : "RunForward"
            ["Name": xmlName, "FileName": installedBytesName, "PivotNode": pivot, "FirstFrame": "0", "EndFrame": "\(frames.count - 1)", "EntryFrame": "\(entry)", "SafeStart": "\(safeStart)", "SafeEnd": "\(safeEnd)", "ExitAnimation": chainedExit, "ExitFrame": "\(exitFrame)", "VisualName": visualName.isEmpty ? xmlName : visualName, "Description": trickDescription.isEmpty ? "Custom trick: \(visualName.isEmpty ? xmlName : visualName)" : trickDescription, "Image": cardImage, "Rarity": "\(cardRarity)", "Price": "\(cardPrice)", "ShopEnabled": "1", "CardType": "Stunts", "EffectID": "Stunts", "Slot": "Stunts", "Group": "CustomTricks", "SetupMin": "0", "SetupMax": "99", "Weight": "1250", "WeightForUse": "1", "MaxLevel": "5"].forEach {
                element.addAttribute(XMLNode.attribute(withName: $0.key, stringValue: $0.value) as! XMLNode)
            }
            // New cards start with a complete, editable upgrade curve. The Shop
            // and Upgrades studios can tune every row later without touching XML.
            for (index, cards, points) in [(1, 2, 100), (2, 3, 120), (3, 5, 145), (4, 7, 175), (5, 9, 210)] {
                let level = XMLElement(name: "Level")
                level.addAttribute(XMLNode.attribute(withName: "Number", stringValue: "\(index)") as! XMLNode)
                level.addAttribute(XMLNode.attribute(withName: "Cards", stringValue: "\(cards)") as! XMLNode)
                level.addAttribute(XMLNode.attribute(withName: "Points", stringValue: "\(points)") as! XMLNode)
                element.addChild(level)
            }
            let document = XMLDocument(rootElement: element); document.version = "1.0"; document.characterEncoding = "utf-8"
            try document.xmlData(options: [.nodePrettyPrint]).write(to: package.appendingPathComponent("trick.xml"), options: .atomic)
            message = isUpdate ? "Updated \(xmlName) in place." : "Saved \(xmlName): separate .bytes and trick.xml files."; onStatus(message)
        } catch { message = "Save failed: \(error.localizedDescription)" }
    }

    private var availableCardImages: [String] {
        guard !folderPath.isEmpty else { return [] }
        let textures = URL(fileURLWithPath: folderPath).deletingLastPathComponent().appendingPathComponent("custom_textures", isDirectory: true)
        let supported = Set(["png", "jpg", "jpeg", "bmp", "gif", "tif", "tiff", "webp"])
        guard let files = try? FileManager.default.contentsOfDirectory(at: textures, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return [] }
        return files.filter { supported.contains($0.pathExtension.lowercased()) }.map(\.lastPathComponent).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func saveOverride(bytesData: Data, root: URL) throws {
        guard let target = selectedOverrideMove, overrideIsCompatible else { throw StudioError(overrideCompatibilityText) }
        let overrides = root.appendingPathComponent("animation_overrides", isDirectory: true)
        let package = overrides.appendingPathComponent(target.name, isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let binaryName = "replacement.bytes"
        try bytesData.write(to: package.appendingPathComponent(binaryName), options: .atomic)
        let element = XMLElement(name: "AnimationOverride")
        ["Target": target.name, "FileName": binaryName, "Enabled": "1"].forEach {
            element.addAttribute(XMLNode.attribute(withName: $0.key, stringValue: $0.value) as! XMLNode)
        }
        let document = XMLDocument(rootElement: element); document.version = "1.0"; document.characterEncoding = "utf-8"
        try document.xmlData(options: [.nodePrettyPrint]).write(to: package.appendingPathComponent("override.xml"), options: .atomic)
        message = "Installed override for \(target.name). Restart the run to apply it."
        onStatus(message)
    }

    private func restoreDefault() {
        do {
            let root = try tricksRoot()
            let access = projectTricksDirectory == nil && root.startAccessingSecurityScopedResource()
            defer { if access { root.stopAccessingSecurityScopedResource() } }
            let package = root.appendingPathComponent("animation_overrides", isDirectory: true).appendingPathComponent(overrideTarget, isDirectory: true)
            if FileManager.default.fileExists(atPath: package.path) { try FileManager.default.removeItem(at: package) }
            message = "Restored \(overrideTarget) to default. Restart the run to apply it."
            onStatus(message)
        } catch { message = "Restore failed: \(error.localizedDescription)" }
    }

    private func tricksRoot() throws -> URL {
        if let projectTricksDirectory {
            try FileManager.default.createDirectory(at: projectTricksDirectory, withIntermediateDirectories: true)
            return projectTricksDirectory
        }
        var stale = false
        guard let saved = Data(base64Encoded: folderBookmark) else { throw StudioError("Choose the custom_tricks folder again") }
        let root = try URL(resolvingBookmarkData: saved, options: resolutionOptions, relativeTo: nil, bookmarkDataIsStale: &stale)
        return root
    }
}

private enum AnimationInstallMode: Hashable {
    case newAnimation
    case overrideAnimation
}

private struct StudioError: LocalizedError {
    let text: String
    init(_ text: String) { self.text = text }
    var errorDescription: String? { text }
}
