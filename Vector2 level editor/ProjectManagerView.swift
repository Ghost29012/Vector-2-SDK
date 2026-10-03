import AppKit
import SwiftUI
import UniformTypeIdentifiers

private struct ProjectSearchHit: Identifiable {
    let title: String
    let detail: String
    let symbol: String
    let section: String
    let file: URL?
    var id: String { section + "|" + (file?.path ?? title) }
}

// One project owns the folders that travel together. Browsing is read-only;
// saving project content installs it when Vector 2 Data is connected.
struct ProjectManagerView: View {
    let onOpenRoom: (String) -> Void
    let onOpenZoneBackgroundDesigner: () -> Void
    let onPlacePoolBackground: (URL) -> Void
    let onPlaceSceneBackground: (String) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var root: URL?
    @State private var name = ""
    @State private var author = ""
    @State private var version = "1.0.0"
    @State private var description = ""
    @AppStorage("projectManager.selectedSection") private var section = "Overview"
    @AppStorage("projectManager.backgroundTab") private var backgroundTab = "Library"
    @State private var files: [URL] = []
    @State private var query = ""
    @State private var searchHits: [ProjectSearchHit] = []
    @State private var searchFileIndex: [(category: String, file: URL)] = []
    @FocusState private var searchFocused: Bool
    @State private var status = "Create or open a project to begin."
    @State private var settings = false
    @State private var access: URL?
    @State private var coverPath = ""
    @State private var counts: [String: Int] = [:]
    @State private var validation = "Not checked"
    @State private var zones: [URL] = []
    @State private var zoneRoomCounts: [String: Int] = [:]
    @State private var zoneArtwork: [String: String] = [:]
    @State private var outputFolder = ""
    @State private var generateDebugData = false
    @State private var gameSourcePath = ""
    @State private var gameDataPath = ""
    @State private var liveSync = false
    @State private var gameSourceAccess: URL?
    @State private var gameDataAccess: URL?
    @State private var projectID = ""
    @State private var showingCreator = false
	@State private var creatorSection: String?
	@State private var storyWorkspaceSection = "Story"
    @State private var showingTrickStudio = false
    @State private var editingContentURL: URL?
    @State private var pendingProjectDelete: URL?
    private var ink: Color { colorScheme == .dark ? Color(red: 0.88, green: 0.92, blue: 0.98) : Color(red: 0.08, green: 0.16, blue: 0.29) }
    private let folders = [
        "Content": "custom_rooms", "Chapters": "custom_chapters", "Zones": "custom_zones",
        "Quests": "custom_quests", "Dialogue": "custom_dialogue", "Characters": "custom_characters",
        "Localization": "custom_localization", "Assets": "custom_textures",
        "Obstacles": "custom_obstacles",
        "Backgrounds": "custom_backgrounds", "Models": "custom_models", "Protocols": "custom_protocols",
        "Zone Background Pool": "custom_backgrounds_pool",
        "Tricks": "custom_tricks", "Traps": "custom_traps", "Audio": "custom_audio",
        "Upgrades": "custom_upgrades", "Missions": "custom_missions", "Rewards": "custom_rewards",
        "Tutorials": "custom_tutorials", "Story": "custom_story"
    ]
	private let sections = ["Overview", "Content", "Chapters", "Zones", "Story", "Trigger Designer", "Protocols", "Generator", "Quests", "Localization", "Models", "Traps", "Obstacles", "Tricks", "Upgrades", "Shop", "Missions", "Rewards", "Tutorials", "Audio", "Assets", "Backgrounds", "Save Data"]
    private let designedSections = ["Chapters", "Zones", "Quests", "Dialogue", "Characters", "Localization"]
    private let systemSections = ["Trigger Designer", "Protocols", "Generator", "Models", "Traps", "Upgrades", "Shop", "Missions", "Rewards", "Tutorials", "Audio", "Save Data"]
    private let mediaSections = ["Content", "Tricks", "Assets", "Backgrounds"]

    private var bg: Color { Color(nsColor: .windowBackgroundColor) }
    private var edge: Color { Color(nsColor: .separatorColor) }
    private let blue = Color(red: 0.29, green: 0.59, blue: 0.96)

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            VStack(spacing: 0) {
                topBar
                Group {
                if showingTrickStudio, let root {
                    CustomTrickStudioView(
                        gameDirectory: gameDataPath,
                        projectTricksDirectory: root.appendingPathComponent("custom_tricks"),
                        onClose: { showingTrickStudio = false; refresh() },
                        onStatus: { message in status = message; syncIfNeeded() }
                    )
                } else if showingCreator, let root {
					ProjectContentCreator(section: creatorSection ?? section, projectRoot: root, editingURL: editingContentURL, embedded: true, onCancel: {
						showingCreator = false; editingContentURL = nil; creatorSection = nil
					}) { message in
						status = message; showingCreator = false; editingContentURL = nil; creatorSection = nil; refresh(); syncIfNeeded()
                    }
                } else if section == "Overview" { overview }
                else if section == "Story", let root {
					storyWorkspace(root)
                }
                else if designedSections.contains(section), let root, let folder = folders[section] {
                    ProjectStructuredStudioView(
                        section: section,
                        folder: root.appendingPathComponent(folder),
                        files: filteredFiles,
						onImport: { importFiles() },
                        onCreate: { editingContentURL = nil; showingCreator = true },
                        onEdit: { editingContentURL = $0; showingCreator = true },
                        onDelete: deleteProjectItem
                    )
                }
                else if systemSections.contains(section), let root {
                    ProjectSystemStudioView(section: section, projectRoot: root,
                        gameDataRoot: gameDataPath.isEmpty ? nil : URL(fileURLWithPath: gameDataPath),
                        onOpenTrickStudio: { showingTrickStudio = true },
                        onStatus: { status = $0; refresh(); syncIfNeeded() })
                }
                else if section == "Tricks", let root {
                    TrickLibraryStudioView(
                        projectRoot: root,
						onImport: { importFiles() },
                        onCreate: { showingTrickStudio = true },
                        onOpenShop: { section = "Shop" },
                        onOpenUpgrades: { section = "Upgrades" },
                        onStatus: { status = $0; refresh(); syncIfNeeded() }
                    )
                }
                else if section == "Obstacles", let root {
                    ProjectObstacleLibraryView(projectRoot: root, files: filteredFiles, onChanged: { status = $0; refresh(); syncIfNeeded() })
                }
                else if section == "Backgrounds", let root, let folder = folders[section] {
                    VStack(alignment: .leading, spacing: 0) {
                        Picker("Backgrounds", selection: $backgroundTab) {
                            Text("Library").tag("Library")
                            Text("Zone Pool Designer").tag("Zone Pool Designer")
                        }
                        .pickerStyle(.segmented)
                        .fixedSize()
                        .padding(16)
                        .onChange(of: backgroundTab) { _, tab in
                            if tab == "Zone Pool Designer" {
                                onOpenZoneBackgroundDesigner()
                                backgroundTab = "Library"
                            }
                        }
                        ProjectMediaStudioView(section: section, folder: root.appendingPathComponent(folder), files: filteredFiles,
                            onImport: { importFiles() }, onOpenTrickStudio: { showingTrickStudio = true },
                            onOpenRoom: onOpenRoom, onOpenPoolBackground: onOpenZoneBackgroundDesigner,
                            onPlacePoolBackground: onPlacePoolBackground, onPlaceSceneBackground: onPlaceSceneBackground,
                            onDelete: deleteProjectItem, onChanged: syncIfNeeded)
                    }
                }
                else if mediaSections.contains(section), let root, let folder = folders[section] {
					ProjectMediaStudioView(section: section, folder: root.appendingPathComponent(folder), files: filteredFiles,
						onImport: { importFiles() }, onOpenTrickStudio: { showingTrickStudio = true }, onOpenRoom: onOpenRoom,
                        onOpenPoolBackground: onOpenZoneBackgroundDesigner, onPlacePoolBackground: onPlacePoolBackground,
                        onPlaceSceneBackground: onPlaceSceneBackground,
                        onDelete: deleteProjectItem, onChanged: syncIfNeeded)
                }
                else { fileBrowser }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                statusBar
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(ink).font(.system(size: 14))
        .onAppear(perform: restoreProject)
        .alert("Delete this project item?", isPresented: Binding(
            get: { pendingProjectDelete != nil },
            set: { if !$0 { pendingProjectDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) { pendingProjectDelete = nil }
            Button("Delete", role: .destructive) {
                guard let target = pendingProjectDelete else { return }
                pendingProjectDelete = nil
                deleteProjectItem(target)
            }
        } message: {
            Text("This removes \(pendingProjectDelete?.lastPathComponent ?? "the item") from the project. Install Changes will also clean its previously installed game copy.")
        }
        .onDisappear {
            if root != nil { save() }
            access?.stopAccessingSecurityScopedResource()
            gameSourceAccess?.stopAccessingSecurityScopedResource()
            gameDataAccess?.stopAccessingSecurityScopedResource()
            access = nil; root = nil
        }
    }

    private var sidebar: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 0) {
            Text("Vector 2 Editor").font(.system(size: 21, weight: .bold)).padding(.top, 28)
            Text("Project Manager").font(.system(size: 15)).foregroundStyle(.secondary).padding(.top, 3).padding(.bottom, 26)
            sideLink("Overview", "house.fill")
            sideLink("Content", "folder")
            sideLink("Chapters", "books.vertical")
            sideLink("Zones", "square.3.layers.3d")
			sideLink("Story & Dialogue", "bubble.left.and.text.bubble.right") { section = "Story" }
            sideLink("Trigger Designer", "square.dashed.inset.filled")
            sideLink("Protocols", "shield.lefthalf.filled")
            sideLink("Generator", "point.3.connected.trianglepath.dotted")
            sideLink("Quests", "bookmark")
            sideLink("Localization", "character.book.closed")
            sideLink("Models", "cube")
            sideLink("Obstacles", "shippingbox")
            sideLink("Traps", "bolt.trianglebadge.exclamationmark")
            sideLink("Tricks", "figure.run")
            sideLink("Upgrades", "arrow.up.circle")
            sideLink("Shop", "cart")
            sideLink("Missions", "scope")
            sideLink("Rewards", "gift")
            sideLink("Tutorials", "graduationcap")
            sideLink("Audio", "music.note")
            sideLink("Assets", "photo.on.rectangle.angled")
            sideLink("Backgrounds", "photo")
            sideLink("Save Data", "externaldrive")
            Divider().padding(.vertical, 12)
            sideCommand("Validation", "checkmark.shield", validate)
            sideCommand("Install to Game", "arrow.triangle.2.circlepath", syncToGame)
            Spacer(minLength: 18)
            Text("Rooms, chapters, and game content.").font(.caption).foregroundStyle(.secondary)
            Text("Vector 2 Editor").font(.caption2).foregroundStyle(.secondary.opacity(0.8)).padding(.top, 3).padding(.bottom, 16)
            if let root {
                HStack(spacing: 7) {
                    Circle().fill(.green).frame(width: 8, height: 8)
                    Text(name).font(.caption.bold()).lineLimit(1)
                }
                Text(root.path).font(.caption2).foregroundStyle(.secondary).lineLimit(2).padding(.top, 3)
            }
            HStack {
                Button("New…") { choose(create: true) }
                Button("Open…") { choose(create: false) }
            }.buttonStyle(.borderless).padding(.top, 9)
        }
        .padding(.horizontal, 18).padding(.bottom, 14).frame(width: 232)
        }
        .scrollIndicators(.hidden)
        .background(LinearGradient(colors: colorScheme == .dark
            ? [Color(nsColor: .controlBackgroundColor), Color(nsColor: .windowBackgroundColor)]
            : [Color(red: 0.90, green: 0.94, blue: 0.98), Color(red: 0.85, green: 0.91, blue: 0.96)],
            startPoint: .top, endPoint: .bottom))
        .overlay(alignment: .trailing) { Rectangle().fill(edge.opacity(0.8)).frame(width: 1) }
    }

