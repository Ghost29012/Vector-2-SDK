//
//  CanvasSupportViews.swift
//  Vector2 level editor
//
//  The canvas itself is already a beast, so all the reusable visual bits and
//  the native input bridge live here. Quick map for future us:
//  - OverlayBox / PreviewPiecesCanvas: what a node looks like.
//  - Selection / resize / rotation / grid: editor-only chrome.
//  - CanvasInputCatcher / CanvasEventView: raw mouse and keyboard plumbing.
//
//  If you touch the input section, please test zoom, middle-mouse pan, Shift
//  select, Delete, Q+scroll, and Y placement. Those tiny paths are connected.
//

import AppKit
import SwiftUI

/// Visual representation for nodes on the canvas.
///
/// This view handles both simple colored rectangles and texture-backed previews.
/// If something appears as a green/red/blue blob, the node reached the canvas
/// but did not have a resolved image/preview path.
struct OverlayBox: View, Equatable {
    enum Style: Equatable {
        case scene
        case ui
    }

    let label: String
    let color: Color
    var outlineColor: Color? = nil
    let size: CGSize
    var opacity: Double = 0.45
    var style: Style = .ui
    var rotationDegrees: Double = 0
    var imagePath: String = ""
    var previewPieces: [LevelNode.PreviewPiece] = []
    var tintColorHex: String = ""
    var isMirrored: Bool = false
    var isFlippedVertically: Bool = false
    var trapezoidStyle: TrapezoidCollisionShape.Style? = nil

