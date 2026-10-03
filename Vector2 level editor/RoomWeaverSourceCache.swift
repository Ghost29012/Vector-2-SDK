//
//  RoomWeaverSourceCache.swift
//  Vector2 level editor
//
//  Room import asks the same file three questions: is it a room, which choices
//  exist, and what scene should be built. Large Vector 2 rooms should only be
//  read and parsed once for those operations.
//

import Foundation

enum RoomWeaverSourceCache {
    private struct Version: Equatable {
        let size: Int
        let modifiedAt: Date?
    }

    private struct Entry {
        let version: Version
        let document: XMLDocument
    }

    private static var entries: [String: Entry] = [:]
    private static let lock = NSLock()

    static func rootElement(at url: URL) -> XMLElement? {
        let normalizedURL = url.standardizedFileURL
        let values = try? normalizedURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let version = Version(size: values?.fileSize ?? -1, modifiedAt: values?.contentModificationDate)

        lock.lock()
        defer { lock.unlock() }

        if let cached = entries[normalizedURL.path], cached.version == version {
            return cached.document.rootElement()
        }

        guard let document = try? XMLDocument(contentsOf: normalizedURL, options: []) else {
            entries.removeValue(forKey: normalizedURL.path)
            return nil
        }
        entries[normalizedURL.path] = Entry(version: version, document: document)
        return document.rootElement()
    }

    static func clear() {
        lock.lock()
        entries.removeAll(keepingCapacity: true)
        lock.unlock()
    }
}
