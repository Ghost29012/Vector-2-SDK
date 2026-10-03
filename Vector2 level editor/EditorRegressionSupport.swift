import Foundation
import CoreGraphics

/// Plain rules with no UI stuff, so the Windows version can copy them easily.
enum EditorSelectionPolicy {
    static func preferredID<ID: Hashable>(primary: ID?, selected: Set<ID>, eligible: [ID]) -> ID? {
        if let primary, selected.contains(primary), eligible.contains(primary) { return primary }
        return eligible.first { selected.contains($0) }
    }

    /// Clicking the timeline should not randomly forget the object we were editing lmao.
    static func retainedTargetID<ID: Hashable>(current: ID?, primary: ID?, selected: Set<ID>, eligible: [ID]) -> ID? {
        if let next = preferredID(primary: primary, selected: selected, eligible: eligible) {
            return next
        }
        if let current, eligible.contains(current) { return current }
        return nil
    }
}

enum TriggerActionTargetPolicy {
    private static let movement = [
        "RunForward", "RunFast", "StopMoveRun", "StartMoveRun",
        "Jump", "WallJump", "Slide", "DivingKong", "DivingKongFly", "SpeedVault",
        "MonkeyVault", "DashVault", "PopVaultStart", "HurdleJump", "Trick",
        "Animation", "Spawn", "Activate Spawn", "Respawn", "Ragdoll", "Exit"
    ]

    static func templates(for target: String) -> [String] {
        switch target {
        case "player":
            return ["StopMoveRun", "StartMoveRun", "Trick", "Animation"]
        case "project":
            return ["Send Event"]
        default:
            return movement
        }
    }

    static func actionAfterTargetEdit(
        currentTarget: String, newTarget: String, template: String, value: String
    ) -> (template: String, value: String) {
        guard currentTarget != newTarget else { return (template, value) }
        return (newTarget == "project" ? "Send Event" : "", "")
    }
}

enum AnimationAreaPolicy {
    // These names come straight from Vector 2's animation reactions and rooms.
    // The match is exact: adding "Trigger" in front makes the area do nothing.
    static let commonNames = [
        "RunInhibition", "RunFromInhibition", "RunFast", "RunReverse",
        "RunReverseFromInhibition", "HighJump", "HurdleJump", "HurdleJumpToFly",
        "WallJump", "WallRunFromFail", "WallRunFromFailReverse", "NoWallRun",
        "CrawlingStart", "CrawlingMiddle", "CrawlingFinish"
    ]
    static let defaultName = "RunInhibition"

    static func isKnown(_ name: String) -> Bool {
        commonNames.contains(name)
    }

    static func exportName(for name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.caseInsensitiveCompare("Area") == .orderedSame {
            return defaultName
        }
        return trimmed
    }

    static func legacyAreaName(forTriggerTemplate template: String) -> String? {
        template == "RunInhibition" ? "RunInhibition" : nil
    }

    static func options(discovered: [String], current: String) -> [String] {
        let source = discovered.isEmpty ? commonNames : discovered
        let values = source + (current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : [current])
        var seen: Set<String> = []
        return values
            .filter { seen.insert($0.lowercased()).inserted }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}

enum GameMoveLibraryParser {
    static func animationAreaNames(from data: Data) -> [String] {
        guard let document = try? XMLDocument(data: data, options: [.nodePreserveWhitespace]),
              let nodes = try? document.nodes(forXPath: "//*[@AreaName]") else { return [] }
        var seen: Set<String> = []
        return nodes.compactMap { node -> String? in
            guard let element = node as? XMLElement,
                  let value = element.attribute(forName: "AreaName")?.stringValue?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty,
                  seen.insert(value.lowercased()).inserted else { return nil }
            return value
        }
        .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}

enum CanvasInteractionPolicy {
    static func shouldClearSelection(sceneHit: Bool, selectionHandleHit: Bool) -> Bool {
        !sceneHit && !selectionHandleHit
    }
    static func selectionTransform<T>(model: T, displayed: T?) -> T {
        displayed ?? model
    }

