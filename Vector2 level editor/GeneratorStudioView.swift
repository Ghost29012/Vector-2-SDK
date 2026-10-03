import Foundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct GeneratorStudio: View {
    let projectRoot: URL
    @State private var refreshToken = UUID()

    private struct ZonePool: Identifiable {
        let id: String
        let name: String
        let relativePath: String
        let rooms: [String]
        let folderExists: Bool
    }

    private var zones: [ZonePool] {
        _ = refreshToken
        let definitions = projectRoot.appendingPathComponent("custom_zones", isDirectory: true)
        let files = ((try? FileManager.default.contentsOfDirectory(at: definitions, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
            .filter { $0.pathExtension.lowercased() == "xml" }
        return files.compactMap { file in
            guard let document = try? XMLDocument(contentsOf: file),
                  let node = (try? document.nodes(forXPath: "//Zone").first) as? XMLElement,
                  let id = node.attribute(forName: "Id")?.stringValue, !id.isEmpty else { return nil }
            let name = node.attribute(forName: "Name")?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            let storedPath = node.attribute(forName: "RoomsPath")?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let relativePath = storedPath.isEmpty ? "custom_rooms/\(id)" : storedPath
            let folder = projectRoot.appendingPathComponent(relativePath, isDirectory: true)
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory) && isDirectory.boolValue
            let rooms: [String]
            if let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
                rooms = enumerator.compactMap { item -> String? in
                    guard let url = item as? URL,
                          url.pathExtension.lowercased() == "xml",
                          !url.lastPathComponent.lowercased().hasSuffix(".meta.xml") else { return nil }
                    return url.deletingPathExtension().lastPathComponent
                }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            } else { rooms = [] }
            return ZonePool(id: id, name: (name?.isEmpty == false ? name! : id), relativePath: relativePath, rooms: rooms, folderExists: exists)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        ProjectStudioShell(title: "Room Generator", subtitle: "Check which rooms the game can pick for each zone.", symbol: "point.3.connected.trianglepath.dotted", tint: .green) {
            HStack(spacing: 12) {
                flowNode("Start Run", "play.fill", .green); arrow
                flowNode("Choose Zone", "map.fill", .teal); arrow
                flowNode("Pick Room", "square.stack.3d.up.fill", .blue); arrow
                flowNode("Build Floor", "flag.checkered", .orange)
            }.padding(18).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18))
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Zone Room Pools").font(.title3.bold())
                    Text("Each zone picks rooms from the folder shown here.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { refreshToken = UUID() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 13)], spacing: 13) {
                ForEach(zones) { zone in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Image(systemName: zone.folderExists ? "square.3.layers.3d" : "exclamationmark.triangle.fill")
                                .font(.title2).foregroundStyle(zone.folderExists ? .green : .orange)
                            Spacer()
                            Text("\(zone.rooms.count) room\(zone.rooms.count == 1 ? "" : "s")")
                                .font(.caption.bold()).foregroundStyle(.secondary)
                        }
                        Text(zone.name).font(.headline)
                        Text(zone.relativePath).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        if !zone.folderExists {
                            Label("Folder is missing", systemImage: "folder.badge.questionmark").font(.caption).foregroundStyle(.orange)
                        } else if zone.rooms.isEmpty {
                            Text("Add room XML files to this pool.").font(.caption).foregroundStyle(.secondary)
                        } else {
                            VStack(alignment: .leading, spacing: 5) {
                                ForEach(zone.rooms.prefix(6), id: \.self) { room in
                                    Label(room, systemImage: "doc.text").font(.caption).lineLimit(1)
                                }
                                if zone.rooms.count > 6 { Text("+ \(zone.rooms.count - 6) more").font(.caption2).foregroundStyle(.secondary) }
                            }
                        }
                        Divider()
                        HStack {
                            Button { openPool(zone) } label: { Label("Open", systemImage: "folder") }
                            Spacer()
                            Button { importRooms(into: zone) } label: { Label("Add Rooms…", systemImage: "plus") }
                                .buttonStyle(.borderedProminent)
                        }
                    }.padding(16).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(zone.folderExists ? Color.green.opacity(0.14) : Color.orange.opacity(0.3)))
                }
            }
            if zones.isEmpty { ContentUnavailableView("No zone pools", systemImage: "square.stack.3d.up.slash", description: Text("Create a zone first. Its selected room folder appears here automatically.")) }
        }
    }

    private var arrow: some View { Image(systemName: "arrow.right").foregroundStyle(.secondary) }
    private func flowNode(_ title: String, _ icon: String, _ color: Color) -> some View {
        VStack(spacing: 9) { Image(systemName: icon).font(.title2).foregroundStyle(color); Text(title).fontWeight(.semibold) }
            .frame(maxWidth: .infinity, minHeight: 90).background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
    }

    private func poolURL(_ zone: ZonePool) -> URL {
        projectRoot.appendingPathComponent(zone.relativePath, isDirectory: true)
    }

    private func openPool(_ zone: ZonePool) {
        let folder = poolURL(zone)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
        refreshToken = UUID()
    }

    private func importRooms(into zone: ZonePool) {
        let panel = NSOpenPanel()
        panel.title = "Add rooms to \(zone.name)"
        panel.prompt = "Add to Pool"
        panel.message = "Choose room XML files. They are copied into this zone's real runtime pool."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.xml]
        guard panel.runModal() == .OK else { return }
        let destination = poolURL(zone)
        try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for source in panel.urls {
            let access = source.startAccessingSecurityScopedResource()
            defer { if access { source.stopAccessingSecurityScopedResource() } }
            var target = destination.appendingPathComponent(source.lastPathComponent)
            var suffix = 2
            while FileManager.default.fileExists(atPath: target.path) {
                let stem = source.deletingPathExtension().lastPathComponent
                target = destination.appendingPathComponent("\(stem)_\(suffix).xml")
                suffix += 1
            }
            try? FileManager.default.copyItem(at: source, to: target)
        }
        refreshToken = UUID()
    }
}
