import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ObstacleDesignerBar: View {
    @Binding var document: LevelDocument
    let onStatus: (String) -> Void
    @State private var stableID = "new_obstacle"
    @State private var displayName = "New Obstacle"
    @State private var author = ""
    @State private var version = "1.0.0"

    var body: some View {
        HStack(spacing: 12) {
            Label("Obstacle Designer", systemImage: "shippingbox.fill").font(.headline).foregroundStyle(.orange)
            TextField("Stable ID", text: $stableID).frame(width: 150)
            TextField("Name", text: $displayName).frame(width: 180)
            TextField("Author", text: $author).frame(width: 130)
            TextField("Version", text: $version).frame(width: 80)
            Spacer()
            Button("Open Package", action: openPackage)
            Button("Export & Share", action: exportPackage).buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 14).frame(height: 54).background(Color(nsColor: .controlBackgroundColor))
    }

    private func exportPackage() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: ObstaclePackageStore.fileExtension) ?? .data]
        panel.nameFieldStringValue = "\(stableID).v2obstacle"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let textures = referencedTextureURLs()
            let definition = ObstaclePackageDefinition(stableID: stableID, name: displayName, author: author, version: version, xml: document.exportedXML(), textureURLs: textures, previewPNG: ObstaclePreviewRenderer.pngData(for: document))
            try ObstaclePackageStore.export(definition, to: url)
            onStatus("Exported \(url.lastPathComponent) with \(textures.count) custom texture\(textures.count == 1 ? "" : "s").")
        } catch { onStatus("Obstacle export failed: \(error.localizedDescription)") }
    }

    private func openPackage() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [UTType(filenameExtension: ObstaclePackageStore.fileExtension) ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let loaded = try ObstaclePackageStore.read(url)
            let xmlURL = loaded.extractionRoot.appendingPathComponent("obstacle.xml")
            guard var parsed = LevelDocument.loadFromXML(at: xmlURL.path) else { throw ObstaclePackageError.missingXML }
            parsed.sourcePath = LevelDocument.obstacleStudioSourcePath
            document = parsed; stableID = loaded.definition.stableID; displayName = loaded.definition.name; author = loaded.definition.author; version = loaded.definition.version
            onStatus("Opened \(url.lastPathComponent).")
        } catch { onStatus("Could not open obstacle: \(error.localizedDescription)") }
    }

    private func referencedTextureURLs() -> [URL] {
        let names = Set(document.root.flattenedSceneNodes().flatMap { [$0.metadata.className, $0.name] }.filter { !$0.isEmpty })
        return names.compactMap { Vector2AssetCatalog.imagePath(forClassName: $0).map(URL.init(fileURLWithPath:)) }.filter { $0.path.contains("custom_textures") }
    }
}

enum ObstaclePreviewRenderer {
    static func pngData(for document: LevelDocument) -> Data? {
        let size = NSSize(width: 640, height: 360), image = NSImage(size: NSSize(width: 640, height: 360))
        image.lockFocus(); NSColor(calibratedWhite: 0.10, alpha: 1).setFill(); NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        let nodes = document.root.flattenedSceneNodes().filter { $0.transform != nil }
        let bounds = nodes.compactMap(\.transform).reduce(CGRect.null) { $0.union(CGRect(x: $1.x, y: $1.y, width: max(1, $1.width), height: max(1, $1.height))) }
        if !bounds.isNull {
            let scale = min(580 / max(1, bounds.width), 300 / max(1, bounds.height))
            for node in nodes {
                guard let t = node.transform else { continue }
                let rect = NSRect(x: 30 + (CGFloat(t.x) - bounds.minX) * scale, y: 30 + (CGFloat(t.y) - bounds.minY) * scale, width: max(2, CGFloat(t.width) * scale), height: max(2, CGFloat(t.height) * scale))
                let imagePath = node.metadata.imagePath.isEmpty ? Vector2AssetCatalog.imagePath(forClassName: node.metadata.className) : node.metadata.imagePath
                if let imagePath, let texture = NSImage(contentsOfFile: imagePath) {
                    texture.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
                } else {
                    (node.kind == .platform ? NSColor.systemPurple : node.kind == .trigger || node.kind == .area ? NSColor.systemOrange : NSColor.systemTeal).withAlphaComponent(0.65).setFill()
                    NSBezierPath(rect: rect).fill()
                }
            }
        }
        image.unlockFocus(); guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }; return rep.representation(using: .png, properties: [:])
    }
}
