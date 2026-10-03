import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

// Main editor window and command routing. The document stores Vector world
// coordinates; canvas pan and zoom stay in the view. Room XML comes from
// LevelDocument, and editor-only Comment boxes stay out of the export.
// The game preview writes a room, then asks the local console bridge to load it.

extension Notification.Name {
    static let vector2EditorCopyRequested = Notification.Name("vector2EditorCopyRequested")
    static let vector2EditorPasteRequested = Notification.Name("vector2EditorPasteRequested")
    static let vector2ClearImportedAssetsRequested = Notification.Name("vector2ClearImportedAssetsRequested")
}

private enum CustomTrapDependencyError: LocalizedError {
    case noActiveProject
    case missingLibrary(String)
    case gameDataPermissionRequired

    var errorDescription: String? {
        switch self {
        case .noActiveProject:
            return "Open the project in Project Manager once so the editor can install this trap's library and artwork."
        case let .missingLibrary(filename):
            return "The room uses \(filename), but that trap has not been compiled in the active project. Open Trap Designer and choose Save & Compile."
        case .gameDataPermissionRequired:
            return "Vector 2 Data access was not granted. Choose the data folder so the room, trap library and textures can be installed together."
        }
    }
}

// Commands that need to work globally even when SwiftUI focus is sitting on the
// canvas. AppKit catches them more reliably than pure SwiftUI commands here.
private enum AppKeyCommand {
    case copy
    case paste
    case tool(EditorTool)
    case parallaxPreview
}

// Tiny invisible AppKit view mounted behind the SwiftUI tree. It lets us catch
// Cmd+C/Cmd+V and number-key tool shortcuts without breaking text fields.
private struct AppKeyCommandCatcher: NSViewRepresentable {
    let isEnabled: Bool
    let onCommand: (AppKeyCommand) -> Void

    func makeNSView(context: Context) -> AppKeyCommandView {
        AppKeyCommandView(isEnabled: isEnabled, onCommand: onCommand)
    }

    func updateNSView(_ nsView: AppKeyCommandView, context: Context) {
        nsView.onCommand = onCommand
        nsView.isEnabled = isEnabled
    }

    static func dismantleNSView(_ nsView: AppKeyCommandView, coordinator: ()) {
        nsView.stopMonitoring()
    }
}

private final class AppKeyCommandView: NSView {
    var onCommand: (AppKeyCommand) -> Void
    var isEnabled: Bool
    private var monitor: Any?

    private var isTextInputFocused: Bool {
        guard let responder = window?.firstResponder else { return false }
        return responder is NSTextView || responder is NSTextField || responder is NSSearchField
    }

    init(isEnabled: Bool, onCommand: @escaping (AppKeyCommand) -> Void) {
        self.isEnabled = isEnabled
        self.onCommand = onCommand
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        self.onCommand = { _ in }
        self.isEnabled = false
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
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            guard self.isEnabled else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard !self.isTextInputFocused else { return event }
            if flags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "c" {
                self.onCommand(.copy)
                return nil
            }
            if flags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "v" {
                self.onCommand(.paste)
                return nil
            }
            guard !flags.contains(.command), let key = event.charactersIgnoringModifiers else { return event }
            if flags.intersection([.command, .control, .option]).isEmpty, key.lowercased() == "i" {
                self.onCommand(.parallaxPreview)
                return nil
            }
            if let tool = EditorTool.tool(forNumberKey: key) {
                self.onCommand(.tool(tool))
                return nil
            }
            return event
        }
    }

    deinit {
        stopMonitoring()
    }

    func stopMonitoring() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

// MARK: - Main Editor Shell

// ContentView should coordinate features, not secretly become every feature.
// Focused popups such as the swarm binder now live in EditorUtilitySheets.swift.

/// Main window state: tabs, tools, assets, undo and redo, and game preview.
struct ContentView: View {
    private var isProjectManagerSelected: Bool {
        editor.documents.contains { $0.id == editor.selectedDocumentID && $0.sourcePath == "internal://project-manager" }
    }
    // The sidebar buttons all update the same active tool.
    @State private var selectedTool = EditorTool.images
    @State private var lastRoomDocumentID: UUID?
    // Older document paths still use the game selector. New rooms default to Vector 2.
    @State private var selectedGame = GameProfile.vector2
    // Which tab is visible in the right dock: hierarchy, inspector, or raw XML.
    @State private var selectedRightTab = RightSidebarTab.properties
    // Whole editor workspace: open tabs, active tab, and scene trees. This is the
    // closest thing we have to a document-store service.
    @State private var editor = EditorSession.workspaceOrFallback
    // Undo/redo are snapshot-based. Heavy, but safe for XML editor data because
    // LevelDocument/LevelNode are value types. Do not snapshot every mouse move.
    @State private var undoStack: [EditorSession] = []
    @State private var redoStack: [EditorSession] = []
    @State private var isRestoringHistory = false
    @State private var isLiveEditing = false
    // Presentation state for Settings, About and Help.
    @State private var isSettingsPresented = false
    @State private var isHelpPresented = false
    @State private var isCreditsPresented = false
    @State private var isSwarmWaypointBinderPresented = false
    @State private var isTrickPreviewPresented = false
    @State private var isCustomTrickStudioPresented = false
    @State private var isBackgroundDesignerPresented = false
    @State private var parallaxPreviewEnabled = false
    @State private var parallaxPreviewStartPan: CGSize = .zero
    @State private var isRoomLayoutsPresented = false
    @State private var isTrapPlacementPresented = false
    @State private var trickPreviewPlayback: TrickPreviewPlayback?
    // Cached browser catalog. Refreshing this is what makes newly copied assets
    // show up without restarting the editor.
    @State private var assetCatalog = Vector2AssetCatalog.load()
    // Asset chosen from the browser but not placed yet. The next canvas click
    // consumes this and creates a node at that world coordinate.
    @State private var activePlacementAsset: TextureAsset?
    // Copy/paste buffer for whole editor nodes. Raw XML copy lives separately in
    // the Raw XML panel; this one is scene-object copy.
    @State private var copiedNode: LevelNode?
    @State private var statusMessage = "Vector 2 editor ready"
    @State private var structuralSaveRequest = 0
    // Camera for the editor canvas only. These are not exported into room XML.
    @State private var canvasCamera = CanvasCameraState()
    @State private var inspectorLivePreviewTransforms: [LevelNode.ID: LevelNode.Transform] = [:]
    // Dynamic Studio is disabled for this release, but these are left in place
    // so a future tab can target a normal room document without rewriting shell
    // state. Windows can ignore these until Dynamic Studio comes back.
    @State private var dynamicStudioTargetDocumentID: LevelDocument.ID?
    @State private var aiStudioTargetDocumentID: LevelDocument.ID?
    @State private var playerDesignerTargetDocumentID: LevelDocument.ID?
    @State private var triggerStudioTargetDocumentID: LevelDocument.ID?
    // User-selected paths are saved in settings, not hardcoded into the app.
    @AppStorage("vector2GameDirectory") private var vector2GameDirectory = ""
    @AppStorage("vector2CustomRoomsDirectory") private var vector2CustomRoomsDirectory = ""
    @AppStorage("vector2GameDataDirectory") private var vector2GameDataDirectory = ""
    @AppStorage("vector2GameDirectoryBookmark") private var vector2GameDirectoryBookmark = ""
    @AppStorage("vector2CustomRoomsDirectoryBookmark") private var vector2CustomRoomsDirectoryBookmark = ""
    @AppStorage("vector2GameDataDirectoryBookmark") private var vector2GameDataDirectoryBookmark = ""
    @AppStorage("vector2CustomBackgroundsDirectory") private var vector2CustomBackgroundsDirectory = ""
    @AppStorage("vector2CustomTexturesDirectory") private var vector2CustomTexturesDirectory = ""
    @AppStorage("extraAssetFolders") private var extraAssetFoldersData = ""
    // RoomWeaver owns room imports. Runtime Graph stays available as the stable
    // original path and should not be mutated by RoomWeaver experiments.
    @AppStorage("vector2ImportPipeline") private var vector2ImportPipeline = Vector2ImportPipeline.roomWeaver.rawValue
    @AppStorage("vector2RoomWeaverConsoleEnabled") private var roomWeaverConsoleEnabled = false
    @AppStorage("vector2RoomWeaverVerboseDiagnostics") private var roomWeaverVerboseDiagnostics = false
    @AppStorage("vector2TrickPreviewConsoleEnabled") private var trickPreviewConsoleEnabled = false
    @AppStorage("vector2.editorDarkMode") private var editorDarkMode = false
    @AppStorage("recentXMLPaths") private var recentXMLPathsData = ""

