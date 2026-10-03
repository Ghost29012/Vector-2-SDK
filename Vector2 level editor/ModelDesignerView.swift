import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct ModelDesignerView: View {
    let projectRoot: URL
    let onStatus: (String) -> Void
    @State private var packages: [ModelPackage] = []
    @State private var selectedID: UUID?
    private var folder: URL { projectRoot.appendingPathComponent("custom_models") }
    private var selectedIndex: Int? { packages.firstIndex { $0.id == selectedID } }

    var body: some View {
        VStack(spacing: 0) {
            header; Divider()
            HSplitView {
                modelList.frame(minWidth: 245, idealWidth: 280, maxWidth: 330)
                if let index = selectedIndex { details($packages[index]).frame(minWidth: 650) }
                else { ContentUnavailableView("No model selected", systemImage: "figure.arms.open", description: Text("Import a Vector model XML to turn it into a reusable project package.")).frame(maxWidth: .infinity, maxHeight: .infinity) }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).background(Color(nsColor: .windowBackgroundColor)).onAppear(perform: reload)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "figure.arms.open").font(.system(size: 23, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 48, height: 48).background(Color.purple.gradient, in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 2) { Text("Models").font(.system(size: 27, weight: .bold)); Text("Package character models, inspect their structure and get the exact runtime reference.").foregroundStyle(.secondary) }
            Spacer(); Button("Open Folder") { NSWorkspace.shared.open(folder) }; Button("Import Model", systemImage: "plus", action: importModel).buttonStyle(.borderedProminent)
        }.padding(.horizontal, 24).padding(.vertical, 16).background(Color(nsColor: .controlBackgroundColor).opacity(0.94))
    }

    private var modelList: some View {
        ScrollView {
            LazyVStack(spacing: 9) {
                ForEach(packages) { model in
                    Button { selectedID = model.id } label: {
                        HStack(spacing: 11) {
                            Image(systemName: model.isValid ? "figure.run" : "exclamationmark.triangle.fill").foregroundStyle(model.isValid ? .purple : .orange)
                                .frame(width: 40, height: 40).background((model.isValid ? Color.purple : .orange).opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                            VStack(alignment: .leading, spacing: 3) { Text(model.name).fontWeight(.semibold).lineLimit(1); Text(model.isValid ? "custom:\(model.stableID)" : model.problem).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                            Spacer()
                        }.padding(9).contentShape(Rectangle())
                    }.buttonStyle(.plain).background(selectedID == model.id ? Color.purple.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 11))
                }
            }.padding(12)
        }.background(Color(nsColor: .controlBackgroundColor).opacity(0.8))
    }

    private func details(_ model: Binding<ModelPackage>) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                modelPreview(model.wrappedValue)
                panel("Package", "These details become the manifest Vector 2 uses to locate the model safely.") {
                    labeled("Display name") { TextField("Runner model", text: model.name).textFieldStyle(.roundedBorder) }
                    HStack {
                        labeled("Stable ID") { TextField("runner_model", text: model.stableID).textFieldStyle(.roundedBorder) }
                        labeled("Category") { Picker("", selection: model.category) { Text("Player").tag("Player"); Text("Armor").tag("Armor"); Text("Character").tag("Character"); Text("Object").tag("Object") }.labelsHidden() }
                    }
                    labeled("Author") { TextField("Creator", text: model.author).textFieldStyle(.roundedBorder) }
                    labeled("Skeleton") { Picker("", selection: model.skeleton) { Text("Vector human (46 bones)").tag("VectorHuman46"); Text("Keep model-defined skeleton").tag("ModelDefined") }.labelsHidden() }
                }
                panel("Runtime", "Use this reference in Protocols, rooms and character tools.") {
                    HStack { Text("custom:\(model.wrappedValue.stableID)").font(.system(.body, design: .monospaced)).textSelection(.enabled); Spacer(); Button("Copy Reference") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString("custom:\(model.wrappedValue.stableID)", forType: .string) } }
                    Label(model.wrappedValue.problem, systemImage: model.wrappedValue.isValid ? "checkmark.seal.fill" : "exclamationmark.triangle.fill").foregroundStyle(model.wrappedValue.isValid ? .green : .orange)
                }
                HStack { Button("Show XML") { NSWorkspace.shared.activateFileViewerSelecting([model.wrappedValue.modelFile]) }; Spacer(); Button("Reload", action: reload); Button("Save Package") { save(model.wrappedValue) }.buttonStyle(.borderedProminent).controlSize(.large) }
            }.frame(maxWidth: 940).padding(24).frame(maxWidth: .infinity)
        }
    }

    private func modelPreview(_ model: ModelPackage) -> some View {
        HStack(alignment: .top, spacing: 20) {
            AnimatedCharacterPreview(projectRoot: projectRoot, modelReferences: ["custom:\(model.stableID)"], accent: .purple)
                .frame(width: 430, height: 330)
            VStack(alignment: .leading, spacing: 7) {
                Text(model.name).font(.title2.bold())
                Text(model.category).foregroundStyle(.secondary)
                Label(model.modelFile.lastPathComponent, systemImage: "doc.text").font(.caption)
                Label("\(model.nodeCount) nodes · \(model.figureCount) shapes", systemImage: "point.3.connected.trianglepath.dotted").font(.caption)
                Text(model.isValid ? "The Scene, Nodes and model geometry are readable." : model.problem).font(.caption).foregroundStyle(model.isValid ? .green : .orange)
            }
            Spacer()
        }.padding(18).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 20))
    }

    private func panel<Content: View>(_ title: String, _ subtitle: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) { Text(title).font(.title3.bold()); Text(subtitle).font(.caption).foregroundStyle(.secondary); Divider(); content() }.padding(18).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 17)).overlay(RoundedRectangle(cornerRadius: 17).stroke(Color.secondary.opacity(0.15)))
    }
    private func labeled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View { VStack(alignment: .leading, spacing: 5) { Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary); content() }.frame(maxWidth: .infinity, alignment: .leading) }

    private func reload() { packages = ModelPackage.load(folder); selectedID = packages.first?.id }
    private func importModel() {
        let panel = NSOpenPanel(); panel.title = "Import a Vector model XML"; panel.allowedContentTypes = [.xml]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let source = panel.url else { return }
        do {
            let scoped = source.startAccessingSecurityScopedResource(); defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            let document = try XMLDocument(contentsOf: source)
            guard document.rootElement()?.name == "Scene" else { throw NSError(domain: "Models", code: 1, userInfo: [NSLocalizedDescriptionKey: "A Vector model must have <Scene> as its root."]) }
            let clean = String(source.deletingPathExtension().lastPathComponent.lowercased().map { $0.isLetter || $0.isNumber ? $0 : Character("_") })
            let package = folder.appendingPathComponent(clean, isDirectory: true); try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
            let target = package.appendingPathComponent("model.xml"); if FileManager.default.fileExists(atPath: target.path) { throw NSError(domain: "Models", code: 2, userInfo: [NSLocalizedDescriptionKey: "A model package named \(clean) already exists."]) }
            try FileManager.default.copyItem(at: source, to: target)
            var model = ModelPackage.inspect(target); model.stableID = clean; model.name = source.deletingPathExtension().lastPathComponent; try model.writeManifest()
            reload(); selectedID = packages.first { $0.stableID == clean }?.id; onStatus("Model imported as custom:\(clean). Install Changes sends it to Vector 2.")
        } catch { onStatus("Model import failed: \(error.localizedDescription)") }
    }
    private func save(_ model: ModelPackage) { do { try model.writeManifest(); reload(); onStatus("Model package saved. Install Changes sends it to Vector 2.") } catch { onStatus("Could not save model: \(error.localizedDescription)") } }
}

