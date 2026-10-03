//
//  EditorUI.swift
//  Vector2 level editor
//
//  Menu, toolbar, tabs, status bar, Help, and the tool rail.
//  Buttons here call the same document and exporter actions as the rest of the editor.
//

import SwiftUI
import AppKit
import Foundation

struct MenuStrip: View {
    let recentPaths: [String]
    let onFileAction: (ToolbarAction) -> Void
    let onOpenRecent: (String) -> Void
    let onShowHelp: () -> Void
    let onShowCredits: () -> Void
    let onOpenDynamicStudio: () -> Void
    let onOpenAIStudio: () -> Void
    let onOpenSwarmWaypointBinder: () -> Void
    let onOpenBackgroundDesigner: () -> Void
    let onOpenCustomTrickStudio: () -> Void
    let onOpenPlayerDesigner: () -> Void
    let onOpenRoomLayouts: () -> Void
    let onOpenTraps: () -> Void
    let onOpenXMLBuilder: () -> Void
    let onOpenObstacleDesigner: () -> Void
    let onOpenEntranceStudio: () -> Void
    let onOpenExitStudio: () -> Void
    let onOpenProjectManager: () -> Void

    var body: some View {
        HStack(spacing: 18) {
            fileMenu

            ForEach(["Edit", "View"], id: \.self) { item in
                menuLabel(item)
            }

            Button("Project Manager", action: onOpenProjectManager)
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(Color.editorPrimaryText.opacity(0.82))
            .help("Open your project")

            toolsMenu

            Button("Help") {
                onShowHelp()
            }
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(Color.editorPrimaryText.opacity(0.82))

            Button("About") {
                onShowCredits()
            }
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(Color.editorPrimaryText.opacity(0.82))
            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(Color.editorChromeBackground)
    }

    private var fileMenu: some View {
        Menu {
            Button("New Document") {
                onFileAction(.new)
            }
            Button("Open XML...") {
                onFileAction(.open)
            }
            Button("Import XML...") {
                onFileAction(.importXML)
            }
            Button("Save XML") {
                onFileAction(.save)
            }
            Button("Export XML...") {
                onFileAction(.export)
            }

            Divider()

            if recentPaths.isEmpty {
                Text("No Recent Files")
            } else {
                Section("Recently Opened") {
                    ForEach(recentPaths, id: \.self) { path in
                        Button(URL(fileURLWithPath: path).lastPathComponent) {
                            onOpenRecent(path)
                        }
                    }
                }
            }
        } label: {
            menuLabel("File")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var toolsMenu: some View {
        Menu {
            Button("Variant Designer") { onOpenRoomLayouts() }
            Divider()
            Button("Entrance Designer") { onOpenEntranceStudio() }
            Button("Exit Designer") { onOpenExitStudio() }
            Divider()
            Button("Trigger Designer") { onOpenXMLBuilder() }
            Divider()
            Button("Obstacle Designer") { onOpenObstacleDesigner() }
            Divider()
            Button("Traps") { onOpenTraps() }
            Divider()
            Button("Player Designer") { onOpenPlayerDesigner() }
            Divider()
            Button("Custom Animations") { onOpenCustomTrickStudio() }
            Divider()
            Button("AI Designer") {
                onOpenAIStudio()
            }
            Divider()
            Button("Background Designer (disabled for this release)") {
                onOpenBackgroundDesigner()
            }
            .disabled(true)
            Divider()
            Button("Swarm Designer") {
                onOpenSwarmWaypointBinder()
            }
            Divider()
            Button("Dynamic Studio") {
                onOpenDynamicStudio()
            }
        } label: {
            menuLabel("Tools")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func menuLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12))
            .foregroundStyle(Color.editorPrimaryText.opacity(0.82))
    }
}

struct AboutSheet: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Vector 2 Level Editor")
                .font(.system(size: 24, weight: .bold))

            Text("Developed by ghosted")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)

