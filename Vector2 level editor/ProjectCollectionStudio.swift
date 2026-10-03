import AppKit
import SwiftUI

struct ProjectCollectionStudio: View {
    let title: String; let subtitle: String; let symbol: String; let tint: Color; let folder: URL; let empty: String
    private var entries: [URL] {
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter { ["xml", "yaml", "yml"].contains($0.pathExtension.lowercased()) }
    }

    var body: some View {
        ProjectStudioShell(title: title, subtitle: subtitle, symbol: symbol, tint: tint) {
            if entries.isEmpty {
                ContentUnavailableView(empty, systemImage: symbol, description: Text("This system fills out as you create project content."))
                    .frame(minHeight: 360).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18))
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 14)], spacing: 14) {
                    ForEach(entries, id: \.path) { file in
                        VStack(alignment: .leading, spacing: 13) {
                            Image(systemName: symbol).font(.title).foregroundStyle(tint)
                            Text(file.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_", with: " ").capitalized).font(.headline)
                            Text(file.pathExtension.uppercased()).font(.caption.bold()).foregroundStyle(.secondary)
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }.buttonStyle(.bordered)
                        }.padding(17).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
                            .overlay(RoundedRectangle(cornerRadius: 16).stroke(tint.opacity(0.25)))
                    }
                }
            }
        }
    }
}
