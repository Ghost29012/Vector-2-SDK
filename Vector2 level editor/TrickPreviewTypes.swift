//
//  TrickPreviewTypes.swift
//  Vector2 level editor
//

import Foundation
import CoreGraphics

struct TrickPreviewMove: Identifiable, Equatable {
    var id: String { name }
    var name: String
    var fileName: String
    var firstFrame: Int
    var endFrame: Int
    var midFrames: Int
    var loops: Bool
    var pivotNode: String
    var isTrick: Bool
    var parts: String
}

struct TrickPreviewModelSkin: Identifiable, Equatable {
    var id: String { filename }
    var filename: String
    var displayName: String
}

struct TrickPreviewFrame: Equatable {
    var points: [CGPoint]
}

struct TrickPreviewPreparedSample: Equatable {
    var frameIndex: Int
    var subframe: Int
    var pose: [CGPoint]
    var resolvedModelPoints: [String: CGPoint]
}

struct TrickPreviewModel: Equatable {
    struct Node: Equatable {
        var name: String
        var type: String
        var basePoint: CGPoint
        var animationIndex: Int?
        var childNames: [String]
        var childWeights: [CGFloat]
    }

    struct Edge: Identifiable, Equatable {
        let id = UUID()
        var name: String
        var startName: String
        var endName: String
        var startIndex: Int?
        var endIndex: Int?
    }

    struct Capsule: Identifiable, Equatable {
        let id = UUID()
        var name: String
        var edgeName: String
        var radius: CGFloat
        var margin1: CGFloat
        var margin2: CGFloat
    }

    struct Triangle: Identifiable, Equatable {
        let id = UUID()
        var name: String
        var nodeNames: [String]
    }

    struct NodePoint: Identifiable, Equatable {
        let id = UUID()
        var name: String
        var nodeName: String
        var radius: CGFloat
    }

    var nodes: [Node]
    var nodeIndexByName: [String: Int]
    var edges: [Edge]
    var capsules: [Capsule]
    var triangles: [Triangle]
    var nodePoints: [NodePoint]

