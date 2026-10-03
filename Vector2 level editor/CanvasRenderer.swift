//
//  CanvasRenderer.swift
//  Vector2 level editor
//
//  The actual editor canvas.
//
//  This owns drawing, hit testing, selection boxes, resize/rotation handles,
//  panning, zooming, V-snap, and the AppKit input bridge SwiftUI cannot give us
//  cleanly. AppKit handles mouse and keyboard events for the canvas.
//

import SwiftUI
import AppKit
import Foundation

// This file owns scene composition and coordinate math. The reusable drawing
// pieces and the slightly cursed-but-important AppKit event bridge were moved
// to CanvasSupportViews.swift so you can work here without scrolling forever.
import Observation

/// Reference-backed camera state keeps rapid pan/zoom mutations local to the
/// canvas and ruler views. The editor shell can pass this object around without
/// observing its individual fields, so the hierarchy and inspector do not get
/// invalidated for every camera event.
@Observable
final class CanvasCameraState {
    var panOffset: CGSize = .zero
    var zoom: CGFloat = 1
}


struct CanvasArea: View {
    @Binding var selectedTool: EditorTool
    let activePlacementAsset: TextureAsset?
    let fallbackPlacementAsset: TextureAsset?
    @Bindable var camera: CanvasCameraState
    let onDeleteSelection: () -> Void
    let onLiveEditBegan: () -> Void
    let onLiveEditEnded: () -> Void
    var parallaxPreviewEnabled = false
    var parallaxPreviewStartPan: CGSize = .zero
    var onToggleParallaxPreview: (() -> Void)? = nil
    var onPlaceAsset: (() -> Void)? = nil
    @Binding var document: LevelDocument
    @Binding var trickPreviewPlayback: TrickPreviewPlayback?
    var dynamicOnionTransforms: [LevelNode.Transform] = []
    var dynamicLivePreviewTransforms: [LevelNode.ID: LevelNode.Transform] = [:]
    var showRoomLayoutGuides = false
    var showTrapGuides = false
    var allowsBlankCanvasDeselection = true
    @AppStorage("vector2.snapToGrid") private var snapToGrid = false
    @State private var dragOriginTransform: LevelNode.Transform?
    @State private var dragOriginPrimaryID: LevelNode.ID?
    @State private var dragGestureStartLocation: CGPoint?
    @State private var dragOriginTransforms: [LevelNode.ID: LevelNode.Transform] = [:]
    @State private var dragPreviewOriginTransforms: [LevelNode.ID: LevelNode.Transform] = [:]
    @State private var dragPreviewTransforms: [LevelNode.ID: LevelNode.Transform] = [:]
    @State private var dragPreviewMovedIDs: Set<LevelNode.ID> = []
    @State private var dragPreviewDeltaX: Int = 0
    @State private var dragPreviewDeltaY: Int = 0
    @State private var activeResizeHandle: CanvasHandle?
    @State private var activeResizeNodeID: LevelNode.ID?
    @State private var resizeOriginTransform: LevelNode.Transform?
    @State private var resizePreviewTransform: LevelNode.Transform?
    @State private var isRotatingSelection = false
    @State private var rotationOriginTransforms: [LevelNode.ID: LevelNode.Transform] = [:]
    @State private var rotationPreviewTransforms: [LevelNode.ID: LevelNode.Transform] = [:]
    @State private var rotationStartAngle: Double?
    @State private var lastPublishedRotationAngle: Double?
    @State private var rotationCenter: CGPoint?
    @State private var rotationHandleStartCenter: CGPoint?
    @State private var rotationHandleStartDegrees: Double = 0
    @State private var groupRotationPreviewDegrees: Double = 0
    @State private var groupSelectionFrameOverride: LevelNode.Transform?
    @State private var isAlternatePlacementPressed = false
    @State private var horizontalAxisLockY: Int?
    @State private var verticalAxisLockX: Int?
    @State private var drilledNodeID: LevelNode.ID?
    @State private var marqueeStart: CGPoint?
    @State private var marqueeCurrent: CGPoint?
    @State private var marqueeBaseSelection: Set<LevelNode.ID> = []
    @State private var viewportSize: CGSize = .zero
    @State private var trickPreviewDragStartOffset: CGSize?
    @State private var cachedSortedCanvasNodes: [LevelNode] = []
    @State private var cachedDisplayImagePathsByNodeID: [LevelNode.ID: String] = [:]
    @State private var cachedPreviewPiecesByNodeID: [LevelNode.ID: [LevelNode.PreviewPiece]] = [:]
    @State private var cachedTrapezoidStylesByNodeID: [LevelNode.ID: TrapezoidCollisionShape.Style] = [:]
    @State private var cachedDynamicBadgeCounts: [LevelNode.ID: Int] = [:]
    @State private var cachedDynamicSourceTransforms: [LevelNode.ID: LevelNode.Transform] = [:]
    @State private var cachedCanvasNodeBuildMilliseconds: Double = 0
    @AppStorage("vector2.showLibraryHelperOverlays") private var showLibraryHelperOverlays = true
    @AppStorage("vector2.showDynamicBadges") private var showDynamicBadges = true
    @AppStorage("vector2.trapezoidVisualizer") private var trapezoidVisualizer = "image"
    @AppStorage("vector2.fullLiveRotationPreview") private var fullLiveRotationPreview = false
    private let canvasCoordinateSpace = "Vector2CanvasArea"
    private let vectorUnitsPerCanvasPoint: CGFloat = 3
    private let canvasOrigin = CGPoint(x: 80, y: 80)
    private let trickPreviewHitSize = CGSize(width: 164, height: 204)

    private var panOffset: CGSize { camera.panOffset }
    private var zoom: CGFloat { camera.zoom }


    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                CanvasGrid(panOffset: panOffset, zoom: zoom)

                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .gesture(SpatialTapGesture().onEnded { value in
                        guard !parallaxPreviewEnabled else { return }
                        clearKeyboardFocus()
                        if let hitNode = sceneNode(at: value.location, preferParent: isParentSelectionPressed) {
                            document.select(hitNode.id)
                        } else if let placementAsset {
                            drilledNodeID = nil
                            let point = documentPoint(from: value.location)
                            document.appendAsset(placementAsset, tool: selectedTool, x: point.x, y: point.y)
                            onPlaceAsset?()
                        } else {
                            drilledNodeID = nil
                            let point = documentPoint(from: value.location)
                            document.appendNodeForPlacement(
                                tool: selectedTool,
                                x: point.x,
                                y: point.y,
                                alternateVariant: isAlternatePlacementPressed
                            )
                            if !selectedTool.canPlaceDirectlyOnCanvas {
                                document.clearSelection()
                            }
                        }
                    })

                canvasContent
                .offset(x: panOffset.width, y: panOffset.height)

                roomTrickPreview(in: geometry.size)