    private func sideLink(_ title: String, _ symbol: String) -> some View {
        Button {
            dismissSearch()
            showingCreator = false; showingTrickStudio = false; editingContentURL = nil
            section = title; refresh()
        } label: {
            Label(title, systemImage: symbol)
                .font(.system(size: 15, weight: section == title ? .semibold : .medium))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .foregroundStyle(section == title ? .white : ink.opacity(0.78))
                .background {
                    if section == title {
                        LinearGradient(colors: [blue, blue.opacity(0.74)], startPoint: .leading, endPoint: .trailing)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .shadow(color: blue.opacity(0.22), radius: 8, y: 3)
                    }
                }
        }.buttonStyle(.plain)
    }

	private func sideLink(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
		Button {
			dismissSearch()
			showingCreator = false; showingTrickStudio = false; editingContentURL = nil; creatorSection = nil
			action(); refresh()
		} label: {
			Label(title, systemImage: symbol)
				.font(.system(size: 15, weight: section == "Story" ? .semibold : .medium))
				.frame(maxWidth: .infinity, alignment: .leading)
				.padding(.horizontal, 14).padding(.vertical, 10)
				.foregroundStyle(section == "Story" ? .white : ink.opacity(0.78))
				.background {
					if section == "Story" { LinearGradient(colors: [blue, blue.opacity(0.74)], startPoint: .leading, endPoint: .trailing).clipShape(RoundedRectangle(cornerRadius: 10)) }
				}
		}.buttonStyle(.plain)
	}

	@ViewBuilder private func storyWorkspace(_ root: URL) -> some View {
		VStack(spacing: 0) {
			Picker("Story workspace", selection: $storyWorkspaceSection) {
				Text("Story Flow").tag("Story")
				Text("Dialogue").tag("Dialogue")
				Text("Cast").tag("Characters")
			}
			.pickerStyle(.segmented)
			.frame(maxWidth: 470)
			.padding(12)
			if storyWorkspaceSection == "Story" {
				StoryGraphView(projectRoot: root, onStatus: { status = $0; refresh(); syncIfNeeded() })
			} else {
				let category = storyWorkspaceSection
				ProjectStructuredStudioView(
					section: category == "Characters" ? "Cast" : category,
					folder: root.appendingPathComponent(folders[category]!),
					files: inventory(category),
					onImport: { importFiles(into: category) },
					onCreate: { creatorSection = category; editingContentURL = nil; showingCreator = true },
					onEdit: { creatorSection = category; editingContentURL = $0; showingCreator = true },
					onDelete: deleteProjectItem
				)
			}
		}
	}