    func nodeIndex(named name: String) -> Int? {
        if let exact = nodeIndexByName[name] {
            return exact
        }
        return nodes.firstIndex { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    func edge(named name: String) -> Edge? {
        edges.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    func animatedPoint(named name: String, pose: [CGPoint], memo: inout [String: CGPoint]) -> CGPoint? {
        if let cached = memo[name] {
            return cached
        }
        guard let index = nodeIndex(named: name) else {
            return nil
        }
        let node = nodes[index]
        let value: CGPoint
        if let animationIndex = node.animationIndex, animationIndex < pose.count {
            value = pose[animationIndex]
        } else if (node.type == "CenterOfMass" || node.type == "MacroNode"), !node.childNames.isEmpty {
            var total = CGPoint.zero
            var weightTotal: CGFloat = 0
            for (index, childName) in node.childNames.enumerated() {
                guard let child = animatedPoint(named: childName, pose: pose, memo: &memo) else { continue }
                let weight = index < node.childWeights.count ? node.childWeights[index] : 1
                total.x += child.x * weight
                total.y += child.y * weight
                weightTotal += weight
            }
            value = abs(weightTotal) > 0.0001 ? CGPoint(x: total.x / weightTotal, y: total.y / weightTotal) : node.basePoint
        } else {
            value = node.basePoint
        }
        memo[name] = value
        return value
    }

    func pivotPoint(named rawName: String, pose: [CGPoint]) -> CGPoint {
        var memo: [String: CGPoint] = [:]
        let candidates = [rawName, "DetectorH", "NPivot", "COM"]
        for candidate in candidates where !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let point = animatedPoint(named: candidate, pose: pose, memo: &memo) {
                return point
            }
        }
        return .zero
    }
}

struct TrickPreviewPlayback: Equatable {
    let id = UUID()
    var move: TrickPreviewMove
    var model: TrickPreviewModel
    var frames: [TrickPreviewFrame]
    var startFrame: Int
    var pivotIndex: Int?
    var selectedSkins: [String]
    var anchorNodeID: LevelNode.ID?
    var placementOffset: CGSize = .zero
    var preparedSamples: [TrickPreviewPreparedSample]
    var originPivot: CGPoint

    init(move: TrickPreviewMove, model: TrickPreviewModel, frames: [TrickPreviewFrame], startFrame: Int,
         pivotIndex: Int?, selectedSkins: [String], anchorNodeID: LevelNode.ID?, placementOffset: CGSize = .zero) {
        self.move = move
        self.model = model
        self.frames = frames
        self.startFrame = startFrame
        self.pivotIndex = pivotIndex
        self.selectedSkins = selectedSkins
        self.anchorNodeID = anchorNodeID
        self.placementOffset = placementOffset

        guard !frames.isEmpty else {
            preparedSamples = []
            originPivot = .zero
            return
        }
        let first = max(0, min(startFrame, frames.count - 1))
        let requestedEnd = move.endFrame > 0 ? move.endFrame : frames.count - 1
        let end = max(first, min(requestedEnd, frames.count - 1))
        let pointFrames = max(1, move.midFrames)
        preparedSamples = (first...end).flatMap { frameIndex in
            (0...pointFrames).map { subframe in
                let previous = frames[frameIndex == first ? end : frameIndex - 1].points
                let current = frames[frameIndex].points
                let next = frames[frameIndex == end ? first : frameIndex + 1].points
                let count = min(previous.count, current.count, next.count)
                let t = CGFloat(subframe + 1) / CGFloat(pointFrames + 1)
                let pose = (0..<count).map { index -> CGPoint in
                    let a = Self.lerp(previous[index], current[index], 0.5)
                    let b = Self.lerp(current[index], next[index], 0.5)
                    let inverse = 1 - t
                    return CGPoint(x: a.x * inverse * inverse + current[index].x * 2 * inverse * t + b.x * t * t,
                                   y: a.y * inverse * inverse + current[index].y * 2 * inverse * t + b.y * t * t)
                }
                var resolved: [String: CGPoint] = [:]
                for node in model.nodes {
                    _ = model.animatedPoint(named: node.name, pose: pose, memo: &resolved)
                }
                return TrickPreviewPreparedSample(frameIndex: frameIndex, subframe: subframe, pose: pose, resolvedModelPoints: resolved)
            }
        }
        originPivot = model.pivotPoint(named: move.pivotNode, pose: preparedSamples.first?.pose ?? frames[first].points)
    }

    func sample(frame: Int, subframe: Int = 0) -> TrickPreviewPreparedSample? {
        preparedSamples.first { $0.frameIndex == frame && $0.subframe == subframe }
    }

    func previewCenter(frame: Int) -> CGPoint {
        guard let sample = sample(frame: frame) else { return originPivot }
        var visiblePoints: [CGPoint] = []
        if !model.capsules.isEmpty {
            for capsule in model.capsules {
                guard let edge = model.edge(named: capsule.edgeName) else { continue }
                if let start = sample.resolvedModelPoints[edge.startName] { visiblePoints.append(start) }
                if let end = sample.resolvedModelPoints[edge.endName] { visiblePoints.append(end) }
            }
        } else {
            for edge in model.edges {
                if let start = sample.resolvedModelPoints[edge.startName] { visiblePoints.append(start) }
                if let end = sample.resolvedModelPoints[edge.endName] { visiblePoints.append(end) }
            }
        }
        for triangle in model.triangles {
            for name in triangle.nodeNames {
                if let point = sample.resolvedModelPoints[name] { visiblePoints.append(point) }
            }
        }
        if visiblePoints.isEmpty { visiblePoints = Array(sample.pose.prefix(46)) }
        let finitePoints = visiblePoints.filter { $0.x.isFinite && $0.y.isFinite }
        guard let first = finitePoints.first else { return originPivot }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in finitePoints.dropFirst() {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }
        return CGPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2)
    }

    func previewOrigin(frame: Int, preservesMotion: Bool) -> CGPoint {
        let referenceFrame = preservesMotion ? (preparedSamples.first?.frameIndex ?? frame) : frame
        return previewCenter(frame: referenceFrame)
    }

    private static func lerp(_ lhs: CGPoint, _ rhs: CGPoint, _ t: CGFloat) -> CGPoint {
        CGPoint(x: lhs.x + (rhs.x - lhs.x) * t, y: lhs.y + (rhs.y - lhs.y) * t)
    }
}

enum TrickPreviewRoomFraming {
    static func screenAnchor(localAnchor: CGPoint, panOffset: CGSize) -> CGPoint {
        CGPoint(
            x: localAnchor.x + panOffset.width,
            y: localAnchor.y + panOffset.height
        )
    }
}

extension Array where Element: Hashable {
    func vector2Uniqued() -> [Element] {
        var seen: Set<Element> = []
        return filter { seen.insert($0).inserted }
    }
}
