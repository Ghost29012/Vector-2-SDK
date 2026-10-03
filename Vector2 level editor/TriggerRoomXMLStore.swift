import Foundation

enum TriggerRoomXMLStoreError: LocalizedError {
    case noFactorContent
    case invalidTrigger

    var errorDescription: String? {
        switch self {
        case .noFactorContent: return "The room has no Factor content container for this trigger."
        case .invalidTrigger: return "The generated trigger XML could not be parsed."
        }
    }
}

enum TriggerRoomXMLStore {
    static func inserting(_ trigger: TriggerDefinition, into roomXML: String) throws -> String {
        let room = try XMLDocument(xmlString: roomXML, options: [.nodePreserveAll])
        let candidates = try room.nodes(forXPath: "//Object[@Factor]/Content")
        guard let content = candidates.first as? XMLElement else { throw TriggerRoomXMLStoreError.noFactorContent }
        let triggerDocument = try XMLDocument(xmlString: TriggerXMLCodec.encode(trigger), options: [.nodePreserveAll])
        guard let triggerElement = triggerDocument.rootElement()?.copy() as? XMLElement else { throw TriggerRoomXMLStoreError.invalidTrigger }
        content.addChild(triggerElement)
        return room.xmlString(options: [.nodePrettyPrint])
    }

    static func insert(_ trigger: TriggerDefinition, intoRoomAt url: URL) throws {
        let source = try String(contentsOf: url, encoding: .utf8)
        let output = try inserting(trigger, into: source)
        try output.write(to: url, atomically: true, encoding: .utf8)
    }
}

/// Project-owned reusable authoring files. These are editor templates, not room
/// content: a room only receives a copy when the creator places one from Tools.
enum ProjectTriggerStore {
    static let folderName = "custom_triggers"

    static func folder(in projectRoot: URL) -> URL {
        projectRoot.appendingPathComponent(folderName, isDirectory: true)
    }

    static func files(in projectRoot: URL) -> [URL] {
        let root = folder(in: projectRoot)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
            .filter { $0.pathExtension.lowercased() == "xml" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    static func load(_ url: URL) -> TriggerDefinition? {
        guard let source = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return try? TriggerXMLCodec.decode(source)
    }

    @discardableResult
    static func save(_ trigger: TriggerDefinition, in projectRoot: URL, replacing oldURL: URL? = nil) throws -> URL {
        let root = folder(in: projectRoot)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let clean = trigger.name.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" }.reduce(into: "") { $0.append($1) }
        guard !clean.isEmpty else { throw TriggerRoomXMLStoreError.invalidTrigger }
        let destination = root.appendingPathComponent(clean).appendingPathExtension("xml")
        try TriggerXMLCodec.encode(trigger).write(to: destination, atomically: true, encoding: .utf8)
        if let oldURL, oldURL.standardizedFileURL != destination.standardizedFileURL,
           FileManager.default.fileExists(atPath: oldURL.path) { try FileManager.default.removeItem(at: oldURL) }
        return destination
    }
}