    var body: some View {
        ZStack {
            Color.platformWindowBackground
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Top native-looking menu strip. This is intentionally separate
                // from the icon toolbar because File/About/Help are document/app
                // concepts, while the toolbar is quick action buttons.
                MenuStrip(
                    recentPaths: recentXMLPaths,
                    onFileAction: handleToolbarAction(_:),
                    onOpenRecent: openRecentXML(at:),
                    onShowHelp: openHelpStudio,
                    onShowCredits: { isCreditsPresented = true },
                    onOpenDynamicStudio: openDynamicStudio,
                    onOpenAIStudio: openAIStudio,
                    onOpenSwarmWaypointBinder: { isSwarmWaypointBinderPresented = true },
                    onOpenBackgroundDesigner: {
                        statusMessage = "Per-room backgrounds are disabled for this release. The Project Manager background pool is still available."
                    },
                    onOpenCustomTrickStudio: { isCustomTrickStudioPresented = true },
                    onOpenPlayerDesigner: openPlayerDesigner,
                    onOpenRoomLayouts: {
                        guard !isProjectManagerSelected else {
                            statusMessage = "Open a room tab before editing room layouts"
                            return
                        }
                        isRoomLayoutsPresented = true
                        isTrapPlacementPresented = false
                        selectedRightTab = .hierarchy
                        statusMessage = "Room Layouts: select objects, name a Start, Middle or Finish layout, then create it"
                    },
                    onOpenTraps: {
                        guard !isProjectManagerSelected else {
                            statusMessage = "Open a room tab before placing traps"
                            return
                        }
                        isTrapPlacementPresented = true
                        isRoomLayoutsPresented = false
                        selectedRightTab = .properties
                        statusMessage = "Traps: choose a tested setup, then click the canvas to place it"
                    },
                    onOpenXMLBuilder: {
                        guard !isProjectManagerSelected else {
                            statusMessage = "Open a room tab before using Trigger Builder"
                            return
                        }
                        openTriggerStudio()
                    },
                    onOpenObstacleDesigner: openObstacleStudio,
                    onOpenEntranceStudio: { openStructuralRoomStudio(.entrance) },
                    onOpenExitStudio: { openStructuralRoomStudio(.exit) },
                    onOpenProjectManager: {
                        if let existing = editor.documents.first(where: { $0.sourcePath == "internal://project-manager" }) {
                            editor.selectedDocumentID = existing.id
                        } else {
                            editor.appendDocument(LevelDocument(name: "Project Manager", sourcePath: "internal://project-manager", root: LevelNode(name: "Project Manager", kind: .document, factor: "1", transform: nil, xml: .init())))
                        }
                    }
                )
                Divider()
                // Icon toolbar: new/open/import/export/copy/delete/play/etc.
                // Keep toolbar actions routed through `handleToolbarAction`.
                if !isProjectManagerSelected && !selectedDocumentIsTriggerStudio && !selectedDocumentIsHelpStudio { TopToolbar(
                    selectedGame: $selectedGame,
                    camera: canvasCamera,
                    onAction: handleToolbarAction(_:)
                ) }
                Divider()

                HStack(spacing: 0) {
                    // Left rail owns the current placement/selection tool. The
                    // selected value is read by the canvas on click/drag.
                    if !isProjectManagerSelected && !selectedDocumentIsTriggerStudio && !selectedDocumentIsHelpStudio {
                        ToolRail(selectedTool: $selectedTool)
                        Divider()
                    }

                    if editor.documents.isEmpty {
                        EmptyWorkspaceView(
                            onNew: {
                                recordHistorySnapshot()
                                editor.createEmptyDocument(for: selectedGame)
                                statusMessage = "New blank \(selectedGame.rawValue) document"
                            },
                            onOpen: {
                                openXML(replacingSelectedDocument: false)
                            },
                            recentPaths: recentXMLPaths,
                            onOpenRecent: openRecentXML(at:)
                        )
                    } else {
                        VStack(spacing: 0) {
                            DocumentTabs(
                                documents: editor.documents,
                                selectedDocumentID: $editor.selectedDocumentID,
                                onClose: closeDocument(_:)
                            )
                            Divider()

                            if editor.selectedDocument.sourcePath == "internal://project-manager" {
                                ProjectManagerView(onOpenRoom: openRecentXML(at:),
                                                   onOpenZoneBackgroundDesigner: openZoneBackgroundDesigner,
                                                   onPlacePoolBackground: placeProjectBackground(_:),
                                                   onPlaceSceneBackground: placeSceneBackground(_:))
                            } else if selectedDocumentIsHelpStudio {
                                HelpSheet()
                            } else if selectedDocumentIsPlayerDesigner {
                                PlayerDesignerView(document: playerDesignerTargetDocumentBinding, gameDirectory: vector2GameDirectory, onClose: { closeDocument(editor.selectedDocument.id) }, onStatus: { statusMessage = $0 })
                            } else if selectedDocumentIsAIStudio {
                                AIStudioView(
                                    document: aiStudioTargetDocumentBinding,
                                    gameDirectory: vector2GameDirectory,
                                    onStatus: { statusMessage = $0 }
                                )
                            } else if selectedDocumentIsDynamicStudio {
                                DynamicStudioView(
                                    document: dynamicStudioTargetDocumentBinding,
                                    selectedTool: $selectedTool,
                                    activePlacementAsset: activePlacementAsset,
                                    fallbackPlacementAsset: Vector2AssetCatalog.defaultPlacementAsset(for: selectedTool, in: assetCatalog),
                                    camera: canvasCamera,
                                    onDeleteSelection: { handleToolbarAction(.delete) },
                                    onLiveEditBegan: beginLiveEdit,
                                    onLiveEditEnded: endLiveEdit
                                )
                            } else if selectedDocumentIsTriggerStudio {
                                XMLTemplateBuilderView(
                                    document: triggerStudioTargetDocumentBinding,
                                    onClose: { closeDocument(editor.selectedDocument.id) },
                                    onStatus: { statusMessage = $0 }
                                )
                            } else if selectedDocumentIsObstacleStudio {
                                VStack(spacing: 0) {
                                    CanvasArea(
                                        selectedTool: $selectedTool,
                                        activePlacementAsset: activePlacementAsset,
                                        fallbackPlacementAsset: Vector2AssetCatalog.defaultPlacementAsset(for: selectedTool, in: assetCatalog),
                                        camera: canvasCamera,
                                        onDeleteSelection: { handleToolbarAction(.delete) },
                                        onLiveEditBegan: beginLiveEdit,
                                        onLiveEditEnded: endLiveEdit,
                                        document: selectedDocumentBinding,
                                        trickPreviewPlayback: $trickPreviewPlayback,
                                        dynamicLivePreviewTransforms: inspectorLivePreviewTransforms,
                                        showRoomLayoutGuides: false,
                                        showTrapGuides: false
                                    )
                                    Divider()
                                    ObstacleDesignerBar(document: selectedDocumentBinding, onStatus: { statusMessage = $0 })
                                }
                            } else if editor.selectedDocument.isStructuralRoomStudio {
                                VStack(spacing: 0) {
                                    CanvasArea(
                                        selectedTool: $selectedTool,
                                        activePlacementAsset: activePlacementAsset,
                                        fallbackPlacementAsset: Vector2AssetCatalog.defaultPlacementAsset(for: selectedTool, in: assetCatalog),
                                        camera: canvasCamera,
                                        onDeleteSelection: { handleToolbarAction(.delete) },
                                        onLiveEditBegan: beginLiveEdit,
                                        onLiveEditEnded: endLiveEdit,
                                        document: selectedDocumentBinding,
                                        trickPreviewPlayback: $trickPreviewPlayback,
                                        dynamicLivePreviewTransforms: inspectorLivePreviewTransforms,
                                        showRoomLayoutGuides: false,
                                        showTrapGuides: false
                                    )
                                    Divider()
                                    StructuralRoomStudioBar(document: selectedDocumentBinding, saveRequest: structuralSaveRequest, onStatus: { statusMessage = $0 })
                                        .frame(height: 92)
                                }
                            } else {
                                // Main editable world. This receives the active
                                // document as a binding so it can mutate transforms,
                                // selections, placements, and hierarchy nodes.
                                VStack(spacing: 0) {
                                    CanvasArea(
                                        selectedTool: $selectedTool,
                                        activePlacementAsset: activePlacementAsset,
                                        fallbackPlacementAsset: editor.selectedDocument.sourcePath == "internal://zone-background-pool"
                                            ? nil : Vector2AssetCatalog.defaultPlacementAsset(for: selectedTool, in: assetCatalog),
                                        camera: canvasCamera,
                                        onDeleteSelection: { handleToolbarAction(.delete) },
                                        onLiveEditBegan: beginLiveEdit,
                                        onLiveEditEnded: endLiveEdit,
                                        parallaxPreviewEnabled: parallaxPreviewEnabled,
                                        parallaxPreviewStartPan: parallaxPreviewStartPan,
                                        onToggleParallaxPreview: toggleParallaxPreview,
                                        onPlaceAsset: {
                                            if editor.selectedDocument.sourcePath == "internal://zone-background-pool" {
                                                activePlacementAsset = nil
                                                selectedTool = .cursor
                                            }
                                        },
                                        document: selectedDocumentBinding,
                                        trickPreviewPlayback: $trickPreviewPlayback,
                                        dynamicLivePreviewTransforms: inspectorLivePreviewTransforms,
                                        showRoomLayoutGuides: isRoomLayoutsPresented,
                                        showTrapGuides: isTrapPlacementPresented
                                    )
                                    if isRoomLayoutsPresented {
                                        Divider()
                                        RoomLayoutEditorPanel(
                                            document: selectedDocumentBinding,
                                            isPresented: $isRoomLayoutsPresented
                                        )
                                        .frame(height: 300)
                                    }
                                    if isTrapPlacementPresented {
                                        Divider()
                                        TrapPlacementPanel(
                                            document: selectedDocumentBinding,
                                            isPresented: $isTrapPlacementPresented,
                                            assetCatalog: assetCatalog,
                                            onArmPlacement: { asset in
                                                activePlacementAsset = asset
                                                selectedTool = .objectRef
                                            },
                                            onOpenSwarmDesigner: {
                                                isSwarmWaypointBinderPresented = true
                                            },
                                            onStatus: { statusMessage = $0 }
                                        )
                                        .frame(height: 250)
                                    }
                                    if isBackgroundDesignerPresented && editor.selectedDocument.sourcePath == "internal://zone-background-pool" {
                                        Divider()
                                        if editor.selectedDocument.sourcePath != "internal://zone-background-pool" {
                                            RoomBackgroundDesignerOverlay(
                                                document: selectedDocumentBinding,
                                                directoryPath: $vector2CustomBackgroundsDirectory,
                                                texturesPath: $vector2CustomTexturesDirectory,
                                                onClose: { isBackgroundDesignerPresented = false }
                                            ).padding(12).frame(height: 260)
                                        } else {
                                        BackgroundDesignerOverlay(
                                                document: selectedDocumentBinding,
                                                directoryPath: $vector2CustomBackgroundsDirectory,
                                                customTexturesDirectory: $vector2CustomTexturesDirectory,
                                                importedTexturesDirectories: extraAssetFolders,
                                                projectRoot: Vector2AssetCatalog.activeProjectRootURL(),
                                                onBrowseAssets: { showAssetBrowserWindow() },
                                                onPoolSaved: { statusMessage = $0 },
                                                onInstallPool: installZoneBackgroundPool,
                                                onClose: {
                                                    isBackgroundDesignerPresented = false
                                                    if editor.selectedDocument.sourcePath == "internal://zone-background-pool" {
                                                        closeDocument(editor.selectedDocument.id)
                                                    }
                                                }
                                        )
                                        .padding(12)
                                        .frame(height: 300)
                                        .background(Color(nsColor: .windowBackgroundColor))
                                        }
                                    }
                                }
                            }
                        }

                        Divider()
                        // Inspector/right dock combines hierarchy, properties,
                        // and raw XML. Selection changes from here update the
                        // same document selection set used by the canvas.
                        if editor.selectedDocument.sourcePath != "internal://project-manager" && !selectedDocumentIsTriggerStudio { RightDock(
                            selectedTab: $selectedRightTab,
                            document: activeInspectorDocumentBinding,
                            selectedTool: selectedTool,
                            gameDirectory: vector2GameDirectory,
                            dynamicLivePreviewTransforms: $inspectorLivePreviewTransforms
                        ) }
                    }
                }

                Divider()
                StatusStrip(message: statusMessage)
            }
        }
        .frame(minWidth: 1380, minHeight: 860)
        .preferredColorScheme(editorDarkMode ? .dark : .light)
        .overlay(alignment: .bottomLeading) {
            if roomWeaverConsoleEnabled || roomWeaverVerboseDiagnostics {
                RoomWeaverConsoleHost()
                    .equatable()
                    .padding(.leading, 72)
                    .padding(.bottom, 34)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if trickPreviewConsoleEnabled || TrickPreviewDiagnostics.shared.isVisible {
                TrickPreviewConsoleView()
                    .padding(.trailing, 18)
                    .padding(.bottom, 34)
            }
        }
        .sheet(isPresented: $isSettingsPresented) {
            SettingsSheet(
                selectedImportPipelineRaw: $vector2ImportPipeline,
                assetCatalog: assetCatalog,
                currentDocumentName: editor.selectedDocument.name,
                gameDirectory: $vector2GameDirectory,
                customRoomsDirectory: $vector2CustomRoomsDirectory,
                customBackgroundsDirectory: $vector2CustomBackgroundsDirectory,
                customTexturesDirectory: $vector2CustomTexturesDirectory,
                gameDirectoryBookmark: $vector2GameDirectoryBookmark,
                customRoomsDirectoryBookmark: $vector2CustomRoomsDirectoryBookmark,
                extraAssetFoldersData: $extraAssetFoldersData,
                onRefreshAssets: refreshWorkspaceData
            )
        }
        .sheet(isPresented: $isHelpPresented) {
            HelpSheet()
        }
        .sheet(isPresented: $isCreditsPresented) {
            AboutSheet()
        }
        .sheet(isPresented: $isSwarmWaypointBinderPresented) {
            SwarmDesignerView(
                document: activeInspectorDocumentBinding,
                gameDirectory: vector2GameDirectory,
                onClose: { isSwarmWaypointBinderPresented = false },
                onStatus: { statusMessage = $0 }
            )
        }
        .sheet(isPresented: $isTrickPreviewPresented) {
            TrickPreviewPickerSheet(
                selectedNode: editor.selectedDocument.selectedNode,
                gameDirectory: vector2GameDirectory,
                onPreview: { playback in
                    trickPreviewPlayback = playback
                    statusMessage = "Previewing trick \(playback.move.name)"
                },
                onClose: { isTrickPreviewPresented = false }
            )
        }
        .sheet(isPresented: $isCustomTrickStudioPresented) {
            CustomTrickStudioView(
                gameDirectory: vector2GameDirectory,
                onClose: { isCustomTrickStudioPresented = false },
                onStatus: { statusMessage = $0 }
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .vector2EditorCopyRequested)) { _ in
            handleKeyCommand(.copy)
        }
        .onReceive(NotificationCenter.default.publisher(for: .vector2EditorPasteRequested)) { _ in
            handleKeyCommand(.paste)
        }
        .onReceive(NotificationCenter.default.publisher(for: .vector2ClearImportedAssetsRequested)) { _ in
            clearImportedAssets()
        }
        .onReceive(NotificationCenter.default.publisher(for: .vector2AssetCatalogChanged)) { _ in
            assetCatalog = Vector2AssetCatalog.load(extraAssetFolders: extraAssetFolders)
            statusMessage = "Asset Browser updated."
        }
        .onAppear {
            adoptProjectManagerGameDataDestination()
            assetCatalog = Vector2AssetCatalog.load(extraAssetFolders: extraAssetFolders)
        }
        .onChange(of: editor.selectedDocumentID) { previousID, _ in
            if let previous = editor.documents.first(where: { $0.id == previousID }),
               previous.sourcePath?.hasPrefix("internal://") != true {
                lastRoomDocumentID = previous.id
            }
            parallaxPreviewEnabled = false
            if editor.selectedDocument.sourcePath == "internal://zone-background-pool" {
                isBackgroundDesignerPresented = true
            } else if editor.documents.first(where: { $0.id == previousID })?.sourcePath == "internal://zone-background-pool" {
                isBackgroundDesignerPresented = false
            }
            // Project Manager can compile a trap while the room editor remains
            // open. Refresh on tab switches so Custom appears immediately in
            // Tools -> Traps instead of requiring an app restart.
            if editor.documents.first(where: { $0.id == previousID })?.sourcePath == "internal://project-manager" {
                let refreshedCatalog = Vector2AssetCatalog.load(extraAssetFolders: extraAssetFolders)
                for index in editor.documents.indices where editor.documents[index].sourcePath != "internal://project-manager" {
                    _ = editor.documents[index].refreshCustomTrapPreviews(using: refreshedCatalog)
                }
                assetCatalog = refreshedCatalog
            }
        }
        .background(AppKeyCommandCatcher(isEnabled: !isProjectManagerSelected && !selectedDocumentIsTriggerStudio, onCommand: handleKeyCommand(_:)))
    }

