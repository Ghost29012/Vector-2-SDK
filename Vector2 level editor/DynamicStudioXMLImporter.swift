
//
//  DynamicStudioXMLImporter.swift
//  Vector2 level editor
//
//  Converts existing Vector 2 Dynamic XML into an editable Dynamic Studio
//  timeline without changing the original XML until the user edits it.
//

import Foundation

struct DynamicStudioImportedKeyframe {
    let frame: Int
    let x: Int
    let y: Int
    let width: Int
    let height: Int
    let rotation: Double
    /// Easing carried by the interval that ends at this keyframe.
    let movementMode: DynamicPathMode?
    let movementQuarter: DynamicSinQuarter
    let sizeMode: DynamicPathMode?
    let sizeQuarter: DynamicSinQuarter
    let rotationMode: DynamicRotationMode?
}

struct DynamicStudioImportedTimeline {
    let name: String
    let totalFrames: Int
    let keyframes: [DynamicStudioImportedKeyframe]

    func pose(at frame: Int) -> DynamicStudioImportedKeyframe? {
        guard let first = keyframes.first else { return nil }
        guard keyframes.count > 1 else { return first }
        if frame <= first.frame { return first }
        guard let last = keyframes.last else { return first }
        if frame >= last.frame { return last }
        guard let upperIndex = keyframes.firstIndex(where: { $0.frame >= frame }), upperIndex > 0 else { return first }
        let lower = keyframes[upperIndex - 1]
        let upper = keyframes[upperIndex]
        let rawT = Double(frame - lower.frame) / Double(max(1, upper.frame - lower.frame))
        let moveT = upper.movementMode.map {
            DynamicStudioEasing.pathProgress(rawT, mode: $0, quarter: upper.movementQuarter)
        } ?? rawT
        let sizeT = upper.sizeMode.map {
            DynamicStudioEasing.pathProgress(rawT, mode: $0, quarter: upper.sizeQuarter)
        } ?? rawT
        let rotateT = upper.rotationMode.map {
            DynamicStudioEasing.rotationProgress(rawT, mode: $0)
        } ?? rawT
        return .init(
            frame: frame,
            x: lerp(lower.x, upper.x, moveT),
            y: lerp(lower.y, upper.y, moveT),
            width: lerp(lower.width, upper.width, sizeT),
            height: lerp(lower.height, upper.height, sizeT),
            rotation: lower.rotation + (upper.rotation - lower.rotation) * rotateT,
            movementMode: upper.movementMode,
            movementQuarter: upper.movementQuarter,
            sizeMode: upper.sizeMode,
            sizeQuarter: upper.sizeQuarter,
            rotationMode: upper.rotationMode
        )
    }

    private func lerp(_ lhs: Int, _ rhs: Int, _ t: Double) -> Int {
        Int((Double(lhs) + Double(rhs - lhs) * t).rounded())
    }

