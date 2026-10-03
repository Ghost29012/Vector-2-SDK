//
//  RoomLayoutPanelView.swift
//  Vector2 level editor
//
//  Room Layouts controls. XML mapping lives in RoomLayoutEditor.swift.
//

import SwiftUI

struct RoomLayoutEditorPanel: View {
    @Binding var document: LevelDocument
    @Binding var isPresented: Bool
    @State private var draftNames: [RoomLayoutSection: String] = [:]
    @State private var message = "Select some objects, then add them as a layout."
    @State private var detailsExpanded = true

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            layoutLanes
            if let group = document.selectedSharedObjectsGroup {
                Divider()
                sharedObjectsEditor(group)
            } else if detailsExpanded, let option = selectedOption {
                Divider()
                details(for: option)
            }
            Divider()
            footer
        }
        .background(Color.editorChromeBackground)
        .onAppear { document.prepareRoomLayouts() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Label("Room Layouts", systemImage: "square.3.layers.3d")
                .font(.system(size: 13, weight: .bold))
            Text("Build alternate starts, routes and finishes without touching XML. Moving pieces stay on the scene.")
                .font(.system(size: 10))
                .foregroundStyle(Color.editorSecondaryText)
            Spacer()
            validationBadge
            Button {
                runLayoutCheck()
            } label: {
                Label("Test All Layouts", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            Toggle("Ghost others", isOn: $document.ghostInactiveRoomLayouts)
                .toggleStyle(.switch)
                .controlSize(.mini)
            Button {
                if let error = document.createSharedObjectsGroup() {
                    message = error
                } else {
                    message = "Created Shared Objects. Choose exactly where the group appears."
                }
            } label: {
                Label("Create Shared Objects", systemImage: "square.stack.3d.up.fill")
            }
            .controlSize(.small)
            .disabled(document.effectiveSelectedNodeIDs.isEmpty || document.selectedSharedObjectsGroup != nil)
            Button { isPresented = false } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .frame(height: 42)
    }

    private var validationBadge: some View {
        let issues = document.roomLayoutIssues
        return Label(
            issues.isEmpty ? "\(document.roomLayoutCombinationCount) routes ready" : "\(issues.count) to fix",
            systemImage: issues.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
        )
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(issues.isEmpty ? .green : .orange)
    }

    private var layoutLanes: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(RoomLayoutSection.authoringCases) { section in
                sectionColumn(section)
                if section != RoomLayoutSection.authoringCases.last { Divider() }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func sectionColumn(_ section: RoomLayoutSection) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label(section.rawValue.uppercased(), systemImage: section.icon)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(section.color)
                Text("\(document.roomLayoutOptions(in: section).count)")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.editorSecondaryText)
                Spacer()
            }

            ScrollView(.horizontal, showsIndicators: true) {
                HStack(spacing: 7) {
                    ForEach(document.roomLayoutOptions(in: section)) { option in
                        optionCard(option)
                    }
                    if document.roomLayoutOptions(in: section).isEmpty {
                        emptyCard(section)
                    }
                }
            }

            HStack(spacing: 5) {
                TextField(section.exampleName, text: Binding(
                    get: { draftNames[section, default: ""] },
                    set: { draftNames[section] = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 10))

                Button {
                    createLayout(in: section)
                } label: {
                    Image(systemName: "plus")
                }
                .help("Create this layout from the selected objects")
                .controlSize(.small)
                .disabled(!canCreate(in: section))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func emptyCard(_ section: RoomLayoutSection) -> some View {
        HStack(spacing: 7) {
            Image(systemName: section.icon)
                .font(.system(size: 16))
                .foregroundStyle(section.color.opacity(0.7))
            Text(section.emptyHint)
                .font(.system(size: 9))
                .foregroundStyle(Color.editorSecondaryText)
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 9)
        .frame(width: 185, height: 54, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.platformControlBackground.opacity(0.55)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3])).foregroundStyle(Color.editorHairline))
    }

    private func optionCard(_ option: RoomLayoutOption) -> some View {
        let active = document.activeRoomLayoutVariants[option.key.section]?.caseInsensitiveCompare(option.key.variant) == .orderedSame
        let editing = document.editingRoomLayout == option.key
        return Button {
            document.activateRoomLayout(option)
            detailsExpanded = true
            message = "Editing \(option.key.displayName). New objects automatically join it."
        } label: {
            HStack(spacing: 8) {
                RoomLayoutMiniMap(nodes: option.nodeIDs.compactMap { document.node(for: $0) }, color: option.key.section.color)
                    .frame(width: 62, height: 42)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Text(option.key.displayName)
                            .font(.system(size: 10, weight: .semibold))
                            .lineLimit(1)
                        if active { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                    }
                    Text("\(option.nodeIDs.count) objects\(editing ? " · editing" : "")")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.editorSecondaryText)
                }
                Spacer(minLength: 0)
            }
            .padding(6)
            .frame(width: 205, height: 56, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9).fill(active ? option.key.section.color.opacity(0.10) : Color.platformControlBackground))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(editing ? option.key.section.color : Color.editorHairline, lineWidth: editing ? 1.5 : 1))
        }
        .buttonStyle(.plain)
    }

    private func details(for option: RoomLayoutOption) -> some View {
        HStack(spacing: 18) {
            RoomLayoutMiniMap(nodes: option.nodeIDs.compactMap { document.node(for: $0) }, color: option.key.section.color)
                .frame(width: 108, height: 68)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color.platformControlBackground))

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(option.key.displayName).font(.system(size: 12, weight: .bold))
                    Text(option.key.section.rawValue)
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Capsule().fill(option.key.section.color.opacity(0.13)))
                        .foregroundStyle(option.key.section.color)
                }
                Text("\(option.nodeIDs.count) objects. Select more objects on the canvas to add them here.")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.editorSecondaryText)
                Button("Add current selection") {
                    let count = document.effectiveSelectedNodeIDs.count
                    document.applyEditingRoomLayoutToSelection()
                    message = "Added \(count) object\(count == 1 ? "" : "s") to \(option.key.displayName)."
                }
                .controlSize(.mini)
                .disabled(document.effectiveSelectedNodeIDs.isEmpty)
            }
            .frame(width: 300, alignment: .leading)

            Divider().frame(height: 58)
            compatibilityEditor(for: option)
            Divider().frame(height: 58)
            variations(for: option)
            Spacer(minLength: 0)
            Button { detailsExpanded = false } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.plain)
                .help("Collapse details")
        }
        .padding(.horizontal, 14)
        .frame(height: 86)
    }

    private func compatibilityEditor(for option: RoomLayoutOption) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("WORKS WITH")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color.editorSecondaryText)
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(spacing: 5) {
                    if eligibleParents(for: option).isEmpty {
                        Text("Starts a route")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Color.editorSecondaryText)
                    } else {
                        parentButton(nil, for: option)
                        ForEach(eligibleParents(for: option)) { parent in
                            parentButton(parent, for: option)
                        }
                    }
                }
            }
        }
        .frame(minWidth: 330, alignment: .leading)
    }

    private func parentButton(_ parent: RoomLayoutOption?, for child: RoomLayoutOption) -> some View {
        let selected = document.roomLayoutParent(for: child.key) == parent?.key
        let color = parent?.key.section.color ?? Color.editorSecondaryText
        return Button {
            document.setRoomLayoutParent(parent?.key, for: child.key)
            message = parent.map { "\(child.key.displayName) now appears with \($0.key.displayName)." }
                ?? "\(child.key.displayName) can now appear independently."
        } label: {
            HStack(spacing: 4) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                Text(parent?.key.displayName ?? "Any")
                    .lineLimit(1)
            }
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 7).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? color.opacity(0.14) : Color.platformControlBackground))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? color.opacity(0.7) : Color.editorHairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func eligibleParents(for option: RoomLayoutOption) -> [RoomLayoutOption] {
        let sections: Set<RoomLayoutSection>
        switch option.key.section {
        case .start: sections = []
        case .middle: sections = [.start]
        case .finish: sections = document.roomLayoutOptions(in: .middle).isEmpty ? [.start] : [.middle]
        case .dynamic: sections = [.start, .middle, .finish]
        }
        return document.roomLayoutOptions.filter { sections.contains($0.key.section) }
    }

    private func variations(for option: RoomLayoutOption) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("VARIATIONS")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color.editorSecondaryText)
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(spacing: 5) {
                    ForEach(document.roomLayoutOptions(in: option.key.section)) { variation in
                        Button(variation.key.displayName) {
                            document.activateRoomLayout(variation)
                            message = "Previewing \(variation.key.displayName)."
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .tint(option.key.section.color)
                    }
                }
            }
        }
        .frame(minWidth: 220, alignment: .leading)
    }

    private func sharedObjectsEditor(_ group: LevelNode) -> some View {
        let selectedKeys = document.sharedGroupRouteKeys(group)
        return HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Label(group.name, systemImage: "square.stack.3d.up.fill")
                    .font(.system(size: 12, weight: .bold))
                Text("Everything inside follows these route rules as one reusable group.")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.editorSecondaryText)
            }
            .frame(width: 250, alignment: .leading)

            Divider().frame(height: 55)

            VStack(alignment: .leading, spacing: 6) {
                Text("APPEARS IN")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.editorSecondaryText)
                ScrollView(.horizontal, showsIndicators: true) {
                    HStack(spacing: 5) {
                        Button {
                            document.setSharedGroup(group.id, appearsIn: [])
                            message = "\(group.name) now appears in every route."
                        } label: {
                            sharedRouteChip("Every route", selected: selectedKeys.isEmpty, color: .blue)
                        }
                        .buttonStyle(.plain)

                        ForEach(document.roomLayoutOptions) { option in
                            let selected = selectedKeys.contains(option.key)
                            Button {
                                var updated = selectedKeys
                                if selected { updated.remove(option.key) } else { updated.insert(option.key) }
                                document.setSharedGroup(group.id, appearsIn: updated)
                                message = updated.isEmpty
                                    ? "\(group.name) now appears in every route."
                                    : "Updated where \(group.name) appears."
                            } label: {
                                sharedRouteChip(
                                    "\(option.key.section.rawValue) · \(option.key.displayName)",
                                    selected: selected,
                                    color: option.key.section.color
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 5) {
                Button("Current Route") {
                    if document.setSharedGroupToCurrentRoute(group.id) {
                        message = "\(group.name) now follows the current route only."
                    } else {
                        message = "Choose a layout card first, then use Current Route."
                    }
                }
                .controlSize(.small)
                Button("Ungroup") {
                    if document.ungroupSharedObjects(group.id) {
                        message = "Ungrouped the shared objects without changing their routes."
                    }
                }
                .controlSize(.mini)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 82)
    }

    private func sharedRouteChip(_ title: String, selected: Bool, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
            Text(title).lineLimit(1)
        }
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(selected ? color : Color.editorSecondaryText)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7).fill(selected ? color.opacity(0.13) : Color.platformControlBackground))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(selected ? color.opacity(0.7) : Color.editorHairline, lineWidth: 1))
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(message)
                .font(.system(size: 9))
                .foregroundStyle(document.roomLayoutIssues.isEmpty ? Color.editorSecondaryText : .orange)
                .lineLimit(1)
            Spacer()
            if !detailsExpanded, selectedOption != nil {
                Button("Show details") { detailsExpanded = true }
                    .controlSize(.mini)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 26)
    }

    private var selectedOption: RoomLayoutOption? {
        guard let key = document.editingRoomLayout else { return nil }
        return document.roomLayoutOptions.first { $0.key == key }
    }

    private func canCreate(in section: RoomLayoutSection) -> Bool {
        !document.effectiveSelectedNodeIDs.isEmpty &&
            !draftNames[section, default: ""].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func createLayout(in section: RoomLayoutSection) {
        let name = draftNames[section, default: ""]
        if let error = document.createRoomLayout(section: section, name: name) {
            message = error
        } else {
            message = "Created \(name) from \(document.effectiveSelectedNodeIDs.count) selected objects."
            draftNames[section] = ""
            detailsExpanded = true
        }
    }

    private func runLayoutCheck() {
        let issues = document.roomLayoutIssues
        if issues.isEmpty {
            message = "All \(document.roomLayoutCombinationCount) layout routes passed the current safety checks. Linked sections are mutually exclusive."
        } else {
            message = issues.first ?? "Some layouts need attention."
        }
    }
}