    var body: some View {
        let _ = RoomWeaverDiagnostics.shared.recordZoomOverlayBody(
            hasImage: !imagePath.isEmpty,
            previewPieceCount: previewPieces.count,
            isTrapezoid: trapezoidStyle != nil
        )
        ZStack(alignment: .topLeading) {
            if style == .scene,
               let trapezoidStyle,
               let image = CachedImageStore.shared.image(at: imagePath) {
                ZStack {
                    // The source texture doesn't always reach the runtime slope
                    // edge. Fill underneath it so the guide line describes one
                    // solid collision area instead of leaving a white wedge.
                    TrapezoidCollisionShape(style: trapezoidStyle)
                        .fill(color.opacity(max(0.24, opacity)))
                    if hasTint {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: size.width, height: size.height)
                            .clipShape(TrapezoidCollisionShape(style: trapezoidStyle))
                            .colorMultiply(tintColor)
                    } else {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: size.width, height: size.height)
                            .clipShape(TrapezoidCollisionShape(style: trapezoidStyle))
                    }
                    TrapezoidCollisionShape(style: trapezoidStyle)
                        .stroke((outlineColor ?? color).opacity(0.9), lineWidth: 2)
                }
                    .frame(width: size.width, height: size.height)
                    .background(Color.clear)
                    .clipShape(TrapezoidCollisionShape(style: trapezoidStyle))
                    .overlay(
                        TrapezoidCollisionShape(style: trapezoidStyle)
                            .stroke((outlineColor ?? color).opacity(0.9), lineWidth: 2)
                    )
                    .scaleEffect(x: isMirrored ? -1 : 1, y: isFlippedVertically ? -1 : 1)
            } else if style == .scene, let trapezoidStyle {
                TrapezoidCollisionShape(style: trapezoidStyle)
                    .fill(color.opacity(max(0.24, opacity)))
                    .overlay(
                        TrapezoidCollisionShape(style: trapezoidStyle)
                            .stroke((outlineColor ?? color).opacity(0.95), style: StrokeStyle(lineWidth: 5, dash: [18, 9]))
                    )
                    .frame(width: size.width, height: size.height)
                    .scaleEffect(x: isMirrored ? -1 : 1, y: isFlippedVertically ? -1 : 1)
            } else if style == .scene, let image = CachedImageStore.shared.image(at: imagePath) {
                if hasTint {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: size.width, height: size.height)
                        .scaleEffect(x: isMirrored ? -1 : 1, y: isFlippedVertically ? -1 : 1)
                        .colorMultiply(tintColor)
                } else {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: size.width, height: size.height)
                        .scaleEffect(x: isMirrored ? -1 : 1, y: isFlippedVertically ? -1 : 1)
                }
            } else if style == .scene, !previewPieces.isEmpty {
                let metrics = previewMetrics
                let scaleX = size.width / max(1, metrics.width)
                let scaleY = size.height / max(1, metrics.height)
                PreviewPiecesCanvas(
                    pieces: previewPieces,
                    metrics: metrics,
                    scaleX: scaleX,
                    scaleY: scaleY
                )
                .frame(width: size.width, height: size.height)
                .scaleEffect(x: isMirrored ? -1 : 1, y: isFlippedVertically ? -1 : 1)
            } else {
                Rectangle()
                    .fill(color.opacity(opacity))
                    .overlay(Rectangle().stroke((outlineColor ?? color).opacity(0.95), lineWidth: 1))
                    .frame(width: size.width, height: size.height)
                    .scaleEffect(x: isMirrored ? -1 : 1, y: isFlippedVertically ? -1 : 1)
            }

            if shouldShowLabel {
                labelOverlay
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .rotationEffect(.degrees(rotationDegrees))
    }

    private var shouldShowLabel: Bool {
        guard !label.isEmpty && imagePath.isEmpty && previewPieces.isEmpty else {
            return false
        }
        if style == .scene {
            return size.width >= 12 && size.height >= 8
        }
        return true
    }

    private var labelFontSize: CGFloat {
        style == .scene ? max(5, min(10, size.height * 0.24)) : 11
    }

    private var labelForegroundColor: Color {
        style == .scene ? Color.black.opacity(0.7) : Color.white.opacity(0.84)
    }

    private var labelBackgroundColor: Color {
        style == .scene ? Color.clear : Color.black.opacity(0.18)
    }

    private var labelHorizontalPadding: CGFloat {
        style == .scene ? 3 : 6
    }

    private var labelVerticalPadding: CGFloat {
        style == .scene ? 2 : 4
    }

    private var labelOuterPadding: CGFloat {
        style == .scene ? 1 : 4
    }

    private var tintColor: Color {
        let cleaned = tintColorHex.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleaned.isEmpty {
            return Color(rgbaHex: cleaned)
        }
        return .white
    }

    private var hasTint: Bool {
        !tintColorHex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var labelOverlay: some View {
        Text(label)
            .font(.system(size: labelFontSize, weight: .medium))
            .foregroundStyle(labelForegroundColor)
            .padding(.horizontal, labelHorizontalPadding)
            .padding(.vertical, labelVerticalPadding)
            .background(labelBackgroundColor, in: RoundedRectangle(cornerRadius: 3))
            .padding(labelOuterPadding)
            .lineLimit(2)
            .minimumScaleFactor(0.45)
            .frame(width: max(0, size.width - 4), height: max(0, size.height - 4), alignment: .topLeading)
            .clipped()
    }

    private func tintColor(for piece: LevelNode.PreviewPiece) -> Color {
        let cleaned = piece.tintColorHex.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleaned.isEmpty {
            return Color(rgbaHex: cleaned)
        }
        return .white
    }

    private var previewMetrics: (centerX: CGFloat, centerY: CGFloat, width: CGFloat, height: CGFloat) {
        let bounds = previewPieces.flatMap { piece -> [CGPoint] in
            if let basisXX = piece.basisXX,
               let basisXY = piece.basisXY,
               let basisYX = piece.basisYX,
               let basisYY = piece.basisYY {
                let origin = CGPoint(x: piece.centerX, y: piece.centerY)
                return [
                    origin,
                    CGPoint(x: origin.x + basisXX, y: origin.y + basisXY),
                    CGPoint(x: origin.x + basisXX + basisYX, y: origin.y + basisXY + basisYY),
                    CGPoint(x: origin.x + basisYX, y: origin.y + basisYY)
                ]
            }
            return [
                CGPoint(x: piece.centerX - piece.width / 2, y: piece.centerY - piece.height / 2),
                CGPoint(x: piece.centerX + piece.width / 2, y: piece.centerY - piece.height / 2),
                CGPoint(x: piece.centerX + piece.width / 2, y: piece.centerY + piece.height / 2),
                CGPoint(x: piece.centerX - piece.width / 2, y: piece.centerY + piece.height / 2)
            ]
        }
        let minX = bounds.map(\.x).min() ?? 0
        let maxX = bounds.map(\.x).max() ?? 0
        let minY = bounds.map(\.y).min() ?? 0
        let maxY = bounds.map(\.y).max() ?? 0
        return (
            centerX: (minX + maxX) / 2,
            centerY: (minY + maxY) / 2,
            width: max(1, maxX - minX),
            height: max(1, maxY - minY)
        )
    }

}

struct PreviewPiecesCanvas: View {
    let pieces: [LevelNode.PreviewPiece]
    let metrics: (centerX: CGFloat, centerY: CGFloat, width: CGFloat, height: CGFloat)
    let scaleX: CGFloat
    let scaleY: CGFloat