    static func shouldRefreshDisplayCache<Selection: Equatable>(
        previousSelection: Selection,
        newSelection: Selection
    ) -> Bool {
        previousSelection != newSelection
    }
}

enum CanvasHandleHitPolicy {
    static func contains(point: CGPoint, center: CGPoint, diameter: CGFloat) -> Bool {
        CGRect(
            x: center.x - diameter / 2,
            y: center.y - diameter / 2,
            width: diameter,
            height: diameter
        ).contains(point)
    }
}

enum CanvasRotationPreviewPolicy {
    static func rotatedPoint(_ point: CGPoint, around center: CGPoint, degrees: Double) -> CGPoint {
        let angle = degrees * .pi / 180
        let x = point.x - center.x, y = point.y - center.y
        return CGPoint(x: center.x + x * cos(angle) - y * sin(angle),
                       y: center.y + x * sin(angle) + y * cos(angle))
    }
    static func minimumStep(fullLivePreview: Bool) -> Double {
        // A quarter degree still looks fully attached, but avoids asking
        // SwiftUI to redraw a packed room for duplicate sub-pixel mouse events.
        fullLivePreview ? 0.25 : 1
    }

    static func publishableAngle(_ angle: Double, after previous: Double?, minimumStep: Double) -> Double? {
        guard let previous else { return angle }
        return abs(angle - previous) >= minimumStep ? angle : nil
    }
}

enum RoomWeaverAttachmentPolicy {
    static func usesParentAffine(isHierarchyAttachment: Bool) -> Bool {
        !isHierarchyAttachment
    }
}


enum CanvasTransformHandlePolicy {
    static func canResize(hasChildren: Bool, isAffineImportedPreview: Bool) -> Bool {
        !hasChildren
    }

    static func canRotate(isTrap: Bool, isAffineImportedPreview: Bool) -> Bool {
        !isTrap
    }
}

enum CanvasTransformEditPolicy {
    static func shouldMarkEdited<Transform: Equatable>(current: Transform, proposed: Transform) -> Bool {
        current != proposed
    }
}

enum CanvasResizePolicy {
    static func minimumVectorDimension(isImage: Bool) -> Int {
        isImage ? 8 : 24
    }
}

struct ImportedAffineRect: Equatable {
    var x: Int
    var y: Int
    var width: Int
    var height: Int
    var rotation: Double
    var localA: Double
    var localB: Double
    var localC: Double
    var localD: Double
}

enum ImportedAffineRectPolicy {
    static func editableRect(
        x: Double,
        y: Double,
        a: Double,
        b: Double,
        c: Double,
        d: Double,
        tx: Double,
        ty: Double
    ) -> ImportedAffineRect {
        let originX = x + tx
        let originY = y + ty
        let radians = atan2(b, a)
        let cosine = cos(radians)
        let sine = sin(radians)
        let localA = a * cosine + b * sine
        let localB = -a * sine + b * cosine
        let localC = c * cosine + d * sine
        let localD = -c * sine + d * cosine
        let corners = [
            CGPoint.zero,
            CGPoint(x: localA, y: localB),
            CGPoint(x: localA + localC, y: localB + localD),
            CGPoint(x: localC, y: localD)
        ]
        let minX = corners.map(\.x).min() ?? 0
        let maxX = corners.map(\.x).max() ?? 0
        let minY = corners.map(\.y).min() ?? 0
        let maxY = corners.map(\.y).max() ?? 0
        let width = max(1, Int((maxX - minX).rounded(.up)))
        let height = max(1, Int((maxY - minY).rounded(.up)))
        let centerX = originX + (a + c) / 2
        let centerY = originY + (b + d) / 2
        return ImportedAffineRect(
            x: Int((centerX - Double(width) / 2).rounded()),
            y: Int((centerY - Double(height) / 2).rounded()),
            width: width,
            height: height,
            rotation: radians * 180 / .pi,
            localA: localA,
            localB: localB,
            localC: localC,
            localD: localD
        )
    }
}

struct MovementTriggerEnterAction: Equatable {
    let controlEnabled: Bool
    let pressedKey: String
}

enum MovementTriggerPolicy {
    static func enterAction(for template: String) -> MovementTriggerEnterAction? {
        switch template {
        case "StopMoveRun":
            // Pressing Left is what makes Vector 2 pick RunInhibition from the active Area.
            return MovementTriggerEnterAction(controlEnabled: false, pressedKey: "Left")
        case "StartMoveRun":
            return MovementTriggerEnterAction(controlEnabled: true, pressedKey: "Right")
        default:
            return nil
        }
    }
}

enum InspectorGameplayPanel: Equatable {
    case trigger
    case animationArea
    case none
}

enum InspectorGameplayPanelPolicy {
    static func panel(
        selectedToolIsTrigger: Bool,
        selectedToolIsArea: Bool,
        selectedNodeIsTrigger: Bool,
        selectedNodeIsArea: Bool
    ) -> InspectorGameplayPanel {
        if selectedToolIsArea { return .animationArea }
        if selectedToolIsTrigger { return .trigger }
        if selectedNodeIsArea { return .animationArea }
        if selectedNodeIsTrigger { return .trigger }
        return .none
    }
}

enum EditorTabPolicy {
    /// Keep one blank tab around so closing everything does not crash the editor.
    static func shouldCreateBlankDocument(afterClosingRemainingCount count: Int) -> Bool {
        count == 0
    }
}

enum CustomLibraryVisibility {
    static func shouldIndex(filename: String, objectName: String, currentTrapObjects: Set<String>) -> Bool {
        guard filename.lowercased().hasPrefix("v2trap_") else { return true }
        return currentTrapObjects.contains(objectName)
    }
}

enum ProjectBackgroundInstallPolicy {
    nonisolated static func shouldInstall(relativePath: String) -> Bool {
        // We can look at background.xml, but do not copy it back into the game lmao.
        relativePath.lowercased() != "custom_backgrounds/background.xml"
    }

