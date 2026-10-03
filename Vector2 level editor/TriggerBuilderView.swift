import AppKit
import SwiftUI

struct TriggerBuilderView: View {
    @State private var definition: TriggerDefinition
    @State private var selectedLoop = 0
    @State private var rawXML = ""
    @State private var rawError = ""
    @State private var showGuide = true
    @State private var showSetupPanel = true
    @State private var showBehaviorPanel = true
    @State private var showRawPanel = true
    @State private var draftReview = TriggerRuntimeSchema.DraftReview(messages: [], proposedXML: nil)
    @State private var showFixPreview = false
    @State private var showXMLIssues = false
    @State private var templateIndex = XMLAssistantTemplateIndex()
    @State private var templateReload = 0
    @State private var previousCheckedXML: String?
    @AppStorage("vector2.triggerPredictiveCoding") private var predictiveCoding = true
    let projectRoot: URL?
    let applyTitle: String
    let modelReferences: [String]
    private var assistantIndex: XMLAssistantTemplateIndex { templateIndex.withModels(modelReferences) }
    let onApply: (TriggerDefinition) throws -> Void

    init(initial: TriggerDefinition? = nil, projectRoot: URL? = nil, applyTitle: String = "Add to Room", modelReferences: [String] = [], onApply: @escaping (TriggerDefinition) throws -> Void) {
        let value = initial ?? TriggerDefinition(name: "NewTrigger", bounds: .init(x: 0, y: 0, width: 320, height: 180), loops: [.init(events: [.init(node: .init(name: "Enter"))], actions: [])])
        _definition = State(initialValue: value)
        _rawXML = State(initialValue: (try? TriggerXMLCodec.encode(value)) ?? "")
        self.projectRoot = projectRoot
        self.applyTitle = applyTitle
        self.modelReferences = modelReferences
        self.onApply = onApply
    }