private struct RoomLayoutMiniMap: View {
    let nodes: [LevelNode]
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            let rects = nodes.compactMap(Self.rect(for:))
            let bounds = rects.dropFirst().reduce(rects.first ?? CGRect(x: 0, y: 0, width: 1, height: 1)) { $0.union($1) }
            let scale = min(
                (proxy.size.width - 8) / max(bounds.width, 1),
                (proxy.size.height - 8) / max(bounds.height, 1)
            )
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(color.opacity(0.07))
                ForEach(Array(rects.enumerated()), id: \.offset) { item in
                    let rect = item.element
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(color.opacity(0.72))
                        .frame(width: max(2, rect.width * scale), height: max(2, rect.height * scale))
                        .position(
                            x: 4 + (rect.midX - bounds.minX) * scale,
                            y: 4 + (rect.midY - bounds.minY) * scale
                        )
                }
            }
            .clipped()
        }
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.editorHairline, lineWidth: 1))
    }

    nonisolated private static func rect(for node: LevelNode) -> CGRect? {
        guard let transform = node.transform else { return nil }
        return CGRect(
            x: transform.x - transform.width / 2,
            y: transform.y - transform.height / 2,
            width: max(2, transform.width),
            height: max(2, transform.height)
        )
    }
}

private extension RoomLayoutSection {
    var exampleName: String {
        switch self {
        case .start: return "e.g. Short Entrance"
        case .middle: return "e.g. Lower Route"
        case .finish: return "e.g. Safe Exit"
        case .dynamic: return "e.g. Moving Platforms"
        }
    }

    var emptyHint: String {
        switch self {
        case .start: return "Add an entrance layout"
        case .middle: return "Add a route layout"
        case .finish: return "Add an exit layout"
        case .dynamic: return "Add moving or timed pieces"
        }
    }
}