    var body: some View {
        // Keep composite presentation off the main thread. Some imported
        // objects contain many sprite pieces, and drawing them synchronously
        // makes camera updates compete with their raster work.
        Canvas(rendersAsynchronously: true) { context, size in
            for piece in pieces {
                guard let image = CachedImageStore.shared.image(at: piece.imagePath) else {
                    continue
                }
                draw(piece: piece, image: image, in: &context, size: size)
            }
        }
    }

    private func draw(
        piece: LevelNode.PreviewPiece,
        image: NSImage,
        in context: inout GraphicsContext,
        size: CGSize
    ) {
        let swiftUIImage = Image(nsImage: image)
        let tintHex = piece.tintColorHex.trimmingCharacters(in: .whitespacesAndNewlines)
        // GraphicsContext is a value type. Copying it isolates this piece's
        // transform/filter state without creating an offscreen compositing
        // layer. The previous drawLayer call did that for all ~2,500 imported
        // sprites, including the overwhelming majority with no filter at all.
        var layer = context

        if !tintHex.isEmpty {
            layer.addFilter(.colorMultiply(Color(rgbaHex: tintHex)))
        }

        if let basisXX = piece.basisXX,
           let basisXY = piece.basisXY,
           let basisYX = piece.basisYX,
           let basisYY = piece.basisYY,
           image.size.width > 0,
           image.size.height > 0 {
            let originX = size.width / 2 + (CGFloat(piece.centerX) - metrics.centerX) * scaleX
            let originY = size.height / 2 + (CGFloat(piece.centerY) - metrics.centerY) * scaleY
            layer.concatenate(
                CGAffineTransform(
                    a: CGFloat(basisXX) * scaleX / image.size.width,
                    b: CGFloat(basisXY) * scaleY / image.size.width,
                    c: CGFloat(basisYX) * scaleX / image.size.height,
                    d: CGFloat(basisYY) * scaleY / image.size.height,
                    tx: originX,
                    ty: originY
                )
            )
            layer.draw(swiftUIImage, at: .zero, anchor: .topLeading)
        } else {
            let drawWidth = max(1, CGFloat(piece.width) * scaleX)
            let drawHeight = max(1, CGFloat(piece.height) * scaleY)
            let center = CGPoint(
                x: size.width / 2 + (CGFloat(piece.centerX) - metrics.centerX) * scaleX,
                y: size.height / 2 + (CGFloat(piece.centerY) - metrics.centerY) * scaleY
            )
            layer.translateBy(x: center.x, y: center.y)
            layer.rotate(by: .degrees(piece.rotation))
            layer.scaleBy(x: piece.mirrored ? -1 : 1, y: 1)
            layer.draw(
                swiftUIImage,
                in: CGRect(
                    x: -drawWidth / 2,
                    y: -drawHeight / 2,
                    width: drawWidth,
                    height: drawHeight
                )
            )
        }
    }

}

struct TrapezoidCollisionShape: Shape {
    enum Style {
        case left
        case right
    }

    let style: Style

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let rise = min(rect.height, rect.width / 2)
        switch style {
        case .left:
            path.move(to: CGPoint(x: rect.minX, y: rect.minY + rise))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        case .right:
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rise))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        }
        path.closeSubpath()
        return path
    }
}

/// Green selection rectangle and rotation stem around the active node.
///
/// Drawn over the selected object without changing its room geometry.
struct SelectedObjectOutline: View {
    let size: CGSize
    var rotationDegrees: Double = 0

    var body: some View {
        ZStack {
            Rectangle()
                .stroke(Color(red: 0.17, green: 0.9, blue: 0.36), lineWidth: 2)
                .frame(width: size.width, height: size.height)

            Rectangle()
                .fill(Color(red: 0.17, green: 0.9, blue: 0.36))
                .frame(width: 18, height: 1)
                .offset(x: 0, y: -(size.height / 2) - 16)
            Rectangle()
                .fill(Color(red: 0.17, green: 0.9, blue: 0.36))
                .frame(width: 1, height: 16)
                .offset(x: 0, y: -(size.height / 2) - 8)
        }
        .rotationEffect(.degrees(rotationDegrees))
    }
}

