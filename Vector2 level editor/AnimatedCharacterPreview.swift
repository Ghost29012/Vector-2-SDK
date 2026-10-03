import SwiftUI

/// One shared character viewer for every project tool. This is the same model
/// and animation pipeline used by the room Player/AI designers, so the preview
struct AnimatedCharacterPreview: View {
    let projectRoot: URL
    let modelReferences: [String]
    var includesDefaultBody = false
    var accent: Color = .blue

    @AppStorage("vector2GameDirectory") private var gameDirectory = ""
    @State private var moves: [TrickPreviewMove] = []
    @State private var selectedMove = ""
    @State private var playback: TrickPreviewPlayback?
    @State private var error = ""
    @State private var zoom: CGFloat = 3.5

    private var previewMoves: [TrickPreviewMove] {
        let preferred = ["Swarm Idle", "RunForward", "DivingKong", "Kong"]
        var result: [TrickPreviewMove] = []
        for hint in preferred {
            if let move = moves.first(where: { matches($0, hint) }), !result.contains(where: { $0.id == move.id }) { result.append(move) }
        }
        return result.isEmpty ? Array(moves.prefix(20)) : result
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Label("Animated preview", systemImage: "figure.run")
                    .font(.headline)
                Spacer()
                Picker("Animation", selection: $selectedMove) {
                    ForEach(previewMoves) { Text(displayName($0)).tag($0.name) }
                }
                .labelsHidden()
                .frame(maxWidth: 190)
            }

            GeometryReader { geometry in
                ZStack {
                    RoundedRectangle(cornerRadius: 18)
                        .fill(LinearGradient(colors: [.black.opacity(0.96), accent.opacity(0.16)], startPoint: .top, endPoint: .bottom))
                    if let playback {
                        TrickPreviewOverlay(
                            playback: playback,
                            anchor: CGPoint(x: geometry.size.width / 2, y: geometry.size.height * 0.76),
                            zoom: zoom,
                            unitsPerCanvasPoint: 3,
                            showsDebugLabel: false
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                    } else {
                        VStack(spacing: 8) {
                            Image(systemName: "figure.stand").font(.system(size: 42)).foregroundStyle(accent)
                            Text(error.isEmpty ? "Loading model…" : error).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }.padding()
                    }
                    VStack {
                        Spacer()
                        HStack(spacing: 8) {
                            Button { zoom = max(0.75, zoom - 0.5) } label: { Image(systemName: "minus.magnifyingglass") }
                            Slider(value: $zoom, in: 0.75...8).frame(width: 110)
                            Button { zoom = min(8, zoom + 0.5) } label: { Image(systemName: "plus.magnifyingglass") }
                        }
                        .buttonStyle(.bordered)
                        .padding(8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, 10)
                    }
                }
            }
            .frame(minHeight: 260)
        }
        .onAppear(perform: load)
        .onChange(of: selectedMove) { _, _ in rebuild() }
        .onChange(of: modelReferences) { _, _ in rebuild() }
        .onChange(of: includesDefaultBody) { _, _ in rebuild() }
    }

    private func load() {
        var catalog = TrickPreviewCatalog(gameDirectory: gameDirectory)
        catalog.customModelRoots = [projectRoot.appendingPathComponent("custom_models")]
        moves = catalog.loadMoves()
        selectedMove = moves.first(where: { $0.fileName.localizedCaseInsensitiveContains("cs_swarm_idle") })?.name
            ?? moves.first(where: { matches($0, "Swarm Idle") })?.name
            ?? moves.first(where: { matches($0, "RunForward") })?.name
            ?? moves.first?.name ?? ""
        rebuild()
    }

    private func rebuild() {
        guard let move = moves.first(where: { $0.name == selectedMove }) else {
            playback = nil; error = "No Vector animations were found. Choose the Unity project in Editor Settings."
            return
        }
        var catalog = TrickPreviewCatalog(gameDirectory: gameDirectory)
        catalog.customModelRoots = [projectRoot.appendingPathComponent("custom_models")]
        let stack = PlayerPreviewPolicy.skinStack(
            modelReferences: modelReferences,
            includesDefaultBody: includesDefaultBody || modelReferences.isEmpty
        )
        do {
            let model = try catalog.loadModel(skins: stack)
            let frames = try catalog.loadFrames(fileName: move.fileName)
            playback = TrickPreviewPlayback(move: move, model: model, frames: frames, startFrame: max(0, move.firstFrame), pivotIndex: model.nodeIndex(named: move.pivotNode), selectedSkins: stack, anchorNodeID: nil)
            error = ""
        } catch {
            playback = nil; self.error = error.localizedDescription
        }
    }

    private func matches(_ move: TrickPreviewMove, _ hint: String) -> Bool {
        let compactHint = hint.replacingOccurrences(of: " ", with: "")
        return move.name.replacingOccurrences(of: " ", with: "").localizedCaseInsensitiveContains(compactHint)
            || move.fileName.replacingOccurrences(of: "_", with: "").localizedCaseInsensitiveContains(compactHint)
    }

    private func displayName(_ move: TrickPreviewMove) -> String {
        if move.fileName.localizedCaseInsensitiveContains("cs_swarm_idle") { return "Swarm Idle" }
        if matches(move, "RunForward") { return "Run Forward" }
        if matches(move, "DivingKong") { return "Diving Kong" }
        return move.name
    }
}