            Text("Release v0.1 alpha")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                Text("Community")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                HStack(spacing: 10) {
                    contactLink("YouTube", "https://www.youtube.com/@Enderdude290")
                    contactPill("Discord: enderdude290")
                    contactLink("Vectorier server", "https://discord.com/invite/pVRuFBVwC2")
                }
            }

            Text("A massive thanks to:")
                .font(.system(size: 18, weight: .bold))

            VStack(alignment: .leading, spacing: 12) {
                creditLine("@vision", "ConvertXmlObject2 guidance and Vector 2 XML sanity checks")
                creditLine("@flipthosetitle", "Vectorier work that was used for this project")
                creditLine("@tom", "Windows port work")
                creditLine("@kubinka", "The most eager playtester")
            }

            Spacer()
        }
        .padding(28)
        .frame(width: 660, height: 410)
    }

    private func creditLine(_ name: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(name)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(.blue)
                .frame(width: 120, alignment: .leading)
            Text(detail)
                .font(.system(size: 14))
                .foregroundStyle(.primary.opacity(0.82))
        }
    }

    private func contactLink(_ title: String, _ url: String) -> some View {
        Link(destination: URL(string: url)!) {
            Text(title)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.blue.opacity(0.85), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func contactPill(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(.primary.opacity(0.86))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color.white.opacity(0.08), in: Capsule())
    }
}

/// Keep this guide in sync when a tool or shortcut changes.
struct HelpSheet: View {
    private let channelURL = URL(string: "https://www.youtube.com/@Enderdude290")!
    private let discordURL = URL(string: "https://discord.com/invite/pVRuFBVwC2")!
    private let toolRows: [(EditorTool, String)] = [
        (.cursor, "Select, drag, resize single objects, rotate single objects"),
        (.images, "Place texture images from the asset browser"),
        (.backgrounds, "Place background-tagged images"),
        (.trapezoid, "Place slope collision. Hold Y for Type 2"),
        (.collision, "Place rectangular platform collision"),
        (.trigger, "Place trigger regions"),
        (.area, "Place Area regions"),
        (.coin, "Place bonus pickups"),
        (.camera, "Place camera and zoom helpers"),
        (.comment, "Place editor-only red comment boxes; they do not export"),
        (.objectRef, "Place object references"),
        (.object, "Place library objects"),
        (.dynamic, "Open Dynamic Studio from Tools to bake movement/size/rotation keyframes"),
        (.playerIn, "Player start gate"),
        (.playerOut, "Player exit gate"),
        (.runFast, "RunFast area: exports as Area Type=Animation"),
        (.swarm, "Swarm helper"),
        (.waypoint, "Swarm waypoint")
    ]

