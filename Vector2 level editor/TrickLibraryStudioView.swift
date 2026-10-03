import AppKit
import Foundation
import SwiftUI

/// Tricks are packages, not loose files. This view deliberately reads only the
/// package manifest so animation bytes and XML never become giant fake cards.
struct TrickLibraryStudioView: View {
    let projectRoot: URL
    let onImport: () -> Void
    let onCreate: () -> Void
    let onOpenShop: () -> Void
    let onOpenUpgrades: () -> Void
    let onStatus: (String) -> Void

    @State private var tricks: [TrickLibraryItem] = []
    @State private var query = ""
    @State private var pendingDelete: TrickLibraryItem?

    private var folder: URL { projectRoot.appendingPathComponent("custom_tricks", isDirectory: true) }
    private var visible: [TrickLibraryItem] {
        query.isEmpty ? tricks : tricks.filter { $0.name.localizedCaseInsensitiveContains(query) || $0.id.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "figure.run").font(.system(size: 22, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 48, height: 48).background(Color.green.gradient, in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Trick Library").font(.system(size: 27, weight: .bold))
                    Text("View each custom trick, its shop card, and its upgrades.").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Import Existing", action: onImport)
                Button("New Trick", action: onCreate).buttonStyle(.borderedProminent)
            }.padding(.horizontal, 24).padding(.vertical, 16).background(Color(nsColor: .controlBackgroundColor).opacity(0.94))
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        TextField("Find a trick", text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 360)
                        Spacer()
                        Button("Shop Cards", action: onOpenShop)
                        Button("Upgrade Paths", action: onOpenUpgrades)
                    }
                    workflow
                    if tricks.isEmpty { emptyState }
                    else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 280, maximum: 360), spacing: 14)], spacing: 14) {
                            ForEach(visible) { item in trickCard(item) }
                        }
                    }
                }.frame(maxWidth: 1240).padding(24).frame(maxWidth: .infinity)
            }.background(Color(nsColor: .windowBackgroundColor))
        }.onAppear(perform: reload)
        .alert("Delete trick package?", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) { pendingDelete = nil }
            Button("Delete", role: .destructive) { deletePending() }
        } message: {
            Text("This removes the animation, shop card and upgrade path together. Install Changes removes its old game copy.")
        }
    }

    private var workflow: some View {
        HStack(spacing: 10) {
            workflowStep("1", "Animation", "Trick Creator", "figure.run")
            Image(systemName: "chevron.right").foregroundStyle(.secondary)
            workflowStep("2", "Presentation", "Shop", "rectangle.stack")
            Image(systemName: "chevron.right").foregroundStyle(.secondary)
            workflowStep("3", "Progression", "Upgrades", "arrow.up.circle")
        }.padding(14).background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
    }

    private func workflowStep(_ number: String, _ title: String, _ place: String, _ symbol: String) -> some View {
        HStack(spacing: 10) {
            Text(number).font(.caption.bold()).foregroundStyle(.white).frame(width: 26, height: 26).background(Color.green, in: Circle())
            Image(systemName: symbol).foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 1) { Text(title).fontWeight(.semibold); Text(place).font(.caption).foregroundStyle(.secondary) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func trickCard(_ item: TrickLibraryItem) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            ZStack(alignment: .bottomLeading) {
                Color(nsColor: .controlBackgroundColor)
                if let image = item.imageURL.flatMap(NSImage.init(contentsOf:)) {
                    Image(nsImage: image).resizable().scaledToFill().blur(radius: 15).scaleEffect(1.08)
                    Color.black.opacity(0.18)
                    Image(nsImage: image).resizable().scaledToFit().padding(8)
                } else {
                    LinearGradient(colors: [.green.opacity(0.2), .blue.opacity(0.08)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "figure.run").font(.system(size: 54)).foregroundStyle(.green)
                }
                LinearGradient(colors: [.clear, .black.opacity(0.72)], startPoint: .center, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 2) { Text(item.name).font(.headline).foregroundStyle(.white); Text(item.id).font(.caption).foregroundStyle(.white.opacity(0.72)) }.padding(13)
            }.frame(height: 170).clipped().clipShape(RoundedRectangle(cornerRadius: 15))
            HStack {
                Label(item.animationFile, systemImage: "waveform.path").lineLimit(1)
                Spacer(); Text("Level \(item.maxLevel)").fontWeight(.semibold)
            }.font(.caption).foregroundStyle(.secondary)
            HStack {
                Label(item.shopEnabled ? "In shop" : "Hidden from shop", systemImage: item.shopEnabled ? "cart.fill" : "eye.slash")
                    .foregroundStyle(item.shopEnabled ? .green : .secondary)
                Spacer()
                Button { NSWorkspace.shared.activateFileViewerSelecting([item.manifest]) } label: { Image(systemName: "folder") }.buttonStyle(.borderless)
                Button(role: .destructive) { pendingDelete = item } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
            }.font(.caption)
        }.padding(12).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.primary.opacity(0.07)))
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No complete tricks yet", systemImage: "figure.run")
        } description: {
            Text("Create a trick or import a folder containing trick.xml. Animation files without a trick definition stay in the folder but do not appear in this list.")
        } actions: {
            Button("Create a Trick", action: onCreate).buttonStyle(.borderedProminent)
        }.frame(minHeight: 330)
    }

    private func reload() { tricks = TrickLibraryItem.load(folder: folder, projectRoot: projectRoot) }
    private func deletePending() {
        guard let item = pendingDelete else { return }
        let package = item.manifest.deletingLastPathComponent().standardizedFileURL
        let target = package == folder.standardizedFileURL ? item.manifest : package
        do {
            try FileManager.default.removeItem(at: target)
            pendingDelete = nil
            reload()
            onStatus("Deleted \(item.name). Install Changes removes its old game copy.")
        } catch {
            pendingDelete = nil
            reload()
            onStatus("Could not delete \(item.name): \(error.localizedDescription)")
        }
    }
}