    static func poolFileNames(from installedPaths: Set<String>) -> Set<String> {
        Set(installedPaths.compactMap { path in
            guard path.hasPrefix("custom_backgrounds_pool/") else { return nil }
            let filename = String(path.dropFirst("custom_backgrounds_pool/".count))
            guard filename == URL(fileURLWithPath: filename).lastPathComponent,
                  filename.lowercased().hasSuffix(".xml") else { return nil }
            return filename
        })
    }

    static func stalePoolFileNames(previous: Set<String>, current: Set<String>) -> Set<String> {
        previous.subtracting(current).filter {
            $0 == URL(fileURLWithPath: $0).lastPathComponent && $0.lowercased().hasSuffix(".xml")
        }
    }
}

enum ParallaxPreviewMath {
    /// Vector 2 VisualRunner uses FactorX and FactorY = 1 - K * (1 - FactorX).
    /// The canvas already follows the camera pan, so this extra offset cancels
    /// the corresponding fraction of that pan for a background image.
    static func offset(cameraPanDelta: CGSize, factorX: Double, verticalK: Double) -> CGSize {
        guard factorX.isFinite, factorX > 0 else { return CGSize(width: 0, height: 0) }
        let factorY = 1 - verticalK * (1 - factorX)
        return CGSize(width: -cameraPanDelta.width * factorX,
                      height: -cameraPanDelta.height * factorY)
    }
}

enum BackgroundPlacementPolicy {
    // The biggest single Image in Vector 2's shipped background library is
    // 3268 wide and 2343 tall. Wider scenery is built from several images.
    static let maximumWidth = 3268
    static let maximumHeight = 2343
    /// Pool backgrounds need their own origin. Per-room backgrounds stay untouched.
    static func centeredXPositions(_ positions: [Int], widths: [Int]) -> [Int] {
        guard positions.count == widths.count, !positions.isEmpty else { return positions }
        let left = positions.min() ?? 0
        let right = zip(positions, widths).map(+).max() ?? left
        let center = (left + right) / 2
        return positions.map { $0 - center }
    }

    static func normalizedPoolFrames(_ frames: [CGRect]) -> [CGRect] {
        normalizedPoolFrames(
            frames,
            layerKeys: Array(repeating: "", count: frames.count),
            factors: Array(repeating: 1, count: frames.count)
        )
    }

    static func normalizedPoolFrames(_ frames: [CGRect], layerKeys: [String]) -> [CGRect] {
        normalizedPoolFrames(frames, layerKeys: layerKeys, factors: Array(repeating: 1, count: frames.count))
    }