    private func sideCommand(_ title: String, _ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(.system(size: 15, weight: .medium))
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.vertical, 9)
        }.buttonStyle(.plain).foregroundStyle(ink.opacity(0.78)).disabled(root == nil)
    }

    private var topBar: some View {
        ZStack {
            HStack(spacing: 11) {
                Image(systemName: "magnifyingglass").foregroundStyle(searchFocused ? blue : .secondary)
                TextField("Search every project tab and file", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onChange(of: query) { _, value in rebuildSearchResults(value) }
                    .onChange(of: searchFocused) { _, focused in
                        if focused { rebuildSearchIndex() }
                    }
                if !query.isEmpty {
                    Button { query = ""; searchHits = [] } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 15).frame(width: searchFocused ? 610 : 520, height: 39)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(searchFocused ? blue : edge.opacity(0.8), lineWidth: searchFocused ? 2 : 1))
            .shadow(color: searchFocused ? blue.opacity(0.16) : .clear, radius: 8, y: 3)
            .frame(maxWidth: .infinity, alignment: .center)

            Button("") { searchFocused = true }
                .keyboardShortcut("k", modifiers: .command)
                .frame(width: 0, height: 0).opacity(0)

            HStack {
                Spacer()
                if searchFocused {
                    Button("Done") { dismissSearch() }
                        .buttonStyle(.bordered)
                        .keyboardShortcut(.cancelAction)
                }
                if root != nil {
                    Button(action: syncToGame) {
                        Label(gameConnectionReady ? "Install Changes" : "Connect Game", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.borderedProminent)
                    .help("Copies this project's current files into Vector 2 and removes stale files previously installed by this project.")
                }
                Button { refresh() } label: {
                    Image(systemName: "arrow.clockwise").frame(width: 34, height: 34)
                        .background(Color(nsColor: .controlBackgroundColor).opacity(0.9), in: Circle())
                }.buttonStyle(.plain).help("Refresh project")
            }
        }
        .padding(.horizontal, 24).frame(height: 50).background(Color(nsColor: .controlBackgroundColor).opacity(0.78))
        .overlay(alignment: .bottom) { Rectangle().fill(edge.opacity(0.65)).frame(height: 1) }
        .overlay(alignment: .top) {
            if searchFocused && !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                searchResultsPanel.offset(y: 44)
                    .transition(.asymmetric(
                        insertion: .offset(y: -12).combined(with: .scale(scale: 0.96, anchor: .top)).combined(with: .opacity),
                        removal: .offset(y: -6).combined(with: .scale(scale: 0.98, anchor: .top)).combined(with: .opacity)
                    ))
            }
        }
        .animation(.snappy(duration: 0.28, extraBounce: 0.12), value: searchFocused)
        .animation(.snappy(duration: 0.24, extraBounce: 0.08),
                   value: !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .zIndex(100)
    }

    private var searchResultsPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            if searchHits.isEmpty {
                Label("Nothing in this project matches “\(query)”", systemImage: "magnifyingglass")
                    .font(.callout).foregroundStyle(.secondary).padding(14)
            } else {
                ForEach(searchHits) { hit in
                    Button { openSearchHit(hit) } label: {
                        HStack(spacing: 11) {
                            Image(systemName: hit.symbol).foregroundStyle(blue).frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(hit.title).fontWeight(.semibold).lineLimit(1)
                                Text(hit.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Text(hit.section).font(.caption2.bold()).foregroundStyle(.secondary)
                            Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
                        }.padding(.horizontal, 12).padding(.vertical, 9).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
        }
        .padding(6).frame(width: 610)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 13))
        .clipShape(RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(edge))
        .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
    }

    private func rebuildSearchResults(_ rawQuery: String) {
        let clean = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { searchHits = []; return }
        let aliases: [String: String] = [
            "Content": "rooms levels xml open editor", "Story & Dialogue": "characters cast dialogue narrative",
            "Trigger Designer": "trigger xml code events actions variables", "Backgrounds": "background parallax zone pool art",
            "Save Data": "player profile armour armor credits", "Assets": "textures images imports browser",
            "Tricks": "stunts animation custom trick", "Generator": "zones room pool generation"
        ]
        let visibleTabs = sections.map { $0 == "Story" ? "Story & Dialogue" : $0 }
        var ranked: [(Int, ProjectSearchHit)] = visibleTabs.compactMap { title in
            let searchable = title + " " + aliases[title, default: ""]
            guard let score = ProjectManagerSearchPolicy.score(searchable, query: clean) else { return nil }
            let hit = ProjectSearchHit(title: title, detail: "Open project tool", symbol: icon(title), section: title == "Story & Dialogue" ? "Story" : title, file: nil)
            return (score, hit)
        }
        if root != nil {
            for category in folders.keys.sorted() {
                let targetSection = ["Dialogue", "Characters"].contains(category) ? "Story" : (category == "Zone Background Pool" ? "Backgrounds" : category)
                for entry in searchFileIndex where entry.category == category {
                    let file = entry.file
                    guard let score = ProjectManagerSearchPolicy.score(file.path, query: clean) else { continue }
                    ranked.append((200 + score, ProjectSearchHit(title: file.deletingPathExtension().lastPathComponent,
                                                                  detail: file.lastPathComponent,
                                                                  symbol: icon(targetSection),
                                                                  section: targetSection,
                                                                  file: file)))
                    if ranked.count >= 40 { break }
                }
                if ranked.count >= 40 { break }
            }
        }
        searchHits = ranked.sorted { lhs, rhs in
            lhs.0 == rhs.0 ? lhs.1.title.localizedStandardCompare(rhs.1.title) == .orderedAscending : lhs.0 < rhs.0
        }.prefix(14).map(\.1)
    }

    private func rebuildSearchIndex() {
        guard let root else { searchFileIndex = []; return }
        let folderSnapshot = folders
        Task.detached(priority: .utility) {
            var result: [(category: String, file: URL)] = []
            func collectFiles(in directory: URL, category: String) {
                let children = (try? FileManager.default.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
                    options: [.skipsHiddenFiles]
                )) ?? []
                for child in children {
                    let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
                    if values?.isDirectory == true { collectFiles(in: child, category: category) }
                    else if values?.isRegularFile == true { result.append((category, child)) }
                }
            }
            for (category, folder) in folderSnapshot {
                let directory = root.appendingPathComponent(folder, isDirectory: true)
                collectFiles(in: directory, category: category)
            }
            let completed = result
            await MainActor.run {
                searchFileIndex = completed
                if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { rebuildSearchResults(query) }
            }
        }
    }

    private func openSearchHit(_ hit: ProjectSearchHit) {
        section = hit.section
        showingCreator = false; showingTrickStudio = false; editingContentURL = nil
        query = ""; searchHits = []; searchFocused = false
        refresh()
        if let file = hit.file, hit.section == "Content" { onOpenRoom(file.path) }
    }

    private func dismissSearch() {
        searchFocused = false
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Project Overview").font(.system(size: 30, weight: .bold))
                    Text("Open a section on the left to edit this project.")
                        .font(.system(size: 16)).foregroundStyle(.secondary)
                }
                if root != nil {
                    hero
                    HStack(alignment: .top, spacing: 15) {
                        zonesPanel.frame(maxWidth: .infinity)
                        recentRooms.frame(width: 385)
                    }
                    HStack(alignment: .top, spacing: 15) {
                        quickActions.frame(maxWidth: .infinity)
                        settingsPanel.frame(width: 385)
                    }
                } else { welcome }
            }
            .frame(maxWidth: 1290).padding(.horizontal, 24).padding(.vertical, 14)
            .frame(maxWidth: .infinity)
        }.background(bg)
    }

    private func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        content().padding(15).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.95), in: RoundedRectangle(cornerRadius: 15))
            .overlay(RoundedRectangle(cornerRadius: 15).stroke(edge.opacity(0.72)))
            .shadow(color: Color.blue.opacity(0.045), radius: 12, y: 5)
    }

    private var hero: some View {
        card {
            HStack(spacing: 22) {
                Button(action: chooseCover) {
                    artwork(path: coverPath, height: 190, prompt: "Choose project artwork")
                        .frame(width: 310, height: 190)
                        .clipped()
                }
                    .buttonStyle(.plain).help("Choose project artwork")
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 12) {
                        Text(name).font(.system(size: 25, weight: .bold)).lineLimit(1)
                        Label("Active Project", systemImage: "circle.fill")
                            .font(.caption).foregroundStyle(Color(red: 0.08, green: 0.62, blue: 0.30))
                            .padding(.horizontal, 11).padding(.vertical, 7)
                            .background(Color.green.opacity(0.1), in: Capsule())
                    }
                    Text("Version \(version)   |   Author \(author.isEmpty ? "Not set" : author)")
                        .font(.system(size: 16)).foregroundStyle(.secondary)
                    Text(description.isEmpty ? "Add a description in Project Settings." : description)
                        .font(.system(size: 16)).lineLimit(2)
                    Spacer()
                    HStack(spacing: 8) {
                        stat("Zones", zones.count, "square.3.layers.3d", blue)
                        stat("Rooms", counts["Content", default: 0], "doc.text", blue)
                        stat("Assets", counts["Assets", default: 0], "cube", blue)
                        stat("Models", counts["Models", default: 0], "cube.transparent", .purple)
                        stat("Tricks", counts["Tricks", default: 0], "figure.run", .green)
                        stat("Audio", counts["Audio", default: 0], "music.note", .orange)
                    }
                }.frame(height: 190)
            }
        }
    }

    private func stat(_ title: String, _ value: Int, _ symbol: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: symbol).foregroundStyle(color)
                Text(title).foregroundStyle(.secondary)
            }.font(.caption)
            Text("\(value)").font(.system(size: 20, weight: .semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(edge.opacity(0.75)))
    }

    private var zonesPanel: some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Zones", systemImage: "square.3.layers.3d").font(.headline)
                    Spacer()
                    Button("Add Zone  +", action: addZoneFolder).buttonStyle(.plain).foregroundStyle(blue)
                }
                if zones.isEmpty {
                    emptyState("square.3.layers.3d", "No zones yet", "Add a zone folder to start organizing rooms.").frame(height: 170)
                } else {
                    ScrollView(.horizontal) {
                        HStack(spacing: 10) {
                            ForEach(Array(zones.prefix(6)), id: \.path) { zone in zoneTile(zone) }
                        }
                    }
                    .scrollIndicators(.hidden)
                    .frame(height: 155)
                    .clipped()
                }
            }
        }
    }

    private func zoneTile(_ zone: URL) -> some View {
        ZStack(alignment: .bottomLeading) {
            artwork(path: zoneArtwork[zone.lastPathComponent] ?? "", height: 155, prompt: "Choose artwork")
            LinearGradient(colors: [.clear, .black.opacity(0.82)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 2) {
                Text(zone.lastPathComponent.replacingOccurrences(of: "_", with: " ").capitalized).font(.headline)
                Text("\(zoneRoomCounts[zone.path, default: 0]) rooms").font(.caption)
            }.foregroundStyle(.white).padding(13)
        }
        .frame(width: 255, height: 155).clipShape(RoundedRectangle(cornerRadius: 11))
        .contentShape(Rectangle()).onTapGesture { NSWorkspace.shared.open(zone) }
        .overlay(alignment: .topTrailing) {
            Button { chooseZoneArtwork(zone) } label: {
                Image(systemName: "photo.badge.plus").padding(8).background(.black.opacity(0.55), in: Circle())
            }.buttonStyle(.plain).foregroundStyle(.white).padding(8).help("Choose zone artwork")
        }
        .help("Open this zone folder")
    }

    private func artwork(path: String, height: CGFloat, prompt: String) -> some View {
        Group {
            if let root, !path.isEmpty, let image = NSImage(contentsOf: root.appendingPathComponent(path)) {
                // Keep the whole preview readable. The softened edge-fill prevents
                // letterbox bars without cropping the actual project artwork.
                ZStack {
                    Image(nsImage: image).resizable().scaledToFill()
                        .scaleEffect(1.08).blur(radius: 18)
                    Color.black.opacity(0.10)
                    Image(nsImage: image).resizable().scaledToFit().padding(6)
                }
            } else {
                LinearGradient(colors: [Color(red: 0.25, green: 0.62, blue: 0.95), Color(red: 0.10, green: 0.25, blue: 0.49)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    .overlay {
                        VStack(spacing: 8) {
                            Image(systemName: "photo.badge.plus").font(.title)
                            Text(prompt).font(.caption.bold())
                        }.foregroundStyle(.white.opacity(0.82))
                    }
            }
        }.frame(maxWidth: .infinity, maxHeight: height).clipped()
            .clipShape(RoundedRectangle(cornerRadius: 11))
    }

    private var recentRooms: some View {
        card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Recent Rooms", systemImage: "doc").font(.headline)
                    Spacer()
                    Button("View All  →") { section = "Content"; refresh() }.buttonStyle(.plain).foregroundStyle(blue)
                }
                ForEach(Array(filteredFiles.prefix(5)), id: \.path) { file in
                    HStack(spacing: 8) {
                        Image(systemName: "doc").foregroundStyle(.secondary)
                        Button(file.lastPathComponent) { openFile(file) }.buttonStyle(.plain).lineLimit(1)
                        Spacer()
                        Text(modified(file)).font(.caption).foregroundStyle(.secondary)
                    }.frame(height: 25)
                    Divider()
                }
                if filteredFiles.isEmpty {
                    emptyState("doc.badge.plus", "No rooms imported", "Import a room to begin.").frame(height: 128)
                    Button("Import Rooms…") { section = "Content"; importFiles() }
                }
            }.frame(minHeight: 170, alignment: .top)
        }
    }

    private var quickActions: some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                Label("Quick Actions", systemImage: "bolt.fill").font(.headline)
                HStack(spacing: 9) {
                    actionTile("Open Room", "Open or import XML", "folder") { section = "Content"; importFiles() }
                    actionTile("Validate", "Run project checks", "checkmark.circle", .green, validate)
                    actionTile("Assets", "Organize files", "cube") { section = "Assets"; refresh() }
                    actionTile("Install to Game", gameDataPath.isEmpty ? "Connect Vector 2 first" : "Sync changes live", "arrow.triangle.2.circlepath", blue, syncToGame)
                }
            }
        }
    }

    private func actionTile(_ title: String, _ detail: String, _ symbol: String, _ color: Color = .blue, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: symbol).font(.title2).foregroundStyle(color)
                Spacer()
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }.frame(maxWidth: .infinity, minHeight: 68, alignment: .leading).padding(11)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(edge.opacity(0.75)))
        }.buttonStyle(.plain)
    }

    private var settingsPanel: some View {
        card {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("Project Settings", systemImage: "gearshape.fill").font(.headline)
                    Spacer()
                    Button(settings ? "Done" : "Edit") { if settings { save() }; settings.toggle() }
                }
                if settings {
                    TextField("Project name", text: $name)
                    HStack { TextField("Version", text: $version); TextField("Author", text: $author) }
                    TextField("Description", text: $description)
                    HStack { Button("Artwork…", action: chooseCover); Button("Backup Folder…", action: chooseOutputFolder); Button(gameConnectionReady ? "Change Game Data…" : "Choose Game Data…", action: connectGame) }
                } else {
                    row("Name", name); row("Version", version); row("Author", author.isEmpty ? "Not set" : author)
                    row("Project Folder", root?.path ?? "—"); row("Backup Folder", outputFolder.isEmpty ? "Choose when exporting" : outputFolder)
                    row("Game Data", gameConnectionReady ? "Connected" : "Not connected")
                }
                Toggle("Generate Debug Data", isOn: $generateDebugData).font(.caption)
                    .onChange(of: generateDebugData) { _, _ in save() }
            }.textFieldStyle(.roundedBorder).frame(minHeight: 101, alignment: .top)
        }
    }

    private var gameConnectionReady: Bool {
        isVectorData(URL(fileURLWithPath: gameDataPath))
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(spacing: 7) {
            Text(title).foregroundStyle(.secondary).frame(width: 88, alignment: .leading)
            Text(value).lineLimit(1).truncationMode(.middle).help(value); Spacer(minLength: 0)
        }.font(.system(size: 11.5)).padding(.vertical, 2)
            .overlay(alignment: .bottom) { Rectangle().fill(edge.opacity(0.5)).frame(height: 1) }
    }

    private var fileBrowser: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 15) {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(section).font(.system(size: 32, weight: .bold))
                        Text("Manage files stored in \(folders[section] ?? section).").foregroundStyle(.secondary)
                    }
                    Spacer()
                    if designedSections.contains(section) {
                        Button("Create \(section.dropLast(section.hasSuffix("s") ? 1 : 0))…") { showingCreator = true }
                            .buttonStyle(.borderedProminent)
                    }
                    if designedSections.contains(section) {
						Button("Import Files…") { importFiles() }.buttonStyle(.bordered)
                    } else {
						Button("Import Files…") { importFiles() }.buttonStyle(.borderedProminent)
                    }
                    Button("Open Folder") {
                        if let root, let folder = folders[section] { NSWorkspace.shared.open(root.appendingPathComponent(folder)) }
                    }
                }
                card {
                    ForEach(filteredFiles, id: \.path) { file in
                        HStack {
                            Label(file.lastPathComponent, systemImage: "doc"); Spacer()
                            Text(modified(file)).foregroundStyle(.secondary)
                            if designedSections.contains(section), file.pathExtension.lowercased() == "xml" {
                                Button("Edit") { editingContentURL = file; showingCreator = true }
                                    .buttonStyle(.borderedProminent)
                            } else {
                                Button("Open") { openFile(file) }
                            }
                            Button { NSWorkspace.shared.activateFileViewerSelecting([file]) } label: { Image(systemName: "folder") }
                            Button(role: .destructive) { pendingProjectDelete = file } label: { Image(systemName: "trash") }
                                .help("Delete from project")
                        }
                        .frame(height: 36)
                        Divider()
                    }
                    if filteredFiles.isEmpty {
                        emptyState(icon(section), "Nothing here yet", "Import files to build this part of your project.").frame(height: 280)
                    }
                }
            }.frame(maxWidth: 1290).padding(24).frame(maxWidth: .infinity)
        }.background(bg)
    }

    private var welcome: some View {
        card {
            VStack(spacing: 16) {
                Image(systemName: "folder.badge.plus").font(.system(size: 42)).foregroundStyle(blue)
                Text("Choose a folder for your mod").font(.title2.bold())
                Text("Use a separate folder, such as one in Documents—not the game's rooms folder.")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("New Project…") { choose(create: true) }.buttonStyle(.borderedProminent)
                    Button("Open Existing Project…") { choose(create: false) }
                }
            }.frame(maxWidth: .infinity, minHeight: 380)
        }
    }

    private func emptyState(_ symbol: String, _ title: String, _ detail: String) -> some View {
        VStack(spacing: 7) {
            Image(systemName: symbol).font(.title2).foregroundStyle(blue.opacity(0.7))
            Text(title).font(.headline); Text(detail).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Circle().fill(root == nil ? Color.gray : Color.green).frame(width: 7, height: 7)
            Text(status).font(.caption).lineLimit(1).textSelection(.enabled); Spacer()
        }.padding(.horizontal, 13).frame(height: 31).background(Color(nsColor: .controlBackgroundColor).opacity(0.88))
            .overlay(alignment: .top) { Rectangle().fill(edge.opacity(0.7)).frame(height: 1) }
    }

    private var filteredFiles: [URL] {
        // This field navigates the whole project. It should not rearrange the
        // Overview or hide items from the section sitting behind its dropdown.
        files
    }

    private func roomCount(in zone: URL) -> Int {
        guard let e = FileManager.default.enumerator(at: zone, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return 0 }
        return e.compactMap { $0 as? URL }.filter { $0.pathExtension.lowercased() == "xml" }.count
    }

    private func modified(_ file: URL) -> String {
        ((try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
            .formatted(date: .abbreviated, time: .omitted)
    }

    private func openFile(_ file: URL) {
        if file.pathExtension.lowercased() == "xml" && (section == "Content" || section == "Overview") {
            onOpenRoom(file.path)
        } else { NSWorkspace.shared.open(file) }
    }

    private func deleteProjectItem(_ file: URL) {
        guard let root else { return }
        let projectPath = root.standardizedFileURL.path
        let target = file.standardizedFileURL
        guard target.path.hasPrefix(projectPath + "/"), target.path != root.appendingPathComponent("project.xml").path else {
            status = "Delete stopped because that item is outside the project."
            return
        }
        do {
            try FileManager.default.removeItem(at: target)
            refresh()
            if gameConnectionReady { syncToGame() }
            else { status = "Deleted \(target.lastPathComponent) from the project. Connect Vector 2 Data to remove its game copy." }
        } catch {
            refresh()
            status = "Could not delete \(target.lastPathComponent): \(error.localizedDescription)"
        }
    }

    private func icon(_ item: String) -> String {
        [
            "Content": "folder", "Assets": "photo.on.rectangle.angled",
            "Chapters": "books.vertical", "Zones": "square.3.layers.3d",
            "Quests": "bookmark", "Dialogue": "text.bubble",
            "Characters": "person.2", "Localization": "character.book.closed", "Obstacles": "shippingbox",
            "Backgrounds": "photo", "Models": "cube", "Tricks": "figure.run", "Generator": "point.3.connected.trianglepath.dotted",
            "Upgrades": "arrow.up.circle", "Missions": "scope", "Rewards": "gift", "Tutorials": "graduationcap",
            "Audio": "music.note", "Shop": "cart", "Save Data": "externaldrive"
        ][item] ?? "doc"
    }

    private func addZoneFolder() {
        guard let root else { return }
        let parent = root.appendingPathComponent("custom_rooms")
        let panel = NSSavePanel()
        panel.title = "Add a zone folder"
        panel.message = "Create a folder directly inside custom_rooms. Runtime zone configuration is separate."
        panel.directoryURL = parent
        panel.nameFieldStringValue = "zone_3"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard url.deletingLastPathComponent().standardizedFileURL == parent.standardizedFileURL else {
            status = "Choose a folder name directly inside this project's custom_rooms folder."
            return
        }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            refresh()
            status = "Zone folder created. Game zone registration has not been changed."
        } catch {
            status = error.localizedDescription
        }
    }

    private func chooseCover() {
        guard let root else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff]
        guard panel.runModal() == .OK, let source = panel.url else { return }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: source)
            guard NSImage(data: data) != nil else { throw CocoaError(.fileReadCorruptFile) }
            let folder = root.appendingPathComponent("project_artwork")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let relative = "project_artwork/cover-\(UUID().uuidString).\(source.pathExtension)"
            try data.write(to: root.appendingPathComponent(relative), options: .atomic)
            coverPath = relative
            save()
        } catch { status = "Artwork could not be imported: \(error.localizedDescription)" }
    }

    private func chooseZoneArtwork(_ zone: URL) {
        guard let root else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff]
        guard panel.runModal() == .OK, let source = panel.url else { return }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: source)
            guard NSImage(data: data) != nil else { throw CocoaError(.fileReadCorruptFile) }
            try FileManager.default.createDirectory(at: root.appendingPathComponent("project_artwork"), withIntermediateDirectories: true)
            let path = "project_artwork/zone-\(UUID().uuidString).\(source.pathExtension)"
            try data.write(to: root.appendingPathComponent(path), options: .atomic)
            zoneArtwork[zone.lastPathComponent] = path
            save()
        } catch { status = error.localizedDescription }
    }

    private func choose(create: Bool) {
        if root != nil, !save() { return }
        let url: URL
        if create {
            let panel = NSSavePanel()
            panel.title = "Create a mod project folder"
            panel.message = "Choose a parent location and name your new project folder. Your game installation stays untouched."
            panel.nameFieldLabel = "Project folder:"
            panel.nameFieldStringValue = "My Vector 2 Project"
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let selected = panel.url else { return }
            url = selected
        } else {
            let panel = NSOpenPanel()
            panel.title = "Open a Vector 2 project"
            panel.message = "Select the folder containing project.xml—not a room or zone folder."
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            guard panel.runModal() == .OK, let selected = panel.url else { return }
            url = selected
        }
        let scoped = url.startAccessingSecurityScopedResource()
        do {
            let manifest = url.appendingPathComponent("project.xml")
            if create {
                guard !FileManager.default.fileExists(atPath: url.path) else {
                    status = "Choose a NEW folder name. Existing folders are never converted or overwritten."
                    if scoped { url.stopAccessingSecurityScopedResource() }
                    return
                }
                for folder in Set(folders.values).union(["custom_economy"]) { try FileManager.default.createDirectory(at: url.appendingPathComponent(folder), withIntermediateDirectories: true) }
                try FileManager.default.createDirectory(at: url.appendingPathComponent("custom_tricks/animation_overrides"), withIntermediateDirectories: true)
                for path in ["custom_gamedata/generator_data/default", "custom_gamedata/settings", "custom_gamedata/sounds", "custom_gamedata/text/localization", "custom_gamedata/run_data/libraries", "custom_gamedata/run_data/templates"] {
                    try FileManager.default.createDirectory(at: url.appendingPathComponent(path), withIntermediateDirectories: true)
                }
                root = url; projectID = UUID().uuidString; name = url.lastPathComponent; author = ""; version = "1.0.0"; description = ""; coverPath = ""; zoneArtwork = [:]; outputFolder = ""; generateDebugData = false
                gameSourcePath = ""; gameDataPath = ""; liveSync = false; save()
            } else {
                let xml = try XMLDocument(contentsOf: manifest)
                guard let element = xml.rootElement(), element.name == "Vector2Project", element.attribute(forName: "SchemaVersion")?.stringValue == "1" else { throw CocoaError(.fileReadCorruptFile) }
                root = url; projectID = element.attribute(forName: "ProjectID")?.stringValue ?? UUID().uuidString; name = element.attribute(forName: "Name")?.stringValue ?? ""; author = element.attribute(forName: "Author")?.stringValue ?? ""; version = element.attribute(forName: "Version")?.stringValue ?? ""; description = element.elements(forName: "Description").first?.stringValue ?? ""
                coverPath = safeArtworkPath(element.elements(forName: "Cover").first?.stringValue ?? "")
                loadZoneArtwork(element)
            }
            access?.stopAccessingSecurityScopedResource()
            access = scoped ? url : nil
            rememberProject(url)
            validation = "Not checked"
            refresh()
            if create {
                status = "Project created. Choose Vector 2 Data in Project Settings only when you are ready to install it."
            } else { restoreGameBookmarks() }
        } catch {
            if scoped { url.stopAccessingSecurityScopedResource() }
            status = "Could not open project. Select a folder containing a valid project.xml, or create a new project. \(error.localizedDescription)"
        }
    }

    // The project lives across room-tab switches, including sandbox access.
    private func rememberProject(_ url: URL) {
        UserDefaults.standard.set(url.path, forKey: "projectManager.lastProjectPath")
        if let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(bookmark, forKey: "projectManager.lastProjectBookmark")
        }
    }

    private func restoreProject() {
        if !sections.contains(section) { section = "Overview" }
        guard root == nil, let data = UserDefaults.standard.data(forKey: "projectManager.lastProjectBookmark") else { return }
        do {
            var stale = false
            let url = try URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
            let scoped = url.startAccessingSecurityScopedResource()
            do {
                let xml = try XMLDocument(contentsOf: url.appendingPathComponent("project.xml"))
                guard let element = xml.rootElement(), element.name == "Vector2Project", element.attribute(forName: "SchemaVersion")?.stringValue == "1" else { throw CocoaError(.fileReadCorruptFile) }
                root = url
                access = scoped ? url : nil
                projectID = element.attribute(forName: "ProjectID")?.stringValue ?? UUID().uuidString
                name = element.attribute(forName: "Name")?.stringValue ?? url.lastPathComponent
                version = element.attribute(forName: "Version")?.stringValue ?? "1.0.0"
                author = element.attribute(forName: "Author")?.stringValue ?? ""
                description = element.elements(forName: "Description").first?.stringValue ?? ""
                coverPath = safeArtworkPath(element.elements(forName: "Cover").first?.stringValue ?? "")
                loadZoneArtwork(element)
                restoreGameBookmarks()
                // Save/Play also needs a current plain path when the bookmark
                // was not stale, so it can install generated trap dependencies.
                rememberProject(url)
                refresh(scanOverviewStats: false)
                status = "Project ready."
            } catch {
                if scoped { url.stopAccessingSecurityScopedResource() }
                throw error
            }
        } catch { status = "Reopen your project folder to restore access. \(error.localizedDescription)" }
    }

    private func safeArtworkPath(_ value: String) -> String {
        guard !value.hasPrefix("/"), !value.split(separator: "/").contains("..") else { return "" }
        return value
    }

    private func loadZoneArtwork(_ element: XMLElement) {
        outputFolder = element.attribute(forName: "OutputFolder")?.stringValue ?? ""
        generateDebugData = element.attribute(forName: "GenerateDebugData")?.stringValue == "true"
        gameSourcePath = element.attribute(forName: "GameSourcePath")?.stringValue ?? ""
        gameDataPath = element.attribute(forName: "GameDataPath")?.stringValue ?? ""
        // Installing while the game is booting can make Unity reload cards and
        // scenes mid-initialization. Connections are read-only until Install.
        liveSync = false
        zoneArtwork = [:]
        for entry in element.elements(forName: "ZoneArtwork") {
            guard let key = entry.attribute(forName: "Folder")?.stringValue else { continue }
            let path = safeArtworkPath(entry.stringValue ?? "")
            if !path.isEmpty { zoneArtwork[key] = path }
        }
    }
    @discardableResult
    private func save() -> Bool {
        guard let root else { return false }
        if projectID.isEmpty { projectID = UUID().uuidString }
        // Preserve fields from newer tools instead of discarding unknown XML.
        let existing = try? XMLDocument(contentsOf: root.appendingPathComponent("project.xml"))
        let element = (existing?.rootElement()?.copy() as? XMLElement) ?? XMLElement(name: "Vector2Project")
        for (key, value) in ["SchemaVersion": "1", "ProjectID": projectID, "Name": name, "Author": author, "Version": version, "OutputFolder": outputFolder, "GenerateDebugData": generateDebugData ? "true" : "false", "GameSourcePath": gameSourcePath, "GameDataPath": gameDataPath, "LiveSync": liveSync ? "true" : "false"] {
            element.removeAttribute(forName: key)
            element.addAttribute(XMLNode.attribute(withName: key, stringValue: value) as! XMLNode)
        }
        element.elements(forName: "Description").forEach { $0.detach() }
        element.elements(forName: "Cover").forEach { $0.detach() }
        element.elements(forName: "ZoneArtwork").forEach { $0.detach() }
        element.addChild(XMLElement(name: "Description", stringValue: description))
        element.addChild(XMLElement(name: "Cover", stringValue: coverPath))
        for key in zoneArtwork.keys.sorted() {
            let entry = XMLElement(name: "ZoneArtwork", stringValue: zoneArtwork[key])
            entry.addAttribute(XMLNode.attribute(withName: "Folder", stringValue: key) as! XMLNode)
            element.addChild(entry)
        }
        do {
            try XMLDocument(rootElement: element).xmlData(options: .nodePrettyPrint).write(to: root.appendingPathComponent("project.xml"), options: .atomic)
            status = "Project saved."
            return true
        } catch {
            status = error.localizedDescription
            return false
        }
    }
    private func inventory(_ category: String) -> [URL] {
        guard let root, let folder = folders[category], let enumerator = FileManager.default.enumerator(at: root.appendingPathComponent(folder), includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }.sorted { $0.path < $1.path }
    }
    private func refresh(scanOverviewStats: Bool = true) {
        ensureProjectFolders()
        // Opening Project Manager used to recursively scan every studio folder,
        // including textures and generated game data, before drawing anything.
        // Only scan what the visible section needs; Overview owns its five stats.
        let visibleCategory = section == "Overview" ? "Content" : section
        let categories: Set<String> = section == "Overview"
            ? (scanOverviewStats ? Set(["Content", "Assets", "Models", "Tricks", "Audio"]) : Set(["Content"]))
            : Set([visibleCategory])
        if section == "Overview", !scanOverviewStats, let root {
            let prefix = "projectManager.counts.\(root.path.hashValue)."
            for category in ["Content", "Assets", "Models", "Tricks", "Audio"] {
                let cached = UserDefaults.standard.integer(forKey: prefix + category)
                if cached > 0 { counts[category] = cached }
            }
        }
        var inventories: [String: [URL]] = [:]
        for category in categories where folders[category] != nil {
            let items = inventory(category)
            inventories[category] = items
            counts[category] = items.count
            if let root {
                UserDefaults.standard.set(items.count, forKey: "projectManager.counts.\(root.path.hashValue)." + category)
            }
        }
        if section == "Overview", let root {
            zones = ((try? FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("custom_rooms"), includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? [])
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            zoneRoomCounts = Dictionary(uniqueKeysWithValues: zones.map { ($0.path, roomCount(in: $0)) })
        }
        files = inventories[visibleCategory, default: []]
        if section == "Overview" {
            files.sort {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a > b
            }
        }
    }
    private func ensureProjectFolders() {
        guard let root else { return }
        for folder in Set(folders.values).union(["custom_economy", ProjectTriggerStore.folderName]) {
            try? FileManager.default.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        for path in ["custom_gamedata/generator_data/default", "custom_gamedata/settings", "custom_gamedata/sounds", "custom_gamedata/text/localization", "custom_gamedata/run_data/libraries", "custom_gamedata/run_data/templates"] {
            try? FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
        }
    }
	private func importFiles(into category: String? = nil) {
		let destinationCategory = category ?? section
		guard let root, let folder = folders[destinationCategory] else { return }
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; panel.canChooseDirectories = true
        guard panel.runModal() == .OK else { return }
        do {
            let destination = root.appendingPathComponent(folder); try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            for source in panel.urls {
                let scoped = source.startAccessingSecurityScopedResource()
                defer { if scoped { source.stopAccessingSecurityScopedResource() } }
                let target = destination.appendingPathComponent(source.lastPathComponent)
				if destinationCategory == "Backgrounds" && source.lastPathComponent.lowercased() == "background.xml" {
					throw NSError(domain: "ProjectManager", code: 2, userInfo: [NSLocalizedDescriptionKey: "Vector's background.xml is a read-only library. Open it from Zone Pool Designer → Vector Library; it is never copied into or installed with the project."])
				}
                let sourcePath = source.resolvingSymlinksInPath().standardizedFileURL.path
                let targetPath = target.resolvingSymlinksInPath().standardizedFileURL.path
                guard targetPath != sourcePath, !targetPath.hasPrefix(sourcePath + "/") else {
                    throw NSError(domain: "ProjectManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "A folder cannot be imported into itself. Choose content outside the destination folder."])
                }
                try FileManager.default.copyItem(at: source, to: target)
            }
            status = "Files imported."; refresh(); syncIfNeeded()
        } catch { refresh(); status = "Import stopped: \(error.localizedDescription). Existing files were not overwritten." }
    }
    private func validate() {
        var issues: [String] = root.map(ProjectIntegrationAudit.issues) ?? []
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { issues.append("Project name is empty.") }
        for category in sections where folders[category] != nil {
            for file in inventory(category) where file.pathExtension.lowercased() == "xml" {
                do {
                    let document = try XMLDocument(contentsOf: file)
                    issues.append(contentsOf: schemaIssues(in: document, category: category, filename: file.lastPathComponent))
                } catch { issues.append("\(file.lastPathComponent): \(error.localizedDescription)") }
            }
        }
        validation = issues.isEmpty ? "Project structure passed" : "\(issues.count) issues"
        status = issues.isEmpty ? "XML and custom-content structure checks passed. Final game behavior still needs a playtest." : issues.joined(separator: "\n")
    }

    private func schemaIssues(in document: XMLDocument, category: String, filename: String) -> [String] {
        let rules: [String: (root: String, item: String, id: String)] = [
            "Chapters": ("Chapters", "Chapter", "Id"), "Zones": ("Zones", "Zone", "Id"),
            "Quests": ("Quests", "Quest", "Name"), "Dialogue": ("Dialogues", "Dialogue", "Id"),
            "Characters": ("Characters", "Character", "Id"), "Localization": ("Localization", "Phrase", "Key")
        ]
        guard let rule = rules[category] else { return [] }
        guard let root = document.rootElement(), root.name == rule.root else {
            return ["\(filename): expected <\(rule.root)> as the root element."]
        }
        let items = root.elements(forName: rule.item)
        if items.isEmpty { return ["\(filename): contains no <\(rule.item)> entries."] }
        var seen = Set<String>()
        var result: [String] = []
        for item in items {
            let id = item.attribute(forName: rule.id)?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if id.isEmpty { result.append("\(filename): <\(rule.item)> is missing \(rule.id).") }
            else if !seen.insert(id.lowercased()).inserted { result.append("\(filename): duplicate \(rule.id) '\(id)'.") }
            if category == "Quests" {
                if item.elements(forName: "Info").first == nil { result.append("\(filename): quest '\(id)' is missing Info.") }
                if item.elements(forName: "StartTrigger").first?.elements(forName: "Content").first == nil { result.append("\(filename): quest '\(id)' is missing StartTrigger/Content.") }
            }
        }
        return result
    }
    private func export() {
        guard let root else { return }
        guard save() else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.title = "Choose export destination"
        panel.message = "Creates a new \(root.lastPathComponent)-export folder here. Existing exports are never overwritten."
        panel.canCreateDirectories = true
        if !outputFolder.isEmpty { panel.directoryURL = URL(fileURLWithPath: outputFolder) }
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let scoped = destination.startAccessingSecurityScopedResource(); defer { if scoped { destination.stopAccessingSecurityScopedResource() } }
        let target = destination.appendingPathComponent(root.lastPathComponent + "-export")
        let sourcePath = root.resolvingSymlinksInPath().standardizedFileURL.path
        let targetPath = target.resolvingSymlinksInPath().standardizedFileURL.path
        guard targetPath != sourcePath, !targetPath.hasPrefix(sourcePath + "/") else { status = "Choose an export folder outside this project."; return }
        do {
            try FileManager.default.copyItem(at: root, to: target)
            if generateDebugData {
                let report = (["Vector 2 project export", "Created: \(Date().ISO8601Format())", "Project: \(name)", "Version: \(version)", "Checks: \(validation)", "This report is an inventory, not proof of game compatibility."] +
                    folders.keys.sorted().map { "\($0): \(inventory($0).count) files" }).joined(separator: "\n")
                try report.write(to: target.appendingPathComponent("export-debug-\(UUID().uuidString).txt"), atomically: true, encoding: .utf8)
            }
            status = "Exported project to \(target.path)."
        } catch { status = "Export incomplete: \(error.localizedDescription). A partial copy may exist at \(target.path)." }
    }

    private func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.message = "Choose a destination outside the project. Export will ask you to confirm this destination."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        outputFolder = url.path
        save()
    }

    private var defaultGameDataPath: String {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return support
            .appendingPathComponent("Nekki", isDirectory: true)
            .appendingPathComponent("Vector 2", isDirectory: true).path
    }

    private func isVectorData(_ url: URL) -> Bool {
        guard !url.path.isEmpty else { return false }
        return FileManager.default.fileExists(atPath: url.appendingPathComponent("userdata").path)
            || FileManager.default.fileExists(atPath: url.appendingPathComponent("custom_rooms").path)
            || FileManager.default.fileExists(atPath: url.appendingPathComponent("gamedata").path)
    }

    private func connectGame() {
        let dataPanel = NSOpenPanel()
        dataPanel.title = "Choose Vector 2 Data"
        dataPanel.message = "Choose the main Vector 2 Data folder. This grants access to the whole root—including every current and future custom-content folder—not a small folder allowlist."
        dataPanel.prompt = "Use Vector 2 Data"
        dataPanel.canChooseDirectories = true; dataPanel.canChooseFiles = false; dataPanel.canCreateDirectories = true
        let suggested = URL(fileURLWithPath: gameDataPath.isEmpty ? defaultGameDataPath : gameDataPath)
        try? FileManager.default.createDirectory(at: suggested, withIntermediateDirectories: true)
        dataPanel.directoryURL = suggested
        guard dataPanel.runModal() == .OK, let data = dataPanel.url else { return }
        guard isVectorData(data) else {
            status = "That is not the main Vector 2 Data folder. Choose the root that contains userdata, gamedata, or custom_rooms."
            return
        }
        rememberGameURL(data, key: "projectManager.gameDataBookmark")
        gameDataAccess?.stopAccessingSecurityScopedResource()
        gameDataAccess = data.startAccessingSecurityScopedResource() ? data : nil
        gameDataPath = data.path
        gameSourcePath = ""
        publishGameDataToRoomEditor(data)
        save()
        status = "Vector 2 data connected. Nothing is installed until you choose Install to Game."
    }

    private func rememberGameURL(_ url: URL, key: String) {
        if let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(bookmark, forKey: key)
        }
    }

    private func restoreGameBookmarks() {
        func restore(_ key: String) -> URL? {
            guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
            var stale = false
            return try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
        }
        if let url = restore("projectManager.gameSourceBookmark"), url.path == gameSourcePath {
            gameSourceAccess?.stopAccessingSecurityScopedResource()
            gameSourceAccess = url.startAccessingSecurityScopedResource() ? url : nil
        }
        if let url = restore("projectManager.gameDataBookmark"), url.path == gameDataPath {
            gameDataAccess?.stopAccessingSecurityScopedResource()
            gameDataAccess = url.startAccessingSecurityScopedResource() ? url : nil
            publishGameDataToRoomEditor(url)
        }
    }

    /// Project Manager and the room editor must target the same Vector 2 data
    /// root. Older builds kept separate settings, which could send the room to
    /// an old game-data selection while installing its trap library elsewhere.
    private func publishGameDataToRoomEditor(_ data: URL) {
        let rooms = data.appendingPathComponent("custom_rooms", isDirectory: true)
        let textures = data.appendingPathComponent("custom_textures", isDirectory: true)
        try? FileManager.default.createDirectory(at: rooms, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: textures, withIntermediateDirectories: true)
        UserDefaults.standard.set(rooms.path, forKey: "vector2CustomRoomsDirectory")
        UserDefaults.standard.set(textures.path, forKey: "vector2CustomTexturesDirectory")
        UserDefaults.standard.set(data.path, forKey: "vector2GameDataDirectory")
        if let bookmark = try? data.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(bookmark.base64EncodedString(), forKey: "vector2GameDataDirectoryBookmark")
        }
        if let bookmark = try? rooms.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(bookmark.base64EncodedString(), forKey: "vector2CustomRoomsDirectoryBookmark")
        }
    }

    private func syncIfNeeded() {
        // Project Manager saves and Install Changes use the same game folder.
        if gameConnectionReady { syncToGame() }
    }

    private func syncToGame() {
        guard let root else { return }
        guard gameConnectionReady else { status = "Connect Vector 2 before installing this project."; connectGame(); return }
        guard save() else { return }
        let destination = URL(fileURLWithPath: gameDataPath, isDirectory: true)
        do {
            try CustomBackgroundStore.migrateLegacyPool(in: root.appendingPathComponent("custom_backgrounds_pool", isDirectory: true))
            // Generated libraries are derived project files. Rebuild them from
            // the manifests before every install so Project Manager and the
            // room editor can never ship different versions of the same trap.
            try rebuildGeneratedTrapLibraries(in: root)
            let textures = root.appendingPathComponent("custom_textures", isDirectory: true)
            if let gifs = try? FileManager.default.contentsOfDirectory(at: textures, includingPropertiesForKeys: nil) {
                for gif in gifs where gif.pathExtension.lowercased() == "gif" {
                    _ = try CustomGIFFrames.compile(source: gif, into: textures,
                                                    name: "gif_\(gif.deletingPathExtension().lastPathComponent)")
                }
            }
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let projectFolders = Set(folders.values).union(["custom_gamedata", "custom_economy"])
            let currentFiles = Set(projectFolders.flatMap { installedPaths(in: root, folder: $0) }
                .filter(ProjectBackgroundInstallPolicy.shouldInstall))
            let receipts = destination.appendingPathComponent(".vector2-installed-projects", isDirectory: true)
            try FileManager.default.createDirectory(at: receipts, withIntermediateDirectories: true)
            let receipt = receipts.appendingPathComponent(projectID + ".json")
            let previousFiles = Set((try? JSONDecoder().decode([String].self, from: Data(contentsOf: receipt))) ?? [])
            let poolReceipt = receipts.appendingPathComponent(projectID + "-background-pool.json")
            let previousPoolFiles = Set((try? JSONDecoder().decode([String].self, from: Data(contentsOf: poolReceipt))) ?? [])
            let currentPoolFiles = ProjectBackgroundInstallPolicy.poolFileNames(from: currentFiles)
            var removed = 0
            for relative in previousFiles.subtracting(currentFiles) where isSafeInstalledPath(relative, folders: projectFolders) {
                let stale = destination.appendingPathComponent(relative)
                if FileManager.default.fileExists(atPath: stale.path) {
                    try FileManager.default.removeItem(at: stale)
                    removed += 1
                }
            }
            // The canvas Install button used a separate receipt. Reconcile it
            // here too, or deleting a pool set in Project Manager leaves the
            // old XML installed and Vector can still pick it.
            for filename in ProjectBackgroundInstallPolicy.stalePoolFileNames(previous: previousPoolFiles, current: currentPoolFiles) {
                let stale = destination.appendingPathComponent("custom_backgrounds_pool", isDirectory: true).appendingPathComponent(filename)
                if FileManager.default.fileExists(atPath: stale.path) {
                    try FileManager.default.removeItem(at: stale)
                    removed += 1
                }
            }
            var copied = 0
            for folder in projectFolders {
                let source = root.appendingPathComponent(folder, isDirectory: true)
                guard FileManager.default.fileExists(atPath: source.path) else { continue }
                copied += try mergeFolder(source, into: destination.appendingPathComponent(folder, isDirectory: true), folder: folder)
            }
            let poolFolder = root.appendingPathComponent("custom_backgrounds_pool", isDirectory: true)
            if let files = try? FileManager.default.contentsOfDirectory(at: poolFolder, includingPropertiesForKeys: nil) {
                for file in files where file.pathExtension.lowercased() == "xml" {
                    try CustomBackgroundStore.normalizedPoolCatalogData(from: file)
                        .write(to: destination.appendingPathComponent("custom_backgrounds_pool").appendingPathComponent(file.lastPathComponent), options: .atomic)
                }
            }
            try JSONEncoder().encode(currentFiles.sorted()).write(to: receipt, options: .atomic)
            try JSONEncoder().encode(currentPoolFiles.sorted()).write(to: poolReceipt, options: .atomic)
            status = removed == 0
                ? "Installed \(copied) project files into Vector 2."
                : "Installed \(copied) project files and removed \(removed) stale game copies."
        } catch { status = "Could not sync to Vector 2: \(error.localizedDescription)" }
    }

    private func rebuildGeneratedTrapLibraries(in projectRoot: URL) throws {
        let traps = CustomTrapDefinition.load(from: projectRoot)
        let libraries = projectRoot.appendingPathComponent("custom_gamedata/run_data/libraries", isDirectory: true)
        try FileManager.default.createDirectory(at: libraries, withIntermediateDirectories: true)
        let expected = Set(traps.map { $0.libraryFilename.lowercased() })
        let generated = ((try? FileManager.default.contentsOfDirectory(at: libraries, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
            .filter { $0.pathExtension.lowercased() == "xml" && $0.lastPathComponent.lowercased().hasPrefix("v2trap_") }
        for stale in generated where !expected.contains(stale.lastPathComponent.lowercased()) {
            try FileManager.default.removeItem(at: stale)
        }
        for trap in traps { _ = try trap.write(to: projectRoot) }
    }

    private func installedPaths(in root: URL, folder: String) -> [String] {
        let source = root.appendingPathComponent(folder, isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(at: source, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return [] }
        return enumerator.compactMap { item -> String? in
            guard let url = item as? URL, (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
            let relative = String(url.path.dropFirst(source.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return relative.isEmpty ? nil : folder + "/" + relative
        }
    }

    private func isSafeInstalledPath(_ relative: String, folders: Set<String>) -> Bool {
        guard !relative.hasPrefix("/"), !relative.split(separator: "/").contains(".."), let first = relative.split(separator: "/").first else { return false }
        return folders.contains(String(first))
    }

    private func mergeFolder(_ source: URL, into destination: URL, folder: String) throws -> Int {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        guard let enumerator = FileManager.default.enumerator(at: source, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return 0 }
        var count = 0
        for case let item as URL in enumerator {
            let relative = String(item.path.dropFirst(source.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !relative.isEmpty else { continue }
            guard ProjectBackgroundInstallPolicy.shouldInstall(relativePath: folder + "/" + relative) else { continue }
            let target = destination.appendingPathComponent(relative)
            let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            if isDirectory { try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true); continue }
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
            try FileManager.default.copyItem(at: item, to: target); count += 1
        }
        return count
    }
}
