//
//  TrickPreviewCatalog.swift
//  Vector2 level editor
//

import Foundation
import CoreGraphics

struct TrickPreviewCatalog {
    var gameDirectory: String = ""
    var customModelRoots: [URL] = []
    private let fileManager = FileManager.default

    func loadMoves() -> [TrickPreviewMove] {
        guard let url = resourceURL(relativePath: "Libraries/moves_new.xml")
            ?? resourceURL(relativePath: "gamedata/run_data/libraries/moves_new.xml") else {
            TrickPreviewDiagnostics.shared.log("moves_new.xml not found")
            return []
        }
        do {
            let document = try XMLDocument(contentsOf: url, options: [.nodePreserveWhitespace])
            let nodes = try document.nodes(forXPath: "//*[@FileName]")
            let moves = (nodes.compactMap(parseMove(node:)) + loadCustomMoves())
                .filter { !$0.fileName.isEmpty }
                .sorted { lhs, rhs in
                    if lhs.isTrick == rhs.isTrick {
                        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                    }
                    return lhs.isTrick && !rhs.isTrick
                }
            TrickPreviewDiagnostics.shared.log("moves xml=\(url.path) entries=\(moves.count)")
            return moves
        } catch {
            TrickPreviewDiagnostics.shared.log("moves parse failed \(url.path): \(error.localizedDescription)")
            return []
        }
    }

    func loadAnimationAreaNames() -> [String] {
        guard let url = resourceURL(relativePath: "Libraries/moves_new.xml")
            ?? resourceURL(relativePath: "gamedata/run_data/libraries/moves_new.xml"),
              let data = try? Data(contentsOf: url) else {
            return []
        }
        return GameMoveLibraryParser.animationAreaNames(from: data)
    }

