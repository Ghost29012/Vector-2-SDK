import SwiftUI

/// Room-editor entry point for the shared visual trigger authoring surface.
struct XMLTemplateBuilderView: View {
    @Binding var document: LevelDocument
    let onClose: () -> Void
    let onStatus: (String) -> Void
    @State private var files: [URL] = []
    @State private var selectedURL: URL?
    @State private var creating = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Trigger Designer").font(.headline)
                Spacer()
                Text(document.name).font(.caption).foregroundStyle(.secondary)
                Button("Close Tab", action: onClose).keyboardShortcut(.cancelAction)
            }.padding(.horizontal, 16).padding(.vertical, 8)
            HSplitView {
                VStack(alignment: .leading, spacing: 8) {
                    Text("PROJECT TRIGGERS").font(.caption.bold()).foregroundStyle(.secondary)
                    Text("Make a trigger here, then place it in this room.").font(.caption).foregroundStyle(.secondary)
                    Button("New Trigger", systemImage: "plus") { creating = true; selectedURL = nil }
                        .buttonStyle(.borderedProminent)
                    if files.isEmpty { Text("No saved triggers yet.").font(.caption).foregroundStyle(.secondary) }
                    else { ScrollView { LazyVStack(spacing: 6) { ForEach(files, id: \.path) { file in Button { selectedURL = file; creating = false } label: { HStack { Image(systemName: "square.dashed.inset.filled"); Text(file.deletingPathExtension().lastPathComponent); Spacer(); if selectedURL == file { Image(systemName: "checkmark.circle.fill") } }.padding(9) }.buttonStyle(.plain).background(selectedURL == file ? Color.indigo.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 9)) } } } }
                }.padding(12).frame(minWidth: 220, idealWidth: 250, maxWidth: 290)
                if creating {
                    TriggerBuilderView(projectRoot: Vector2AssetCatalog.activeProjectRootURL(), applyTitle: "Place in Open Room", modelReferences: document.aiCharacters.map(\.name)) { trigger in
                        try place(trigger)
                    }.id("new-trigger")
                } else if let selectedURL, let trigger = ProjectTriggerStore.load(selectedURL) {
                    TriggerBuilderView(initial: trigger, projectRoot: Vector2AssetCatalog.activeProjectRootURL(), applyTitle: "Place in Open Room", modelReferences: document.aiCharacters.map(\.name)) { trigger in
                        try place(trigger)
                    }.id(selectedURL.path)
                } else {
                    ContentUnavailableView("Make or choose a trigger", systemImage: "cursorarrow.click", description: Text("You can create one right here and place it in the open room."))
                }
            }
        }
        .onAppear {
            guard let project = Vector2AssetCatalog.activeProjectRootURL() else {
                files = []
                selectedURL = nil
                return
            }
            files = ProjectTriggerStore.files(in: project)
            if selectedURL == nil || !files.contains(selectedURL!) { selectedURL = files.first }
        }
    }

    private func place(_ trigger: TriggerDefinition) throws {
        let xml = try TriggerXMLCodec.encode(trigger)
        let base = document.sourcePath.map { URL(fileURLWithPath: $0).deletingLastPathComponent() } ?? URL(fileURLWithPath: NSTemporaryDirectory())
        guard let node = XMLSceneParser.parseNodeXML(xml, baseURL: base), document.insertSceneNode(node) else { throw TriggerRoomXMLStoreError.invalidTrigger }
        onStatus("Placed trigger \(trigger.name) in \(document.name). Drag or resize it, then save/export the room.")
    }
}

extension LevelDocument {
    mutating func insertSceneNode(_ node: LevelNode) -> Bool {
        if !root.appendToFirstFactor(node) {
            let factor = LevelNode(name: "Object Factor = 1", kind: .factor, factor: "1", transform: nil, xml: .init(), children: [node])
            if let track = root.children.firstIndex(where: { $0.kind == .track }) { root.children[track].children.append(factor) }
            else { root.children.append(LevelNode(name: "Track", kind: .track, factor: "1", transform: nil, xml: .init(), children: [factor])) }
        }
        selectedNodeID = node.id
        selectedNodeIDs = [node.id]
        return true
    }
}
