import SwiftUI
import Foundation
import Combine

struct DynamicStudioView: View {
    @Binding var document: LevelDocument
    @Binding var selectedTool: EditorTool
    let activePlacementAsset: TextureAsset?
    let fallbackPlacementAsset: TextureAsset?
    @Bindable var camera: CanvasCameraState
    let onDeleteSelection: () -> Void
    let onLiveEditBegan: () -> Void
    let onLiveEditEnded: () -> Void

    @State private var transformName = "NewTransform"
    @State private var currentFrame = 0
    @State private var totalFrames = 300
    @State private var zoom: Double = 1
    @State private var customEase = false
    @State private var movementMode: DynamicPathMode = .bezier
    @State private var movementQuarter: DynamicSinQuarter = .twoQuarters
    @State private var sizeMode: DynamicPathMode = .bezier
    @State private var sizeQuarter: DynamicSinQuarter = .twoQuarters
    @State private var rotationMode: DynamicRotationMode = .linear
    @State private var onionSkin = false
    @State private var scrubPreview = false
    @State private var isPreviewing = false
    @State private var selectedTriggerIDString = ""
    @State private var previewOriginalTransform: LevelNode.Transform?
    @State private var previewTargetID: LevelNode.ID?
	@State private var previewHierarchyTemplate: LevelNode?
    @State private var scrubOriginalTransform: LevelNode.Transform?
    @State private var cachedDynamicXML = ""
    @State private var livePreviewTransforms: [LevelNode.ID: LevelNode.Transform] = [:]
    @State private var showOutputXML = false
    @State private var timelineDockWidth: CGFloat = 1160
    @State private var timelineDockHeight: CGFloat = 410
    @State private var resizeStartSize: CGSize?
    @State private var selectedKeyframeIDs: Set<DynamicStudioKeyframe.ID> = []
    @State private var selectedSequenceIndex = 0
    @State private var pinnedAnimationTargetID: LevelNode.ID?
    private struct ImportedPreviewTrack {
        let nodeID: LevelNode.ID
        let sourceTransform: LevelNode.Transform
        let timeline: DynamicStudioImportedTimeline
    }
    @State private var importedPreviewTracks: [ImportedPreviewTrack] = []
    @State private var groupedImportedPreviewTracks: [LevelNode.ID: [ImportedPreviewTrack]] = [:]
    @State private var primaryImportedTimeline: DynamicStudioImportedTimeline?
    @State private var cachedSelectedNodes: [LevelNode] = []
    @State private var cachedAnimationTargets: [LevelNode] = []
    @State private var cachedTriggerNodes: [LevelNode] = []
    @State private var cachedImportedSequenceOptions: [ImportedSequenceOption] = []
    @State private var keyframes: [DynamicStudioKeyframe] = [
        DynamicStudioKeyframe(frame: 0, x: 0, y: 0, width: 72, height: 72, rotation: 0)
    ]

    private var selectedNodes: [LevelNode] {
        cachedSelectedNodes
    }

    private var animationTargets: [LevelNode] {
        cachedAnimationTargets
    }

    private func resolvedAnimationTargets(from selectedNodes: [LevelNode]) -> [LevelNode] {
        let selectedIDs = Set(selectedNodes.map(\.id))
        guard !selectedIDs.isEmpty else { return [] }
        var seen: Set<LevelNode.ID> = []
        var related: [LevelNode] = []

        func isSpatialDynamic(_ node: LevelNode) -> Bool {
            guard node.kind != .trigger, node.transform != nil else { return false }
            let xml = node.metadata.dynamicXML
            return xml.contains("<MoveInterval")
                || xml.contains("<RotationInterval")
                || xml.contains("<SizeInterval")
        }

        // One traversal finds Dynamic ancestors of the selection. The previous
        // implementation flattened the full room and then recursively searched
        // the tree again for every candidate, turning each preview frame into an
        // O(n squared) scan on large imported rooms.
        @discardableResult
        func collectSelectedBranches(_ node: LevelNode) -> Bool {
            var containsSelection = selectedIDs.contains(node.id)
            for child in node.children where collectSelectedBranches(child) {
                containsSelection = true
            }
            if containsSelection, isSpatialDynamic(node), seen.insert(node.id).inserted {
                related.append(node)
            }
            return containsSelection
        }
        collectSelectedBranches(document.root)

        // Descendant Dynamics are cheap to collect from the handful of selected
        // assembly roots and cover nested manipulator sequences.
        for selected in selectedNodes {
            for node in selected.allDescendantsIncludingSelf()
            where isSpatialDynamic(node) && seen.insert(node.id).inserted {
                related.append(node)
            }
        }
        return related
    }

    private struct ImportedSequenceMember: Hashable {
        let nodeID: LevelNode.ID
        let transformationName: String
    }

    private struct ImportedSequenceOption: Identifiable {
        let id: String
        let displayName: String
        let members: [ImportedSequenceMember]
        let isRuntimeSync: Bool
        var nodeID: LevelNode.ID { members[0].nodeID }
        var transformationName: String { members[0].transformationName }
    }

    private var importedSequenceOptions: [ImportedSequenceOption] {
        cachedImportedSequenceOptions
    }