    private func clearImportedAssets() {
        extraAssetFoldersData = ""
        assetCatalog = Vector2AssetCatalog.load()
        statusMessage = "Cleared imported asset folders"
    }

    /// Binding to the active document tab.
    ///
    /// SwiftUI needs bindings for subviews to mutate nested document data. The
    /// setter keeps history recording under control by respecting live-edit
    /// sessions, so dragging a resize handle does not add 300 undo steps.
    private var selectedDocumentBinding: Binding<LevelDocument> {
        Binding(
            get: {
                editor.documents[editor.selectedDocumentIndex]
            },
            set: { newDocument in
                let index = editor.selectedDocumentIndex
                guard editor.documents[index] != newDocument else { return }
                if !isLiveEditing {
                    recordHistorySnapshot()
                }
                editor.documents[index] = newDocument
            }
        )
    }

    private var selectedDocumentIsDynamicStudio: Bool {
        editor.selectedDocument.isDynamicStudio
    }

    private var selectedDocumentIsAIStudio: Bool {
        editor.selectedDocument.isAIStudio
    }

    private var selectedDocumentIsPlayerDesigner: Bool { editor.selectedDocument.isPlayerDesigner }
    private var selectedDocumentIsTriggerStudio: Bool { editor.selectedDocument.isTriggerStudio }
    private var selectedDocumentIsObstacleStudio: Bool { editor.selectedDocument.isObstacleStudio }
    private var selectedDocumentIsHelpStudio: Bool { editor.selectedDocument.isHelpStudio }

    /// The real room document commands should act on.
    ///
    /// Dynamic Studio is a helper tab, not a playable XML document. If toolbar
    /// actions export/play/delete against that fake tab, Vector 2 receives an
    /// empty `<Root><Track><Content>` room and immediately faceplants.
    private var commandDocumentIndex: Int {
        if selectedDocumentIsDynamicStudio,
           let dynamicStudioTargetDocumentID,
           let index = editor.documents.firstIndex(where: { $0.id == dynamicStudioTargetDocumentID && !$0.isDynamicStudio }) {
            return index
        }
        if selectedDocumentIsAIStudio,
           let aiStudioTargetDocumentID,
           let index = editor.documents.firstIndex(where: { $0.id == aiStudioTargetDocumentID && !$0.isAIStudio && !$0.isDynamicStudio }) {
            return index
        }
        if selectedDocumentIsPlayerDesigner,
           let playerDesignerTargetDocumentID,
           let index = editor.documents.firstIndex(where: { $0.id == playerDesignerTargetDocumentID && !$0.isPlayerDesigner && !$0.isAIStudio && !$0.isDynamicStudio }) {
            return index
        }
        if selectedDocumentIsTriggerStudio,
           let triggerStudioTargetDocumentID,
           let index = editor.documents.firstIndex(where: { $0.id == triggerStudioTargetDocumentID && !$0.isHelperStudio }) {
            return index
        }
        // Obstacle Designer is a real isolated canvas document. Delete, copy,
        // undo and inspector commands must target it—not the first open room.
        if selectedDocumentIsObstacleStudio {
            return editor.selectedDocumentIndex
        }
        if !editor.selectedDocument.isHelperStudio {
            return editor.selectedDocumentIndex
        }
        return editor.documents.firstIndex(where: { !$0.isHelperStudio }) ?? editor.selectedDocumentIndex
    }

