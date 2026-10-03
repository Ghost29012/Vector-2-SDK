import Foundation

struct TriggerBounds: Equatable {
    var x: Int
    var y: Int
    var width: Int
    var height: Int
}

struct TriggerXMLNode: Identifiable, Equatable {
    var id = UUID()
    var name: String
    var attributes: [String: String] = [:]
    var children: [TriggerXMLNode] = []
    var text: String?
    var originalXML: String?

    init(name: String, attributes: [String: String] = [:], children: [TriggerXMLNode] = [], text: String? = nil) {
        self.name = name
        self.attributes = attributes
        self.children = children
        self.text = text
    }
}

struct TriggerEventDefinition: Identifiable, Equatable {
    var id: UUID { node.id }
    var node: TriggerXMLNode
}

struct TriggerActionDefinition: Identifiable, Equatable {
    var id: UUID { node.id }
    var node: TriggerXMLNode
}

struct TriggerLoopDefinition: Identifiable, Equatable {
    var id = UUID()
    var events: [TriggerEventDefinition] = []
    var conditions: [TriggerXMLNode] = []
    var actions: [TriggerActionDefinition] = []
    var attributes: [String: String] = [:]
    var otherChildren: [TriggerXMLNode] = []
    var originalXML: String?
}

struct TriggerDefinition: Identifiable, Equatable {
    var id = UUID()
    var name: String
    var bounds: TriggerBounds
    var attributes: [String: String] = [:]
    var initNodes: [TriggerXMLNode] = []
    var loops: [TriggerLoopDefinition] = []
    var otherContent: [TriggerXMLNode] = []
    var otherChildren: [TriggerXMLNode] = []
    var originalXML: String?
}

enum TriggerXMLCodecError: LocalizedError {
    case missingTrigger
    case invalidBounds

    var errorDescription: String? {
        switch self {
        case .missingTrigger: return "The XML does not contain a Trigger root."
        case .invalidBounds: return "Trigger X, Y, Width and Height must be whole numbers."
        }
    }
}

enum TriggerXMLCodec {
    static func decode(_ xml: String) throws -> TriggerDefinition {
        let document = try XMLDocument(xmlString: xml, options: [.nodePreserveAll])
        guard let root = document.rootElement(), root.name == "Trigger" else { throw TriggerXMLCodecError.missingTrigger }
        func intAttribute(_ name: String) throws -> Int {
            guard let raw = root.attribute(forName: name)?.stringValue, let value = Int(raw) else { throw TriggerXMLCodecError.invalidBounds }
            return value
        }
        var attributes = attributeMap(root)
        let name = attributes.removeValue(forKey: "Name") ?? "Trigger"
        ["X", "Y", "Width", "Height"].forEach { attributes.removeValue(forKey: $0) }
        var definition = TriggerDefinition(
            name: name,
            bounds: try TriggerBounds(x: intAttribute("X"), y: intAttribute("Y"), width: intAttribute("Width"), height: intAttribute("Height")),
            attributes: attributes
        )
        definition.originalXML = root.xmlString
        for child in elementChildren(root) {
            guard child.name == "Content" else { definition.otherChildren.append(node(child)); continue }
            for contentChild in elementChildren(child) {
                if contentChild.name == "Init" {
                    definition.initNodes.removeAll(keepingCapacity: true)
                    for initChild in elementChildren(contentChild) {
                        definition.initNodes.append(node(initChild))
                    }
                } else if contentChild.name == "Loop" {
                    definition.loops.append(decodeLoop(contentChild))
                } else {
                    definition.otherContent.append(node(contentChild))
                }
            }
        }
        return definition
    }

    static func encode(_ definition: TriggerDefinition) throws -> String {
        let original = sourceElement(definition.originalXML)
        let originalContent = original?.elements(forName: "Content").first
        let root = XMLElement(name: "Trigger")
        var attributes = definition.attributes
        attributes["Name"] = definition.name
        attributes["X"] = "\(definition.bounds.x)"
        attributes["Y"] = "\(definition.bounds.y)"
        attributes["Width"] = "\(definition.bounds.width)"
        attributes["Height"] = "\(definition.bounds.height)"
        addAttributes(attributes, to: root)
        let content = XMLElement(name: "Content")
        let initNodes = runtimeInitNodes(definition.initNodes)
        if !initNodes.isEmpty {
            let initial = XMLElement(name: "Init")
            initNodes.forEach { initial.addChild(element($0)) }
            restoreTrivia(from: originalContent?.elements(forName: "Init").first, into: initial)
            content.addChild(initial)
        }
        definition.loops.forEach { content.addChild(encodeLoop($0)) }
        definition.otherContent.forEach { content.addChild(element($0)) }
        restoreTrivia(from: originalContent, into: content)
        root.addChild(content)
        definition.otherChildren.forEach { root.addChild(element($0)) }
        restoreTrivia(from: original, into: root)
        return "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n" + formatted(root, depth: 0)
    }