struct TrickLibraryItem: Identifiable {
    let manifest: URL
    let id: String
    let name: String
    let imageURL: URL?
    let animationFile: String
    let maxLevel: Int
    let shopEnabled: Bool

    static func load(folder: URL, projectRoot: URL) -> [TrickLibraryItem] {
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        return enumerator.compactMap { value -> TrickLibraryItem? in
            guard let url = value as? URL, url.lastPathComponent.caseInsensitiveCompare("trick.xml") == .orderedSame,
                  let root = try? XMLDocument(contentsOf: url).rootElement(), root.name == "CustomTrick" else { return nil }
            func attr(_ key: String, _ fallback: String = "") -> String { root.attribute(forName: key)?.stringValue ?? fallback }
            let id = attr("Name", url.deletingLastPathComponent().lastPathComponent)
            let imageName = attr("Image")
            return TrickLibraryItem(manifest: url, id: id, name: attr("VisualName", id), imageURL: resolveImage(imageName, root: projectRoot), animationFile: attr("FileName", "Animation not linked"), maxLevel: Int(attr("MaxLevel", "1")) ?? 1, shopEnabled: !["0", "false"].contains(attr("ShopEnabled", "1").lowercased()))
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func resolveImage(_ name: String, root: URL) -> URL? {
        guard !name.isEmpty else { return nil }
        let wanted = URL(fileURLWithPath: name).lastPathComponent.lowercased()
        for folder in ["custom_textures", "custom_backgrounds"] {
            guard let enumerator = FileManager.default.enumerator(at: root.appendingPathComponent(folder), includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            if let match = enumerator.compactMap({ $0 as? URL }).first(where: { $0.lastPathComponent.lowercased() == wanted || $0.deletingPathExtension().lastPathComponent.lowercased() == wanted }) { return match }
        }
        return nil
    }
}
