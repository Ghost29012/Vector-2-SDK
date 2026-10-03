import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ProjectObstacleLibraryView: View {
    let projectRoot: URL
    let files: [URL]
    let onChanged: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "shippingbox.fill").font(.title2).foregroundStyle(.white).frame(width: 48, height: 48).background(.orange.gradient, in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading) { Text("Obstacle Library").font(.system(size: 27, weight: .bold)); Text("Reusable obstacles, including their XML, preview and custom textures.").foregroundStyle(.secondary) }
                Spacer(); Button("Open Folder") { NSWorkspace.shared.open(projectRoot.appendingPathComponent("custom_obstacles")) }; Button("Import Package", action: importPackage).buttonStyle(.borderedProminent)
            }.padding(24)
            Divider()
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 270), spacing: 14)], spacing: 14) {
                    ForEach(files.filter { $0.pathExtension.lowercased() == ObstaclePackageStore.fileExtension }, id: \.path) { file in
                        ObstaclePackageCard(file: file, onDelete: {
                            try? FileManager.default.removeItem(at: file)
                            NotificationCenter.default.post(name: .vector2AssetCatalogChanged, object: projectRoot)
                            onChanged("Deleted \(file.lastPathComponent).")
                        })
                    }
                }.padding(24)
            }
        }
    }

    private func importPackage() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; panel.allowedContentTypes = [UTType(filenameExtension: ObstaclePackageStore.fileExtension) ?? .data]
        guard panel.runModal() == .OK else { return }
        do {
            for url in panel.urls { _ = try ObstaclePackageStore.install(url, into: projectRoot) }
            NotificationCenter.default.post(name: .vector2AssetCatalogChanged, object: projectRoot)
            onChanged("Imported \(panel.urls.count) obstacle package\(panel.urls.count == 1 ? "" : "s") and indexed their textures.")
        }
        catch { onChanged("Obstacle import failed: \(error.localizedDescription)") }
    }
}

extension Notification.Name {
    static let vector2AssetCatalogChanged = Notification.Name("Vector2AssetCatalogChanged")
}

private struct ObstaclePackageCard: View {
    let file: URL
    let onDelete: () -> Void
    @State private var loaded: LoadedObstaclePackage?
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ZStack { Color.black.opacity(0.82); if let url = loaded?.previewURL, let image = NSImage(contentsOf: url) { Image(nsImage: image).resizable().scaledToFit() } else { Image(systemName: "shippingbox.fill").font(.system(size: 50)).foregroundStyle(.orange) } }.frame(height: 150).clipShape(RoundedRectangle(cornerRadius: 13))
            Text(loaded?.definition.name ?? file.deletingPathExtension().lastPathComponent).font(.headline)
            Text(loaded.map { "\($0.definition.stableID) · \($0.textureURLs.count) textures" } ?? "Reading package…").font(.caption).foregroundStyle(.secondary)
            HStack { Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([file]) }; Spacer(); Button(role: .destructive, action: onDelete) { Image(systemName: "trash") } }
        }.padding(12).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 17)).task { loaded = try? ObstaclePackageStore.read(file) }
    }
}