    private let shortcuts: [(String, String)] = [
        (", (comma)", "Center the canvas on the selected object without changing zoom"),
        ("1-9", "Switch tools on the left rail"),
        ("I", "Toggle parallax preview. Pan the canvas to see Bg images move at their saved Factor; press I again to edit"),
        ("Hold Q + scroll", "Cycle through left-rail tools"),
        ("Hold V + drag", "Corner/edge snap against nearby objects"),
        ("Hold U + drag", "Middle-handle snap against nearby objects"),
        ("Hold T + drag", "Lock movement horizontally"),
        ("Hold G + drag", "Lock movement vertically"),
        ("Hold Y in Trapezoid tool", "Place Type 2 trapezoid"),
		("Shift + drag", "Highlight/select several canvas objects at once. Use this to select a room floor and its objects before assigning a variant"),
        ("Shift in hierarchy", "Range-select like Photoshop"),
        ("Cmd+C / Cmd+V", "Copy and paste selected object"),
        ("Delete", "Delete selected object"),
        ("Cmd+Z / Cmd+Shift+Z", "Undo / redo")
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                quickStart
                backgroundGuide
                featureGuide
                troubleshooting
                shortcutGrid
                toolMap
                DynamicStudioHelpSection()
            }
            .padding(26)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.platformWindowBackground)
    }

    private var featureGuide: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("The stuff you'll use most").font(.system(size: 17, weight: .bold))
            helpRow("Rooms and variants", "Open Tools → Room Layouts. Shift-drag around the floor and everything that belongs to one route, then save it as Start, Middle or Finish. Objects left outside a layout appear in every variant.")
            helpRow("Entrances and exits", "Open the matching designer from Tools, choose a zone, add your artwork, then hit Save to Zone. The starting In, Out and floor are already there. Each zone has its own entrance and exit pool.")
            helpRow("Custom zones", "Check the zone's RoomsPath and keep at least one playable room there with In, Out and a platform. If there's only one room, the generator reuses it for each segment.")
            helpRow("Story and dialogue", "Project Manager → Story & Dialogue: add speakers in Cast, write reusable lines in Dialogue, then connect lines, entrances, choices and events in Story Flow.")
            helpRow("Triggers and quests", "A trigger is WHEN, optional IF, then DO. Build it in Trigger Designer and place it in a room. For quests, ExecuteCall must send the exact objective event name.")
            helpRow("Typing trigger XML", "Start an event, condition or action tag to get suggestions, or press Escape to complete it. Insert adds to the loop selected in the visual editor. Apply XML checks it before changing the trigger.")
            helpRow("Dynamic Studio", "Select the object or its parent, add a frame 0 pose, move the playhead and object, add another keyframe, then Preview and Save. Children move with their parent.")
            helpRow("Parenting", "Drag objects under a parent in Hierarchy. Moving the parent moves the whole assembly; children keep their positions relative to it.")
            helpRow("Find your selection", "Press comma to center the canvas on the selected object. Hierarchy expands its parents and scrolls to its row; switch off Hierarchy follows selection in Settings if you prefer manual navigation.")
            helpRow("Custom assets", "Import a texture before placing objects that use it. If you changed files in Finder, hit Refresh Assets. Obstacle packages bring their XML, preview and textures together.")
            helpRow("Project Manager", "Use it when you want to organize zones, stories, tricks and other project content, or install a whole project. You can create and play a room without opening it.")
        }.padding(16).background(RoundedRectangle(cornerRadius: 16).fill(Color.platformControlBackground))
    }

    private var troubleshooting: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("When something looks wrong").font(.system(size: 17, weight: .bold))
            helpRow("Green or empty object", "The XML loaded, but its texture or library dependency did not resolve. Check Assets and the object's File/Class values.")
            helpRow("Room does not start", "Check that the room has an In, Out and a usable platform path. Missing library objects can stop Vector before the room appears. If it's part of a project, run Validate there too.")
            helpRow("Trigger does nothing", "Check its box overlaps the player, then verify the event, action and referenced Stable ID in the XML diagnostics.")
            helpRow("Wrong custom rooms", "Each custom zone must point RoomsPath at its own folder. Normal generation only uses that folder; Play can still test a named room directly.")
            helpRow("Background is missing", "Check that the set is saved to the right zone, then click Install to Game. A room background and a zone pool background use different save paths.")
            helpRow("Background pieces shifted", "Load the saved set onto the canvas and check the pieces together. Keep buildings positioned against the main background, then save and install the whole set again.")
        }.padding(16).background(RoundedRectangle(cornerRadius: 16).fill(Color.platformControlBackground))
    }

    private func helpRow(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) { Text(title).font(.subheadline.bold()); Text(text).font(.caption).foregroundStyle(.secondary) }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Vector 2 Editor Help")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                Text("Start here, then jump into the tools below. If you get stuck, the fixes are right here too.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 6) {
                Link(destination: channelURL) {
                    Label("My YouTube channel", systemImage: "play.rectangle.fill")
                        .font(.system(size: 12, weight: .semibold))
                }
                Link(destination: discordURL) {
                    Label("Vectorier Discord", systemImage: "bubble.left.and.bubble.right.fill")
                        .font(.system(size: 12, weight: .semibold))
                }
                Text("Discord: enderdude290")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.bordered)
        }
    }

    private var quickStart: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Make a room, play it, keep going").font(.system(size: 17, weight: .bold))
            Text("The editor opens with a blank room ready to go. Project Manager is optional for a single room.")
                .font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 165), spacing: 10)], spacing: 10) {
                guideStep("1", "Start on the canvas", "Your first room is already open, with In and Out placed. Use New Document only when you want another room.", "square.dashed")
                guideStep("2", "Build it", "Add a platform, then place artwork, obstacles and anything else the player needs.", "square.on.square")
                guideStep("3", "Save the XML", "Choose File → Save XML. For a new room, pick its filename and where to keep it.", "square.and.arrow.down")
                guideStep("4", "Play it", "Use Play to test the open room in Vector 2. Set your game folder first so the editor can launch it.", "play.circle")
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.accentColor.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.accentColor.opacity(0.18), lineWidth: 1))
    }

    private var backgroundGuide: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Backgrounds: pick the right path").font(.system(size: 17, weight: .bold))
            Text("These two buttons save different things. Pick the one you actually want in game.")
                .font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 12)], spacing: 12) {
                backgroundPath("One room", "Open a room → Tools → Background Designer → Save Background → Assign to Room", "Use this when the same room should always show that background.", "rectangle.on.rectangle")
                backgroundPath("Random zone pool", "Open Zone Pool Designer → choose zone → place pieces → Save to Zone Pool → Install to Game", "Every saved set for that zone stays in its random pool. Delete an old set if the game should stop picking it.", "square.stack.3d.up")
            }
            Text("Want to see how the shipped backgrounds are built? In Background Designer, choose Vector Library and load one onto the canvas. Select a piece to check its layer, Factor and size.")
                .font(.caption).foregroundStyle(.secondary)
            Text("For parallax, select an image and turn it on in Background Designer. Lower Factor means stronger movement; shipped backgrounds commonly use 0.65–0.95. Press I, pan the canvas to preview, then press I again to edit. Keep a single image within 3268 × 2343 and use several pieces for wider scenes.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.platformControlBackground))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.editorHairline, lineWidth: 1))
    }

    private func guideStep(_ number: String, _ title: String, _ detail: String, _ symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: symbol).foregroundStyle(Color.accentColor)
                Spacer()
                Text(number).font(.caption.bold()).foregroundStyle(Color.accentColor)
            }
            Text(title).font(.subheadline.bold())
            Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.platformControlBackground))
    }

    private func backgroundPath(_ title: String, _ route: String, _ detail: String, _ symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).font(.subheadline.bold()).foregroundStyle(Color.accentColor)
            Text(route).font(.caption.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
            Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.06)))
    }

    private var shortcutGrid: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Keyboard")
                .font(.system(size: 17, weight: .bold))

            LazyVGrid(columns: [GridItem(.fixed(190), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 10) {
                ForEach(shortcuts, id: \.0) { shortcut, detail in
                    Text(shortcut)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.82)))

                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.editorPrimaryText.opacity(0.72))
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.platformControlBackground))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.editorHairline, lineWidth: 1))
    }

    private var toolMap: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tools")
                .font(.system(size: 17, weight: .bold))

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                ForEach(toolRows, id: \.0) { tool, detail in
                    HStack(alignment: .top, spacing: 10) {
                        toolBadge(tool)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(tool.rawValue)
                                .font(.system(size: 12, weight: .bold))
                            Text(detail)
                                .font(.system(size: 11))
                                .foregroundStyle(Color.editorSecondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.platformControlBackground))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.editorHairline, lineWidth: 1))
                }
            }
        }
    }

    private func toolBadge(_ tool: EditorTool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.accentColor.opacity(0.10))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.blue.opacity(0.22), lineWidth: 1))

            if [.playerIn, .playerOut, .runFast, .swarm, .waypoint].contains(tool) {
                Text(shortLabel(for: tool))
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.editorPrimaryText.opacity(0.82))
            } else {
                ToolGlyph(tool: tool)
                    .frame(width: 20, height: 20)
            }
        }
        .frame(width: 34, height: 34)
    }

    private func shortLabel(for tool: EditorTool) -> String {
        switch tool {
        case .playerIn: return "IN"
        case .playerOut: return "OUT"
        case .runFast: return "RF"
        case .swarm: return "S"
        case .waypoint: return "W"
        default: return tool.rawValue
        }
    }
}

