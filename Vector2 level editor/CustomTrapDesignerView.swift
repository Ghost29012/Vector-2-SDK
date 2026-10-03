import AppKit
import SwiftUI

struct CustomTrapDesignerView: View {
    let projectRoot: URL
    let onStatus: (String) -> Void
    @State private var traps: [CustomTrapDefinition] = []
    @State private var selectedID = ""
    @State private var stableIDDraft = ""
    @State private var confirmingDelete = false
    @State private var previewVisualState = "Regular"

    private var selectedIndex: Int? { traps.firstIndex { $0.id == selectedID } }
    private var textureFiles: [URL] {
        let root = projectRoot.appendingPathComponent("custom_textures")
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        return e.compactMap { $0 as? URL }.filter { ["png", "jpg", "jpeg", "gif"].contains($0.pathExtension.lowercased()) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    private var audioFiles: [URL] {
        let root = projectRoot.appendingPathComponent("custom_audio")
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        return e.compactMap { $0 as? URL }.filter { ["wav", "mp3", "ogg", "aif", "aiff", "m4a"].contains($0.pathExtension.lowercased()) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                list.frame(minWidth: 250, idealWidth: 285, maxWidth: 340)
                if let index = selectedIndex { editor($traps[index]) }
                else { ContentUnavailableView("No custom traps", systemImage: "bolt.trianglebadge.exclamationmark", description: Text("Create a trap, then choose its image, hit area, and behavior.")).frame(maxWidth: .infinity, maxHeight: .infinity) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear(perform: reload)
        .alert("Delete custom trap?", isPresented: $confirmingDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive, action: deleteSelected)
        } message: {
            Text("Deletes the trap package and compiled library. Use Install Changes to remove its old copy from the game too.")
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "bolt.trianglebadge.exclamationmark.fill").font(.system(size: 23, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 48, height: 48).background(Color.orange.gradient, in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 2) { Text("Trap Designer").font(.system(size: 27, weight: .bold)); Text("Create traps that can be placed in any room.").foregroundStyle(.secondary) }
            Spacer()
            Button("Open Folder") { NSWorkspace.shared.open(projectRoot.appendingPathComponent("custom_traps")) }
            Button("New Trap", systemImage: "plus", action: add).buttonStyle(.borderedProminent)
        }.padding(.horizontal, 24).padding(.vertical, 16).background(Color(nsColor: .controlBackgroundColor).opacity(0.94))
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(traps) { trap in
                    Button { selectedID = trap.id; stableIDDraft = trap.id } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "bolt.fill").foregroundStyle(.orange).frame(width: 38, height: 38).background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                            VStack(alignment: .leading, spacing: 2) { Text(trap.name).fontWeight(.semibold).lineLimit(1); Text("Custom trap").font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                        }.padding(9).contentShape(Rectangle())
                    }.buttonStyle(.plain).background(selectedID == trap.id ? Color.orange.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 11))
                }
            }.padding(12)
        }.background(Color(nsColor: .controlBackgroundColor).opacity(0.72))
    }

    private func editor(_ trap: Binding<CustomTrapDefinition>) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 22) {
                    preview(trap)
                    VStack(alignment: .leading, spacing: 12) {
                        TextField("Trap name", text: trap.name).font(.title2.bold()).textFieldStyle(.roundedBorder)
                        labeled("Stable ID") {
                            TextField("spike_wall", text: $stableIDDraft).textFieldStyle(.roundedBorder)
                            Text("The ID changes when you choose Save & Compile, not while you type.")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        labeled("Mounted on") { Picker("", selection: trap.mount) { ForEach(CustomTrapDefinition.Mount.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).labelsHidden() }
                        labeled("Artwork") { Picker("", selection: trap.artwork) { Text("No artwork").tag(""); ForEach(textureFiles, id: \.path) { Text($0.lastPathComponent).tag($0.lastPathComponent) } }.labelsHidden() }
                        Text("Choose artwork from Custom Textures. The red and orange boxes mark the trap's gameplay areas.").font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(alignment: .top, spacing: 14) {
                    panel("Behavior", "The trap owns these triggers; no stock trap is hidden underneath.") {
                        Picker("On contact", selection: trap.impact) {
                            ForEach(CustomTrapDefinition.Impact.allCases) { Text($0.rawValue).tag($0) }
                        }.pickerStyle(.segmented)
                        if trap.wrappedValue.impact == .armor {
                            Picker("Damages", selection: trap.armorSlot) {
                                ForEach(CustomTrapDefinition.ArmorSlot.allCases) { Text($0.rawValue).tag($0) }
                            }.pickerStyle(.segmented)
                            Stepper("Charges to remove: \(trap.wrappedValue.damageAmount)", value: trap.damageAmount, in: 1...12)
                            Text("Choose how many of that equipped armour piece's 12 native charges this hit removes. The normal gadget HUD shows the result.").font(.caption).foregroundStyle(.secondary)
                        }
                        Toggle("Only active while player is nearby", isOn: trap.enabledByArea)
                        Text(impactExplanation(trap.wrappedValue)).font(.caption).foregroundStyle(.secondary)
                    }
                    panel("Artwork size", "Displayed around the trap origin.") {
                        Stepper("Width: \(trap.wrappedValue.width)", value: trap.width, in: 24...1200, step: 10)
                        Stepper("Height: \(trap.wrappedValue.height)", value: trap.height, in: 24...1200, step: 10)
                    }
                }
                panel("Visual states", "Assign imported artwork to the four states Vector's trap flow actually uses. Empty states reuse Regular.") {
                    Picker("Preview", selection: $previewVisualState) {
                        ForEach(["Regular", "Charge up", "Disabled", "Player collision"], id: \.self) { Text($0).tag($0) }
                    }.pickerStyle(.segmented)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 12)], spacing: 12) {
                        statePicker("Regular", selection: trap.artwork)
                        statePicker("Charge up", selection: trap.chargeArtwork)
                        statePicker("Disabled", selection: trap.disabledArtwork)
                        statePicker("Player collision", selection: trap.hitArtwork)
                    }
                    HStack {
                        Stepper("Charge: \(trap.wrappedValue.chargeFrames) frames", value: trap.chargeFrames, in: 0...600)
                        Stepper("Hit: \(trap.wrappedValue.hitFrames) frames", value: trap.hitFrames, in: 0...600)
                    }
                    Text("Charge plays when the player enters the activation area; collision plays on contact; Disabled is used when the trap leaves its active area or is hidden.").font(.caption).foregroundStyle(.secondary)
                }
                panel("Sound states", "Each sound is compiled into the trap's real Vector trigger actions.") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 12)], spacing: 12) {
                        soundPicker("Regular", selection: trap.idleSound)
                        soundPicker("Charge up", selection: trap.chargeSound)
                        soundPicker("Player collision", selection: trap.hitSound)
                        soundPicker("Disabled", selection: trap.disabledSound)
                    }
                    HStack { Text("Volume"); Slider(value: trap.soundVolume, in: 0...1); Text(trap.wrappedValue.soundVolume, format: .number.precision(.fractionLength(2))).monospacedDigit() }
                    if audioFiles.isEmpty { Label("Import sounds from Audio first.", systemImage: "waveform.badge.exclamationmark").font(.caption).foregroundStyle(.orange) }
                }
                HStack(alignment: .top, spacing: 14) {
                    geometryPanel("Danger area", tint: .red, x: trap.dangerX, y: trap.dangerY, width: trap.dangerWidth, height: trap.dangerHeight)
                    geometryPanel("Activation area", tint: .orange, x: trap.activationX, y: trap.activationY, width: trap.activationWidth, height: trap.activationHeight)
                        .opacity(trap.wrappedValue.enabledByArea ? 1 : 0.45)
                        .disabled(!trap.wrappedValue.enabledByArea)
                }
                HStack {
                    Label("Compiles to \(trap.wrappedValue.libraryFilename) / \(trap.wrappedValue.objectName)", systemImage: "checkmark.shield").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Delete", role: .destructive) { confirmingDelete = true }
                    Button("Save & Compile") { save(trap.wrappedValue) }.buttonStyle(.borderedProminent).controlSize(.large)
                }
            }.frame(maxWidth: 1000).padding(24).frame(maxWidth: .infinity)
                .onChange(of: trap.wrappedValue.artwork) { oldValue, newValue in
                    guard oldValue != newValue else { return }
                    fitArtwork(newValue, trap: trap)
                }
        }
    }

    private func preview(_ trap: Binding<CustomTrapDefinition>) -> some View {
        let scale = 0.43
        let origin = CGPoint(x: 235, y: 270)
        return ZStack {
            RoundedRectangle(cornerRadius: 20).fill(LinearGradient(colors: [.black.opacity(0.9), .orange.opacity(0.12)], startPoint: .top, endPoint: .bottom))
            Path { path in
                stride(from: 20.0, through: 450.0, by: 40).forEach { x in path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: 320)) }
                stride(from: 20.0, through: 300.0, by: 40).forEach { y in path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: 470, y: y)) }
            }.stroke(Color.white.opacity(0.08), lineWidth: 1)
            if let file = textureFiles.first(where: { $0.lastPathComponent == previewArtwork(trap.wrappedValue) }), let image = NSImage(contentsOf: file) {
                let artworkWidth = CGFloat(trap.wrappedValue.width) * scale
                let artworkHeight = CGFloat(trap.wrappedValue.height) * scale
                if file.pathExtension.lowercased() == "gif" {
                    TrapArtworkPreview(image: image, animated: true)
                        .frame(width: artworkWidth, height: artworkHeight)
                        .clipped()
                        .position(x: origin.x, y: origin.y - artworkHeight / 2)
                } else {
                    Image(nsImage: image)
                        .resizable()
                        .frame(width: artworkWidth, height: artworkHeight)
                        .clipped()
                        .position(x: origin.x, y: origin.y - artworkHeight / 2)
                }
            } else {
                Image(systemName: "bolt.trianglebadge.exclamationmark.fill").font(.system(size: 58)).foregroundStyle(.orange)
                    .position(x: origin.x, y: origin.y - 42)
            }
            if trap.wrappedValue.enabledByArea {
                TrapRegionOverlay(title: "ActivationArea", kind: .trigger, scale: scale, origin: origin, x: trap.activationX, y: trap.activationY, width: trap.activationWidth, height: trap.activationHeight)
            }
            TrapRegionOverlay(title: "DamageArea", kind: .area, scale: scale, origin: origin, x: trap.dangerX, y: trap.dangerY, width: trap.dangerWidth, height: trap.dangerHeight)
            Circle().fill(.white).frame(width: 7, height: 7).position(origin)
            VStack { Spacer(); HStack { Label(trap.wrappedValue.mount.rawValue, systemImage: "square.bottomhalf.filled"); Spacer(); Text(trap.wrappedValue.impact == .armor ? "\(trap.wrappedValue.armorSlot.rawValue.uppercased()) CHARGES" : trap.wrappedValue.impact.rawValue.uppercased()) }.font(.caption.bold()).foregroundStyle(.white).padding(14) }
        }.frame(width: 470, height: 320).clipped().overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.orange.opacity(0.45)))
    }

    private func impactExplanation(_ trap: CustomTrapDefinition) -> String {
        switch trap.impact {
        case .defeat: return "Entering the red area immediately defeats the player."
        case .armor: return "Entering the red area removes armour; the player is defeated when it reaches zero."
        case .knockback: return "Entering the red area pushes the player away without damaging armour."
        }
    }

    private func previewArtwork(_ trap: CustomTrapDefinition) -> String {
        let selected: String
        switch previewVisualState {
        case "Charge up": selected = trap.chargeArtwork
        case "Disabled": selected = trap.disabledArtwork
        case "Player collision": selected = trap.hitArtwork
        default: selected = trap.artwork
        }
        return selected.isEmpty ? trap.artwork : selected
    }

    private func geometryPanel(_ title: String, tint: Color, x: Binding<Int>, y: Binding<Int>, width: Binding<Int>, height: Binding<Int>) -> some View {
        panel(title, "Exact Vector coordinates shown on the preview and room canvas.") {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 9) {
                GridRow { Text("Position").foregroundStyle(.secondary); Stepper("X: \(x.wrappedValue)", value: x, in: -2000...2000, step: 10); Stepper("Y: \(y.wrappedValue)", value: y, in: -2000...2000, step: 10) }
                GridRow { Text("Size").foregroundStyle(.secondary); Stepper("W: \(width.wrappedValue)", value: width, in: 10...3000, step: 10); Stepper("H: \(height.wrappedValue)", value: height, in: 10...3000, step: 10) }
            }.tint(tint)
        }
    }

    private func statePicker(_ title: String, selection: Binding<String>) -> some View {
        labeled(title) {
            Picker("", selection: selection) {
                Text(title == "Regular" ? "No artwork" : "Reuse Regular").tag("")
                ForEach(textureFiles, id: \.path) { Text($0.lastPathComponent).tag($0.lastPathComponent) }
            }.labelsHidden()
        }
    }

    private func soundPicker(_ title: String, selection: Binding<String>) -> some View {
        labeled(title) {
            Picker("", selection: selection) {
                Text("Silent").tag("")
                ForEach(audioFiles, id: \.path) { Text($0.deletingPathExtension().lastPathComponent).tag($0.deletingPathExtension().lastPathComponent) }
            }.labelsHidden()
        }
    }

    private func panel<Content: View>(_ title: String, _ subtitle: String, @ViewBuilder content: () -> Content) -> some View { VStack(alignment: .leading, spacing: 11) { Text(title).font(.title3.bold()); Text(subtitle).font(.caption).foregroundStyle(.secondary); Divider(); content() }.padding(17).frame(maxWidth: .infinity, alignment: .leading).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 17)).overlay(RoundedRectangle(cornerRadius: 17).stroke(Color.secondary.opacity(0.14))) }
    private func labeled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View { VStack(alignment: .leading, spacing: 5) { Text(title).font(.caption.bold()).foregroundStyle(.secondary); content() }.frame(maxWidth: .infinity, alignment: .leading) }

    private func add() {
        let root = projectRoot.appendingPathComponent("custom_traps", isDirectory: true)
        let existingFolders = Set(((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []).map(\.lastPathComponent))
        let used = Set(traps.map { CustomTrapDefinition.clean($0.id) }).union(existingFolders)
        var number = 1
        while used.contains("trap_\(number)") { number += 1 }
        let id = "trap_\(number)"
        // An unsaved draft has no package yet. Pretending it does made rename
        // cleanup repeatedly target stale trap_12 folders after failed saves.
        let trap = CustomTrapDefinition(id: id, name: "New Trap")
        traps.append(trap)
        selectedID = id
        stableIDDraft = id
    }
    private func fitArtwork(_ artwork: String, trap: Binding<CustomTrapDefinition>) {
        guard let file = textureFiles.first(where: { $0.lastPathComponent == artwork }),
              let image = NSImage(contentsOf: file), image.size.width > 0, image.size.height > 0 else { return }
        let currentHeight = max(24, trap.wrappedValue.height)
        let fittedWidth = Int((CGFloat(currentHeight) * image.size.width / image.size.height).rounded())
        trap.wrappedValue.width = min(1200, max(24, fittedWidth))
    }
    private func reload() {
        traps = CustomTrapDefinition.load(from: projectRoot)
        // The first custom-trap build defaulted every visual to a square. Fix
        // those unsaved drafts from the image itself so designer, canvas and
        // runtime all begin with the same footprint.
        for index in traps.indices where traps[index].width == traps[index].height && !traps[index].artwork.isEmpty {
            guard let file = textureFiles.first(where: { $0.lastPathComponent == traps[index].artwork }),
                  let image = NSImage(contentsOf: file), image.size.width > 0, image.size.height > 0 else { continue }
            let aspect = image.size.width / image.size.height
            if abs(aspect - 1) > 0.05 {
                traps[index].width = min(1200, max(24, Int((CGFloat(traps[index].height) * aspect).rounded())))
            }
        }
        if !traps.contains(where: { $0.id == selectedID }) { selectedID = traps.first?.id ?? "" }
        stableIDDraft = traps.first(where: { $0.id == selectedID })?.id ?? ""
    }
    private func save(_ trap: CustomTrapDefinition) {
        do {
            var updated = trap
            updated.id = stableIDDraft
            _ = try updated.write(to: projectRoot)
            selectedID = CustomTrapDefinition.clean(updated.id)
            reload()
            onStatus("\(updated.name) compiled. Install Changes sends its package and runtime library to Vector 2.")
        } catch { onStatus("Trap could not be saved: \(error.localizedDescription)") }
    }
    private func deleteSelected() {
        guard let index = selectedIndex else { return }
        let trap = traps[index]
        do {
            try trap.delete(from: projectRoot)
            selectedID = ""
            reload()
            onStatus("\(trap.name) deleted. Install Changes removes its old Vector 2 copy.")
        } catch {
            reload()
            onStatus("Trap could not be deleted: \(error.localizedDescription)")
        }
    }
}

