import AppKit
import SwiftUI

// These forms write the XML read by CustomProjectCatalog.
struct ProjectContentCreator: View {
    let section: String
    let projectRoot: URL
    var editingURL: URL? = nil
    var embedded = false
    var onCancel: (() -> Void)? = nil
    let onFinish: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var id = ""
    @State private var name = ""
    @State private var details = ""
    @State private var parent = ""
    @State private var artwork = ""
    @State private var extra = ""
    @State private var language = "Default"
    @State private var mainBackground = ""
    @State private var loaderBackground = ""
    @State private var tricksPath = ""
    @State private var order = ""
    @State private var error = ""
    @State private var questStart = "When the menu opens"
    @State private var questSteps = [QuestSequenceStep(title: "Reach the objective", event: "QuestGoalReached")]
    @State private var questStartReference = ""
    @State private var questRawXML = ""
    @State private var questRawStatus = ""
    @State private var rewardType = "None"
    @State private var rewardName = ""
    @State private var rewardVisualName = ""
    @State private var contentTrigger = "Manual"
    @State private var triggerReference = ""
    @State private var triggerOnce = true
    @State private var chapterFloors = [1]

    private var itemName: String { String(section.dropLast(section.hasSuffix("s") ? 1 : 0)) }
    private var title: String { editingURL == nil ? "New \(itemName)" : "Edit \(itemName)" }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Button(action: close) { Label("Back to \(section)", systemImage: "chevron.left") }.buttonStyle(.plain).foregroundStyle(.blue)
                Divider().frame(height: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 27, weight: .bold))
                    Text(helpText).foregroundStyle(.secondary)
                }
                Spacer()
                Button(editingURL == nil ? "Create \(itemName)" : "Save Changes") { create() }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.padding(.horizontal, 26).frame(height: 82).background(Color(nsColor: .controlBackgroundColor).opacity(0.84))
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if section == "Quests" { questJourney }
                    editorCard("Basics", "Give this a name and an ID you can find later.", "square.and.pencil") {
                        field(idLabel, "A short unique ID, such as chapter_3 or rooftop_escape.", text: $id)
                        if section != "Localization" { field("Display name", "The name shown in the editor and game.", text: $name) }
                        if ["Chapters", "Zones", "Dialogue", "Quests"].contains(section) {
                            field(section == "Dialogue" ? "Dialogue text" : "Description", "Write what you want people to read.", text: $details, multiline: true)
                        }
                        if section == "Localization" {
                            field("Language", "Use Default for the fallback text.", text: $language)
                            field("Translated value", "The phrase players will see.", text: $details, multiline: true)
                        }
                    }
                    if section == "Zones" {
                        editorCard("Menu & Story", "Choose where this zone belongs and how its menu dot is presented.", "circle.grid.3x3") {
                            field("Chapter ID", "The chapter containing this zone.", text: $parent)
                            field("Menu position", "3 creates the next dot after the two original zones.", text: $order)
                            imagePicker("Menu artwork", "Shown on the zone card or selector.", selection: $artwork)
                            imagePicker("Main menu background", "Shown while this zone is selected.", selection: $mainBackground, backgroundsFirst: true)
                            imagePicker("Loading background", "Shown while entering the zone.", selection: $loaderBackground, backgroundsFirst: true)
                        }
                        editorCard("Gameplay Content", "Pick the rooms and tricks this zone can use.", "gamecontroller") {
                            zoneFolderPicker(
                                title: "Room pool",
                                help: "Every room inside this folder can be generated in this zone. Variants stay inside each room.",
                                rootFolder: "custom_rooms",
                                selection: $extra
                            )
                            field("Tricks folder", "For example custom_tricks/chapter_3.", text: $tricksPath)
                        }
                    }
                    if section == "Chapters" {
                        editorCard("Chapter Content", "Connect existing zone IDs to this chapter.", "square.3.layers.3d") {
                            field("Zones", "Separate zone IDs with commas. You can also assign the chapter from each Zone screen.", text: $extra)
                            imagePicker("Chapter artwork", "Artwork used to represent this chapter.", selection: $artwork)
                        }
                        ChapterFloorDesigner(floors: $chapterFloors)
                    }
                    if section == "Dialogue" {
                        editorCard("Speaker & Presentation", "Connect this line to a character and its on-screen controls.", "person.wave.2") {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Speaker").font(.headline)
                                Text("Choose a character already created in Characters.").font(.caption).foregroundStyle(.secondary)
                                Picker("Speaker", selection: $parent) {
                                    Text("No speaker").tag("")
                                    ForEach(characterChoices, id: \.id) { character in Text(character.name).tag(character.id) }
                                }.labelsHidden().pickerStyle(.menu)
                                if characterChoices.isEmpty { Text("Create a character first so dialogue never points at a made-up ID.").font(.caption).foregroundStyle(.orange) }
                            }
                            field("Continue button", "Text such as Continue, or a localization phrase key.", text: $extra)
                            imagePicker("Override portrait", "Optional. Leave empty to use the selected character's portrait.", selection: $artwork)
                        }
                        ContentTriggerPicker(trigger: $contentTrigger, reference: $triggerReference, once: $triggerOnce, contentName: "conversation")
                    }
                    if section == "Characters" {
                        editorCard("Appearance", "How this character appears during story dialogue.", "person.crop.circle") {
                            imagePicker("Portrait", "Choose from the images already imported into this project.", selection: $artwork)
                            Text("Accent colour").font(.headline)
                            HStack(spacing: 10) {
                                ForEach(["#62C9FF", "#9B7BFF", "#FF5C7A", "#FFB347", "#53D769", "#FFFFFF"], id: \.self) { value in
                                    Button { extra = value } label: {
                                        Circle().fill(paletteColor(value)).frame(width: 30, height: 30)
                                            .overlay(Circle().stroke(extra == value ? Color.primary : Color.clear, lineWidth: 3))
                                    }.buttonStyle(.plain)
                                }
                                TextField("#62C9FF", text: $extra).textFieldStyle(.roundedBorder).frame(maxWidth: 130)
                            }
                        }
                    }
                    if section == "Quests" {
                        editorCard("Quest Start", "Choose when Vector activates this sequence.", "play.circle") {
                            Picker("Start", selection: $questStart) {
                                Text("When the menu opens").tag("When the menu opens")
                                Text("After another quest").tag("After another quest")
                                Text("When a zone is selected").tag("When a zone is selected")
                                Text("When a chapter starts").tag("When a chapter starts")
                                Text("When a floor starts").tag("When a floor starts")
                                Text("From a custom event").tag("From a custom event")
                            }.pickerStyle(.menu)
                            if questStart == "After another quest" {
                                field("Previous quest ID", "This quest starts after that quest completes.", text: $parent)
                            } else if questStart != "When the menu opens" {
                                field(startReferenceLabel, "Use the exact stable ID, floor number, or event name.", text: $questStartReference)
                            }
                        }
                        editorCard("Level Sequence", "Add the objectives in the exact order the player must complete them.", "list.number") {
                            Text("Each room trigger sends the matching event. Vector advances one step at a time; later events cannot skip earlier objectives.")
                                .font(.caption).foregroundStyle(.secondary)
                            ForEach(questSteps.indices, id: \.self) { index in
                                HStack(alignment: .top, spacing: 12) {
                                    Text("\(index + 1)").font(.headline).foregroundStyle(.white)
                                        .frame(width: 30, height: 30).background(Color.indigo, in: Circle())
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text("Objective shown to the player").font(.caption.bold()).foregroundStyle(.secondary)
                                        TextField("For example: Enter the locked laboratory", text: $questSteps[index].title).textFieldStyle(.roundedBorder)
                                        Text("Trigger event ID").font(.caption.bold()).foregroundStyle(.secondary)
                                        TextField("For example: LaboratoryEntered", text: $questSteps[index].event).textFieldStyle(.roundedBorder)
                                        HStack {
                                            Text("Place a room trigger that sends this exact event.").font(.caption2).foregroundStyle(.secondary)
                                            Spacer()
                                            Button("Copy Trigger XML") { copyQuestTrigger(for: questSteps[index]) }
                                                .buttonStyle(.borderless).help("Paste this into Trigger Designer Raw XML, then place it in the room.")
                                        }
                                        HStack {
                                            TextField("Animated visual ID (optional)", text: $questSteps[index].visualGroup)
                                                .textFieldStyle(.roundedBorder)
                                            Picker("Change to GIF", selection: $questSteps[index].visualGIF) {
                                                Text("No artwork change").tag("")
                                                ForEach(projectGIFs, id: \.self) { gif in Text(gif).tag(gif) }
                                            }.frame(maxWidth: 240)
                                        }
                                        Text("When this objective completes, the named visual plays the selected GIF without moving or resizing.")
                                            .font(.caption2).foregroundStyle(.secondary)
                                    }
                                    VStack(spacing: 4) {
                                        Button { moveQuestStep(index, by: -1) } label: { Image(systemName: "chevron.up") }.disabled(index == 0)
                                        Button { moveQuestStep(index, by: 1) } label: { Image(systemName: "chevron.down") }.disabled(index == questSteps.count - 1)
                                        Button(role: .destructive) { questSteps.remove(at: index) } label: { Image(systemName: "trash") }.disabled(questSteps.count == 1)
                                    }.buttonStyle(.borderless)
                                }.padding(12).background(Color.indigo.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                            }
                            Button { questSteps.append(.init(title: "New objective", event: "QuestEvent\(questSteps.count + 1)")) } label: {
                                Label("Add Objective", systemImage: "plus")
                            }.buttonStyle(.borderedProminent)
                        }
                        editorCard("Reward", "Configure what the player sees and receives when the quest completes.", "gift") {
                            Picker("Reward type", selection: $rewardType) {
                                Text("No item reward").tag("None")
                                Text("Custom reward").tag("CustomReward")
                                Text("Native reward preset").tag("Preset")
                            }.pickerStyle(.segmented)
                            if rewardType != "None" {
                                field(rewardType == "Preset" ? "Native reward preset ID" : "Custom reward ID", rewardType == "Preset" ? "Use an existing Vector reward preset." : "Use the stable ID from the Rewards tool. The game grants it when this quest completes.", text: $rewardName)
                            }
                            field("Reward label", "The friendly reward name shown to the player.", text: $rewardVisualName)
                            imagePicker("Reward image", "Choose from the images already imported into this project.", selection: $artwork)
                        }
                        if editingURL != nil {
                            editorCard("Advanced Quest XML", "Every native event, condition and action remains available when the visual presets are not enough.", "chevron.left.forwardslash.chevron.right") {
                                TextEditor(text: $questRawXML)
                                    .font(.system(.caption, design: .monospaced))
                                    .frame(minHeight: 260)
                                    .padding(8)
                                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
                                HStack {
                                    Text(questRawStatus).font(.caption).foregroundStyle(questRawStatus.hasPrefix("Saved") ? .green : .red)
                                    Spacer()
                                    Button("Reload File", action: reloadQuestXML)
                                    Button("Validate & Apply", action: applyQuestXML).buttonStyle(.borderedProminent)
                                }
                            }
                        }
                    }
                    if !error.isEmpty { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).padding(14).background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 12)) }
                }.frame(maxWidth: 930).padding(26).frame(maxWidth: .infinity)
            }.background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(width: embedded ? nil : 760, height: embedded ? nil : 720)
        .onAppear(perform: loadExisting)
    }

    private func copyQuestTrigger(for step: QuestSequenceStep) {
        let event = step.event.trimmingCharacters(in: .whitespacesAndNewlines)
        let safe = event.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
        let xml = """
        <Trigger Name="Quest_\(safe)" X="0" Y="0" Width="320" Height="180">
          <Content>
            <Loop>
              <Events><Enter/></Events>
              <Actions><ExecuteCall Message="\(safe)"/></Actions>
            </Loop>
          </Content>
        </Trigger>
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(xml, forType: .string)
    }

    private var questJourney: some View {
        HStack(spacing: 0) {
            journeyStep("1", "Story", "Name what players are doing", .blue)
            journeyLine
            journeyStep("2", "Start", "Choose when it activates", .indigo)
            journeyLine
            journeyStep("3", "Sequence", "Build ordered level objectives", .purple)
            journeyLine
            journeyStep("4", "Reward", "Complete only after the last step", .green)
        }
        .padding(22).background(LinearGradient(colors: [Color.blue.opacity(0.12), Color.purple.opacity(0.06)], startPoint: .leading, endPoint: .trailing), in: RoundedRectangle(cornerRadius: 20))
    }

    private func journeyStep(_ number: String, _ title: String, _ subtitle: String, _ color: Color) -> some View {
        VStack(spacing: 7) {
            Text(number).font(.headline).foregroundStyle(.white).frame(width: 36, height: 36).background(color.gradient, in: Circle())
            Text(title).fontWeight(.semibold)
            Text(subtitle).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center).lineLimit(2)
        }.frame(maxWidth: .infinity)
    }

    private var journeyLine: some View { Rectangle().fill(Color.secondary.opacity(0.2)).frame(width: 35, height: 2).offset(y: -22) }

    private func editorCard<Content: View>(_ title: String, _ subtitle: String, _ icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon).font(.title2).foregroundStyle(.blue).frame(width: 28)
                VStack(alignment: .leading, spacing: 3) { Text(title).font(.title3.bold()); Text(subtitle).font(.callout).foregroundStyle(.secondary) }
            }
            Divider(); content()
        }.padding(20).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.blue.opacity(0.12)))
    }

    private func field(_ title: String, _ help: String, text: Binding<String>, multiline: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline); Text(help).font(.caption).foregroundStyle(.secondary)
            if multiline { TextField(title, text: text, axis: .vertical).lineLimit(3...7).textFieldStyle(.roundedBorder) }
            else { TextField(title, text: text).textFieldStyle(.roundedBorder) }
        }
    }

    private func imagePicker(_ title: String, _ help: String, selection: Binding<String>, backgroundsFirst: Bool = false) -> some View {
        let choices = importedImages(backgroundsFirst: backgroundsFirst)
        return VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Text(help).font(.caption).foregroundStyle(.secondary)
            Picker(title, selection: selection) {
                Text("None").tag("")
                if !selection.wrappedValue.isEmpty && !choices.contains(selection.wrappedValue) {
                    Text("Missing: \(selection.wrappedValue)").tag(selection.wrappedValue)
                }
                ForEach(choices, id: \.self) { value in
                    Text(value).tag(value)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)
            if choices.isEmpty {
                Text("Import an image in Assets or Backgrounds first.")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private func zoneFolderPicker(title: String, help: String, rootFolder: String, selection: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Text(help).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Image(systemName: "folder.fill")
                    .font(.title2)
                    .foregroundStyle(.blue)
                    .frame(width: 42, height: 42)
                    .background(Color.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    Text(selection.wrappedValue.isEmpty ? "No folder selected" : selection.wrappedValue)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("Stored as a project-relative path")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Choose Folder…") { chooseProjectFolder(rootFolder: rootFolder, selection: selection) }
                    .buttonStyle(.borderedProminent)
            }
            .padding(12)
            .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08)))
        }
    }

    private func chooseProjectFolder(rootFolder: String, selection: Binding<String>) {
        let allowedRoot = projectRoot.appendingPathComponent(rootFolder, isDirectory: true).standardizedFileURL
        try? FileManager.default.createDirectory(at: allowedRoot, withIntermediateDirectories: true)
        let panel = NSOpenPanel()
        panel.title = "Choose this zone's room pool"
        panel.prompt = "Choose Room Pool"
        panel.message = "Choose an existing room folder. External folders are imported into this project so it stays portable."
        panel.directoryURL = allowedRoot
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let chosen = panel.url?.standardizedFileURL else { return }

        let rootPath = allowedRoot.path.hasSuffix("/") ? allowedRoot.path : allowedRoot.path + "/"
        if chosen.path != allowedRoot.path && !chosen.path.hasPrefix(rootPath) {
            let cleanID = safeFilename(id.trimmingCharacters(in: .whitespacesAndNewlines))
            let destinationName = cleanID.isEmpty ? safeFilename(chosen.lastPathComponent) : cleanID
            let destination = allowedRoot.appendingPathComponent(destinationName, isDirectory: true)
            do {
                try importFolderContents(from: chosen, into: destination)
                selection.wrappedValue = "\(rootFolder)/\(destinationName)"
                error = ""
            } catch {
                self.error = "Could not import that room folder: \(error.localizedDescription)"
            }
            return
        }
        let relativeTail = chosen.path == allowedRoot.path ? "" : String(chosen.path.dropFirst(rootPath.count))
        selection.wrappedValue = relativeTail.isEmpty ? rootFolder : "\(rootFolder)/\(relativeTail)"
        error = ""
    }

    private func importFolderContents(from source: URL, into destination: URL) throws {
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        guard let enumerator = FileManager.default.enumerator(at: source, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return }
        for case let item as URL in enumerator {
            let relative = String(item.path.dropFirst(source.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !relative.isEmpty else { continue }
            let target = destination.appendingPathComponent(relative)
            let directory = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            if directory {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            } else {
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
                try FileManager.default.copyItem(at: item, to: target)
            }
        }
    }

    private func importedImages(backgroundsFirst: Bool) -> [String] {
        let folders = backgroundsFirst ? ["custom_backgrounds", "custom_textures"] : ["custom_textures", "custom_backgrounds"]
        let extensions = Set(["png", "jpg", "jpeg", "bmp", "gif", "tif", "tiff", "webp"])
        var seen = Set<String>()
        var result: [String] = []
        for folder in folders {
            let root = projectRoot.appendingPathComponent(folder, isDirectory: true)
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in enumerator where extensions.contains(url.pathExtension.lowercased()) {
                // Runtime's custom texture resolver accepts the filename or stem.
                // Keeping the filename makes duplicate names in subfolders obvious.
                let value = url.lastPathComponent
                if seen.insert(value.lowercased()).inserted { result.append(value) }
            }
        }
        return result.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private var projectGIFs: [String] {
        let folder = projectRoot.appendingPathComponent("custom_textures", isDirectory: true)
        return ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "gif" }
            .map(\.lastPathComponent)
            .sorted()
    }

    private var characterChoices: [(id: String, name: String)] {
        let folder = projectRoot.appendingPathComponent("custom_characters", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        return files.compactMap { url in
            guard url.pathExtension.lowercased() == "xml", let document = try? XMLDocument(contentsOf: url),
                  let character = document.rootElement()?.elements(forName: "Character").first,
                  let id = character.attribute(forName: "Id")?.stringValue, !id.isEmpty else { return nil }
            return (id, character.attribute(forName: "Name")?.stringValue ?? id)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func paletteColor(_ value: String) -> Color {
        let rgb: [String: (Double, Double, Double)] = [
            "#62C9FF": (0.38, 0.79, 1), "#9B7BFF": (0.61, 0.48, 1), "#FF5C7A": (1, 0.36, 0.48),
            "#FFB347": (1, 0.70, 0.28), "#53D769": (0.33, 0.84, 0.41), "#FFFFFF": (1, 1, 1)
        ]
        let color = rgb[value] ?? (0.38, 0.79, 1)
        return Color(red: color.0, green: color.1, blue: color.2)
    }

    private func close() { if let onCancel { onCancel() } else { dismiss() } }

    private var idLabel: String { section == "Localization" ? "Phrase key" : section == "Quests" ? "Quest name / ID" : "Stable ID" }
    private var helpText: String {
        switch section {
        case "Chapters": return "Groups custom zones into a chapter. Zone IDs can be added now or later."
        case "Zones": return "Connects a stable zone ID to a chapter and custom_rooms folder."
        case "Quests": return "Set up the quest steps here. The editor writes the trigger XML."
        case "Dialogue": return "Write a line that a quest or room trigger can play by DialogueId."
        case "Characters": return "Add a speaker for your story dialogue."
        case "Localization": return "Add a phrase for one language. Default fills in when a translation is missing."
        default: return "Add custom content for your project."
        }
    }

    private func create() {
        let cleanID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanID.contains("/"), !cleanID.contains("\\"), cleanID != ".", cleanID != ".." else {
            error = "Use a simple ID without slashes."
            return
        }
        guard let folder = folderName else { error = "This section uses file importing instead."; return }
        if section == "Quests" {
            let invalid = questSteps.first { $0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || $0.event.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            guard !questSteps.isEmpty, invalid == nil else { error = "Every quest objective needs a player-facing instruction and a room event."; return }
            let events = questSteps.map { $0.event.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            guard Set(events).count == events.count else { error = "Each quest step needs a unique room event."; return }
            for step in questSteps where !step.visualGIF.isEmpty {
                let group = step.visualGroup.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !group.isEmpty, group.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else {
                    error = "A GIF change needs a Visual ID using letters, numbers, _ or -. Set the same ID on the GIF in the room inspector."; return
                }
                guard projectGIFs.contains(step.visualGIF) else { error = "The selected GIF is missing from Project Assets."; return }
            }
        }
        if section == "Zones" {
            // A zone without its own room folder used to fall back to the global
            // custom-room pool. That is how Maintenance rooms ended up in Lab.
            if extra.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                extra = "custom_rooms/\(safeFilename(cleanID))"
            }
            if tricksPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                tricksPath = "custom_tricks/\(safeFilename(cleanID))"
            }
        }
        let destination = editingURL ?? projectRoot.appendingPathComponent(folder).appendingPathComponent(safeFilename(cleanID) + ".xml")
        guard editingURL != nil || !FileManager.default.fileExists(atPath: destination.path) else { error = "That ID already exists. Select it from the list to edit it."; return }
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if section == "Zones" {
                try createProjectSubfolder(extra)
                try createProjectSubfolder(tricksPath)
            }
            try document(cleanID).xmlData(options: .nodePrettyPrint).write(to: destination, options: .atomic)
            onFinish("Created \(destination.lastPathComponent).")
            close()
        } catch { self.error = error.localizedDescription }
    }

    private func createProjectSubfolder(_ relativePath: String) throws {
        let clean = relativePath.replacingOccurrences(of: "\\", with: "/").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !clean.isEmpty, !clean.split(separator: "/").contains("..") else { return }
        try FileManager.default.createDirectory(at: projectRoot.appendingPathComponent(clean, isDirectory: true), withIntermediateDirectories: true)
    }

    private func loadExisting() {
        guard let editingURL,
              let document = try? XMLDocument(contentsOf: editingURL),
              let root = document.rootElement(),
              let item = root.children?.compactMap({ $0 as? XMLElement }).first else { return }
        if section == "Quests" { questRawXML = document.xmlString(options: .nodePrettyPrint) }
        func attribute(_ key: String) -> String { item.attribute(forName: key)?.stringValue ?? "" }
        switch section {
        case "Chapters":
            id = attribute("Id"); name = attribute("Name"); details = attribute("Description"); artwork = attribute("Artwork")
            extra = item.elements(forName: "Zone").compactMap { $0.attribute(forName: "Id")?.stringValue }.joined(separator: ", ")
            chapterFloors = item.elements(forName: "Floor").compactMap { Int($0.attribute(forName: "Number")?.stringValue ?? "") }
            if chapterFloors.isEmpty { chapterFloors = [1] }
        case "Zones":
            id = attribute("Id"); parent = attribute("Chapter"); name = attribute("Name"); details = attribute("Description"); extra = attribute("RoomsPath"); artwork = attribute("Artwork")
            mainBackground = attribute("MainBackground"); loaderBackground = attribute("LoaderBackground"); tricksPath = attribute("TricksPath"); order = attribute("Order")
        case "Dialogue":
            id = attribute("Id"); parent = attribute("Speaker"); name = attribute("Title"); details = attribute("Text"); extra = attribute("Button"); artwork = attribute("Image")
            contentTrigger = attribute("Trigger").isEmpty ? "Manual" : attribute("Trigger")
            triggerReference = attribute("Reference")
            triggerOnce = attribute("Once") != "0"
        case "Characters":
            id = attribute("Id"); name = attribute("Name"); artwork = attribute("Portrait"); extra = attribute("Color")
        case "Localization":
            id = attribute("Key"); language = attribute("Language"); details = attribute("Value")
        case "Quests":
            id = attribute("Name")
            if let info = item.elements(forName: "Info").first {
                name = info.elements(forName: "VisualName").first?.attribute(forName: "Value")?.stringValue ?? ""
                details = info.elements(forName: "Description").first?.attribute(forName: "Value")?.stringValue ?? ""
                if let reward = info.elements(forName: "Reward").first {
                    artwork = reward.attribute(forName: "ImageName")?.stringValue ?? ""
                    rewardType = reward.attribute(forName: "Type")?.stringValue ?? "None"
                    if rewardType == "Card" || rewardType == "StarterPack" { rewardType = "CustomReward" }
                    rewardName = reward.attribute(forName: "Name")?.stringValue ?? ""
                    rewardVisualName = reward.attribute(forName: "VisualName")?.stringValue ?? ""
                }
            }
            if let start = item.elements(forName: "StartTrigger").first,
               let previous = (try? start.nodes(forXPath: ".//CounterRange[@Namespace='ST_Quests'][@Equal='-1']"))?.first as? XMLElement {
                questStart = "After another quest"; parent = previous.attribute(forName: "Name")?.stringValue ?? ""
            } else if let event = (try? item.nodes(forXPath: ".//StartTrigger[@EditorManaged='1']//OnCall[@Name='Trigger']"))?.first as? XMLElement,
                      let signal = event.attribute(forName: "Message")?.stringValue {
                decodeQuestStartSignal(signal)
            }
            let sequence = item.elements(forName: "Trigger").filter { $0.attribute(forName: "EditorManaged")?.stringValue == "Sequence" }
            let loaded = sequence.compactMap { trigger -> QuestSequenceStep? in
                guard let event = (try? trigger.nodes(forXPath: ".//Events/OnCall[@Name='Trigger']"))?.first as? XMLElement,
                      let message = event.attribute(forName: "Message")?.stringValue, !message.isEmpty else { return nil }
                var step = QuestSequenceStep(title: trigger.attribute(forName: "EditorTitle")?.stringValue ?? trigger.attribute(forName: "Name")?.stringValue ?? "Objective", event: message)
                if let action = (try? trigger.nodes(forXPath: ".//Actions/ExecuteCall[starts-with(@Message, 'Content.Visual:')]"))?.first as? XMLElement,
                   let signal = action.attribute(forName: "Message")?.stringValue {
                    let parts = signal.components(separatedBy: ":")
                    if parts.count == 4 {
                        step.visualGroup = parts[2]
                        let stem = URL(fileURLWithPath: parts[3]).deletingPathExtension().lastPathComponent
                        step.visualGIF = String(stem.dropFirst(stem.hasPrefix("gif_") ? 4 : 0)) + ".gif"
                    }
                }
                return step
            }
            if !loaded.isEmpty { questSteps = loaded }
            else if let event = (try? item.nodes(forXPath: ".//Trigger[@EditorManaged='1']//Events/OnCall[@Name='Trigger']"))?.first as? XMLElement {
                questSteps = [.init(title: "Complete the objective", event: event.attribute(forName: "Message")?.stringValue ?? "QuestGoalReached")]
            }
        default: break
        }
    }

    private var folderName: String? {
        ["Chapters": "custom_chapters", "Zones": "custom_zones", "Quests": "custom_quests", "Dialogue": "custom_dialogue", "Characters": "custom_characters", "Localization": "custom_localization"][section]
    }

    private func document(_ cleanID: String) -> XMLDocument {
        if let editingURL,
           let existing = try? XMLDocument(contentsOf: editingURL),
           let item = existing.rootElement()?.children?.compactMap({ $0 as? XMLElement }).first {
            updateExisting(item, cleanID: cleanID)
            return existing
        }
        let rootName = section == "Localization" ? "Localization" : section
        let root = XMLElement(name: rootName)
        switch section {
        case "Chapters":
            let item = element("Chapter", ["Id": cleanID, "Name": name, "Description": details, "Artwork": artwork])
            for zone in csv(extra) { item.addChild(element("Zone", ["Id": zone])) }
            for floor in chapterFloors { item.addChild(element("Floor", ["Number": "\(floor)"])) }
            root.addChild(item)
        case "Zones":
            root.addChild(element("Zone", ["Id": cleanID, "Chapter": parent, "Name": name, "Description": details, "RoomsPath": extra, "Artwork": artwork, "MainBackground": mainBackground, "LoaderBackground": loaderBackground, "TricksPath": tricksPath, "Order": order]))
        case "Dialogue":
            root.addChild(element("Dialogue", ["Id": cleanID, "Speaker": parent, "Title": name, "Text": details, "Button": extra, "Image": artwork, "Trigger": contentTrigger, "Reference": triggerReference, "Once": triggerOnce ? "1" : "0"]))
        case "Characters":
            root.addChild(element("Character", ["Id": cleanID, "Name": name, "Portrait": artwork, "Color": extra]))
        case "Localization":
            root.addChild(element("Phrase", ["Key": cleanID, "Language": language.isEmpty ? "Default" : language, "Value": details]))
        case "Quests":
            let quest = element("Quest", ["Name": cleanID])
            let info = XMLElement(name: "Info")
            info.addChild(element("VisualName", ["Value": name]))
            info.addChild(element("Description", ["Value": details]))
            info.addChild(element("Reward", ["VisualName": rewardVisualName, "ImageName": artwork, "Name": rewardName, "Type": rewardType]))
            ensureQuestInfoAttributes(info)
            quest.addChild(info)
            addQuestTriggers(to: quest, id: cleanID)
            root.addChild(quest)
        default: break
        }
        let document = XMLDocument(rootElement: root)
        document.characterEncoding = "utf-8"
        document.version = "1.0"
        return document
    }

    private func updateExisting(_ item: XMLElement, cleanID: String) {
        switch section {
        case "Chapters":
            set(item, ["Id": cleanID, "Name": name, "Description": details, "Artwork": artwork])
            (item.elements(forName: "Zone") + item.elements(forName: "Floor")).forEach { $0.detach() }
            for zone in csv(extra) { item.addChild(element("Zone", ["Id": zone])) }
            for floor in chapterFloors { item.addChild(element("Floor", ["Number": "\(floor)"])) }
        case "Zones": set(item, ["Id": cleanID, "Chapter": parent, "Name": name, "Description": details, "RoomsPath": extra, "Artwork": artwork, "MainBackground": mainBackground, "LoaderBackground": loaderBackground, "TricksPath": tricksPath, "Order": order])
        case "Dialogue": set(item, ["Id": cleanID, "Speaker": parent, "Title": name, "Text": details, "Button": extra, "Image": artwork, "Trigger": contentTrigger, "Reference": triggerReference, "Once": triggerOnce ? "1" : "0"])
        case "Characters": set(item, ["Id": cleanID, "Name": name, "Portrait": artwork, "Color": extra])
        case "Localization": set(item, ["Key": cleanID, "Language": language.isEmpty ? "Default" : language, "Value": details])
        case "Quests":
            set(item, ["Name": cleanID])
            if let info = item.elements(forName: "Info").first {
                if let visual = info.elements(forName: "VisualName").first { set(visual, ["Value": name]) }
                if let description = info.elements(forName: "Description").first { set(description, ["Value": details]) }
                if let reward = info.elements(forName: "Reward").first { set(reward, ["VisualName": rewardVisualName, "ImageName": artwork, "Name": rewardName, "Type": rewardType]) }
                ensureQuestInfoAttributes(info)
            }
            let managed = item.children?.compactMap { $0 as? XMLElement }.filter { $0.attribute(forName: "EditorManaged") != nil } ?? []
            managed.forEach { $0.detach() }
            let oldStarter = item.elements(forName: "StartTrigger").first(where: { trigger in
                guard trigger.attribute(forName: "EditorManaged") == nil else { return false }
                return trigger.elements(forName: "Content").first?.children?.isEmpty ?? true
            })
            oldStarter?.detach()
            addQuestTriggers(to: item, id: cleanID)
        default: break
        }
    }

    private func addQuestTriggers(to quest: XMLElement, id: String) {
        let start = element("StartTrigger", ["Name": "StartQuest", "EditorManaged": "1"])
        let startContent = XMLElement(name: "Content"), startLoop = XMLElement(name: "Loop")
        let startEvents = XMLElement(name: "Events")
        if questStart == "After another quest" { startEvents.addChild(element("OnCall", ["Name": "QuestComplete"])) }
        else if questStart == "When the menu opens" { startEvents.addChild(element("OnScreen", ["Name": "Start"])) }
        else { startEvents.addChild(element("OnCall", ["Name": "Trigger", "Message": questStartSignal])) }
        let startConditions = XMLElement(name: "Conditions")
        startConditions.addChild(element("CounterRange", ["Name": id, "Namespace": "ST_Quests", "Equal": "0"]))
        if questStart == "After another quest", !parent.isEmpty { startConditions.addChild(element("CounterRange", ["Name": parent, "Namespace": "ST_Quests", "Equal": "-1"])) }
        let startActions = XMLElement(name: "Actions"); startActions.addChild(XMLElement(name: "QuestStart"))
        startActions.addChild(element("SetCounter", ["Name": "Step", "Namespace": id, "Value": "0"]))
        [startEvents, startConditions, startActions].forEach(startLoop.addChild); startContent.addChild(startLoop); start.addChild(startContent); quest.addChild(start)
        let reward = rewardType == "None" ? "" : rewardName
        QuestSequenceCompiler.progressTriggers(questID: id, steps: questSteps, rewardPreset: reward).forEach(quest.addChild)
    }

    private func ensureQuestInfoAttributes(_ info: XMLElement) {
        // Vector's Quest parser reads these as attributes even when there is no
        // reward art or label. Windows should emit the same empty attributes.
        for (elementName, attributes) in [
            ("VisualName", ["Value"]),
            ("Description", ["Value", "Progress"]),
            ("Reward", ["VisualName", "ImageName", "Name", "Type"])
        ] {
            guard let item = info.elements(forName: elementName).first else { continue }
            for attribute in attributes where item.attribute(forName: attribute) == nil {
                item.addAttribute(XMLNode.attribute(withName: attribute, stringValue: "") as! XMLNode)
            }
        }
    }

    private func set(_ node: XMLElement, _ attributes: [String: String]) {
        for (key, value) in attributes {
            node.removeAttribute(forName: key)
            if !value.isEmpty { node.addAttribute(XMLNode.attribute(withName: key, stringValue: value) as! XMLNode) }
        }
    }

    private func element(_ name: String, _ attributes: [String: String]) -> XMLElement {
        let node = XMLElement(name: name)
        for key in attributes.keys.sorted() where !attributes[key, default: ""].isEmpty {
            node.addAttribute(XMLNode.attribute(withName: key, stringValue: attributes[key, default: ""]) as! XMLNode)
        }
        return node
    }

    private func csv(_ value: String) -> [String] {
        value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private func safeFilename(_ value: String) -> String {
        value.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" }.reduce(into: "") { $0.append($1) }
    }

    private var startReferenceLabel: String {
        ["When a zone is selected": "Zone ID", "When a chapter starts": "Chapter ID", "When a floor starts": "Floor number", "From a custom event": "Event name"][questStart] ?? "Reference"
    }

    private var questStartSignal: String {
        let prefix = ["When a zone is selected": "Content.ZoneSelected", "When a chapter starts": "Content.ChapterStart", "When a floor starts": "Content.FloorStart", "From a custom event": "Content.CustomEvent"][questStart] ?? "Content.MenuOpen"
        return questStartReference.isEmpty ? prefix : "\(prefix):\(questStartReference)"
    }

    private func moveQuestStep(_ index: Int, by offset: Int) {
        let destination = index + offset
        guard questSteps.indices.contains(index), questSteps.indices.contains(destination) else { return }
        questSteps.swapAt(index, destination)
    }

    private func decodeQuestStartSignal(_ signal: String) {
        let mappings = [("Content.ZoneSelected", "When a zone is selected"), ("Content.ChapterStart", "When a chapter starts"), ("Content.FloorStart", "When a floor starts"), ("Content.CustomEvent", "From a custom event")]
        for (prefix, label) in mappings where signal == prefix || signal.hasPrefix(prefix + ":") {
            questStart = label
            questStartReference = signal == prefix ? "" : String(signal.dropFirst(prefix.count + 1))
            return
        }
    }

    private func reloadQuestXML() {
        guard let editingURL, let contents = try? String(contentsOf: editingURL, encoding: .utf8) else { return }
        questRawXML = contents
        questRawStatus = ""
    }

    private func applyQuestXML() {
        guard let editingURL else { return }
        do {
            let parsed = try XMLDocument(xmlString: questRawXML, options: [])
            guard parsed.rootElement()?.name == "Quests",
                  let quest = parsed.rootElement()?.elements(forName: "Quest").first,
                  !(quest.attribute(forName: "Name")?.stringValue ?? "").isEmpty,
                  quest.elements(forName: "StartTrigger").first?.elements(forName: "Content").first != nil else {
                questRawStatus = "Invalid quest: expected Quests/Quest with a name and StartTrigger/Content."
                return
            }
            parsed.version = "1.0"; parsed.characterEncoding = "utf-8"
            try parsed.xmlData(options: .nodePrettyPrint).write(to: editingURL, options: .atomic)
            questRawXML = parsed.xmlString(options: .nodePrettyPrint)
            questRawStatus = "Saved native quest XML."
        } catch {
            questRawStatus = "XML error: \(error.localizedDescription)"
        }
    }
}