    private func buildImportedSequenceOptions() -> [ImportedSequenceOption] {
        let individual = animationTargets.flatMap { target in
            DynamicStudioImportedTimeline.transformationNames(in: target.metadata.dynamicXML).map {
                ImportedSequenceOption(
                    id: "\(target.id.uuidString)|\($0)",
                    displayName: "\(target.name): \($0)",
                    members: [.init(nodeID: target.id, transformationName: $0)],
                    isRuntimeSync: false
                )
            }
        }
        let memberByName = Dictionary(
            individual.flatMap(\.members).map { ($0.transformationName, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var synchronized: [ImportedSequenceOption] = []
        for trigger in triggerNodes {
            let xml = trigger.metadata.sourceContentXML
            guard !xml.isEmpty,
                  let parsed = try? XMLDocument(xmlString: "<Root>\(xml)</Root>") else { continue }
            let choices = (try? parsed.nodes(forXPath: ".//Choose[@Order='Sync']")) ?? []
            for (index, choice) in choices.enumerated() {
                guard let element = choice as? XMLElement else { continue }
                let names = element.elements(forName: "Transform").compactMap {
                    $0.attribute(forName: "Name")?.stringValue
                }
                let members = names.compactMap { memberByName[$0] }
                guard !members.isEmpty else { continue }
                synchronized.append(.init(
                    id: "sync|\(trigger.id.uuidString)|\(index)",
                    displayName: "\(trigger.name) (runtime sync)",
                    members: members,
                    isRuntimeSync: true
                ))
            }
        }
        return synchronized + individual
    }

    private var presentedSequenceOptions: [ImportedSequenceOption] {
        let runtime = importedSequenceOptions.filter(\.isRuntimeSync)
        return runtime.isEmpty ? importedSequenceOptions : runtime
    }

    private var activeSequenceOption: ImportedSequenceOption? {
        guard !presentedSequenceOptions.isEmpty else { return nil }
        return presentedSequenceOptions[min(max(0, selectedSequenceIndex), presentedSequenceOptions.count - 1)]
    }

    private var activeSequenceIndex: Int {
        guard !presentedSequenceOptions.isEmpty else { return 0 }
        return min(max(0, selectedSequenceIndex), presentedSequenceOptions.count - 1)
    }

    private func selectSequence(offset: Int) {
        let options = presentedSequenceOptions
        guard !options.isEmpty else { return }
        stopPreview(restore: true)
        stopScrubPreview(restore: true)
        let next = (activeSequenceIndex + offset + options.count) % options.count
        selectedSequenceIndex = next
    }

    private var animationTarget: LevelNode? {
        if let activeSequenceOption,
           let selected = animationTargets.first(where: { $0.id == activeSequenceOption.nodeID }) {
            return selected
        }
        let eligible = animationTargets.isEmpty
            ? selectedNodes.filter { $0.kind != .trigger }
            : animationTargets
        let selectedIDs = document.selectedNodeIDs
        guard let preferred = EditorSelectionPolicy.retainedTargetID(
            current: pinnedAnimationTargetID,
            primary: document.selectedNodeID,
            selected: selectedIDs,
            eligible: eligible.map(\.id)
        ) else { return nil }
        return eligible.first { $0.id == preferred }
    }

    private var triggerNodes: [LevelNode] {
        cachedTriggerNodes
    }

    private func rebuildSceneCaches() {
        let selected = document.selectedNodes.filter { $0.transform != nil }
        cachedSelectedNodes = selected
        cachedAnimationTargets = resolvedAnimationTargets(from: selected)
        cachedTriggerNodes = flattenedNodes(in: document.root).filter { $0.kind == .trigger }
        cachedImportedSequenceOptions = buildImportedSequenceOptions()
    }

    private var onionCanvasTransforms: [LevelNode.Transform] {
        guard onionSkin, let target = animationTarget else { return [] }
        return keyframes.map {
            document.root.canvasTransform(
                for: target.id,
                localTransform: .init(x: $0.x, y: $0.y, width: $0.width, height: $0.height, rotation: $0.rotation)
            )
        }
    }

    private var outputDisplayXML: String {
        guard let option = activeSequenceOption, option.isRuntimeSync else {
            return cachedDynamicXML
        }
        var targets: [String] = []
        for member in option.members {
            guard let target = animationTargets.first(where: { $0.id == member.nodeID }) else { continue }
            let raw = target.metadata.dynamicXML
            let wrapped = raw.hasPrefix("<Dynamic") ? "<Root>\(raw)</Root>" : "<Root><Dynamic>\(raw)</Dynamic></Root>"
            guard let parsed = try? XMLDocument(xmlString: wrapped),
                  let dynamic = parsed.rootElement()?.elements(forName: "Dynamic").first,
                  let transformation = dynamic.elements(forName: "Transformation").first(where: {
                    $0.attribute(forName: "Name")?.stringValue == member.transformationName
                  }) else { continue }
            targets.append("""
              <Target Object="\(escapeXML(target.name))">
            \(transformation.xmlString(options: [.nodePrettyPrint]))
              </Target>
            """)
        }
        guard !targets.isEmpty else { return cachedDynamicXML }
        return """
        <RuntimeDynamicAction Name="\(escapeXML(option.displayName))">
        \(targets.joined(separator: "\n"))
        </RuntimeDynamicAction>
        """
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            CanvasArea(
                selectedTool: $selectedTool,
                activePlacementAsset: activePlacementAsset,
                fallbackPlacementAsset: fallbackPlacementAsset,
                camera: camera,
                onDeleteSelection: onDeleteSelection,
                onLiveEditBegan: onLiveEditBegan,
                onLiveEditEnded: onLiveEditEnded,
                document: $document,
                trickPreviewPlayback: .constant(nil),
                dynamicOnionTransforms: onionCanvasTransforms,
                dynamicLivePreviewTransforms: livePreviewTransforms,
                allowsBlankCanvasDeselection: false
            )

            VStack {
                studioOverlayHeader
                Spacer()
            }

            timelineDock
                .padding(.horizontal, 28)
                .padding(.bottom, 20)
        }
        .onAppear {
            rebuildSceneCaches()
            updatePinnedAnimationTarget()
            loadTimelineForSelection()
        }
        .onChange(of: animationTarget?.id) { _, _ in
            stopPreview(restore: true)
            stopScrubPreview(restore: true)
            loadTimelineForSelection()
        }
        .onChange(of: selectedSequenceIndex) { _, _ in
            stopPreview(restore: true)
            stopScrubPreview(restore: true)
            loadTimelineForSelection()
        }
        .onChange(of: document.selectedNodeID) { _, _ in
            rebuildSceneCaches()
            updatePinnedAnimationTarget()
            selectedSequenceIndex = 0
            stopPreview(restore: true)
            stopScrubPreview(restore: true)
            loadTimelineForSelection()
        }
        .onChange(of: document.renderRevision) { _, _ in
            guard !isPreviewing else { return }
            rebuildSceneCaches()
        }
        .onChange(of: currentFrame) { _, _ in
            applyScrubPreviewIfNeeded()
        }
        .onChange(of: scrubPreview) { _, enabled in
            if enabled {
                beginScrubPreview()
            } else {
                stopScrubPreview(restore: true)
            }
        }
        .onChange(of: transformName) { _, _ in
            refreshGeneratedXMLCache()
        }
        .onChange(of: keyframes) { _, _ in
            refreshGeneratedXMLCache()
            if keyframes.count < 2 {
                scrubPreview = false
                stopScrubPreview(restore: true)
            } else {
                applyScrubPreviewIfNeeded()
            }
        }
        .onChange(of: customEase) { _, _ in
            refreshGeneratedXMLCache()
        }
        .onChange(of: movementMode) { _, _ in motionSettingsChanged() }
        .onChange(of: movementQuarter) { _, _ in motionSettingsChanged() }
        .onChange(of: sizeMode) { _, _ in motionSettingsChanged() }
        .onChange(of: sizeQuarter) { _, _ in motionSettingsChanged() }
        .onChange(of: rotationMode) { _, _ in motionSettingsChanged() }
        .onChange(of: totalFrames) { _, newValue in
            totalFrames = max(1, newValue)
            currentFrame = min(currentFrame, totalFrames)
        }
        .task(id: isPreviewing) {
            await runPreviewLoop()
        }
    }

    private func runPreviewLoop() async {
        guard isPreviewing else { return }
        while !Task.isCancelled && isPreviewing {
            // Vector timelines run at 30 fps, so there is no point rebuilding
            // the whole preview twice for the same game frame.
            try? await Task.sleep(for: .milliseconds(33))
            guard !Task.isCancelled && isPreviewing else { return }
            advancePreview()
        }
    }

    private var dockMode: DynamicStudioDockMode {
        if timelineDockHeight < 280 { return .compact }
        if timelineDockHeight < 390 { return .normal }
        return .expanded
    }

    private var hasRotationKeyframes: Bool {
        guard let first = keyframes.sorted(by: { $0.frame < $1.frame }).first else { return false }
        return keyframes.contains { abs($0.rotation - first.rotation) > 0.001 }
    }

    private var studioOverlayHeader: some View {
        HStack(spacing: 12) {
            Label("Dynamic Studio", systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
            Text("\(selectedNodes.count) selected")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.86))
            if let activeSequenceOption {
                HStack(spacing: 6) {
                    Button {
                        selectSequence(offset: -1)
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(presentedSequenceOptions.count < 2)
                    .help("Preview the previous runtime Dynamic action.")

                    VStack(spacing: 1) {
                        Text("Dynamic \(activeSequenceIndex + 1) of \(presentedSequenceOptions.count)")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(.cyan)
                        Text(activeSequenceOption.displayName)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .frame(minWidth: 190, maxWidth: 260)
                    }

                    Button {
                        selectSequence(offset: 1)
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(presentedSequenceOptions.count < 2)
                    .help("Preview the next runtime Dynamic action.")
                }
            }
            Text("Frame \(currentFrame) / \(totalFrames)")
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.white.opacity(0.86))
            Spacer()
            Text("Move: \(movementMode.title)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.86))
            Toggle("Onion", isOn: $onionSkin)
                .toggleStyle(.checkbox)
                .allowsHitTesting(true)
                .foregroundStyle(.white)
                .help("Draws ghost boxes for saved keyframes.")
            Toggle("Scrub", isOn: $scrubPreview)
                .toggleStyle(.checkbox)
                .allowsHitTesting(true)
                .foregroundStyle(.white)
                .help("Applies the timeline pose while moving the playhead, then restores when turned off.")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.68), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(0.18), lineWidth: 1)
        )
        .padding(.top, 14)
        .padding(.horizontal, 18)
    }

    private var header: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Dynamic Studio")
                    .font(.system(size: 22, weight: .bold))
                Text("Vector 2 movement animator")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Toggle("Custom Ease", isOn: $customEase)
                .toggleStyle(.checkbox)
            Toggle("Onion", isOn: $onionSkin)
                .toggleStyle(.checkbox)

            HStack(spacing: 8) {
                Text("Zoom")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Slider(value: $zoom, in: 0.5...2.5)
                    .frame(width: 150)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.white)
    }