private struct ModelPackage: Identifiable {
    var id = UUID(); var manifestFile: URL?; var modelFile: URL; var stableID: String; var name: String; var category = "Player"; var author = "Unknown"; var skeleton = "VectorHuman46"; var nodeCount = 0; var figureCount = 0; var isValid = false; var problem = "Model XML is not packaged yet."

    static func load(_ folder: URL) -> [ModelPackage] {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return [] }
        let urls = enumerator.compactMap { $0 as? URL }
        var result: [ModelPackage] = urls.filter { $0.lastPathComponent == "manifest.xml" }.compactMap(fromManifest)
        let claimed = Set(result.map { $0.modelFile.standardizedFileURL.path })
        result += urls.filter { $0.pathExtension.lowercased() == "xml" && $0.lastPathComponent != "manifest.xml" && !claimed.contains($0.standardizedFileURL.path) }.map(inspect)
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    nonisolated static func fromManifest(_ url: URL) -> ModelPackage? {
        guard let doc = try? XMLDocument(contentsOf: url), let root = doc.rootElement(), root.name == "CustomModel" else { return nil }
        let file = url.deletingLastPathComponent().appendingPathComponent(root.attribute(forName: "FileName")?.stringValue ?? "model.xml")
        var result = inspect(file); result.manifestFile = url; result.stableID = root.attribute(forName: "ID")?.stringValue ?? result.stableID; result.name = root.attribute(forName: "Name")?.stringValue ?? result.name; result.category = root.attribute(forName: "Category")?.stringValue ?? "Player"; result.author = root.attribute(forName: "Author")?.stringValue ?? "Unknown"; result.skeleton = root.attribute(forName: "Skeleton")?.stringValue ?? "VectorHuman46"; return result
    }

    nonisolated static func inspect(_ url: URL) -> ModelPackage {
        let stable = url.deletingLastPathComponent().lastPathComponent == "custom_models" ? url.deletingPathExtension().lastPathComponent : url.deletingLastPathComponent().lastPathComponent
        var result = ModelPackage(modelFile: url, stableID: stable, name: stable.replacingOccurrences(of: "_", with: " ").capitalized)
        guard let doc = try? XMLDocument(contentsOf: url), doc.rootElement()?.name == "Scene" else { result.problem = "This file is not a readable Vector <Scene> model."; return result }
        result.nodeCount = (try? doc.nodes(forXPath: "/Scene/Nodes/*").count) ?? 0; result.figureCount = (try? doc.nodes(forXPath: "/Scene/Figures/*").count) ?? 0; result.isValid = result.nodeCount > 0; result.problem = result.isValid ? "Ready for Vector 2." : "The model has no nodes."; return result
    }

    func writeManifest() throws {
        let clean = String(stableID.lowercased().map { $0.isLetter || $0.isNumber ? $0 : Character("_") })
        guard isValid, !clean.isEmpty, modelFile.deletingLastPathComponent().path != modelFile.path else { throw NSError(domain: "Models", code: 3, userInfo: [NSLocalizedDescriptionKey: problem]) }
        let manifest = manifestFile ?? modelFile.deletingLastPathComponent().appendingPathComponent("manifest.xml")
        let root = XMLElement(name: "CustomModel"); ["ID": clean, "Name": name, "Category": category, "Author": author, "FileName": modelFile.lastPathComponent, "Skeleton": skeleton].forEach { root.addAttribute(XMLNode.attribute(withName: $0.key, stringValue: $0.value) as! XMLNode) }
        try XMLDocument(rootElement: root).xmlData(options: .nodePrettyPrint).write(to: manifest, options: .atomic)
    }
}
