//
//  RoomWeaverDiagnostics.swift
//  Vector2 level editor
//
//  RoomWeaver logging, profiling, and import-debug snapshots.
//
//  Keep measurements here and scene reconstruction in
//  RoomWeaverSceneImporter.swift. Debugging should observe imports, not become
//  part of the import algorithm by accident.
//

import SwiftUI
import AppKit
import Foundation
import Combine
import UniformTypeIdentifiers

final class RoomWeaverDiagnostics: ObservableObject {
    struct Entry: Identifiable, Equatable {
        enum Level: String {
            case info = "Info"
            case warning = "Warning"
            case error = "Error"
        }

        let id = UUID()
        let level: Level
        let message: String
        let detail: String
    }

    static let shared = RoomWeaverDiagnostics()

    @Published private(set) var entries: [Entry] = []
    @Published private(set) var liveCanvasPerformance = "Canvas telemetry idle - pan or zoom the canvas"
    private(set) var isImporting = false
    private var seenKeys: Set<String> = []
    private var deferredEntries: [Entry] = []
    private var exportEntries: [Entry] = []
    private var lastPerformanceLogTimes: [String: TimeInterval] = [:]
    private var canvasTelemetryWindowStart: CFAbsoluteTime?
    private var panInputEvents = 0
    private var zoomInputEvents = 0
    private var panViewUpdates = 0
    private var zoomViewUpdates = 0
    private var zoomScenePasses = 0
    private var zoomSceneNodeVisits = 0
    private var zoomOverlayBodies = 0
    private var zoomImageBodies = 0
    private var zoomCompositeBodies = 0
    private var zoomCompositePieces = 0
    private var zoomShapeBodies = 0
    private var zoomTrapezoidBodies = 0
    private var zoomResponseTotalMilliseconds = 0.0
    private var zoomResponseMaxMilliseconds = 0.0
    private var zoomMainQueueTotalMilliseconds = 0.0
    private var zoomMainQueueMaxMilliseconds = 0.0
    private var zoomMainQueueSamples = 0
    private var zoomMainQueueProbePending = false
    private var zoomProfilingActive = false
    private var lastPanInputTime: CFAbsoluteTime?
    private var lastZoomInputTime: CFAbsoluteTime?
    private var lastImportedNodes: [LevelNode] = []
    private var lastImportedDocument: LevelDocument?
    private var lastEditorLayoutTSV = ""
    private let liveEntryLimit = 1_600
    private let exportEntryLimit = 24_000
    private var verboseEnabled: Bool {
        UserDefaults.standard.bool(forKey: "vector2RoomWeaverVerboseDiagnostics")
    }

    var plainText: String {
        let source = exportEntries.isEmpty ? entries : exportEntries
        return source.map { entry in
            let detail = entry.detail.isEmpty ? "" : " -- \(entry.detail)"
            return "[\(entry.level.rawValue)] \(entry.message)\(detail)"
        }.joined(separator: "\n")
    }

    func beginImport(path: String) {
        clear()
        isImporting = true
        log(.info, "RoomWeaver import started", detail: URL(fileURLWithPath: path).lastPathComponent)
    }

    func finishImport(document: LevelDocument) {
        let nodes = document.root.flattenedSceneNodes()
        lastImportedNodes = nodes
        lastImportedDocument = document
        // The TSV is a debugging artifact, not part of importing or rendering.
        // Build it only when Export Editor TSV is actually requested.
        lastEditorLayoutTSV = ""
        let unresolved = nodes.filter { node in
            switch node.kind {
            case .image:
                return !node.metadata.className.isEmpty && node.metadata.imagePath.isEmpty && node.previewPieces.isEmpty
            case .object, .objectReference:
                return node.metadata.imagePath.isEmpty && node.previewPieces.isEmpty && node.children.isEmpty
            default:
                return false
            }
        }
        log(.info, "RoomWeaver import finished", detail: "\(nodes.count) scene nodes, \(unresolved.count) unresolved visuals")
        log(
            .info,
            "Editor runtime-layout capture ready",
            detail: "Generated on demand by Export Editor TSV; no capture work runs during normal editing"
        )
        // Containers are flattened out of `nodes` for normal scene editing, but
        // room dynamics frequently live on those container elements. Audit the
        // complete hierarchy so the console reflects what was actually parsed.
        let hierarchyNodes = document.root.allDescendantsIncludingSelf()
        let directDynamicNodes = hierarchyNodes.filter { hasSpatialDynamic($0.metadata.dynamicXML) }
        let resolvedDynamicNodes = nodes.filter { $0.metadata.resolvedDynamicCount > 0 }
        if !directDynamicNodes.isEmpty || !resolvedDynamicNodes.isEmpty {
            let nestedBlocks = resolvedDynamicNodes.reduce(0) { $0 + $1.metadata.resolvedDynamicCount }
            log(
                .info,
                "RoomWeaver dynamics resolved",
                detail: "direct=\(directDynamicNodes.count) | libraryReferences=\(resolvedDynamicNodes.count) | nestedBlocks=\(nestedBlocks)"
            )
            for node in resolvedDynamicNodes.prefix(60) {
                log(
                    .info,
                    "Resolved library dynamics",
                    detail: "\(node.name) | blocks=\(node.metadata.resolvedDynamicCount) | owners=\(emptyDash(node.metadata.resolvedDynamicOwners))",
                    dedupeKey: "resolved-dynamics:\(node.id)"
                )
            }
        }
        if verboseEnabled {
            logImportBreakdown(document: document, nodes: nodes)
            logTransformBreakdown(nodes: nodes)
            logDeepImportDiagnostics(document: document)
        }
        if !unresolved.isEmpty {
            log(.warning, "Some nodes still need resolver rules", detail: unresolved.prefix(12).map(\.name).joined(separator: ", "))
            logUnresolvedBreakdown(unresolved)
        }
        flushDeferredEntries()
        isImporting = false
    }

    private func logTransformBreakdown(nodes: [LevelNode]) {
        let matrixNodes = nodes.filter { !$0.metadata.matrixA.isEmpty }
        let groupedDynamics = matrixNodes.filter {
            !$0.children.isEmpty && (
                hasSpatialDynamic($0.metadata.dynamicXML)
                    || $0.metadata.resolvedDynamicCount > 0
            )
        }
        let singular = matrixNodes.filter { node in
            guard let a = Double(node.metadata.matrixA), let b = Double(node.metadata.matrixB),
                  let c = Double(node.metadata.matrixC), let d = Double(node.metadata.matrixD) else { return true }
            return abs(a * d - b * c) < 0.0001
        }
        let skewed = matrixNodes.filter { node in
            guard let a = Double(node.metadata.matrixA), let b = Double(node.metadata.matrixB),
                  let c = Double(node.metadata.matrixC), let d = Double(node.metadata.matrixD) else { return false }
            let denominator = max(0.0001, hypot(a, b) * hypot(c, d))
            return abs(a * c + b * d) / denominator > 0.001
        }
        log(
            .info,
            "RoomWeaver transform audit",
            detail: "matrices=\(matrixNodes.count) | groupedDynamics=\(groupedDynamics.count) | skewed=\(skewed.count) | singular=\(singular.count)"
        )
        for node in groupedDynamics.prefix(40) {
            let transform = node.transform
            let matrix = "[\(node.metadata.matrixA),\(node.metadata.matrixB),\(node.metadata.matrixC),\(node.metadata.matrixD), tx=\(node.metadata.matrixTx), ty=\(node.metadata.matrixTy)]"
            let position = transform.map { value in
                let rotation = String(format: "%.3f", value.rotation)
                return "local=(\(value.x),\(value.y)) size=\(value.width)x\(value.height) rotation=\(rotation)"
            } ?? "local=nil"
            log(
                .info,
                "Grouped dynamic transform",
                detail: "\(node.name) | children=\(node.children.count) | \(position) | matrix=\(matrix)",
                dedupeKey: "grouped-transform:\(node.id)"
            )
        }
        if !singular.isEmpty {
            log(.warning, "Non-invertible RoomWeaver matrices", detail: singular.prefix(24).map(\.name).joined(separator: ", "))
        }
    }