private struct TrapArtworkPreview: NSViewRepresentable {
    let image: NSImage
    let animated: Bool

    final class Coordinator {
        let imageView = NSImageView()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let wrapper = NSView()
        wrapper.wantsLayer = true
        wrapper.layer?.masksToBounds = true
        let view = context.coordinator.imageView
        // Match the room canvas/runtime matrix exactly. Proportional fitting
        // made static artwork look smaller than the same trap in the editor.
        view.imageScaling = .scaleAxesIndependently
        view.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
            view.topAnchor.constraint(equalTo: wrapper.topAnchor),
            view.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor)
        ])
        return wrapper
    }

    func updateNSView(_ wrapper: NSView, context: Context) {
        let view = context.coordinator.imageView
        view.image = image
        view.animates = animated
    }
}

private struct TrapRegionOverlay: View {
    let title: String
    let kind: VectorRuntimeRegionBox.Kind
    let scale: CGFloat
    let origin: CGPoint
    @Binding var x: Int
    @Binding var y: Int
    @Binding var width: Int
    @Binding var height: Int
    @State private var dragStartX: Int?
    @State private var dragStartY: Int?

    var body: some View {
        VectorRuntimeRegionBox(title: title, kind: kind)
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(kind == .trigger ? Color(rgbaHex: Vector2RuntimeSettings.triggerOutlineHex) : Color(rgbaHex: Vector2RuntimeSettings.areaOutlineHex))
                    .padding(4)
            }
            .frame(width: CGFloat(width) * scale, height: CGFloat(height) * scale)
            .position(
                x: origin.x + CGFloat(x + width / 2) * scale,
                y: origin.y + CGFloat(y + height / 2) * scale
            )
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if dragStartX == nil { dragStartX = x; dragStartY = y }
                        x = (dragStartX ?? x) + Int((value.translation.width / scale).rounded())
                        y = (dragStartY ?? y) + Int((value.translation.height / scale).rounded())
                    }
                    .onEnded { _ in dragStartX = nil; dragStartY = nil }
            )
            .help("Drag to move this gameplay area. Use the size controls below to resize it precisely.")
    }
}