/// Small square resize handle used for single-object resizing only.
///
/// Group resizing is intentionally disabled because Vector 2 objects often have
/// nested helper triggers that should move with parents but not scale blindly.
struct ResizeHandleView: View {
    var body: some View {
        ZStack {
            // The invisible hit target needs an actual hit-testable shape on
            // macOS. A clear Color could let the node's move gesture win the
            // first drag, so resizing only worked after moving the object.
            Rectangle().fill(Color.white.opacity(0.001))
            Rectangle()
                .fill(Color.white)
                .frame(width: 10, height: 10)
                .overlay(Rectangle().stroke(Color.black.opacity(0.82), lineWidth: 1))
        }
        .frame(width: 32, height: 32)
        .contentShape(Rectangle())
    }
}

/// Circular rotation handle displayed above the selected object.
struct RotationHandleView: View {
    var body: some View {
        ZStack {
            Rectangle().fill(Color.white.opacity(0.001))
            Circle()
                .fill(Color.white)
                .frame(width: 10, height: 10)
                .overlay(Circle().stroke(Color.black.opacity(0.82), lineWidth: 1))
        }
        .frame(width: 36, height: 36)
        .contentShape(Rectangle())
    }
}

/// Infinite-feeling grid background.
///
/// The grid is screen-space decoration only. It should never leak into XML
/// coordinates or export math.
struct CanvasGrid: View {
    let panOffset: CGSize
    let zoom: CGFloat

    var body: some View {
        Canvas(opaque: true, rendersAsynchronously: true) { context, size in
            context.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .color(Color.editorCanvasBackground)
            )

            let step = max(12, 44 * zoom)
            let startX = panOffset.width.truncatingRemainder(dividingBy: step)
            let startY = panOffset.height.truncatingRemainder(dividingBy: step)
            var grid = Path()
            for x in stride(from: startX - step, through: size.width + step, by: step) {
                grid.move(to: CGPoint(x: x, y: 0))
                grid.addLine(to: CGPoint(x: x, y: size.height))
            }
            for y in stride(from: startY - step, through: size.height + step, by: step) {
                grid.move(to: CGPoint(x: 0, y: y))
                grid.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.stroke(
                grid,
                with: .color(Color.editorGridLine.opacity(0.75)),
                lineWidth: 0.8
            )
        }
    }
}

/// AppKit event bridge for canvas-only input.
///
/// SwiftUI gestures are great for simple drags, but they are not enough for
/// middle mouse pan, Q+scroll tool cycling, Delete, and global modifier-state
/// placement. This invisible NSView captures those edge-case events.
struct CanvasInputCatcher: NSViewRepresentable {
    @Binding var panOffset: CGSize
    @Binding var zoom: CGFloat
    let onDeleteSelection: () -> Void
    let onClearFocus: () -> Void
    let onShiftSelectClick: ((CGPoint) -> Void)?
    let onShiftSelectDragStart: ((CGPoint) -> Void)?
    let onShiftSelectDragChange: ((CGPoint) -> Void)?
    let onShiftSelectDragEnd: ((CGPoint) -> Void)?
    let onToolScroll: ((Int) -> Void)?
    let onAlternatePlacementChanged: ((Bool) -> Void)?
    var onPrimaryMouseDown: ((CGPoint) -> Void)? = nil
    var onFocusSelection: (() -> Void)? = nil

    func makeNSView(context: Context) -> CanvasEventView {
        let view = CanvasEventView()
        view.onDeleteSelection = onDeleteSelection
        view.onShiftSelectClick = onShiftSelectClick
        view.onShiftSelectDragStart = onShiftSelectDragStart
        view.onShiftSelectDragChange = onShiftSelectDragChange
        view.onShiftSelectDragEnd = onShiftSelectDragEnd
        view.onToolScroll = onToolScroll
        view.onAlternatePlacementChanged = onAlternatePlacementChanged
        view.onPrimaryMouseDown = onPrimaryMouseDown
        view.onFocusSelection = onFocusSelection
        view.onScroll = { delta, point in
            let oldZoom = zoom
            let newZoom = min(4, max(0.25, oldZoom * (delta > 0 ? 1.08 : 0.92)))
            guard abs(newZoom - oldZoom) > 0.001 else { return }
            let localX = (point.x - panOffset.width) / oldZoom
            let localY = (point.y - panOffset.height) / oldZoom
            panOffset = CGSize(width: point.x - localX * newZoom, height: point.y - localY * newZoom)
            zoom = newZoom
        }
        view.onMiddleDrag = { delta in
            onClearFocus()
            panOffset = CGSize(
                width: panOffset.width + delta.width,
                height: panOffset.height + delta.height
            )
        }
        return view
    }