                CanvasInputCatcher(
                    panOffset: $camera.panOffset,
                    zoom: $camera.zoom,
                    onDeleteSelection: onDeleteSelection,
                    onClearFocus: clearKeyboardFocus,
                    onShiftSelectClick: { point in
                        // sceneNode performs the pan conversion internally.
                        // Passing an already-local point subtracted pan twice,
                        // which is why Shift-click missed after moving the view.
                        if let node = sceneNode(at: point) {
                            document.toggleSelected(interactionNodeID(for: node))
                        }
                    },
                    onShiftSelectDragStart: { point in
                        let local = localCanvasLocation(point)
                        marqueeBaseSelection = Set(document.effectiveSelectedNodeIDs)
                        marqueeStart = local
                        marqueeCurrent = local
                    },
                    onShiftSelectDragChange: { point in
                        marqueeCurrent = localCanvasLocation(point)
                    },
                    onShiftSelectDragEnd: { point in
                        marqueeCurrent = localCanvasLocation(point)
                        updateMarqueeSelection()
                        marqueeStart = nil
                        marqueeCurrent = nil
                        marqueeBaseSelection.removeAll()
                    },
                    onToolScroll: { direction in
                        selectedTool = selectedTool.cycled(by: direction)
                    },
                    onAlternatePlacementChanged: { isPressed in
                        isAlternatePlacementPressed = isPressed
                    },
                    onPrimaryMouseDown: { point in
                        // Blank-space deselection should feel immediate. SwiftUI's
                        // tap recognizers wait to rule out the node double-click,
                        // but this native mouse-down path never touches node drags.
                        guard !parallaxPreviewEnabled,
                              allowsBlankCanvasDeselection,
                              placementAsset == nil,
                              !selectedTool.canPlaceDirectlyOnCanvas,
                              CanvasInteractionPolicy.shouldClearSelection(
                                sceneHit: sceneNode(at: point, preferParent: isParentSelectionPressed) != nil,
                                selectionHandleHit: selectionHandleContains(point)
                              ) else { return }
                        drilledNodeID = nil
                        document.clearSelection()
                        // Ending an active NSTextField can commit formatting and
                        // XML work. Let the selection disappear first so clicking
                        // empty canvas never waits on the inspector to resign focus.
                        DispatchQueue.main.async { clearKeyboardFocus() }
                    },
                    onFocusSelection: focusSelection
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .coordinateSpace(name: canvasCoordinateSpace)
            .clipped()
            .onAppear {
                viewportSize = geometry.size
                rebuildCanvasNodeCache()
            }
            .onChange(of: geometry.size) { _, newValue in
                viewportSize = newValue
            }
            .onChange(of: document.renderRevision) { _, _ in
                if !isRotatingSelection {
                    groupSelectionFrameOverride = nil
                }
                rebuildCanvasNodeCache()
            }
            .onChange(of: document.id) { _, _ in
                groupSelectionFrameOverride = nil
                rebuildCanvasNodeCache()
            }
            .onChange(of: document.selectedNodeIDs) { oldSelection, newSelection in
                groupSelectionFrameOverride = nil
                if CanvasInteractionPolicy.shouldRefreshDisplayCache(
                    previousSelection: oldSelection,
                    newSelection: newSelection
                ) {
                    // Imported references reveal selection-only display helpers.
                    // Refresh now so handles use composed geometry before any move.
                    rebuildCanvasNodeCache()
                }
                if activeResizeHandle != nil || resizePreviewTransform != nil {
                    resetResizeGestureState()
                    onLiveEditEnded()
                }
            }
            .onChange(of: drilledNodeID) { _, _ in
                rebuildCanvasNodeCache()
            }
            .onChange(of: showLibraryHelperOverlays) { _, _ in
                rebuildCanvasNodeCache()
            }
            .onChange(of: trapezoidVisualizer) { _, _ in
                rebuildCanvasNodeCache()
            }
        }
        .background(Color.editorCanvasBackground)
        .overlay(alignment: .topTrailing) {
            if parallaxPreviewEnabled {
                Button { onToggleParallaxPreview?() } label: {
                    Label("Parallax preview · I to exit", systemImage: "square.3.layers.3d")
                        .font(.caption.bold())
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .foregroundStyle(.white)
                        .background(Color.black.opacity(0.8), in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(12)
            }
        }
    }

    private var placementAsset: TextureAsset? {
        // Active asset browser selection wins if compatible with the current
        // tool; otherwise we use a safe tool default.
        if let activePlacementAsset, selectedTool.canPlace(asset: activePlacementAsset) {
            return activePlacementAsset
        }
        if let fallbackPlacementAsset, selectedTool.canPlace(asset: fallbackPlacementAsset) {
            return fallbackPlacementAsset
        }
        return nil
    }

    private func focusSelection() {
        guard viewportSize.width > 0, viewportSize.height > 0,
              let selected = displaySelectedNode(from: sortedCanvasNodes),
              let transform = selected.transform else { return }
        let center = visualCanvasPoint(for: selected, transform: transform)
        camera.panOffset = CGSize(width: viewportSize.width / 2 - center.x,
                                  height: viewportSize.height / 2 - center.y)
    }

    /// Draw stack for the editable world.
    ///
    /// Rendering order is intentionally separated from hierarchy order through
    /// `sortedCanvasNodes` so editor-side layering can match the game better.
    private var canvasContent: some View {
        let canvasNodes = sortedCanvasNodes
        let _ = RoomWeaverDiagnostics.shared.recordZoomScenePass(nodeCount: canvasNodes.count)
        // Selection changes are cheap compared with rebuilding the scene cache.
        // Resolve the outline from the current selection every pass; caching this
        // node made Properties update immediately while the old outline stayed
        // on screen until some unrelated render revision arrived.
        let selectedNode = displaySelectedNode(from: canvasNodes)
        return ZStack(alignment: .topLeading) {
            ForEach(canvasNodes) { node in
                if let transform = node.transform {
                    let layoutOpacity = document.roomLayoutOpacity(for: node, guidesVisible: showRoomLayoutGuides)
                    let rawDisplayTransform = ownedRotationPreviewTransform(for: node, baseTransform: transform)
                        ?? affineReferenceDynamicPreviewTransform(for: node, baseTransform: transform)
                        ?? dynamicLivePreviewTransforms[node.id]
                        ?? groupedDynamicPreviewTransform(for: node, baseTransform: transform)
                        ?? ownedVisualDragPreviewTransform(for: node, baseTransform: transform)
                        ?? rotationPreviewTransforms[node.id]
                        ?? dragPreviewTransforms[node.id]
                        ?? (activeResizeNodeID == node.id ? resizePreviewTransform : nil)
                        ?? transform
                    let displayTransform = rawDisplayTransform
                    let resolvedImagePath = cachedDisplayImagePathsByNodeID[node.id]
                        ?? displayImagePath(for: node)
                    // A resolved image always wins in OverlayBox. Do not also
                    // carry hundreds of unused prefab pieces through SwiftUI's
                    // diffing path on every canvas update.
                    let livePreviewPieces = resolvedImagePath.isEmpty
                        ? (cachedPreviewPiecesByNodeID[node.id] ?? renderablePreviewPieces(for: node))
                        : []
                    let resolvedTrapezoidStyle = cachedTrapezoidStylesByNodeID[node.id]
                    let isReadOnlyOverlay = isReadOnlyDisplayOverlay(node)
                    let displaySize = canvasSize(for: displayTransform)
                    // Texture and prefab-composite contents do not change when
                    // the camera zooms. Keep their expensive child view at a
                    // stable logical size and update only its cheap per-node
                    // presentation transform. Shapes retain the original
                    // layout path so labels, trigger names, and handles keep
                    // their exact screen-space behavior.
                    let hasStableVisualContent = resolvedTrapezoidStyle == nil &&
                        (!resolvedImagePath.isEmpty || !livePreviewPieces.isEmpty)
                    let visualContentSize = hasStableVisualContent
                        ? canvasUnzoomedVisualSize(for: displayTransform)
                        : displaySize
                    let visualContentScale = hasStableVisualContent ? zoom : 1
                    let displayPoint = liveRotationCanvasPoint(for: node, baseline: transform)
                        ?? visualCanvasPoint(for: node, transform: displayTransform)
                    let parallaxOffset = previewOffset(for: node)
                    let previewPoint = CGPoint(x: displayPoint.x + parallaxOffset.width,
                                               y: displayPoint.y + parallaxOffset.height)
                    let box = OverlayBox(
                        label: node.name,
                        color: node.canvasColor,
                        outlineColor: node.canvasOutlineColor,
                        size: visualContentSize,
                        opacity: node.canvasOpacity,
                        style: .scene,
                        rotationDegrees: displayTransform.rotation,
                        imagePath: resolvedImagePath,
                        previewPieces: livePreviewPieces,
                        tintColorHex: node.metadata.tintColorHex,
                        isMirrored: node.metadata.isMirrored,
                        isFlippedVertically: node.metadata.isFlippedVertically,
                        trapezoidStyle: resolvedTrapezoidStyle
                    )
                    .equatable()
                    .transaction { transaction in
                        transaction.animation = nil
                    }
                    .scaleEffect(visualContentScale)
                    .opacity(layoutOpacity)
                    .position(previewPoint)

                    if parallaxPreviewEnabled || isReadOnlyOverlay || !document.roomLayoutIsInteractable(node, guidesVisible: showRoomLayoutGuides) {
                        // RoomWeaver emits extra render slices for sorting
                        // layers. They were already non-interactive, so adding
                        // tap and drag recognizers to every slice only inflated
                        // SwiftUI's gesture graph with no editor behavior.
                        box.allowsHitTesting(false)
                    } else {
                        box
                            .onTapGesture(count: 2) {
                                clearKeyboardFocus()
                                guard !node.rendersAsRuntimeGraph else { return }
                                guard canDrillInto(node) else { return }
                                drilledNodeID = drilledNodeID == node.id ? nil : node.id
                                document.select(interactionNodeID(for: node))
                            }
                            .highPriorityGesture(TapGesture().onEnded {
                                clearKeyboardFocus()
                                document.select(interactionNodeID(for: node))
                            })
                            .simultaneousGesture(moveGesture(for: interactionNodeID(for: node), transform: transform))
                    }

                    if node.kind == .trigger && node.metadata.aiActionTemplate == "Spawn" {
                        VStack(spacing: 2) {
                            Image(systemName: "person.crop.circle.badge.plus")
                                .font(.system(size: 16, weight: .bold))
                            Text("AI SPAWN")
                                .font(.system(size: 8, weight: .black, design: .rounded))
                        }
                        .foregroundStyle(Color.green)
                        .padding(5)
                        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 6))
                        .position(
                            canvasPoint(for: LevelNode.Transform(
                                x: displayTransform.x + displayTransform.width / 2,
                                y: displayTransform.y + displayTransform.height / 2,
                                width: 0,
                                height: 0
                            ))
                        )
                        .allowsHitTesting(false)
                        .zIndex(950)
                    }

                    if showDynamicBadges, let dynamicCount = cachedDynamicBadgeCounts[node.id] {
                        let countSuffix = dynamicCount > 1 ? " x\(dynamicCount)" : ""
                        Label("DYNAMIC\(countSuffix)", systemImage: "waveform.path.ecg")
                            .font(.system(size: 8, weight: .black, design: .rounded))
                            .foregroundStyle(Color.cyan)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 3)
                            .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 5))
                            .position(
                                x: displayPoint.x,
                                y: displayPoint.y - displaySize.height / 2 - 9
                            )
                            .allowsHitTesting(false)
                            .zIndex(951)
                    }
                }
            }

            if showRoomLayoutGuides {
                ForEach(document.activeRoomLayoutBounds) { guide in
                    let size = canvasSize(for: guide.transform)
                    let center = canvasPoint(for: .init(
                        x: guide.transform.x + guide.transform.width / 2,
                        y: guide.transform.y + guide.transform.height / 2,
                        width: guide.transform.width,
                        height: guide.transform.height
                    ))
                    ZStack(alignment: .topLeading) {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(guide.section.color.opacity(0.055))
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(guide.section.color.opacity(0.9), style: StrokeStyle(lineWidth: 2, dash: [8, 5]))
                        Text("\(guide.section.rawValue.uppercased()) · \(guide.displayName)")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(guide.section.color, in: Capsule())
                            .padding(6)
                    }
                    .frame(width: size.width, height: size.height)
                    .position(center)
                    .allowsHitTesting(false)
                    .zIndex(970)
                }
            }

            ForEach(Array(dynamicOnionTransforms.enumerated()), id: \.offset) { _, transform in
                Rectangle()
                    .fill(Color.blue.opacity(0.08))
                    .overlay(Rectangle().stroke(Color.blue.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
                    .frame(width: canvasSize(for: transform).width, height: canvasSize(for: transform).height)
                    .rotationEffect(.degrees(transform.rotation))
                    .position(canvasPoint(for: transform))
                    .allowsHitTesting(false)
                    .zIndex(900)
            }

            if showTrapGuides,
               let trap = document.selectedNode,
               let transform = trap.transform,
               TrapCatalog.isTrap(trap) {
                ForEach(TrapCatalog.guideRegions(for: trap)) { region in
                    let guideTransform = LevelNode.Transform(
                        x: transform.x + region.offsetX,
                        y: transform.y + region.offsetY,
                        width: region.width,
                        height: region.height
                    )
                    let danger = region.kind == .danger
                    VectorRuntimeRegionBox(
                        title: danger ? "DamageArea" : "ActivationArea",
                        kind: danger ? .area : .trigger
                    )
                        .frame(width: canvasSize(for: guideTransform).width, height: canvasSize(for: guideTransform).height)
                        .position(canvasPoint(for: guideTransform))
                        .allowsHitTesting(false)
                        .zIndex(980)
                }
            }

            if !parallaxPreviewEnabled, let selectedNode, let modelTransform = selectedNode.transform {
                let isAffineRoomWeaverPreview = selectedNode.metadata.visualType == "RoomWeaverAffinePreview"
                let baseTransform = selectedNode.metadata.visualType == "RoomWeaverDynamicSelectionGroup"
                    ? modelTransform
                    : CanvasInteractionPolicy.selectionTransform(
                        model: modelTransform,
                        displayed: displayedTransform(for: selectedNode.id)
                    )
                let canEditSingleSelection = document.movableSelectedNodeIDs.count <= 1
                let usesGroupSelectionFrame = !canEditSingleSelection
                let baseDisplayTransform: LevelNode.Transform = {
                    if selectedNode.metadata.visualType == "RoomWeaverDynamicSelectionGroup",
                       dragOriginTransform != nil {
                        return .init(
                        x: baseTransform.x + dragPreviewDeltaX,
                        y: baseTransform.y + dragPreviewDeltaY,
                        width: baseTransform.width,
                        height: baseTransform.height,
                        rotation: baseTransform.rotation
                        )
                    }
                    if selectedNode.metadata.visualType == "RoomWeaverDynamicSelectionGroup",
                       let origin = rotationOriginTransforms[selectedNode.id],
                       let preview = rotationPreviewTransforms[selectedNode.id] {
                        return LevelDocument.projectVisualEdit(baseTransform, usesRectOrigin: false,
                            from: origin, to: preview,
                            ownerUsesRectOrigin: document.root.find(id: selectedNode.id)?.kind.usesVectorRectOrigin ?? false)
                    }
                    return rotationPreviewTransforms[selectedNode.id] ?? dragPreviewTransforms[selectedNode.id] ?? baseTransform
                }()
                let groupFrameOrigins = isRotatingSelection && usesGroupSelectionFrame ? rotationOriginTransforms : nil
                let sharedGroupRotation = document.commonMovableSelectionRotation(from: groupFrameOrigins)
                let selectionTransform = usesGroupSelectionFrame
                    ? (groupSelectionFrameOverride
                        ?? sharedGroupRotation.flatMap {
                            document.selectedBounds(
                                alignedTo: $0,
                                from: groupFrameOrigins ?? (dragPreviewTransforms.isEmpty ? nil : dragPreviewTransforms)
                            )
                        }
                        ?? document.selectedBounds(from: groupFrameOrigins ?? (dragPreviewTransforms.isEmpty ? nil : dragPreviewTransforms))
                        ?? baseDisplayTransform)
                    : baseDisplayTransform
                let groupFrameRotation = isRotatingSelection && usesGroupSelectionFrame
                    ? groupRotationPreviewDegrees
                    : (sharedGroupRotation ?? 0)
                let ownedResizePreview = activeResizeNodeID == selectedNode.id ? resizePreviewTransform : nil
                let transform = ownedResizePreview ?? selectionTransform
                SelectedObjectOutline(
                    size: canvasSize(for: transform),
                    rotationDegrees: usesGroupSelectionFrame ? groupFrameRotation : transform.rotation
                )
                .position(
                    x: selectionCanvasPoint(for: selectedNode, transform: transform, forceRectOrigin: usesGroupSelectionFrame).x,
                    y: selectionCanvasPoint(for: selectedNode, transform: transform, forceRectOrigin: usesGroupSelectionFrame).y
                )
                .allowsHitTesting(false)
                .zIndex(1_000)

                if canEditSingleSelection && CanvasTransformHandlePolicy.canResize(
                    hasChildren: !selectedNode.children.isEmpty,
                    isAffineImportedPreview: isAffineRoomWeaverPreview
                ) {
                    ForEach(CanvasHandle.resizeCases, id: \.self) { handle in
                        ResizeHandleView()
                            .position(resizeHandlePosition(for: selectedNode, transform: transform, handle: handle))
                            .highPriorityGesture(resizeGesture(for: selectedNode, transform: baseTransform, handle: handle))
                            .zIndex(1_001)
                    }

                }

                if CanvasTransformHandlePolicy.canRotate(
                    isTrap: TrapCatalog.isTrap(selectedNode),
                    isAffineImportedPreview: isAffineRoomWeaverPreview
                ) {
                    RotationHandleView()
                        .position(rotationHandlePosition(
                            for: selectedNode,
                            transform: withRotation(transform, usesGroupSelectionFrame ? groupFrameRotation : transform.rotation),
                            forceRectOrigin: usesGroupSelectionFrame
                        ))
                        .gesture(rotationGesture(for: selectedNode, transform: selectionTransform, isGroupRotation: usesGroupSelectionFrame))
                        .zIndex(1_002)
                }
            }

            if let marqueeRect {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.12))
                    .overlay(Rectangle().stroke(Color.accentColor.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
                    .frame(width: marqueeRect.width, height: marqueeRect.height)
                    .position(x: marqueeRect.midX, y: marqueeRect.midY)
                    .allowsHitTesting(false)
            }

        }
    }

    @ViewBuilder
    private func roomTrickPreview(in size: CGSize) -> some View {
        if let trickPreviewPlayback, let localAnchor = trickPreviewAnchor(for: trickPreviewPlayback) {
            let anchor = TrickPreviewRoomFraming.screenAnchor(
                localAnchor: localAnchor,
                panOffset: panOffset
            )
            TrickPreviewOverlay(
                playback: trickPreviewPlayback,
                anchor: anchor,
                zoom: zoom,
                unitsPerCanvasPoint: vectorUnitsPerCanvasPoint,
                centersVisibleModel: true
            )
            .frame(width: size.width, height: size.height)
            .allowsHitTesting(false)
            .zIndex(1_200)

            Rectangle()
                .fill(Color.clear)
                .contentShape(Rectangle())
                .frame(width: trickPreviewHitSize.width, height: trickPreviewHitSize.height)
                .position(anchor)
                .gesture(
                    DragGesture(coordinateSpace: .named(canvasCoordinateSpace))
                        .onChanged { value in
                            if trickPreviewDragStartOffset == nil {
                                trickPreviewDragStartOffset = trickPreviewPlayback.placementOffset
                            }
                            let start = trickPreviewDragStartOffset ?? .zero
                            updateTrickPreviewOffset(CGSize(
                                width: start.width + (value.translation.width / zoom) * vectorUnitsPerCanvasPoint,
                                height: start.height + (value.translation.height / zoom) * vectorUnitsPerCanvasPoint
                            ))
                        }
                        .onEnded { _ in
                            trickPreviewDragStartOffset = nil
                        }
                )
                .zIndex(1_201)

            Button {
                self.trickPreviewPlayback = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .padding(6)
                    .background(.black.opacity(0.72), in: Capsule())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .position(
                x: min(max(anchor.x + 96, 124), max(124, size.width - 124)),
                y: min(max(anchor.y - 86, 32), max(32, size.height - 32))
            )
            .zIndex(1_202)
        }
    }

    private func trickPreviewAnchor(for playback: TrickPreviewPlayback) -> CGPoint? {
        let node = document.node(for: playback.anchorNodeID) ?? document.selectedNode
        guard let node, let transform = node.transform else {
            return nil
        }
        let centered = visualCenterTransform(for: node, transform: transform)
        let previewBaseYOffset = max(72, min(180, Int((CGFloat(centered.height) * 0.55).rounded()) + 40))
        return canvasPoint(
            for: .init(
                x: centered.x + Int(CGFloat(node.metadata.visualOffsetX) + playback.placementOffset.width),
                y: centered.y + previewBaseYOffset + Int(CGFloat(node.metadata.visualOffsetY) + playback.placementOffset.height),
                width: centered.width,
                height: centered.height,
                rotation: centered.rotation
            )
        )
    }

    private func updateTrickPreviewOffset(_ offset: CGSize) {
        guard var playback = trickPreviewPlayback else { return }
        playback.placementOffset = offset
        trickPreviewPlayback = playback
    }

    private func isPointInsideTrickPreview(_ point: CGPoint) -> Bool {
        guard let playback = trickPreviewPlayback, let localAnchor = trickPreviewAnchor(for: playback) else { return false }
        let anchor = TrickPreviewRoomFraming.screenAnchor(
            localAnchor: localAnchor,
            panOffset: panOffset
        )
        let rect = CGRect(
            x: anchor.x - trickPreviewHitSize.width / 2,
            y: anchor.y - trickPreviewHitSize.height / 2,
            width: trickPreviewHitSize.width,
            height: trickPreviewHitSize.height
        )
        return rect.contains(point)
    }

    /// Sorts visible nodes for drawing/hit-testing.
    ///
    /// place to inspect: draw order should respect Vector 2 sorting layer/factor
    /// expectations without breaking hierarchy editing.
    private var sortedCanvasNodes: [LevelNode] {
        cachedSortedCanvasNodes.isEmpty ? sortedDisplayNodes(from: document.root) : cachedSortedCanvasNodes
    }

    private func sortedDisplayNodes(from node: LevelNode) -> [LevelNode] {
        displayNodes(from: node).enumerated().sorted { lhs, rhs in
            let lhsKey = canvasSortKey(for: lhs.element)
            let rhsKey = canvasSortKey(for: rhs.element)
            if lhsKey.layer == rhsKey.layer {
                if lhsKey.factor == rhsKey.factor {
                    // Unity/Vector keep sibling order meaningful. Alphabetical tie-breaking
                    // made same-layer objects visually reorder themselves in our editor.
                    return lhs.offset < rhs.offset
                }
                return lhsKey.factor < rhsKey.factor
            }
            return lhsKey.layer < rhsKey.layer
        }.map(\.element)
    }

    private var visibleCanvasNodes: [LevelNode] {
        sortedCanvasNodes
    }

    private func rebuildCanvasNodeCache() {
        let start = CFAbsoluteTimeGetCurrent()
        let nodes = sortedDisplayNodes(from: document.root)
        var imagePaths: [LevelNode.ID: String] = [:]
        var previewPieces: [LevelNode.ID: [LevelNode.PreviewPiece]] = [:]
        var trapezoidStyles: [LevelNode.ID: TrapezoidCollisionShape.Style] = [:]
        var badgeCounts: [LevelNode.ID: Int] = [:]
        imagePaths.reserveCapacity(nodes.count)
        previewPieces.reserveCapacity(nodes.count)
        trapezoidStyles.reserveCapacity(16)
        badgeCounts.reserveCapacity(16)
        for node in nodes {
            let imagePath = displayImagePath(for: node)
            imagePaths[node.id] = imagePath
            if imagePath.isEmpty {
                let pieces = renderablePreviewPieces(for: node)
                previewPieces[node.id] = pieces
            }
            if let trapezoidStyle = trapezoidDisplayStyle(for: node) {
                trapezoidStyles[node.id] = trapezoidStyle
            }
            if let count = dynamicBadgeCount(for: node) {
                badgeCounts[node.id] = count
            }
        }
        cachedSortedCanvasNodes = nodes
        cachedDisplayImagePathsByNodeID = imagePaths
        cachedPreviewPiecesByNodeID = previewPieces
        cachedTrapezoidStylesByNodeID = trapezoidStyles
        cachedDynamicBadgeCounts = badgeCounts
        var dynamicSources: [LevelNode.ID: LevelNode.Transform] = [:]
        let owners = Set(nodes.flatMap { node in
            node.metadata.roomWeaverDynamicOwnerIDs
                + [node.metadata.roomWeaverDynamicOwnerID].compactMap { $0 }
                + (node.metadata.dynamicXML.isEmpty ? [] : [node.id])
        })
        for id in owners {
            if let transform = document.root.find(id: id)?.transform {
                dynamicSources[id] = document.root.canvasTransform(for: id, localTransform: transform)
            }
        }
        cachedDynamicSourceTransforms = dynamicSources
        cachedCanvasNodeBuildMilliseconds = max(0, (CFAbsoluteTimeGetCurrent() - start) * 1000)
        RoomWeaverDiagnostics.shared.performanceSample(
            operation: "Canvas display-cache rebuild",
            milliseconds: cachedCanvasNodeBuildMilliseconds
        )
    }

    private func dynamicBadgeCount(for node: LevelNode) -> Int? {
        let identityParts = [node.name, node.metadata.className, node.metadata.sortingLayer]
        let isLightingService = identityParts.contains {
            $0.localizedCaseInsensitiveContains("light") || $0.localizedCaseInsensitiveContains("lamp")
        }
        let xml = node.metadata.dynamicXML
        let hasDirectDynamic = !isLightingService && (
            xml.contains("<MoveInterval") ||
            xml.contains("<RotationInterval") ||
            xml.contains("<SizeInterval")
        )
        guard hasDirectDynamic || node.metadata.resolvedDynamicCount > 0 else { return nil }
        return max(1, node.metadata.resolvedDynamicCount)
    }

    private func displaySelectedNode(from nodes: [LevelNode]) -> LevelNode? {
        guard let selectedID = document.selectedNodeID else { return nil }
        let ownedVisuals = nodes.filter {
            $0.metadata.visualType != "RoomWeaverHelperOverlay" && (
            $0.metadata.roomWeaverVisualOwnerID == selectedID ||
            $0.metadata.roomWeaverDynamicOwnerIDs.contains(selectedID)
                || $0.metadata.roomWeaverDynamicOwnerID == selectedID
                || $0.metadata.roomLayoutSharedOwnerID == selectedID)
        }
        if !ownedVisuals.isEmpty,
           let source = document.root.find(id: selectedID) {
            let bounds = ownedVisuals.compactMap { node -> CGRect? in
                guard let transform = node.transform else { return nil }
                let center = visualCenterTransform(for: node, transform: transform)
                return CGRect(
                    x: center.x - transform.width / 2,
                    y: center.y - transform.height / 2,
                    width: transform.width,
                    height: transform.height
                )
            }.reduce(nil as CGRect?) { partial, next in
                partial.map { $0.union(next) } ?? next
            }
            if let bounds {
                var groupedSelection = source
                groupedSelection.kind = .object
                groupedSelection.transform = .init(
                    x: Int(bounds.midX.rounded()),
                    y: Int(bounds.midY.rounded()),
                    width: max(1, Int(bounds.width.rounded(.up))),
                    height: max(1, Int(bounds.height.rounded(.up))),
                    rotation: 0
                )
                groupedSelection.metadata.visualOffsetX = 0
                groupedSelection.metadata.visualOffsetY = 0
                groupedSelection.metadata.visualType = "RoomWeaverDynamicSelectionGroup"
                return groupedSelection
            }
        }
        let movableIDs = document.movableSelectedNodeIDs
        if !movableIDs.contains(selectedID),
           let movableID = movableIDs.first {
            return nodes.first { $0.id == movableID } ?? document.root.find(id: movableID)
        }
        return nodes.first { $0.id == selectedID } ?? document.selectedNode
    }

    private func displayImagePath(for node: LevelNode) -> String {
        // Resolves the image used by OverlayBox. Trapezoids intentionally keep
        // their original editor art while export remains XML geometry.
        if node.kind == .trapezoid && trapezoidVisualizer == "polygon" {
            return ""
        }
        if node.kind == .image,
           node.previewPieces.contains(where: { $0.basisXX != nil && $0.basisXY != nil && $0.basisYX != nil && $0.basisYY != nil }) {
            return ""
        }
        if !node.metadata.imagePath.isEmpty {
            return node.metadata.imagePath
        }
        return ""
    }

    private func trapezoidDisplayStyle(for node: LevelNode) -> TrapezoidCollisionShape.Style? {
        guard node.kind == .trapezoid else {
            return nil
        }
        let variant = [
            node.xml.variant,
            node.name,
            node.metadata.imagePath
        ]
            .joined(separator: " ")
            .lowercased()
        return (variant.contains("type2") || variant.contains("right") || variant.contains("trapezoid_type2")) ? .right : .left
    }

    private func renderablePreviewPieces(for node: LevelNode) -> [LevelNode.PreviewPiece] {
        // Prefer cached preview pieces from import/builders, otherwise derive
        // pieces from child image nodes for object-style wrappers only.
        if !node.previewPieces.isEmpty {
            return node.previewPieces
        }

        guard node.kind == .object || node.kind == .objectReference || node.kind == .dynamic else {
            return []
        }

        guard let parentTransform = node.transform else {
            return []
        }

        return previewPieces(in: node, relativeTo: parentTransform)
    }

    private func previewPieces(in node: LevelNode, relativeTo parentTransform: LevelNode.Transform) -> [LevelNode.PreviewPiece] {
        // Builds parent-relative sprite pieces from child nodes. Used when an
        // object is visually composed from children rather than one baked image.
        node.children.flatMap { child -> [LevelNode.PreviewPiece] in
            guard let childTransform = child.transform else {
                return previewPieces(in: child, relativeTo: parentTransform)
            }

            var pieces: [LevelNode.PreviewPiece] = []
            if child.kind == .image, !child.metadata.imagePath.isEmpty {
                pieces.append(
                        LevelNode.PreviewPiece(
                            imagePath: child.metadata.imagePath,
                            centerX: Double(visualCenterTransform(for: child, transform: childTransform).x - parentTransform.x),
                            centerY: Double(visualCenterTransform(for: child, transform: childTransform).y - parentTransform.y),
                            width: Double(childTransform.width),
                            height: Double(childTransform.height),
                            rotation: childTransform.rotation
                     )
                )
            }

            pieces.append(contentsOf: previewPieces(in: child, relativeTo: parentTransform))
            return pieces
        }
    }

    /// Drag-move gesture for selected nodes.
    ///
    /// Movement uses frozen origin transforms from drag start, which prevents
    /// accumulating rounding error and keeps undo to one step per drag.
    private func moveGesture(for nodeID: LevelNode.ID, transform: LevelNode.Transform) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(canvasCoordinateSpace))
            .onChanged { value in
                guard !isPointInsideTrickPreview(value.startLocation) else { return }
                guard activeResizeHandle == nil else { return }
                beginMoveGestureSession(at: value.startLocation)
                let resolvedNodeID = dragOriginPrimaryID
                    ?? dragTargetNodeID(forGestureNodeID: nodeID, startLocation: value.startLocation)
                let targetNodeID = isParentSelectionPressed
                    ? (preferredParentSelection(for: resolvedNodeID)?.id ?? resolvedNodeID)
                    : resolvedNodeID
                let targetTransform = displayedTransform(for: targetNodeID) ?? document.root.find(id: targetNodeID)?.transform ?? transform
                if dragOriginTransform == nil {
                    onLiveEditBegan()
                    groupSelectionFrameOverride = nil
                    dragOriginTransform = targetTransform
                    dragOriginPrimaryID = targetNodeID
                    if !document.selectedNodeIDs.contains(targetNodeID) {
                        document.select(targetNodeID)
                    }
                    // Drag deltas are measured in canvas/display space. Imported
                    // RoomWeaver children store local transforms, so freezing
                    // those raw values here made grouped objects jump.
                    dragOriginTransforms = document.selectedTransformSnapshots()
                    let selectedIDs = Set(document.movableSelectedNodeIDs)
                    dragPreviewMovedIDs = movedPreviewNodeIDs(for: selectedIDs.isEmpty ? Set([targetNodeID]) : selectedIDs)
                    dragPreviewOriginTransforms = previewOriginTransforms(for: dragPreviewMovedIDs)
                    if dragPreviewOriginTransforms[targetNodeID] == nil {
                        dragPreviewOriginTransforms[targetNodeID] = targetTransform
                    }
                }

                guard let origin = dragOriginTransform else { return }
                let rawX = snapVectorValue(origin.x + Int(((value.translation.width / zoom) * vectorUnitsPerCanvasPoint).rounded()))
                let rawY = snapVectorValue(origin.y + Int(((value.translation.height / zoom) * vectorUnitsPerCanvasPoint).rounded()))
                if isVerticalAxisLockPressed {
                    verticalAxisLockX = verticalAxisLockX ?? rawX
                } else {
                    verticalAxisLockX = nil
                }
                if isHorizontalAxisLockPressed {
                    horizontalAxisLockY = horizontalAxisLockY ?? rawY
                } else {
                    horizontalAxisLockY = nil
                }

                let proposedX = verticalAxisLockX ?? rawX
                let proposedY = horizontalAxisLockY ?? rawY
                let proposed = vSnappedTransform(
                    for: targetNodeID,
                    proposed: .init(x: proposedX, y: proposedY, width: origin.width, height: origin.height, rotation: origin.rotation)
                )
                let x = proposed.x
                let y = proposed.y
                let deltaX = x - origin.x
                let deltaY = y - origin.y
                dragPreviewDeltaX = deltaX
                dragPreviewDeltaY = deltaY
                dragPreviewTransforms = dragPreviewOriginTransforms.mapValues { origin in
                    .init(
                        x: origin.x + deltaX,
                        y: origin.y + deltaY,
                        width: origin.width,
                        height: origin.height,
                        rotation: origin.rotation
                    )
                }
            }
            .onEnded { _ in
                guard dragOriginTransform != nil else { return }
                if let targetNodeID = dragOriginPrimaryID {
                    // RoomWeaver library references are displayed using the center
                    // of their reconstructed sprite bounds, which is not their XML
                    // origin. Writing the preview center back as an absolute X/Y
                    // made a single dragged reference jump. Commit every drag as a
                    // delta from the frozen model-space snapshots instead.
                    if document.selectedNodeIDs.contains(targetNodeID) {
                        document.moveSelectedNodes(from: dragOriginTransforms, byX: dragPreviewDeltaX, y: dragPreviewDeltaY)
                    } else {
                        document.moveNode(from: dragOriginTransforms[targetNodeID], id: targetNodeID, byX: dragPreviewDeltaX, y: dragPreviewDeltaY)
                    }
                }
                resetMoveGestureState()
                onLiveEditEnded()
            }
    }

    private func beginMoveGestureSession(at startLocation: CGPoint) {
        if let previous = dragGestureStartLocation {
            let distance = hypot(previous.x - startLocation.x, previous.y - startLocation.y)
            if distance > 1 {
                // SwiftUI can cancel an overlapping drag without delivering
                // onEnded. Never let that orphaned target own the next drag.
                resetMoveGestureState()
                onLiveEditEnded()
            }
        }
        if dragGestureStartLocation == nil {
            dragGestureStartLocation = startLocation
        }
    }

    private func resetMoveGestureState() {
        dragOriginTransform = nil
        dragOriginPrimaryID = nil
        dragGestureStartLocation = nil
        dragOriginTransforms = [:]
        dragPreviewOriginTransforms = [:]
        dragPreviewTransforms = [:]
        dragPreviewMovedIDs = []
        dragPreviewDeltaX = 0
        dragPreviewDeltaY = 0
        horizontalAxisLockY = nil
        verticalAxisLockX = nil
    }

    private func dragTargetNodeID(forGestureNodeID nodeID: LevelNode.ID, startLocation: CGPoint) -> LevelNode.ID {
        // When objects overlap, SwiftUI can deliver the drag to the front-most
        // view even if the user is clearly dragging the already-selected object.
        // Prefer selected nodes under the drag start so moving doesn't randomly
        // jump to a neighbor.
        let selectedIDs = document.selectedNodeIDs.isEmpty
            ? (document.selectedNodeID.map { Set([$0]) } ?? [])
            : document.selectedNodeIDs
        guard !selectedIDs.isEmpty else { return nodeID }

        for node in sortedCanvasNodes.reversed() where selectedIDs.contains(node.id) {
            guard let transform = displayedTransform(for: node.id) ?? node.transform else { continue }
            if hitTest(location: startLocation, node: node, transform: transform) {
                return node.id
            }
        }
        return nodeID
    }

    private func displayedTransform(for nodeID: LevelNode.ID) -> LevelNode.Transform? {
        cachedSortedCanvasNodes.first { $0.id == nodeID }?.transform
            ?? sortedCanvasNodes.first { $0.id == nodeID }?.transform
    }

    private func movedPreviewNodeIDs(for selectedIDs: Set<LevelNode.ID>) -> Set<LevelNode.ID> {
        var movedIDs: Set<LevelNode.ID> = []
        for id in selectedIDs {
            guard let node = document.root.find(id: id) else {
                movedIDs.insert(id)
                continue
            }
            movedIDs.formUnion(descendantIDsIncludingSelf(from: node))
        }
        return movedIDs
    }

    private func descendantIDsIncludingSelf(from node: LevelNode) -> Set<LevelNode.ID> {
        var ids: Set<LevelNode.ID> = [node.id]
        for child in node.children {
            ids.formUnion(descendantIDsIncludingSelf(from: child))
        }
        return ids
    }

    private func previewOriginTransforms(for movedIDs: Set<LevelNode.ID>) -> [LevelNode.ID: LevelNode.Transform] {
        Dictionary(
            cachedSortedCanvasNodes.compactMap { node in
                guard movedIDs.contains(node.id), let transform = node.transform else { return nil }
                return (node.id, transform)
            },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private var isVSnapPressed: Bool {
        CGEventSource.keyState(.combinedSessionState, key: 9)
            || CGEventSource.keyState(.hidSystemState, key: 9)
    }

    private var isHorizontalAxisLockPressed: Bool {
        CGEventSource.keyState(.combinedSessionState, key: 17)
            || CGEventSource.keyState(.hidSystemState, key: 17)
    }

    private var isVerticalAxisLockPressed: Bool {
        CGEventSource.keyState(.combinedSessionState, key: 5)
            || CGEventSource.keyState(.hidSystemState, key: 5)
    }

    private var isCenterSnapPressed: Bool {
        CGEventSource.keyState(.combinedSessionState, key: 32)
            || CGEventSource.keyState(.hidSystemState, key: 32)
    }

    private var isParentSelectionPressed: Bool {
        CGEventSource.keyState(.combinedSessionState, key: 14)
            || CGEventSource.keyState(.hidSystemState, key: 14)
    }

    /// Unity-style V snapping.
    ///
    /// While V is held, the moving node's corners/edges can snap to nearby
    /// corners/edges from other nodes. This helps align platforms and obstacles
    /// without globally enabling grid snapping.
    private func vSnappedTransform(for nodeID: LevelNode.ID, proposed: LevelNode.Transform) -> LevelNode.Transform {
        if isCenterSnapPressed {
            return centerSnappedTransform(for: nodeID, proposed: proposed)
        }

        guard isVSnapPressed,
              let movingNode = document.root.find(id: nodeID) else {
            return proposed
        }

        let movingCorners = canvasCorners(for: movingNode, transform: proposed)
        let selectedIDs = document.selectedNodeIDs.isEmpty ? Set([nodeID]) : document.selectedNodeIDs
        let targetCorners = sortedCanvasNodes
            .filter { !isVSnapExcludedTarget($0, selectedIDs: selectedIDs) }
            .compactMap { node -> [CGPoint]? in
                guard let transform = node.transform else { return nil }
                return canvasCorners(for: node, transform: transform)
            }
            .flatMap { $0 }

        var best: (dx: CGFloat, dy: CGFloat, distance: CGFloat)?
        for moving in movingCorners {
            for target in targetCorners {
                let dx = target.x - moving.x
                let dy = target.y - moving.y
                let distance = hypot(dx, dy)
                if distance <= 18, best == nil || distance < best!.distance {
                    best = (dx, dy, distance)
                }
            }
        }

        guard let best else { return proposed }
        return .init(
            x: proposed.x + Int((best.dx / zoom * vectorUnitsPerCanvasPoint).rounded()),
            y: proposed.y + Int((best.dy / zoom * vectorUnitsPerCanvasPoint).rounded()),
            width: proposed.width,
            height: proposed.height,
            rotation: proposed.rotation
        )
    }

    private func isVSnapExcludedTarget(_ node: LevelNode, selectedIDs: Set<LevelNode.ID>) -> Bool {
        // V-snap targets must be outside the thing currently being dragged.
        // Imported Vector 2 objects often render parent + helper children at the
        // same time; if those helpers stay targetable, the dragged object snaps
        // against its own internals and jitters like crazy.
        if selectedIDs.contains(node.id) {
            return true
        }
        for selectedID in selectedIDs {
            if document.root.containsDescendant(node.id, under: selectedID) {
                return true
            }
            if document.root.containsDescendant(selectedID, under: node.id) {
                return true
            }
        }
        return false
    }

    private func centerSnappedTransform(for nodeID: LevelNode.ID, proposed: LevelNode.Transform) -> LevelNode.Transform {
        guard let movingNode = document.root.find(id: nodeID) else {
            return proposed
        }

        let movingHandles = canvasMiddleHandles(for: movingNode, transform: proposed)
        let selectedIDs = document.selectedNodeIDs.isEmpty ? Set([nodeID]) : document.selectedNodeIDs
        let targetHandles = sortedCanvasNodes
            .filter { !isVSnapExcludedTarget($0, selectedIDs: selectedIDs) }
            .compactMap { node -> [CGPoint]? in
                guard let transform = node.transform else { return nil }
                return canvasMiddleHandles(for: node, transform: transform)
            }
            .flatMap { $0 }

        var best: (dx: CGFloat, dy: CGFloat, distance: CGFloat)?
        for moving in movingHandles {
            for target in targetHandles {
                let dx = target.x - moving.x
                let dy = target.y - moving.y
                let distance = hypot(dx, dy)
                if distance <= 22, best == nil || distance < best!.distance {
                    best = (dx, dy, distance)
                }
            }
        }

        guard let best else { return proposed }
        return .init(
            x: proposed.x + Int((best.dx / zoom * vectorUnitsPerCanvasPoint).rounded()),
            y: proposed.y + Int((best.dy / zoom * vectorUnitsPerCanvasPoint).rounded()),
            width: proposed.width,
            height: proposed.height,
            rotation: proposed.rotation
        )
    }

    private func canvasCorners(for node: LevelNode, transform: LevelNode.Transform) -> [CGPoint] {
        let center = selectionCanvasPoint(for: node, transform: transform)
        let size = canvasSize(for: transform)
        let halfW = size.width / 2
        let halfH = size.height / 2
        return [
            CGPoint(x: center.x - halfW, y: center.y - halfH),
            CGPoint(x: center.x + halfW, y: center.y - halfH),
            CGPoint(x: center.x + halfW, y: center.y + halfH),
            CGPoint(x: center.x - halfW, y: center.y + halfH)
        ].map { rotate(point: $0, around: center, degrees: transform.rotation) }
    }

    private func canvasMiddleHandles(for node: LevelNode, transform: LevelNode.Transform) -> [CGPoint] {
        let center = selectionCanvasPoint(for: node, transform: transform)
        let size = canvasSize(for: transform)
        let halfW = size.width / 2
        let halfH = size.height / 2
        return [
            CGPoint(x: center.x, y: center.y - halfH),
            CGPoint(x: center.x + halfW, y: center.y),
            CGPoint(x: center.x, y: center.y + halfH),
            CGPoint(x: center.x - halfW, y: center.y)
        ].map { rotate(point: $0, around: center, degrees: transform.rotation) }
    }

    /// Single-node resize gesture.
    ///
    /// We deliberately keep resize local to one node. Multi-object/group resize
    /// caused Vector 2 library children to stretch apart because those children
    /// are visual helpers, not true affine children.
    private func resizeGesture(for node: LevelNode, transform: LevelNode.Transform, handle: CanvasHandle) -> some Gesture {
        // The handle itself moves while the preview changes. Measuring in the
        // handle's local space feeds that motion back into the drag and causes
        // jumping/stalling, so resize uses the fixed canvas coordinate space.
        DragGesture(minimumDistance: 0, coordinateSpace: .named(canvasCoordinateSpace))
            .onChanged { value in
                if activeResizeHandle != nil,
                   (activeResizeHandle != handle || activeResizeNodeID != node.id) {
                    resetResizeGestureState()
                    onLiveEditEnded()
                }
                if activeResizeHandle == nil {
                    if dragOriginTransform != nil {
                        resetMoveGestureState()
                        onLiveEditEnded()
                    }
                    onLiveEditBegan()
                    activeResizeHandle = handle
                    activeResizeNodeID = node.id
                    resizeOriginTransform = transform
                }

                guard activeResizeHandle == handle,
                      activeResizeNodeID == node.id,
                      let origin = resizeOriginTransform else { return }

                let drag = CGPoint(
                    x: (value.location.x - value.startLocation.x) / zoom,
                    y: (value.location.y - value.startLocation.y) / zoom
                )
                let localDrag = rotateVector(drag, degrees: -origin.rotation)

                var left = -CGFloat(origin.width) / (vectorUnitsPerCanvasPoint * 2)
                var right = CGFloat(origin.width) / (vectorUnitsPerCanvasPoint * 2)
                var top = -CGFloat(origin.height) / (vectorUnitsPerCanvasPoint * 2)
                var bottom = CGFloat(origin.height) / (vectorUnitsPerCanvasPoint * 2)
                let minimumVectorDimension = CanvasResizePolicy.minimumVectorDimension(isImage: node.kind == .image)
                let minimumCanvasDimension = CGFloat(minimumVectorDimension) / vectorUnitsPerCanvasPoint

                if handle.affectsLeft {
                    left = min(right - minimumCanvasDimension, left + localDrag.x)
                } else if handle.affectsRight {
                    right = max(left + minimumCanvasDimension, right + localDrag.x)
                }

                if handle.affectsTop {
                    top = min(bottom - minimumCanvasDimension, top + localDrag.y)
                } else if handle.affectsBottom {
                    bottom = max(top + minimumCanvasDimension, bottom + localDrag.y)
                }

                if node.metadata.tag.caseInsensitiveCompare("Background") == .orderedSame || node.metadata.sortingLayer.hasPrefix("Bg") {
                    let horizontal = BackgroundPlacementPolicy.clampedAxis(
                        minimum: left,
                        maximum: right,
                        maximumLength: CGFloat(BackgroundPlacementPolicy.maximumWidth) / vectorUnitsPerCanvasPoint,
                        draggingMinimum: handle.affectsLeft,
                        draggingMaximum: handle.affectsRight
                    )
                    left = horizontal.minimum
                    right = horizontal.maximum
                    let vertical = BackgroundPlacementPolicy.clampedAxis(
                        minimum: top,
                        maximum: bottom,
                        maximumLength: CGFloat(BackgroundPlacementPolicy.maximumHeight) / vectorUnitsPerCanvasPoint,
                        draggingMinimum: handle.affectsTop,
                        draggingMaximum: handle.affectsBottom
                    )
                    top = vertical.minimum
                    bottom = vertical.maximum
                }

                let width = max(minimumVectorDimension, Int(((right - left) * vectorUnitsPerCanvasPoint).rounded()))
                let height = max(minimumVectorDimension, Int(((bottom - top) * vectorUnitsPerCanvasPoint).rounded()))
                let localCenterShift = CGPoint(x: (left + right) / 2, y: (top + bottom) / 2)
                let canvasCenterShift = rotateVector(localCenterShift, degrees: origin.rotation)
                let originCenter = visualCenterTransform(for: node, transform: origin)
                let newCenterX = originCenter.x + Int((canvasCenterShift.x * vectorUnitsPerCanvasPoint).rounded())
                let newCenterY = originCenter.y + Int((canvasCenterShift.y * vectorUnitsPerCanvasPoint).rounded())
                let x = snapVectorValue(node.kind.usesVectorRectOrigin ? newCenterX - width / 2 : newCenterX)
                let y = snapVectorValue(node.kind.usesVectorRectOrigin ? newCenterY - height / 2 : newCenterY)
                resizePreviewTransform = .init(x: x, y: y, width: width, height: height, rotation: origin.rotation)
            }
            .onEnded { _ in
                if let targetNodeID = activeResizeNodeID,
                   let preview = resizePreviewTransform {
                    document.updateCanvasTransform(
                        for: targetNodeID,
                        x: preview.x,
                        y: preview.y,
                        width: preview.width,
                        height: preview.height,
                        rotation: preview.rotation
                    )
                }
                resetResizeGestureState()
                onLiveEditEnded()
            }
    }

    private func resetResizeGestureState() {
        activeResizeHandle = nil
        activeResizeNodeID = nil
        resizeOriginTransform = nil
        resizePreviewTransform = nil
    }

    private func rotationGesture(for node: LevelNode, transform: LevelNode.Transform, isGroupRotation: Bool = false) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(canvasCoordinateSpace))
            .onChanged { value in
                if !isRotatingSelection {
                    onLiveEditBegan()
                    isRotatingSelection = true
                    rotationOriginTransforms = document.rotationHandleOrigins(
                        for: node.id, selectionFrame: transform, isGroup: isGroupRotation)
                    let center = rotationCanvasPoint(for: node, transform: transform, forceRectOrigin: isGroupRotation)
                    rotationHandleStartCenter = center
                    rotationHandleStartDegrees = transform.rotation
                    rotationCenter = CGPoint(x: (center.x / zoom - canvasOrigin.x) * vectorUnitsPerCanvasPoint,
                                             y: (center.y / zoom - canvasOrigin.y) * vectorUnitsPerCanvasPoint)
                    rotationStartAngle = nil
                }
                guard let center = rotationHandleStartCenter else { return }
                let location = localCanvasLocation(value.location)
                let angle = atan2(location.y - center.y, location.x - center.x) * 180 / .pi + 90
                if isGroupRotation, rotationStartAngle == nil { rotationStartAngle = angle }
                guard let publishedAngle = CanvasRotationPreviewPolicy.publishableAngle(
                    angle,
                    after: lastPublishedRotationAngle,
                    minimumStep: CanvasRotationPreviewPolicy.minimumStep(
                        fullLivePreview: fullLiveRotationPreview
                    )
                ) else { return }
                lastPublishedRotationAngle = publishedAngle
                if isGroupRotation, let vectorCenter = rotationCenter {
                    let degrees = publishedAngle - (rotationStartAngle ?? publishedAngle)
                    let baseRotation = document.commonMovableSelectionRotation(from: rotationOriginTransforms) ?? 0
                    groupRotationPreviewDegrees = baseRotation + degrees
                    if let originBounds = document.selectedBounds(
                        alignedTo: baseRotation,
                        from: rotationOriginTransforms
                    ) {
                        groupSelectionFrameOverride = withRotation(originBounds, groupRotationPreviewDegrees)
                    }
                    rotationPreviewTransforms = document.rotatedSelectedTransforms(
                        from: rotationOriginTransforms,
                        around: vectorCenter,
                        by: degrees
                    )
                } else if let vectorCenter = rotationCenter {
                    rotationPreviewTransforms = document.rotatedSelectedTransforms(
                        from: rotationOriginTransforms, around: vectorCenter,
                        by: publishedAngle - rotationHandleStartDegrees)
                }
            }
            .onEnded { _ in
                if !rotationPreviewTransforms.isEmpty {
                    document.applyTransforms(rotationPreviewTransforms)
                }
                isRotatingSelection = false
                rotationOriginTransforms = [:]
                rotationPreviewTransforms = [:]
                rotationStartAngle = nil
                lastPublishedRotationAngle = nil
                rotationCenter = nil
                rotationHandleStartCenter = nil
                rotationHandleStartDegrees = 0
                groupRotationPreviewDegrees = 0
                groupSelectionFrameOverride = nil
                onLiveEditEnded()
            }
    }

    private func withRotation(_ transform: LevelNode.Transform, _ rotation: Double) -> LevelNode.Transform {
        LevelNode.Transform(
            x: transform.x,
            y: transform.y,
            width: transform.width,
            height: transform.height,
            rotation: rotation
        )
    }

    private func canvasPoint(for transform: LevelNode.Transform) -> CGPoint {
        let base = CGPoint(
            x: canvasOrigin.x + CGFloat(transform.x) / vectorUnitsPerCanvasPoint,
            y: canvasOrigin.y + CGFloat(transform.y) / vectorUnitsPerCanvasPoint
        )
        return CGPoint(
            x: base.x * zoom,
            y: base.y * zoom
        )
    }

    private func previewOffset(for node: LevelNode) -> CGSize {
        guard parallaxPreviewEnabled,
              node.kind == .image,
              node.metadata.sortingLayer.hasPrefix("Bg"),
              let factor = Double(node.factor) else { return .zero }
        let delta = CGSize(width: panOffset.width - parallaxPreviewStartPan.width,
                           height: panOffset.height - parallaxPreviewStartPan.height)
        // Vector 2's VisualRunner uses FactorY = 1 - K * (1 - FactorX).
        // Stock Bg layers omit FactorVerticalK in layers.xml, so K defaults to 1.
        return ParallaxPreviewMath.offset(cameraPanDelta: delta, factorX: factor, verticalK: 1)
    }

    private func localCanvasLocation(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: point.x - panOffset.width,
            y: point.y - panOffset.height
        )
    }

    private func canvasSize(for transform: LevelNode.Transform) -> CGSize {
        CGSize(
            width: max(14, CGFloat(transform.width) / vectorUnitsPerCanvasPoint) * zoom,
            height: max(14, CGFloat(transform.height) / vectorUnitsPerCanvasPoint) * zoom
        )
    }

    private func canvasUnzoomedSize(for transform: LevelNode.Transform) -> CGSize {
        CGSize(
            width: max(14, CGFloat(transform.width) / vectorUnitsPerCanvasPoint),
            height: max(14, CGFloat(transform.height) / vectorUnitsPerCanvasPoint)
        )
    }

    private func canvasUnzoomedVisualSize(for transform: LevelNode.Transform) -> CGSize {
        // The old 14-point floor was useful for hit testing, but applying it to
        // the actual sprite made tiny resized images look like they floated as
        // their real transform continued shrinking underneath the fixed frame.
        CGSize(
            width: max(1, CGFloat(transform.width) / vectorUnitsPerCanvasPoint),
            height: max(1, CGFloat(transform.height) / vectorUnitsPerCanvasPoint)
        )
    }

    private func visualCanvasPoint(for node: LevelNode, transform: LevelNode.Transform) -> CGPoint {
        let root = canvasPoint(for: visualCenterTransform(for: node, transform: transform))
        let offset = visualOffset(for: node, transform: transform)
        return CGPoint(x: root.x + offset.x, y: root.y + offset.y)
    }

    private func visualCenterTransform(for node: LevelNode, transform: LevelNode.Transform) -> LevelNode.Transform {
        guard node.kind.usesVectorRectOrigin else { return transform }
        var centered = transform
        centered.x += transform.width / 2
        centered.y += transform.height / 2
        return centered
    }

    private func selectionCanvasPoint(for node: LevelNode, transform: LevelNode.Transform, forceRectOrigin: Bool = false) -> CGPoint {
        if !forceRectOrigin, let baseline = node.transform,
           let point = liveRotationCanvasPoint(for: node, baseline: baseline) { return point }
        if forceRectOrigin {
            return canvasPoint(
                for: .init(
                    x: transform.x + transform.width / 2,
                    y: transform.y + transform.height / 2,
                    width: transform.width,
                    height: transform.height,
                    rotation: transform.rotation
                )
            )
        }
        return visualCanvasPoint(for: node, transform: transform)
    }

    private var marqueeRect: CGRect? {
        guard let start = marqueeStart, let current = marqueeCurrent else { return nil }
        let origin = CGPoint(x: min(start.x, current.x), y: min(start.y, current.y))
        let size = CGSize(width: abs(start.x - current.x), height: abs(start.y - current.y))
        guard size.width > 2 || size.height > 2 else { return nil }
        return CGRect(origin: origin, size: size)
    }

    /// Shift-drag rectangle selection.
    ///
    /// Marquee adds all selectable scene nodes intersecting the rectangle. It
    /// does not recurse into hidden hierarchy-only children.
    private func updateMarqueeSelection() {
        guard let rect = marqueeRect else {
            if let point = marqueeCurrent,
               let node = selectableSceneNode(
                    at: CGPoint(x: point.x + panOffset.width, y: point.y + panOffset.height),
                    preferParent: true
               ) {
                document.toggleSelected(marqueeSelectionID(for: node))
            }
            return
        }
        var seenIDs: Set<LevelNode.ID> = []
        let hits = visibleCanvasNodes.compactMap { node -> LevelNode.ID? in
            guard isMarqueeSelectable(node) else { return nil }
            guard let transform = node.transform else { return nil }
            guard marqueeHitRect(for: node, transform: transform).intersects(rect) else { return nil }
            let id = marqueeSelectionID(for: node)
            guard !seenIDs.contains(id) else { return nil }
            seenIDs.insert(id)
            return id
        }
        let added = Set(document.prunedMarqueeSelectionIDs(hits))
        document.setSelected(ids: Array(marqueeBaseSelection.union(added)))
    }

    private func isMarqueeSelectable(_ node: LevelNode) -> Bool {
        !isReadOnlyDisplayOverlay(node)
    }

    private func marqueeSelectionID(for node: LevelNode) -> LevelNode.ID {
        if drilledNodeID == node.id {
            return node.id
        }
        if node.metadata.visualType == "RoomWeaverHelperOverlay",
           let parent = preferredParentSelection(for: node.id) {
            return parent.id
        }
        return preferredParentSelection(for: node.id)?.id ?? node.id
    }

    private func marqueeHitRect(for node: LevelNode, transform: LevelNode.Transform) -> CGRect {
        let corners = canvasCorners(for: node, transform: transform)
        guard let minX = corners.map(\.x).min(),
              let maxX = corners.map(\.x).max(),
              let minY = corners.map(\.y).min(),
              let maxY = corners.map(\.y).max() else {
            let center = visualCanvasPoint(for: node, transform: transform)
            let size = canvasSize(for: transform)
            return CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
        }
        return CGRect(x: minX, y: minY, width: max(1, maxX - minX), height: max(1, maxY - minY))
    }

    private func selectableSceneNode(at location: CGPoint, preferParent: Bool = false) -> LevelNode? {
        for node in sortedCanvasNodes.reversed() where isMarqueeSelectable(node) {
            guard let transform = node.transform else { continue }
            if hitTest(location: location, node: node, transform: transform) {
                if preferParent, let parent = preferredParentSelection(for: node.id) {
                    return parent
                }
                return node
            }
        }
        return nil
    }

    private func snapVectorValue(_ value: Int, step: Int = 10) -> Int {
        guard snapToGrid else { return value }
        return Int((Double(value) / Double(step)).rounded()) * step
    }

    private func visualOffset(for node: LevelNode, transform: LevelNode.Transform) -> CGPoint {
        guard node.metadata.visualOffsetX != 0 || node.metadata.visualOffsetY != 0 else {
            return .zero
        }
        let offset = node.metadata.visualType == "RoomWeaverLibraryReference"
            ? LevelDocument.libraryArtworkOffset(for: node, transform: transform)
            : CGPoint(x: node.metadata.visualOffsetX, y: node.metadata.visualOffsetY)
        return CGPoint(x: offset.x / vectorUnitsPerCanvasPoint * zoom,
                       y: offset.y / vectorUnitsPerCanvasPoint * zoom)
    }

    private func resizeHandlePosition(for node: LevelNode, transform: LevelNode.Transform, handle: CanvasHandle) -> CGPoint {
        let center = selectionCanvasPoint(for: node, transform: transform)
        let size = canvasSize(for: transform)
        let halfW = size.width / 2
        let halfH = size.height / 2

        let unrotated: CGPoint
        switch handle {
        case .topLeft:
            unrotated = CGPoint(x: center.x - halfW, y: center.y - halfH)
        case .top:
            unrotated = CGPoint(x: center.x, y: center.y - halfH)
        case .topRight:
            unrotated = CGPoint(x: center.x + halfW, y: center.y - halfH)
        case .left:
            unrotated = CGPoint(x: center.x - halfW, y: center.y)
        case .right:
            unrotated = CGPoint(x: center.x + halfW, y: center.y)
        case .bottomLeft:
            unrotated = CGPoint(x: center.x - halfW, y: center.y + halfH)
        case .bottom:
            unrotated = CGPoint(x: center.x, y: center.y + halfH)
        case .bottomRight:
            unrotated = CGPoint(x: center.x + halfW, y: center.y + halfH)
        }

        return rotate(point: unrotated, around: center, degrees: transform.rotation)
    }

    private func rotationHandlePosition(for node: LevelNode, transform: LevelNode.Transform, forceRectOrigin: Bool = false) -> CGPoint {
        let center = selectionCanvasPoint(for: node, transform: transform, forceRectOrigin: forceRectOrigin)
        let size = canvasSize(for: transform)
        let unrotated = CGPoint(x: center.x, y: center.y - size.height / 2 - 26)
        return rotate(point: unrotated, around: center, degrees: transform.rotation)
    }

    private func selectionHandleContains(_ point: CGPoint) -> Bool {
        guard let node = displaySelectedNode(from: sortedCanvasNodes), let model = node.transform else { return false }
        let base = node.metadata.visualType == "RoomWeaverDynamicSelectionGroup"
            ? model : CanvasInteractionPolicy.selectionTransform(model: model, displayed: displayedTransform(for: node.id))
        let isGroup = document.movableSelectedNodeIDs.count > 1
        let angle = document.commonMovableSelectionRotation() ?? 0
        let frame = isGroup
            ? (document.selectedBounds(alignedTo: angle) ?? document.selectedBounds() ?? base) : base
        let local = localCanvasLocation(point)
        if CanvasTransformHandlePolicy.canRotate(isTrap: TrapCatalog.isTrap(node),
            isAffineImportedPreview: node.metadata.visualType == "RoomWeaverAffinePreview"),
           CanvasHandleHitPolicy.contains(point: local,
            center: rotationHandlePosition(for: node, transform: withRotation(frame, isGroup ? angle : frame.rotation),
                forceRectOrigin: isGroup), diameter: 36) {
            return true
        }
        if !isGroup, CanvasTransformHandlePolicy.canResize(hasChildren: !node.children.isEmpty,
            isAffineImportedPreview: node.metadata.visualType == "RoomWeaverAffinePreview") {
            return CanvasHandle.resizeCases.contains { handle in
                CanvasHandleHitPolicy.contains(point: local,
                    center: resizeHandlePosition(for: node, transform: frame, handle: handle), diameter: 32)
            }
        }
        return false
    }

    private func rotationCanvasPoint(for node: LevelNode, transform: LevelNode.Transform, forceRectOrigin: Bool) -> CGPoint {
        selectionCanvasPoint(for: node, transform: transform, forceRectOrigin: forceRectOrigin)
    }

    private func liveRotationCanvasPoint(for node: LevelNode, baseline: LevelNode.Transform) -> CGPoint? {
        guard isRotatingSelection, let pivot = rotationHandleStartCenter else { return nil }
        let owners = [node.id] + node.metadata.roomWeaverDynamicOwnerIDs
            + [node.metadata.roomWeaverVisualOwnerID, node.metadata.roomWeaverDynamicOwnerID].compactMap { $0 }
        guard let owner = owners.first(where: { rotationOriginTransforms[$0] != nil && rotationPreviewTransforms[$0] != nil }),
              let origin = rotationOriginTransforms[owner], let preview = rotationPreviewTransforms[owner] else { return nil }
        // Keep the live orbit fractional. Integer XML coordinates are committed
        // separately; magnifying their rounding here makes the artwork jitter.
        return CanvasRotationPreviewPolicy.rotatedPoint(visualCanvasPoint(for: node, transform: baseline),
            around: pivot, degrees: preview.rotation - origin.rotation)
    }

    private func rotationCenterPoint(for node: LevelNode, transform: LevelNode.Transform, forceRectOrigin: Bool) -> CGPoint {
        if forceRectOrigin {
            return CGPoint(x: CGFloat(transform.x) + CGFloat(transform.width) / 2, y: CGFloat(transform.y) + CGFloat(transform.height) / 2)
        }
        let centered = visualCenterTransform(for: node, transform: transform)
        return CGPoint(x: centered.x, y: centered.y)
    }

    private func documentPoint(from location: CGPoint) -> (x: Int, y: Int) {
        let localX = (location.x - panOffset.width) / zoom
        let localY = (location.y - panOffset.height) / zoom
        let x = Int(((localX - canvasOrigin.x) * vectorUnitsPerCanvasPoint).rounded())
        let y = Int(((localY - canvasOrigin.y) * vectorUnitsPerCanvasPoint).rounded())
        return (x, y)
    }

    private func sceneNode(at location: CGPoint, preferParent: Bool = false) -> LevelNode? {
        for node in sortedCanvasNodes.reversed() {
            guard !isReadOnlyDisplayOverlay(node) else { continue }
            guard document.roomLayoutIsInteractable(node, guidesVisible: showRoomLayoutGuides) else { continue }
            guard let transform = node.transform else { continue }
            if hitTest(location: location, node: node, transform: transform) {
                if preferParent, let parent = preferredParentSelection(for: node.id) {
                    return parent
                }
                return node
            }
        }
        return nil
    }

    private func preferredParentSelection(for nodeID: LevelNode.ID) -> LevelNode? {
        if let roomWeaverParent = document.root.localRoomWeaverParent(for: nodeID),
           roomWeaverParent.kind != .document,
           roomWeaverParent.kind != .track,
           roomWeaverParent.kind != .factor {
            return roomWeaverParent
        }
        return parentNode(for: nodeID, in: document.root)
    }

    private func parentNode(for nodeID: LevelNode.ID, in root: LevelNode) -> LevelNode? {
        for child in root.children {
            if child.id == nodeID {
                return root.kind == .document || root.kind == .track || root.kind == .factor ? nil : root
            }
            if let parent = parentNode(for: nodeID, in: child) {
                return parent
            }
        }
        return nil
    }

    private func canvasSortKey(for node: LevelNode) -> (layer: Int, factor: Int, name: String) {
        let layerName = shouldDrawAsEditorHelperOverlay(node)
            ? "Debug"
            : editorPreviewSortingLayer(for: node)
        let layer = Vector2SortingLayers.index(of: layerName)
        var factor = Int(node.factor) ?? 0
        if node.kind == .trapezoid {
            // Trapezoids are collision visuals like platforms, but their editor
            // texture needs to sit above same-layer platform fills so the slope
            // shape stays readable while editing. This is draw-order only; XML
            // export still uses the real Factor value.
            factor += 1
        }
        return (layer, factor, node.name)
    }

    private func editorPreviewSortingLayer(for node: LevelNode) -> String {
        if shouldPreviewAsWallStructureDecal(node) {
            return "Wall"
        }
        if shouldPreviewNearCAperture(node) {
            return "CAperture"
        }
        return node.metadata.sortingLayer
    }

    private func shouldDrawAsEditorHelperOverlay(_ node: LevelNode) -> Bool {
        // Imported triggers/areas are editing handles first. Keep them visible
        // over dense library art without changing the XML layer they export as.
        node.kind == .trigger || node.kind == .area || node.kind == .comment
    }

    private func shouldPreviewNearCAperture(_ node: LevelNode) -> Bool {
        // Editor-only layering nudge: wall-prop pieces preview around CAperture
        // so platforms and collision stay readable. Fans are excluded because
        // their art belongs behind wall/c-aperture foreground pieces.
        guard node.kind == .image || !node.metadata.imagePath.isEmpty else { return false }
        let combined = [
            node.name,
            node.metadata.className,
            node.metadata.imagePath,
            node.metadata.filename,
            node.xml.choice,
            node.xml.variant
        ]
        .joined(separator: " ")
        .replacingOccurrences(of: "__", with: ".")
        .replacingOccurrences(of: "-", with: "_")
        .lowercased()

        if combined.contains("ventilator") ||
            combined.contains(".v_fan") ||
            combined.contains("v_fan") ||
            combined.contains("_fan") ||
            combined.contains(".fan") ||
            combined.contains(" fan") {
            return false
        }

        return combined.contains("wall_props") ||
        combined.contains("z2_wall_props") ||
        combined.contains("walls.")
    }

    private func shouldPreviewAsWallStructureDecal(_ node: LevelNode) -> Bool {
        // Some zone2 structural strips are tagged as CDecals in XML, but in-game
        // they sit visually behind shaft/wall prop assemblies. Keep this as
        // editor draw-order only so exported XML still preserves the real layer.
        guard node.kind == .image,
              node.metadata.sortingLayer == "CDecals" else {
            return false
        }
        let className = node.metadata.className
            .replacingOccurrences(of: "__", with: ".")
            .lowercased()
        return className.hasPrefix("zone2.light_panel")
            || className.hasPrefix("zone2.trough")
            || className.hasPrefix("walls.recessed_panel_edge")
    }

    private func hitTest(location: CGPoint, node: LevelNode, transform: LevelNode.Transform) -> Bool {
        let location = localCanvasLocation(location)
        let center = visualCanvasPoint(for: node, transform: transform)
        let size = canvasSize(for: transform)
        let local = unrotate(point: location, around: center, degrees: transform.rotation)
        let rect = CGRect(
            x: center.x - size.width / 2,
            y: center.y - size.height / 2,
            width: size.width,
            height: size.height
        )
        return rect.contains(local)
    }

    private func rotate(point: CGPoint, around center: CGPoint, degrees: Double) -> CGPoint {
        let radians = degrees * .pi / 180
        let translatedX = point.x - center.x
        let translatedY = point.y - center.y
        let cosine = CGFloat(Foundation.cos(radians))
        let sine = CGFloat(Foundation.sin(radians))
        let rotatedX = translatedX * cosine - translatedY * sine
        let rotatedY = translatedX * sine + translatedY * cosine
        return CGPoint(x: center.x + rotatedX, y: center.y + rotatedY)
    }

    private func unrotate(point: CGPoint, around center: CGPoint, degrees: Double) -> CGPoint {
        rotate(point: point, around: center, degrees: -degrees)
    }

    private func rotateVector(_ vector: CGPoint, degrees: Double) -> CGPoint {
        let radians = degrees * .pi / 180
        let cosine = CGFloat(Foundation.cos(radians))
        let sine = CGFloat(Foundation.sin(radians))
        return CGPoint(
            x: vector.x * cosine - vector.y * sine,
            y: vector.x * sine + vector.y * cosine
        )
    }

    private func clearKeyboardFocus() {
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    private func displayNodes(from node: LevelNode) -> [LevelNode] {
        // Flattens the hierarchy into what the canvas should draw. This is where
        // hidden editor internals, drill-down behavior, runtime graph wrappers,
        // and child trigger overlays are reconciled.
        if node.metadata.isHidden {
            return []
        }

        if node.metadata.visualType == "RoomWeaverUnresolvedImage" {
            return []
        }

        if node.kind == .document || node.kind == .track || node.kind == .factor {
            return node.children.flatMap(displayNodes)
        }

        if drilledNodeID == node.id, canDrillInto(node) {
            return node.children.flatMap(displayNodes)
        }

        if isRoomWeaverVisualContainer(node) {
            return roomWeaverDisplayChildren(from: node, context: roomWeaverContext(for: node, under: .identity))
        }

        if node.metadata.visualType == "RoomLayoutSharedGroup" {
            return node.children.flatMap(displayNodes).map { source in
                var display = source
                display.xml.choice = node.xml.choice
                display.xml.variant = node.xml.variant
                display.xml.parentChoice = node.xml.parentChoice
                display.xml.additionalSelections = node.xml.additionalSelections
                display.metadata.roomLayoutSharedOwnerID = node.id
                return display
            }
        }

        if node.rendersAsRuntimeGraph {
            if let visualShell = shapeOnlyWrapperDisplayNode(for: node) {
                return [visualShell]
            }
            let attachedChildren = hierarchyAttachmentDisplayNodes(from: node)
            if shouldRenderOnlyBakedPreview(for: node) {
                return [node] + attachedChildren
            }
            if node.transform != nil && (!node.metadata.imagePath.isEmpty || !renderablePreviewPieces(for: node).isEmpty) {
                return [node] + visibleChildShapeOverlays(from: node) + attachedChildren
            }
            return node.children.flatMap(displayNodes)
        }

        if node.transform != nil {
            if let visualShell = shapeOnlyWrapperDisplayNode(for: node) {
                return [visualShell]
            }
            let attachedChildren = hierarchyAttachmentDisplayNodes(from: node)
            if shouldRenderOnlyBakedPreview(for: node) {
                return [node] + attachedChildren
            }
            if !node.children.isEmpty && node.metadata.imagePath.isEmpty && renderablePreviewPieces(for: node).isEmpty {
                return [node] + visibleChildShapeOverlays(from: node) + attachedChildren
            }
            return [node] + visibleChildShapeOverlays(from: node) + attachedChildren
        }

        return node.children.flatMap(displayNodes)
    }

    private func visibleChildShapeOverlays(from node: LevelNode) -> [LevelNode] {
        // Expanding every helper inside every imported reference creates
        // thousands of extra SwiftUI views in large stock rooms. Keep the
        // reconstructed object visible, but reveal its helper geometry only
        // when explicitly requested or while that reference is being edited.
        guard showLibraryHelperOverlays || document.selectedNodeIDs.contains(node.id) || drilledNodeID == node.id else {
            return []
        }
        return childShapeOverlays(from: node)
    }

    private func isRoomWeaverVisualContainer(_ node: LevelNode) -> Bool {
        node.metadata.visualType == "RoomWeaverContainer"
    }

    private struct RoomWeaverAffine {
        var x: Double
        var y: Double
        var xx: Double
        var xy: Double
        var yx: Double
        var yy: Double

        static let identity = RoomWeaverAffine(x: 0, y: 0, xx: 1, xy: 0, yx: 0, yy: 1)

        func point(_ localX: Double, _ localY: Double) -> CGPoint {
            CGPoint(x: x + localX * xx + localY * yx, y: y + localX * xy + localY * yy)
        }

        func vector(_ localX: Double, _ localY: Double) -> CGPoint {
            CGPoint(x: localX * xx + localY * yx, y: localX * xy + localY * yy)
        }
    }

    private func roomWeaverContext(for node: LevelNode, under parent: RoomWeaverAffine) -> RoomWeaverAffine {
        let transform = node.transform ?? .init(x: 0, y: 0, width: 1, height: 1)
        let origin = parent.point(Double(transform.x), Double(transform.y))
        let local: (Double, Double, Double, Double)
        if let basis = LevelDocument.roomWeaverAffineBasis(for: node) {
            local = (basis.a, basis.b, basis.c, basis.d)
        } else {
            let radians = transform.rotation * .pi / 180
            local = (cos(radians), sin(radians), -sin(radians), cos(radians))
        }
        return RoomWeaverAffine(
            x: origin.x, y: origin.y,
            xx: parent.xx * local.0 + parent.yx * local.1,
            xy: parent.xy * local.0 + parent.yy * local.1,
            yx: parent.xx * local.2 + parent.yx * local.3,
            yy: parent.xy * local.2 + parent.yy * local.3
        )
    }

    private func roomWeaverDisplayChildren(from node: LevelNode, context: RoomWeaverAffine) -> [LevelNode] {
        node.children.flatMap { child -> [LevelNode] in
            // Hierarchy drag/drop keeps attached nodes in canvas coordinates so
            // export can localize them once. Applying the imported parent's
            // affine here localized them a second time and made grouped floors,
            // Areas and Triggers vanish from the canvas.
            if !RoomWeaverAttachmentPolicy.usesParentAffine(
                isHierarchyAttachment: child.metadata.isHierarchyAttachment
            ) {
                return displayNodes(from: child)
            }
            var stackedChild = child
            if child.kind == .image,
               let exactImage = roomWeaverImageDisplayNode(child, under: context) {
                stackedChild = exactImage
            } else {
                let exactReferences = roomWeaverReferenceDisplayNodes(child, under: context)
                if !exactReferences.isEmpty {
                    var nodes = exactReferences
                    if showLibraryHelperOverlays || document.selectedNodeIDs.contains(child.id) || drilledNodeID == child.id {
                        nodes.append(contentsOf: roomWeaverReferenceShapeOverlays(child, under: context))
                    }
                    let dynamicXML = child.metadata.dynamicXML
                    let ownsSpatialDynamic = dynamicXML.contains("<MoveInterval")
                        || dynamicXML.contains("<RotationInterval")
                        || dynamicXML.contains("<SizeInterval")
                    if ownsSpatialDynamic {
                        for index in nodes.indices {
                            nodes[index].metadata.roomWeaverDynamicOwnerID = child.id
                            if !nodes[index].metadata.roomWeaverDynamicOwnerIDs.contains(child.id) {
                                nodes[index].metadata.roomWeaverDynamicOwnerIDs.append(child.id)
                            }
                        }
                    }
                    return nodes
                }
                if let childTransform = child.transform {
                var parent = node
                parent.transform = .init(x: Int(context.x.rounded()), y: Int(context.y.rounded()), width: 1, height: 1)
                parent.metadata.visualType = "RoomWeaverContainer"
                parent.metadata.matrixA = String(context.xx)
                parent.metadata.matrixB = String(context.xy)
                parent.metadata.matrixC = String(context.yx)
                parent.metadata.matrixD = String(context.yy)
                parent.metadata.isTransformEdited = false
                let visualOffset = context.vector(
                    Double(child.metadata.visualOffsetX),
                    Double(child.metadata.visualOffsetY)
                )
                stackedChild.transform = LevelDocument.displayTransform(
                    fromLocalTransform: childTransform, under: parent,
                    usesRectOrigin: child.kind.usesVectorRectOrigin
                )
                // Library previews are anchored by an offset from the XML
                // object's origin to the reconstructed sprite bounds. That
                // offset lives in the same local space as the object and must
                // follow every parent matrix too. Leaving it untouched made
                // correctly exported references appear displaced only in the
                // editor, especially inside rotated room groups.
                stackedChild.metadata.visualOffsetX = Int(visualOffset.x.rounded())
                stackedChild.metadata.visualOffsetY = Int(visualOffset.y.rounded())
                }
            }

            if isRoomWeaverVisualContainer(child) {
                var descendants = roomWeaverDisplayChildren(
                    from: child,
                    context: roomWeaverContext(for: child, under: context)
                )
                let dynamicXML = child.metadata.dynamicXML
                let ownsSpatialDynamic = dynamicXML.contains("<MoveInterval")
                    || dynamicXML.contains("<RotationInterval")
                    || dynamicXML.contains("<SizeInterval")
                // RoomWeaver containers are deliberately flattened out of the
                // canvas. Their Dynamic block still owns the assembled visible
                // descendants, though. Preserve that ownership on exactly one
                // display node so the assembly gets one badge instead of either
                // losing it or marking every image/light layer as dynamic.
                if ownsSpatialDynamic, !descendants.isEmpty {
                    for index in descendants.indices {
                        descendants[index].metadata.roomWeaverDynamicOwnerID = child.id
                        if !descendants[index].metadata.roomWeaverDynamicOwnerIDs.contains(child.id) {
                            descendants[index].metadata.roomWeaverDynamicOwnerIDs.append(child.id)
                        }
                    }
                    descendants[0].metadata.resolvedDynamicCount += 1
                    let owners = descendants[0].metadata.resolvedDynamicOwners
                        .split(separator: ",")
                        .map { String($0).trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    if !owners.contains(child.name) {
                        descendants[0].metadata.resolvedDynamicOwners = (owners + [child.name]).joined(separator: ", ")
                    }
                }
                return descendants
            }

            return displayNodes(from: stackedChild)
        }
    }

    private func interactionNodeID(for node: LevelNode) -> LevelNode.ID {
        node.metadata.roomLayoutSharedOwnerID
            ?? node.metadata.roomWeaverDynamicOwnerID
            ?? node.metadata.roomWeaverVisualOwnerID
            ?? node.id
    }

    private func ownedVisualDragPreviewTransform(
        for node: LevelNode,
        baseTransform: LevelNode.Transform
    ) -> LevelNode.Transform? {
        guard dragOriginTransform != nil,
              let ownerID = node.metadata.roomWeaverVisualOwnerID,
              dragOriginPrimaryID == ownerID ||
                dragPreviewMovedIDs.contains(ownerID) else { return nil }
        // Every sorting-layer slice carries the same visual owner. Apply the
        // frozen drag delta to all of them—including the primary slice—so a
        // multi-piece reference moves as one assembly during the gesture, not
        // only after the model commit rebuilds the display cache.
        return .init(
            x: baseTransform.x + dragPreviewDeltaX,
            y: baseTransform.y + dragPreviewDeltaY,
            width: baseTransform.width,
            height: baseTransform.height,
            rotation: baseTransform.rotation
        )
    }

    private func ownedRotationPreviewTransform(for node: LevelNode,
                                               baseTransform: LevelNode.Transform) -> LevelNode.Transform? {
        var result = baseTransform
        var changed = false
        // Preserve nested ownership order rather than a Set's iteration order.
        let ordered = node.metadata.roomWeaverDynamicOwnerIDs
            + [node.metadata.roomWeaverVisualOwnerID, node.metadata.roomWeaverDynamicOwnerID].compactMap { $0 }
        var visited: Set<LevelNode.ID> = []
        for owner in ordered where visited.insert(owner).inserted {
            guard let origin = rotationOriginTransforms[owner], let preview = rotationPreviewTransforms[owner],
                  let source = document.root.find(id: owner) else { continue }
            result = LevelDocument.projectVisualEdit(result, usesRectOrigin: node.kind.usesVectorRectOrigin,
                from: origin, to: preview, ownerUsesRectOrigin: source.kind.usesVectorRectOrigin)
            changed = true
        }
        return changed ? result : nil
    }

    private func groupedDynamicPreviewTransform(
        for node: LevelNode,
        baseTransform: LevelNode.Transform
    ) -> LevelNode.Transform? {
        let ownerIDs = node.metadata.roomWeaverDynamicOwnerIDs.isEmpty
            ? node.metadata.roomWeaverDynamicOwnerID.map { [$0] } ?? []
            : node.metadata.roomWeaverDynamicOwnerIDs
        let activeOwners = ownerIDs.compactMap { ownerID -> (LevelNode.Transform, LevelNode.Transform)? in
            guard let preview = dynamicLivePreviewTransforms[ownerID],
                  let base = cachedDynamicSourceTransforms[ownerID] else { return nil }
            return (base, preview)
        }
        guard !activeOwners.isEmpty else { return nil }

        // Owner IDs are accumulated while RoomWeaver flattens from the deepest
        // visual container outward. Apply them in that same inner-to-outer order:
        // a head moves in its local manipulator first, then the parent rotation /
        // translation carries the already-moved head. Selecting only one owner
        // made synchronized multi-state assemblies visibly break into pieces.
        let centered = visualCenterTransform(for: node, transform: baseTransform)
        var centerX = Double(centered.x)
        var centerY = Double(centered.y)
        var width = Double(baseTransform.width)
        var height = Double(baseTransform.height)
        var rotation = baseTransform.rotation
        for (base, preview) in activeOwners {
            let scaleX = Double(preview.width) / Double(max(1, base.width))
            let scaleY = Double(preview.height) / Double(max(1, base.height))
            let angleDegrees = preview.rotation - base.rotation
            let angle = angleDegrees * .pi / 180
            let cosine = cos(angle)
            let sine = sin(angle)
            let relativeX = (centerX - Double(base.x)) * scaleX
            let relativeY = (centerY - Double(base.y)) * scaleY
            centerX = Double(preview.x) + relativeX * cosine - relativeY * sine
            centerY = Double(preview.y) + relativeX * sine + relativeY * cosine
            width *= abs(scaleX)
            height *= abs(scaleY)
            rotation += angleDegrees
        }
        let resolvedWidth = max(1, Int(width.rounded()))
        let resolvedHeight = max(1, Int(height.rounded()))
        return .init(
            x: Int(centerX.rounded()) - (node.kind.usesVectorRectOrigin ? resolvedWidth / 2 : 0),
            y: Int(centerY.rounded()) - (node.kind.usesVectorRectOrigin ? resolvedHeight / 2 : 0),
            width: resolvedWidth,
            height: resolvedHeight,
            rotation: rotation
        )
    }

    private func liveDynamicPreviewTransform(
        for node: LevelNode,
        baseTransform: LevelNode.Transform
    ) -> LevelNode.Transform? {
        affineReferenceDynamicPreviewTransform(for: node, baseTransform: baseTransform)
            ?? dynamicLivePreviewTransforms[node.id]
            ?? groupedDynamicPreviewTransform(for: node, baseTransform: baseTransform)
    }

    private func affineReferenceDynamicPreviewTransform(
        for node: LevelNode,
        baseTransform: LevelNode.Transform
    ) -> LevelNode.Transform? {
        guard node.metadata.visualType == "RoomWeaverAffinePreview",
              let preview = dynamicLivePreviewTransforms[node.id],
              let source = document.root.find(id: node.id),
              let sourceLocal = source.transform else { return nil }
        let sourceBase = document.root.canvasTransform(for: node.id, localTransform: sourceLocal)
        return .init(
            x: baseTransform.x + preview.x - sourceBase.x,
            y: baseTransform.y + preview.y - sourceBase.y,
            width: max(1, Int((Double(baseTransform.width) * Double(preview.width) / Double(max(1, sourceBase.width))).rounded())),
            height: max(1, Int((Double(baseTransform.height) * Double(preview.height) / Double(max(1, sourceBase.height))).rounded())),
            rotation: baseTransform.rotation + preview.rotation - sourceBase.rotation
        )
    }

    private func roomWeaverReferenceShapeOverlays(
        _ reference: LevelNode,
        under context: RoomWeaverAffine
    ) -> [LevelNode] {
        guard let referenceTransform = reference.transform else { return [] }

        func collect(_ node: LevelNode, offsetX: Double, offsetY: Double) -> [LevelNode] {
            node.children.flatMap { child -> [LevelNode] in
                guard !child.metadata.isHidden,
                      !child.metadata.isHierarchyAttachment else { return [] }

                var result: [LevelNode] = []
                if let transform = child.transform {
                    let localX = offsetX + Double(transform.x)
                    let localY = offsetY + Double(transform.y)
                    let radians = transform.rotation * .pi / 180
                    let localBasisX = CGPoint(
                        x: cos(radians) * Double(transform.width),
                        y: sin(radians) * Double(transform.width)
                    )
                    let localBasisY = CGPoint(
                        x: -sin(radians) * Double(transform.height),
                        y: cos(radians) * Double(transform.height)
                    )
                    let basisX = context.vector(localBasisX.x, localBasisX.y)
                    let basisY = context.vector(localBasisY.x, localBasisY.y)
                    let visualOffset = context.vector(
                        Double(child.metadata.visualOffsetX),
                        Double(child.metadata.visualOffsetY)
                    )
                    let rawOrigin = context.point(localX, localY)
                    let origin = CGPoint(
                        x: rawOrigin.x + visualOffset.x,
                        y: rawOrigin.y + visualOffset.y
                    )
                    let center = CGPoint(
                        x: origin.x + (basisX.x + basisY.x) / 2,
                        y: origin.y + (basisX.y + basisY.y) / 2
                    )
                    let width = max(1, Int(hypot(basisX.x, basisX.y).rounded()))
                    let height = max(1, Int(hypot(basisY.x, basisY.y).rounded()))

                    if child.kind == .trigger || child.kind == .area || child.kind == .platform || child.kind == .trapezoid {
                        var overlay = child
                        overlay.transform = .init(
                            x: Int((center.x - Double(width) / 2).rounded()),
                            y: Int((center.y - Double(height) / 2).rounded()),
                            width: width,
                            height: height,
                            rotation: atan2(basisX.y, basisX.x) * 180 / .pi
                        )
                        overlay.metadata.sortingLayer = "Debug"
                        overlay.metadata.visualType = "RoomWeaverHelperOverlay"
                        result.append(overlay)
                    }

                    result.append(contentsOf: collect(child, offsetX: localX, offsetY: localY))
                } else {
                    result.append(contentsOf: collect(child, offsetX: offsetX, offsetY: offsetY))
                }
                return result
            }
        }

        return collect(
            reference,
            offsetX: Double(referenceTransform.x),
            offsetY: Double(referenceTransform.y)
        )
    }

    private func roomWeaverReferenceDisplayNodes(_ node: LevelNode, under context: RoomWeaverAffine) -> [LevelNode] {
        guard node.metadata.visualType == "RoomWeaverLibraryReference",
              let transform = node.transform,
              !node.previewPieces.isEmpty else { return [] }

        // Pieces already contain the import matrix, but not subsequent edits.
        // Apply the editable reference transform before its room parent.
        let scaleX = Double(transform.width) / Double(max(1, node.metadata.visualNativeWidth))
        let scaleY = Double(transform.height) / Double(max(1, node.metadata.visualNativeHeight))
        let angle = transform.rotation * .pi / 180
        func editedVector(_ x: Double, _ y: Double) -> CGPoint {
            let sx = x * scaleX
            let sy = y * scaleY
            return CGPoint(x: sx * cos(angle) - sy * sin(angle),
                           y: sx * sin(angle) + sy * cos(angle))
        }
        let offset = LevelDocument.libraryArtworkOffset(for: node, transform: transform)
        let localGroupCenter = CGPoint(x: Double(transform.x) + offset.x,
                                       y: Double(transform.y) + offset.y)

        func transformedPiece(_ piece: LevelNode.PreviewPiece) -> LevelNode.PreviewPiece {
            if let xx = piece.basisXX, let xy = piece.basisXY,
               let yx = piece.basisYX, let yy = piece.basisYY {
                let center = editedVector(piece.centerX, piece.centerY)
                let origin = context.point(localGroupCenter.x + center.x, localGroupCenter.y + center.y)
                let editedX = editedVector(xx, xy)
                let editedY = editedVector(yx, yy)
                let axisX = context.vector(editedX.x, editedX.y)
                let axisY = context.vector(editedY.x, editedY.y)
                return .init(
                    imagePath: piece.imagePath,
                    centerX: origin.x,
                    centerY: origin.y,
                    width: hypot(axisX.x, axisX.y),
                    height: hypot(axisY.x, axisY.y),
                    rotation: 0,
                    mirrored: piece.mirrored,
                    basisXX: axisX.x,
                    basisXY: axisX.y,
                    basisYX: axisY.x,
                    basisYY: axisY.y,
                    tintColorHex: piece.tintColorHex,
                    sortingLayer: piece.sortingLayer
                )
            }

            let radians = piece.rotation * .pi / 180
            let center = editedVector(piece.centerX, piece.centerY)
            let localCenter = context.point(localGroupCenter.x + center.x, localGroupCenter.y + center.y)
            let editedX = editedVector(cos(radians) * piece.width, sin(radians) * piece.width)
            let editedY = editedVector(-sin(radians) * piece.height, cos(radians) * piece.height)
            let axisX = context.vector(editedX.x, editedX.y)
            let axisY = context.vector(editedY.x, editedY.y)
            return .init(
                imagePath: piece.imagePath,
                centerX: localCenter.x,
                centerY: localCenter.y,
                width: hypot(axisX.x, axisX.y),
                height: hypot(axisY.x, axisY.y),
                rotation: 0,
                mirrored: piece.mirrored,
                basisXX: axisX.x,
                basisXY: axisX.y,
                basisYX: axisY.x,
                basisYY: axisY.y,
                tintColorHex: piece.tintColorHex,
                sortingLayer: piece.sortingLayer
            )
        }

        func bounds(of pieces: [LevelNode.PreviewPiece]) -> CGRect {
            let points = pieces.flatMap { piece -> [CGPoint] in
                guard let xx = piece.basisXX, let xy = piece.basisXY,
                      let yx = piece.basisYX, let yy = piece.basisYY else {
                    return [CGPoint(x: piece.centerX, y: piece.centerY)]
                }
                let origin = CGPoint(x: piece.centerX, y: piece.centerY)
                return [
                    origin,
                    CGPoint(x: origin.x + xx, y: origin.y + xy),
                    CGPoint(x: origin.x + xx + yx, y: origin.y + xy + yy),
                    CGPoint(x: origin.x + yx, y: origin.y + yy)
                ]
            }
            guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
                  let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else {
                return CGRect(x: localGroupCenter.x, y: localGroupCenter.y, width: 1, height: 1)
            }
            return CGRect(x: minX, y: minY, width: max(1, maxX - minX), height: max(1, maxY - minY))
        }

        let worldPieces = node.previewPieces.map(transformedPiece)
        let grouped = Dictionary(grouping: worldPieces) {
            $0.sortingLayer.isEmpty ? "Default" : $0.sortingLayer
        }
        let orderedLayers = grouped.keys.sorted {
            Vector2SortingLayers.index(of: $0) < Vector2SortingLayers.index(of: $1)
        }

        return orderedLayers.enumerated().compactMap { index, layer -> LevelNode? in
            guard let pieces = grouped[layer], !pieces.isEmpty else { return nil }
            let frame = bounds(of: pieces)
            let frameCenter = CGPoint(x: frame.midX, y: frame.midY)
            let relativePieces = pieces.map { piece -> LevelNode.PreviewPiece in
                var adjusted = piece
                adjusted.centerX -= frameCenter.x
                adjusted.centerY -= frameCenter.y
                return adjusted
            }

            var metadata = node.metadata
            metadata.roomWeaverVisualOwnerID = node.id
            metadata.imagePath = ""
            metadata.visualOffsetX = 0
            metadata.visualOffsetY = 0
            metadata.sortingLayer = layer
            metadata.visualType = "RoomWeaverAffinePreview"
            metadata.isVisualOnlyLayer = index > 0
            if index > 0 {
                // Sorting-layer slices are visual fragments of one reference,
                // not independent dynamic objects. Retaining the source metadata
                // here put DYNAMIC badges on its Lights/LightsAdd fragments.
                metadata.dynamicXML = ""
                metadata.resolvedDynamicCount = 0
                metadata.resolvedDynamicOwners = ""
            }

            if index == 0 {
                var display = node
                display.transform = .init(
                    x: Int(frameCenter.x.rounded()), y: Int(frameCenter.y.rounded()),
                    width: max(1, Int(frame.width.rounded(.up))),
                    height: max(1, Int(frame.height.rounded(.up))), rotation: 0
                )
                display.metadata = metadata
                display.previewPieces = relativePieces
                return display
            }

            return LevelNode(
                name: "\(node.name) [\(layer)]",
                kind: node.kind,
                factor: node.factor,
                transform: .init(
                    x: Int(frameCenter.x.rounded()), y: Int(frameCenter.y.rounded()),
                    width: max(1, Int(frame.width.rounded(.up))),
                    height: max(1, Int(frame.height.rounded(.up))), rotation: 0
                ),
                xml: node.xml,
                metadata: metadata,
                previewPieces: relativePieces
            )
        }
    }

    private func roomWeaverImageDisplayNode(_ node: LevelNode, under context: RoomWeaverAffine) -> LevelNode? {
        // The source matrix is the authoritative import-time preview only.
        // Once the user moves/resizes/rotates this image, Exporter deliberately
        // switches to the editable transform; the canvas must do the same or
        // the art appears frozen while its selection/data moves away.
        guard !node.metadata.isTransformEdited,
              let sourceX = Double(node.metadata.sourceX),
              let sourceY = Double(node.metadata.sourceY),
              let a = Double(node.metadata.matrixA),
              let b = Double(node.metadata.matrixB),
              let c = Double(node.metadata.matrixC),
              let d = Double(node.metadata.matrixD) else { return nil }
        let tx = Double(node.metadata.matrixTx) ?? 0
        let ty = Double(node.metadata.matrixTy) ?? 0
        let origin = context.point(sourceX + tx, sourceY + ty)
        let basisX = context.vector(a, b)
        let basisY = context.vector(c, d)
        // Use the source matrix for every imported matrix image, including
        // ordinary rotations, flips, and non-uniform scale. The previous code
        // only did this for skew, then rendered all orthogonal matrices from an
        // axis-aligned bounding box. In nested room groups that discarded the
        // image's actual basis and produced the broken stock-room layout.
        let editable = ImportedAffineRectPolicy.editableRect(
            x: origin.x, y: origin.y,
            a: basisX.x, b: basisX.y,
            c: basisY.x, d: basisY.y,
            tx: 0, ty: 0
        )
        guard let originalPath = Vector2AssetCatalog.imagePath(forClassName: node.metadata.className) else { return nil }

        var display = node
        display.transform = .init(
            x: editable.x, y: editable.y,
            width: editable.width, height: editable.height,
            rotation: editable.rotation
        )
        display.metadata.imagePath = ""
        display.metadata.visualType = "RoomWeaverAffinePreview"
        display.metadata.isMirrored = false
        display.metadata.isFlippedVertically = false
        display.previewPieces = [
            .init(
                imagePath: originalPath,
                centerX: 0,
                centerY: 0,
                width: hypot(editable.localA, editable.localB),
                height: hypot(editable.localC, editable.localD),
                rotation: 0,
                mirrored: (basisX.x * basisY.y - basisX.y * basisY.x) < 0,
                basisXX: editable.localA,
                basisXY: editable.localB,
                basisYX: editable.localC,
                basisYY: editable.localD,
                tintColorHex: node.metadata.tintColorHex
            )
        ]
        return display
    }

    private func stackedRoomWeaverTransform(
        _ child: LevelNode.Transform,
        under parentNode: LevelNode
    ) -> LevelNode.Transform {
        // Vector 2 creates a GameObject for each Object/ObjectReference wrapper,
        // then child runners inherit that local transform. RoomWeaver containers
        // are visual-only, so we compose that parent offset before drawing.
        guard let parent = parentNode.transform else { return child }
        if let a = Double(parentNode.metadata.matrixA),
           let b = Double(parentNode.metadata.matrixB),
           let c = Double(parentNode.metadata.matrixC),
           let d = Double(parentNode.metadata.matrixD) {
            // Object matrices transform child-local coordinates. The previous
            // implementation retained only atan2(B,A), dropping scale, mirror,
            // and the second basis axis. That pulled nested stock-room art apart.
            let localRotation = atan2(b, a) * 180 / .pi
            let ancestorRotation = parent.rotation - localRotation
            let matrixVector = CGPoint(
                x: Double(child.x) * a + Double(child.y) * c,
                y: Double(child.x) * b + Double(child.y) * d
            )
            let worldVector = rotateVector(matrixVector, degrees: ancestorRotation)
            let scaleX = hypot(a, b)
            let scaleY = hypot(c, d)
            return .init(
                x: parent.x + Int(worldVector.x.rounded()),
                y: parent.y + Int(worldVector.y.rounded()),
                width: max(1, Int((Double(child.width) * scaleX).rounded())),
                height: max(1, Int((Double(child.height) * scaleY).rounded())),
                rotation: parent.rotation + child.rotation
            )
        }
        let rotated = rotateVector(CGPoint(x: child.x, y: child.y), degrees: parent.rotation)
        return .init(
            x: parent.x + Int(rotated.x.rounded()),
            y: parent.y + Int(rotated.y.rounded()),
            width: child.width,
            height: child.height,
            rotation: parent.rotation + child.rotation
        )
    }

    private func shouldRenderOnlyBakedPreview(for node: LevelNode) -> Bool {
        // Phantoms often have baked previews plus helper children. Drawing both
        // can double-render or stretch visuals, so baked preview wins.
        node.metadata.filename == "phantoms.xml" && !node.metadata.imagePath.isEmpty
    }

    private func canDrillInto(_ node: LevelNode) -> Bool {
        // Double-click drill-down is only useful for real composite visuals, not
        // simple shape wrappers like WallJump's hidden trigger child.
        guard !node.children.isEmpty else { return false }
        if shapeOnlyWrapperDisplayNode(for: node) != nil {
            return false
        }
        return containsInspectableChild(in: node)
    }

    private func containsInspectableChild(in node: LevelNode) -> Bool {
        // Determines whether a parent has child visuals worth exposing on
        // double-click.
        node.children.contains { child in
            if child.metadata.isHidden {
                return false
            }
            if child.kind.isEditorShape || child.kind == .waypoint {
                return true
            }
            if child.kind == .image && (!child.metadata.imagePath.isEmpty || !child.previewPieces.isEmpty) {
                return true
            }
            if child.kind == .object || child.kind == .objectReference {
                return containsInspectableChild(in: child)
            }
            return false
        }
    }

    private func shapeOnlyWrapperDisplayNode(for node: LevelNode) -> LevelNode? {
        guard node.transform != nil,
              node.metadata.imagePath.isEmpty,
              node.previewPieces.isEmpty,
              !node.children.isEmpty else {
            return nil
        }

        let shapeChildren = node.children.filter {
            !$0.metadata.isHidden &&
            !$0.metadata.isHierarchyAttachment &&
            ($0.kind == .trigger || $0.kind == .area || $0.kind == .platform || $0.kind == .trapezoid)
        }
        guard shapeChildren.count == 1,
              let shape = shapeChildren.first,
              node.children.allSatisfy({ $0.id == shape.id || $0.metadata.isHidden }) else {
            return nil
        }

        // This is only a canvas visual shell. Keep the parent transform intact so
        // moving/resizing ObjectReference nodes still edits the XML node itself.
        var display = node
        display.kind = shape.kind
        display.name = shape.name.isEmpty ? node.name : shape.name
        display.metadata.sortingLayer = shape.metadata.sortingLayer
        display.metadata.tag = shape.metadata.tag
        display.metadata.visualOffsetX = 0
        display.metadata.visualOffsetY = 0
        return display
    }

    private func isReadOnlyDisplayOverlay(_ node: LevelNode) -> Bool {
        node.metadata.isVisualOnlyLayer ||
            (node.metadata.visualType == "RoomWeaverHelperOverlay" &&
             !document.selectedNodeIDs.contains(node.id))
    }

    private func childShapeOverlays(from node: LevelNode) -> [LevelNode] {
        // Shows child trigger/area/platform/trapezoid boxes over parent visuals
        // without making those helper nodes steal primary selection behavior.
        node.children.flatMap { child -> [LevelNode] in
            guard !child.metadata.isHidden,
                  !child.metadata.isHierarchyAttachment else { return [] }
            var overlays: [LevelNode] = []
            if child.kind == .trigger || child.kind == .area || child.kind == .platform || child.kind == .trapezoid {
                overlays.append(scaledOverlayNode(child, relativeTo: node))
            }
            overlays.append(contentsOf: childShapeOverlays(from: child).map { scaledOverlayNode($0, relativeTo: node) })
            return overlays
        }
    }

    private func hierarchyAttachmentDisplayNodes(from node: LevelNode) -> [LevelNode] {
        // Some imported child nodes are real hierarchy attachments, not baked
        // visual internals. Keep them visible as separate canvas objects.
        node.children.flatMap { child -> [LevelNode] in
            guard child.metadata.isHierarchyAttachment,
                  !child.metadata.isHidden else {
                return []
            }
            return displayNodes(from: child)
        }
    }

    func scaledOverlayNode(_ overlay: LevelNode, relativeTo root: LevelNode) -> LevelNode {
        // Scales helper overlays to match a resized parent preview. This is
        // visual-only; group-based resizing of real children is intentionally
        // disabled elsewhere to avoid corrupting XML.
        var overlay = overlay
        overlay.metadata.sortingLayer = "Debug"
        overlay.metadata.visualType = "RoomWeaverHelperOverlay"
        overlay.metadata.roomWeaverVisualOwnerID = root.id
        if !overlay.metadata.roomWeaverDynamicOwnerIDs.contains(root.id) {
            overlay.metadata.roomWeaverDynamicOwnerIDs.append(root.id)
        }
        guard let rootTransform = root.transform,
              overlay.transform != nil,
              root.metadata.visualNativeWidth > 0,
              root.metadata.visualNativeHeight > 0 else {
            return overlay
        }

        var adjusted = overlay
        adjusted.metadata.sortingLayer = "Debug"
        adjusted.metadata.visualType = "RoomWeaverHelperOverlay"

        let scaleX = Double(rootTransform.width) / Double(root.metadata.visualNativeWidth)
        let scaleY = Double(rootTransform.height) / Double(root.metadata.visualNativeHeight)
        let overlayIsLocalToRoot = root.metadata.visualType == "RoomWeaverLibraryReference" ||
            root.rendersAsRuntimeGraph
        adjusted.transform = composedOverlayTransform(
            overlay,
            root: root,
            scaleX: scaleX,
            scaleY: scaleY,
            isLocalToRoot: overlayIsLocalToRoot
        )
        return adjusted
    }

    private func composedOverlayTransform(
        _ overlay: LevelNode,
        root: LevelNode,
        scaleX: Double,
        scaleY: Double,
        isLocalToRoot: Bool
    ) -> LevelNode.Transform? {
        guard let rootTransform = root.transform,
              let overlayTransform = overlay.transform else {
            return overlay.transform
        }

        let rootCenter = visualCenterTransform(for: root, transform: rootTransform)
        let overlayCenter = visualCenterTransform(for: overlay, transform: overlayTransform)
        let rootVisualCenter = CGPoint(
            x: CGFloat(rootCenter.x + root.metadata.visualOffsetX),
            y: CGFloat(rootCenter.y + root.metadata.visualOffsetY)
        )
        let localCenter = CGPoint(
            x: isLocalToRoot
                ? CGFloat(overlayCenter.x - root.metadata.visualOffsetX)
                : CGFloat(overlayCenter.x) - rootVisualCenter.x,
            y: isLocalToRoot
                ? CGFloat(overlayCenter.y - root.metadata.visualOffsetY)
                : CGFloat(overlayCenter.y) - rootVisualCenter.y
        )
        let scaledLocalCenter = CGPoint(
            x: localCenter.x * CGFloat(scaleX),
            y: localCenter.y * CGFloat(scaleY)
        )
        let rotatedLocalCenter = rotateVector(scaledLocalCenter, degrees: rootTransform.rotation)
        let worldCenter = isLocalToRoot ? LevelDocument.libraryHelperCenter(
            localCenter: CGPoint(x: overlayCenter.x, y: overlayCenter.y), root: root,
            transform: rootTransform, scaleX: scaleX, scaleY: scaleY) : CGPoint(
            x: rootVisualCenter.x + rotatedLocalCenter.x,
            y: rootVisualCenter.y + rotatedLocalCenter.y
        )
        let width = max(1, Int((Double(overlayTransform.width) * scaleX).rounded()))
        let height = max(1, Int((Double(overlayTransform.height) * scaleY).rounded()))

        if overlay.kind.usesVectorRectOrigin {
            return .init(
                x: Int((worldCenter.x - CGFloat(width) / 2).rounded()),
                y: Int((worldCenter.y - CGFloat(height) / 2).rounded()),
                width: width,
                height: height,
                rotation: rootTransform.rotation + overlayTransform.rotation
            )
        }

        return .init(
            x: Int(worldCenter.x.rounded()),
            y: Int(worldCenter.y.rounded()),
            width: width,
            height: height,
            rotation: rootTransform.rotation + overlayTransform.rotation
        )
    }
}
