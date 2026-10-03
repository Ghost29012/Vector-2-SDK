//
//  RightDock.swift
//  Vector2 level editor
//
//  Right sidebar: hierarchy, inspector, and raw XML.
//
//  This panel is where selected LevelNode metadata becomes editable UI. The
//  inspector fields intentionally mirror Vector 2 XML names instead of prettier
//  labels, because creators need to see the same concepts the game reads.
//

import SwiftUI
import AppKit
import Foundation
import UniformTypeIdentifiers

struct RightDock: View {
    @Binding var selectedTab: RightSidebarTab
    @Binding var document: LevelDocument
    let selectedTool: EditorTool
    let gameDirectory: String
    @Binding var dynamicLivePreviewTransforms: [LevelNode.ID: LevelNode.Transform]
    @State private var collapsedNodeIDs: Set<LevelNode.ID> = []
    @State private var expandedDeepNodeIDs: Set<LevelNode.ID> = []
    @State private var rawXMLDraft = ""
    @AppStorage("vector2.triggerPredictiveCoding") private var xmlPredictiveCoding = true
    @State private var rawXMLReview: TriggerRuntimeSchema.DraftReview = .init(messages: [], proposedXML: nil)
    @State private var previousCheckedRawXML: String?
    @State private var rawXMLDiagnostics: [XMLAuthoringDiagnostic] = []
    @State private var rawXMLSelectedID: LevelNode.ID?
    @State private var rawXMLError = ""
    @State private var rawXMLApplied = false
    @State private var rawXMLKnownLibraryObjects: Set<String> = []
    @State private var rawXMLKnownTextures: Set<String> = []
    @State private var xmlTemplateIndex = XMLAssistantTemplateIndex()
    private var rawXMLAssistantIndex: XMLAssistantTemplateIndex { xmlTemplateIndex.withModels(document.aiCharacters.map(\.name)) }
    @State private var xmlTemplateReload = 0
    @State private var hierarchySelectionAnchorID: LevelNode.ID?
    @State private var hierarchySearch = ""
    @State private var hierarchyAppliedSearch = ""
    @State private var hierarchySearchMatchIDs: Set<LevelNode.ID> = []
    @State private var hierarchyDirectMatches: [LevelNode] = []
    @State private var hierarchySearchBlobs: [LevelNode.ID: String] = [:]
    @State private var liftPreviewTimer: Timer?
    @State private var liftPreviewNodeID: LevelNode.ID?
    @State private var propertyPreviewSequenceID = ""
    @State private var propertyPreviewOptions: [PropertyPreviewOption] = []
    @State private var propertyPreviewTracks: [PropertyPreviewTrack] = []
    @State private var isAITrickPickerPresented = false
    @State private var isAIAnimationPickerPresented = false
    @State private var animationAreaOptions: [String] = []
    @AppStorage("vector2.hierarchyFollowsSelection") private var hierarchyFollowsSelection = true

    private struct MovePreview {
        let deltas: [(x: Double, y: Double)]
        let duration: TimeInterval
    }

    private struct PropertyPreviewMember: Hashable {
        let nodeID: LevelNode.ID
        let transformationName: String
    }

    private struct PropertyPreviewOption: Identifiable {
        let id: String
        let displayName: String
        let members: [PropertyPreviewMember]
    }

    private struct PropertyPreviewTrack {
        let nodeID: LevelNode.ID
        let sourceTransform: LevelNode.Transform
        let timeline: DynamicStudioImportedTimeline
    }

    var body: some View {
        VStack(spacing: 0) {
            RightTabs(selectedTab: $selectedTab)
            Divider()

            VStack(spacing: 0) {
                if selectedTab == .hierarchy {
                    DockSection(title: "Hierarchy") {
                        hierarchyTree
                    }
                    Divider()
                }

                if selectedTab == .properties {
                    switch gameplayInspectorPanel {
                    case .trigger:
                        DockSection(title: "Trigger Action") {
                            aiTriggerPanel
                        }
                        Divider()
                    case .animationArea:
                        DockSection(title: "Animation Area") {
                            animationAreaPanel
                        }
                        Divider()
                    case .none:
                        EmptyView()
                    }
                    DockSection(title: "Properties") {
                        propertiesPanel
                    }
                    Divider()
                    DockSection(title: "XML") {
                        xmlPanel
                    }
                } else if selectedTab == .xml {
                    DockSection(title: "Raw XML") {
                        xmlEditorPanel
                    }
                } else {
                    DockSection(title: "Layer / Selection") {
                        layerPanel
                    }
                }
            }
            .background(Color.platformControlBackground)
        }
        .frame(width: 306)
        .background(Color.editorChromeBackground)
        .onChange(of: document.selectedNodeID) { _, _ in
            stopLiftPreview(restore: true)
            rebuildPropertyPreviewOptions()
        }
        .onChange(of: document.renderRevision) { _, _ in
            hierarchySearchBlobs.removeAll(keepingCapacity: true)
            if !normalizedHierarchySearch.isEmpty {
                rebuildHierarchySearchIndex()
            }
        }
        .onChange(of: document.id) { _, _ in
            hierarchySearchBlobs.removeAll()
            if !normalizedHierarchySearch.isEmpty {
                rebuildHierarchySearchIndex()
            }
            rebuildPropertyPreviewOptions()
        }
        .onAppear {
            rebuildPropertyPreviewOptions()
            refreshRawXMLReferenceIndex()
            refreshAnimationAreaOptions()
        }
        .sheet(isPresented: $isAITrickPickerPresented) {
            AITrickPickerSheet(
                gameDirectory: gameDirectory,
                selectedName: document.selectedNode?.metadata.aiActionValue ?? "",
                onSelect: { name in
                    guard let id = document.selectedNodeID else { return }
                    document.root.update(id: id) { $0.metadata.aiActionValue = name }
                    isAITrickPickerPresented = false
                },
                onClose: { isAITrickPickerPresented = false }
            )
        }
        .sheet(isPresented: $isAIAnimationPickerPresented) {
            AIAnimationPickerSheet(
                gameDirectory: gameDirectory,
                selectedName: document.selectedNode?.metadata.aiActionValue ?? "",
                onSelect: { name in
                    guard let id = document.selectedNodeID else { return }
                    document.root.update(id: id) { $0.metadata.aiActionValue = name }
                    isAIAnimationPickerPresented = false
                },
                onClose: { isAIAnimationPickerPresented = false }
            )
        }
        .onChange(of: gameDirectory) { _, _ in
            refreshAnimationAreaOptions()
        }
    }

    private var gameplayInspectorPanel: InspectorGameplayPanel {
        InspectorGameplayPanelPolicy.panel(
            selectedToolIsTrigger: selectedTool == .trigger,
            selectedToolIsArea: selectedTool == .area || selectedTool == .runFast,
            selectedNodeIsTrigger: document.selectedNode?.kind == .trigger,
            selectedNodeIsArea: document.selectedNode?.kind == .area
        )
    }

