import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Creates reusable trigger definitions. It intentionally knows nothing about
/// rooms: placement belongs to the open level editor canvas.
struct ProjectTriggerStudioView: View {
    let projectRoot: URL
    let onStatus: (String) -> Void
    @State private var files: [URL] = []
    @State private var selectedURL: URL?
    @State private var creating = false
    @State private var openedTriggers: [TriggerDefinition] = []
    @State private var openedTriggerIndex: Int?
    @State private var openedFileName = ""

    var body: some View {
        HSplitView {
            VStack(spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("TRIGGER LIBRARY").font(.caption.bold()).foregroundStyle(.secondary)
                        Text("Reusable in every room.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { openXML() } label: { Image(systemName: "folder.badge.plus") }.help("Open a trigger or room XML")
                    Button { startNewTrigger() } label: { Image(systemName: "plus") }.buttonStyle(.borderedProminent)
                }.padding(.horizontal, 14).padding(.top, 14)
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(files, id: \.path) { file in
                            Button { selectedURL = file; creating = false; openedTriggerIndex = nil } label: {
                                HStack {
                                    Image(systemName: "point.3.connected.trianglepath.dotted")
                                    Text(file.deletingPathExtension().lastPathComponent).lineLimit(1)
                                    Spacer()
                                    if selectedURL == file { Image(systemName: "checkmark.circle.fill").foregroundStyle(.indigo) }
                                }.padding(9).contentShape(Rectangle())
                            }.buttonStyle(.plain).background(selectedURL == file ? Color.indigo.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 10))
                        }
                        if !openedTriggers.isEmpty {
                            Divider().padding(.vertical, 6)
                            HStack { Text("OPENED FROM \(openedFileName.uppercased())").font(.caption2.bold()).foregroundStyle(.secondary); Spacer() }
                                .padding(.horizontal, 8)
                            ForEach(openedTriggers.indices, id: \.self) { index in
                                Button { openedTriggerIndex = index; selectedURL = nil; creating = false } label: {
                                    HStack {
                                        Image(systemName: "doc.text.magnifyingglass")
                                        Text(openedTriggers[index].name).lineLimit(1)
                                        Spacer()
                                        if openedTriggerIndex == index { Image(systemName: "checkmark.circle.fill").foregroundStyle(.indigo) }
                                    }.padding(9).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                    .background(openedTriggerIndex == index ? Color.indigo.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 10))
                            }
                        }
                    }.padding(8)
                }
                Text("Make or open a trigger here. To place it, open a room and choose Tools → Triggers.")
                    .font(.caption).foregroundStyle(.secondary).padding(12)
            }.frame(minWidth: 230, idealWidth: 260, maxWidth: 300).background(Color(nsColor: .controlBackgroundColor).opacity(0.8))

            if creating {
                TriggerBuilderView(projectRoot: projectRoot, applyTitle: "Save to Library") { trigger in try save(trigger, replacing: nil) }
                    .id("new-trigger")
            } else if let openedTriggerIndex, openedTriggers.indices.contains(openedTriggerIndex) {
                TriggerBuilderView(initial: openedTriggers[openedTriggerIndex], projectRoot: projectRoot, applyTitle: "Save Copy to Library") { trigger in
                    try save(trigger, replacing: nil)
                }
                .id("opened-\(openedFileName)-\(openedTriggerIndex)")
            } else if let selectedURL, let trigger = ProjectTriggerStore.load(selectedURL) {
                TriggerBuilderView(initial: trigger, projectRoot: projectRoot, applyTitle: "Save Changes") { trigger in try save(trigger, replacing: selectedURL) }
                    .id(selectedURL.path)
            } else {
                ContentUnavailableView("No trigger selected", systemImage: "point.3.connected.trianglepath.dotted", description: Text("Create one, or open an XML file from Vector 2 to inspect its triggers."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.onAppear { reload() }
    }

    private func save(_ trigger: TriggerDefinition, replacing oldURL: URL?) throws {
        let saved = try ProjectTriggerStore.save(trigger, in: projectRoot, replacing: oldURL)
        reload(selecting: saved)
        creating = false
        openedTriggerIndex = nil
        onStatus("Saved \(trigger.name). Open a room and use Tools → Triggers when you want to place it.")
    }

    private func reload(selecting preferred: URL? = nil) {
        files = ProjectTriggerStore.files(in: projectRoot)
        if let preferred { selectedURL = preferred }
        else if selectedURL == nil || !files.contains(selectedURL!) { selectedURL = files.first }
    }

    private func startNewTrigger() {
        creating = true
        selectedURL = nil
        openedTriggerIndex = nil
    }

    private func openXML() {
        let panel = NSOpenPanel()
        panel.title = "Open a Trigger or Room XML"
        panel.message = "Choose a standalone trigger or a room containing triggers. The original file will not be changed."
        panel.allowedContentTypes = [.xml]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let decoded = try TriggerXMLImporter.decodeAll(contentsOf: url)
            openedTriggers = decoded
            openedTriggerIndex = decoded.indices.first
            openedFileName = url.lastPathComponent
            selectedURL = nil
            creating = false
            onStatus(decoded.count == 1 ? "Opened \(decoded[0].name) from \(url.lastPathComponent)." : "Found \(decoded.count) triggers in \(url.lastPathComponent).")
        } catch {
            onStatus("Could not open triggers: \(error.localizedDescription)")
        }
    }
}