    private var previewWorkspace: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18)
                .fill(Color.white.opacity(0.92))
                .shadow(color: .black.opacity(0.06), radius: 14, y: 8)
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(Color.black.opacity(0.08), lineWidth: 1)
                )

            VStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color(red: 0.98, green: 0.985, blue: 1))
                        .overlay(dynamicStudioGrid.opacity(0.55))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(Color.black.opacity(0.08), lineWidth: 1)
                        )

                    VStack(spacing: 8) {
                        Image(systemName: "point.topleft.down.curvedto.point.bottomright.up")
                            .font(.system(size: 36, weight: .light))
                            .foregroundStyle(Color.blue.opacity(0.75))
                        Text("Preview lane")
                            .font(.headline)
                        Text("Select an object in the room, add keyframes below, then preview motion here.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                }
                .frame(maxHeight: 360)

                HStack(spacing: 10) {
                    Label("\(selectedNodes.count) selected", systemImage: "cube.transparent")
                    Divider()
                        .frame(height: 18)
                    Label("\(keyframes.count) keyframe\(keyframes.count == 1 ? "" : "s")", systemImage: "diamond")
                    Spacer()
                    Text("Frame \(currentFrame) / \(totalFrames)")
                        .font(.caption.monospacedDigit().weight(.semibold))
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            }
            .padding(18)
        }
        .padding(22)
    }

    private var dynamicStudioGrid: some View {
        Canvas { context, size in
            let step: CGFloat = 40
            var path = Path()
            var x: CGFloat = 0
            while x <= size.width {
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                x += step
            }
            var y: CGFloat = 0
            while y <= size.height {
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                y += step
            }
            context.stroke(path, with: .color(Color.black.opacity(0.08)), lineWidth: 1)
        }
    }

    private var timelineDock: some View {
        VStack(spacing: 12) {
            resizeHandle

            HStack(spacing: 10) {
                Text("Transform")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.primary)
                TextField("Transform name", text: $transformName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: dockMode == .compact ? 150 : 230)

                Button("Save", action: saveDynamicTransform)
                    .buttonStyle(.borderedProminent)
                    .disabled(animationTarget == nil || keyframes.count < 2)

                Spacer()

                if dockMode != .compact {
                    transformCapabilityBadges
                    motionModeMenu
                    frameStepper(label: "Frame", value: $currentFrame, range: 0...totalFrames)
                    frameStepper(label: "End", value: $totalFrames, range: max(1, currentFrame)...9999)
                }
            }

            VStack(spacing: 10) {
                HStack {
                    if dockMode == .compact {
                        frameStepper(label: "F", value: $currentFrame, range: 0...totalFrames)
                        frameStepper(label: "End", value: $totalFrames, range: max(1, currentFrame)...9999)
                    }
                    Button("Clear") {
                        keyframes.removeAll()
                        selectedKeyframeIDs.removeAll()
                    }
                    Button(action: addSnapshotKeyframe) {
                        Label("Add Keyframe", systemImage: "diamond.fill")
                    }
                        .keyboardShortcut("k", modifiers: [.command])
                        .help("Snapshots the selected object's current X/Y/size/rotation at the playhead.")
                    Button("Del KF", action: deleteSelectedKeyframes)
                        .disabled(selectedKeyframeIDs.isEmpty)
                    Button(action: togglePreview) {
                        Label(isPreviewing ? "Stop Preview" : "Preview", systemImage: isPreviewing ? "stop.fill" : "play.fill")
                    }
                        .disabled(keyframes.count < 2 || animationTarget == nil)
                        .help("Previews the saved keyframes in the editor, then restores the object when stopped.")
                    if let activeSequenceOption {
                        HStack(spacing: 5) {
                            Button {
                                selectSequence(offset: -1)
                            } label: {
                                Image(systemName: "chevron.left")
                            }
                            .disabled(presentedSequenceOptions.count < 2)

                            VStack(spacing: 0) {
                                Text("Dynamic \(activeSequenceIndex + 1)/\(presentedSequenceOptions.count)")
                                    .font(.system(size: 9, weight: .bold, design: .rounded))
                                    .foregroundStyle(.blue)
                                Text(activeSequenceOption.displayName)
                                    .font(.caption2.weight(.semibold))
                                    .lineLimit(1)
                                    .frame(width: dockMode == .compact ? 120 : 190)
                            }

                            Button {
                                selectSequence(offset: 1)
                            } label: {
                                Image(systemName: "chevron.right")
                            }
                            .disabled(presentedSequenceOptions.count < 2)
                        }
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                        .help("Switch between complete runtime Dynamic actions before previewing.")
                    }
                    Toggle("Scrub Preview", isOn: $scrubPreview)
                        .toggleStyle(.checkbox)
                        .disabled(keyframes.count < 2 || animationTarget == nil || isPreviewing)
                        .help("When enabled, dragging/clicking the timeline updates the selected object to that frame.")
                    Spacer()
                    if dockMode == .compact {
                        transformCapabilityBadges
                        motionModeMenu
                    }
                }
                .buttonStyle(.bordered)

                DynamicTimelineStrip(
                    totalFrames: max(1, totalFrames),
                    currentFrame: $currentFrame,
                    keyframes: keyframes,
                    selectedIDs: $selectedKeyframeIDs
                )
                .frame(height: dockMode == .compact ? 58 : 86)

                if dockMode != .compact {
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: 12) {
                            motionSettingsPanel
                                .frame(width: 280)
                            selectionPanel
                                .frame(width: 250)
                            keyframeList
                            triggerBindingPanel
                            outputPlan
                                .frame(width: dockMode == .expanded ? 360 : 280)
                        }
                        .padding(.bottom, 2)
                    }
                }
            }
        }
        .padding(16)
        .frame(width: timelineDockWidth)
        .frame(height: timelineDockHeight)
        .clipped()
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Color(nsColor: .windowBackgroundColor))
                .shadow(color: .black.opacity(0.12), radius: 20, y: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(Color.black.opacity(0.1), lineWidth: 1)
        )
    }

    private var resizeHandle: some View {
        HStack {
            Capsule()
                .fill(Color.black.opacity(0.24))
                .frame(width: 58, height: 5)
            Spacer()
            Label("\(Int(timelineDockWidth))x\(Int(timelineDockHeight))", systemImage: "arrow.up.left.and.arrow.down.right")
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.black.opacity(0.06), in: Capsule())
        }
        .contentShape(Rectangle().inset(by: -6))
        .gesture(resizeGesture)
        .help("Drag anywhere on this top bar to resize Dynamic Studio.")
        .padding(.top, -4)
        .padding(.bottom, -2)
    }

    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if resizeStartSize == nil {
                    resizeStartSize = CGSize(width: timelineDockWidth, height: timelineDockHeight)
                }
                let start = resizeStartSize ?? CGSize(width: timelineDockWidth, height: timelineDockHeight)
                timelineDockWidth = min(max(680, start.width + value.translation.width), 1320)
                timelineDockHeight = min(max(220, start.height - value.translation.height), 620)
            }
            .onEnded { _ in
                resizeStartSize = nil
            }
    }

    private var transformCapabilityBadges: some View {
        HStack(spacing: 6) {
            capabilityBadge("Move")
            capabilityBadge("Size")
            capabilityBadge(hasRotationKeyframes ? "Rotate ✓" : "Rotate")
        }
    }

    private var motionModeMenu: some View {
        Menu {
            Picker("Movement", selection: $movementMode) {
                ForEach(DynamicPathMode.allCases) { Text($0.title).tag($0) }
            }
            Picker("Rotation", selection: $rotationMode) {
                ForEach(DynamicRotationMode.allCases) { Text($0.title).tag($0) }
            }
        } label: {
            Label("Motion", systemImage: "waveform.path")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var motionSettingsPanel: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Motion modes")
                .font(.caption.weight(.bold))
            motionPathPicker("Move", mode: $movementMode, quarter: $movementQuarter)
            motionPathPicker("Resize", mode: $sizeMode, quarter: $sizeQuarter)
            VStack(alignment: .leading, spacing: 4) {
                Picker("Rotate", selection: $rotationMode) {
                    ForEach(DynamicRotationMode.allCases) { Text($0.title).tag($0) }
                }
                Text(rotationMode.summary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func motionPathPicker(
        _ label: String,
        mode: Binding<DynamicPathMode>,
        quarter: Binding<DynamicSinQuarter>
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.caption.weight(.semibold))
                Picker(label, selection: mode) {
                    ForEach(DynamicPathMode.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                if mode.wrappedValue == .sinusoidal {
                    Picker("Curve", selection: quarter) {
                        ForEach(DynamicSinQuarter.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                }
            }
            Text(mode.wrappedValue == .sinusoidal ? quarter.wrappedValue.summary : mode.wrappedValue.summary)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func capabilityBadge(_ label: String) -> some View {
        Text(label)
            .font(.caption2.weight(.bold))
            .foregroundStyle(label.contains("✓") ? .green : .secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Color.black.opacity(0.06), in: Capsule())
    }

    private var selectionPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Selection")
                .font(.caption.weight(.bold))
                .foregroundStyle(.primary)

            if selectedNodes.isEmpty {
                Text("Select an object in the room first.")
                    .font(.caption)
                    .foregroundStyle(.primary.opacity(0.72))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            } else {
                ForEach(selectedNodes.prefix(6)) { node in
                    DynamicStudioSelectionRow(node: node)
                }
                if selectedNodes.count > 6 {
                    Text("+ \(selectedNodes.count - 6) more")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var keyframeList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Keyframes")
                .font(.caption.weight(.bold))
                .foregroundStyle(.primary)
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(keyframes.sorted { $0.frame < $1.frame }) { keyframe in
                        DynamicKeyframeRow(
                            keyframe: keyframe,
                            isSelected: selectedKeyframeIDs.contains(keyframe.id)
                        )
                        .onTapGesture {
                            selectedKeyframeIDs = [keyframe.id]
                            currentFrame = keyframe.frame
                        }
                    }
                }
            }
            .frame(width: 250, height: 74)
        }
    }

    private var outputPlan: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Vector 2 Output")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.primary)
                Spacer()
                Button(showOutputXML ? "Hide XML" : "Show XML") {
                    showOutputXML.toggle()
                }
                .buttonStyle(.borderless)
                .font(.caption.weight(.semibold))
                .disabled(outputDisplayXML.isEmpty)
            }

            if outputDisplayXML.isEmpty {
                Text("Add at least two keyframes, then Save to add the animation to this object.")
                    .font(.caption)
                    .foregroundStyle(.primary.opacity(0.75))
            } else if showOutputXML {
                ScrollView {
                    Text(outputDisplayXML)
                        .font(.caption.monospaced())
                        .foregroundStyle(.primary.opacity(0.75))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Label("XML ready. Hidden for FPS.", systemImage: "checkmark.seal.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var triggerBindingPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Trigger bind")
                .font(.caption.weight(.bold))
                .foregroundStyle(.primary)
            Button(action: createTriggerForTarget) {
                Label("Create Trigger", systemImage: "plus.square.on.square")
            }
            .buttonStyle(.borderedProminent)
            .disabled(animationTarget == nil || cachedDynamicXML.isEmpty)
            .help("Adds a simple trigger box near the selected object and binds this transform to it.")
            if triggerNodes.isEmpty {
                Text("No trigger boxes in this room yet.")
                    .font(.caption)
                    .foregroundStyle(.primary.opacity(0.72))
                    .frame(width: 210, alignment: .leading)
            } else {
                Picker("Trigger", selection: $selectedTriggerIDString) {
                    Text("Pick trigger").tag("")
                    ForEach(triggerNodes) { trigger in
                        Text(trigger.name.isEmpty ? "Trigger" : trigger.name).tag(trigger.id.uuidString)
                    }
                }
                .labelsHidden()
                .frame(width: 210)
                Button("Bind Transform", action: bindSelectedTrigger)
                    .buttonStyle(.bordered)
                    .disabled(selectedTriggerIDString.isEmpty || cachedDynamicXML.isEmpty)
            }
        }
        .frame(width: 230, alignment: .topLeading)
    }

    private func frameStepper(label: String, value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField(label, value: value, formatter: DynamicStudioNumberFormatter.integer)
                .textFieldStyle(.roundedBorder)
                .frame(width: 72)
                .onChange(of: value.wrappedValue) { _, newValue in
                    value.wrappedValue = min(max(newValue, range.lowerBound), range.upperBound)
                }
        }
    }

    private func addSnapshotKeyframe() {
        guard let node = animationTarget, let transform = node.transform else { return }
        let keyframe = DynamicStudioKeyframe(
            frame: currentFrame,
            x: transform.x,
            y: transform.y,
            width: transform.width,
            height: transform.height,
            rotation: transform.rotation
        )
        keyframes.removeAll { $0.frame == currentFrame }
        keyframes.append(keyframe)
        selectedKeyframeIDs = [keyframe.id]
    }

    private func updatePinnedAnimationTarget() {
        let selected = document.selectedNodes.filter { $0.kind != .trigger && $0.transform != nil }
        guard !selected.isEmpty else { return }
        let ids = selected.map(\.id)
        pinnedAnimationTargetID = EditorSelectionPolicy.preferredID(
            primary: document.selectedNodeID,
            selected: document.selectedNodeIDs,
            eligible: ids
        ) ?? ids.first
    }

    private func deleteSelectedKeyframes() {
        keyframes.removeAll { selectedKeyframeIDs.contains($0.id) }
        selectedKeyframeIDs.removeAll()
    }

    private func saveDynamicTransform() {
        guard let target = animationTarget,
              let startPose = keyframes.min(by: { $0.frame < $1.frame }) else { return }
        stopPreview(restore: true)
        stopScrubPreview(restore: true)

        // Vector 2 applies transformation intervals from the object's exported
        // pose. Keep the scene at frame zero so editor preview and runtime share
        // the same baseline. The canvas mutator also carries attached children.
        document.root.update(id: target.id) { node in
            let oldTransform = node.transform
            let newTransform = LevelNode.Transform(x: startPose.x, y: startPose.y, width: startPose.width, height: startPose.height, rotation: startPose.rotation)
            node.transform = newTransform
            if let oldTransform, !node.keepsChildrenInLocalRoomWeaverSpace {
                node.transformDescendants(from: oldTransform, to: newTransform)
            }
            node.metadata.isTransformEdited = true
        }
        refreshGeneratedXMLCache()
        let xml = cachedDynamicXML
        guard !xml.isEmpty else { return }
        document.root.update(id: target.id) { node in
            node.metadata.dynamicXML = xml
        }
        bindSelectedTrigger()
    }

    private func bindSelectedTrigger() {
        guard let triggerID = UUID(uuidString: selectedTriggerIDString) else { return }
        let loop = generatedTriggerLoopXML()
        guard !loop.isEmpty else { return }
        document.root.update(id: triggerID) { node in
            node.metadata.dynamicTriggerXML = loop
        }
    }

    private func createTriggerForTarget() {
        guard let target = animationTarget, let transform = target.transform else { return }
        let trigger = LevelNode(
            name: "Trigger_\(safeTransformName)",
            kind: .trigger,
            factor: target.factor,
            transform: .init(
                x: transform.x,
                y: transform.y,
                width: max(180, transform.width),
                height: max(100, transform.height)
            ),
            xml: .init(template: "", choice: "Dynamic", variant: "Default"),
            metadata: .init(
                sortingLayer: "Default",
                tag: LevelNode.Kind.trigger.defaultTag,
                dynamicTriggerXML: generatedTriggerLoopXML()
            )
        )
        if document.root.appendToFirstFactor(trigger) {
            selectedTriggerIDString = trigger.id.uuidString
        }
    }

    private func generatedTriggerLoopXML() -> String {
        let dynamicXML = cachedDynamicXML.isEmpty ? generatedDynamicXML() : cachedDynamicXML
        guard !dynamicXML.isEmpty else { return "" }
        let loopName = "Run_\(safeTransformName)"
        return """
        <Loop Name="\(escapeXML(loopName))">
          <Events>
            <Enter />
          </Events>
          <Actions>
            <Choose Order="Sync" Set="0">
              <Transform Name="\(escapeXML(safeTransformName))" />
            </Choose>
          </Actions>
        </Loop>
        """
    }

    private func generatedDynamicXML() -> String {
        let sortedKeyframes = keyframes.sorted { $0.frame < $1.frame }
        guard sortedKeyframes.count >= 2 else { return "" }

        let dynamic = XMLElement(name: "Dynamic")
        let transformation = XMLElement(name: "Transformation")
        transformation.addAttribute(XMLNode.attribute(withName: "Name", stringValue: safeTransformName) as! XMLNode)
        for pair in zip(sortedKeyframes, sortedKeyframes.dropFirst()) {
            let start = pair.0
            let finish = pair.1
            let frames = max(1, finish.frame - start.frame)
            let dx = finish.x - start.x
            let dy = finish.y - start.y
            let rotationDelta = finish.rotation - start.rotation
            let widthRatio = start.width == 0 ? 1 : Double(finish.width) / Double(start.width)
            let heightRatio = start.height == 0 ? 1 : Double(finish.height) / Double(start.height)
            var wroteInterval = false

            if dx != 0 || dy != 0 {
                let move = XMLElement(name: "MoveInterval")
                move.addAttribute(XMLNode.attribute(withName: "Frames", stringValue: "\(frames)") as! XMLNode)
                move.addAttribute(XMLNode.attribute(withName: "Type", stringValue: movementMode.xmlName) as! XMLNode)
                addPoint(to: move, x: 0, y: 0)
                addPoint(to: move, x: dx, y: dy)
                if movementMode == .sinusoidal { addQuarters(to: move, value: movementQuarter.xmlName) }
                transformation.addChild(move)
                wroteInterval = true
            }

            if abs(rotationDelta) > 0.001 {
                let rotate = XMLElement(name: "RotationInterval")
                rotate.addAttribute(XMLNode.attribute(withName: "Angle", stringValue: pretty(rotationDelta)) as! XMLNode)
                rotate.addAttribute(XMLNode.attribute(withName: "Type", stringValue: rotationMode.xmlName) as! XMLNode)
                rotate.addAttribute(XMLNode.attribute(withName: "Frames", stringValue: "\(frames)") as! XMLNode)
                transformation.addChild(rotate)
                wroteInterval = true
            }

            if abs(widthRatio - 1) > 0.001 || abs(heightRatio - 1) > 0.001 {
                let size = XMLElement(name: "SizeInterval")
                size.addAttribute(XMLNode.attribute(withName: "Frames", stringValue: "\(frames)") as! XMLNode)
                size.addAttribute(XMLNode.attribute(withName: "Type", stringValue: sizeMode.xmlName) as! XMLNode)
                addPoint(to: size, w: 1, h: 1)
                addPoint(to: size, w: widthRatio, h: heightRatio)
                if sizeMode == .sinusoidal { addQuarters(to: size, value: sizeQuarter.xmlName) }
                transformation.addChild(size)
                wroteInterval = true
            }

            if !wroteInterval {
                let delay = XMLElement(name: "DelayInterval")
                delay.addAttribute(XMLNode.attribute(withName: "Frames", stringValue: "\(frames)") as! XMLNode)
                transformation.addChild(delay)
            }
        }

        dynamic.addChild(transformation)
        return dynamic.xmlString(options: [.nodePrettyPrint])
    }

    private func refreshGeneratedXMLCache() {
        cachedDynamicXML = generatedDynamicXML()
    }

    private var safeTransformName: String {
        let trimmed = transformName.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawName = trimmed.isEmpty ? "NewTransform" : trimmed
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        let scalars = rawName.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? String(scalar) : "_"
        }
        let sanitized = scalars.joined()
            .trimmingCharacters(in: CharacterSet(charactersIn: "_-"))
        return sanitized.isEmpty ? "NewTransform" : sanitized
    }

    private func loadTimelineForSelection() {
        importedPreviewTracks.removeAll()
        groupedImportedPreviewTracks.removeAll()
        primaryImportedTimeline = nil
        guard let target = animationTarget, let transform = target.transform else {
            keyframes = []
            selectedKeyframeIDs.removeAll()
            return
        }

        var preserveImportedXML = false

        if let imported = DynamicStudioImportedTimeline.parse(
            target.metadata.dynamicXML,
            x: transform.x,
            y: transform.y,
            width: transform.width,
            height: transform.height,
            rotation: transform.rotation,
            transformationName: activeSequenceOption?.nodeID == target.id
                ? activeSequenceOption?.transformationName
                : nil
        ) {
            primaryImportedTimeline = imported
            transformName = imported.name
            totalFrames = max(1, imported.totalFrames)
            keyframes = imported.keyframes.map {
                DynamicStudioKeyframe(
                    frame: $0.frame,
                    x: $0.x,
                    y: $0.y,
                    width: $0.width,
                    height: $0.height,
                    rotation: $0.rotation
                )
            }
            currentFrame = 0
            loadMotionModes(from: target.metadata.dynamicXML)
            preserveImportedXML = true
            if let option = activeSequenceOption {
                for member in option.members {
                    guard let memberTarget = animationTargets.first(where: { $0.id == member.nodeID }),
                          let memberTransform = memberTarget.transform,
                          let timeline = DynamicStudioImportedTimeline.parse(
                            memberTarget.metadata.dynamicXML,
                            x: memberTransform.x,
                            y: memberTransform.y,
                            width: memberTransform.width,
                            height: memberTransform.height,
                            rotation: memberTransform.rotation,
                            transformationName: member.transformationName
                          ) else { continue }
                    importedPreviewTracks.append(.init(
                        nodeID: member.nodeID,
                        sourceTransform: memberTransform,
                        timeline: timeline
                    ))
                    totalFrames = max(totalFrames, timeline.totalFrames)
                }
            }
        } else {
            transformName = target.metadata.dynamicXML.isEmpty ? "\(target.name.isEmpty ? "New" : target.name)Transform" : safeTransformNameFromXML(target.metadata.dynamicXML)
            totalFrames = max(300, currentFrame)
            keyframes = [
                DynamicStudioKeyframe(
                    frame: 0,
                    x: transform.x,
                    y: transform.y,
                    width: transform.width,
                    height: transform.height,
                    rotation: transform.rotation
                )
            ]
            currentFrame = 0
            loadMotionModes(from: target.metadata.dynamicXML)
        }

        selectedKeyframeIDs = keyframes.first.map { [$0.id] } ?? []
        if selectedTriggerIDString.isEmpty, let firstTrigger = triggerNodes.first {
            selectedTriggerIDString = firstTrigger.id.uuidString
        }
        if preserveImportedXML {
            cachedDynamicXML = target.metadata.dynamicXML
        } else {
            refreshGeneratedXMLCache()
        }
        groupedImportedPreviewTracks = Dictionary(grouping: importedPreviewTracks, by: \.nodeID)
    }

    private func togglePreview() {
        if isPreviewing {
            stopPreview(restore: true)
        } else {
            startPreview()
        }
    }

    private func startPreview() {
        guard let target = animationTarget, let transform = target.transform else { return }
        scrubPreview = false
        stopScrubPreview(restore: true)
        previewOriginalTransform = transform
        previewTargetID = target.id
		previewHierarchyTemplate = document.node(for: target.id)
        currentFrame = keyframes.map(\.frame).min() ?? 0
        isPreviewing = true
        applyPreviewPose(for: currentFrame, targetID: target.id)
    }

    private func stopPreview(restore: Bool) {
        guard isPreviewing || previewOriginalTransform != nil else { return }
        isPreviewing = false
        livePreviewTransforms.removeAll()
        previewOriginalTransform = nil
        previewTargetID = nil
		previewHierarchyTemplate = nil
    }

    private func advancePreview() {
        guard let targetID = previewTargetID else {
            stopPreview(restore: true)
            return
        }
        let maxFrame = max(totalFrames, keyframes.map(\.frame).max() ?? totalFrames)
        if currentFrame >= maxFrame {
            stopPreview(restore: true)
            return
        }
		currentFrame = min(maxFrame, currentFrame + 1)
        applyPreviewPose(for: currentFrame, targetID: targetID)
    }

    private func beginScrubPreview() {
        guard !isPreviewing,
              scrubOriginalTransform == nil,
              let target = animationTarget,
              let transform = target.transform else { return }
        scrubOriginalTransform = transform
        applyScrubPreviewIfNeeded()
    }

    private func stopScrubPreview(restore: Bool) {
        guard scrubOriginalTransform != nil else { return }
        livePreviewTransforms.removeAll()
        scrubOriginalTransform = nil
    }

    private func applyScrubPreviewIfNeeded() {
        guard scrubPreview,
              !isPreviewing,
              keyframes.count >= 2,
              let target = animationTarget else { return }
        if scrubOriginalTransform == nil {
            beginScrubPreview()
            return
        }
        applyPreviewPose(for: currentFrame, targetID: target.id)
    }

    private func applyPreviewPose(for frame: Int, targetID: LevelNode.ID) {
        let local: LevelNode.Transform
        if let pose = primaryImportedTimeline?.pose(at: frame) {
            local = .init(
                x: pose.x,
                y: pose.y,
                width: pose.width,
                height: pose.height,
                rotation: pose.rotation
            )
        } else {
            guard let pose = interpolatedPose(at: frame) else { return }
            local = .init(
                x: pose.x,
                y: pose.y,
                width: pose.width,
                height: pose.height,
                rotation: pose.rotation
            )
        }
        var nextTransforms: [LevelNode.ID: LevelNode.Transform] = [
            targetID: document.root.canvasTransform(for: targetID, localTransform: local)
        ]
        // Normal editor parenting stores descendants in scene space. Runtime
        // parenting carries them with the Dynamic owner, so mirror that here
        // instead of previewing only the owner's rectangle.
		if var previewTree = previewHierarchyTemplate,
           let original = previewTree.transform,
           !previewTree.keepsChildrenInLocalRoomWeaverSpace {
            previewTree.transform = local
            previewTree.transformDescendants(from: original, to: local)
            for descendant in previewTree.children.flatMap({ $0.allDescendantsIncludingSelf() }) {
                if let transform = descendant.transform {
                    nextTransforms[descendant.id] = transform
                }
            }
        }
        for (memberID, tracks) in groupedImportedPreviewTracks {
            guard let sourceTransform = tracks.first?.sourceTransform else { continue }
            var composed = sourceTransform
            var widthScale = 1.0
            var heightScale = 1.0
            for track in tracks {
                guard let first = track.timeline.keyframes.min(by: { $0.frame < $1.frame }),
                      let memberPose = interpolatedImportedPose(in: track.timeline, at: frame) else { continue }
                composed.x += memberPose.x - first.x
                composed.y += memberPose.y - first.y
                composed.rotation += memberPose.rotation - first.rotation
                widthScale *= Double(memberPose.width) / Double(max(1, first.width))
                heightScale *= Double(memberPose.height) / Double(max(1, first.height))
            }
            composed.width = max(1, Int((Double(sourceTransform.width) * widthScale).rounded()))
            composed.height = max(1, Int((Double(sourceTransform.height) * heightScale).rounded()))
            nextTransforms[memberID] = document.root.canvasTransform(for: memberID, localTransform: composed)
        }
        livePreviewTransforms = nextTransforms
    }

    private func interpolatedImportedPose(
        in timeline: DynamicStudioImportedTimeline,
        at frame: Int
    ) -> DynamicStudioImportedKeyframe? {
        timeline.pose(at: frame)
    }

    private func interpolatedPose(at frame: Int) -> DynamicStudioKeyframe? {
        let sorted = keyframes.sorted { $0.frame < $1.frame }
        guard let first = sorted.first else { return nil }
        guard sorted.count > 1 else { return first }
        if frame <= first.frame { return first }
        if let last = sorted.last, frame >= last.frame { return last }
        guard let upperIndex = sorted.firstIndex(where: { $0.frame >= frame }), upperIndex > 0 else { return first }
        let lower = sorted[upperIndex - 1]
        let upper = sorted[upperIndex]
        let span = max(1, upper.frame - lower.frame)
        let rawT = Double(frame - lower.frame) / Double(span)
        let moveT = DynamicStudioEasing.pathProgress(rawT, mode: movementMode, quarter: movementQuarter)
        let sizeT = DynamicStudioEasing.pathProgress(rawT, mode: sizeMode, quarter: sizeQuarter)
        let rotateT = DynamicStudioEasing.rotationProgress(rawT, mode: rotationMode)
        return DynamicStudioKeyframe(
            frame: frame,
            x: lerp(lower.x, upper.x, moveT),
            y: lerp(lower.y, upper.y, moveT),
            width: lerp(lower.width, upper.width, sizeT),
            height: lerp(lower.height, upper.height, sizeT),
            rotation: lerp(lower.rotation, upper.rotation, rotateT)
        )
    }

    private func lerp(_ a: Int, _ b: Int, _ t: Double) -> Int {
        Int((Double(a) + (Double(b - a) * t)).rounded())
    }

    private func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double {
        a + ((b - a) * t)
    }

    private func motionSettingsChanged() {
        customEase = false
        refreshGeneratedXMLCache()
        applyScrubPreviewIfNeeded()
    }

    private func loadMotionModes(from xml: String) {
        guard !xml.isEmpty,
              let document = try? XMLDocument(xmlString: "<Root>\(xml)</Root>", options: []) else { return }
        if let move = (try? document.nodes(forXPath: ".//MoveInterval").first) as? XMLElement {
            movementMode = move.attribute(forName: "Type")?.stringValue == "Sin" ? .sinusoidal : .bezier
            movementQuarter = DynamicSinQuarter.fromXML(quarterValue(in: move))
        }
        if let size = (try? document.nodes(forXPath: ".//SizeInterval").first) as? XMLElement {
            sizeMode = size.attribute(forName: "Type")?.stringValue == "Sin" ? .sinusoidal : .bezier
            sizeQuarter = DynamicSinQuarter.fromXML(quarterValue(in: size))
        }
        if let rotate = (try? document.nodes(forXPath: ".//RotationInterval").first) as? XMLElement {
            rotationMode = DynamicRotationMode.fromXML(rotate.attribute(forName: "Type")?.stringValue)
        }
    }

    private func quarterValue(in interval: XMLElement) -> String? {
        ((try? interval.nodes(forXPath: "./Quarters"))?.first as? XMLElement)?
            .attribute(forName: "Value")?.stringValue
    }

    private func safeTransformNameFromXML(_ xml: String) -> String {
        guard let document = try? XMLDocument(xmlString: xml.hasPrefix("<Dynamic") ? "<Root>\(xml)</Root>" : "<Root><Dynamic>\(xml)</Dynamic></Root>", options: []),
              let transformation = document.rootElement()?.elements(forName: "Dynamic").first?.elements(forName: "Transformation").first,
              let name = transformation.attribute(forName: "Name")?.stringValue,
              !name.isEmpty else {
            return "NewTransform"
        }
        return name
    }

    private func flattenedNodes(in node: LevelNode) -> [LevelNode] {
        [node] + node.children.flatMap { flattenedNodes(in: $0) }
    }

    private func escapeXML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private func addPoint(to element: XMLElement, x: Int, y: Int) {
        let point = XMLElement(name: "Point")
        point.addAttribute(XMLNode.attribute(withName: "X", stringValue: "\(x)") as! XMLNode)
        point.addAttribute(XMLNode.attribute(withName: "Y", stringValue: "\(y)") as! XMLNode)
        element.addChild(point)
    }

    private func addPoint(to element: XMLElement, w: Double, h: Double) {
        let point = XMLElement(name: "Point")
        point.addAttribute(XMLNode.attribute(withName: "W", stringValue: pretty(w)) as! XMLNode)
        point.addAttribute(XMLNode.attribute(withName: "H", stringValue: pretty(h)) as! XMLNode)
        element.addChild(point)
    }

    private func addQuarters(to element: XMLElement, value: String) {
        let quarters = XMLElement(name: "Quarters")
        quarters.addAttribute(XMLNode.attribute(withName: "Value", stringValue: value) as! XMLNode)
        element.addChild(quarters)
    }

    private func pretty(_ value: Double) -> String {
        let rounded = (value * 1000).rounded() / 1000
        if rounded.rounded() == rounded {
            return "\(Int(rounded))"
        }
        return String(rounded)
    }
}

private enum DynamicStudioDockMode {
    case compact
    case normal
    case expanded
}

private struct DynamicStudioKeyframe: Identifiable, Codable, Equatable {
    var id = UUID()
    var frame: Int
    var x: Int
    var y: Int
    var width: Int
    var height: Int
    var rotation: Double
}

private enum DynamicStudioNumberFormatter {
    static let integer: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.allowsFloats = false
        return formatter
    }()
}

