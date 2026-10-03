import Foundation
import SwiftUI

struct StoryGraphNode: Identifiable, Equatable {
    var id = UUID().uuidString.prefix(8).lowercased()
    var type = "Dialogue"
    var title = ""
    var text = ""
    var value = ""
    var alternate = ""
    var choiceA = "Continue"
    var choiceB = "Leave"
}

struct StoryGraphDocument: Identifiable, Equatable {
    var id = UUID().uuidString.prefix(8).lowercased()
    var name = "New Story"
    var trigger = "Chapter Start"
    var reference = ""
    var once = true
    var nodes = [StoryGraphNode(type: "Dialogue")]
    var file: URL?
}

/// Story blocks map to Vector 2 runtime operations.
struct StoryGraphView: View {
    let projectRoot: URL
    let onStatus: (String) -> Void
    @State private var graphs: [StoryGraphDocument] = []
    @State private var selectedGraphID: String?
    @State private var selectedNodeID: String?

    private var folder: URL { projectRoot.appendingPathComponent("custom_story") }
    private var graphIndex: Int? { graphs.firstIndex { $0.id == selectedGraphID } }
    private var nodeIndex: Int? {
        guard let graphIndex else { return nil }
        return graphs[graphIndex].nodes.firstIndex { $0.id == selectedNodeID }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                graphList.frame(minWidth: 230, idealWidth: 260, maxWidth: 300)
                if let graphIndex { graphEditor($graphs[graphIndex]) }
                else { ContentUnavailableView("Create a story", systemImage: "point.3.connected.trianglepath.dotted") }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear(perform: reload)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "point.3.connected.trianglepath.dotted").font(.title2).foregroundStyle(.white)
                .frame(width: 48, height: 48).background(Color.indigo.gradient, in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 2) {
                Text("Story Graph").font(.system(size: 27, weight: .bold))
                Text("Choose what happens next after each line, choice, or quest event.").foregroundStyle(.secondary)
            }
            Spacer()
            Button { createGraph() } label: { Label("New Story", systemImage: "plus") }.buttonStyle(.borderedProminent)
        }.padding(.horizontal, 24).padding(.vertical, 16).background(Color(nsColor: .controlBackgroundColor).opacity(0.94))
    }

    private var graphList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("STORIES").font(.caption.bold()).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.top, 16)
            ScrollView {
                LazyVStack(spacing: 7) {
                    ForEach(graphs) { graph in
                        Button { selectedGraphID = graph.id; selectedNodeID = graph.nodes.first?.id } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "arrow.triangle.branch").foregroundStyle(.indigo)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(graph.name).fontWeight(.semibold).lineLimit(1)
                                    Text("\(graph.nodes.count) blocks · \(graph.trigger)").font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }.padding(10).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .background(selectedGraphID == graph.id ? Color.indigo.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 11))
                    }
                }.padding(.horizontal, 9)
            }
        }.background(Color(nsColor: .controlBackgroundColor).opacity(0.8))
    }

    private func graphEditor(_ graph: Binding<StoryGraphDocument>) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .bottom, spacing: 14) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Story name").font(.caption.bold()).foregroundStyle(.secondary)
                        TextField("Story name", text: graph.name).textFieldStyle(.roundedBorder).font(.title3.bold())
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Starts when").font(.caption.bold()).foregroundStyle(.secondary)
                        Picker("Starts when", selection: graph.trigger) {
                            ForEach(["Menu Open", "Chapter Start", "Zone Selected", "Floor Start", "Custom Event"], id: \.self) { Text($0).tag($0) }
                        }.labelsHidden().pickerStyle(.menu)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Matching chapter, zone, floor or event").font(.caption.bold()).foregroundStyle(.secondary)
                        TextField("Optional", text: graph.reference).textFieldStyle(.roundedBorder)
                    }
                    Toggle("Only once", isOn: graph.once).toggleStyle(.checkbox)
                }.padding(18).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 17))

                HStack {
                    Label("Flow", systemImage: "arrow.right.circle.fill").font(.headline)
                    Spacer()
                    ForEach([("Dialogue", "text.bubble"), ("Entrance", "person.crop.circle.badge.plus"), ("Choice", "arrow.triangle.branch"), ("QuestSignal", "scope"), ("SetFlag", "flag"), ("Branch", "point.3.connected.trianglepath.dotted"), ("Cutscene", "film"), ("SceneEvent", "bolt.horizontal.circle"), ("End", "stop.circle")], id: \.0) { item in
                        Button { addNode(item.0) } label: { Image(systemName: item.1) }.help("Add \(displayName(item.0))")
                    }
                }
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(Array(graph.wrappedValue.nodes.enumerated()), id: \.element.id) { index, node in
                            nodeCard(node, number: index + 1)
                            if index < graph.wrappedValue.nodes.count - 1 { Image(systemName: "arrow.right").foregroundStyle(.secondary) }
                        }
                    }.padding(.vertical, 4)
                }
                .padding(16).background(Color.indigo.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))

                if let graphIndex, let nodeIndex { nodeInspector($graphs[graphIndex].nodes[nodeIndex], graph: graphs[graphIndex]) }

                HStack {
                    Button("Delete Story", role: .destructive, action: deleteGraph)
                    Spacer(); Button("Revert", action: reload)
                    Button("Save Story", action: saveGraph).buttonStyle(.borderedProminent).controlSize(.large)
                }
            }.frame(maxWidth: 1180).padding(24).frame(maxWidth: .infinity)
        }
    }

    private func nodeCard(_ node: StoryGraphNode, number: Int) -> some View {
        Button { selectedNodeID = node.id } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack { Text("\(number)").font(.caption.bold()).foregroundStyle(.white).frame(width: 25, height: 25).background(nodeColor(node.type), in: Circle()); Spacer(); Image(systemName: nodeSymbol(node.type)).foregroundStyle(nodeColor(node.type)) }
                Text(displayName(node.type)).fontWeight(.bold)
                Text(nodeSummary(node)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }.padding(14).frame(width: 170, height: 112, alignment: .topLeading).contentShape(Rectangle())
        }.buttonStyle(.plain).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 15))
            .overlay(RoundedRectangle(cornerRadius: 15).stroke(selectedNodeID == node.id ? nodeColor(node.type) : Color.secondary.opacity(0.18), lineWidth: selectedNodeID == node.id ? 2 : 1))
    }

    private func nodeInspector(_ node: Binding<StoryGraphNode>, graph: StoryGraphDocument) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Edit \(displayName(node.wrappedValue.type))", systemImage: nodeSymbol(node.wrappedValue.type)).font(.title3.bold()).foregroundStyle(nodeColor(node.wrappedValue.type))
                Spacer(); Button { moveNode(-1) } label: { Image(systemName: "arrow.left") }; Button { moveNode(1) } label: { Image(systemName: "arrow.right") }
                Button("Remove", role: .destructive, action: removeNode)
            }
            Divider()
            switch node.wrappedValue.type {
            case "Dialogue": pickerField("Dialogue", selection: node.value, choices: xmlIDs(folder: "custom_dialogue", xpath: "//Dialogue", attribute: "Id"))
            case "Entrance":
                pickerField("Character", selection: node.value, choices: xmlIDs(folder: "custom_characters", xpath: "//Character", attribute: "Id"))
                field("What they say", text: node.text, multiline: true)
            case "Choice":
                field("Question", text: node.text, multiline: true)
                HStack { field("First answer", text: node.choiceA); targetPicker("Goes to", selection: node.value, graph: graph) }
                HStack { field("Second answer", text: node.choiceB); targetPicker("Goes to", selection: node.alternate, graph: graph) }
            case "QuestSignal": field("Quest event name", text: node.value)
            case "SetFlag": HStack { field("Story flag", text: node.title); field("Value", text: node.value) }
            case "Branch":
                HStack { field("Story flag", text: node.title); field("Equals", text: node.text) }
                HStack { targetPicker("If true", selection: node.value, graph: graph); targetPicker("If false", selection: node.alternate, graph: graph) }
            case "Cutscene": field("Cutscene cue event", text: node.value)
            case "SceneEvent": field("Event name", text: node.value)
            default: Text("The story stops here.").foregroundStyle(.secondary)
            }
        }.padding(18).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 17))
    }

    private func field(_ title: String, text: Binding<String>, multiline: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 5) { Text(title).font(.caption.bold()).foregroundStyle(.secondary); TextField(title, text: text, axis: multiline ? .vertical : .horizontal).textFieldStyle(.roundedBorder).lineLimit(multiline ? 2...5 : 1...1) }.frame(maxWidth: .infinity)
    }
    private func pickerField(_ title: String, selection: Binding<String>, choices: [String]) -> some View {
        VStack(alignment: .leading, spacing: 5) { Text(title).font(.caption.bold()).foregroundStyle(.secondary); Picker(title, selection: selection) { Text("Choose…").tag(""); ForEach(choices, id: \.self) { Text($0).tag($0) } }.labelsHidden().pickerStyle(.menu) }
    }
    private func targetPicker(_ title: String, selection: Binding<String>, graph: StoryGraphDocument) -> some View {
        VStack(alignment: .leading, spacing: 5) { Text(title).font(.caption.bold()).foregroundStyle(.secondary); Picker(title, selection: selection) { Text("End story").tag(""); ForEach(graph.nodes) { Text("\(displayName($0.type)) · \($0.id)").tag(String($0.id)) } }.labelsHidden().pickerStyle(.menu) }.frame(maxWidth: .infinity)
    }

    private func addNode(_ type: String) { guard let graphIndex else { return }; let node = StoryGraphNode(type: type); graphs[graphIndex].nodes.append(node); selectedNodeID = node.id }
    private func removeNode() { guard let graphIndex, let nodeIndex else { return }; graphs[graphIndex].nodes.remove(at: nodeIndex); selectedNodeID = graphs[graphIndex].nodes.first?.id }
    private func moveNode(_ amount: Int) { guard let graphIndex, let nodeIndex else { return }; let target = nodeIndex + amount; guard graphs[graphIndex].nodes.indices.contains(target) else { return }; graphs[graphIndex].nodes.swapAt(nodeIndex, target) }
    private func createGraph() { let graph = StoryGraphDocument(); graphs.insert(graph, at: 0); selectedGraphID = graph.id; selectedNodeID = graph.nodes.first?.id }

    private func saveGraph() {
        guard let graphIndex else { return }; var graph = graphs[graphIndex]
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let root = XMLElement(name: "StoryGraphs"), graphNode = XMLElement(name: "StoryGraph")
            attributes(["Id": graph.id, "Name": graph.name, "Trigger": graph.trigger, "Reference": graph.reference, "Once": graph.once ? "1" : "0", "Start": String(graph.nodes.first?.id ?? "")], on: graphNode)
            for (index, item) in graph.nodes.enumerated() {
                let node = XMLElement(name: "Node"); let automaticNext = index + 1 < graph.nodes.count ? String(graph.nodes[index + 1].id) : ""
                var values = ["Id": String(item.id), "Type": item.type, "Next": automaticNext]
                switch item.type {
                case "Dialogue": values["Dialogue"] = item.value
                case "Entrance": values["Speaker"] = item.value; values["Text"] = item.text
                case "QuestSignal": values["Signal"] = item.value
                case "SetFlag": values["Flag"] = item.title; values["Value"] = item.value
                case "Branch": values["Flag"] = item.title; values["Equals"] = item.text; values["True"] = item.value; values["False"] = item.alternate
                case "Cutscene", "SceneEvent": values["Event"] = item.value
                default: break
                }
                attributes(values, on: node)
                if item.type == "Choice" {
                    attributes(["Title": item.title, "Text": item.text], on: node)
                    for (label, next) in [(item.choiceA, item.value), (item.choiceB, item.alternate)] { let choice = XMLElement(name: "Choice"); attributes(["Text": label, "Next": next], on: choice); node.addChild(choice) }
                }
                graphNode.addChild(node)
            }
            root.addChild(graphNode); let document = XMLDocument(rootElement: root); document.characterEncoding = "utf-8"
            let output = graph.file ?? folder.appendingPathComponent("\(safe(graph.id)).xml")
            try document.xmlData(options: .nodePrettyPrint).write(to: output, options: .atomic); graph.file = output; graphs[graphIndex] = graph
            onStatus("Saved \(graph.name). Install Changes sends the playable graph to Vector 2.")
        } catch { onStatus("Could not save story: \(error.localizedDescription)") }
    }

    private func reload() {
        graphs = loadGraphs(); selectedGraphID = graphs.first?.id; selectedNodeID = graphs.first?.nodes.first?.id
    }
    private func deleteGraph() {
        guard let graphIndex else { return }
        let graph = graphs[graphIndex]
        do {
            if let file = graph.file { try FileManager.default.removeItem(at: file) }
            graphs.remove(at: graphIndex)
            selectedGraphID = graphs.first?.id
            selectedNodeID = graphs.first?.nodes.first?.id
            onStatus("Deleted \(graph.name). Install Changes removes its old game copy.")
        } catch {
            onStatus("Could not delete \(graph.name): \(error.localizedDescription)")
            reload()
        }
    }

    private func loadGraphs() -> [StoryGraphDocument] {
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension.lowercased() == "xml" }
        return files.compactMap { url in
            guard let doc = try? XMLDocument(contentsOf: url), let root = (try? doc.nodes(forXPath: "//StoryGraph"))?.first as? XMLElement else { return nil }
            var graph = StoryGraphDocument(id: root.attribute(forName: "Id")?.stringValue ?? url.deletingPathExtension().lastPathComponent, name: root.attribute(forName: "Name")?.stringValue ?? "Story", trigger: root.attribute(forName: "Trigger")?.stringValue ?? "Chapter Start", reference: root.attribute(forName: "Reference")?.stringValue ?? "", once: root.attribute(forName: "Once")?.stringValue != "0", nodes: [], file: url)
            graph.nodes = root.elements(forName: "Node").map { node in
                let a: (String) -> String = { node.attribute(forName: $0)?.stringValue ?? "" }; let choices = node.elements(forName: "Choice")
                return StoryGraphNode(id: a("Id"), type: a("Type"), title: a("Flag").isEmpty ? a("Title") : a("Flag"), text: a("Text").isEmpty ? a("Equals") : a("Text"), value: ["Dialogue": "Dialogue", "Entrance": "Speaker", "QuestSignal": "Signal", "SetFlag": "Value", "Branch": "True", "Cutscene": "Event", "SceneEvent": "Event"][a("Type")].map(a) ?? (choices.first?.attribute(forName: "Next")?.stringValue ?? ""), alternate: a("Type") == "Branch" ? a("False") : (choices.dropFirst().first?.attribute(forName: "Next")?.stringValue ?? ""), choiceA: choices.first?.attribute(forName: "Text")?.stringValue ?? "Continue", choiceB: choices.dropFirst().first?.attribute(forName: "Text")?.stringValue ?? "Leave")
            }
            return graph
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func attributes(_ values: [String: String], on node: XMLElement) { values.forEach { node.addAttribute(XMLNode.attribute(withName: $0.key, stringValue: $0.value) as! XMLNode) } }
    private func safe(_ value: String) -> String { value.filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" } }
    private func xmlIDs(folder name: String, xpath: String, attribute: String) -> [String] {
        let root = projectRoot.appendingPathComponent(name); guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        let values = e.compactMap { $0 as? URL }.filter { $0.pathExtension.lowercased() == "xml" }.flatMap { url in ((try? XMLDocument(contentsOf: url).nodes(forXPath: xpath)) ?? []).compactMap { ($0 as? XMLElement)?.attribute(forName: attribute)?.stringValue } }
        return Array(Set(values)).sorted()
    }
    private func displayName(_ type: String) -> String { ["Entrance": "Character Entrance", "QuestSignal": "Quest Signal", "SetFlag": "Set Story Flag", "Cutscene": "Cutscene Cue", "SceneEvent": "Scene Event"][type] ?? type }
    private func nodeSymbol(_ type: String) -> String { ["Dialogue": "text.bubble", "Entrance": "person.crop.circle.badge.plus", "Choice": "arrow.triangle.branch", "QuestSignal": "scope", "SetFlag": "flag", "Branch": "point.3.connected.trianglepath.dotted", "Cutscene": "film", "SceneEvent": "bolt.horizontal.circle", "End": "stop.circle"][type] ?? "square" }
    private func nodeColor(_ type: String) -> Color { ["Dialogue": .blue, "Entrance": .cyan, "Choice": .indigo, "QuestSignal": .orange, "SetFlag": .green, "Branch": .purple, "Cutscene": .pink, "SceneEvent": .mint, "End": .red][type] ?? .gray }
    private func nodeSummary(_ node: StoryGraphNode) -> String { node.type == "Entrance" ? (node.value.isEmpty ? "Choose a character" : node.value) : node.type == "Dialogue" ? (node.value.isEmpty ? "Choose dialogue" : node.value) : node.type == "End" ? "Finish this story" : (node.value.isEmpty ? "Configure this block" : node.value) }
}