/// Horizontal icon toolbar under the menu strip.
///
/// Toolbar buttons forward commands to `ContentView.handleToolbarAction`.
struct TopToolbar: View {
    @Binding var selectedGame: GameProfile
    let camera: CanvasCameraState
    let onAction: (ToolbarAction) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(ToolbarAction.allCases) { action in
                ToolbarButton(symbol: action.symbol, label: action.rawValue) {
                    onAction(action)
                }
            }

            Spacer()
            CameraRulers(camera: camera)
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
        .background(Color.editorToolbarBackground)
    }
}

/// The only toolbar fragment that observes camera movement. Keeping this tiny
/// prevents all toolbar buttons from rebuilding while the canvas is panned.
private struct CameraRulers: View {
    @Bindable var camera: CanvasCameraState

    var body: some View {
        HStack(spacing: 10) {
            RulerHandle(value: camera.panOffset.width, zoom: camera.zoom, axis: .horizontal)
            RulerHandle(value: camera.panOffset.height, zoom: camera.zoom, axis: .vertical)
        }
        .padding(.trailing, 8)
    }
}

struct StatusStrip: View {
    let message: String

    var body: some View {
        HStack {
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(Color.editorSecondaryText)
            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(height: 22)
        .background(Color.editorChromeBackground)
    }
}

struct ToolbarButton: View {
    let symbol: String
    let label: String
    var action: (() -> Void)? = nil