    private static func decodeLoop(_ element: XMLElement) -> TriggerLoopDefinition {
        var loop = TriggerLoopDefinition(attributes: attributeMap(element))
        loop.originalXML = element.xmlString
        for child in elementChildren(element) {
            switch child.name {
            case "Events": loop.events = elementChildren(child).map { TriggerEventDefinition(node: node($0)) }
            case "Conditions":
                loop.conditions.removeAll(keepingCapacity: true)
                for condition in elementChildren(child) {
                    loop.conditions.append(node(condition))
                }
            case "Actions": loop.actions = elementChildren(child).map { TriggerActionDefinition(node: node($0)) }
            default: loop.otherChildren.append(node(child))
            }
        }
        return loop
    }

    private static func encodeLoop(_ definition: TriggerLoopDefinition) -> XMLElement {
        let original = sourceElement(definition.originalXML)
        let loop = XMLElement(name: "Loop")
        addAttributes(definition.attributes, to: loop)
        let events = XMLElement(name: "Events")
        definition.events.forEach { events.addChild(element($0.node)) }
        restoreTrivia(from: original?.elements(forName: "Events").first, into: events)
        loop.addChild(events)
        if !definition.conditions.isEmpty || original?.elements(forName: "Conditions").isEmpty == false {
            let conditions = XMLElement(name: "Conditions")
            definition.conditions.forEach { conditions.addChild(element($0)) }
            restoreTrivia(from: original?.elements(forName: "Conditions").first, into: conditions)
            loop.addChild(conditions)
        }
        let actions = XMLElement(name: "Actions")
        definition.actions.forEach { actions.addChild(element($0.node)) }
        restoreTrivia(from: original?.elements(forName: "Actions").first, into: actions)
        loop.addChild(actions)
        definition.otherChildren.forEach { loop.addChild(element($0)) }
        restoreTrivia(from: original, into: loop)
        return loop
    }

    private static func node(_ element: XMLElement) -> TriggerXMLNode {
        var children: [TriggerXMLNode] = []
        for child in elementChildren(element) {
            children.append(node(child))
        }
        var result = TriggerXMLNode(name: element.name ?? "Unknown", attributes: attributeMap(element), children: children, text: element.stringValueIfTextOnly)
        result.originalXML = element.xmlString
        return result
    }

    private static func element(_ node: TriggerXMLNode) -> XMLElement {
        let result = XMLElement(name: node.name)
        let original = sourceElement(node.originalXML)
        let preserveOriginalText = original != nil && node.text == original?.stringValueIfTextOnly
        addAttributes(node.attributes, to: result)
        node.children.forEach { result.addChild(element($0)) }
        if node.children.isEmpty, !preserveOriginalText, let text = node.text { result.stringValue = text }
        restoreTrivia(from: original, into: result, preserveText: preserveOriginalText)
        return result
    }

    private static func sourceElement(_ source: String?) -> XMLElement? {
        guard let source else { return nil }
        return try? XMLDocument(xmlString: source, options: [.nodePreserveAll, .nodeLoadExternalEntitiesNever]).rootElement()
    }

    /// Foundation's pretty printer adds whitespace around comments inside text.
    /// Format only element-only containers; mixed-content leaves stay compact.
    private static func formatted(_ element: XMLElement, depth: Int) -> String {
        let children = element.children ?? []
        if children.contains(where: { $0.kind == .text && $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }) {
            return element.xmlString
        }
        let meaningful = children.filter { $0.kind != .text || $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }
        guard !meaningful.isEmpty, let name = element.name, let shell = element.copy() as? XMLElement else { return element.xmlString }
        (shell.children ?? []).forEach { $0.detach() }
        let closing = "</\(name)>"
        let shellXML = shell.xmlString
        let opening: String
        if shellXML.hasSuffix(closing) { opening = String(shellXML.dropLast(closing.count)) }
        else if shellXML.hasSuffix("/>") { opening = String(shellXML.dropLast(2)) + ">" }
        else { return element.xmlString }
        let indent = String(repeating: "    ", count: depth)
        let content = meaningful.map { child in
            indent + "    " + ((child as? XMLElement).map { formatted($0, depth: depth + 1) } ?? child.xmlString)
        }.joined(separator: "\n")
        return opening + "\n" + content + "\n" + indent + closing
    }