    func updateNSView(_ nsView: CanvasEventView, context: Context) {
        RoomWeaverDiagnostics.shared.recordCanvasViewUpdate()
        nsView.onDeleteSelection = onDeleteSelection
        nsView.onShiftSelectClick = onShiftSelectClick
        nsView.onShiftSelectDragStart = onShiftSelectDragStart
        nsView.onShiftSelectDragChange = onShiftSelectDragChange
        nsView.onShiftSelectDragEnd = onShiftSelectDragEnd
        nsView.onToolScroll = onToolScroll
        nsView.onAlternatePlacementChanged = onAlternatePlacementChanged
        nsView.onPrimaryMouseDown = onPrimaryMouseDown
        nsView.onFocusSelection = onFocusSelection
        nsView.onScroll = { delta, point in
            let oldZoom = zoom
            let newZoom = min(4, max(0.25, oldZoom * (delta > 0 ? 1.08 : 0.92)))
            guard abs(newZoom - oldZoom) > 0.001 else { return }
            let localX = (point.x - panOffset.width) / oldZoom
            let localY = (point.y - panOffset.height) / oldZoom
            panOffset = CGSize(width: point.x - localX * newZoom, height: point.y - localY * newZoom)
            zoom = newZoom
        }
        nsView.onMiddleDrag = { delta in
            onClearFocus()
            panOffset = CGSize(
                width: panOffset.width + delta.width,
                height: panOffset.height + delta.height
            )
        }
    }

}

/// Native event sink mounted over the canvas.
///
/// Key detail: it refuses to handle events when text input is focused, otherwise
/// typing in properties would accidentally delete nodes or cycle tools.
final class CanvasEventView: NSView {
    var onScroll: ((CGFloat, CGPoint) -> Void)?
    var onMiddleDrag: ((CGSize) -> Void)?
    var onDeleteSelection: (() -> Void)?
    var onShiftSelectClick: ((CGPoint) -> Void)?
    var onShiftSelectDragStart: ((CGPoint) -> Void)?
    var onShiftSelectDragChange: ((CGPoint) -> Void)?
    var onShiftSelectDragEnd: ((CGPoint) -> Void)?
    var onToolScroll: ((Int) -> Void)?
    var onAlternatePlacementChanged: ((Bool) -> Void)?
    var onPrimaryMouseDown: ((CGPoint) -> Void)?
    var onFocusSelection: (() -> Void)?
    private var monitor: Any?
    private var lastMiddleLocation: CGPoint?
    private var isShiftSelectDragging = false
    private var shiftSelectMouseDownPoint: CGPoint?
    private var isToolCycling = false

    override var isFlipped: Bool { true }

