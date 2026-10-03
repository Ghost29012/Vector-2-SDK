import Foundation
import ImageIO
import UniformTypeIdentifiers

enum CustomGIFFrames {
    static func compile(source: URL, into folder: URL, name: String) throws -> String {
        guard let gif = CGImageSourceCreateWithURL(source as CFURL, nil), CGImageSourceGetCount(gif) > 0 else {
            throw NSError(domain: "CustomGIFFrames", code: 1, userInfo: [NSLocalizedDescriptionKey: "This GIF has no readable frames."])
        }
        let key = name.map { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" ? $0 : "_" }.reduce(into: "") { $0.append($1) }
        guard !key.isEmpty else { throw CocoaError(.fileWriteInvalidFileName) }
        let framesFolder = folder.appendingPathComponent("animation_frames", isDirectory: true).appendingPathComponent(key, isDirectory: true)
        try FileManager.default.createDirectory(at: framesFolder, withIntermediateDirectories: true)
        let root = XMLElement(name: "CustomAnimation")
        for index in 0..<CGImageSourceGetCount(gif) {
            guard let image = CGImageSourceCreateImageAtIndex(gif, index, nil) else { continue }
            // Resource lookup falls back to recursive filename search, so every
            // animation frame needs a unique basename across the whole project.
            let fileName = "\(key)_" + String(format: "%04d.png", index)
            let output = framesFolder.appendingPathComponent(fileName)
            guard let writer = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(writer, image, nil)
            guard CGImageDestinationFinalize(writer) else { throw CocoaError(.fileWriteUnknown) }
            let properties = CGImageSourceCopyPropertiesAtIndex(gif, index, nil) as? [CFString: Any]
            let gifProperties = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay = (gifProperties?[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
                ?? (gifProperties?[kCGImagePropertyGIFDelayTime] as? Double) ?? (1.0 / 30.0)
            let frame = XMLElement(name: "Frame")
            frame.addAttribute(XMLNode.attribute(withName: "Texture", stringValue: "animation_frames/\(key)/\(fileName)") as! XMLNode)
            frame.addAttribute(XMLNode.attribute(withName: "Frames", stringValue: "\(max(1, Int((delay * 30).rounded())))") as! XMLNode)
            root.addChild(frame)
        }
        guard root.childCount > 0 else { throw NSError(domain: "CustomGIFFrames", code: 2, userInfo: [NSLocalizedDescriptionKey: "The GIF frames could not be exported."]) }
        let document = XMLDocument(rootElement: root)
        document.version = "1.0"; document.characterEncoding = "utf-8"
        let manifestName = "\(key).xml"
        try document.xmlData(options: .nodePrettyPrint).write(to: folder.appendingPathComponent(manifestName), options: .atomic)
        return manifestName
    }
}