    /// Preserve comments, processing instructions and mixed text without exposing
    /// them as editable action cards. Indentation is regenerated by the formatter.
    private static func restoreTrivia(from original: XMLElement?, into result: XMLElement, preserveText: Bool = true) {
        var elementsSeen = 0
        var inserted = 0
        for child in original?.children ?? [] {
            if child.kind == .element { elementsSeen += 1; continue }
            if child.kind == .text {
                guard preserveText, child.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { continue }
            }
            guard let copy = child.copy() as? XMLNode else { continue }
            result.insertChild(copy, at: min(elementsSeen + inserted, result.childCount))
            inserted += 1
        }
    }

    private static func elementChildren(_ node: XMLNode) -> [XMLElement] {
        (node.children ?? []).compactMap { $0 as? XMLElement }
    }

    private static func attributeMap(_ element: XMLElement) -> [String: String] {
        Dictionary(uniqueKeysWithValues: (element.attributes ?? []).compactMap { attribute in
            guard let name = attribute.name else { return nil }
            return (name, attribute.stringValue ?? "")
        })
    }

    private static func addAttributes(_ attributes: [String: String], to element: XMLElement) {
        for key in attributes.keys.sorted() {
            element.addAttribute(XMLNode.attribute(withName: key, stringValue: attributes[key] ?? "") as! XMLNode)
        }
    }

    /// TriggerRunner reads these variables unconditionally during Init. Keep
    /// imported values, but fill any missing runtime defaults before export.
    private static func runtimeInitNodes(_ existing: [TriggerXMLNode]) -> [TriggerXMLNode] {
        var result = existing
        let names = Set(existing.compactMap { node -> String? in
            guard node.name == "SetVariable" else { return nil }
            return node.attributes["Name"]
        })
        let required: [(name: String, type: String, value: String)] = [
            ("$AI", "AI", "0"),
            ("$Active", "Bool", "1"),
            ("$Node", "Node", "COM")
        ]
        for item in required where !names.contains(item.name) {
            result.append(.init(name: "SetVariable", attributes: ["Name": item.name, "Type": item.type, "Value": item.value]))
        }
        return result
    }
}

/// Opens either a standalone game trigger or every trigger embedded in a room.
/// The source is only read; callers decide whether to save a project copy.
enum TriggerXMLImporter {
    static func decodeAll(_ xml: String) throws -> [TriggerDefinition] {
        let document = try XMLDocument(xmlString: xml, options: [.nodePreserveAll])
        guard let root = document.rootElement() else { throw TriggerXMLCodecError.missingTrigger }
        let elements: [XMLElement]
        if root.name == "Trigger" {
            elements = [root]
        } else {
            elements = try document.nodes(forXPath: "//Trigger").compactMap { $0 as? XMLElement }
        }
        guard !elements.isEmpty else { throw TriggerXMLCodecError.missingTrigger }
        return try elements.map { try TriggerXMLCodec.decode($0.xmlString(options: [.nodePrettyPrint])) }
    }

    static func decodeAll(contentsOf url: URL) throws -> [TriggerDefinition] {
        try decodeAll(String(contentsOf: url, encoding: .utf8))
    }
}

private extension XMLElement {
    var stringValueIfTextOnly: String? {
        guard !(children ?? []).contains(where: { $0.kind == .element }) else { return nil }
        let value = (children ?? []).filter { $0.kind == .text }.map { $0.stringValue ?? "" }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

enum TriggerPreset {
    static func dialogue(id: String, bounds: TriggerBounds) -> TriggerDefinition {
        let event = TriggerEventDefinition(node: .init(name: "Enter"))
        let action = TriggerActionDefinition(node: .init(name: "ExecuteCall", attributes: ["Message": "Content.Dialogue:\(id)"]))
        return TriggerDefinition(name: "Dialogue_\(id)", bounds: bounds, loops: [.init(events: [event], actions: [action])])
    }
}