    private var isQPressed: Bool {
        CGEventSource.keyState(.combinedSessionState, key: 12)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            onAlternatePlacementChanged?(false)
            lastMiddleLocation = nil
            shiftSelectMouseDownPoint = nil
            isShiftSelectDragging = false
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
            return
        }

        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .keyDown, .keyUp, .leftMouseDown, .leftMouseDragged, .leftMouseUp, .otherMouseDown, .otherMouseDragged, .otherMouseUp]) { [weak self] event in
            guard let self, event.window === self.window else { return event }

            let point = self.convert(event.locationInWindow, from: nil)
            if event.type != .keyDown && event.type != .keyUp {
                // A drag that began on the canvas still owns its mouse-up even
                // if the pointer leaves the canvas. Dropping that final event
                // leaves modifier/marquee state stuck and poisons the next input.
                let completesMiddleDrag = self.lastMiddleLocation != nil &&
                    (event.type == .otherMouseDragged || event.type == .otherMouseUp)
                let completesShiftDrag = self.shiftSelectMouseDownPoint != nil &&
                    (event.type == .leftMouseDragged || event.type == .leftMouseUp)
                guard self.bounds.contains(point) || completesMiddleDrag || completesShiftDrag else { return event }
            }

            switch event.type {
            case .keyDown:
                let textInputFocused = Self.isTextInputFocused(in: self.window)
                if !textInputFocused, event.charactersIgnoringModifiers == ",",
                   event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
                    self.onFocusSelection?()
                    return nil
                }
                if !textInputFocused,
                   let key = event.charactersIgnoringModifiers?.lowercased(),
                   ["e", "v", "t", "g", "u"].contains(key) {
                    return nil
                }
                if event.charactersIgnoringModifiers?.lowercased() == "q" {
                    guard !textInputFocused else { return event }
                    self.isToolCycling = true
                    return nil
                }
                if event.charactersIgnoringModifiers?.lowercased() == "y" {
                    guard !textInputFocused else { return event }
                    self.onAlternatePlacementChanged?(true)
                    return nil
                }
                if event.keyCode == 51 || event.keyCode == 117 {
                    guard !textInputFocused else { return event }
                    self.onDeleteSelection?()
                    return nil
                }
            case .keyUp:
                if !Self.isTextInputFocused(in: self.window),
                   let key = event.charactersIgnoringModifiers?.lowercased(),
                   ["e", "v", "t", "g", "u"].contains(key) {
                    return nil
                }
                if event.charactersIgnoringModifiers?.lowercased() == "q" {
                    self.isToolCycling = false
                    return nil
                }
                if event.charactersIgnoringModifiers?.lowercased() == "y" {
                    self.onAlternatePlacementChanged?(false)
                    return nil
                }
            case .scrollWheel:
                // Local monitors can miss keyUp when focus moves, so scroll
                // checks the live hardware key state before stealing zoom.
                if self.isToolCycling && self.isQPressed {
                    let direction = event.scrollingDeltaY >= 0 ? -1 : 1
                    self.onToolScroll?(direction)
                    return nil
                }
                self.isToolCycling = false
                RoomWeaverDiagnostics.shared.recordCanvasInput(isZoom: true)
                self.onScroll?(event.scrollingDeltaY, point)
                return nil
            case .otherMouseDown:
                if event.buttonNumber == 2 {
                    self.lastMiddleLocation = point
                    return nil
                }
            case .otherMouseDragged:
                if event.buttonNumber == 2, let lastMiddleLocation {
                    RoomWeaverDiagnostics.shared.recordCanvasInput(isZoom: false)
                    self.onMiddleDrag?(CGSize(width: point.x - lastMiddleLocation.x, height: point.y - lastMiddleLocation.y))
                    self.lastMiddleLocation = point
                    return nil
                }
            case .otherMouseUp:
                if event.buttonNumber == 2 {
                    self.lastMiddleLocation = nil
                    return nil
                }
            case .leftMouseDown:
                if event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.shift) {
                    // A Shift-click toggles one object; a Shift-drag adds a
                    // marquee. Wait for real pointer movement before deciding
                    // which interaction this is, otherwise tiny mouse jitter
                    // turns an ordinary click into a microscopic selection box.
                    self.shiftSelectMouseDownPoint = point
                    self.isShiftSelectDragging = false
                    return nil
                }
                self.onPrimaryMouseDown?(point)
                return event
            case .leftMouseDragged:
                guard let downPoint = self.shiftSelectMouseDownPoint else { return event }
                if !self.isShiftSelectDragging {
                    guard hypot(point.x - downPoint.x, point.y - downPoint.y) >= 4 else { return nil }
                    self.isShiftSelectDragging = true
                    self.onShiftSelectDragStart?(downPoint)
                }
                self.onShiftSelectDragChange?(point)
                return nil
            case .leftMouseUp:
                guard self.shiftSelectMouseDownPoint != nil else { return event }
                if self.isShiftSelectDragging {
                    self.onShiftSelectDragEnd?(point)
                } else {
                    self.onShiftSelectClick?(point)
                }
                self.shiftSelectMouseDownPoint = nil
                self.isShiftSelectDragging = false
                return nil
            default:
                break
            }

            return event
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    private static func isTextInputFocused(in window: NSWindow?) -> Bool {
        guard let responder = window?.firstResponder else { return false }
        return responder is NSTextView || responder is NSTextField || responder is NSSearchField
    }

    deinit {
        onAlternatePlacementChanged?(false)
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}

enum CanvasHandle: CaseIterable {
    case topLeft
    case top
    case topRight
    case left
    case right
    case bottomLeft
    case bottom
    case bottomRight

    static let resizeCases = Self.allCases

    var affectsLeft: Bool {
        self == .topLeft || self == .left || self == .bottomLeft
    }

    var affectsRight: Bool {
        self == .topRight || self == .right || self == .bottomRight
    }

    var affectsTop: Bool {
        self == .topLeft || self == .top || self == .topRight
    }

    var affectsBottom: Bool {
        self == .bottomLeft || self == .bottom || self == .bottomRight
    }
}

// MARK: - Right Dock / Inspector

/// Right side panel: hierarchy, properties, and raw XML.
///
/// The hierarchy is editable: it supports selection, shift-range selection,
/// search filtering, and drag reparenting. The properties panel edits the same
/// selected node data that the canvas uses, so property changes and canvas
/// changes stay in sync.
