import Foundation

enum StructuralRoomGameInstaller {
    /// Copies a project room into the exact Vector 2 Data root selected by the
    /// project. Callers keep the security-scoped URLs open while this runs.
    static func install(room: URL, projectRoot: URL, gameRoot: URL, relativePath: String) throws -> URL {
        let parts = relativePath.replacingOccurrences(of: "\\", with: "/").split(separator: "/").map(String.init)
        guard parts.count >= 4,
              parts.first == "custom_rooms",
              !parts.contains(".."),
              !relativePath.hasPrefix("/"),
              parts.last?.lowercased().hasSuffix(".xml") == true else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        let expectedSource = parts.reduce(projectRoot) { $0.appendingPathComponent($1) }.standardizedFileURL
        guard room.standardizedFileURL == expectedSource else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        let destination = parts.reduce(gameRoot) { $0.appendingPathComponent($1) }
        let files = FileManager.default
        try files.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let roomData = try Data(contentsOf: room)
        try roomData.write(to: destination, options: .atomic)

        for catalog in ["custom_chapters", "custom_zones"] {
            let sourceFolder = projectRoot.appendingPathComponent(catalog, isDirectory: true)
            let gameFolder = gameRoot.appendingPathComponent(catalog, isDirectory: true)
            for source in (try? files.contentsOfDirectory(at: sourceFolder, includingPropertiesForKeys: nil)) ?? []
                where source.pathExtension.lowercased() == "xml" {
                try files.createDirectory(at: gameFolder, withIntermediateDirectories: true)
                try Data(contentsOf: source).write(to: gameFolder.appendingPathComponent(source.lastPathComponent), options: .atomic)
            }
        }
        guard try Data(contentsOf: destination) == roomData else {
            throw CocoaError(.fileWriteUnknown)
        }
        return destination
    }
}
