//
//  TrickPreviewPickerSheet.swift
//  Vector2 level editor
//

import SwiftUI

struct TrickPreviewPickerSheet: View {
    let selectedNode: LevelNode?
    let gameDirectory: String
    let onPreview: (TrickPreviewPlayback) -> Void
    let onClose: () -> Void

    @State private var catalog = TrickPreviewCatalog()
    @State private var moves: [TrickPreviewMove] = []
    @State private var skins: [TrickPreviewModelSkin] = []
    @State private var selectedMoveName = ""
    @State private var selectedBody = "1.xml"
    @State private var selectedChestArmor = ""
    @State private var selectedHelmet = ""
    @State private var selectedHair = "hair.xml"
    @State private var startEarlierFrames = 5
    @State private var filter = ""

    private var filteredMoves: [TrickPreviewMove] {
        let needle = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return moves }
        return moves.filter { "\($0.name) \($0.fileName) \($0.pivotNode)".lowercased().contains(needle) }
    }

    private var selectedMove: TrickPreviewMove? {
        moves.first { $0.name == selectedMoveName } ?? filteredMoves.first ?? moves.first
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                moveList
                Divider()
                configurationPanel
            }
        }
        .frame(width: 980, height: 660)
        .background(Color.platformWindowBackground)
        .foregroundStyle(Color.primary)
        .onAppear(perform: loadCatalog)
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Trick Preview")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                Text("Pick the Vector 2 trick, skin stack, and start offset. The preview anchors on the selected object.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Close", action: onClose)
        }
        .padding(18)
    }

    private var moveList: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Search tricks", text: $filter)
                .textFieldStyle(.roundedBorder)

            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(filteredMoves) { move in
                        Button {
                            selectedMoveName = move.name
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(move.name)
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(Color.primary)
                                Text("\(move.fileName) - first \(move.firstFrame) - pivot \(move.pivotNode)")
                                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(Color.secondary)
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(selectedMoveName == move.name ? Color.accentColor.opacity(0.16) : Color.platformControlBackground)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(selectedMoveName == move.name ? Color.accentColor : Color.editorHairline, lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    if filteredMoves.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("No tricks loaded")
                                .font(.system(size: 13, weight: .bold))
                            Text("Check Settings > Trick Preview Console, then reopen this sheet to see the resource lookup log.")
                                .font(.system(size: 12))
                                .foregroundStyle(Color.secondary)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.platformControlBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
            .background(Color.platformControlBackground.opacity(0.35))
        }
        .padding(16)
        .frame(width: 330)
    }

    private var configurationPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let selectedMove {
                GroupBox("Selected Trick") {
                    VStack(alignment: .leading, spacing: 8) {
                        keyValue("Name", selectedMove.name)
                        keyValue("Animation", selectedMove.fileName)
                        keyValue("First frame", "\(selectedMove.firstFrame)")
                        keyValue("End frame", selectedMove.endFrame > 0 ? "\(selectedMove.endFrame)" : "file end")
                        keyValue("Pivot", selectedMove.pivotNode)
                        if !selectedMove.parts.isEmpty {
                            keyValue("Parts", selectedMove.parts)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Model Stack") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("0.xml is always loaded first as the skeleton. Pick the visible player model, then optional chest armor, helmet, and hair layers.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Picker("Model", selection: $selectedBody) {
                            ForEach(bodySkins) { skin in
                                Text(skin.displayName).tag(skin.filename)
                            }
                        }
                        Picker("Chest", selection: $selectedChestArmor) {
                            Text("None").tag("")
                            ForEach(chestArmorSkins) { skin in
                                Text(skin.displayName).tag(skin.filename)
                            }
                        }
                        Picker("Helmet", selection: $selectedHelmet) {
                            Text("None").tag("")
                            ForEach(helmetSkins) { skin in
                                Text(skin.displayName).tag(skin.filename)
                            }
                        }
                        Picker("Hair", selection: $selectedHair) {
                            Text("None").tag("")
                            ForEach(hairSkins) { skin in
                                Text(skin.displayName).tag(skin.filename)
                            }
                        }
                    }
                }

                GroupBox("Playback") {
                    Stepper("Start \(startEarlierFrames) frames before trick point", value: $startEarlierFrames, in: 0...30)
                }

                HStack {
                    Button("Show Console") {
                        TrickPreviewDiagnostics.shared.isVisible = true
                    }
                    Spacer()
                    Button("Preview Trick") {
                        preview(move: selectedMove)
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                }
            } else {
                Text("No trick animations found.")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func keyValue(_ key: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(key.uppercased())
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .textSelection(.enabled)
        }
    }

    private func loadCatalog() {
        catalog = TrickPreviewCatalog(gameDirectory: gameDirectory)
        TrickPreviewDiagnostics.shared.clear()
        TrickPreviewDiagnostics.shared.log("opening picker; selected node=\(selectedNode?.name ?? "none")")
        moves = catalog.loadMoves()
        skins = catalog.loadModelSkins()
        selectedBody = preferredBodySkinName()
        selectedChestArmor = skins.contains(where: { $0.filename == "black_armor.xml" }) ? "black_armor.xml" : ""
        selectedHelmet = skins.contains(where: { $0.filename == "black_helmet.xml" }) ? "black_helmet.xml" : ""
        selectedHair = skins.contains(where: { $0.filename == "hair.xml" }) ? "hair.xml" : ""
        selectedMoveName = bestInitialMoveName() ?? moves.first?.name ?? ""
        TrickPreviewDiagnostics.shared.log("catalog loaded moves=\(moves.count) skins=\(skins.count)")
    }

    private func bestInitialMoveName() -> String? {
        guard let selectedNode else { return nil }
        let hints = [
            selectedNode.name,
            selectedNode.metadata.className,
            selectedNode.xml.template,
            selectedNode.xml.variant,
            selectedNode.xml.choice
        ]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for hint in hints {
            if let match = moves.first(where: { $0.name.caseInsensitiveCompare(hint) == .orderedSame }) {
                return match.name
            }
            if let match = moves.first(where: { hint.localizedCaseInsensitiveContains($0.name) || $0.name.localizedCaseInsensitiveContains(hint) }) {
                return match.name
            }
        }
        return nil
    }

    private func preview(move: TrickPreviewMove) {
        do {
            let selectedSkins = ["0.xml", selectedBody, selectedChestArmor, selectedHelmet, selectedHair]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .vector2Uniqued()
            let model = try catalog.loadModel(skins: selectedSkins)
            let frames = try catalog.loadFrames(fileName: move.fileName)
            let pivot = model.nodeIndex(named: move.pivotNode)
            let start = max(0, move.firstFrame - startEarlierFrames)
            TrickPreviewDiagnostics.shared.log("preview move=\(move.name) file=\(move.fileName) frames=\(frames.count) start=\(start) pivot=\(move.pivotNode) index=\(pivot.map(String.init) ?? "missing")")
            TrickPreviewDiagnostics.shared.log("skins=\(selectedSkins.joined(separator: ", ")) nodes=\(model.nodes.count) edges=\(model.edges.count) triangles=\(model.triangles.count)")
            if pivot == nil {
                TrickPreviewDiagnostics.shared.log("warning: pivot node \(move.pivotNode) not found; anchoring to frame origin")
            }
            onPreview(.init(move: move, model: model, frames: frames, startFrame: start, pivotIndex: pivot, selectedSkins: selectedSkins, anchorNodeID: selectedNode?.id))
            onClose()
        } catch {
            TrickPreviewDiagnostics.shared.log("failed preview: \(error.localizedDescription)")
        }
    }

    private var bodySkins: [TrickPreviewModelSkin] {
        skins.filter { skin in
            let name = skin.filename.lowercased()
            return name != "0.xml"
                && !name.contains("hair")
                && !name.contains("helmet")
                && !name.contains("cap")
                && !name.contains("armor")
                && !name.contains("gear")
        }
    }

    private var chestArmorSkins: [TrickPreviewModelSkin] {
        skins.filter { skin in
            let name = skin.filename.lowercased()
            return name.contains("armor") || name.contains("shirt") || name.contains("jacket") || name.contains("shorts") || name.contains("scarf")
        }
    }

    private var helmetSkins: [TrickPreviewModelSkin] {
        skins.filter { skin in
            let name = skin.filename.lowercased()
            return name.contains("helmet") || name.contains("cap")
        }
    }

    private var hairSkins: [TrickPreviewModelSkin] {
        skins.filter { $0.filename.localizedCaseInsensitiveContains("hair") }
    }

    private func preferredBodySkinName() -> String {
        if skins.contains(where: { $0.filename == "1.xml" }) {
            return "1.xml"
        }
        return bodySkins.first?.filename ?? skins.first(where: { $0.filename != "0.xml" })?.filename ?? ""
    }
}
