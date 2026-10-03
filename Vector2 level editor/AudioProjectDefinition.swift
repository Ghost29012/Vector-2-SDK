import Foundation

struct AudioTrackDefinition: Identifiable, Equatable {
    var id: String
    var weight: Int = 1
    var minimumFloor: Int = 0
    var maximumFloor: Int = 0
}

struct AudioPoolDefinition: Identifiable, Equatable {
    enum Scope: String, CaseIterable, Identifiable { case chapter = "Chapter", zone = "Zone"; var id: String { rawValue } }
    var id: String { "\(scope.rawValue):\(reference)" }
    var scope: Scope
    var reference: String
    var ambientID: String = ""
    var ambientVolume: Double = 0.5
    var tracks: [AudioTrackDefinition] = []
}

struct AudioProjectDefinition: Equatable {
    var pools: [AudioPoolDefinition] = []
}

enum AudioProjectXMLCodec {
    static func decode(_ xml: String) throws -> AudioProjectDefinition {
        let document = try XMLDocument(xmlString: xml)
        guard let root = document.rootElement(), root.name == "CustomAudio" else { return .init() }
        let pools = (try root.nodes(forXPath: "./MusicPools/Pool")).compactMap { node -> AudioPoolDefinition? in
            guard let element = node as? XMLElement,
                  let rawScope = element.attribute(forName: "Scope")?.stringValue,
                  let scope = AudioPoolDefinition.Scope(rawValue: rawScope) else { return nil }
            func attr(_ name: String, _ fallback: String = "") -> String { element.attribute(forName: name)?.stringValue ?? fallback }
            let tracks = element.elements(forName: "Track").compactMap { track -> AudioTrackDefinition? in
                guard let id = track.attribute(forName: "Id")?.stringValue, !id.isEmpty else { return nil }
                func number(_ key: String, _ fallback: Int) -> Int { Int(track.attribute(forName: key)?.stringValue ?? "") ?? fallback }
                return .init(id: id, weight: number("Weight", 1), minimumFloor: number("MinFloor", 0), maximumFloor: number("MaxFloor", 0))
            }
            return .init(scope: scope, reference: attr("Reference"), ambientID: attr("Ambient"), ambientVolume: Double(attr("AmbientVolume", "0.5")) ?? 0.5, tracks: tracks)
        }
        return .init(pools: pools)
    }

    static func encode(_ definition: AudioProjectDefinition) throws -> String {
        let root = XMLElement(name: "CustomAudio")
        root.addAttribute(XMLNode.attribute(withName: "SchemaVersion", stringValue: "1") as! XMLNode)
        let pools = XMLElement(name: "MusicPools")
        for pool in definition.pools {
            let element = XMLElement(name: "Pool")
            add(["Scope": pool.scope.rawValue, "Reference": pool.reference, "Ambient": pool.ambientID, "AmbientVolume": String(pool.ambientVolume)], to: element)
            for track in pool.tracks {
                let child = XMLElement(name: "Track")
                add(["Id": track.id, "Weight": String(max(1, track.weight)), "MinFloor": String(max(0, track.minimumFloor)), "MaxFloor": String(max(0, track.maximumFloor))], to: child)
                element.addChild(child)
            }
            pools.addChild(element)
        }
        root.addChild(pools)
        let document = XMLDocument(rootElement: root); document.version = "1.0"; document.characterEncoding = "utf-8"
        return document.xmlString(options: [.nodePrettyPrint])
    }

    static func load(from projectRoot: URL) -> AudioProjectDefinition {
        let url = manifestURL(projectRoot)
        guard let xml = try? String(contentsOf: url, encoding: .utf8) else { return .init() }
        return (try? decode(xml)) ?? .init()
    }

    static func write(_ definition: AudioProjectDefinition, to projectRoot: URL) throws {
        let url = manifestURL(projectRoot)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encode(definition).write(to: url, atomically: true, encoding: .utf8)
    }

    private static func manifestURL(_ root: URL) -> URL { root.appendingPathComponent("custom_audio", isDirectory: true).appendingPathComponent("audio_manifest.xml") }
    private static func add(_ values: [String: String], to element: XMLElement) { for key in values.keys.sorted() where !values[key, default: ""].isEmpty { element.addAttribute(XMLNode.attribute(withName: key, stringValue: values[key, default: ""]) as! XMLNode) } }
}