    private var commandDocument: LevelDocument {
        editor.documents[commandDocumentIndex]
    }

    /// Chooses which document the right dock edits.
    ///
    /// Normally the dock edits the active tab. If the disabled Dynamic Studio
    /// tab is ever reopened, its inspector should still edit the room document
    /// the studio is animating instead of editing the studio UI tab itself.
    private var activeInspectorDocumentBinding: Binding<LevelDocument> {
        if selectedDocumentIsDynamicStudio { return dynamicStudioTargetDocumentBinding }
        if selectedDocumentIsAIStudio { return aiStudioTargetDocumentBinding }
        if selectedDocumentIsPlayerDesigner { return playerDesignerTargetDocumentBinding }
        if selectedDocumentIsTriggerStudio { return triggerStudioTargetDocumentBinding }
        return selectedDocumentBinding
    }

    /// Binding used by the paused Dynamic Studio path.
    ///
    /// This looks odd because Dynamic Studio is a fake document tab. Keeping the
    /// binding here means future work can re-enable it without changing how the
    /// inspector talks to normal `LevelDocument` models.
    private var dynamicStudioTargetDocumentBinding: Binding<LevelDocument> {
        Binding(
            get: {
                if let dynamicStudioTargetDocumentID,
                   let document = editor.documents.first(where: { $0.id == dynamicStudioTargetDocumentID && !$0.isDynamicStudio }) {
                    return document
                }
                return editor.documents.first(where: { !$0.isDynamicStudio }) ?? editor.selectedDocument
            },
            set: { newDocument in
                guard let index = editor.documents.firstIndex(where: { $0.id == newDocument.id && !$0.isDynamicStudio }) else { return }
                guard editor.documents[index] != newDocument else { return }
                if !isLiveEditing {
                    recordHistorySnapshot()
                }
                editor.documents[index] = newDocument
            }
        )
    }

    private var aiStudioTargetDocumentBinding: Binding<LevelDocument> {
        Binding(
            get: {
                if let aiStudioTargetDocumentID,
                   let document = editor.documents.first(where: { $0.id == aiStudioTargetDocumentID && !$0.isAIStudio && !$0.isDynamicStudio }) {
                    return document
                }
                return editor.documents.first(where: { !$0.isAIStudio && !$0.isDynamicStudio }) ?? editor.selectedDocument
            },
            set: { newDocument in
                guard let index = editor.documents.firstIndex(where: { $0.id == newDocument.id && !$0.isAIStudio && !$0.isDynamicStudio }) else { return }
                guard editor.documents[index] != newDocument else { return }
                if !isLiveEditing { recordHistorySnapshot() }
                editor.documents[index] = newDocument
            }
        )
    }

    private var playerDesignerTargetDocumentBinding: Binding<LevelDocument> {
        Binding(
            get: {
                if let playerDesignerTargetDocumentID,
                   let document = editor.documents.first(where: { $0.id == playerDesignerTargetDocumentID && !$0.isPlayerDesigner && !$0.isAIStudio && !$0.isDynamicStudio }) { return document }
                return editor.documents.first(where: { !$0.isPlayerDesigner && !$0.isAIStudio && !$0.isDynamicStudio }) ?? editor.selectedDocument
            },
            set: { newDocument in
                guard let index = editor.documents.firstIndex(where: { $0.id == newDocument.id && !$0.isPlayerDesigner && !$0.isAIStudio && !$0.isDynamicStudio }) else { return }
                guard editor.documents[index] != newDocument else { return }
                if !isLiveEditing { recordHistorySnapshot() }
                editor.documents[index] = newDocument
            }
        )
    }

    private var triggerStudioTargetDocumentBinding: Binding<LevelDocument> {
        Binding(
            get: {
                if let triggerStudioTargetDocumentID,
                   let document = editor.documents.first(where: { $0.id == triggerStudioTargetDocumentID && !$0.isHelperStudio }) { return document }
                return editor.documents.first(where: { !$0.isHelperStudio }) ?? editor.selectedDocument
            },
            set: { newDocument in
                guard let index = editor.documents.firstIndex(where: { $0.id == newDocument.id && !$0.isHelperStudio }) else { return }
                guard editor.documents[index] != newDocument else { return }
                if !isLiveEditing { recordHistorySnapshot() }
                editor.documents[index] = newDocument
            }
        )
    }

    /// Closes a tab and moves selection to a nearby document. Dynamic Studio is
    /// treated like a document tab but has its own internal source path.
    private func closeDocument(_ documentID: LevelDocument.ID) {
        if editor.documents.first(where: { $0.id == documentID })?.sourcePath == "internal://project-manager" {
            let refreshedCatalog = Vector2AssetCatalog.load(extraAssetFolders: extraAssetFolders)
            for index in editor.documents.indices where editor.documents[index].sourcePath != "internal://project-manager" {
                _ = editor.documents[index].refreshCustomTrapPreviews(using: refreshedCatalog)
            }
            assetCatalog = refreshedCatalog
        }
        if editor.documents.first(where: { $0.id == documentID })?.sourcePath == "internal://zone-background-pool" {
            isBackgroundDesignerPresented = false
        }
        recordHistorySnapshot()
        editor.closeDocument(id: documentID)
        statusMessage = editor.documents.isEmpty ? "Closed document" : "Closed tab"
    }

    /// Central command dispatcher for toolbar/menu actions.
    ///
    /// Routes toolbar buttons through the same document actions.
    private func handleToolbarAction(_ action: ToolbarAction) {
        // A manager tab has no room XML to edit or run. Keep room commands from
        // accidentally exporting its internal document shell.
        if editor.documents.contains(where: { $0.id == editor.selectedDocumentID && $0.sourcePath == "internal://project-manager" }),
           ![ToolbarAction.new, .open, .settings, .refresh, .browser].contains(action) {
            statusMessage = "Use the Project Manager controls, or select a room tab."
            return
        }
        if editor.selectedDocument.sourcePath == "internal://zone-background-pool",
           [.save, .export, .play].contains(action) {
            statusMessage = "Use Background Designer → Save to Zone Pool. This canvas is not a room."
            return
        }
        switch action {
        case .new:
            recordHistorySnapshot()
            editor.createEmptyDocument(for: selectedGame)
            statusMessage = "New blank \(selectedGame.rawValue) document"
        case .open:
            openXML(replacingSelectedDocument: true)
        case .importXML:
            openXML(replacingSelectedDocument: false)
        case .save:
            if commandDocument.structuralRoomKind != nil {
                // The ordinary room Save writes a root-level custom_rooms file.
                // Structural rooms must use their zone's start/finish pool.
                if editor.selectedDocument.id == commandDocument.id {
                    structuralSaveRequest += 1
                } else {
                    statusMessage = "Select the Entrance or Exit Designer tab before saving its zone room."
                }
            } else {
                saveSelectedDocument()
            }
        case .export:
            exportSelectedDocument()
        case .copy:
            recordHistorySnapshot()
            editor.documents[commandDocumentIndex].duplicateSelectedNode()
            statusMessage = "Duplicated selected node"
        case .flipHorizontal:
            flipSelectedNodes(horizontal: true, vertical: false)
        case .flipVertical:
            flipSelectedNodes(horizontal: false, vertical: true)
        case .delete:
            recordHistorySnapshot()
            if editor.documents[commandDocumentIndex].deleteSelectedNode() {
                statusMessage = "Deleted selected node"
            } else {
                _ = undoStack.popLast()
                statusMessage = "Select a scene object before deleting"
            }
        case .play:
            previewCurrentDocument()
        case .trickPreview:
            isTrickPreviewPresented = true
        case .refresh:
            refreshWorkspaceData()
        case .undo:
            performUndo()
        case .redo:
            performRedo()
        case .browser:
            showAssetBrowserWindow()
        case .settings:
            isSettingsPresented = true
        }
    }

    private func flipSelectedNodes(horizontal: Bool, vertical: Bool) {
        recordHistorySnapshot()
        if editor.documents[commandDocumentIndex].flipSelectedNodes(horizontal: horizontal, vertical: vertical) {
            statusMessage = horizontal ? "Flipped selection horizontally" : "Flipped selection vertically"
        } else {
            _ = undoStack.popLast()
            statusMessage = "Select a scene object before flipping"
        }
    }

    private func openDynamicStudio() {
        guard !editor.selectedDocument.isDynamicStudio else {
            statusMessage = "Dynamic Studio already open"
            return
        }
        dynamicStudioTargetDocumentID = editor.selectedDocument.id
        editor.openDynamicStudio()
        statusMessage = "Dynamic Studio opened for \(dynamicStudioTargetDocumentBinding.wrappedValue.name)"
    }