    var body: some View {
        Button {
            action?()
        } label: {
            VStack(spacing: 2) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 24, height: 18)
                    .foregroundStyle(Color.editorPrimaryText.opacity(0.84))
                Text(label)
                    .font(.system(size: 9))
                    .foregroundStyle(Color.editorPrimaryText.opacity(0.7))
            }
            .frame(width: 42, height: 28)
        }
        .buttonStyle(.plain)
    }
}

struct RulerHandle: View {
    enum Axis {
        case horizontal
        case vertical
    }

    let value: CGFloat
    let zoom: CGFloat
    let axis: Axis

    private var thumbOffset: CGFloat {
        let camera = axis == .horizontal ? value : -value
        let normalized = camera / max(1, zoom * 18)
        return max(-68, min(68, normalized))
    }

    private var fillWidth: CGFloat {
        max(18, min(160, 160 / max(0.35, zoom)))
    }

    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.gray.opacity(0.55))
                .frame(width: 10, height: 18)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.platformControlBackground)
                    .overlay(Capsule().stroke(Color.editorHairline, lineWidth: 1))
                    .frame(width: 160, height: 6)
                Capsule()
                    .fill(Color.editorSecondaryText.opacity(0.18))
                    .frame(width: fillWidth, height: 6)
                    .offset(x: max(0, min(160 - fillWidth, 80 + thumbOffset - fillWidth / 2)))
                Circle()
                    .fill(Color.gray.opacity(0.55))
                    .frame(width: 10, height: 10)
                    .offset(x: 75 + thumbOffset)
            }
            .frame(width: 160, height: 18)
        }
    }
}

/// Vertical tool rail on the left edge.
///
/// Selecting a tool only changes state. The canvas decides what that tool does
/// on click/drag, which keeps input behavior centralized.
struct ToolRail: View {
    @Binding var selectedTool: EditorTool

    var body: some View {
        VStack(spacing: 0) {
            ForEach(EditorTool.allCases) { tool in
                ToolRailButton(tool: tool, isSelected: selectedTool == tool) {
                    selectedTool = tool
                }
            }
            Spacer()
        }
        .frame(width: 48)
        .background(Color.editorToolbarBackground)
    }
}

struct ToolRailButton: View {
    let tool: EditorTool
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Rectangle()
                    .fill(isSelected ? Color.accentColor.opacity(0.18) : .clear)

                if [.playerIn, .playerOut, .runFast, .swarm, .waypoint].contains(tool) {
                    Text(labelText)
                        .font(.system(size: tool == .playerOut ? 17 : 13, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.editorPrimaryText.opacity(0.84))
                } else {
                    ToolGlyph(tool: tool)
                        .frame(width: 22, height: 22)
                }
            }
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.editorHairline)
                    .frame(height: 1)
            }
        }
        .buttonStyle(.plain)
        .frame(width: 48, height: 38)
        .help(tool.rawValue)
    }

    private var labelText: String {
        switch tool {
        case .playerIn: "IN"
        case .playerOut: "OUT"
        case .runFast: "RF"
        case .swarm: "S"
        case .waypoint: "W"
        default: tool.rawValue
        }
    }
}

