import AppKit
import Foundation
import SwiftUI

/// Browses the project records that have dedicated visual creators. Parsing the
/// summaries here keeps ProjectManagerView focused on navigation and project IO.
struct ProjectStructuredStudioView: View {
    let section: String
    let folder: URL
    let files: [URL]
    let onImport: () -> Void
    let onCreate: () -> Void
    let onEdit: (URL) -> Void
    let onDelete: (URL) -> Void
    @State private var pendingDelete: URL?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(section).font(.system(size: 32, weight: .bold))
                        Text(subtitle).font(.system(size: 15)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Import Existing…", action: onImport)
                    Button("Open Folder") { NSWorkspace.shared.open(folder) }
                    Button("New \(singular)", action: onCreate).buttonStyle(.borderedProminent).controlSize(.large)
                }
                if files.isEmpty { emptyState }
                else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 285, maximum: 390), spacing: 14)], spacing: 14) {
                        ForEach(files, id: \.path) { card($0) }
                    }
                }
            }.frame(maxWidth: 1290).padding(24).frame(maxWidth: .infinity)
        }.background(Color(nsColor: .windowBackgroundColor))
        .alert("Delete \(singular)?", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) { pendingDelete = nil }
            Button("Delete", role: .destructive) {
                if let file = pendingDelete { onDelete(file) }
                pendingDelete = nil
            }
        } message: {
            Text("This removes the project file. Install Changes will also remove its old copy from Vector 2.")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 38)).foregroundStyle(.blue)
            Text("Create your first \(singular.lowercased())").font(.title3.bold())
            Text(emptyText).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Get Started", action: onCreate).buttonStyle(.borderedProminent)
        }.frame(maxWidth: .infinity, minHeight: 330).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18))
    }

    private func card(_ file: URL) -> some View {
        let info = summary(file)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: symbol).font(.title2).foregroundStyle(.blue)
                Spacer()
                Button("Edit") { onEdit(file) }.buttonStyle(.borderedProminent)
                Button(role: .destructive) { pendingDelete = file } label: { Image(systemName: "trash") }
                    .buttonStyle(.bordered)
                    .help("Delete from project")
            }
            Text(info.title).font(.system(size: 18, weight: .semibold)).lineLimit(1)
            Text(info.id).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
            Text(info.detail.isEmpty ? "No description" : info.detail).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(3).frame(maxWidth: .infinity, minHeight: 47, alignment: .topLeading)
            Divider()
            HStack { Label(info.meta, systemImage: info.metaSymbol).font(.caption); Spacer(); Text(modified(file)).font(.caption).foregroundStyle(.secondary) }
        }.padding(16).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 15))
            .overlay(RoundedRectangle(cornerRadius: 15).stroke(Color(nsColor: .separatorColor).opacity(0.75)))
    }

    private func summary(_ file: URL) -> (title: String, id: String, detail: String, meta: String, metaSymbol: String) {
        guard let document = try? XMLDocument(contentsOf: file), let item = document.rootElement()?.children?.compactMap({ $0 as? XMLElement }).first else {
            return (file.deletingPathExtension().lastPathComponent, "Could not read", "Run validation for details.", section, "exclamationmark.triangle")
        }
        func value(_ key: String) -> String { item.attribute(forName: key)?.stringValue ?? "" }
        func fallback(_ first: String, _ second: String) -> String { first.isEmpty ? second : first }
        switch section {
        case "Chapters": return (fallback(value("Name"), value("Id")), value("Id"), value("Description"), "\(item.elements(forName: "Zone").count) zones", "circle.grid.3x3.fill")
        case "Zones": return (fallback(value("Name"), value("Id")), value("Id"), value("Description"), fallback(value("Chapter"), "No chapter"), "circle.fill")
        case "Quests":
            let info = item.elements(forName: "Info").first
            return (fallback(info?.elements(forName: "VisualName").first?.attribute(forName: "Value")?.stringValue ?? "", value("Name")), value("Name"), info?.elements(forName: "Description").first?.attribute(forName: "Value")?.stringValue ?? "", "Quest flow", "point.3.connected.trianglepath.dotted")
        case "Dialogue": return (fallback(value("Title"), value("Id")), value("Id"), value("Text"), fallback(value("Speaker"), "No speaker"), "person.wave.2")
        case "Characters": return (fallback(value("Name"), value("Id")), value("Id"), value("Portrait"), fallback(value("Color"), "Default colour"), "person.crop.circle")
        case "Localization": return (value("Key"), fallback(value("Language"), "Default"), value("Value"), "Translation", "character.book.closed")
        default: return (file.lastPathComponent, "", "", section, "doc")
        }
    }

    private var singular: String { section.hasSuffix("s") ? String(section.dropLast()) : section }
    private var symbol: String { ["Chapters": "books.vertical", "Zones": "square.3.layers.3d", "Quests": "bookmark", "Dialogue": "text.bubble", "Characters": "person.2", "Localization": "character.book.closed"][section] ?? "doc" }
    private var subtitle: String { ["Chapters": "Set up the floors and zones shown in the chapter menu.", "Zones": "Choose a zone's rooms, menu position, and artwork.", "Quests": "List the objectives the player must complete, in order.", "Dialogue": "Write conversations that rooms and stories can start.", "Characters": "Add speakers and choose their portraits.", "Localization": "Store the text used by your project in each language."][section] ?? "Files used by this project." }
    private var emptyText: String { ["Chapters": "Add a chapter to choose its floors and zones.", "Zones": "Add a zone, then assign its chapter, rooms, and menu artwork.", "Quests": "Add a quest, then list the events that complete its objectives.", "Dialogue": "Add a conversation, then choose its speaker and lines.", "Characters": "Add a character before using them in dialogue or stories.", "Localization": "Add the text your project needs. Other languages can come later."][section] ?? "Nothing has been added here yet." }
    private func modified(_ file: URL) -> String { ((try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map { $0.formatted(date: .abbreviated, time: .omitted) }) ?? "—" }
}