    private func openAIStudio() {
        guard !editor.selectedDocument.isAIStudio else {
            statusMessage = "AI Designer already open"
            return
        }
        let target = commandDocument
        aiStudioTargetDocumentID = target.id
        editor.openAIStudio()
        statusMessage = "AI Designer opened for \(target.name)"
    }

    private func openPlayerDesigner() {
        guard !editor.selectedDocument.isPlayerDesigner else { statusMessage = "Player Designer already open"; return }
        let target = commandDocument
        playerDesignerTargetDocumentID = target.id
        editor.openPlayerDesigner()
        statusMessage = "Player Designer opened for \(target.name)"
    }

    private func openTriggerStudio() {
        guard !editor.selectedDocument.isTriggerStudio else { statusMessage = "Trigger Designer already open"; return }
        let target = commandDocument
        triggerStudioTargetDocumentID = target.id
        editor.openTriggerStudio()
        statusMessage = "Trigger Designer opened for \(target.name)"
    }

    private func openObstacleStudio() {
        editor.openObstacleStudio()
        selectedTool = .cursor
        activePlacementAsset = nil
        statusMessage = "Obstacle Designer ready. Use the tool rail, Browser and Dynamic Studio to build it."
    }

    private func openStructuralRoomStudio(_ kind: StructuralRoomKind) {
        editor.openStructuralRoomStudio(kind)
        selectedTool = .cursor
        activePlacementAsset = nil
        isRoomLayoutsPresented = false
        isTrapPlacementPresented = false
        statusMessage = "\(kind.rawValue) Designer ready. Choose a zone, add artwork, then Save to Zone."
    }

    private func openHelpStudio() {
        editor.openHelpStudio()
        statusMessage = "Help opened"
    }

    /// Handles global keyboard shortcuts after AppKit filters out active text
    /// fields. Copy/paste operate on whole `LevelNode`s, not raw text.
    private func handleKeyCommand(_ command: AppKeyCommand) {
        // Project Manager is an app workspace, not a room document. Global
        // canvas shortcuts used to mutate its placeholder LevelDocument (most
        // visibly through number keys), which could crash the manager view.
        guard !isProjectManagerSelected else { return }
        switch command {
        case .copy:
            copiedNode = commandDocument.selectedNode
            statusMessage = copiedNode.map { "Copied \($0.name)" } ?? "Select something before copying"
        case .paste:
            guard let copiedNode else {
                statusMessage = "Nothing copied yet"
                return
            }
            recordHistorySnapshot()
            editor.documents[commandDocumentIndex].pasteNode(copiedNode)
            statusMessage = "Pasted \(copiedNode.name)"
        case .tool(let tool):
            selectedTool = tool
            activePlacementAsset = nil
            statusMessage = "Tool: \(tool.rawValue)"
        case .parallaxPreview:
            guard !editor.selectedDocument.isHelperStudio,
                  !editor.selectedDocument.isStructuralRoomStudio else { return }
            toggleParallaxPreview()
        }
    }

    private func toggleParallaxPreview() {
        if parallaxPreviewEnabled {
            parallaxPreviewEnabled = false
            statusMessage = "Parallax preview off"
        } else {
            parallaxPreviewStartPan = canvasCamera.panOffset
            parallaxPreviewEnabled = true
            selectedTool = .cursor
            activePlacementAsset = nil
            statusMessage = "Parallax preview on — pan the canvas to see background depth. Press I to exit."
        }
    }

    /// Called when a drag/resize/rotate starts. We snapshot once at the start so
    /// undo jumps back to the pre-drag state instead of crawling pixel by pixel.
    private func beginLiveEdit() {
        guard !isLiveEditing else { return }
        recordHistorySnapshot()
        isLiveEditing = true
    }

    /// Ends a live canvas edit. The actual document is already mutated during
    /// the drag; this just re-enables normal history behavior.
    private func endLiveEdit() {
        isLiveEditing = false
    }

    /// Pushes the current session to undo and clears redo.
    ///
    /// The guard flags matter: without them, restoring undo would itself create
    /// a new undo entry and the stack would feel haunted.
    private func recordHistorySnapshot() {
        guard !isRestoringHistory else { return }
        undoStack.append(editor)
        if undoStack.count > 60 {
            undoStack.removeFirst(undoStack.count - 60)
        }
        redoStack.removeAll()
    }

    private var extraAssetFolders: [String] {
        extraAssetFoldersData
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    /// Recent XML paths, stored as newline-separated text in AppStorage.
    private var recentXMLPaths: [String] {
        recentXMLPathsData
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.isEmpty && FileManager.default.fileExists(atPath: $0) }
    }

    private func showAssetBrowserWindow() {
        let refreshedCatalog = Vector2AssetCatalog.load(extraAssetFolders: extraAssetFolders)
        assetCatalog = refreshedCatalog
        AssetBrowserWindowController.show(catalog: refreshedCatalog) { asset in
            // Camera-related assets should put the user into the camera tool so
            // the left rail matches what they selected from search results.
            if editor.selectedDocument.sourcePath == "internal://zone-background-pool" {
                guard asset.kind == .texture else {
                    statusMessage = "Pick a texture for the zone background canvas."
                    return
                }
                activePlacementAsset = asset
                selectedTool = .backgrounds
                statusMessage = "Click once to place \(asset.name), then drag or resize it with Select."
                return
            }
            activePlacementAsset = asset
            selectedTool = asset.isCameraRelated ? .camera : (asset.kind == .texture ? .images : .objectRef)
            statusMessage = "Selected \(asset.name). Click the canvas to place it."
        }
    }

    private func openZoneBackgroundDesigner() {
        guard Vector2AssetCatalog.activeProjectRootURL() != nil else {
            statusMessage = "Open a project before designing its zone background pool."
            return
        }
        if let existing = editor.documents.first(where: { $0.sourcePath == "internal://zone-background-pool" }) {
            // Re-entering from Project Manager starts a new composition. To edit
            // a saved set, use Load on Canvas instead of inheriting old nodes.
            recordHistorySnapshot()
            if let index = editor.documents.firstIndex(where: { $0.id == existing.id }) {
                let fresh = LevelDocument.zoneBackgroundCanvas()
                editor.documents[index] = fresh
                editor.selectedDocumentID = fresh.id
            }
        } else {
            editor.appendDocument(LevelDocument.zoneBackgroundCanvas())
        }
        UserDefaults.standard.removeObject(forKey: "vector2ZonePoolDraftName")
        selectedTool = .cursor
        activePlacementAsset = nil
        isBackgroundDesignerPresented = true
        statusMessage = "Zone background canvas ready. Place artwork, then save it to a zone pool."
    }

    private func placeProjectBackground(_ file: URL) {
        guard let project = Vector2AssetCatalog.activeProjectRootURL(),
              file.deletingLastPathComponent().standardizedFileURL == project.appendingPathComponent("custom_backgrounds_pool").standardizedFileURL,
              let definition = CustomBackgroundStore.loadPool(from: file.deletingLastPathComponent())
                .first(where: { $0.name == file.deletingPathExtension().lastPathComponent }) else {
            statusMessage = "That saved background is no longer in this project."
            return
        }
        placeBackground(definition, from: project)
    }

    private func placeSceneBackground(_ name: String) {
        guard let project = Vector2AssetCatalog.activeProjectRootURL(),
              let definition = CustomBackgroundStore.load(from: project.appendingPathComponent("custom_backgrounds"))
                .first(where: { $0.name == name }) else {
            statusMessage = "That room background is no longer in this project."
            return
        }
        placeBackground(definition, from: project)
    }

    private func placeBackground(_ definition: CustomBackgroundDefinition, from project: URL) {
        let roomIndex = lastRoomDocumentID.flatMap { id in editor.documents.firstIndex(where: { $0.id == id }) }
            ?? editor.documents.indices.last(where: { editor.documents[$0].sourcePath?.hasPrefix("internal://") != true })
        guard let roomIndex else {
            statusMessage = "Open a room tab first, then place the background from Project Manager."
            return
        }
        let textures = project.appendingPathComponent("custom_textures", isDirectory: true)
        let textureFiles = ((FileManager.default.enumerator(at: textures, includingPropertiesForKeys: nil,
                                                          options: [.skipsHiddenFiles])?.allObjects as? [URL]) ?? [])
            .filter { ["png", "jpg", "jpeg", "gif"].contains($0.pathExtension.lowercased()) }
        var imagePaths: [String: String] = [:]
        for texture in textureFiles {
            imagePaths[texture.lastPathComponent.lowercased()] = texture.path
            imagePaths[texture.deletingPathExtension().lastPathComponent.lowercased()] = texture.path
        }
        let nodes: [LevelNode] = definition.pieces.compactMap { piece in
            guard var node = XMLSceneParser.parseNodeXML(piece, baseURL: textures) else { return nil }
            node.metadata.tag = "Background"
            if !node.metadata.sortingLayer.hasPrefix("Bg") { node.metadata.sortingLayer = "BgMiddle" }
            if let xml = try? XMLDocument(xmlString: piece),
               let angle = Double(xml.rootElement()?.attribute(forName: "EditorRotation")?.stringValue ?? "") {
                node.transform?.rotation = angle
            }
            if node.metadata.imagePath.isEmpty {
                let key = node.metadata.className.lowercased()
                node.metadata.imagePath = imagePaths[key] ?? imagePaths[key + ".png"] ?? imagePaths[key + ".jpg"] ?? ""
            }
            return node
        }
        guard !nodes.isEmpty else { statusMessage = "This background has no readable artwork to place."; return }
        recordHistorySnapshot()
        var room = editor.documents[roomIndex]
        let placed = nodes.filter { room.root.appendToFirstFactor($0) }.map(\.id)
        guard !placed.isEmpty else { statusMessage = "Couldn’t place this background in the room."; return }
        room.customBackgroundName = definition.name
        room.hasCustomBackgroundAssignment = true
        room.setSelected(ids: placed)
        editor.documents[roomIndex] = room
        editor.selectedDocumentID = room.id
        statusMessage = "Placed \(definition.name) in \(room.name). Save the room to keep this background."
    }