/// Hand-drawn tiny icons for the left rail.
///
/// Icons use vector shapes and text instead of asset files.
/// Tool mapping: `.area` is the A tool; `.comment`
/// is the filled circle tool; `.mask` currently shares the same glyph but does
/// not place comment boxes.
struct ToolGlyph: View {
    let tool: EditorTool

    var body: some View {
        Canvas { context, size in
            let stroke = Color.editorPrimaryText.opacity(0.84)
            let fill = Color.editorPrimaryText.opacity(0.84)
            let w = size.width
            let h = size.height

            switch tool {
            case .cursor:
                var arrow = Path()
                arrow.move(to: CGPoint(x: w * 0.22, y: h * 0.12))
                arrow.addLine(to: CGPoint(x: w * 0.22, y: h * 0.82))
                arrow.addLine(to: CGPoint(x: w * 0.42, y: h * 0.66))
                arrow.addLine(to: CGPoint(x: w * 0.54, y: h * 0.9))
                arrow.addLine(to: CGPoint(x: w * 0.66, y: h * 0.84))
                arrow.addLine(to: CGPoint(x: w * 0.54, y: h * 0.62))
                arrow.addLine(to: CGPoint(x: w * 0.8, y: h * 0.62))
                arrow.closeSubpath()
                context.fill(arrow, with: .color(fill))

            case .images:
                var frame = Path()
                frame.addRect(CGRect(x: 2.5, y: 2.5, width: w - 5, height: h - 5))
                context.stroke(frame, with: .color(stroke), lineWidth: 1.25)

                let sun = Path(ellipseIn: CGRect(x: w * 0.67, y: h * 0.18, width: w * 0.12, height: h * 0.12))
                context.fill(sun, with: .color(fill))

                var mountain = Path()
                mountain.move(to: CGPoint(x: w * 0.18, y: h * 0.72))
                mountain.addLine(to: CGPoint(x: w * 0.4, y: h * 0.46))
                mountain.addLine(to: CGPoint(x: w * 0.56, y: h * 0.62))
                mountain.addLine(to: CGPoint(x: w * 0.68, y: h * 0.4))
                mountain.addLine(to: CGPoint(x: w * 0.82, y: h * 0.72))
                context.stroke(mountain, with: .color(stroke), lineWidth: 1.25)

            case .backgrounds:
                var frame = Path()
                frame.addRect(CGRect(x: 2.5, y: 2.5, width: w - 5, height: h - 5))
                context.stroke(frame, with: .color(stroke), lineWidth: 1.25)
                for offset in [0.28, 0.5, 0.72] {
                    var line = Path()
                    line.move(to: CGPoint(x: w * 0.16, y: h * offset))
                    line.addLine(to: CGPoint(x: w * 0.84, y: h * offset))
                    context.stroke(line, with: .color(stroke), lineWidth: 1.1)
                }

            case .trapezoid:
                var shape = Path()
                shape.move(to: CGPoint(x: w * 0.18, y: h * 0.78))
                shape.addLine(to: CGPoint(x: w * 0.84, y: h * 0.78))
                shape.addLine(to: CGPoint(x: w * 0.58, y: h * 0.16))
                shape.closeSubpath()
                context.fill(shape, with: .color(fill))

            case .collision:
                var shape = Path()
                shape.addRect(CGRect(x: 3, y: 3, width: w - 6, height: h - 6))
                context.stroke(shape, with: .color(stroke), lineWidth: 1.55)

            case .trigger:
                let resolved = context.resolve(
                    Text("T")
                        .font(.system(size: 21, weight: .regular))
                        .foregroundStyle(stroke)
                )
                context.draw(resolved, at: CGPoint(x: w / 2, y: h / 2 + 1), anchor: .center)

            case .area:
                let resolved = context.resolve(
                    Text("A")
                        .font(.system(size: 21, weight: .regular))
                        .foregroundStyle(stroke)
                )
                context.draw(resolved, at: CGPoint(x: w / 2, y: h / 2 + 1), anchor: .center)

            case .coin:
                var diamond = Path()
                diamond.move(to: CGPoint(x: w * 0.5, y: h * 0.12))
                diamond.addLine(to: CGPoint(x: w * 0.85, y: h * 0.5))
                diamond.addLine(to: CGPoint(x: w * 0.5, y: h * 0.88))
                diamond.addLine(to: CGPoint(x: w * 0.15, y: h * 0.5))
                diamond.closeSubpath()
                context.stroke(diamond, with: .color(stroke), lineWidth: 1.25)

            case .camera:
                var body = Path()
                body.addRect(CGRect(x: w * 0.18, y: h * 0.34, width: w * 0.38, height: h * 0.32))
                context.stroke(body, with: .color(stroke), lineWidth: 1.2)

                var lens = Path()
                lens.move(to: CGPoint(x: w * 0.56, y: h * 0.4))
                lens.addLine(to: CGPoint(x: w * 0.84, y: h * 0.28))
                lens.addLine(to: CGPoint(x: w * 0.84, y: h * 0.72))
                lens.addLine(to: CGPoint(x: w * 0.56, y: h * 0.6))
                lens.closeSubpath()
                context.stroke(lens, with: .color(stroke), lineWidth: 1.2)

            case .comment, .mask:
                let circle = Path(ellipseIn: CGRect(x: w * 0.18, y: h * 0.18, width: w * 0.64, height: h * 0.64))
                context.fill(circle, with: .color(fill))

            case .objectRef:
                let resolved = context.resolve(
                    Text("⌘")
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(stroke)
                )
                context.draw(resolved, at: CGPoint(x: w / 2, y: h / 2 + 0.5), anchor: .center)

            case .object:
                var hex = Path()
                hex.move(to: CGPoint(x: w * 0.5, y: h * 0.08))
                hex.addLine(to: CGPoint(x: w * 0.8, y: h * 0.26))
                hex.addLine(to: CGPoint(x: w * 0.8, y: h * 0.74))
                hex.addLine(to: CGPoint(x: w * 0.5, y: h * 0.92))
                hex.addLine(to: CGPoint(x: w * 0.2, y: h * 0.74))
                hex.addLine(to: CGPoint(x: w * 0.2, y: h * 0.26))
                hex.closeSubpath()
                context.stroke(hex, with: .color(stroke), lineWidth: 1.2)

            case .dynamic:
                var top = Path()
                top.move(to: CGPoint(x: w * 0.2, y: h * 0.28))
                top.addLine(to: CGPoint(x: w * 0.5, y: h * 0.12))
                top.addLine(to: CGPoint(x: w * 0.8, y: h * 0.28))
                top.addLine(to: CGPoint(x: w * 0.5, y: h * 0.44))
                top.closeSubpath()
                context.stroke(top, with: .color(stroke), lineWidth: 1.15)

                var left = Path()
                left.move(to: CGPoint(x: w * 0.2, y: h * 0.28))
                left.addLine(to: CGPoint(x: w * 0.2, y: h * 0.7))
                left.addLine(to: CGPoint(x: w * 0.5, y: h * 0.86))
                left.addLine(to: CGPoint(x: w * 0.5, y: h * 0.44))
                left.closeSubpath()
                context.stroke(left, with: .color(stroke), lineWidth: 1.15)

                var right = Path()
                right.move(to: CGPoint(x: w * 0.8, y: h * 0.28))
                right.addLine(to: CGPoint(x: w * 0.8, y: h * 0.7))
                right.addLine(to: CGPoint(x: w * 0.5, y: h * 0.86))
                right.addLine(to: CGPoint(x: w * 0.5, y: h * 0.44))
                right.closeSubpath()
                context.stroke(right, with: .color(stroke), lineWidth: 1.15)

            default:
                break
            }
        }
    }
}