    private var diagnostics: [TriggerDiagnostic] { TriggerRuntimeSchema.validate(definition) }
    private var hasErrors: Bool { diagnostics.contains { $0.severity == .error } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                if showSetupPanel { ScrollView { identityAndPreview.padding(18) }.frame(minWidth: 280, idealWidth: 390) }
                if showBehaviorPanel { ScrollView { graph.padding(18) }.frame(minWidth: 380, idealWidth: 680) }
                if showRawPanel { rawPanel.frame(minWidth: 330, idealWidth: 390, maxWidth: .infinity) }
            }
            Divider()
            footer
        }
        .frame(minWidth: 1180, minHeight: 700)
        .onChange(of: definition) { _, value in rawXML = (try? TriggerXMLCodec.encode(value)) ?? rawXML }
        .task(id: "\(projectRoot?.path ?? ""):\(templateReload)") {
            let roots = Vector2AssetCatalog.xmlAssistantTemplateRoots(projectRoot: projectRoot)
            let packages = Vector2AssetCatalog.xmlAssistantPackageRoots(projectRoot: projectRoot)
            let index = await Task.detached(priority: .utility) { XMLAssistantTemplateIndex.load(roots: roots, packageRoots: packages) }.value
            guard !Task.isCancelled else { return }
            templateIndex = index
        }
        .onReceive(NotificationCenter.default.publisher(for: .vector2AssetCatalogChanged)) { _ in templateReload += 1 }
        .task(id: XMLAssistantDraftRequest(source: rawXML, templates: assistantIndex)) {
            let source = rawXML
            let templates = assistantIndex
            let previous = previousCheckedXML
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            let catalogues = ["Events": TriggerRuntimeSchema.events, "Conditions": TriggerRuntimeSchema.conditions,
                              "Actions": TriggerRuntimeSchema.actions, "Init": TriggerRuntimeSchema.actions]
            let review = await Task.detached(priority: .utility) {
                TriggerRuntimeSchema.reviewDraft(source, catalogues: catalogues, templates: templates, previousSource: previous)
            }.value
            guard !Task.isCancelled, rawXML == source else { return }
            draftReview = review
            if review.issues.isEmpty && !TriggerRuntimeSchema.isEmptyXMLDraft(source) { previousCheckedXML = source }
            showFixPreview = false
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.dashed.inset.filled").font(.title2.bold()).foregroundStyle(.white)
                .frame(width: 46, height: 46).background(.indigo.gradient, in: RoundedRectangle(cornerRadius: 13))
            VStack(alignment: .leading, spacing: 2) {
                Text("Trigger Designer").font(.title.bold())
                Text("Choose what starts the trigger and what happens next.").foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Toggle("Setup", isOn: $showSetupPanel).disabled(showSetupPanel && !showBehaviorPanel && !showRawPanel)
                Toggle("Behavior", isOn: $showBehaviorPanel).disabled(showBehaviorPanel && !showSetupPanel && !showRawPanel)
                Toggle("Raw XML", isOn: $showRawPanel).disabled(showRawPanel && !showSetupPanel && !showBehaviorPanel)
                Divider()
                Button("Raw XML only") { showSetupPanel = false; showBehaviorPanel = false; showRawPanel = true }
                Button("Show all panels") { showSetupPanel = true; showBehaviorPanel = true; showRawPanel = true }
            } label: { Label("Panels", systemImage: "rectangle.split.3x1") }
            Button { showGuide.toggle() } label: { Label("Guide", systemImage: "questionmark.circle") }
            templatesMenu
            Menu("Choose an outcome") {
                Button("Show dialogue when entered") { definition = TriggerPreset.dialogue(id: firstID(in: "custom_dialogue") ?? "dialogue_id", bounds: definition.bounds) }
                Button("Door: finish run and open a custom zone") { replaceWithZoneDoor(firstID(in: "custom_zones") ?? "zone_id") }
                Button("Complete a quest objective") { replaceWithSingle(event: "Enter", action: "ExecuteCall", attributes: ["Message": "QuestEventName"]) }
                Button("Start a tutorial") { replaceWithSingle(event: "Enter", action: "ExecuteCall", attributes: ["Message": "Content.Tutorial:\(firstID(in: "custom_tutorials") ?? "tutorial_id")"]) }
                Button("Start a story") { replaceWithSingle(event: "Enter", action: "ExecuteCall", attributes: ["Message": "Content.Story:\(firstID(in: "custom_story") ?? "story_id")"]) }
                Button("Send a project event") { replaceWithSingle(event: "Enter", action: "ExecuteCall", attributes: ["Message": "Content.CustomEvent:event_id"]) }
                Divider()
                Button("Play a sound") { replaceWithSingle(event: "Enter", action: "Sound", attributes: ["Name": firstID(in: "custom_audio") ?? "sound_id", "Action": "Play", "Channel": "Sound", "Volume": "1"]) }
                Button("Play music when the room starts") { replaceWithSingle(event: "OnStartGame", action: "Music", attributes: ["Track": firstID(in: "custom_audio") ?? "music_id", "Action": "Play"]) }
                Button("Kill the player") { replaceWithSingle(event: "Enter", action: "Kill", attributes: ["Model": "Player"]) }
            }
        }.padding(.horizontal, 20).padding(.vertical, 14)
    }

    private var templatesMenu: some View {
        Menu {
            Menu("Complete game triggers") {
                ForEach(TriggerTemplateCatalogue.whole) { item in
                    Button {
                        TriggerTemplateCatalogue.apply(.whole(item.reference), to: &definition)
                        selectedLoop = 0
                    } label: { VStack(alignment: .leading) { Text(item.title); Text(item.reference) } }
                }
            }
            Menu("Add to current loop") {
                Section("WHEN") {
                    ForEach(TriggerTemplateCatalogue.loops.filter { $0.kind == .event }) { item in templateButton(item, selection: .event(item.reference)) }
                }
                Section("IF") {
                    ForEach(TriggerTemplateCatalogue.loops.filter { $0.kind == .condition }) { item in templateButton(item, selection: .condition(item.reference)) }
                }
                Section("DO") {
                    ForEach(TriggerTemplateCatalogue.loops.filter { $0.kind == .action }) { item in templateButton(item, selection: .action(item.reference)) }
                }
            }.disabled(!definition.loops.indices.contains(selectedLoop))
            Menu("Add complete loop") {
                ForEach(TriggerTemplateCatalogue.loops.filter { $0.kind == .loop }) { item in templateButton(item, selection: .loop(item.reference)) }
            }
        } label: { Label("Game Templates", systemImage: "shippingbox") }
        .help("Triggers and blocks from Vector 2's trigger_templates.xml")
    }

    private func templateButton(_ item: TriggerTemplateEntry, selection: TriggerTemplateSelection) -> some View {
        Button {
            TriggerTemplateCatalogue.apply(selection, to: &definition, selectedLoop: selectedLoop)
            if case .loop = selection { selectedLoop = max(0, definition.loops.count - 1) }
        } label: { Text("\(item.title) — \(item.reference)") }
        .help(item.detail)
    }

    private var identityAndPreview: some View {
        VStack(alignment: .leading, spacing: 16) {
            if showGuide { beginnerGuide }
            TriggerCanvasPreview(definition: definition)
            section("Trigger area", "This box is the part of the room that can detect the player.") {
                TextField("Trigger name", text: $definition.name).textFieldStyle(.roundedBorder)
                HStack { integer("X", binding: $definition.bounds.x); integer("Y", binding: $definition.bounds.y) }
                HStack { integer("Width", binding: $definition.bounds.width); integer("Height", binding: $definition.bounds.height) }
            }
            section("Starting variables", "Set the values this trigger begins with. Vector also adds its required runtime variables when you save.") {
                ForEach(definition.initNodes.indices, id: \.self) { index in
                    let node = definition.initNodes[index]
                    if node.name == "SetVariable" {
                        HStack(spacing: 7) {
                            TextField("$Variable", text: initAttributeBinding(index, "Name")).textFieldStyle(.roundedBorder)
                            Picker("Type", selection: initAttributeBinding(index, "Type")) {
                                ForEach(["Bool", "Int", "Float", "String", "Node", "AI"], id: \.self) { Text($0).tag($0) }
                            }.labelsHidden().frame(width: 90)
                            TextField("Initial value", text: initAttributeBinding(index, "Value")).textFieldStyle(.roundedBorder)
                            Button(role: .destructive) { definition.initNodes.remove(at: index) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                        }
                    }
                }
                Button { definition.initNodes.append(.init(name: "SetVariable", attributes: ["Name": "$Variable", "Type": "Bool", "Value": "0"])) } label: {
                    Label("Add variable", systemImage: "plus")
                }
            }
            section("Checks", "Fix red errors before saving. Orange warnings usually mean the file contains advanced game XML.") {
                if diagnostics.isEmpty { Label("Ready for Vector 2", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                ForEach(Array(diagnostics.enumerated()), id: \.offset) { _, diagnostic in
                    Label(diagnostic.message, systemImage: diagnostic.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(diagnostic.severity == .error ? .red : .orange)
                }
            }
        }
    }

    private var beginnerGuide: some View {
        section("Trigger guide", "Start with a preset, then change the pieces you need.") {
            VStack(alignment: .leading, spacing: 10) {
                guideRow("1", "WHEN", "The event that starts this loop. Enter fires when the player enters the trigger box. OnStartGame fires when the run begins.")
                guideRow("2", "IF", "Optional rules that must be true. Leave this empty if the action should always run.")
                guideRow("3", "DO", "The actions Vector runs in order. A loop can play sound, send a message, finish a run, or do several things.")
                Divider()
                Text("Messages").font(.subheadline.bold())
                Text("ExecuteCall sends a Message to another project system. The part before the colon says what should receive it; the part after the colon is that item's Stable ID.")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Content.Zone:maintenance_3  — select a zone")
                    Text("Content.Dialogue:intro  — open dialogue")
                    Text("Content.Tutorial:movement  — start a tutorial")
                    Text("Content.Story:chapter_intro  — start a story")
                    Text("Content.CustomEvent:VaultOpened  — broadcast your own event")
                }.font(.caption.monospaced()).textSelection(.enabled)
                Text("Quest objectives are different: send the objective's event name exactly as written, without Content.CustomEvent: in front of it.")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                Text("Using game XML").font(.subheadline.bold())
                Text("Open a trigger or room from the Trigger Library. If a room has several triggers, you'll find each one under Opened File. Saving keeps game nodes this editor doesn't recognize.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("To put a saved trigger into a room: open the room, choose Tools → Triggers, pick the trigger, then choose Place in Open Room. Move or resize it on the canvas and save the room normally.")
                    .font(.caption).foregroundStyle(.blue)
                DisclosureGroup("Raw XML basics") {
                    Text("A trigger begins with <Trigger Name=\"...\" X=\"...\" Y=\"...\" Width=\"...\" Height=\"...\">. Inside <Content>, each <Loop> contains <Events>, optional <Conditions>, and <Actions>. Apply XML checks your changes and rebuilds the visual editor. If it reports an error, the current visual trigger is left unchanged.")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled).padding(.top, 5)
                }
            }
        }
    }

    private func guideRow(_ number: String, _ word: String, _ explanation: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number).font(.caption.bold()).foregroundStyle(.white).frame(width: 22, height: 22).background(Color.indigo, in: Circle())
            VStack(alignment: .leading, spacing: 2) { Text(word).font(.caption.bold()); Text(explanation).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func firstID(in folderName: String) -> String? {
        guard let projectRoot else { return nil }
        let folder = projectRoot.appendingPathComponent(folderName, isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return nil }
        return files.first(where: { $0.pathExtension.lowercased() == "xml" })?.deletingPathExtension().lastPathComponent
    }

    private func replaceWithZoneDoor(_ zoneID: String) {
        definition.loops = [.init(
            events: [.init(node: .init(name: "Enter"))],
            actions: [
                .init(node: .init(name: "ExecuteCall", attributes: ["Message": "Content.Zone:\(zoneID)"])),
                .init(node: .init(name: "EndGame", attributes: ["Result": "Win", "Model": "Player", "Frames": "30"]))
            ]
        )]
        selectedLoop = 0
    }

    private var graph: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Behavior").font(.title2.bold())
                Spacer()
                Picker("Loop", selection: $selectedLoop) {
                    ForEach(definition.loops.indices, id: \.self) { Text("Loop \($0 + 1)").tag($0) }
                }.frame(width: 150)
                Button { definition.loops.append(.init(events: [.init(node: .init(name: "Enter"))])); selectedLoop = definition.loops.count - 1 } label: { Label("Loop", systemImage: "plus") }
                Button(role: .destructive) { removeSelectedLoop() } label: { Image(systemName: "trash") }.disabled(definition.loops.count == 1)
            }
            if definition.loops.isEmpty {
                ContentUnavailableView("Game template controls this trigger", systemImage: "shippingbox.fill", description: Text("Use Game Templates to replace it, or add a Loop to extend it."))
            }
            if definition.loops.indices.contains(selectedLoop) {
                nodeColumn(title: "WHEN", subtitle: "Any listed event can wake this loop.", nodes: eventNodes, catalogue: TriggerRuntimeSchema.events, add: addEvent, remove: removeEvent, attributeBinding: eventAttributeBinding)
                nodeColumn(title: "IF", subtitle: "Every condition must pass before actions run.", nodes: conditionNodes, catalogue: TriggerRuntimeSchema.conditions, add: addCondition, remove: removeCondition, attributeBinding: conditionAttributeBinding)
                nodeColumn(title: "DO", subtitle: "Actions run from top to bottom.", nodes: actionNodes, catalogue: TriggerRuntimeSchema.actions, add: addAction, remove: removeAction, attributeBinding: actionAttributeBinding)
            }
        }
    }

    private func nodeColumn(title: String, subtitle: String, nodes: [TriggerXMLNode], catalogue: [TriggerRuntimeItem], add: @escaping (TriggerRuntimeItem) -> Void, remove: @escaping (Int) -> Void, attributeBinding: @escaping (Int, String) -> Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { VStack(alignment: .leading) { Text(title).font(.caption.bold()).foregroundStyle(.indigo); Text(subtitle).font(.caption).foregroundStyle(.secondary) }; Spacer(); Menu { ForEach(catalogue) { item in Button(item.title) { add(item) } } } label: { Label("Add", systemImage: "plus") } }
            ForEach(Array(nodes.enumerated()), id: \.element.id) { index, node in
                VStack(alignment: .leading, spacing: 8) {
                    HStack { Image(systemName: title == "WHEN" ? "bolt.circle" : "arrow.right.circle").foregroundStyle(.indigo); Text(node.name).fontWeight(.semibold); Spacer(); Button(role: .destructive) { remove(index) } label: { Image(systemName: "trash") }.buttonStyle(.borderless) }
                    let keys = attributeKeys(for: node, in: catalogue)
                    if keys.isEmpty { Text("No settings needed.").font(.caption).foregroundStyle(.secondary) }
                    ForEach(keys, id: \.self) { key in
                        HStack {
                            Text(key).font(.caption.monospaced()).frame(width: 110, alignment: .leading)
                            TextField(key, text: attributeBinding(index, key)).textFieldStyle(.roundedBorder)
                            let choices = projectChoices(for: key, node: node)
                            if !choices.isEmpty {
                                Menu { ForEach(choices, id: \.self) { choice in Button(choice) { attributeBinding(index, key).wrappedValue = choice } } } label: {
                                    Image(systemName: "list.bullet.rectangle")
                                }.menuStyle(.borderlessButton).help("Pick from this project instead of typing an ID.")
                            }
                        }
                    }
                    Divider()
                }.padding(12).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 13))
            }
        }.padding(15).background(.indigo.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
    }

    private var rawPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Trigger.xml", systemImage: "doc.text").font(.system(size: 13, weight: .semibold))
                    Text("XML Assistant · Click an error line for help").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Button { showXMLIssues.toggle() } label: {
                    Image(systemName: draftReview.messages.isEmpty && rawError.isEmpty ? "checkmark.shield" : "exclamationmark.bubble")
                    Text(draftReview.messages.isEmpty && rawError.isEmpty ? "Checks" : "Issues \(draftReview.messages.count + (rawError.isEmpty ? 0 : 1))")
                }.popover(isPresented: $showXMLIssues) { xmlIssuesPanel }
                Button("Format", action: formatRawXML)
                Button("Revert", action: revertRawXML)
            }.controlSize(.small)
            TriggerXMLCodeEditor(text: $rawXML, predictiveCoding: predictiveCoding, templates: assistantIndex, review: draftReview)
            .frame(minHeight: 320, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(.secondary.opacity(0.14)))
            HStack { Button("Apply XML") { applyRawXML(); if !rawError.isEmpty { showXMLIssues = true } }; Spacer(); Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(rawXML, forType: .string) } }
        }.padding(14)
    }

    private var xmlIssuesPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("XML checks", systemImage: "checkmark.shield").font(.headline)
            if !rawError.isEmpty { Text(rawError).font(.caption).foregroundStyle(.red) }
            if draftReview.messages.isEmpty && rawError.isEmpty {
                Text("No issues found so far. Apply XML to check the full trigger.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(draftReview.issues.prefix(8).enumerated()), id: \.offset) { _, issue in
                VStack(alignment: .leading, spacing: 4) {
                    Label("Line \(issue.line): \(issue.message)", systemImage: "exclamationmark.circle").font(.caption.weight(.semibold)).foregroundStyle(.red)
                    Text(issue.explanation).font(.caption).foregroundStyle(.secondary)
                    if !issue.solutions.isEmpty {
                        XMLIssueFixButton(issue: issue, review: draftReview, draft: $rawXML)
                    }
                }
            }
            if let proposal = draftReview.proposedXML {
                Button(showFixPreview ? "Hide fix preview" : "Preview suggested fix") { showFixPreview.toggle() }
                if showFixPreview {
                    Text("Review the proposed XML before applying. This can repair a stray empty tag, tag capitalization, or a missing attribute with a known default.")
                        .font(.caption).foregroundStyle(.secondary)
                    ScrollView { Text(proposal).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 140)
                    Button("Apply suggested fix") {
                        guard draftReview.source == rawXML else { return }
                        rawXML = proposal; showFixPreview = false
                    }
                }
            }
        }.padding(18).frame(width: 380)
    }

    private func formatRawXML() {
        do {
            let document = try XMLDocument(xmlString: rawXML)
            rawXML = document.xmlString(options: [.nodePrettyPrint])
            rawError = ""
        } catch { rawError = "Cannot format yet: \(error.localizedDescription)" }
    }

    private func revertRawXML() {
        rawXML = (try? TriggerXMLCodec.encode(definition)) ?? rawXML
        rawError = ""
    }

    private var footer: some View {
        HStack {
            Text("\(definition.loops.count) loop\(definition.loops.count == 1 ? "" : "s") · \(actionNodes.count) selected-loop actions").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button(applyTitle) { do { try onApply(definition) } catch { rawError = error.localizedDescription } }.buttonStyle(.borderedProminent).disabled(hasErrors)
        }.padding(14)
    }

    private func section<Content: View>(_ title: String, _ subtitle: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) { Text(title).font(.headline); Text(subtitle).font(.caption).foregroundStyle(.secondary); content() }
            .padding(14).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 15))
    }
    private func integer(_ label: String, binding: Binding<Int>) -> some View { VStack(alignment: .leading) { Text(label).font(.caption); TextField(label, value: binding, format: .number).textFieldStyle(.roundedBorder) } }
    private var eventNodes: [TriggerXMLNode] { definition.loops.indices.contains(selectedLoop) ? definition.loops[selectedLoop].events.map(\.node) : [] }
    private var actionNodes: [TriggerXMLNode] { definition.loops.indices.contains(selectedLoop) ? definition.loops[selectedLoop].actions.map(\.node) : [] }
    private var conditionNodes: [TriggerXMLNode] { definition.loops.indices.contains(selectedLoop) ? definition.loops[selectedLoop].conditions : [] }
    private func addEvent(_ item: TriggerRuntimeItem) { definition.loops[selectedLoop].events.append(.init(node: .init(name: item.xmlName, attributes: initialAttributes(item)))) }
    private func addAction(_ item: TriggerRuntimeItem) { definition.loops[selectedLoop].actions.append(.init(node: .init(name: item.xmlName, attributes: initialAttributes(item)))) }
    private func addCondition(_ item: TriggerRuntimeItem) { definition.loops[selectedLoop].conditions.append(.init(name: item.xmlName, attributes: initialAttributes(item))) }
    private func removeEvent(_ index: Int) { definition.loops[selectedLoop].events.remove(at: index) }
    private func removeAction(_ index: Int) { definition.loops[selectedLoop].actions.remove(at: index) }
    private func removeCondition(_ index: Int) { definition.loops[selectedLoop].conditions.remove(at: index) }
    private func initialAttributes(_ item: TriggerRuntimeItem) -> [String: String] { var value = item.suggestedAttributes; item.requiredAttributes.forEach { value[$0, default: ""] = "" }; return value }
    private func attributeKeys(for node: TriggerXMLNode, in catalogue: [TriggerRuntimeItem]) -> [String] {
        var keys = Set(node.attributes.keys)
        if let schema = catalogue.first(where: { $0.xmlName == node.name }) {
            keys.formUnion(schema.requiredAttributes)
            keys.formUnion(schema.suggestedAttributes.keys)
        }
        return keys.sorted()
    }
    private func eventAttributeBinding(_ index: Int, _ key: String) -> Binding<String> { Binding(get: { definition.loops[selectedLoop].events[index].node.attributes[key] ?? "" }, set: { definition.loops[selectedLoop].events[index].node.attributes[key] = $0 }) }
    private func actionAttributeBinding(_ index: Int, _ key: String) -> Binding<String> { Binding(get: { definition.loops[selectedLoop].actions[index].node.attributes[key] ?? "" }, set: { definition.loops[selectedLoop].actions[index].node.attributes[key] = $0 }) }
    private func conditionAttributeBinding(_ index: Int, _ key: String) -> Binding<String> { Binding(get: { definition.loops[selectedLoop].conditions[index].attributes[key] ?? "" }, set: { definition.loops[selectedLoop].conditions[index].attributes[key] = $0 }) }
    private func initAttributeBinding(_ index: Int, _ key: String) -> Binding<String> { Binding(get: { definition.initNodes[index].attributes[key] ?? "" }, set: { definition.initNodes[index].attributes[key] = $0 }) }
    private func removeSelectedLoop() { definition.loops.remove(at: selectedLoop); selectedLoop = max(0, min(selectedLoop, definition.loops.count - 1)) }
    private func applyRawXML() { do { definition = try TriggerXMLCodec.decode(rawXML); selectedLoop = 0; rawError = "" } catch { rawError = error.localizedDescription } }
    private func replaceWithSingle(event: String, action: String, attributes: [String: String]) { definition.loops = [.init(events: [.init(node: .init(name: event))], actions: [.init(node: .init(name: action, attributes: attributes))])]; selectedLoop = 0 }

    private func insertCompletion(_ item: TriggerRuntimeItem, kind: TriggerCodingAssistant.Kind) {
        let attributes = initialAttributes(item).keys.sorted().map { key in
            " \(key)=\"\(initialAttributes(item)[key] ?? "")\""
        }.joined()
        let fragment = "  <\(item.xmlName)\(attributes) />\n"
        do {
            rawXML = try TriggerCodingAssistant.inserting(fragment, kind: kind, loopIndex: selectedLoop, into: rawXML)
            rawError = ""
        } catch { rawError = error.localizedDescription }
    }

    private func projectChoices(for key: String, node: TriggerXMLNode) -> [String] {
        guard let projectRoot else { return [] }
        if key == "Name", node.name == "SetVariable" || key == "Value" {
            let names = TriggerCodingAssistant.variableNames(in: definition.initNodes)
            if !names.isEmpty { return names }
        }
        let folders: [String]
        switch (node.name, key) {
        case ("Sound", "Name"), ("SoundSource", "Name"), ("Music", "Track"): folders = ["custom_audio"]
        case ("TutorialSequence", "Name"): folders = ["custom_tutorials"]
        case ("ExecuteCall", "Message"): folders = ["custom_dialogue", "custom_story", "custom_quests", "custom_zones"]
        case ("Transform", "Name"): return []
        default: return []
        }
        return folders.flatMap { folder in
            let url = projectRoot.appendingPathComponent(folder, isDirectory: true)
            let files = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            return files.filter { $0.pathExtension.lowercased() == "xml" }.map { file in
                let id = file.deletingPathExtension().lastPathComponent
                guard node.name == "ExecuteCall" else { return id }
                if folder == "custom_dialogue" { return "Content.Dialogue:\(id)" }
                if folder == "custom_story" { return "Content.Story:\(id)" }
                if folder == "custom_zones" { return "Content.Zone:\(id)" }
                return id
            }
        }.sorted()
    }
}

private struct XMLIssueFixButton: View {
    let issue: TriggerRuntimeSchema.DraftIssue
    let review: TriggerRuntimeSchema.DraftReview
    @Binding var draft: String
    @State private var showing = false
    var body: some View {
        Button("View suggested fixes") { showing = true }
            .popover(isPresented: $showing) {
                TriggerXMLIssueCard(issue: issue, proposal: review.proposedXML, source: review.source) { code in
                    guard draft == review.source else { showing = false; return }
                    draft = code
                    showing = false
                }
            }
    }
}
