import AppKit
import CryptoKit
import Foundation

struct ObstaclePackageDefinition: Equatable {
    var stableID: String
    var name: String
    var author: String
    var version: String
    var xml: String
    var textureURLs: [URL]
    var previewPNG: Data? = nil
}

struct LoadedObstaclePackage {
    var definition: ObstaclePackageDefinition
    var textureURLs: [URL]
    var previewURL: URL?
    var extractionRoot: URL
}

enum ObstaclePackageError: LocalizedError {
    case invalidID, invalidArchive, missingManifest, missingXML, unsafeArchive, textureConflict(String), process(String)
    var errorDescription: String? {
        switch self {
        case .invalidID: return "Use a stable ID containing letters, numbers, underscores or hyphens."
        case .invalidArchive: return "This is not a readable .v2obstacle package."
        case .missingManifest: return "The obstacle package has no manifest.xml."
        case .missingXML: return "The obstacle package has no obstacle.xml."
        case .unsafeArchive: return "The package contains an unsafe path and was not imported."
        case .textureConflict(let name): return "A different custom texture named '\(name)' is already installed. Rename one of the textures before importing."
        case .process(let message): return message
        }
    }
}

enum ObstaclePackageStore {
    static let fileExtension = "v2obstacle"

    static func export(_ definition: ObstaclePackageDefinition, to destination: URL) throws {
        let id = cleanID(definition.stableID)
        guard !id.isEmpty else { throw ObstaclePackageError.invalidID }
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("v2obstacle-export-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        try fm.createDirectory(at: staging.appendingPathComponent("textures"), withIntermediateDirectories: true)
        try definition.xml.data(using: .utf8)?.write(to: staging.appendingPathComponent("obstacle.xml"), options: .atomic)
        var copied: [String] = []
        for source in definition.textureURLs where fm.fileExists(atPath: source.path) {
            let name = source.lastPathComponent
            guard !copied.contains(name) else { continue }
            try fm.copyItem(at: source, to: staging.appendingPathComponent("textures").appendingPathComponent(name))
            copied.append(name)
        }
        if let preview = definition.previewPNG { try preview.write(to: staging.appendingPathComponent("preview.png"), options: .atomic) }
        let manifest = XMLElement(name: "Vector2Obstacle")
        ["SchemaVersion": "1", "Id": id, "Name": definition.name, "Author": definition.author, "Version": definition.version, "XML": "obstacle.xml", "Preview": definition.previewPNG == nil ? "" : "preview.png"].forEach {
            manifest.addAttribute(XMLNode.attribute(withName: $0.key, stringValue: $0.value) as! XMLNode)
        }
        let dependencies = XMLElement(name: "Textures")
        copied.sorted().forEach { let node = XMLElement(name: "Texture"); node.addAttribute(XMLNode.attribute(withName: "File", stringValue: $0) as! XMLNode); dependencies.addChild(node) }
        manifest.addChild(dependencies)
        try XMLDocument(rootElement: manifest).xmlData(options: .nodePrettyPrint).write(to: staging.appendingPathComponent("manifest.xml"), options: .atomic)
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try runDitto(["-c", "-k", "--sequesterRsrc", "--keepParent", staging.path, destination.path])
    }

    static func read(_ archive: URL) throws -> LoadedObstaclePackage {
        guard archive.pathExtension.lowercased() == fileExtension else { throw ObstaclePackageError.invalidArchive }
        let fm = FileManager.default
        let attributes = try fm.attributesOfItem(atPath: archive.path)
        let stamp = "\(archive.standardizedFileURL.path)|\(attributes[.size] ?? 0)|\((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
        let key = SHA256.hash(data: Data(stamp.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        let root = fm.temporaryDirectory.appendingPathComponent("v2obstacle-cache-\(key)", isDirectory: true)
        if findPackageRoot(in: root) == nil {
            // Asset catalog refreshes a lot. Only unpack a changed archive once;
            // doing a fresh ditto from SwiftUI's body can re-enter its graph.
            if fm.fileExists(atPath: root.path) { try fm.removeItem(at: root) }
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            try runDitto(["-x", "-k", archive.path, root.path])
        }
        guard let packageRoot = findPackageRoot(in: root) else { throw ObstaclePackageError.missingManifest }
        try verifyDescendants(of: packageRoot)
        let manifestURL = packageRoot.appendingPathComponent("manifest.xml")
        guard let document = try? XMLDocument(contentsOf: manifestURL), let manifest = document.rootElement(), manifest.name == "Vector2Obstacle" else { throw ObstaclePackageError.missingManifest }
        let xmlName = manifest.attribute(forName: "XML")?.stringValue ?? "obstacle.xml"
        guard safeRelative(xmlName) else { throw ObstaclePackageError.unsafeArchive }
        let xmlURL = packageRoot.appendingPathComponent(xmlName)
        guard let xml = try? String(contentsOf: xmlURL, encoding: .utf8) else { throw ObstaclePackageError.missingXML }
        let textures = manifest.elements(forName: "Textures").first?.elements(forName: "Texture").compactMap { node -> URL? in
            guard let name = node.attribute(forName: "File")?.stringValue, safeRelative(name) else { return nil }
            let url = packageRoot.appendingPathComponent("textures").appendingPathComponent(name)
            return fm.fileExists(atPath: url.path) ? url : nil
        } ?? []
        let previewName = manifest.attribute(forName: "Preview")?.stringValue ?? ""
        let preview = safeRelative(previewName) && !previewName.isEmpty ? packageRoot.appendingPathComponent(previewName) : nil
        let definition = ObstaclePackageDefinition(stableID: manifest.attribute(forName: "Id")?.stringValue ?? "", name: manifest.attribute(forName: "Name")?.stringValue ?? "Obstacle", author: manifest.attribute(forName: "Author")?.stringValue ?? "", version: manifest.attribute(forName: "Version")?.stringValue ?? "1.0.0", xml: xml, textureURLs: textures, previewPNG: preview.flatMap { try? Data(contentsOf: $0) })
        return LoadedObstaclePackage(definition: definition, textureURLs: textures, previewURL: preview, extractionRoot: packageRoot)
    }

    static func install(_ archive: URL, into project: URL) throws -> URL {
        let loaded = try read(archive)
        let id = cleanID(loaded.definition.stableID)
        guard !id.isEmpty else { throw ObstaclePackageError.invalidID }
        let fm = FileManager.default
        let obstacles = project.appendingPathComponent("custom_obstacles", isDirectory: true)
        let textures = project.appendingPathComponent("custom_textures", isDirectory: true)
        try fm.createDirectory(at: obstacles, withIntermediateDirectories: true)
        try fm.createDirectory(at: textures, withIntermediateDirectories: true)
        let target = obstacles.appendingPathComponent("\(id).v2obstacle")
        if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
        try fm.copyItem(at: archive, to: target)
        for source in loaded.textureURLs {
            let destination = textures.appendingPathComponent(source.lastPathComponent)
            if fm.fileExists(atPath: destination.path) {
                if (try? Data(contentsOf: source)) != (try? Data(contentsOf: destination)) { throw ObstaclePackageError.textureConflict(source.lastPathComponent) }
            } else { try fm.copyItem(at: source, to: destination) }
        }
        return target
    }

    private static func cleanID(_ value: String) -> String { value.lowercased().replacingOccurrences(of: "[^a-z0-9_-]", with: "_", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: "_")) }
    private static func safeRelative(_ value: String) -> Bool { !value.isEmpty && !value.hasPrefix("/") && !value.split(separator: "/").contains("..") }
    private static func findPackageRoot(in root: URL) -> URL? {
        let fm = FileManager.default
        if fm.fileExists(atPath: root.appendingPathComponent("manifest.xml").path) { return root }
        return ((try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []).first { fm.fileExists(atPath: $0.appendingPathComponent("manifest.xml").path) }
    }
    private static func verifyDescendants(of root: URL) throws {
        let base = root.standardizedFileURL.path + "/"
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey]) else { return }
        for case let url as URL in e {
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true || !url.standardizedFileURL.path.hasPrefix(base) { throw ObstaclePackageError.unsafeArchive }
        }
    }
    private static func runDitto(_ arguments: [String]) throws {
        try DispatchQueue.global(qos: .utility).sync {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto"); process.arguments = arguments
            let pipe = Pipe(); process.standardError = pipe
            try process.run()
            // Drain before waiting so a noisy ditto failure cannot fill the pipe.
            let errors = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if process.terminationStatus != 0 { throw ObstaclePackageError.process(String(data: errors, encoding: .utf8) ?? "Archive operation failed.") }
        }
    }
}