/// File/tab strip below the toolbar.
///
/// Shows open documents in a row. Middle-click closes a tab.
struct DocumentTabs: View {
    let documents: [LevelDocument]
    @Binding var selectedDocumentID: LevelDocument.ID
    let onClose: (LevelDocument.ID) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(documents) { document in
                HStack(spacing: 8) {
                    Button {
                        selectedDocumentID = document.id
                    } label: {
                        Text(document.name)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.editorPrimaryText.opacity(0.86))
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)

                    Button {
                        onClose(document.id)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color.editorSecondaryText)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(selectedDocumentID == document.id ? Color.editorSelectedTabBackground : Color.editorUnselectedTabBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.editorHairline, lineWidth: 1)
                )
                .background(
                    MiddleClickMonitor {
                        onClose(document.id)
                    }
                )
                .padding(.leading, document.id == documents.first?.id ? 8 : 4)
            }
            Spacer()
        }
        .frame(height: 31)
        .background(Color.editorTabBarBackground)
    }
}

/// AppKit shim that lets tabs close on middle mouse.
///
/// A transparent AppKit view catches middle-clicks that SwiftUI doesn't expose.
struct MiddleClickMonitor: NSViewRepresentable {
    let onMiddleClick: () -> Void

    func makeNSView(context: Context) -> MiddleClickMonitorView {
        MiddleClickMonitorView(onMiddleClick: onMiddleClick)
    }