    private var aiTriggerPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            if document.selectedNode?.kind != .trigger {
                Text("Select or place a trigger, then choose its action.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else if let triggerID = document.selectedNode?.id {
                Picker("Target", selection: aiTargetBinding(for: triggerID)) {
                    Text("No action").tag("")
                    Text("Player").tag("player")
                    Text("Project event").tag("project")
                    Text("All AI").tag("all")
                    ForEach(document.aiCharacters) { character in
                        Text(character.name)
                            .foregroundStyle(character.kind == .enemy ? Color.red : Color.blue)
                            .tag("character:\(character.id.uuidString)")
                    }
                    ForEach(document.aiGroups) { group in
                        Text("Group: \(group.name)").tag("group:\(group.id.uuidString)")
                    }
                }
                Picker("Template", selection: aiMetadataBinding(\.aiActionTemplate)) {
                    Text("None").tag("")
                    ForEach(actionTemplates, id: \.self) {
                        Text($0).tag($0)
                    }
                }
                if document.selectedNode?.metadata.aiActionTemplate == "WallJump" {
                    Picker("Direction", selection: aiMetadataBinding(\.aiActionValue)) {
                        Text("Left").tag("Left")
                        Text("Right").tag("Right")
                    }
                } else if document.selectedNode?.metadata.aiActionTemplate == "Animation" {
                    HStack(spacing: 6) {
                        TextField("Type animation name", text: aiMetadataBinding(\.aiActionValue))
                            .textFieldStyle(.roundedBorder)
                        Button("Browse…") { isAIAnimationPickerPresented = true }
                    }
                } else if document.selectedNode?.metadata.aiActionTemplate == "Trick" {
                    HStack(spacing: 6) {
                        TextField("Type trick name", text: aiMetadataBinding(\.aiActionValue))
                            .textFieldStyle(.roundedBorder)
                        Button("Browse…") { isAITrickPickerPresented = true }
                    }
                } else if document.selectedNode?.metadata.aiActionTemplate == "Activate Spawn" {
                    Picker("Spawn / Respawn", selection: aiMetadataBinding(\.aiActionValue)) {
                        Text("Choose a spawn or respawn trigger").tag("")
                        ForEach(aiSpawnTriggers, id: \.id) { trigger in
                            Text(trigger.name.isEmpty ? "Spawn trigger" : trigger.name)
                                .tag(trigger.id.uuidString)
                        }
                    }
                } else {
                    TextField(aiActionValuePlaceholder, text: aiMetadataBinding(\.aiActionValue))
                        .textFieldStyle(.roundedBorder)
                        .disabled(!aiActionNeedsValue)
                }
            }
        }
        .padding(10)
    }

    private var animationAreaPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            if document.selectedNode?.kind != .area {
                Text("Place or select an Area, then choose the animation rule it enables.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                InspectorPickerField(
                    title: "Animation",
                    value: document.selectedNode?.name ?? "",
                    options: AnimationAreaPolicy.options(
                        discovered: animationAreaOptions,
                        current: document.selectedNode?.name ?? ""
                    ),
                    onCommit: { document.updateSelectedText(name: $0) }
                )
                Text("The name must match Vector 2's AreaName exactly. This exports as an Area with Type=Animation.")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.editorSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
    }

    private func aiTargetBinding(for triggerID: LevelNode.ID) -> Binding<String> {
        Binding(
            get: { document.root.find(id: triggerID)?.metadata.aiTarget ?? "" },
            set: { newTarget in
                guard let node = document.root.find(id: triggerID), node.kind == .trigger else { return }
                let currentTarget = node.metadata.aiTarget
                guard currentTarget != newTarget else { return }
                let action = TriggerActionTargetPolicy.actionAfterTargetEdit(
                    currentTarget: currentTarget,
                    newTarget: newTarget,
                    template: node.metadata.aiActionTemplate,
                    value: node.metadata.aiActionValue
                )
                document.root.update(id: triggerID) {
                    $0.metadata.aiTarget = newTarget
                    $0.metadata.aiActionTemplate = action.template
                    $0.metadata.aiActionValue = action.value
                }
            }
        )
    }

    private func aiMetadataBinding(_ keyPath: WritableKeyPath<LevelNode.Metadata, String>) -> Binding<String> {
        Binding(
            get: { document.selectedNode?.metadata[keyPath: keyPath] ?? "" },
            set: { value in
                guard let id = document.selectedNodeID else { return }
                document.root.update(id: id) { $0.metadata[keyPath: keyPath] = value }
            }
        )
    }

    private var aiActionNeedsValue: Bool {
        guard let template = document.selectedNode?.metadata.aiActionTemplate else { return false }
        return ["Trick", "Animation", "Spawn", "Activate Spawn", "Respawn", "Send Event"].contains(template)
    }

    private var aiSpawnTriggers: [LevelNode] {
        document.root.flattenedSceneNodes().filter { ["Spawn", "Respawn"].contains($0.metadata.aiActionTemplate) }
    }

    private var aiActionValuePlaceholder: String {
        guard let template = document.selectedNode?.metadata.aiActionTemplate else { return "Optional value" }
        if template == "Send Event" { return "Event name used by dialogue or tutorials" }
        return (template == "Spawn" || template == "Respawn") ? "Spawn name" : "Animation name"
    }

    private var actionTemplates: [String] {
        TriggerActionTargetPolicy.templates(for: document.selectedNode?.metadata.aiTarget ?? "")
    }

    private func refreshAnimationAreaOptions() {
        animationAreaOptions = TrickPreviewCatalog(gameDirectory: gameDirectory).loadAnimationAreaNames()
    }

    /// Searchable hierarchy tree.
    ///
    /// The search prunes branches before drawing rows for performance. Shift
    /// selection operates over the currently visible/search-filtered ids.
    private var hierarchyTree: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.editorSecondaryText)
                TextField("Search hierarchy", text: $hierarchySearch)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.editorPrimaryText)
                if !hierarchySearch.isEmpty {
                    Button {
                        hierarchySearch = ""
                        hierarchyAppliedSearch = ""
                        hierarchySearchMatchIDs.removeAll()
                        hierarchyDirectMatches.removeAll()
                    } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                            .foregroundStyle(Color.editorSecondaryText.opacity(0.65))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.platformControlBackground.opacity(0.92)))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.editorHairline, lineWidth: 1))
            .padding(.horizontal, 10)
            .padding(.top, 10)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        if normalizedHierarchySearch.isEmpty {
                            if RoomLayoutSection.authoringCases.contains(where: { !document.roomLayoutOptions(in: $0).isEmpty }) {
                                roomLayoutHierarchySummary
                            }
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                                    .font(.system(size: 10, weight: .semibold))
                                Text("Drop here to unparent to scene root")
                                    .font(.system(size: 10, weight: .semibold))
                            }
                            .foregroundStyle(Color.editorSecondaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(Color.editorSecondaryText.opacity(0.08))
                            .cornerRadius(6)
                            .onDrop(of: [UTType.plainText], isTargeted: nil) { providers in
                                reparentHierarchyDropToSceneRoot(providers: providers)
                            }
                            ForEach(visibleHierarchyRows, id: \.node.id) { row in
                                hierarchyItem(row.node, depth: row.depth, search: "")
                            }
                        } else if hierarchyDirectMatches.isEmpty {
                            Text("No matching objects")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.editorSecondaryText)
                                .padding(.horizontal, 8)
                        } else {
                            ForEach(hierarchyDirectMatches) { node in
                                hierarchySearchResult(node)
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                }
                .task(id: "\(document.selectedNodeID?.uuidString ?? "")|\(hierarchyFollowsSelection)") {
                    guard hierarchyFollowsSelection, let selectedID = document.selectedNodeID,
                          let path = document.root.hierarchyPath(to: selectedID) else { return }
                    let ancestors = Set(path.dropLast())
                    collapsedNodeIDs.subtract(ancestors)
                    expandedDeepNodeIDs.formUnion(ancestors)
                    if !normalizedHierarchySearch.isEmpty,
                       !hierarchyDirectMatches.contains(where: { $0.id == selectedID }) {
                        hierarchySearch = ""
                        hierarchyAppliedSearch = ""
                        hierarchySearchMatchIDs.removeAll()
                        hierarchyDirectMatches.removeAll()
                    }
                    await Task.yield()
                    guard !Task.isCancelled, document.selectedNodeID == selectedID else { return }
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(selectedID, anchor: .center) }
                }
            }
        }
        .task(id: hierarchySearch) {
            let pending = hierarchySearch
            if !pending.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try? await Task.sleep(for: .milliseconds(120))
            }
            guard !Task.isCancelled, pending == hierarchySearch else { return }
            hierarchyAppliedSearch = pending
            rebuildHierarchySearchIndex()
        }
    }

    private func hierarchySearchResult(_ node: LevelNode) -> some View {
        let isSelected = document.selectedNodeIDs.contains(node.id)
        return Button {
            document.select(node.id)
            hierarchySelectionAnchorID = node.id
        } label: {
            HStack(spacing: 7) {
                Rectangle()
                    .fill(Color.editorSecondaryText.opacity(0.25))
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(hierarchyDisplayName(for: node))
                        .font(.system(size: 11))
                        .lineLimit(1)
                    Text(node.kind.rawValue)
                        .font(.system(size: 9))
                        .foregroundStyle(Color.editorSecondaryText)
                }
                Spacer()
            }
            .foregroundStyle(Color.editorPrimaryText)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(isSelected ? Color.editorHierarchySelectionBackground : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .id(node.id)
    }

    /// Room layouts are virtual hierarchy groups. Nodes stay in their original
    /// XML-safe tree, while creators get the Start/Middle/Finish ownership view
    /// they actually need. Selecting a layout selects all objects it owns.
    private var roomLayoutHierarchySummary: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "square.3.layers.3d")
                Text("Room Layouts")
                    .font(.system(size: 11, weight: .bold))
                Spacer()
                Text("virtual groups")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.editorSecondaryText)
            }
            .foregroundStyle(Color.editorPrimaryText)

            ForEach(RoomLayoutSection.authoringCases) { section in
                let options = document.roomLayoutOptions(in: section)
                if !options.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Label(section.rawValue, systemImage: section.icon)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(section.color)
                        ForEach(options) { option in
                            Button {
                                document.activateRoomLayout(option)
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: document.editingRoomLayout == option.key ? "pencil.circle.fill" : "circle")
                                        .font(.system(size: 9))
                                    Text(option.key.displayName)
                                        .lineLimit(1)
                                    Spacer()
                                    Text("\(option.nodeIDs.count)")
                                        .foregroundStyle(Color.editorSecondaryText)
                                }
                                .font(.system(size: 10))
                                .foregroundStyle(Color.editorPrimaryText.opacity(0.8))
                                .padding(.leading, 15)
                                .padding(.vertical, 2)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.accentColor.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.accentColor.opacity(0.2), lineWidth: 1))
    }

    private var normalizedHierarchySearch: String {
        hierarchyAppliedSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func hierarchyItem(_ node: LevelNode, depth: Int, search: String) -> AnyView {
        guard hierarchyNodeMatchesSearch(node, search: search) else {
            return AnyView(EmptyView())
        }
        let isSelected = document.selectedNodeIDs.contains(node.id)
        let visibleChildren = hierarchyVisibleChildren(for: node, search: search)
        let hasChildren = !visibleChildren.isEmpty
        let startsCollapsedForPerformance = hasChildren && depth >= 3 && !expandedDeepNodeIDs.contains(node.id)
        let isFiltering = !search.isEmpty
        let isCollapsed = isFiltering ? false : (collapsedNodeIDs.contains(node.id) || startsCollapsedForPerformance)
        return AnyView(
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    if hasChildren {
                        Button {
                            if isCollapsed {
                                expandedDeepNodeIDs.insert(node.id)
                                collapsedNodeIDs.remove(node.id)
                            } else {
                                expandedDeepNodeIDs.remove(node.id)
                                collapsedNodeIDs.insert(node.id)
                            }
                        } label: {
                            Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Color.editorSecondaryText)
                                .frame(width: 14, height: 18)
                        }
                        .buttonStyle(.plain)
                        .focusable(false)
                    } else {
                        Color.clear.frame(width: 14, height: 18)
                    }

                    Button {
                        document.setHidden(!node.metadata.isHidden, for: node.id)
                    } label: {
                        Image(systemName: node.metadata.isHidden ? "eye.slash" : "eye")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.editorSecondaryText.opacity(node.metadata.isHidden ? 0.55 : 1))
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.plain)
                    .focusable(false)

                    HStack(spacing: 6) {
                        ForEach(0..<depth, id: \.self) { _ in
                            Color.clear.frame(width: 10)
                        }
                        Rectangle()
                            .fill(Color.editorSecondaryText.opacity(0.25))
                            .frame(width: 8, height: 8)
                        Text(hierarchyDisplayName(for: node))
                            .font(.system(size: 11))
                            .foregroundStyle(Color.editorPrimaryText.opacity(node.metadata.isHidden ? 0.38 : (isSelected ? 0.92 : 0.72)))
                            .textSelection(.disabled)
                        Spacer()
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(isSelected ? Color.editorHierarchySelectionBackground : .clear)
                    .overlay {
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(isSelected ? Color.editorHierarchySelectionStroke : Color.clear, lineWidth: 1)
                    }
                    .cornerRadius(4)
                    .contentShape(Rectangle())
                    .overlay(
                        HierarchyClickCatcher { modifiers in
                            NSApp.keyWindow?.makeFirstResponder(nil)
                            selectHierarchyNode(node.id, modifiers: modifiers)
                        }
                    )
                    .onDrag {
                        NSItemProvider(object: node.id.uuidString as NSString)
                    }
                    .onDrop(of: [UTType.plainText], isTargeted: nil) { providers in
                        reparentHierarchyDrop(providers: providers, onto: node.id)
                    }
                }
                .id(node.id)

            }
        )
    }

    private var visibleHierarchyRows: [(node: LevelNode, depth: Int)] {
        var rows: [(node: LevelNode, depth: Int)] = []
        func visit(_ node: LevelNode, depth: Int) {
            rows.append((node, depth))
            guard !collapsedNodeIDs.contains(node.id),
                  depth < 3 || expandedDeepNodeIDs.contains(node.id) else { return }
            for child in hierarchyVisibleChildren(for: node, search: "") {
                visit(child, depth: depth + 1)
            }
        }
        visit(document.root, depth: 0)
        return rows
    }

    private func hierarchyVisibleChildren(for node: LevelNode, search: String) -> [LevelNode] {
        let children = node.children.filter { child in
            search.isEmpty ? (!isHierarchyInternalVisual(child) || document.selectedNodeIDs.contains(child.id)) : true
        }
        guard !search.isEmpty else { return children }
        return children.filter { hierarchyNodeMatchesSearch($0, search: search) }
    }

    private func hierarchyNodeMatchesSearch(_ node: LevelNode, search: String) -> Bool {
        guard !search.isEmpty else { return true }
        return hierarchySearchMatchIDs.contains(node.id)
    }

    /// Builds descendant-aware search results once per query. The previous
    /// implementation recursively searched the same subtrees for every visible
    /// row, which became quadratic on imported rooms.
    private func rebuildHierarchySearchIndex() {
        let search = normalizedHierarchySearch
        guard !search.isEmpty else {
            hierarchySearchMatchIDs.removeAll()
            hierarchyDirectMatches.removeAll()
            return
        }
        let start = CFAbsoluteTimeGetCurrent()
        var matches: Set<LevelNode.ID> = []
        var blobs = hierarchySearchBlobs
        var directMatches: [LevelNode] = []
        @discardableResult
        func visit(_ node: LevelNode) -> Bool {
            let blob = blobs[node.id] ?? hierarchySearchBlob(for: node)
            blobs[node.id] = blob
            let directMatch = blob.contains(search)
            if directMatch,
               node.kind != .document,
               node.kind != .track,
               node.kind != .factor,
               directMatches.count < 250 {
                directMatches.append(node)
            }
            var matched = directMatch
            for child in node.children where visit(child) {
                matched = true
            }
            if matched { matches.insert(node.id) }
            return matched
        }
        visit(document.root)
        hierarchySearchBlobs = blobs
        hierarchySearchMatchIDs = matches
        hierarchyDirectMatches = directMatches
        RoomWeaverDiagnostics.shared.performanceSample(
            operation: "Hierarchy search",
            milliseconds: (CFAbsoluteTimeGetCurrent() - start) * 1_000,
            detail: "query=\(search)"
        )
    }

    private func hierarchySearchBlob(for node: LevelNode) -> String {
        [
            node.name,
            hierarchyDisplayName(for: node),
            node.kind.rawValue,
            node.metadata.className,
            node.metadata.filename,
            node.metadata.tag,
            node.xml.template,
            node.xml.choice,
            node.xml.variant
        ]
            .joined(separator: " ")
            .lowercased()
    }

    private func isHierarchyInternalVisual(_ node: LevelNode) -> Bool {
        node.metadata.isHidden &&
            node.kind == .image &&
            node.children.isEmpty &&
            (!node.metadata.imagePath.isEmpty || !node.previewPieces.isEmpty || !node.metadata.className.isEmpty)
    }

    private func hierarchyDisplayName(for node: LevelNode) -> String {
        let candidates = [
            node.name,
            node.metadata.className,
            node.metadata.filename,
            node.metadata.tag,
            node.kind.rawValue
        ]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let base = candidates.first(where: { !$0.isEmpty }) ?? "Unnamed Node"
        return node.metadata.isHidden ? "\(base) (hidden)" : base
    }

    private func reparentHierarchyDrop(providers: [NSItemProvider], onto parentID: LevelNode.ID) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else {
            return false
        }

        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard
                let rawID = object as? NSString,
                let draggedID = UUID(uuidString: rawID as String)
            else {
                return
            }

            DispatchQueue.main.async {
                reparentHierarchyNode(draggedID, onto: parentID)
            }
        }
        return true
    }

    private func reparentHierarchyDropToSceneRoot(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else {
            return false
        }

        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard
                let rawID = object as? NSString,
                let draggedID = UUID(uuidString: rawID as String),
                document.root.find(id: draggedID) != nil
            else {
                return
            }

            DispatchQueue.main.async {
                let draggedSelection = document.selectedNodeIDs.contains(draggedID)
                    ? document.selectedNodeIDs
                    : [draggedID]
                document.setSelected(ids: Array(draggedSelection))
                document.reparentSelectedNodesToSceneRoot()
            }
        }
        return true
    }

    /// Moves a node under a new parent in the hierarchy.
    ///
    /// Guard rails prevent parenting a node into itself/its descendants. If users
    /// drag something back to the scene root, use `reparentHierarchyDropToSceneRoot`.
    private func reparentHierarchyNode(_ draggedID: LevelNode.ID, onto parentID: LevelNode.ID) {
        guard draggedID != parentID else { return }
        guard document.root.find(id: draggedID) != nil, document.root.find(id: parentID) != nil else { return }

        let draggedSelection = document.selectedNodeIDs.contains(draggedID)
            ? document.selectedNodeIDs
            : [draggedID]

        document.setSelected(ids: Array(draggedSelection))
        document.reparentSelectedNodes(to: parentID)
    }

    /// Click behavior for hierarchy rows.
    ///
    /// Shift mimics Photoshop-style range selection over visible rows. Command
    /// toggles one row. Plain click selects exactly one node.
    private func selectHierarchyNode(_ id: LevelNode.ID, modifiers: NSEvent.ModifierFlags = NSEvent.modifierFlags) {
        if modifiers.contains(.shift) {
            let subtreeIDs = hierarchySubtreeIDs(for: id)
            if subtreeIDs.count > 1 {
                document.setSelected(ids: subtreeIDs)
                hierarchySelectionAnchorID = id
                return
            }

            let visibleIDs = visibleHierarchyIDs()
            if let anchorID = hierarchySelectionAnchorID ?? document.selectedNodeID,
               let anchorIndex = visibleIDs.firstIndex(of: anchorID),
               let targetIndex = visibleIDs.firstIndex(of: id) {
                let bounds = min(anchorIndex, targetIndex)...max(anchorIndex, targetIndex)
                let rangeIDs = Array(visibleIDs[bounds])
                document.setSelected(ids: rangeIDs)
                hierarchySelectionAnchorID = id
                return
            }
        }

        if modifiers.contains(.command) {
            document.toggleSelected(id)
            hierarchySelectionAnchorID = id
            return
        }

        document.select(id)
        hierarchySelectionAnchorID = id
    }

    private func visibleHierarchyIDs() -> [LevelNode.ID] {
        var ids: [LevelNode.ID] = []
        collectVisibleHierarchyIDs(
            from: document.root,
            depth: 0,
            search: normalizedHierarchySearch,
            into: &ids
        )
        return ids
    }

    private func collectVisibleHierarchyIDs(from node: LevelNode, depth: Int, search: String, into ids: inout [LevelNode.ID]) {
        guard hierarchyNodeMatchesSearch(node, search: search) else { return }
        ids.append(node.id)
        let hasChildren = !node.children.isEmpty
        let visibleChildren = hierarchyVisibleChildren(for: node, search: search)
        let startsCollapsedForPerformance = hasChildren && depth >= 3 && !expandedDeepNodeIDs.contains(node.id)
        let isFiltering = !search.isEmpty
        let isCollapsed = isFiltering ? false : (collapsedNodeIDs.contains(node.id) || startsCollapsedForPerformance)
        guard hasChildren, !isCollapsed else { return }
        for child in visibleChildren {
            collectVisibleHierarchyIDs(from: child, depth: depth + 1, search: search, into: &ids)
        }
    }

    private func hierarchySubtreeIDs(for id: LevelNode.ID) -> [LevelNode.ID] {
        guard let node = document.node(for: id) else { return [] }
        var ids: [LevelNode.ID] = []
        collectHierarchySubtreeIDs(from: node, into: &ids)
        return ids
    }

    private func collectHierarchySubtreeIDs(from node: LevelNode, into ids: inout [LevelNode.ID]) {
        ids.append(node.id)
        for child in node.children {
            collectHierarchySubtreeIDs(from: child, into: &ids)
        }
    }

    /// Properties inspector for the active selected node.
    ///
    /// The inspector edits `LevelNode` fields directly through document mutation
    /// helpers. Text fields commit on enter/focus loss and should not trigger
    /// canvas keyboard shortcuts while focused.
    private var propertiesPanel: some View {
        let selected = document.selectedNode

        return VStack(alignment: .leading, spacing: 10) {
            InspectorTextField(
                title: "Name",
                value: selected?.name ?? "",
                placeholder: "Nothing selected",
                onCommit: { document.updateSelectedText(name: $0) }
            )
            propertyRow("Type", selected?.kind.rawValue ?? "None")
            propertyRow("Group", selected?.kind.rawValue ?? "None")
            InspectorTextField(
                title: "Factor",
                value: selected?.factor ?? "",
                placeholder: "-",
                onCommit: { document.updateSelectedText(factor: $0) }
            )
            InspectorTextField(
                title: "Tag",
                value: selected?.metadata.tag ?? "",
                placeholder: "-",
                onCommit: { document.updateSelectedText(tag: $0) },
                suggestions: Vector2Tags.all
            )
            InspectorPickerField(
                title: "Layer",
                value: selected?.metadata.sortingLayer ?? "",
                options: Vector2SortingLayers.all,
                onCommit: { document.updateSelectedText(sortingLayer: $0) }
            )

            Divider().overlay(Color.white.opacity(0.08))

            InspectorNumberField(
                title: "X",
                value: selected?.transform?.x,
                onCommit: { document.updateSelectedTransform(x: $0) }
            )
            InspectorNumberField(
                title: "Y",
                value: selected?.transform?.y,
                onCommit: { document.updateSelectedTransform(y: $0) }
            )
            if TrapCatalog.isTrap(selected) {
                Label("Trap size and rotation are locked so visuals, triggers and damage stay aligned.", systemImage: "lock.shield")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.editorSecondaryText)
            } else {
                InspectorNumberField(
                    title: "Width",
                    value: selected?.transform?.width,
                    onCommit: { document.updateSelectedTransform(width: $0) }
                )
                InspectorNumberField(
                    title: "Height",
                    value: selected?.transform?.height,
                    onCommit: { document.updateSelectedTransform(height: $0) }
                )
                InspectorNumberField(
                    title: "Rotation",
                    value: selected?.transform.map { Int($0.rotation.rounded()) },
                    onCommit: { document.updateSelectedTransform(rotation: Double($0)) }
                )
            }
            if !propertyPreviewOptions.isEmpty {
                if propertyPreviewOptions.count > 1 {
                    Picker("Dynamic", selection: Binding(
                        get: {
                            propertyPreviewOptions.contains { $0.id == propertyPreviewSequenceID }
                                ? propertyPreviewSequenceID
                                : (propertyPreviewOptions.first?.id ?? "")
                        },
                        set: { propertyPreviewSequenceID = $0 }
                    )) {
                        ForEach(propertyPreviewOptions) { option in
                            Text(option.displayName).tag(option.id)
                        }
                    }
                }
                HStack {
                    Button {
                        if liftPreviewTimer == nil {
                            startLiftPreview()
                        } else {
                            stopLiftPreview(restore: true)
                        }
                    } label: {
                        Label(liftPreviewTimer == nil ? "Preview dynamic" : "Stop preview", systemImage: liftPreviewTimer == nil ? "play.fill" : "stop.fill")
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                }
            }
        }
        .padding(10)
    }

    private func startLiftPreview() {
        stopLiftPreview(restore: true)
        guard let option = propertyPreviewOptions.first(where: { $0.id == propertyPreviewSequenceID })
                ?? propertyPreviewOptions.first else { return }
        propertyPreviewSequenceID = option.id
        let tracks = option.members.compactMap { member -> PropertyPreviewTrack? in
            guard let node = document.root.find(id: member.nodeID),
                  let transform = node.transform,
                  let timeline = DynamicStudioImportedTimeline.parse(
                    node.metadata.dynamicXML,
                    x: transform.x,
                    y: transform.y,
                    width: transform.width,
                    height: transform.height,
                    rotation: transform.rotation,
                    transformationName: member.transformationName
                  ) else { return nil }
            return .init(nodeID: node.id, sourceTransform: transform, timeline: timeline)
        }
        guard !tracks.isEmpty else { return }
        propertyPreviewTracks = tracks
        let nodeID = tracks[0].nodeID
        let totalFrames = tracks.map(\.timeline.totalFrames).max() ?? 1
        let start = Date()
        liftPreviewNodeID = nodeID
        for track in tracks {
            dynamicLivePreviewTransforms[track.nodeID] = document.root.canvasTransform(
                for: track.nodeID,
                localTransform: track.sourceTransform
            )
        }

        liftPreviewTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 10.0, repeats: true) { timer in
            let elapsed = Date().timeIntervalSince(start)
            let frame = min(totalFrames, max(0, Int((elapsed * 60).rounded())))

            if document.selectedNodeID != nil {
                applyPropertyPreviewTracks(tracks, at: frame)
            }

            if frame >= totalFrames {
                timer.invalidate()
                liftPreviewTimer = nil
                for track in tracks {
                    dynamicLivePreviewTransforms.removeValue(forKey: track.nodeID)
                }
                propertyPreviewTracks.removeAll()
                liftPreviewNodeID = nil
            }
        }
    }

    private func rebuildPropertyPreviewOptions() {
        guard let selectedID = document.selectedNodeID else {
            propertyPreviewOptions = []
            propertyPreviewSequenceID = ""
            return
        }

        var targets: [LevelNode] = []
        var seen: Set<LevelNode.ID> = []
        func isSpatialDynamic(_ node: LevelNode) -> Bool {
            guard node.kind != .trigger, node.transform != nil else { return false }
            let xml = node.metadata.dynamicXML
            return xml.contains("<MoveInterval") || xml.contains("<RotationInterval") || xml.contains("<SizeInterval")
        }
        @discardableResult
        func collectSelectedBranch(_ node: LevelNode) -> Bool {
            var contains = node.id == selectedID
            for child in node.children where collectSelectedBranch(child) { contains = true }
            if contains, isSpatialDynamic(node), seen.insert(node.id).inserted { targets.append(node) }
            return contains
        }
        collectSelectedBranch(document.root)
        if let selected = document.root.find(id: selectedID) {
            for node in selected.allDescendantsIncludingSelf()
            where isSpatialDynamic(node) && seen.insert(node.id).inserted {
                targets.append(node)
            }
        }

        let individual = targets.flatMap { target in
            DynamicStudioImportedTimeline.transformationNames(in: target.metadata.dynamicXML).map { name in
                PropertyPreviewOption(
                    id: "\(target.id.uuidString)|\(name)",
                    displayName: "\(target.name): \(name)",
                    members: [.init(nodeID: target.id, transformationName: name)]
                )
            }
        }
        let memberByName = Dictionary(
            individual.flatMap(\.members).map { ($0.transformationName, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var synchronized: [PropertyPreviewOption] = []
        func collectTriggers(_ node: LevelNode) -> [LevelNode] {
            (node.kind == .trigger ? [node] : []) + node.children.flatMap(collectTriggers)
        }
        for trigger in collectTriggers(document.root) {
            let xml = trigger.metadata.sourceContentXML
            guard !xml.isEmpty,
                  let parsed = try? XMLDocument(xmlString: "<Root>\(xml)</Root>") else { continue }
            let choices = (try? parsed.nodes(forXPath: ".//Choose[@Order='Sync']")) ?? []
            for (index, choice) in choices.enumerated() {
                guard let element = choice as? XMLElement else { continue }
                let members = element.elements(forName: "Transform").compactMap {
                    $0.attribute(forName: "Name")?.stringValue.flatMap { memberByName[$0] }
                }
                guard !members.isEmpty else { continue }
                synchronized.append(.init(
                    id: "sync|\(trigger.id.uuidString)|\(index)",
                    displayName: "\(trigger.name) (runtime sync)",
                    members: members
                ))
            }
        }
        propertyPreviewOptions = synchronized.isEmpty ? individual : synchronized
        if !propertyPreviewOptions.contains(where: { $0.id == propertyPreviewSequenceID }) {
            propertyPreviewSequenceID = propertyPreviewOptions.first?.id ?? ""
        }
    }

    private func applyPropertyPreviewTracks(_ tracks: [PropertyPreviewTrack], at frame: Int) {
        for (nodeID, nodeTracks) in Dictionary(grouping: tracks, by: \.nodeID) {
            guard let source = nodeTracks.first?.sourceTransform else { continue }
            let local: LevelNode.Transform
            if nodeTracks.count == 1, let pose = nodeTracks[0].timeline.pose(at: frame) {
                local = .init(
                    x: pose.x,
                    y: pose.y,
                    width: pose.width,
                    height: pose.height,
                    rotation: pose.rotation
                )
            } else {
                var composed = source
                var widthScale = 1.0
                var heightScale = 1.0
                for track in nodeTracks {
                    guard let first = track.timeline.keyframes.first,
                          let pose = track.timeline.pose(at: frame) else { continue }
                    composed.x += pose.x - first.x
                    composed.y += pose.y - first.y
                    composed.rotation += pose.rotation - first.rotation
                    widthScale *= Double(pose.width) / Double(max(1, first.width))
                    heightScale *= Double(pose.height) / Double(max(1, first.height))
                }
                composed.width = max(1, Int((Double(source.width) * widthScale).rounded()))
                composed.height = max(1, Int((Double(source.height) * heightScale).rounded()))
                local = composed
            }
            dynamicLivePreviewTransforms[nodeID] = document.root.canvasTransform(for: nodeID, localTransform: local)
        }
    }

    private func stopLiftPreview(restore: Bool) {
        liftPreviewTimer?.invalidate()
        liftPreviewTimer = nil
        if restore, let nodeID = liftPreviewNodeID {
            dynamicLivePreviewTransforms.removeValue(forKey: nodeID)
        }
        if restore {
            for track in propertyPreviewTracks {
                dynamicLivePreviewTransforms.removeValue(forKey: track.nodeID)
            }
        }
        propertyPreviewTracks.removeAll()
        liftPreviewNodeID = nil
    }

    private func interpolatedPose(
        in timeline: DynamicStudioImportedTimeline,
        at frame: Int
    ) -> DynamicStudioImportedKeyframe? {
        timeline.pose(at: frame)
    }

    private func liftPreviewMotion(for node: LevelNode) -> MovePreview? {
        firstMoveInterval(in: node.metadata.dynamicXML)
    }

    private func firstMoveInterval(in dynamicXML: String) -> MovePreview? {
        guard !dynamicXML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let document = try? XMLDocument(xmlString: "<Root>\(dynamicXML)</Root>", options: []) else {
            return nil
        }

        let moveNodes = (try? document.nodes(forXPath: ".//Transformation[@Name='Move_Lift']/MoveInterval")) ?? []
        let fallbackNodes = (try? document.nodes(forXPath: ".//MoveInterval")) ?? []
        guard let move = (moveNodes.first ?? fallbackNodes.first) as? XMLElement else {
            return nil
        }

        let frames = max(1, Int(parseDouble(attribute("Frames", on: move)) ?? 100))
        let points = childElements(of: move)
            .filter { $0.name == "Point" }
            .compactMap { point -> (x: Double, y: Double)? in
                guard let x = parseDouble(attribute("X", on: point)),
                      let y = parseDouble(attribute("Y", on: point)) else { return nil }
                return (x, y)
            }
        guard let start = points.first,
              let end = points.last,
              points.count >= 2 else {
            return nil
        }

        let type = attribute("Type", on: move) ?? "Bezier"
        let deltas: [(x: Double, y: Double)]
        if type == "Sin" {
            let quarters = firstElement(fromXPath: "./Quarters", on: move)
                .flatMap { attribute("Value", on: $0) } ?? "2Quarters"
            deltas = sinusPoints(from: start, to: end, frames: frames, quarters: quarters)
        } else {
            deltas = bezierPoints(points: points, frames: frames)
        }

        guard !deltas.isEmpty else { return nil }
        return MovePreview(deltas: deltas, duration: max(0.25, Double(frames) / 60.0))
    }

    private func sinusPoints(from start: (x: Double, y: Double), to end: (x: Double, y: Double), frames: Int, quarters: String) -> [(x: Double, y: Double)] {
        let sequence = quartersSequence(quarters)
        guard !sequence.isEmpty else { return [start, end] }
        let increasing = sequence.reduce(0) { partial, quarter in
            partial + ((quarter == 2 || quarter == 3) ? -1 : 1)
        }
        guard increasing > 0 else { return [start, end] }

        let step = ((end.x - start.x) / Double(increasing), (end.y - start.y) / Double(increasing))
        var anchors: [(x: Double, y: Double)] = []
        var cursor = start
        for quarter in sequence {
            if quarter == 2 || quarter == 3 {
                cursor = (cursor.x - step.0, cursor.y - step.1)
            } else {
                cursor = (cursor.x + step.0, cursor.y + step.1)
            }
            anchors.append(cursor)
        }

        var result: [(x: Double, y: Double)] = []
        let framesPerQuarter = max(1, frames / max(1, sequence.count))
        var segmentStart = start
        for (index, quarter) in sequence.enumerated() {
            let destination = anchors[index]
            let slowAtStart = quarter == 2 || quarter == 4
            result.append(contentsOf: quarterPoints(from: segmentStart, to: destination, frames: framesPerQuarter, slowAtStart: slowAtStart))
            segmentStart = destination
        }
        result.append(end)
        return result
    }

    private func quarterPoints(from start: (x: Double, y: Double), to end: (x: Double, y: Double), frames: Int, slowAtStart: Bool) -> [(x: Double, y: Double)] {
        var result: [(x: Double, y: Double)] = []
        var angle = slowAtStart ? -Double.pi / 2 : 0
        let step = Double.pi / 2 / Double(max(1, frames))
        for _ in 0..<max(1, frames) {
            var amount = sin(angle)
            if slowAtStart {
                amount += 1
            }
            result.append((
                start.x + (end.x - start.x) * amount,
                start.y + (end.y - start.y) * amount
            ))
            angle += step
        }
        return result
    }

    private func quartersSequence(_ raw: String) -> [Int] {
        switch raw {
        case "1QuarterAcc": return [4]
        case "1QuarterDec": return [1]
        case "2Quarters": return [4, 1]
        case "2QuartersFastSlowFast": return [1, 4]
        case "3Quarters": return [3, 4, 1]
        default: return [4, 1]
        }
    }

    private func bezierPoints(points: [(x: Double, y: Double)], frames: Int) -> [(x: Double, y: Double)] {
        guard points.count >= 2 else { return points }
        return (0...max(1, frames)).map { frame in
            let t = Double(frame) / Double(max(1, frames))
            return deCasteljau(points, t: t)
        }
    }

    private func deCasteljau(_ points: [(x: Double, y: Double)], t: Double) -> (x: Double, y: Double) {
        guard points.count > 1 else { return points.first ?? (0, 0) }
        let next = zip(points.dropLast(), points.dropFirst()).map { lhs, rhs in
            (
                lhs.x + (rhs.x - lhs.x) * t,
                lhs.y + (rhs.y - lhs.y) * t
            )
        }
        return deCasteljau(next, t: t)
    }

    private func parseDouble(_ raw: String?) -> Double? {
        guard let raw, !raw.isEmpty else { return nil }
        return Double(raw.replacingOccurrences(of: ",", with: "."))
    }

    private func attribute(_ name: String, on element: XMLElement) -> String? {
        element.attribute(forName: name)?.stringValue
    }

    private func childElements(of element: XMLElement) -> [XMLElement] {
        element.children?.compactMap { $0 as? XMLElement } ?? []
    }

    private func firstElement(fromXPath xpath: String, on element: XMLElement) -> XMLElement? {
        (try? element.nodes(forXPath: xpath))?.compactMap { $0 as? XMLElement }.first
    }

    private var xmlPanel: some View {
        let selected = document.selectedNode

        return VStack(alignment: .leading, spacing: 10) {
            InspectorTextField(
                title: "Template",
                value: selected?.xml.template ?? "",
                placeholder: "-",
                onCommit: { document.updateSelectedText(template: $0) }
            )
            InspectorTextField(
                title: "Choice",
                value: selected?.xml.choice ?? "",
                placeholder: "-",
                onCommit: { document.updateSelectedText(choice: $0) }
            )
            InspectorTextField(
                title: "Variant",
                value: selected?.xml.variant ?? "",
                placeholder: "-",
                onCommit: { document.updateSelectedText(variant: $0) }
            )
            propertyRow("Blend", selected?.xml.blend ?? "-")
            InspectorTextField(
                title: "Class",
                value: selected?.metadata.className ?? "",
                placeholder: "-",
                onCommit: { document.updateSelectedText(className: $0) }
            )
            if selected?.kind == .image, selected?.metadata.imagePath.lowercased().hasSuffix(".gif") == true {
                InspectorTextField(
                    title: "Visual ID",
                    value: selected?.metadata.sourceAttributes["EditorVisualGroup"] ?? "",
                    placeholder: "For quest artwork changes",
                    onCommit: { value in
                        guard let id = document.selectedNodeID else { return }
                        document.root.update(id: id) { node in
                            let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
                            if clean.isEmpty { node.metadata.sourceAttributes.removeValue(forKey: "EditorVisualGroup") }
                            else { node.metadata.sourceAttributes["EditorVisualGroup"] = clean }
                        }
                    }
                )
            }
            InspectorTextField(
                title: "File",
                value: selected?.metadata.filename ?? "",
                placeholder: "-",
                onCommit: { document.updateSelectedText(filename: $0) }
            )
        }
        .padding(10)
    }

    private var xmlEditorPanel: some View {
        VStack(spacing: 8) {
            Text("XML Assistant · Click an error line for help")
                .font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            TriggerXMLCodeEditor(text: $rawXMLDraft, predictiveCoding: xmlPredictiveCoding, sceneXML: true, templates: rawXMLAssistantIndex, review: rawXMLReview)
                .background(Color.platformControlBackground.opacity(0.75))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .onAppear(perform: syncRawXMLDraftIfNeeded)
                .onChange(of: document.selectedNodeID) { _, _ in
                    previousCheckedRawXML = nil
                    syncRawXMLDraft(force: true)
                }

            let diagnostics = rawXMLReview.source == rawXMLDraft ? rawXMLDiagnostics : []
            if let first = diagnostics.first {
                Label(first.message, systemImage: first.severity == .error ? "xmark.octagon.fill" : first.severity == .warning ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 10)).foregroundStyle(first.severity == .error ? .red : first.severity == .warning ? .orange : .green).frame(maxWidth: .infinity, alignment: .leading)
            }

            if !rawXMLError.isEmpty {
                Text(rawXMLError)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if rawXMLApplied {
                Label("Applied to the selected object", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.green)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Button("Apply XML") {
                    applyRawXMLDraft()
                }.disabled(document.selectedNodeID == nil || TriggerRuntimeSchema.isEmptyXMLDraft(rawXMLDraft))
                Button("Copy XML") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(rawXMLDraft, forType: .string)
                }
                Button("Reset") {
                    syncRawXMLDraft(force: true)
                }
                Spacer()
            }
        }
        .padding(10)
        .task(id: "\(gameDirectory):\(xmlTemplateReload)") {
            let roots = Vector2AssetCatalog.xmlAssistantTemplateRoots(gameDirectory: gameDirectory)
            let packages = Vector2AssetCatalog.xmlAssistantPackageRoots(gameDirectory: gameDirectory)
            let index = await Task.detached(priority: .utility) { XMLAssistantTemplateIndex.load(roots: roots, packageRoots: packages) }.value
            guard !Task.isCancelled else { return }
            var enriched = index
            enriched.references["Texture"] = rawXMLKnownTextures.sorted()
            enriched.references["ObjectClass"] = Array(Set((index.references["ObjectClass"] ?? []) + rawXMLKnownLibraryObjects)).sorted()
            xmlTemplateIndex = enriched
        }
        .onReceive(NotificationCenter.default.publisher(for: .vector2AssetCatalogChanged)) { _ in xmlTemplateReload += 1 }
        .task(id: XMLAssistantDraftRequest(source: rawXMLDraft, templates: rawXMLAssistantIndex, scopeID: String(describing: document.selectedNodeID))) {
            let source = rawXMLDraft
            let templates = rawXMLAssistantIndex
            let previous = previousCheckedRawXML
            let selection = document.selectedNodeID
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            let catalogue = ["Events": TriggerRuntimeSchema.events, "Conditions": TriggerRuntimeSchema.conditions,
                             "Actions": TriggerRuntimeSchema.actions, "Init": TriggerRuntimeSchema.actions]
            let review = await Task.detached(priority: .utility) {
                TriggerRuntimeSchema.reviewDraft(source, catalogues: catalogue, requiresTriggerRoot: false, templates: templates, previousSource: previous)
            }.value
            guard !Task.isCancelled, source == rawXMLDraft, selection == document.selectedNodeID else { return }
            rawXMLReview = review
            if review.issues.isEmpty && !TriggerRuntimeSchema.isEmptyXMLDraft(source) { previousCheckedRawXML = source }
            rawXMLDiagnostics = XMLAuthoringIntelligence.validate(source, knownLibraryObjects: rawXMLKnownLibraryObjects, knownTextures: rawXMLKnownTextures)
        }
    }

    private func refreshRawXMLReferenceIndex() {
        let assets = Vector2AssetCatalog.load().flatMap(\.assets)
        rawXMLKnownLibraryObjects = Set(assets.filter { $0.kind == .libraryObject }.map { $0.libraryObjectName.isEmpty ? $0.name : $0.libraryObjectName })
        rawXMLKnownTextures = Set(assets.filter { $0.kind == .texture }.flatMap { [$0.name, $0.className] })
    }

    private var layerPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            propertyRow("Sorting Layer", document.selectedNode?.metadata.sortingLayer ?? "Wall")
            propertyRow("Tag", document.selectedNode?.metadata.tag ?? "None")
            propertyRow("Depth", document.selectedNode?.kind.rawValue ?? "None")
            propertyRow("Visibility", "Shown")
        }
        .padding(10)
    }

    /// Raw XML preview for the selected node.
    ///
    /// This uses the same exporter as full document export, so it is useful for
    /// sanity-checking whether a selected node will serialize correctly.
    private var rawXML: String {
        guard let selected = document.selectedNode else {
            return "<!-- Nothing selected -->"
        }
        return document.exportedSelectionXML(for: selected.id)
    }

    private func syncRawXMLDraftIfNeeded() {
        if rawXMLSelectedID != document.selectedNodeID {
            syncRawXMLDraft(force: true)
        }
    }

    private func syncRawXMLDraft(force: Bool = false) {
        guard force || rawXMLSelectedID != document.selectedNodeID else { return }
        previousCheckedRawXML = nil
        rawXMLDraft = rawXML
        rawXMLSelectedID = document.selectedNodeID
        rawXMLError = ""
        rawXMLApplied = false
    }

    private func applyRawXMLDraft() {
        let diagnostics = XMLAuthoringIntelligence.validate(rawXMLDraft, knownLibraryObjects: rawXMLKnownLibraryObjects, knownTextures: rawXMLKnownTextures)
        if let error = diagnostics.first(where: { $0.severity == .error }) {
            rawXMLError = error.message
            rawXMLApplied = false
            return
        }
        let baseURL = document.sourcePath.map { URL(fileURLWithPath: $0).deletingLastPathComponent() }
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        guard let node = XMLSceneParser.parseNodeXML(rawXMLDraft, baseURL: baseURL) else {
            rawXMLError = "XML did not parse into a Vector 2 scene node. Use Project Manager → Trigger Designer for a valid starting point."
            rawXMLApplied = false
            return
        }
        document.replaceSelectedNode(with: node)
        rawXMLDraft = document.exportedSelectionXML(for: node.id)
        rawXMLSelectedID = node.id
        rawXMLError = ""
        rawXMLApplied = true
    }

    private func propertyRow(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(key.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color.editorSecondaryText)
                .frame(width: 72, alignment: .leading)
            Text(value)
                .font(.system(size: 11))
                .foregroundStyle(Color.editorPrimaryText.opacity(0.82))
                .textSelection(.disabled)
            Spacer()
        }
    }
}