    func loadModelSkins() -> [TrickPreviewModelSkin] {
        if let root = resourceURL(relativePath: "gamedata/run_data/models") {
            let urls = (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            let skins = sortedSkins(from: urls.map(\.lastPathComponent))
            TrickPreviewDiagnostics.shared.log("model skins root=\(root.path) count=\(skins.count)")
            return skins
        }

        let flatXMLs = Bundle.main.urls(forResourcesWithExtension: "xml", subdirectory: nil) ?? []
        let skins = sortedSkins(from: flatXMLs.filter(isModelXML(url:)).map(\.lastPathComponent))
        TrickPreviewDiagnostics.shared.log("models folder not found; flat model scan count=\(skins.count)")
        return skins
    }

    private func sortedSkins(from filenames: [String]) -> [TrickPreviewModelSkin] {
        filenames
            .filter { $0.lowercased().hasSuffix(".xml") }
            .map {
                let filename = $0
                let rawName = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
                let displayName: String
                switch filename {
                case "0.xml":
                    displayName = "Skeleton"
                case "1.xml":
                    displayName = "Default body"
                case "helper.xml":
                    displayName = "Helper body"
                default:
                    displayName = rawName.replacingOccurrences(of: "_", with: " ")
                }
                return TrickPreviewModelSkin(
                    filename: filename,
                    displayName: displayName
                )
            }
            .sorted { lhs, rhs in
                if lhs.filename == "0.xml" { return true }
                if rhs.filename == "0.xml" { return false }
                if lhs.filename == "1.xml" { return true }
                if rhs.filename == "1.xml" { return false }
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
    }

    func loadModel(skins: [String]) throws -> TrickPreviewModel {
        var nodes: [TrickPreviewModel.Node] = []
        var nodeIndexByName: [String: Int] = [:]
        var edges: [TrickPreviewModel.Edge] = []
        var capsules: [TrickPreviewModel.Capsule] = []
        var triangles: [TrickPreviewModel.Triangle] = []
        var nodePoints: [TrickPreviewModel.NodePoint] = []

        for skin in skins {
            let document: XMLDocument
            if skin.lowercased().hasPrefix("custom:") {
                guard let loaded = projectCustomModelDocument(for: skin) ?? CustomModelCatalog.document(for: skin) else { TrickPreviewDiagnostics.shared.log("missing custom skin \(skin)"); continue }
                document = loaded
            } else {
                guard let url = resourceURL(relativePath: "gamedata/run_data/models/\(skin)") else { TrickPreviewDiagnostics.shared.log("missing skin \(skin)"); continue }
                document = try XMLDocument(contentsOf: url, options: [.nodePreserveWhitespace])
            }
            let nodeElements = try document.nodes(forXPath: "/Scene/Nodes/*")
            for node in nodeElements {
                let type = stringAttribute("Type", in: node)
                guard type == "Node" || type == "CenterOfMass" || type == "MacroNode",
                      let name = node.name,
                      nodeIndexByName[name] == nil else { continue }
                let x = doubleAttribute("X", in: node)
                let y = -doubleAttribute("Y", in: node)
                let childCount = intAttribute("NodesCount", in: node)
                let childNames: [String] = childCount > 0 ? (1...childCount).compactMap {
                    let child = stringAttribute("ChildNode\($0)", in: node)
                    return child.isEmpty ? nil : child
                } : []
                let childWeights: [CGFloat] = childCount > 0 ? (1...childCount).map {
                    CGFloat(doubleAttribute("LCC\($0)", in: node, fallback: 1))
                } : []
                let animationIndex = nodes.count < 46 ? nodes.count : nil
                nodeIndexByName[name] = nodes.count
                nodes.append(.init(
                    name: name,
                    type: type,
                    basePoint: CGPoint(x: x, y: y),
                    animationIndex: animationIndex,
                    childNames: childNames,
                    childWeights: childWeights
                ))
            }

            let edgeElements = try document.nodes(forXPath: "/Scene/Edges/*")
            for edge in edgeElements {
                let type = stringAttribute("Type", in: edge)
                guard type == "Edge" || type == "Muscle" else { continue }
                let startName = stringAttribute("End1", in: edge)
                let endName = stringAttribute("End2", in: edge)
                guard !startName.isEmpty, !endName.isEmpty else { continue }
                edges.append(.init(
                    name: edge.name ?? "Edge",
                    startName: startName,
                    endName: endName,
                    startIndex: nodeIndexByName[startName],
                    endIndex: nodeIndexByName[endName]
                ))
            }

            let figureElements = try document.nodes(forXPath: "/Scene/Figures/*")
            for figure in figureElements {
                switch stringAttribute("Type", in: figure) {
                case "Capsule":
                    let edgeName = stringAttribute("Edge", in: figure)
                    guard !edgeName.isEmpty else { continue }
                    capsules.append(.init(
                        name: figure.name ?? "Capsule",
                        edgeName: edgeName,
                        radius: max(0.5, CGFloat(doubleAttribute("Radius1", in: figure, fallback: 3))),
                        margin1: CGFloat(doubleAttribute("Margin1", in: figure)),
                        margin2: CGFloat(doubleAttribute("Margin2", in: figure))
                    ))
                case "Triangle":
                    let nodeNames = ["Node1", "Node2", "Node3"].map { stringAttribute($0, in: figure) }.filter { !$0.isEmpty }
                    guard nodeNames.count == 3 else { continue }
                    triangles.append(.init(name: figure.name ?? "Triangle", nodeNames: nodeNames))
                case "NodePoint":
                    let nodeName = stringAttribute("Node", in: figure)
                    guard !nodeName.isEmpty else { continue }
                    nodePoints.append(.init(
                        name: figure.name ?? "NodePoint",
                        nodeName: nodeName,
                        radius: max(1, CGFloat(doubleAttribute("Radius", in: figure, fallback: 3)))
                    ))
                default:
                    continue
                }
            }
        }

        guard !nodes.isEmpty else {
            throw NSError(domain: "TrickPreview", code: 1, userInfo: [NSLocalizedDescriptionKey: "No model nodes loaded"])
        }
        TrickPreviewDiagnostics.shared.log("model loaded nodes=\(nodes.count) edges=\(edges.count) capsules=\(capsules.count) triangles=\(triangles.count) nodePoints=\(nodePoints.count) skins=\(skins.joined(separator: ","))")
        return TrickPreviewModel(nodes: nodes, nodeIndexByName: nodeIndexByName, edges: edges, capsules: capsules, triangles: triangles, nodePoints: nodePoints)
    }

    private func projectCustomModelDocument(for reference: String) -> XMLDocument? {
        let wanted = reference.dropFirst("custom:".count).replacingOccurrences(of: ".xml", with: "")
        for root in customModelRoots {
            guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            for case let manifestURL as URL in enumerator where manifestURL.lastPathComponent == "manifest.xml" {
                guard let manifestDocument = try? XMLDocument(contentsOf: manifestURL),
                      let manifest = manifestDocument.rootElement(),
                      manifest.attribute(forName: "ID")?.stringValue?.localizedCaseInsensitiveCompare(wanted) == .orderedSame,
                      let filename = manifest.attribute(forName: "FileName")?.stringValue else { continue }
                return try? XMLDocument(contentsOf: manifestURL.deletingLastPathComponent().appendingPathComponent(filename), options: [.nodePreserveWhitespace])
            }
        }
        return nil
    }

    private func customModelURL(reference: String) -> URL? {
        let id = reference.dropFirst("custom:".count).replacingOccurrences(of: ".xml", with: "")
        for root in CustomModelCatalog.roots() {
            let access = root.startAccessingSecurityScopedResource(); defer { if access { root.stopAccessingSecurityScopedResource() } }
            let manifests = ((try? fileManager.subpathsOfDirectory(atPath: root.path)) ?? []).filter { $0.hasSuffix("manifest.xml") }
            for relative in manifests {
                let manifestURL = root.appendingPathComponent(relative)
                guard let document = try? XMLDocument(contentsOf: manifestURL), let manifest = document.rootElement(),
                      manifest.attribute(forName: "ID")?.stringValue?.localizedCaseInsensitiveCompare(id) == .orderedSame,
                      let file = manifest.attribute(forName: "FileName")?.stringValue else { continue }
                return manifestURL.deletingLastPathComponent().appendingPathComponent(file)
            }
        }
        return nil
    }

    func loadFrames(fileName: String) throws -> [TrickPreviewFrame] {
        if fileName.hasPrefix("/") { return try loadFrames(url: URL(fileURLWithPath: fileName)) }
        guard let url = resourceURL(relativePath: "gamedata/animations/\(fileName)") else {
            throw NSError(domain: "TrickPreview", code: 2, userInfo: [NSLocalizedDescriptionKey: "Animation file missing: \(fileName)"])
        }
        return try loadFrames(url: url)
    }

    func loadFrames(url: URL) throws -> [TrickPreviewFrame] {
        // The saved security-scoped bookmark belongs to custom_tricks itself.
        // Child files do not carry independent bookmarks, so keep the root
        // scope active while opening an installed trick's .bytes file.
        let root = customTricksRoot()
        let rootAccess = root?.startAccessingSecurityScopedResource() ?? false
        let access = url.startAccessingSecurityScopedResource()
        defer {
            if access { url.stopAccessingSecurityScopedResource() }
            if rootAccess { root?.stopAccessingSecurityScopedResource() }
        }
        return try loadFrames(data: Data(contentsOf: url), source: url.path)
    }

    func loadFrames(data: Data, source: String = "imported bytes") throws -> [TrickPreviewFrame] {
        var reader = TrickPreviewLittleEndianReader(data: data)
        let frameCount = try reader.readInt32()
        var frames: [TrickPreviewFrame] = []
        frames.reserveCapacity(max(0, frameCount))
        for _ in 0..<frameCount {
            _ = try reader.readUInt8()
            let vectorCount = try reader.readInt32()
            var points = Array(repeating: CGPoint.zero, count: 46)
            for index in 0..<vectorCount {
                let x = try reader.readFloat32()
                let y = -(try reader.readFloat32())
                _ = try reader.readFloat32()
                if index < 46 {
                    points[index] = CGPoint(x: CGFloat(x), y: CGFloat(y))
                }
            }
            frames.append(.init(points: points))
        }
        guard reader.offset == data.count else {
            throw NSError(domain: "TrickPreview", code: 4, userInfo: [NSLocalizedDescriptionKey: "Animation contains unexpected trailing data"])
        }
        TrickPreviewDiagnostics.shared.log("animation bytes=\(source) frames=\(frames.count) data=\(data.count)b")
        return frames
    }

    private func parseMove(node: XMLNode) -> TrickPreviewMove? {
        guard let name = node.name else { return nil }
        return TrickPreviewMove(
            name: name,
            fileName: stringAttribute("FileName", in: node),
            firstFrame: intAttribute("FirstFrame", in: node),
            endFrame: intAttribute("EndFrame", in: node),
            midFrames: max(1, intAttribute("MidFrames", in: node, fallback: 2)),
            loops: boolAttribute("Loop", in: node),
            pivotNode: stringAttribute("PivotNode", in: node, fallback: "NPivot"),
            isTrick: boolAttribute("Trick", in: node),
            parts: stringAttribute("Parts", in: node)
        )
    }

    private func loadCustomMoves() -> [TrickPreviewMove] {
        guard let root = customTricksRoot() else { return [] }
        let access = root.startAccessingSecurityScopedResource()
        defer { if access { root.stopAccessingSecurityScopedResource() } }
        let manifests = ((try? fileManager.subpathsOfDirectory(atPath: root.path)) ?? []).filter { $0.hasSuffix("/trick.xml") || $0 == "trick.xml" }
        return manifests.compactMap { relative in
            let url = root.appendingPathComponent(relative)
            guard let document = try? XMLDocument(contentsOf: url), let node = document.rootElement(), node.name == "CustomTrick" else { return nil }
            let name = stringAttribute("Name", in: node), file = stringAttribute("FileName", in: node)
            guard !name.isEmpty, !file.isEmpty else { return nil }
            return TrickPreviewMove(name: name, fileName: url.deletingLastPathComponent().appendingPathComponent(file).path, firstFrame: intAttribute("FirstFrame", in: node), endFrame: intAttribute("EndFrame", in: node), midFrames: 1, loops: false, pivotNode: stringAttribute("PivotNode", in: node, fallback: "DetectorH"), isTrick: true, parts: "")
        }
    }

    private func customTricksRoot() -> URL? {
        if let encoded = UserDefaults.standard.string(forKey: "vector2CustomTricksDirectoryBookmark"), let data = Data(base64Encoded: encoded) {
            var stale = false
            #if os(macOS)
            let options: URL.BookmarkResolutionOptions = .withSecurityScope
            #else
            let options: URL.BookmarkResolutionOptions = .withoutUI
            #endif
            if let url = try? URL(resolvingBookmarkData: data, options: options, relativeTo: nil, bookmarkDataIsStale: &stale) { return url }
        }
        guard let path = UserDefaults.standard.string(forKey: "vector2CustomTricksDirectory"), !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private func resourceURL(relativePath: String) -> URL? {
        let filename = URL(fileURLWithPath: relativePath).lastPathComponent
        if let flat = Bundle.main.url(forResource: URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent,
                                      withExtension: URL(fileURLWithPath: filename).pathExtension),
           fileManager.fileExists(atPath: flat.path) {
            return flat
        }

        for root in candidateRoots() {
            let bundled = root.appendingPathComponent("ProjectAssets/Vector2").appendingPathComponent(relativePath)
            if fileManager.fileExists(atPath: bundled.path) { return bundled }

            let direct = root.appendingPathComponent(relativePath)
            if fileManager.fileExists(atPath: direct.path) { return direct }

            let unity = root.appendingPathComponent("Assets/Resources").appendingPathComponent(relativePath)
            if fileManager.fileExists(atPath: unity.path) { return unity }
        }
        return nil
    }

    private func isModelXML(url: URL) -> Bool {
        guard url.lastPathComponent != "moves_new.xml",
              let document = try? XMLDocument(contentsOf: url, options: [.nodePreserveWhitespace]),
              let root = document.rootElement(),
              root.name == "Scene" else {
            return false
        }
        return ((try? document.nodes(forXPath: "/Scene/Nodes/*").isEmpty == false) ?? false) ||
            ((try? document.nodes(forXPath: "/Scene/Edges/*").isEmpty == false) ?? false) ||
            ((try? document.nodes(forXPath: "/Scene/Figures/*").isEmpty == false) ?? false)
    }

    private func candidateRoots() -> [URL] {
        var starts: [URL] = []
        if let resourceURL = Bundle.main.resourceURL {
            starts.append(resourceURL)
        }
        if !gameDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            starts.append(URL(fileURLWithPath: gameDirectory))
        }
        if let env = ProcessInfo.processInfo.environment["VECTOR2_WORKSPACE_ROOT"], !env.isEmpty {
            starts.append(URL(fileURLWithPath: env))
        }
        starts.append(URL(fileURLWithPath: fileManager.currentDirectoryPath))

        var roots: [URL] = []
        for start in starts {
            var current = start.standardizedFileURL
            for _ in 0..<12 {
                if fileManager.fileExists(atPath: current.appendingPathComponent("ProjectAssets/Vector2/gamedata").path) ||
                    fileManager.fileExists(atPath: current.appendingPathComponent("Assets/Resources/gamedata").path) ||
                    fileManager.fileExists(atPath: current.appendingPathComponent("gamedata").path) {
                    roots.append(current)
                }
                let parent = current.deletingLastPathComponent()
                if parent.path == current.path { break }
                current = parent
            }
        }
        return roots.vector2Uniqued()
    }

    private func stringAttribute(_ name: String, in node: XMLNode, fallback: String = "") -> String {
        (node as? XMLElement)?.attribute(forName: name)?.stringValue ?? fallback
    }

    private func intAttribute(_ name: String, in node: XMLNode, fallback: Int = 0) -> Int {
        Int(stringAttribute(name, in: node)) ?? fallback
    }

    private func doubleAttribute(_ name: String, in node: XMLNode, fallback: Double = 0) -> Double {
        Double(stringAttribute(name, in: node)) ?? fallback
    }

    private func boolAttribute(_ name: String, in node: XMLNode) -> Bool {
        ["1", "true", "yes"].contains(stringAttribute(name, in: node).lowercased())
    }
}

private struct TrickPreviewLittleEndianReader {
    var data: Data
    var offset: Int = 0

    mutating func readUInt8() throws -> UInt8 {
        try require(1)
        defer { offset += 1 }
        return data[offset]
    }

    mutating func readInt32() throws -> Int {
        try require(4)
        let value = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: Int32.self) }
        offset += 4
        return Int(Int32(littleEndian: value))
    }

    mutating func readFloat32() throws -> Float {
        try require(4)
        let bits = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
        offset += 4
        return Float(bitPattern: UInt32(littleEndian: bits))
    }

    private func require(_ count: Int) throws {
        guard offset + count <= data.count else {
            throw NSError(domain: "TrickPreview", code: 3, userInfo: [NSLocalizedDescriptionKey: "Animation byte stream ended early"])
        }
    }
}