    func updateNSView(_ nsView: MiddleClickMonitorView, context: Context) {
        nsView.onMiddleClick = onMiddleClick
    }
}

final class MiddleClickMonitorView: NSView {
    var onMiddleClick: () -> Void
    private var monitor: Any?

    init(onMiddleClick: @escaping () -> Void) {
        self.onMiddleClick = onMiddleClick
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        self.onMiddleClick = {}
        super.init(coder: coder)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
            return
        }

        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.otherMouseDown]) { [weak self] event in
            guard let self, event.buttonNumber == 2, event.window === self.window else { return event }
            let point = self.convert(event.locationInWindow, from: nil)
            guard self.bounds.contains(point) else { return event }
            self.onMiddleClick()
            return nil
        }
    }

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}

/// Click bridge used by the hierarchy panel for modifier-aware selection.
///
/// Reads Shift/Cmd from the click event for range and toggle selection.
struct HierarchyClickCatcher: NSViewRepresentable {
    let onClick: (NSEvent.ModifierFlags) -> Void

    func makeNSView(context: Context) -> HierarchyClickCatcherView {
        HierarchyClickCatcherView(onClick: onClick)
    }

    func updateNSView(_ nsView: HierarchyClickCatcherView, context: Context) {
        nsView.onClick = onClick
    }
}

final class HierarchyClickCatcherView: NSView {
    var onClick: (NSEvent.ModifierFlags) -> Void

    init(onClick: @escaping (NSEvent.ModifierFlags) -> Void) {
        self.onClick = onClick
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        self.onClick = { _ in }
        super.init(coder: coder)
    }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        onClick(event.modifierFlags.intersection(.deviceIndependentFlagsMask))
    }
}

/// Empty editor landing page shown when no XML documents are open.
///
/// Gives quick access to new, open and recent files when the workspace is empty.
struct EmptyWorkspaceView: View {
    let onNew: () -> Void
    let onOpen: () -> Void
    let recentPaths: [String]
    let onOpenRecent: (String) -> Void

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Text("No Levels Open")
                .font(.system(size: 28, weight: .semibold))
            Text("Create a new level, load one from XML, or reopen your work and keep cooking.")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button("Create New Level", action: onNew)
                Button("Open XML", action: onOpen)
            }
            .buttonStyle(.borderedProminent)

            if !recentPaths.isEmpty {
                VStack(spacing: 8) {
                    Text("Recent")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)

                    ForEach(recentPaths, id: \.self) { path in
                        Button {
                            onOpenRecent(path)
                        } label: {
                            Text(URL(fileURLWithPath: path).lastPathComponent)
                                .lineLimit(1)
                        }
                        .buttonStyle(.link)
                    }
                }
                .padding(.top, 8)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.platformWindowBackground)
    }
}

// MARK: - Canvas / Editing Surface

/// Main world editor.
///
/// Responsibilities:
/// - draw grid, images, library previews, collision/trigger/area overlays
/// - place nodes from left-rail tools or asset browser selection
/// - select/move/resize/rotate nodes
/// - run marquee selection, V-snapping, Q tool cycling, Y trapezoid variant
///
/// Porting warning: coordinates are Vector 2 world units, not screen pixels.
/// `vectorUnitsPerCanvasPoint` controls the editor zoom relationship; exporters
/// should never use screen-space values directly.