private struct DynamicStudioSelectionRow: View {
    let node: LevelNode

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: node.kind.toolbarSymbol)
                .foregroundStyle(.blue)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(node.name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(node.kind.rawValue)
                    .font(.caption2)
                    .foregroundStyle(.primary.opacity(0.66))
            }
            Spacer()
        }
        .padding(10)
        .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct DynamicTimelineStrip: View {
    let totalFrames: Int
    @Binding var currentFrame: Int
    let keyframes: [DynamicStudioKeyframe]
    @Binding var selectedIDs: Set<DynamicStudioKeyframe.ID>

    var body: some View {
        GeometryReader { proxy in
            let width = max(1, proxy.size.width)
            let height = proxy.size.height

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.gray.opacity(0.09))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.black.opacity(0.08), lineWidth: 1)
                    )

                ForEach(0...10, id: \.self) { tick in
                    let x = CGFloat(tick) / 10 * width
                    Rectangle()
                        .fill(Color.black.opacity(0.14))
                        .frame(width: 1, height: height)
                        .offset(x: x)
                    Text("\(Int(Double(totalFrames) * Double(tick) / 10.0))")
                        .font(.caption2)
                        .foregroundStyle(.primary.opacity(0.7))
                        .offset(x: max(0, min(width - 26, x - 8)), y: 5)
                }

                ForEach(keyframes) { keyframe in
                    let x = CGFloat(keyframe.frame) / CGFloat(max(1, totalFrames)) * width
                    DynamicStudioDiamond()
                        .fill(selectedIDs.contains(keyframe.id) ? Color.blue : Color.white)
                        .stroke(Color.blue, lineWidth: 2)
                        .frame(width: 13, height: 13)
                        .offset(x: x - 6.5, y: height / 2 - 6.5)
                        .onTapGesture {
                            selectedIDs = [keyframe.id]
                            currentFrame = keyframe.frame
                        }
                }

                Rectangle()
                    .fill(Color.blue)
                    .frame(width: 2, height: height)
                    .offset(x: CGFloat(currentFrame) / CGFloat(max(1, totalFrames)) * width)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let ratio = min(max(value.location.x / width, 0), 1)
                        currentFrame = Int((ratio * CGFloat(totalFrames)).rounded())
                    }
            )
        }
    }
}

private struct DynamicKeyframeRow: View {
    let keyframe: DynamicStudioKeyframe
    let isSelected: Bool

    var body: some View {
        HStack {
            Text("F\(keyframe.frame)")
                .font(.caption.weight(.bold))
            Spacer()
            Text("\(keyframe.x), \(keyframe.y)")
                .font(.caption)
                .foregroundStyle(.primary.opacity(0.72))
            Text("\(keyframe.width)x\(keyframe.height)")
                .font(.caption)
                .foregroundStyle(.primary.opacity(0.72))
            Text("\(Int(keyframe.rotation.rounded()))°")
                .font(.caption)
                .foregroundStyle(.primary.opacity(0.72))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(isSelected ? Color.blue.opacity(0.14) : Color.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct DynamicStudioDiamond: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        path.closeSubpath()
        return path
    }
}
