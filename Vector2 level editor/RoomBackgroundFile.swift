import Foundation

/// A room save replaces the catalog; zone-pool saves use their separate store.
enum RoomBackgroundFile {
    static func replace(name: String, pieces: [String], in folder: URL) throws {
        guard folder.lastPathComponent != "custom_backgrounds_pool" else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let root = XMLElement(name: "CustomBackgrounds")
        let background = XMLElement(name: "Background")
        background.addAttribute(XMLNode.attribute(withName: "Name", stringValue: name) as! XMLNode)
        for piece in pieces {
            let parsed = try XMLDocument(xmlString: "<Root>\(piece)</Root>", options: [])
            for node in parsed.rootElement()?.children ?? [] {
                background.addChild(node.copy() as! XMLNode)
            }
        }
        root.addChild(background)
        let xml = XMLDocument(rootElement: root)
        xml.version = "1.0"
        xml.characterEncoding = "utf-8"
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Replace atomically: a failed write leaves the previous file intact.
        try xml.xmlData(options: .nodePrettyPrint).write(
            to: folder.appendingPathComponent("custom_backgrounds.xml"), options: .atomic)
    }
}