private struct AITrickPickerSheet: View {
    let gameDirectory: String
    let selectedName: String
    let onSelect: (String) -> Void
    let onClose: () -> Void

    @State private var tricks: [TrickPreviewMove] = []
    @State private var search = ""

    private var filteredTricks: [TrickPreviewMove] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return tricks }
        return tricks.filter {
            $0.name.localizedCaseInsensitiveContains(needle)
                || $0.fileName.localizedCaseInsensitiveContains(needle)
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Choose AI Trick").font(.title2.bold())
                    Text("Loaded from Vector 2's move library.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close", action: onClose)
            }
            TextField("Search every trick", text: $search)
                .textFieldStyle(.roundedBorder)
            List(filteredTricks) { trick in
                Button {
                    onSelect(trick.name)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(trick.name).fontWeight(.semibold)
                            Text(trick.fileName)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if trick.name.caseInsensitiveCompare(selectedName) == .orderedSame {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if tricks.isEmpty {
                Text("No tricks were found. Set the Vector 2 project folder in Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .frame(width: 620, height: 640)
        .onAppear {
            tricks = TrickPreviewCatalog(gameDirectory: gameDirectory)
                .loadMoves()
                .filter(\.isTrick)
        }
    }
}

private struct AIAnimationPickerSheet: View {
    let gameDirectory: String
    let selectedName: String
    let onSelect: (String) -> Void
    let onClose: () -> Void

    @State private var animations: [TrickPreviewMove] = []
    @State private var search = ""

    private var filteredAnimations: [TrickPreviewMove] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return animations }
        return animations.filter {
            $0.name.localizedCaseInsensitiveContains(needle)
                || $0.fileName.localizedCaseInsensitiveContains(needle)
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Choose Animation").font(.title2.bold())
                    Text("Animations from Vector 2's move library.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close", action: onClose)
            }
            TextField("Search every animation", text: $search)
                .textFieldStyle(.roundedBorder)
            List(filteredAnimations) { animation in
                Button {
                    onSelect(animation.name)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(animation.name).fontWeight(.semibold)
                            Text(animation.fileName)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if animation.name.caseInsensitiveCompare(selectedName) == .orderedSame {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if animations.isEmpty {
                Text("No animations were found. Set the Vector 2 project folder in Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .frame(width: 620, height: 640)
        .onAppear {
            animations = TrickPreviewCatalog(gameDirectory: gameDirectory).loadMoves()
        }
    }
}

/// Text input used by the inspector.
///
/// It intentionally owns a local draft string so typing does not mutate the
/// document on every keystroke. Commit/cancel behavior keeps undo history sane.
struct InspectorTextField: View {
    let title: String
    let value: String
    let placeholder: String
    let onCommit: (String) -> Void
    var suggestions: [String] = []

    @State private var text = ""
    @State private var isEditing = false
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(alignment: .top) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color.editorSecondaryText)
                .frame(width: 72, alignment: .leading)

            Group {
                if isEditing {
                    TextField("", text: $text)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.editorPrimaryText.opacity(0.82))
                        .focused($isFocused)
                        .onAppear {
                            text = value
                            isFocused = true
                        }
                        .onSubmit {
                            commit()
                        }
                        .onExitCommand {
                            cancel()
                        }
                } else {
                    if suggestions.isEmpty {
                        Button {
                            text = value
                            isEditing = true
                        } label: {
                            readOnlyLabel
                        }
                        .buttonStyle(.plain)
                    } else {
                        Menu {
                            ForEach(suggestions, id: \.self) { suggestion in
                                Button(suggestion) {
                                    text = suggestion
                                    onCommit(suggestion)
                                }
                            }

                            Divider()

                            Button("Custom...") {
                                text = value
                                isEditing = true
                            }
                        } label: {
                            HStack {
                                readOnlyLabel
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(Color.editorSecondaryText)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.platformControlBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.editorHairline, lineWidth: 1)
            )
            .onChange(of: value) { _, newValue in
                if !isEditing {
                    text = newValue
                }
            }
            .onChange(of: isFocused) { _, focused in
                if isEditing && !focused {
                    commit()
                }
            }

            Spacer()
        }
    }

    private var readOnlyLabel: some View {
        Text(value.isEmpty ? placeholder : value)
            .font(.system(size: 11))
            .foregroundStyle(value.isEmpty ? Color.editorSecondaryText.opacity(0.65) : Color.editorPrimaryText.opacity(0.82))
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
    }

    private func commit() {
        onCommit(text)
        isEditing = false
        isFocused = false
    }

    private func cancel() {
        text = value
        isEditing = false
        isFocused = false
    }
}

struct InspectorPickerField: View {
    let title: String
    let value: String
    let options: [String]
    let onCommit: (String) -> Void

    var body: some View {
        HStack(alignment: .top) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color.editorSecondaryText)
                .frame(width: 72, alignment: .leading)

            Menu {
                ForEach(options, id: \.self) { option in
                    Button(option) {
                        onCommit(option)
                    }
                }
            } label: {
                HStack {
                    Text(value.isEmpty ? "Default" : value)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.editorPrimaryText.opacity(0.82))
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.editorSecondaryText)
                }
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.platformControlBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.editorHairline, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)

            Spacer()
        }
    }
}

/// Numeric inspector field for position/size/rotation.
///
/// Values are strings while editing so users can type partial values without the
/// model snapping back mid-keystroke.
struct InspectorNumberField: View {
    let title: String
    let value: Int?
    let onCommit: (Int) -> Void

    @State private var text = ""
    @State private var isEditing = false
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(alignment: .top) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color.editorSecondaryText)
                .frame(width: 72, alignment: .leading)

            Group {
                if isEditing {
                    TextField("", text: $text)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.editorPrimaryText.opacity(0.82))
                        .focused($isFocused)
                        .onAppear {
                            text = value.map(String.init) ?? ""
                            isFocused = true
                        }
                        .onSubmit {
                            commit()
                        }
                        .onExitCommand {
                            cancel()
                        }
                } else {
                    Button {
                        text = value.map(String.init) ?? ""
                        isEditing = true
                    } label: {
                        Text(value.map(String.init) ?? "")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.editorPrimaryText.opacity(0.82))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.platformControlBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.editorHairline, lineWidth: 1)
            )
            .onChange(of: value) { _, newValue in
                if !isEditing {
                    text = newValue.map(String.init) ?? ""
                }
            }
            .onChange(of: isFocused) { _, focused in
                if isEditing && !focused {
                    commit()
                }
            }

            Spacer()
        }
    }

    private func commit() {
        defer {
            isEditing = false
            isFocused = false
        }
        guard let parsed = Int(text) else { return }
        onCommit(parsed)
    }

    private func cancel() {
        text = value.map(String.init) ?? ""
        isEditing = false
        isFocused = false
    }
}

/// Tabs at the top of the right inspector dock.
///
/// Changes the active panel through `RightSidebarTab`.
struct RightTabs: View {
    @Binding var selectedTab: RightSidebarTab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(RightSidebarTab.allCases, id: \.self) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    Text(tab.rawValue)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(selectedTab == tab ? Color.editorPrimaryText.opacity(0.88) : Color.editorSecondaryText)
                        .frame(maxWidth: .infinity)
                        .frame(height: 28)
                        .background(selectedTab == tab ? Color.editorSelectedTabBackground : Color.editorUnselectedTabBackground)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Reusable titled section in the right dock.
///
/// Keeps Properties/XML/Hierarchy panels visually consistent.
struct DockSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.editorSecondaryText)
                Spacer()
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Color.editorSectionHeaderBackground)

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color.platformWindowBackground)
        }
    }
}

/// One asset browser entry.
///
/// The browser, placement tools and import preview share this asset identity.
/// Entries can be textures, library XML objects or Unity prefabs.