    static func normalizedPoolFrames(_ frames: [CGRect], layerKeys: [String], factors: [Double]) -> [CGRect] {
        guard frames.count == layerKeys.count, frames.count == factors.count else { return frames }
        guard !frames.isEmpty else { return [] }
        let left = frames.map { $0.origin.x }.min() ?? 0
        let right = frames.map { $0.origin.x + $0.size.width }.max() ?? left
        guard right > left else { return frames }
        var bottoms: [String: CGFloat] = [:]
        var bleedByLayer: [String: CGFloat] = [:]
        for index in frames.indices {
            let frame = frames[index]
            let layer = layerKeys[index]
            bottoms[layer] = max(bottoms[layer] ?? -.greatestFiniteMagnitude, frame.maxY)
            let factor = factors[index].isFinite ? min(1, max(0, factors[index])) : 1
            bleedByLayer[layer] = max(
                bleedByLayer[layer] ?? 0,
                ceil(frame.height * CGFloat(1 - factor))
            )
        }
        return zip(frames, layerKeys).map { frame, layer -> CGRect in
            CGRect(x: frame.origin.x - left,
                   y: frame.origin.y - (bottoms[layer] ?? frame.maxY)
                       + (bleedByLayer[layer] ?? 0),
                   width: frame.size.width,
                   height: frame.size.height)
        }
    }

    /// Nekki's shipped backgrounds live between 0.65 and 0.95. Lower values are
    /// still legal, but they create much stronger camera-relative movement.
    static func isStockLikeParallaxFactor(_ factor: Double) -> Bool {
        factor >= 0.65 && factor <= 0.95
    }

    static func clampedBackgroundSize(width: Int, height: Int) -> (width: Int, height: Int) {
        let safeWidth = max(24, width)
        let safeHeight = max(24, height)
        let scale = min(1,
                        Double(maximumWidth) / Double(safeWidth),
                        Double(maximumHeight) / Double(safeHeight))
        return (max(24, Int((Double(safeWidth) * scale).rounded())),
                max(24, Int((Double(safeHeight) * scale).rounded())))
    }

    static func clampedAxis(
        minimum: CGFloat,
        maximum: CGFloat,
        maximumLength: CGFloat,
        draggingMinimum: Bool,
        draggingMaximum: Bool
    ) -> (minimum: CGFloat, maximum: CGFloat) {
        guard maximum - minimum > maximumLength else { return (minimum, maximum) }
        if draggingMinimum && !draggingMaximum { return (maximum - maximumLength, maximum) }
        if draggingMaximum && !draggingMinimum { return (minimum, minimum + maximumLength) }
        let center = (minimum + maximum) / 2
        return (center - maximumLength / 2, center + maximumLength / 2)
    }
}

enum PlayerPreviewPolicy {
    /// 0.xml carries the shared skeleton. 1.xml is Vector's normal body and
    /// stays below helmets/armour unless a custom player body replaces it.
    static func skinStack(modelReferences: [String], includesDefaultBody: Bool) -> [String] {
        var stack = ["0.xml"]
        if includesDefaultBody { stack.append("1.xml") }
        stack.append(contentsOf: modelReferences.compactMap { reference in
            guard !reference.isEmpty else { return nil }
            if reference.lowercased().hasPrefix("custom:") || reference.lowercased().hasSuffix(".xml") { return reference }
            return reference + ".xml"
        })
        var seen = Set<String>()
        return stack.filter { seen.insert($0).inserted }
    }
}

enum ProjectManagerSearchPolicy {
    static func matches(_ candidate: String, query: String) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        return words.allSatisfy { candidate.localizedCaseInsensitiveContains(String($0)) }
    }

    /// Lower scores appear first. Exact and prefix matches make the search act
    /// like navigation instead of a flat filename filter.
    static func score(_ candidate: String, query: String) -> Int? {
        let cleanCandidate = candidate.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let cleanQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        guard !cleanQuery.isEmpty, matches(cleanCandidate, query: cleanQuery) else { return nil }
        if cleanCandidate == cleanQuery { return 0 }
        if cleanCandidate.hasPrefix(cleanQuery) { return 10 + cleanCandidate.count }
        return 100 + (cleanCandidate.range(of: cleanQuery)?.lowerBound.utf16Offset(in: cleanCandidate) ?? 50)
    }
}