    func auditExport(documentName: String, nodes: [LevelNode], xml: String) {
        let imported = nodes.filter { $0.metadata.visualType.hasPrefix("RoomWeaver") }
        guard !imported.isEmpty else { return }
        let coloredSources = imported.filter { $0.metadata.sourcePropertiesXML.contains("<StartColor") }
        let dynamicSources = imported.filter { !$0.metadata.dynamicXML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let groupedDynamics = dynamicSources.filter { !$0.children.isEmpty }
        let matrixSources = imported.filter { !$0.metadata.matrixA.isEmpty }
        let syntheticPivots = xml.components(separatedBy: "_DynamicPivot").count - 1
        let exportedColors = xml.components(separatedBy: "<StartColor").count - 1
        let exportedDynamics = xml.components(separatedBy: "<Dynamic").count - 1
        log(
            .info,
            "RoomWeaver export audit",
            detail: "doc=\(documentName) | imported=\(imported.count) | matrices=\(matrixSources.count) | sourceColors=\(coloredSources.count) exportedColors=\(exportedColors) | sourceDynamics=\(dynamicSources.count) groupedDynamics=\(groupedDynamics.count) exportedDynamics=\(exportedDynamics) | syntheticPivots=\(syntheticPivots)"
        )
        if exportedColors < coloredSources.count {
            log(.warning, "Export may have lost color properties", detail: "source=\(coloredSources.count) exported=\(exportedColors)")
        }
        if syntheticPivots > 0 {
            log(.warning, "Export contains synthetic dynamic pivots", detail: "count=\(syntheticPivots)")
        }
        if !groupedDynamics.isEmpty {
            let sample = groupedDynamics.prefix(16).map { "\($0.name)[children=\($0.children.count)]" }.joined(separator: ", ")
            log(.info, "Grouped dynamic preservation sample", detail: sample)
        }
    }

    func failImport(path: String) {
        log(.error, "RoomWeaver could not parse XML", detail: path)
        flushDeferredEntries()
        isImporting = false
    }

    func missingTexture(className: String) {
        let clean = className.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        log(.warning, "Texture alias unresolved", detail: clean, dedupeKey: "texture:\(clean)", deferred: isImporting)
    }

    func missingLibraryObject(name: String, filename: String) {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanFile = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        log(.warning, "Library object unresolved", detail: "\(cleanName) in \(cleanFile)", dedupeKey: "library:\(cleanFile):\(cleanName)", deferred: isImporting)
    }

    func libraryResolveFailed(name: String, filename: String, reason: String, context: String = "") {
        guard isImporting else { return }
        let detail = [
            "\(name) in \(filename)",
            reason,
            context
        ]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " | ")
        log(.warning, "Library resolver failed", detail: detail, dedupeKey: "library-fail:\(filename):\(name):\(reason)", deferred: true)
    }

    func libraryStrictRetry(name: String, filename: String, context: String) {
        guard isImporting else { return }
        log(
            .info,
            "Library strict pass was empty",
            detail: "\(name) in \(filename) | retrying loose filters | \(context)",
            dedupeKey: "library-strict-empty:\(filename):\(name):\(context)",
            deferred: true
        )
    }

    func libraryResolvedAfterLooseRetry(name: String, filename: String, summary: String) {
        guard isImporting else { return }
        log(
            .info,
            "Library loose retry resolved",
            detail: "\(name) in \(filename) | \(summary)",
            dedupeKey: "library-loose:\(filename):\(name):\(summary)",
            deferred: true
        )
    }

    func libraryResolved(name: String, filename: String, mode: String, summary: String) {
        guard isImporting else { return }
        log(
            .info,
            "Library resolved",
            detail: "\(name) in \(filename) | \(mode) | \(summary)",
            dedupeKey: "library-ok:\(filename):\(name):\(mode):\(summary)",
            deferred: true
        )
    }

    func referenceVisualFailed(name: String, filename: String, reason: String) {
        guard isImporting else { return }
        log(
            .warning,
            "Reference visual unresolved",
            detail: "\(name) in \(filename) | \(reason)",
            dedupeKey: "reference-fail:\(filename):\(name):\(reason)",
            deferred: true
        )
    }

    func referenceVisualPath(name: String, filename: String, path: String) {
        guard isImporting else { return }
        log(
            .info,
            "Reference visual path",
            detail: "\(name) in \(filename) | \(path)",
            dedupeKey: "reference-path:\(filename):\(name):\(path)",
            deferred: true
        )
    }

    func layoutDebug(kind: String, name: String, detail: String) {
        guard isImporting, verboseEnabled else { return }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = "layout:\(kind):\(cleanName):\(detail)"
        log(
            .info,
            "V2 layout \(kind)",
            detail: "\(cleanName.isEmpty ? "-" : cleanName) | \(detail)",
            dedupeKey: key,
            deferred: true
        )
    }