    private func installZoneBackgroundPool() {
        guard let project = Vector2AssetCatalog.activeProjectRootURL(),
              let projectXML = try? XMLDocument(contentsOf: project.appendingPathComponent("project.xml")),
              let path = projectXML.rootElement()?.attribute(forName: "GameDataPath")?.stringValue,
              !path.isEmpty else {
            statusMessage = "Connect Vector 2 Data in Project Manager first."
            return
        }
        let poolFolder = project.appendingPathComponent("custom_backgrounds_pool", isDirectory: true)
        do { try CustomBackgroundStore.migrateLegacyPool(in: poolFolder) }
        catch { statusMessage = "Couldn’t migrate the old zone pool: \(error.localizedDescription)"; return }
        let poolFiles = ((try? FileManager.default.contentsOfDirectory(at: poolFolder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "xml" && $0.lastPathComponent.lowercased() != "custom_backgrounds.xml" }
        guard !poolFiles.isEmpty else {
            statusMessage = "Save a zone background before installing it."
            return
        }
        do {
            let textures = project.appendingPathComponent("custom_textures", isDirectory: true)
            if let files = try? FileManager.default.contentsOfDirectory(at: textures, includingPropertiesForKeys: nil) {
                for gif in files where gif.pathExtension.lowercased() == "gif" {
                    _ = try CustomGIFFrames.compile(source: gif, into: textures,
                                                    name: "gif_\(gif.deletingPathExtension().lastPathComponent)")
                }
            }
            let gameRoot = try authorizedGameDataRoot(preferred: URL(fileURLWithPath: path, isDirectory: true))
            guard gameRoot.standardizedFileURL.path == URL(fileURLWithPath: path).standardizedFileURL.path,
                  ["userdata", "custom_rooms", "gamedata"].contains(where: {
                      FileManager.default.fileExists(atPath: gameRoot.appendingPathComponent($0).path)
                  }) else {
                statusMessage = "Choose the Vector 2 Data folder connected to this project."
                return
            }
            try withSecurityScopedAccess(to: gameRoot) {
                let destinationPool = gameRoot.appendingPathComponent("custom_backgrounds_pool", isDirectory: true)
                try FileManager.default.createDirectory(at: destinationPool, withIntermediateDirectories: true)
                let projectID = projectXML.rootElement()?.attribute(forName: "ProjectID")?.stringValue ?? ""
                guard !projectID.isEmpty, !projectID.contains("/"), !projectID.contains("\\") else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                let receiptFolder = gameRoot.appendingPathComponent(".vector2-installed-projects", isDirectory: true)
                try FileManager.default.createDirectory(at: receiptFolder, withIntermediateDirectories: true)
                let receipt = receiptFolder.appendingPathComponent(projectID + "-background-pool.json")
                let previous = Set((try? JSONDecoder().decode([String].self, from: Data(contentsOf: receipt))) ?? [])
                let current = Set(poolFiles.map(\.lastPathComponent))
                for source in poolFiles {
                    guard let xml = try? XMLDocument(contentsOf: source), xml.rootElement()?.name == "Background" else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    try CustomBackgroundStore.normalizedPoolCatalogData(from: source)
                        .write(to: destinationPool.appendingPathComponent(source.lastPathComponent), options: .atomic)
                }
                for stale in previous.subtracting(current)
                    where (stale as NSString).pathExtension.lowercased() == "xml"
                        && stale == URL(fileURLWithPath: stale).lastPathComponent
                        && stale.lowercased() != "custom_backgrounds.xml" {
                    let installed = destinationPool.appendingPathComponent(stale)
                    if FileManager.default.fileExists(atPath: installed.path) { try FileManager.default.removeItem(at: installed) }
                }
                try JSONEncoder().encode(current.sorted()).write(to: receipt, options: .atomic)
                // Pool artwork may use imported textures, so carry those alongside the catalog.
                if let enumerator = FileManager.default.enumerator(at: textures, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
                    for case let source as URL in enumerator {
                        guard (try? source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                        let relative = String(source.path.dropFirst(textures.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                        guard !relative.isEmpty else { continue }
                        try replaceFile(source, at: gameRoot.appendingPathComponent("custom_textures/").appendingPathComponent(relative))
                    }
                }
            }
            statusMessage = "Zone backgrounds and project textures installed to Vector 2."
        } catch {
            statusMessage = "Couldn’t install zone backgrounds: \(error.localizedDescription)"
        }
    }

    /// Opens XML from disk through the selected import pipeline and adds it as a
    /// tab, or replaces the current tab when requested by the empty workspace.
    private func openXML(replacingSelectedDocument: Bool) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.xml]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let document = loadXMLDocument(at: url, promptRoomWeaverChoices: true) else {
            statusMessage = "Couldn’t load \(url.lastPathComponent)"
            return
        }
        rememberRecentXML(url.path)

        if replacingSelectedDocument {
            recordHistorySnapshot()
            editor.replaceSelectedDocument(with: document)
            statusMessage = "Opened \(document.name)"
        } else {
            recordHistorySnapshot()
            editor.appendDocument(document)
            statusMessage = "Imported \(document.name)"
        }
    }

    private func openRecentXML(at path: String) {
        let url = URL(fileURLWithPath: path)
        guard let document = loadXMLDocument(at: url, promptRoomWeaverChoices: true) else {
            statusMessage = "Couldn’t load \(URL(fileURLWithPath: path).lastPathComponent)"
            return
        }
        rememberRecentXML(path)
        recordHistorySnapshot()
        editor.appendDocument(document)
        statusMessage = "Opened recent \(document.name)"
    }

    private func loadXMLDocument(at url: URL, promptRoomWeaverChoices: Bool) -> LevelDocument? {
        // Stock rooms are useful to inspect one generated branch at a time. A
        // room created by this editor must reopen with every layout present or
        // saving it again would throw the unselected variants away.
        if let xml = try? XMLDocument(contentsOf: url, options: []),
           xml.rootElement()?.attribute(forName: "EditorRoomLayouts")?.stringValue == "1" {
            return LevelDocument.loadFromXML(at: url.path)
        }
        let pipeline = Vector2ImportPipeline(rawValue: vector2ImportPipeline) ?? .roomWeaver
        guard pipeline == .roomWeaver,
              RoomWeaverImporter.canImportRoom(at: url.path) else {
            return LevelDocument.loadFromXML(at: url.path)
        }

        let selectedVariants: [String: String]
        if promptRoomWeaverChoices {
            guard let variants = chooseRoomWeaverVariants(for: url) else {
                return nil
            }
            selectedVariants = variants
        } else {
            selectedVariants = [:]
        }
        return RoomWeaverImporter.parseDocument(at: url.path, selectedVariants: selectedVariants)
    }

    private func chooseRoomWeaverVariants(for url: URL) -> [String: String]? {
        let options = RoomWeaverImporter.choiceOptions(at: url.path)
        guard !options.isEmpty else {
            return [:]
        }

        let alert = NSAlert()
        alert.messageText = "RoomWeaver variants"
        alert.informativeText = "Pick the room variants to import. These are the same generator branches Vector 2 chooses before it builds the room."
        alert.addButton(withTitle: "Import")
        alert.addButton(withTitle: "Cancel")

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        var popups: [String: NSPopUpButton] = [:]
        for option in options {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 10
            row.translatesAutoresizingMaskIntoConstraints = false

            let labelStack = NSStackView()
            labelStack.orientation = .vertical
            labelStack.alignment = .leading
            labelStack.spacing = 2
            labelStack.translatesAutoresizingMaskIntoConstraints = false
            labelStack.widthAnchor.constraint(equalToConstant: 240).isActive = true

            let label = NSTextField(labelWithString: option.name)
            label.font = .systemFont(ofSize: 12, weight: .semibold)
            label.lineBreakMode = .byTruncatingMiddle

            let explanation = NSTextField(wrappingLabelWithString: option.description)
            explanation.font = .systemFont(ofSize: 10)
            explanation.textColor = .secondaryLabelColor
            explanation.maximumNumberOfLines = 3

            labelStack.addArrangedSubview(label)
            labelStack.addArrangedSubview(explanation)

            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            popup.addItems(withTitles: option.variants)
            popup.widthAnchor.constraint(equalToConstant: 260).isActive = true
            popups[option.id] = popup

            row.addArrangedSubview(labelStack)
            row.addArrangedSubview(popup)
            stack.addArrangedSubview(row)
        }

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 540, height: min(460, max(160, options.count * 58))))
        scrollView.hasVerticalScroller = options.count > 7
        scrollView.borderType = .bezelBorder
        scrollView.documentView = stack
        NSLayoutConstraint.activate([
            stack.widthAnchor.constraint(equalToConstant: 520)
        ])
        alert.accessoryView = scrollView

        guard alert.runModal() == .alertFirstButtonReturn else {
            return nil
        }

        return Dictionary(uniqueKeysWithValues: options.compactMap { option in
            guard let value = popups[option.id]?.titleOfSelectedItem else { return nil }
            return (option.id, value)
        })
    }

    private func rememberRecentXML(_ path: String) {
        // Newest first, unique, capped so the File menu stays usable.
        var updated = recentXMLPaths.filter { $0 != path }
        updated.insert(path, at: 0)
        recentXMLPathsData = Array(updated.prefix(8)).joined(separator: "\n")
    }

    /// Saves back to the opened XML path when possible; otherwise falls back to
    /// Save As so new documents still get a real file path.
    private func saveSelectedDocument() {
        let index = commandDocumentIndex
        guard let sourcePath = editor.documents[index].sourcePath, !sourcePath.isEmpty else {
            exportSelectedDocument()
            return
        }

        do {
            let url = URL(fileURLWithPath: sourcePath)
            let xml = editor.documents[index].exportedXML()
            try xml.write(to: url, atomically: true, encoding: .utf8)
            try installCustomTrapDependencies(referencedBy: xml, alongside: url)
            statusMessage = "Saved \(url.lastPathComponent)"
        } catch {
            statusMessage = "Save failed: \(error.localizedDescription)"
        }
    }

    /// Exports the current document using the bottom exporter helpers.
    ///
    /// If the document came from a path we default to that filename; new tabs use
    /// the document title so preview/export no longer silently says untitled.
    private func exportSelectedDocument() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.xml]
        let index = commandDocumentIndex
        panel.nameFieldStringValue = editor.documents[index].name

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let xml = editor.documents[index].exportedXML()
            try xml.write(to: url, atomically: true, encoding: .utf8)
            try installCustomTrapDependencies(referencedBy: xml, alongside: url)
            editor.documents[index].name = url.lastPathComponent
            editor.documents[index].sourcePath = url.path
            editor.documents[index].root.name = url.lastPathComponent
            statusMessage = "Exported \(url.lastPathComponent)"
        } catch {
            statusMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    private func refreshWorkspaceData() {
        // Refresh both asset metadata and the current source-backed document.
        // This is useful after copying texture/library files into the project.
        assetCatalog = Vector2AssetCatalog.load(extraAssetFolders: extraAssetFolders)
        if let refreshed = editor.selectedDocument.reloadedFromSource() {
            recordHistorySnapshot()
            editor.replaceSelectedDocument(with: refreshed)
            statusMessage = "Reloaded \(refreshed.name) and refreshed assets"
        } else {
            statusMessage = "Asset browser refreshed"
        }
    }

    private func performUndo() {
        // Snapshot undo: replace the whole session with the previous copy.
        // `isRestoringHistory` prevents this assignment from recording itself.
        guard let previous = undoStack.popLast() else { return }
        isRestoringHistory = true
        redoStack.append(editor)
        editor = previous
        isRestoringHistory = false
        statusMessage = "Undo"
    }

    private func performRedo() {
        // Restore the saved editor state, just like undo, rather than replaying node edits.
        guard let next = redoStack.popLast() else { return }
        isRestoringHistory = true
        undoStack.append(editor)
        editor = next
        isRestoringHistory = false
        statusMessage = "Redo"
    }

    /// "Play" button behavior.
    ///
    /// This writes a temporary custom room XML, then either pings an already
    /// running Vector 2 build over the localhost console bridge or launches the
    /// selected app so it consumes the same request on startup.
    private func previewCurrentDocument() {
        let validationIssues = commandDocument.aiValidationIssues + commandDocument.trapValidationIssues
        guard validationIssues.isEmpty else {
            statusMessage = "Play blocked: \(validationIssues.joined(separator: "; "))"
            return
        }
        let roomName = playableRoomName(for: commandDocument)
        do {
            let customRoomURL = try writePreviewRoom(named: roomName)
            if let launchURL = launchableVector2URL() {
                launchVector2(at: launchURL, roomName: roomName, exportedFileName: customRoomURL.lastPathComponent)
            } else {
                NSWorkspace.shared.open(customRoomURL)
                statusMessage = "No Vector 2 game directory set, opened exported XML"
            }
        } catch {
            statusMessage = "Preview failed: \(error.localizedDescription)"
        }
    }

    /// Writes the active document into Vector 2's `custom_rooms` folder.
    ///
    /// The extra `editor_launch_room.txt` marker is the dumb-but-effective
    /// handshake for startup: if the game is not running yet, it can read this
    /// file after boot and immediately load the exported room.
    private func writePreviewRoom(named roomName: String) throws -> URL {
        // Play uses the exact same room XML as Save/Export.  The former
        // vector_editor_preview rewrite stripped selections and injected helper
        // nodes, which meant Play was no longer testing the level the editor
        // actually authored.
        let xml = commandDocument.exportedXML()
        let preferredFolder = vector2CustomRoomsURL()
        let gameRoot = try authorizedGameDataRoot(preferred: preferredFolder.deletingLastPathComponent())
        let folderURL = gameRoot.appendingPathComponent("custom_rooms", isDirectory: true)
        let roomURL = folderURL.appendingPathComponent("\(roomName).xml")
        let launchMarkerURL = folderURL.appendingPathComponent("editor_launch_room.txt")
        try withSecurityScopedAccess(to: gameRoot) {
            try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
            // Resolve/copy dependencies first. A failed trap install must not
            // leave a room in one data root and a launch marker in another.
            try installCustomTrapDependencies(referencedBy: xml, alongside: roomURL)
            try xml.write(to: roomURL, atomically: true, encoding: .utf8)
            try roomName.write(to: launchMarkerURL, atomically: true, encoding: .utf8)
        }
        return roomURL
    }

    /// A room containing v2trap references is not portable by itself. Whenever
    /// Save/Export/Play targets Vector's custom_rooms folder, carry only the
    /// referenced generated libraries and artwork into the sibling game folders.
    private func installCustomTrapDependencies(referencedBy xml: String, alongside roomURL: URL) throws {
        let customRooms = roomURL.deletingLastPathComponent()
        guard customRooms.lastPathComponent == "custom_rooms" else { return }
        guard let document = try? XMLDocument(xmlString: xml),
              let references = try? document.nodes(forXPath: "//ObjectReference[starts-with(@Filename, 'v2trap_')]") else { return }

        let filenames = Set(references.compactMap { ($0 as? XMLElement)?.attribute(forName: "Filename")?.stringValue })
        guard !filenames.isEmpty else { return }
        guard let project = Vector2AssetCatalog.activeProjectRootURL() else {
            throw CustomTrapDependencyError.noActiveProject
        }
        let gameRoot = try authorizedGameDataRoot(preferred: customRooms.deletingLastPathComponent())
        let destinationLibraries = gameRoot
            .appendingPathComponent("custom_gamedata", isDirectory: true)
            .appendingPathComponent("run_data", isDirectory: true)
            .appendingPathComponent("libraries", isDirectory: true)
        let destinationTextures = gameRoot.appendingPathComponent("custom_textures", isDirectory: true)
        let destinationTraps = gameRoot.appendingPathComponent("custom_traps", isDirectory: true)
        let gameAccess = gameRoot.startAccessingSecurityScopedResource()
        defer { if gameAccess { gameRoot.stopAccessingSecurityScopedResource() } }
        try FileManager.default.createDirectory(at: destinationLibraries, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationTextures, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationTraps, withIntermediateDirectories: true)

        let sourceLibraries = project
            .appendingPathComponent("custom_gamedata", isDirectory: true)
            .appendingPathComponent("run_data", isDirectory: true)
            .appendingPathComponent("libraries", isDirectory: true)
        let sourceTextures = project.appendingPathComponent("custom_textures", isDirectory: true)
        let textureFiles = (try? FileManager.default.contentsOfDirectory(at: sourceTextures, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []

        for filename in filenames {
            let sourceLibrary = sourceLibraries.appendingPathComponent(filename)
            guard FileManager.default.fileExists(atPath: sourceLibrary.path) else {
                throw CustomTrapDependencyError.missingLibrary(filename)
            }
            try replaceFile(sourceLibrary, at: destinationLibraries.appendingPathComponent(filename))

            // Animated traps need their frame manifest and generated PNG
            // sequence as well as the compiled object library.
            let cleanID = filename
                .replacingOccurrences(of: "v2trap_", with: "")
                .replacingOccurrences(of: ".xml", with: "")
            let sourcePackage = project.appendingPathComponent("custom_traps", isDirectory: true).appendingPathComponent(cleanID, isDirectory: true)
            let destinationPackage = destinationTraps.appendingPathComponent(cleanID, isDirectory: true)
            if FileManager.default.fileExists(atPath: sourcePackage.path) {
                if FileManager.default.fileExists(atPath: destinationPackage.path) { try FileManager.default.removeItem(at: destinationPackage) }
                try FileManager.default.copyItem(at: sourcePackage, to: destinationPackage)
            }
            let sourceFrames = sourceTextures.appendingPathComponent("v2trap_\(cleanID)", isDirectory: true)
            let destinationFrames = destinationTextures.appendingPathComponent("v2trap_\(cleanID)", isDirectory: true)
            if FileManager.default.fileExists(atPath: sourceFrames.path) {
                if FileManager.default.fileExists(atPath: destinationFrames.path) { try FileManager.default.removeItem(at: destinationFrames) }
                try FileManager.default.copyItem(at: sourceFrames, to: destinationFrames)
            }

            guard let library = try? XMLDocument(contentsOf: sourceLibrary),
                  let images = try? library.nodes(forXPath: "//Image[@ClassName]") else { continue }
            let classNames = Set(images.compactMap { ($0 as? XMLElement)?.attribute(forName: "ClassName")?.stringValue })
            for className in classNames {
                if let texture = textureFiles.first(where: {
                    $0.deletingPathExtension().lastPathComponent.caseInsensitiveCompare(className) == .orderedSame
                }) {
                    try replaceFile(texture, at: destinationTextures.appendingPathComponent(texture.lastPathComponent))
                }
            }
        }
    }

    private func replaceFile(_ source: URL, at destination: URL) throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)
    }

    /// Sends a load command to a game that is already open.
    ///
    /// The game-side CUDLR/local console server is deliberately localhost-only.
    /// This should stay cross-platform: Windows can hit `127.0.0.1` the same way
    /// macOS does, only the app launch path differs.
    private func nudgeRunningVector2ToPlay(roomName: String) {
        let commands: [(delay: Double, command: String)] = [
            // The editor writes editor_launch_room.txt, then tells the live game
            // to consume it. A second ping covers the short scene-transition
            // window where CUDLR is alive but the command database is rebuilding.
            (0.2, "editorplay"),
            (0.9, "editorplay")
        ]

        for item in commands {
            DispatchQueue.main.asyncAfter(deadline: .now() + item.delay) {
                self.sendVector2ConsoleCommand(item.command)
            }
        }
    }

    private func nudgeStartingVector2ToPlay(roomName: String) {
        // Cold launch relies on editor_launch_room.txt. Re-sending editorplay
        // several seconds later can reload the preview while the player is already
        // running the room, which feels like a freeze.
        statusMessage = "Exported \(roomName).xml; Vector 2 will load it on startup"
    }

    private func launchVector2(at launchURL: URL, roomName: String, exportedFileName: String) {
        let didStartAccess = launchURL.startAccessingSecurityScopedResource()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let bundleID = Bundle(url: launchURL)?.bundleIdentifier
        let wasAlreadyRunning = bundleID.map {
            !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty
        } ?? false

        statusMessage = "Exported \(exportedFileName), launching Vector 2..."
        NSWorkspace.shared.openApplication(at: launchURL, configuration: configuration) { _, error in
            DispatchQueue.main.async {
                if let error {
                    self.statusMessage = "Preview launch failed: \(error.localizedDescription)"
                } else {
                    if wasAlreadyRunning {
                        self.nudgeRunningVector2ToPlay(roomName: roomName)
                    } else {
                        self.nudgeStartingVector2ToPlay(roomName: roomName)
                    }
                    self.statusMessage = "Exported \(exportedFileName) and queued it for Vector 2"
                }
                if didStartAccess {
                    launchURL.stopAccessingSecurityScopedResource()
                }
            }
        }
    }

    /// Fire-and-forget HTTP console command sender.
    ///
    /// We try both known ports because older CUDLR builds and the fallback
    /// bridge have used different loopback ports during development.
    private func sendVector2ConsoleCommand(_ command: String) {
        guard let encoded = command.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return
        }

        // CUDLR in the Vector 2 mod starts on 44444. Keep 55055 as a harmless
        // fallback for older local builds that used the previous editor probe.
        for port in [44444, 55055] {
            guard let url = URL(string: "http://127.0.0.1:\(port)/console/run?command=\(encoded)") else {
                continue
            }
            var request = URLRequest(url: url)
            request.timeoutInterval = 1.25
            URLSession.shared.dataTask(with: request).resume()
        }
    }

    private func vector2CustomRoomsURL() -> URL {
        if !vector2CustomRoomsDirectory.isEmpty {
            return securityScopedURL(
                path: vector2CustomRoomsDirectory,
                bookmark: vector2CustomRoomsDirectoryBookmark,
                isDirectory: true
            )
        }
        return Self.defaultVector2CustomRoomsURL()
    }

    /// Resolves a persisted root bookmark or asks once for the data folder.
    /// Access to only `custom_rooms` is insufficient because traps also install
    /// libraries and textures into sibling folders.
    private func authorizedGameDataRoot(preferred: URL) throws -> URL {
        if !vector2GameDataDirectoryBookmark.isEmpty,
           let data = Data(base64Encoded: vector2GameDataDirectoryBookmark) {
            var stale = false
            if let resolved = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale), !stale {
                return resolved
            }
        }
        if let data = UserDefaults.standard.data(forKey: "projectManager.gameDataBookmark") {
            var stale = false
            if let resolved = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale), !stale {
                rememberGameDataRoot(resolved)
                return resolved
            }
        }

        let panel = NSOpenPanel()
        panel.title = "Allow Vector 2 Data Access"
        panel.message = "Choose your Vector 2 Data folder. Access is granted to this entire folder so every current and future custom-content folder can be installed together."
        panel.prompt = "Allow Export"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = preferred
        guard panel.runModal() == .OK, let selected = panel.url else {
            throw CustomTrapDependencyError.gameDataPermissionRequired
        }
        let root = selected.lastPathComponent == "custom_rooms" ? selected.deletingLastPathComponent() : selected
        rememberGameDataRoot(root)
        return root
    }

    private func rememberGameDataRoot(_ root: URL) {
        vector2GameDataDirectory = root.path
        let rooms = root.appendingPathComponent("custom_rooms", isDirectory: true)
        vector2CustomRoomsDirectory = rooms.path
        if let data = try? root.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            vector2GameDataDirectoryBookmark = data.base64EncodedString()
        }
        if let data = try? rooms.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            vector2CustomRoomsDirectoryBookmark = data.base64EncodedString()
        }
    }

    /// Repairs stale standalone-editor paths from the active project's single
    /// authoritative Vector 2 Data selection. This also replaces stale
    /// standalone-editor destinations.
    private func adoptProjectManagerGameDataDestination() {
        guard let project = Vector2AssetCatalog.activeProjectRootURL(),
              let document = try? XMLDocument(contentsOf: project.appendingPathComponent("project.xml")),
              let path = document.rootElement()?.attribute(forName: "GameDataPath")?.stringValue,
              !path.isEmpty else { return }

        var dataURL = URL(fileURLWithPath: path, isDirectory: true)
        if let bookmark = UserDefaults.standard.data(forKey: "projectManager.gameDataBookmark") {
            var stale = false
            if let resolved = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale),
               !stale, resolved.standardizedFileURL.path == dataURL.standardizedFileURL.path {
                dataURL = resolved
            }
        }

        let didStart = dataURL.startAccessingSecurityScopedResource()
        defer { if didStart { dataURL.stopAccessingSecurityScopedResource() } }
        let rooms = dataURL.appendingPathComponent("custom_rooms", isDirectory: true)
        try? FileManager.default.createDirectory(at: rooms, withIntermediateDirectories: true)
        vector2CustomRoomsDirectory = rooms.path
        vector2GameDataDirectory = dataURL.path
        if let bookmark = try? dataURL.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            vector2GameDataDirectoryBookmark = bookmark.base64EncodedString()
        }
        if let bookmark = try? rooms.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            vector2CustomRoomsDirectoryBookmark = bookmark.base64EncodedString()
        }
    }

    private static func defaultVector2CustomRoomsURL() -> URL {
        defaultVector2CustomRoomsURLs()[0]
    }

    private static func defaultVector2CustomRoomsURLs() -> [URL] {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return [support
            .appendingPathComponent("Nekki", isDirectory: true)
            .appendingPathComponent("Vector 2", isDirectory: true)
            .appendingPathComponent("custom_rooms", isDirectory: true)]
    }

    private func playableRoomName(for document: LevelDocument) -> String {
        let base = URL(fileURLWithPath: document.sourcePath ?? document.name)
            .deletingPathExtension()
            .lastPathComponent
        // The game resolves baked rooms before custom rooms. Testing an edited
        // room201 as room201 would silently load Nekki's baked copy, so imported
        // documents get a unique ordinary custom-room filename for Play.
        let isImportedRoom = document.sourcePath != nil
            && document.sourcePath != LevelDocument.dynamicStudioSourcePath
            && !base.lowercased().hasPrefix("untitled")
        let rawName = base.isEmpty ? "untitled_1" : (isImportedRoom ? "\(base)_editor" : base)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        let cleaned = rawName.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        return String(cleaned).trimmingCharacters(in: CharacterSet(charactersIn: "_")).isEmpty
            ? "untitled_1"
            : String(cleaned)
    }

    /// Resolves the selected Vector 2 game/app path.
    ///
    /// macOS users may select either the `.app` itself or a folder containing it.
    /// Windows should replace this with an `.exe` resolver, but keep the same
    /// idea: user-selected path first, no hardcoded developer machine paths.
    private func launchableVector2URL() -> URL? {
        guard !vector2GameDirectory.isEmpty else { return nil }
        let root = securityScopedURL(
            path: vector2GameDirectory,
            bookmark: vector2GameDirectoryBookmark,
            isDirectory: true
        )
        if root.pathExtension == "app" {
            return root
        }

        guard let children = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        return children.first { $0.pathExtension == "app" }
    }

    /// macOS sandbox bookmark resolver.
    ///
    /// Restores access to a user-selected folder from its saved sandbox bookmark.
    private func securityScopedURL(path: String, bookmark: String, isDirectory: Bool) -> URL {
        guard let data = Data(base64Encoded: bookmark) else {
            return URL(fileURLWithPath: path, isDirectory: isDirectory)
        }

        var stale = false
        if let resolved = try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ), !stale {
            return resolved
        }

        return URL(fileURLWithPath: path, isDirectory: isDirectory)
    }

    /// Runs file work with sandbox access when macOS requires it.
    /// On Windows this becomes a normal file operation wrapper.
    private func withSecurityScopedAccess<T>(to url: URL, _ body: () throws -> T) throws -> T {
        let didStartAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return try body()
    }
}
