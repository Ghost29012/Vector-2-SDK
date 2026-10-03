//
//  TrapPlacementPanelView.swift
//  Vector2 level editor
//
//  Compact trap placement and configuration. The creator deals with families,
//  direction and safe gameplay controls; Vector's XML variable names stay in
//  TrapCatalog and Exporter.
//

import SwiftUI

struct TrapPlacementPanel: View {
    @Binding var document: LevelDocument
    @Binding var isPresented: Bool
    let assetCatalog: [TextureCategory]
    let onArmPlacement: (TextureAsset) -> Void
    let onOpenSwarmDesigner: () -> Void
    let onStatus: (String) -> Void

    @State private var selectedFamily = TrapFamily.beam
    @State private var selectedPresetID = TrapCatalog.presets.first?.id ?? ""

    private var familyPresets: [TrapPreset] { TrapCatalog.presets(in: selectedFamily, catalog: assetCatalog) }
    private var selectedPreset: TrapPreset? {
        familyPresets.first { $0.id == selectedPresetID } ?? familyPresets.first
    }
    private var selectedTrap: LevelNode? {
        guard TrapCatalog.isTrap(document.selectedNode) else { return nil }
        return document.selectedNode
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                familyPicker
                    .frame(width: 390)
                Divider()
                presetPicker
                    .frame(maxWidth: .infinity)
                Divider()
                selectedTrapEditor
                    .frame(width: 360)
            }
        }
        .background(Color.editorChromeBackground)
        .onAppear(perform: syncPresetSelection)
        .onChange(of: selectedFamily) { _, _ in
            selectedPresetID = familyPresets.first?.id ?? ""
        }
        .onChange(of: document.selectedNodeID) { _, _ in
            syncPresetSelection()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Label("Traps", systemImage: "bolt.trianglebadge.exclamationmark.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.orange)
            Text("Pick a tested setup, place it, then tune only the controls Vector actually supports.")
                .font(.system(size: 10))
                .foregroundStyle(Color.editorSecondaryText)
            Spacer()
            Label("Variants use Room Layouts", systemImage: "square.3.layers.3d")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.editorSecondaryText)
            Button("Swarm paths", action: onOpenSwarmDesigner)
                .controlSize(.small)
            Button { isPresented = false } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .frame(height: 42)
    }

    private var familyPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("1 · CHOOSE A FAMILY")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color.editorSecondaryText)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 7) {
                ForEach(TrapFamily.allCases) { family in
                    Button {
                        selectedFamily = family
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: family.symbol)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(family.tint)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(family.rawValue).font(.system(size: 10, weight: .bold))
                                Text(family.hint).font(.system(size: 8)).foregroundStyle(Color.editorSecondaryText).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 9).fill(selectedFamily == family ? family.tint.opacity(0.12) : Color.platformControlBackground))
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(selectedFamily == family ? family.tint.opacity(0.8) : Color.editorHairline))
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
    }

    private var presetPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("2 · CHOOSE A SETUP")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color.editorSecondaryText)
            // A vertical adaptive grid works with an ordinary mouse wheel as
            // well as a trackpad. The old horizontal strip technically
            // scrolled, but gave mouse users no discoverable way to reach the
            // final beam/run presets.
            ScrollView(.vertical, showsIndicators: true) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 112), spacing: 8)], spacing: 8) {
                    ForEach(familyPresets) { preset in
                        presetCard(preset)
                    }
                }
                .padding(.trailing, 4)
            }
            HStack {
                Text("Click the canvas to place this trap.")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.editorSecondaryText)
                Spacer()
                Button {
                    armSelectedPreset()
                } label: {
                    Label("Place \(selectedPreset?.title ?? "trap")", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(selectedPreset == nil)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
    }

    private func presetCard(_ preset: TrapPreset) -> some View {
        let selected = selectedPreset?.id == preset.id
        return Button {
            selectedPresetID = preset.id
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                Image(systemName: preset.family.symbol)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(preset.family.tint)
                Spacer(minLength: 0)
                Text(preset.title)
                    .font(.system(size: 10, weight: .bold))
                    .lineLimit(1)
                Text(preset.subtitle)
                    .font(.system(size: 8))
                    .foregroundStyle(Color.editorSecondaryText)
                    .lineLimit(2)
            }
            .padding(9)
            .frame(maxWidth: .infinity, minHeight: 72, maxHeight: 72, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(selected ? preset.family.tint.opacity(0.12) : Color.platformControlBackground))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? preset.family.tint : Color.editorHairline, lineWidth: selected ? 1.5 : 1))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var selectedTrapEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("3 · TUNE THE SELECTED TRAP")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color.editorSecondaryText)
            if let trap = selectedTrap {
                HStack {
                    Image(systemName: TrapCatalog.preset(for: trap, catalog: assetCatalog)?.family.symbol ?? "bolt.fill")
                        .foregroundStyle(TrapCatalog.preset(for: trap, catalog: assetCatalog)?.family.tint ?? .orange)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(TrapCatalog.preset(for: trap, catalog: assetCatalog)?.title ?? trap.name).font(.system(size: 11, weight: .bold))
                        Text(layoutLabel(for: trap)).font(.system(size: 8)).foregroundStyle(Color.editorSecondaryText)
                    }
                }
                ScrollView {
                    VStack(spacing: 7) {
                        toggleRow("Lethal", key: "isDeadly", node: trap)
                        if TrapCatalog.supports("EnableArea", node: trap) {
                            toggleRow("Trigger nearby", key: "EnableArea", node: trap)
                        }
                        if TrapCatalog.supports("ToFly", node: trap) {
                            toggleRow("Launch player", key: "ToFly", node: trap)
                        }
                        if TrapCatalog.supports("GlobalTimer", node: trap) {
                            stepperRow("Cycle delay", key: "GlobalTimer", node: trap, range: 0...600, step: 10, suffix: " frames")
                        }
                        if TrapCatalog.supports("LaserReachDistance", node: trap) {
                            stepperRow("Reach", key: "LaserReachDistance", node: trap, range: 10...2000, step: 10, suffix: "")
                        }
                        if TrapCatalog.supports("Type", node: trap) {
                            Picker("Height", selection: stringBinding("Type")) {
                                Text("Low").tag("Low")
                                Text("Medium").tag("Medium")
                                Text("High").tag("High")
                            }
                            .pickerStyle(.segmented)
                            .controlSize(.small)
                        }
                    }
                }
            } else {
                ContentUnavailableView(
                    "Select a trap",
                    systemImage: "cursorarrow.click.2",
                    description: Text("Place one or select an existing trap to see its safe controls and live canvas guides.")
                )
                .controlSize(.small)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
    }

    private func toggleRow(_ title: String, key: String, node: LevelNode) -> some View {
        Toggle(title, isOn: Binding(
            get: { TrapCatalog.value(key, node: document.selectedNode ?? node) != "0" },
            set: { document.updateTrapOverride(key, value: $0 ? "1" : "0") }
        ))
        .toggleStyle(.switch)
        .controlSize(.mini)
        .font(.system(size: 10, weight: .medium))
    }

    private func stepperRow(_ title: String, key: String, node: LevelNode, range: ClosedRange<Int>, step: Int, suffix: String) -> some View {
        let current = Int(TrapCatalog.value(key, node: document.selectedNode ?? node)) ?? range.lowerBound
        return HStack {
            Text(title).font(.system(size: 10, weight: .medium))
            Spacer()
            Text("\(current)\(suffix)").font(.system(size: 9)).foregroundStyle(Color.editorSecondaryText)
            Stepper("", value: Binding(
                get: { Int(TrapCatalog.value(key, node: document.selectedNode ?? node)) ?? range.lowerBound },
                set: { document.updateTrapOverride(key, value: String($0)) }
            ), in: range, step: step)
            .labelsHidden()
            .controlSize(.mini)
        }
    }

    private func stringBinding(_ key: String) -> Binding<String> {
        Binding(
            get: {
                guard let node = document.selectedNode else { return "" }
                return TrapCatalog.value(key, node: node)
            },
            set: { document.updateTrapOverride(key, value: $0) }
        )
    }

    private func armSelectedPreset() {
        guard let preset = selectedPreset else { return }
        guard let asset = TrapCatalog.asset(for: preset, in: assetCatalog) else {
            onStatus("Couldn’t find \(preset.objectName) in the connected Vector 2 trap library")
            return
        }
        onArmPlacement(asset)
        onStatus("\(preset.title) armed. Click the canvas to place it.")
    }

    private func syncPresetSelection() {
        guard let preset = TrapCatalog.preset(for: document.selectedNode, catalog: assetCatalog) else { return }
        selectedFamily = preset.family
        selectedPresetID = preset.id
    }

    private func layoutLabel(for node: LevelNode) -> String {
        guard !node.xml.variant.isEmpty else { return "Shared by every room layout" }
        return "Room layout: \(RoomLayoutKey(section: RoomLayoutSection.matching(choice: node.xml.choice) ?? .middle, variant: node.xml.variant).displayName)"
    }
}