    func selectedChoices(_ choices: [String: String]) {
        guard !choices.isEmpty else { return }
        let rootChoices = choices
            .filter { !$0.key.contains("/") && !$0.key.hasPrefix("__") }
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ", ")
        log(.info, "Room choices", detail: rootChoices.isEmpty ? "\(choices.count) choices" : rootChoices)
    }

    /// Reports time spent in a named editor operation. Unlike the old canvas
    /// dump this logs actionable duration data and stays quiet for fast work.
    func performanceSample(operation: String, milliseconds: Double, detail: String = "") {
        guard verboseEnabled else { return }
        let threshold = 4.0
        guard milliseconds >= threshold else { return }
        let now = Date().timeIntervalSinceReferenceDate
        guard now - (lastPerformanceLogTimes[operation] ?? 0) >= 1 else { return }
        lastPerformanceLogTimes[operation] = now
        let suffix = detail.isEmpty ? "" : " | \(detail)"
        log(
            milliseconds >= 16.67 ? .warning : .info,
            "Slow editor operation",
            detail: "\(operation)=\(String(format: "%.2f", milliseconds))ms\(suffix)",
            dedupeKey: nil
        )
    }

    /// Lightweight live telemetry for the editor camera path. Pan and zoom are
    /// deliberately tracked separately: pan reuses the scene subtree, while a
    /// zoom changes every node's geometry and can rebuild much more SwiftUI
    /// work. Counters are published once per second and never append per-node
    /// console entries.
    func recordCanvasInput(isZoom: Bool) {
        guard verboseEnabled else { return }
        let now = CFAbsoluteTimeGetCurrent()
        if canvasTelemetryWindowStart == nil {
            canvasTelemetryWindowStart = now
        }
        if isZoom {
            zoomInputEvents += 1
            lastZoomInputTime = now
            zoomProfilingActive = true
            scheduleZoomMainQueueProbe(startedAt: now)
        } else {
            panInputEvents += 1
            lastPanInputTime = now
        }
    }

    func recordCanvasViewUpdate() {
        guard verboseEnabled, let windowStart = canvasTelemetryWindowStart else { return }
        let now = CFAbsoluteTimeGetCurrent()
        if let zoomTime = lastZoomInputTime,
           now - zoomTime <= 0.25,
           zoomTime >= (lastPanInputTime ?? 0) {
            zoomViewUpdates += 1
            let responseMilliseconds = max(0, (now - zoomTime) * 1_000)
            zoomResponseTotalMilliseconds += responseMilliseconds
            zoomResponseMaxMilliseconds = max(zoomResponseMaxMilliseconds, responseMilliseconds)
        } else if let panTime = lastPanInputTime, now - panTime <= 0.25 {
            panViewUpdates += 1
        }

        let elapsed = now - windowStart
        guard elapsed >= 1 else { return }
        let panInputRate = Double(panInputEvents) / elapsed
        let panUpdateRate = Double(panViewUpdates) / elapsed
        let zoomInputRate = Double(zoomInputEvents) / elapsed
        let zoomUpdateRate = Double(zoomViewUpdates) / elapsed
        let scenePassRate = Double(zoomScenePasses) / elapsed
        let averageNodesPerPass = zoomScenePasses > 0
            ? Double(zoomSceneNodeVisits) / Double(zoomScenePasses)
            : 0
        let averageResponse = zoomViewUpdates > 0
            ? zoomResponseTotalMilliseconds / Double(zoomViewUpdates)
            : 0
        let averageMainQueue = zoomMainQueueSamples > 0
            ? zoomMainQueueTotalMilliseconds / Double(zoomMainQueueSamples)
            : 0
        let panSummary = String(
            format: "LIVE pan: input %.0f/s | host %.0f/s",
            panInputRate,
            panUpdateRate
        )
        let zoomSummary = String(
            format: "LIVE zoom: input %.0f/s | host %.0f/s | scene %.0f/s x %.0f nodes | bodies %d (img %d, comp %d/%d pieces, shape %d, trap %d) | host %.2fms avg %.2f max | main %.2fms avg %.2f max",
            zoomInputRate,
            zoomUpdateRate,
            scenePassRate,
            averageNodesPerPass,
            zoomOverlayBodies,
            zoomImageBodies,
            zoomCompositeBodies,
            zoomCompositePieces,
            zoomShapeBodies,
            zoomTrapezoidBodies,
            averageResponse,
            zoomResponseMaxMilliseconds,
            averageMainQueue,
            zoomMainQueueMaxMilliseconds
        )
        let summary = panSummary + "\n" + zoomSummary

        canvasTelemetryWindowStart = now
        panInputEvents = 0
        zoomInputEvents = 0
        panViewUpdates = 0
        zoomViewUpdates = 0
        zoomScenePasses = 0
        zoomSceneNodeVisits = 0
        zoomOverlayBodies = 0
        zoomImageBodies = 0
        zoomCompositeBodies = 0
        zoomCompositePieces = 0
        zoomShapeBodies = 0
        zoomTrapezoidBodies = 0
        zoomResponseTotalMilliseconds = 0
        zoomResponseMaxMilliseconds = 0
        zoomMainQueueTotalMilliseconds = 0
        zoomMainQueueMaxMilliseconds = 0
        zoomMainQueueSamples = 0
        if let zoomTime = lastZoomInputTime, now - zoomTime > 0.25 {
            zoomProfilingActive = false
            lastZoomInputTime = nil
        }
        DispatchQueue.main.async { [weak self] in
            self?.liveCanvasPerformance = summary
        }
    }

    func recordZoomScenePass(nodeCount: Int) {
        guard zoomProfilingActive else { return }
        zoomScenePasses += 1
        zoomSceneNodeVisits += nodeCount
    }

    func recordZoomOverlayBody(hasImage: Bool, previewPieceCount: Int, isTrapezoid: Bool) {
        guard zoomProfilingActive else { return }
        zoomOverlayBodies += 1
        if isTrapezoid {
            zoomTrapezoidBodies += 1
        } else if hasImage {
            zoomImageBodies += 1
        } else if previewPieceCount > 0 {
            zoomCompositeBodies += 1
            zoomCompositePieces += previewPieceCount
        } else {
            zoomShapeBodies += 1
        }
    }

    private func scheduleZoomMainQueueProbe(startedAt: CFAbsoluteTime) {
        guard !zoomMainQueueProbePending else { return }
        zoomMainQueueProbePending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let milliseconds = max(0, (CFAbsoluteTimeGetCurrent() - startedAt) * 1_000)
            self.zoomMainQueueSamples += 1
            self.zoomMainQueueTotalMilliseconds += milliseconds
            self.zoomMainQueueMaxMilliseconds = max(self.zoomMainQueueMaxMilliseconds, milliseconds)
            self.zoomMainQueueProbePending = false
        }
    }

    func clear() {
        entries.removeAll()
        seenKeys.removeAll()
        deferredEntries.removeAll()
        exportEntries.removeAll()
    }

    func copyToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(plainText, forType: .string)
    }

    func exportText() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "roomweaver-import-log.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? plainText.write(to: url, atomically: true, encoding: .utf8)
    }

    func exportEditorLayout() {
        if lastEditorLayoutTSV.isEmpty, let lastImportedDocument {
            let start = CFAbsoluteTimeGetCurrent()
            lastEditorLayoutTSV = makeEditorLayoutTSV(document: lastImportedDocument)
            performanceSample(
                operation: "Editor TSV generation",
                milliseconds: (CFAbsoluteTimeGetCurrent() - start) * 1_000
            )
        }
        guard !lastEditorLayoutTSV.isEmpty else {
            log(.warning, "No editor layout to export", detail: "Import a room first.")
            return
        }
        let panel = NSSavePanel()
        let room = lastImportedDocument?.name.replacingOccurrences(of: ".xml", with: "") ?? "room"
        panel.nameFieldStringValue = "editor_\(room)_latest.tsv"
        panel.allowedContentTypes = [.tabSeparatedText, .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try lastEditorLayoutTSV.write(to: url, atomically: true, encoding: .utf8)
            log(.info, "Editor runtime-layout exported", detail: url.path)
        } catch {
            log(.error, "Editor runtime-layout export failed", detail: error.localizedDescription)
        }
    }

    func importRuntimeSnapshot() {
        let panel = NSOpenPanel()
        panel.title = "Choose Vector 2 runtime_room_latest.tsv"
        panel.prompt = "Compare Runtime Layout"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.tabSeparatedText, .plainText, .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            compareRuntimeSnapshot(text, filename: url.lastPathComponent)
        } catch {
            log(.error, "Runtime snapshot could not be read", detail: error.localizedDescription)
        }
    }

    private func compareRuntimeSnapshot(_ text: String, filename: String) {
        let dataLines = text.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.hasPrefix("#") }
        guard let headerLine = dataLines.first else {
            log(.error, "Runtime snapshot is empty", detail: filename)
            return
        }
        let headers = headerLine.components(separatedBy: "\t")
        let index = Dictionary(uniqueKeysWithValues: headers.enumerated().map { ($1, $0) })
        guard let nameIndex = index["name"], let pathIndex = index["path"],
              let worldXIndex = index["worldX"], let worldYIndex = index["worldY"] else {
            log(.error, "Unsupported runtime snapshot", detail: "Missing required TSV columns in \(filename)")
            return
        }
        let assetIndex = index["asset"]
        let layerIndex = index["renderLayer"]
        let rotationIndex = index["worldRotZ"]
        let sizeXIndex = index["boundsSizeX"]
        let sizeYIndex = index["boundsSizeY"]

        struct RuntimePoint {
            let label: String
            let x: Double
            let y: Double
            let rotation: Double?
            let width: Double?
            let height: Double?
            let asset: String
            let layer: String
        }
        var runtimeByKey: [String: [RuntimePoint]] = [:]
        let roomStem = (lastImportedDocument?.name ?? "")
            .replacingOccurrences(of: ".xml", with: "")
        let runtimeRoomPrefix = roomStem.isEmpty ? "" : "Object: \(roomStem)_editor"
        var scopedRuntimeRowCount = 0
        for line in dataLines.dropFirst() {
            let fields = line.components(separatedBy: "\t")
            guard fields.indices.contains(nameIndex), fields.indices.contains(pathIndex),
                  fields.indices.contains(worldXIndex), fields.indices.contains(worldYIndex),
                  let x = Double(fields[worldXIndex]), let y = Double(fields[worldYIndex]) else { continue }
            let name = fields[nameIndex]
            let path = fields[pathIndex]
            if !runtimeRoomPrefix.isEmpty && !path.hasPrefix(runtimeRoomPrefix) { continue }
            scopedRuntimeRowCount += 1
            let asset = assetIndex.flatMap { fields.indices.contains($0) ? fields[$0] : nil } ?? ""
            let layer = layerIndex.flatMap { fields.indices.contains($0) ? fields[$0] : nil } ?? ""
            let rotation = rotationIndex.flatMap { fields.indices.contains($0) ? Double(fields[$0]) : nil }
            let width = sizeXIndex.flatMap { fields.indices.contains($0) ? Double(fields[$0]) : nil }
            let height = sizeYIndex.flatMap { fields.indices.contains($0) ? Double(fields[$0]) : nil }
            let keys = Set([comparisonKey(name), comparisonKey(asset)].filter { !$0.isEmpty })
            for key in keys {
                runtimeByKey[key, default: []].append(RuntimePoint(label: path, x: x, y: y, rotation: rotation, width: width, height: height, asset: asset, layer: layer))
            }
        }

        let editorRows = parseLayoutRows(lastEditorLayoutTSV)
        var editorByKey: [String: [LayoutPoint]] = [:]
        for row in editorRows {
            let keys = Set([comparisonKey(row.name), comparisonKey(row.asset)].filter { !$0.isEmpty })
            for key in keys {
                editorByKey[key, default: []].append(row)
            }
        }

        let uniqueKeys = Set(runtimeByKey.keys).intersection(editorByKey.keys).filter {
            runtimeByKey[$0]?.count == 1 && editorByKey[$0]?.count == 1
        }
        var offsetsX: [Double] = []
        var offsetsY: [Double] = []
        for key in uniqueKeys {
            guard let runtime = runtimeByKey[key]?.first, let editor = editorByKey[key]?.first else { continue }
            offsetsX.append(editor.x - runtime.x)
            offsetsY.append(editor.y - runtime.y)
        }
        let offsetX = median(offsetsX)
        let offsetY = median(offsetsY)

        var residuals: [(label: String, distance: Double, dx: Double, dy: Double, detail: String)] = []
        for key in uniqueKeys {
            guard let runtime = runtimeByKey[key]?.first, let editor = editorByKey[key]?.first else { continue }
            let dx = editor.x - (runtime.x + offsetX)
            let dy = editor.y - (runtime.y + offsetY)
            let rotationDelta = angleDelta(editor.rotation, runtime.rotation)
            let widthDelta = optionalDelta(editor.width, runtime.width)
            let heightDelta = optionalDelta(editor.height, runtime.height)
            let layerMismatch = !editor.layer.isEmpty && !runtime.layer.isEmpty && editor.layer != runtime.layer
            let detail = "rotationDelta=\(formatOptional(rotationDelta)) boundsDelta=(\(formatOptional(widthDelta)),\(formatOptional(heightDelta))) layer=\(editor.layer.isEmpty ? "-" : editor.layer)/\(runtime.layer.isEmpty ? "-" : runtime.layer)\(layerMismatch ? " MISMATCH" : "") asset=\(editor.asset.isEmpty ? runtime.asset : editor.asset)"
            residuals.append(("\(editor.path) <-> \(runtime.label)", hypot(dx, dy), dx, dy, detail))
        }
        residuals.sort { $0.distance > $1.distance }

        log(
            .info,
            "Runtime layout snapshot imported",
            detail: "\(filename) | runtimeRows=\(dataLines.count - 1) scopedRuntimeRows=\(scopedRuntimeRowCount) scope=\(runtimeRoomPrefix.isEmpty ? "all" : runtimeRoomPrefix) editorRows=\(editorRows.count) runtimeKeys=\(runtimeByKey.count) editorKeys=\(editorByKey.count) uniqueMatches=\(uniqueKeys.count) calibratedOffset=(\(formatNumber(offsetX)),\(formatNumber(offsetY)))"
        )
        for residual in residuals.prefix(160) where residual.distance > 0.5 || residual.detail.contains("MISMATCH") {
            log(
                residual.distance > 20 ? .warning : .info,
                "Runtime/editor field delta",
                detail: "\(residual.label) | positionDelta=(\(formatNumber(residual.dx)),\(formatNumber(residual.dy))) distance=\(formatNumber(residual.distance)) | \(residual.detail)"
            )
        }
        if uniqueKeys.isEmpty {
            log(.warning, "No unique runtime/editor names matched", detail: "The snapshot was loaded; capture output will be used to extend the resolver keys.")
        }

        // Repeated sprites are the normal case in Vector 2, so unique-name
        // matching alone discards most of the room. Pair every final editor
        // renderer with the nearest unused runtime renderer sharing asset and
        // sorting layer after calibration, and report every field that differs.
        let runtimeRows = parseLayoutRows(text).filter {
            !$0.asset.isEmpty && (runtimeRoomPrefix.isEmpty || $0.path.hasPrefix(runtimeRoomPrefix))
        }
        let editorRenderRows = editorRows.filter { !$0.asset.isEmpty }
        let runtimeGroups = Dictionary(grouping: runtimeRows) { rendererKey(asset: $0.asset, layer: $0.layer) }
        let editorGroups = Dictionary(grouping: editorRenderRows) { rendererKey(asset: $0.asset, layer: $0.layer) }
        let rendererKeys = Set(runtimeGroups.keys).union(editorGroups.keys).sorted()
        var matchedRendererCount = 0
        var unmatchedRuntimeCount = 0
        var unmatchedEditorCount = 0
        var rendererMismatches: [(severity: Double, detail: String)] = []

        for key in rendererKeys {
            let runtimeGroup = runtimeGroups[key] ?? []
            let editorGroup = editorGroups[key] ?? []
            if runtimeGroup.count != editorGroup.count {
                log(
                    .warning,
                    "Runtime/editor renderer count mismatch",
                    detail: "\(key) | game=\(runtimeGroup.count) editor=\(editorGroup.count) delta=\(editorGroup.count - runtimeGroup.count)"
                )
            }
            var available = Array(runtimeGroup.indices)
            for editor in editorGroup {
                guard let best = available.min(by: { left, right in
                    let l = hypot(editor.x - (runtimeGroup[left].x + offsetX), editor.y - (runtimeGroup[left].y + offsetY))
                    let r = hypot(editor.x - (runtimeGroup[right].x + offsetX), editor.y - (runtimeGroup[right].y + offsetY))
                    return l < r
                }) else {
                    unmatchedEditorCount += 1
                    continue
                }
                available.removeAll { $0 == best }
                matchedRendererCount += 1
                let runtime = runtimeGroup[best]
                let dx = editor.x - (runtime.x + offsetX)
                let dy = editor.y - (runtime.y + offsetY)
                let distance = hypot(dx, dy)
                let dr = angleDelta(editor.rotation, runtime.rotation)
                let dw = optionalDelta(editor.width, runtime.width)
                let dh = optionalDelta(editor.height, runtime.height)
                let magnitude = max(distance, abs(dr ?? 0), abs(dw ?? 0), abs(dh ?? 0))
                if magnitude > 0.5 {
                    rendererMismatches.append((
                        magnitude,
                        "\(key) | editor=\(editor.path) | game=\(runtime.path) | positionDelta=(\(formatNumber(dx)),\(formatNumber(dy))) distance=\(formatNumber(distance)) rotationDelta=\(formatOptional(dr)) boundsDelta=(\(formatOptional(dw)),\(formatOptional(dh)))"
                    ))
                }
            }
            unmatchedRuntimeCount += available.count
        }
        rendererMismatches.sort { $0.severity > $1.severity }
        log(
            .info,
            "Full renderer comparison",
            detail: "matched=\(matchedRendererCount) mismatched=\(rendererMismatches.count) unmatchedGame=\(unmatchedRuntimeCount) unmatchedEditor=\(unmatchedEditorCount) assetLayerGroups=\(rendererKeys.count)"
        )
        for mismatch in rendererMismatches.prefix(400) {
            log(mismatch.severity > 20 ? .warning : .info, "Runtime/editor renderer delta", detail: mismatch.detail)
        }
    }

    private func rendererKey(asset: String, layer: String) -> String {
        let unqualifiedAsset = asset.components(separatedBy: "__").last ?? asset
        return "asset=\(comparisonKey(unqualifiedAsset))|layer=\(layer.lowercased())"
    }

    private struct LayoutPoint {
        let path: String
        let name: String
        let x: Double
        let y: Double
        let rotation: Double?
        let width: Double?
        let height: Double?
        let asset: String
        let layer: String
    }

    private func parseLayoutRows(_ text: String) -> [LayoutPoint] {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.hasPrefix("#") }
        guard let header = lines.first else { return [] }
        let columns = header.components(separatedBy: "\t")
        let indexes = Dictionary(uniqueKeysWithValues: columns.enumerated().map { ($1, $0) })
        func field(_ fields: [String], _ name: String) -> String {
            guard let i = indexes[name], fields.indices.contains(i) else { return "" }
            return fields[i]
        }
        return lines.dropFirst().compactMap { line in
            let fields = line.components(separatedBy: "\t")
            guard let x = Double(field(fields, "worldX")), let y = Double(field(fields, "worldY")) else { return nil }
            return LayoutPoint(
                path: field(fields, "path"), name: field(fields, "name"), x: x, y: y,
                rotation: Double(field(fields, "worldRotZ")),
                width: Double(field(fields, "boundsSizeX")), height: Double(field(fields, "boundsSizeY")),
                asset: field(fields, "asset"), layer: field(fields, "renderLayer")
            )
        }
    }

    private func angleDelta(_ lhs: Double?, _ rhs: Double?) -> Double? {
        guard let lhs, let rhs else { return nil }
        var value = (lhs - rhs).truncatingRemainder(dividingBy: 360)
        if value > 180 { value -= 360 }
        if value < -180 { value += 360 }
        return value
    }

    private func optionalDelta(_ lhs: Double?, _ rhs: Double?) -> Double? {
        guard let lhs, let rhs else { return nil }
        return lhs - rhs
    }

    private func formatOptional(_ value: Double?) -> String {
        value.map(formatNumber) ?? "-"
    }

    private struct LayoutAffine {
        var x: Double = 0
        var y: Double = 0
        var xx: Double = 1
        var xy: Double = 0
        var yx: Double = 0
        var yy: Double = 1

        func point(_ x: Double, _ y: Double) -> (Double, Double) {
            (self.x + x * xx + y * yx, self.y + x * xy + y * yy)
        }

        func vector(_ x: Double, _ y: Double) -> (Double, Double) {
            (x * xx + y * yx, x * xy + y * yy)
        }
    }

    private func makeEditorLayoutTSV(document: LevelDocument) -> String {
        let header = "path\tname\tactive\tlayer\tlocalX\tlocalY\tlocalZ\tworldX\tworldY\tworldZ\tlocalRotZ\tworldRotZ\tlocalScaleX\tlocalScaleY\tlossyScaleX\tlossyScaleY\trendererType\trenderLayer\trenderOrder\tboundsCenterX\tboundsCenterY\tboundsSizeX\tboundsSizeY\tasset\tmaterial\tcomponents"
        var rows: [String] = []

        func clean(_ value: String) -> String {
            value.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        }
        func number(_ value: Double) -> String {
            if abs(value) < 0.0000005 { return "0" }
            return String(format: "%.6f", value).replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
        }
        func context(for node: LevelNode, parent: LayoutAffine) -> LayoutAffine {
            let transform = node.transform ?? .init(x: 0, y: 0, width: 1, height: 1)
            let origin = parent.point(Double(transform.x), Double(transform.y))
            let a: Double
            let b: Double
            let c: Double
            let d: Double
            if let ma = Double(node.metadata.matrixA), let mb = Double(node.metadata.matrixB),
               let mc = Double(node.metadata.matrixC), let md = Double(node.metadata.matrixD) {
                (a, b, c, d) = (ma, mb, mc, md)
            } else {
                let radians = transform.rotation * .pi / 180
                (a, b, c, d) = (cos(radians), sin(radians), -sin(radians), cos(radians))
            }
            return LayoutAffine(
                x: origin.0, y: origin.1,
                xx: parent.xx * a + parent.yx * b,
                xy: parent.xy * a + parent.yy * b,
                yx: parent.xx * c + parent.yx * d,
                yy: parent.xy * c + parent.yy * d
            )
        }
        func appendRow(
            path: String, name: String, active: Bool, layer: String,
            localX: Double, localY: Double, worldX: Double, worldY: Double,
            localRotation: Double, worldRotation: Double,
            localScaleX: Double = 1, localScaleY: Double = 1,
            lossyScaleX: Double = 1, lossyScaleY: Double = 1,
            rendererType: String = "", renderLayer: String = "", renderOrder: String = "",
            boundsCenterX: Double? = nil, boundsCenterY: Double? = nil,
            boundsSizeX: Double? = nil, boundsSizeY: Double? = nil,
            asset: String = "", material: String = "", components: String
        ) {
            let values = [
                clean(path), clean(name), active ? "1" : "0", clean(layer),
                number(localX), number(localY), "0", number(worldX), number(worldY), "0",
                number(localRotation), number(worldRotation), number(localScaleX), number(localScaleY),
                number(lossyScaleX), number(lossyScaleY), clean(rendererType), clean(renderLayer), renderOrder,
                boundsCenterX.map(number) ?? "", boundsCenterY.map(number) ?? "",
                boundsSizeX.map(number) ?? "", boundsSizeY.map(number) ?? "",
                clean(asset), clean(material), clean(components)
            ]
            rows.append(values.joined(separator: "\t"))
        }
        func bounds(origin: (Double, Double), axisX: (Double, Double), axisY: (Double, Double)) -> (Double, Double, Double, Double) {
            let points = [
                origin,
                (origin.0 + axisX.0, origin.1 + axisX.1),
                (origin.0 + axisX.0 + axisY.0, origin.1 + axisX.1 + axisY.1),
                (origin.0 + axisY.0, origin.1 + axisY.1)
            ]
            let minX = points.map { $0.0 }.min() ?? origin.0
            let maxX = points.map { $0.0 }.max() ?? origin.0
            let minY = points.map { $0.1 }.min() ?? origin.1
            let maxY = points.map { $0.1 }.max() ?? origin.1
            return ((minX + maxX) / 2, (minY + maxY) / 2, maxX - minX, maxY - minY)
        }

        func walk(_ node: LevelNode, parentPath: String, parent: LayoutAffine, depth: Int, renderEnabled: Bool) {
            let label = node.name.isEmpty ? node.kind.rawValue : node.name
            let path = parentPath.isEmpty ? label : "\(parentPath)/\(label)"
            let transform = node.transform ?? .init(x: 0, y: 0, width: 0, height: 0)
            let nodeContext = context(for: node, parent: parent)
            let worldOrigin = parent.point(Double(transform.x), Double(transform.y))
            let worldRotation = atan2(nodeContext.xy, nodeContext.xx) * 180 / .pi
            let scaleX = hypot(nodeContext.xx, nodeContext.xy)
            let scaleY = hypot(nodeContext.yx, nodeContext.yy)
            let hasRenderer = renderEnabled && !node.metadata.imagePath.isEmpty && node.previewPieces.isEmpty
            var rendererBounds: (Double, Double, Double, Double)?
            if hasRenderer {
                let origin = parent.point(Double(transform.x + node.metadata.visualOffsetX), Double(transform.y + node.metadata.visualOffsetY))
                let axisX = parent.vector(Double(transform.width), 0)
                let axisY = parent.vector(0, Double(transform.height))
                rendererBounds = bounds(origin: origin, axisX: axisX, axisY: axisY)
            }
            appendRow(
                path: path, name: label, active: !node.metadata.isHidden, layer: node.metadata.sortingLayer,
                localX: Double(transform.x), localY: Double(transform.y), worldX: worldOrigin.0, worldY: worldOrigin.1,
                localRotation: transform.rotation, worldRotation: worldRotation,
                lossyScaleX: scaleX, lossyScaleY: scaleY,
                rendererType: hasRenderer ? "SpriteRenderer" : "", renderLayer: hasRenderer ? node.metadata.sortingLayer : "",
                boundsCenterX: rendererBounds?.0, boundsCenterY: rendererBounds?.1,
                boundsSizeX: rendererBounds?.2, boundsSizeY: rendererBounds?.3,
                asset: hasRenderer ? (node.metadata.className.isEmpty ? URL(fileURLWithPath: node.metadata.imagePath).deletingPathExtension().lastPathComponent : node.metadata.className) : "",
                material: hasRenderer ? node.xml.blend : "",
                components: "Editor.LevelNode,kind=\(node.kind.rawValue),visualType=\(node.metadata.visualType),file=\(node.metadata.filename),dynamicCount=\(node.metadata.resolvedDynamicCount),dynamicOwners=\(node.metadata.resolvedDynamicOwners)"
            )

            if renderEnabled && !node.previewPieces.isEmpty {
                // Mirrors CanvasRenderer.roomWeaverReferenceDisplayNodes: pieces
                // are already resolved through the reference's own matrix and
                // only inherit the room-parent affine here.
                let groupX = Double(transform.x + node.metadata.visualOffsetX)
                let groupY = Double(transform.y + node.metadata.visualOffsetY)
                for (index, piece) in node.previewPieces.enumerated() {
                    let localOrigin = (groupX + piece.centerX, groupY + piece.centerY)
                    let origin = parent.point(localOrigin.0, localOrigin.1)
                    let axisX: (Double, Double)
                    let axisY: (Double, Double)
                    if let xx = piece.basisXX, let xy = piece.basisXY,
                       let yx = piece.basisYX, let yy = piece.basisYY {
                        axisX = parent.vector(xx, xy)
                        axisY = parent.vector(yx, yy)
                    } else {
                        let radians = piece.rotation * .pi / 180
                        axisX = parent.vector(cos(radians) * piece.width, sin(radians) * piece.width)
                        axisY = parent.vector(-sin(radians) * piece.height, cos(radians) * piece.height)
                    }
                    let pieceBounds = bounds(origin: origin, axisX: axisX, axisY: axisY)
                    let pieceName = "VisualRunner: \(URL(fileURLWithPath: piece.imagePath).deletingPathExtension().lastPathComponent)"
                    appendRow(
                        path: "\(path)/\(pieceName)[\(index)]", name: pieceName, active: !node.metadata.isHidden, layer: piece.sortingLayer,
                        localX: localOrigin.0, localY: localOrigin.1, worldX: origin.0, worldY: origin.1,
                        localRotation: piece.rotation, worldRotation: atan2(axisX.1, axisX.0) * 180 / .pi,
                        localScaleX: piece.width, localScaleY: piece.height,
                        lossyScaleX: hypot(axisX.0, axisX.1), lossyScaleY: hypot(axisY.0, axisY.1),
                        rendererType: "SpriteRenderer", renderLayer: piece.sortingLayer,
                        boundsCenterX: pieceBounds.0, boundsCenterY: pieceBounds.1,
                        boundsSizeX: pieceBounds.2, boundsSizeY: pieceBounds.3,
                        asset: URL(fileURLWithPath: piece.imagePath).deletingPathExtension().lastPathComponent,
                        material: node.xml.blend,
                        components: "Editor.PreviewPiece,owner=\(path),piece=\(index),mirrored=\(piece.mirrored),dynamicCount=\(node.metadata.resolvedDynamicCount),dynamicOwners=\(node.metadata.resolvedDynamicOwners)"
                    )
                }
            }
            // CanvasRenderer uses a reference's resolved previewPieces as the
            // authoritative visual and does not also draw its expanded helper
            // children. Keep child hierarchy rows for diagnosis, but suppress
            // their renderer fields so this TSV represents the actual canvas.
            let childrenRender = renderEnabled && node.previewPieces.isEmpty
            for child in node.children {
                walk(
                    child,
                    parentPath: path,
                    parent: node.metadata.visualType == "RoomWeaverContainer" ? nodeContext : parent,
                    depth: depth + 1,
                    renderEnabled: childrenRender
                )
            }
        }

        walk(document.root, parentPath: "", parent: .init(), depth: 0, renderEnabled: true)
        return [
            "# Vector 2 Editor Room Layout v1",
            "# capturedUTC=\(ISO8601DateFormatter().string(from: Date()))",
            "# document=\(document.name)",
            "# sourcePath=\(document.sourcePath ?? "")",
            "# count=\(rows.count)",
            header
        ].joined(separator: "\n") + "\n" + rows.joined(separator: "\n") + "\n"
    }

    private func comparisonKey(_ raw: String) -> String {
        let suffix = raw.components(separatedBy: ":").last ?? raw
        return suffix.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    private func formatNumber(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    private func log(_ level: Entry.Level, _ message: String, detail: String = "", dedupeKey: String? = nil, deferred: Bool = false) {
        if let dedupeKey, !seenKeys.insert(dedupeKey).inserted {
            return
        }
        if deferred {
            let entry = Entry(level: level, message: message, detail: detail)
            deferredEntries.append(entry)
            if deferredEntries.count > 1800 {
                deferredEntries.removeFirst(deferredEntries.count - 1800)
            }
        } else {
            let entry = Entry(level: level, message: message, detail: detail)
            exportEntries.append(entry)
            entries.append(entry)
            trimEntries()
        }
    }

    private func flushDeferredEntries() {
        guard !deferredEntries.isEmpty else { return }
        exportEntries.append(contentsOf: deferredEntries)
        entries.append(contentsOf: deferredEntries)
        deferredEntries.removeAll()
        trimEntries()
    }

    private func trimEntries() {
        let liveLimit = verboseEnabled ? max(liveEntryLimit, 900) : liveEntryLimit
        let exportLimit = verboseEnabled ? max(exportEntryLimit, 12_000) : exportEntryLimit
        if entries.count > liveLimit {
            let pinnedCount = min(8, entries.count)
            let remainingCount = max(0, liveLimit - pinnedCount)
            entries = Array(entries.prefix(pinnedCount)) + Array(entries.suffix(remainingCount))
        }
        if exportEntries.count > exportLimit {
            exportEntries.removeFirst(exportEntries.count - exportLimit)
        }
    }

    private func logImportBreakdown(document: LevelDocument, nodes: [LevelNode]) {
        let allNodes = document.root.allDescendantsIncludingSelf()
        let hiddenCount = allNodes.filter(\.metadata.isHidden).count
        let helperCount = allNodes.filter { $0.metadata.visualType == "RoomWeaverHelperOverlay" }.count
        let containerCount = allNodes.filter { $0.metadata.visualType == "RoomWeaverContainer" }.count
        let libraryReferenceCount = allNodes.filter { $0.metadata.visualType == "RoomWeaverLibraryReference" }.count
        let previewPieceNodes = allNodes.filter { !$0.previewPieces.isEmpty }
        let previewPieces = previewPieceNodes.reduce(0) { $0 + $1.previewPieces.count }
        let imagesWithPaths = allNodes.filter { !$0.metadata.imagePath.isEmpty }.count
        let transformed = allNodes.filter { $0.transform != nil }.count
        let kindSummary = Dictionary(grouping: nodes, by: { $0.kind.rawValue })
            .map { "\($0.key)=\($0.value.count)" }
            .sorted()
            .joined(separator: ", ")
        log(
            .info,
            "RoomWeaver import breakdown",
            detail: "tree=\(allNodes.count) flattened=\(nodes.count) transformed=\(transformed) hidden=\(hiddenCount) helpers=\(helperCount) containers=\(containerCount) refs=\(libraryReferenceCount) imagePaths=\(imagesWithPaths) previewNodes=\(previewPieceNodes.count) previewPieces=\(previewPieces)"
        )
        log(.info, "RoomWeaver flattened kinds", detail: kindSummary.isEmpty ? "-" : kindSummary)

        let heavyPreviewNodes = previewPieceNodes
            .sorted { $0.previewPieces.count > $1.previewPieces.count }
            .prefix(20)
            .map { node in
                "\(node.name.isEmpty ? "-" : node.name): pieces=\(node.previewPieces.count) file=\(emptyDash(node.metadata.filename)) layer=\(emptyDash(node.metadata.sortingLayer))"
            }
            .joined(separator: "\n")
        if !heavyPreviewNodes.isEmpty {
            log(.info, "Largest RoomWeaver previews", detail: heavyPreviewNodes)
        }
    }

    /// A high-signal trace of RoomWeaver's actual scene representation. This
    /// deliberately records local/source transforms and preview geometry side
    /// by side so a runtime capture can expose the first bad hierarchy edge,
    /// instead of leaving us to infer it from a screenshot.
    private func logDeepImportDiagnostics(document: LevelDocument) {
        struct Record {
            let path: String
            let depth: Int
            let node: LevelNode
        }

        var records: [Record] = []
        func walk(_ node: LevelNode, path: String, depth: Int) {
            let label = node.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? node.kind.rawValue
                : node.name
            let nextPath = path.isEmpty ? label : "\(path)/\(label)"
            records.append(.init(path: nextPath, depth: depth, node: node))
            for child in node.children {
                walk(child, path: nextPath, depth: depth + 1)
            }
        }
        walk(document.root, path: "", depth: 0)

        let references = records.filter {
            $0.node.metadata.visualType == "RoomWeaverLibraryReference"
        }
        let containers = records.filter {
            $0.node.metadata.visualType == "RoomWeaverContainer"
        }
        let affineImages = records.filter {
            $0.node.kind == .image && !$0.node.metadata.matrixA.isEmpty
        }
        let shapes = records.filter {
            $0.node.kind == .trigger || $0.node.kind == .area
                || $0.node.kind == .platform || $0.node.kind == .trapezoid
        }
        let dynamics = records.filter {
            hasSpatialDynamic($0.node.metadata.dynamicXML)
                || $0.node.metadata.resolvedDynamicCount > 0
        }
        let edited = records.filter(\.node.metadata.isTransformEdited)
        let previewPieces = records.reduce(0) { $0 + $1.node.previewPieces.count }
        let layerSummary = Dictionary(grouping: records, by: {
            let layer = $0.node.metadata.sortingLayer.trimmingCharacters(in: .whitespacesAndNewlines)
            return layer.isEmpty ? "(unset)" : layer
        })
            .map { "\($0.key)=\($0.value.count)" }
            .sorted()
            .joined(separator: ", ")

        log(
            .info,
            "RoomWeaver deep scene audit",
            detail: "tree=\(records.count) maxDepth=\(records.map(\.depth).max() ?? 0) | containers=\(containers.count) references=\(references.count) affineImages=\(affineImages.count) shapes=\(shapes.count) dynamics=\(dynamics.count) edited=\(edited.count) previewPieces=\(previewPieces)"
        )
        log(.info, "RoomWeaver layer population", detail: layerSummary.isEmpty ? "none" : layerSummary)

        for record in references.prefix(240) {
            let node = record.node
            let pieceLayers = Dictionary(grouping: node.previewPieces, by: \.sortingLayer)
                .map { "\($0.key):\($0.value.count)" }
                .sorted()
                .joined(separator: ",")
            let pieceBounds = previewBounds(node.previewPieces)
            log(
                .info,
                "Reference hierarchy",
                detail: "path=\(record.path) | \(diagnosticTransform(node)) | source=(\(emptyDash(node.metadata.sourceX)),\(emptyDash(node.metadata.sourceY))) matrix=\(diagnosticMatrix(node)) | visualOffset=(\(node.metadata.visualOffsetX),\(node.metadata.visualOffsetY)) native=\(node.metadata.visualNativeWidth)x\(node.metadata.visualNativeHeight) | pieces=\(node.previewPieces.count) pieceBounds=\(pieceBounds) layers=[\(pieceLayers)] children=\(node.children.count) | file=\(emptyDash(node.metadata.filename)) class=\(emptyDash(node.metadata.className)) dynamic=\(node.metadata.resolvedDynamicCount)[\(emptyDash(node.metadata.resolvedDynamicOwners))]",
                dedupeKey: "deep-reference:\(node.id)"
            )

            let pieceDetail = node.previewPieces.prefix(500).enumerated().map { index, piece in
                let basis: String
                if let xx = piece.basisXX, let xy = piece.basisXY,
                   let yx = piece.basisYX, let yy = piece.basisYY {
                    basis = "basis=[\(formatNumber(xx)),\(formatNumber(xy)),\(formatNumber(yx)),\(formatNumber(yy))]"
                } else {
                    basis = "size=\(formatNumber(piece.width))x\(formatNumber(piece.height)) r=\(formatNumber(piece.rotation))"
                }
                return "\(index): layer=\(emptyDash(piece.sortingLayer)) origin=(\(formatNumber(piece.centerX)),\(formatNumber(piece.centerY))) \(basis) mirror=\(piece.mirrored) image=\(URL(fileURLWithPath: piece.imagePath).lastPathComponent)"
            }.joined(separator: "\n")
            if !pieceDetail.isEmpty {
                log(
                    .info,
                    "Reference piece map",
                    detail: "path=\(record.path)\n\(pieceDetail)",
                    dedupeKey: "deep-reference-pieces:\(node.id)"
                )
            }

            if let transform = node.transform,
               let sourceX = Double(node.metadata.sourceX),
               let sourceY = Double(node.metadata.sourceY),
               let tx = Double(node.metadata.matrixTx),
               let ty = Double(node.metadata.matrixTy) {
                let expectedX = sourceX + tx
                let expectedY = sourceY + ty
                let deltaX = Double(transform.x) - expectedX
                let deltaY = Double(transform.y) - expectedY
                if abs(deltaX) > 0.51 || abs(deltaY) > 0.51 {
                    log(
                        .warning,
                        "Reference translation mismatch",
                        detail: "path=\(record.path) source=(\(sourceX),\(sourceY)) matrixTranslation=(\(tx),\(ty)) expected=(\(formatNumber(expectedX)),\(formatNumber(expectedY))) stored=(\(transform.x),\(transform.y)) delta=(\(formatNumber(deltaX)),\(formatNumber(deltaY)))",
                        dedupeKey: "reference-translation-mismatch:\(node.id)"
                    )
                }
            }
        }

        for record in affineImages.prefix(400) {
            let node = record.node
            let sourcePosition = "source=(\(emptyDash(node.metadata.sourceX)),\(emptyDash(node.metadata.sourceY)))"
            log(
                .info,
                "Affine image hierarchy",
                detail: "path=\(record.path) | \(diagnosticTransform(node)) | \(sourcePosition) matrix=\(diagnosticMatrix(node)) txTy=(\(emptyDash(node.metadata.matrixTx)),\(emptyDash(node.metadata.matrixTy))) | offset=(\(node.metadata.visualOffsetX),\(node.metadata.visualOffsetY)) native=\(node.metadata.visualNativeWidth)x\(node.metadata.visualNativeHeight) layer=\(emptyDash(node.metadata.sortingLayer)) image=\(URL(fileURLWithPath: node.metadata.imagePath).lastPathComponent)",
                dedupeKey: "deep-image:\(node.id)"
            )
        }

        for record in dynamics.prefix(240) {
            let node = record.node
            let directBlocks = node.metadata.dynamicXML
                .components(separatedBy: "<Dynamic")
                .dropFirst()
                .enumerated()
                .map { index, block in
                    let move = block.contains("<MoveInterval")
                    let rotate = block.contains("<RotationInterval")
                    let resize = block.contains("<SizeInterval")
                    let visualOnly = !move && !rotate && !resize
                    return "#\(index) move=\(move) rotate=\(rotate) resize=\(resize) visualOnly=\(visualOnly)"
                }
                .joined(separator: ", ")
            log(
                .info,
                "Dynamic hierarchy",
                detail: "path=\(record.path) | \(diagnosticTransform(node)) | direct=\(hasSpatialDynamic(node.metadata.dynamicXML)) nested=\(node.metadata.resolvedDynamicCount) owners=[\(emptyDash(node.metadata.resolvedDynamicOwners))] children=\(node.children.count) file=\(emptyDash(node.metadata.filename)) | blocks=[\(directBlocks.isEmpty ? "none" : directBlocks)]",
                dedupeKey: "deep-dynamic:\(node.id)"
            )
        }

        for record in shapes.prefix(400) {
            let node = record.node
            var trapezoid = ""
            if node.kind == .trapezoid, let transform = node.transform {
                let type2 = node.xml.variant == "SlopeType2" || node.metadata.visualType == "2"
                let leftHeight = type2 ? transform.height : max(0, transform.height - transform.width / 2)
                let rightHeight = type2 ? max(0, transform.height - transform.width / 2) : transform.height
                trapezoid = " trapezoidVariant=\(emptyDash(node.xml.variant)) runtimeSides=(left=\(leftHeight),right=\(rightHeight)) finalBoundsYOffset=0"
            }
            log(
                .info,
                "Shape hierarchy",
                detail: "path=\(record.path) | kind=\(node.kind.rawValue) \(diagnosticTransform(node)) | source=(\(emptyDash(node.metadata.sourceX)),\(emptyDash(node.metadata.sourceY))) matrix=\(diagnosticMatrix(node)) offset=(\(node.metadata.visualOffsetX),\(node.metadata.visualOffsetY))\(trapezoid)",
                dedupeKey: "deep-shape:\(node.id)"
            )
        }
    }

    private func diagnosticTransform(_ node: LevelNode) -> String {
        guard let value = node.transform else { return "local=nil" }
        return "local=(x=\(value.x),y=\(value.y),w=\(value.width),h=\(value.height),r=\(formatted(value.rotation)))"
    }

    private func diagnosticMatrix(_ node: LevelNode) -> String {
        "[\(emptyDash(node.metadata.matrixA)),\(emptyDash(node.metadata.matrixB)),\(emptyDash(node.metadata.matrixC)),\(emptyDash(node.metadata.matrixD))]"
    }

    private func previewBounds(_ pieces: [LevelNode.PreviewPiece]) -> String {
        guard !pieces.isEmpty else { return "none" }
        let points = pieces.flatMap { piece -> [CGPoint] in
            if let xx = piece.basisXX, let xy = piece.basisXY,
               let yx = piece.basisYX, let yy = piece.basisYY {
                let origin = CGPoint(x: piece.centerX, y: piece.centerY)
                return [
                    origin,
                    CGPoint(x: origin.x + xx, y: origin.y + xy),
                    CGPoint(x: origin.x + xx + yx, y: origin.y + xy + yy),
                    CGPoint(x: origin.x + yx, y: origin.y + yy)
                ]
            }
            return [
                CGPoint(x: piece.centerX - piece.width / 2, y: piece.centerY - piece.height / 2),
                CGPoint(x: piece.centerX + piece.width / 2, y: piece.centerY + piece.height / 2)
            ]
        }
        let minX = points.map(\.x).min() ?? 0
        let maxX = points.map(\.x).max() ?? 0
        let minY = points.map(\.y).min() ?? 0
        let maxY = points.map(\.y).max() ?? 0
        return "(\(formatNumber(minX)),\(formatNumber(minY)))-(\(formatNumber(maxX)),\(formatNumber(maxY)))"
    }

    private func logUnresolvedBreakdown(_ unresolved: [LevelNode]) {
        let grouped = Dictionary(grouping: unresolved, by: unresolvedReason)
        let summary = grouped
            .map { "\($0.key)=\($0.value.count)" }
            .sorted()
            .joined(separator: ", ")
        log(.warning, "Unresolved groups", detail: summary)

        let detail = unresolved.prefix(30).enumerated().map { index, node in
            "\(index + 1). \(debugLine(for: node))"
        }.joined(separator: "\n")
        log(.info, "Unresolved detail sample", detail: detail)
    }

    private func unresolvedReason(for node: LevelNode) -> String {
        if node.kind == .image {
            return node.metadata.className.isEmpty ? "image has no class" : "image texture alias missing"
        }
        if node.kind == .objectReference {
            return "object reference has no visual pieces"
        }
        if node.xml.template == "LibraryObject" {
            return "library object has no visual pieces"
        }
        return "object has no preview or children"
    }

    private func debugLine(for node: LevelNode) -> String {
        let transform = node.transform.map {
            "x=\($0.x) y=\($0.y) w=\($0.width) h=\($0.height) r=\(formatted($0.rotation))"
        } ?? "no-transform"
        let childKinds = Dictionary(grouping: node.children, by: { $0.kind.rawValue })
            .map { "\($0.key):\($0.value.count)" }
            .sorted()
            .joined(separator: ",")
        let imageState = node.metadata.imagePath.isEmpty ? "no-image" : "image"
        let previewState = node.previewPieces.isEmpty ? "no-preview" : "preview=\(node.previewPieces.count)"
        let childState = node.children.isEmpty ? "children=0" : "children=\(node.children.count)[\(childKinds)]"
        let directDynamic = hasSpatialDynamic(node.metadata.dynamicXML)
        let dynamicState = "dynamic=\(directDynamic ? "direct" : (node.metadata.resolvedDynamicCount > 0 ? "nested:\(node.metadata.resolvedDynamicCount)" : "no"))"
        return "\(node.kind.rawValue) \"\(node.name)\" | file=\(emptyDash(node.metadata.filename)) class=\(emptyDash(node.metadata.className)) template=\(emptyDash(node.xml.template)) choice=\(emptyDash(node.xml.choice)) variant=\(emptyDash(node.xml.variant)) | \(transform) | \(imageState) \(previewState) \(childState) visualType=\(emptyDash(node.metadata.visualType)) \(dynamicState)"
    }

    private func emptyDash(_ value: String) -> String {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? "-" : clean
    }

    private func hasSpatialDynamic(_ xml: String) -> Bool {
        xml.contains("<MoveInterval")
            || xml.contains("<RotationInterval")
            || xml.contains("<SizeInterval")
    }

    private func formatted(_ value: Double) -> String {
        if abs(value.rounded() - value) < 0.0001 {
            return String(Int(value.rounded()))
        }
        return String(format: "%.2f", value)
    }
}
