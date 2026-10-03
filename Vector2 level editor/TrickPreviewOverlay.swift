//
//  TrickPreviewOverlay.swift
//  Vector2 level editor
//

import SwiftUI

struct TrickPreviewOverlay: View {
    let playback: TrickPreviewPlayback
    let anchor: CGPoint
    let zoom: CGFloat
    let unitsPerCanvasPoint: CGFloat
    var showsDebugLabel = true
    var fixedFrame: Int? = nil
    var centersVisibleModel = false
    @AppStorage("vector2TrickPreviewShowSkeletonPoints") private var showSkeletonPoints = true
    @AppStorage("vector2TrickPreviewShowDetectorDots") private var showDetectorDots = true
    @AppStorage("vector2TrickPreviewShowModelNodeSpheres") private var showModelNodeSpheres = true
    @AppStorage("vector2TrickPreviewShowModelSphereOutlines") private var showModelSphereOutlines = true
    @AppStorage("vector2TrickPreviewBatterySaver") private var batterySaver = false
    @State private var startDate = Date()

    var body: some View {
        TimelineView(.periodic(from: startDate, by: frameInterval)) { timeline in
            let sample = sample(at: timeline.date)
            let originPivot = centersVisibleModel
                ? playback.previewOrigin(frame: sample.frameIndex, preservesMotion: fixedFrame == nil)
                : playback.originPivot
            let resolvedPoints = sample.resolvedModelPoints
            Canvas(opaque: false, rendersAsynchronously: false) { context, _ in
                drawTriangles(context: context, points: resolvedPoints, originPivot: originPivot)
                if playback.model.capsules.isEmpty {
                    drawEdges(context: context, pose: sample.pose, points: resolvedPoints, originPivot: originPivot)
                } else {
                    drawCapsules(context: context, points: resolvedPoints, originPivot: originPivot)
                }
                if showModelNodeSpheres {
                    drawNodePoints(context: context, points: resolvedPoints, originPivot: originPivot)
                }

                for index in sample.pose.indices.prefix(46) {
                    let isDetector = index == playback.pivotIndex
                    guard (showDetectorDots && isDetector) || (showSkeletonPoints && !isDetector) else { continue }
                    let p = canvasPoint(sample.pose[index], originPivot: originPivot)
                    let dot = CGRect(x: p.x - 2.4, y: p.y - 2.4, width: 4.8, height: 4.8)
                    context.fill(Path(ellipseIn: dot), with: .color(isDetector ? .orange : .white.opacity(0.72)))
                }
            }
            .overlay(alignment: .topLeading) {
                if showsDebugLabel {
                    Text("\(playback.move.name)  frame \(sample.frameIndex) +\(sample.subframe)")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(.black.opacity(0.62), in: Capsule())
                        .offset(x: anchor.x + 12, y: anchor.y - 58)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
    }

    private struct Sample {
        var frameIndex: Int
        var subframe: Int
        var pose: [CGPoint]
        var resolvedModelPoints: [String: CGPoint]
    }

    private var frameInterval: TimeInterval {
        batterySaver ? 1.0 / 30.0 : 1.0 / 60.0
    }

    private func sample(at date: Date) -> Sample {
        guard !playback.preparedSamples.isEmpty else {
            return Sample(frameIndex: 0, subframe: 0, pose: [], resolvedModelPoints: [:])
        }
        if let fixedFrame {
            let frameIndex = max(playback.preparedSamples[0].frameIndex, min(fixedFrame, playback.preparedSamples.last!.frameIndex))
            if let prepared = playback.sample(frame: frameIndex) {
                return Sample(frameIndex: prepared.frameIndex, subframe: prepared.subframe, pose: prepared.pose, resolvedModelPoints: prepared.resolvedModelPoints)
            }
        }
        let tick = max(0, Int(date.timeIntervalSince(startDate) * 60.0))
        let prepared = playback.preparedSamples[tick % playback.preparedSamples.count]
        return Sample(frameIndex: prepared.frameIndex, subframe: prepared.subframe, pose: prepared.pose, resolvedModelPoints: prepared.resolvedModelPoints)
    }

    private func drawCapsules(context: GraphicsContext, points: [String: CGPoint], originPivot: CGPoint) {
        for capsule in playback.model.capsules {
            guard let edge = playback.model.edge(named: capsule.edgeName),
                  let start = points[edge.startName],
                  let end = points[edge.endName] else { continue }
            let dx = start.x - end.x
            let dy = start.y - end.y
            let a = CGPoint(x: start.x - dx * capsule.margin1, y: start.y - dy * capsule.margin1)
            let b = CGPoint(x: end.x + dx * capsule.margin2, y: end.y + dy * capsule.margin2)
            let p1 = canvasPoint(a, originPivot: originPivot)
            let p2 = canvasPoint(b, originPivot: originPivot)
            var path = Path()
            path.move(to: p1)
            path.addLine(to: p2)
            let width = max(1.5, capsule.radius * 2 / unitsPerCanvasPoint * zoom)
            if showModelSphereOutlines {
                context.stroke(path, with: .color(.white.opacity(0.28)), style: StrokeStyle(lineWidth: width + max(1.0, 2.0 * zoom), lineCap: .round, lineJoin: .round))
            }
            context.stroke(path, with: .color(.black.opacity(0.96)), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
        }
    }

    private func drawTriangles(context: GraphicsContext, points: [String: CGPoint], originPivot: CGPoint) {
        for triangle in playback.model.triangles {
            let trianglePoints = triangle.nodeNames.compactMap {
                points[$0].map { canvasPoint($0, originPivot: originPivot) }
            }
            guard trianglePoints.count == 3 else { continue }
            var path = Path()
            path.move(to: trianglePoints[0])
            path.addLine(to: trianglePoints[1])
            path.addLine(to: trianglePoints[2])
            path.closeSubpath()
            context.fill(path, with: .color(.black.opacity(0.94)))
            if showModelSphereOutlines {
                context.stroke(path, with: .color(.white.opacity(0.10)), lineWidth: max(0.5, 0.8 * zoom))
            }
        }
    }

    private func drawEdges(context: GraphicsContext, pose: [CGPoint], points: [String: CGPoint], originPivot: CGPoint) {
        var path = Path()
        for edge in playback.model.edges {
            let start = edge.startIndex.flatMap { $0 < pose.count ? pose[$0] : nil }
                ?? points[edge.startName]
            let end = edge.endIndex.flatMap { $0 < pose.count ? pose[$0] : nil }
                ?? points[edge.endName]
            guard let start, let end else { continue }
            path.move(to: canvasPoint(start, originPivot: originPivot))
            path.addLine(to: canvasPoint(end, originPivot: originPivot))
        }
        context.stroke(path, with: .color(.cyan.opacity(0.92)), style: StrokeStyle(lineWidth: max(1.2, 2.0 * zoom), lineCap: .round, lineJoin: .round))
    }

    private func drawNodePoints(context: GraphicsContext, points: [String: CGPoint], originPivot: CGPoint) {
        for point in playback.model.nodePoints {
            guard let modelPoint = points[point.nodeName] else { continue }
            let p = canvasPoint(modelPoint, originPivot: originPivot)
            let radius = max(1.5, point.radius / unitsPerCanvasPoint * zoom)
            let rect = CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2)
            context.fill(Path(ellipseIn: rect), with: .color(.black.opacity(0.98)))
            if showModelSphereOutlines {
                context.stroke(Path(ellipseIn: rect), with: .color(.white.opacity(0.18)), lineWidth: max(0.5, 0.7 * zoom))
            }
        }
    }

    private func canvasPoint(_ point: CGPoint, originPivot: CGPoint) -> CGPoint {
        CGPoint(
            x: anchor.x + ((point.x - originPivot.x) / unitsPerCanvasPoint) * zoom,
            y: anchor.y + ((point.y - originPivot.y) / unitsPerCanvasPoint) * zoom
        )
    }
}