    static func parse(
        _ rawXML: String,
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        rotation: Double,
        transformationName: String? = nil
    ) -> DynamicStudioImportedTimeline? {
        let trimmed = rawXML.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let wrapped = trimmed.hasPrefix("<Dynamic")
            ? "<Root>\(trimmed)</Root>"
            : "<Root><Dynamic>\(trimmed)</Dynamic></Root>"
        guard let document = try? XMLDocument(xmlString: wrapped) else {
            return nil
        }
        let transformations = ((try? document.nodes(forXPath: "/Root/Dynamic/Transformation")) ?? [])
            .compactMap { $0 as? XMLElement }
        let transformation = transformationName.flatMap { requested in
            transformations.first { attribute("Name", on: $0) == requested }
        } ?? transformations.first
        guard let transformation else { return nil }

        var frame = 0
        var currentX = x
        var currentY = y
        var currentWidth = max(1, width)
        var currentHeight = max(1, height)
        var currentRotation = rotation
        var keyframes = [
            DynamicStudioImportedKeyframe(
                frame: frame,
                x: currentX,
                y: currentY,
                width: currentWidth,
                height: currentHeight,
                rotation: currentRotation,
                movementMode: nil,
                movementQuarter: .twoQuarters,
                sizeMode: nil,
                sizeQuarter: .twoQuarters,
                rotationMode: nil
            )
        ]

        for interval in childElements(of: transformation) {
            let frames = max(0, integer(attribute("Frames", on: interval)) ?? 0)
            var changed = false
            var movementMode: DynamicPathMode?
            var movementQuarter: DynamicSinQuarter = .twoQuarters
            var sizeMode: DynamicPathMode?
            var sizeQuarter: DynamicSinQuarter = .twoQuarters
            var rotationMode: DynamicRotationMode?

            switch interval.name {
            case "MoveInterval":
                movementMode = attribute("Type", on: interval) == "Sin" ? .sinusoidal : .bezier
                movementQuarter = DynamicSinQuarter.fromXML(quarterValue(in: interval))
                if let point = finishPoint(in: interval) {
                    currentX += integer(attribute("X", on: point)) ?? 0
                    currentY += integer(attribute("Y", on: point)) ?? 0
                    changed = true
                }
            case "SizeInterval":
                sizeMode = attribute("Type", on: interval) == "Sin" ? .sinusoidal : .bezier
                sizeQuarter = DynamicSinQuarter.fromXML(quarterValue(in: interval))
                if let point = finishPoint(in: interval) {
                    let widthScale = double(attribute("W", on: point)) ?? 1
                    let heightScale = double(attribute("H", on: point)) ?? 1
                    currentWidth = max(1, Int((Double(currentWidth) * widthScale).rounded()))
                    currentHeight = max(1, Int((Double(currentHeight) * heightScale).rounded()))
                    changed = true
                }
            case "RotationInterval":
                rotationMode = DynamicRotationMode.fromXML(attribute("Type", on: interval))
                currentRotation += double(attribute("Angle", on: interval)) ?? 0
                changed = true
            case "DelayInterval", "Wait":
                changed = true
            default:
                break
            }

            guard changed else { continue }
            frame += max(1, frames)
            keyframes.append(
                DynamicStudioImportedKeyframe(
                    frame: frame,
                    x: currentX,
                    y: currentY,
                    width: currentWidth,
                    height: currentHeight,
                    rotation: currentRotation,
                    movementMode: movementMode,
                    movementQuarter: movementQuarter,
                    sizeMode: sizeMode,
                    sizeQuarter: sizeQuarter,
                    rotationMode: rotationMode
                )
            )
        }

        guard keyframes.count > 1 else { return nil }
        return DynamicStudioImportedTimeline(
            name: attribute("Name", on: transformation) ?? "ImportedTransform",
            totalFrames: max(1, frame),
            keyframes: keyframes
        )
    }

    static func transformationNames(in rawXML: String) -> [String] {
        let trimmed = rawXML.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let wrapped = trimmed.hasPrefix("<Dynamic")
            ? "<Root>\(trimmed)</Root>"
            : "<Root><Dynamic>\(trimmed)</Dynamic></Root>"
        guard let document = try? XMLDocument(xmlString: wrapped) else { return [] }
        return ((try? document.nodes(forXPath: "/Root/Dynamic/Transformation")) ?? [])
            .compactMap { ($0 as? XMLElement).flatMap { attribute("Name", on: $0) } }
    }

    private static func childElements(of element: XMLElement) -> [XMLElement] {
        (element.children ?? []).compactMap { $0 as? XMLElement }
    }

    private static func finishPoint(in interval: XMLElement) -> XMLElement? {
        let points = childElements(of: interval).filter { $0.name == "Point" }
        return points.first { attribute("Name", on: $0) == "Finish" } ?? points.last
    }

    private static func quarterValue(in interval: XMLElement) -> String? {
        childElements(of: interval)
            .first(where: { $0.name == "Quarters" })?
            .attribute(forName: "Value")?
            .stringValue
    }

    private static func attribute(_ name: String, on element: XMLElement) -> String? {
        element.attribute(forName: name)?.stringValue
    }

    private static func integer(_ raw: String?) -> Int? {
        guard let value = double(raw) else { return nil }
        return Int(value.rounded())
    }

    private static func double(_ raw: String?) -> Double? {
        guard let raw, !raw.isEmpty else { return nil }
        return Double(raw.replacingOccurrences(of: ",", with: "."))
    }
}
