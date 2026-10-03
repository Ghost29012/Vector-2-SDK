import Foundation

struct TutorialStepDefinition: Identifiable, Hashable {
    var id = UUID()
    var instruction: String
    var portrait: String
}

struct SDKDefinition: Identifiable {
    let id = UUID()
    var file: URL?
    var stableID: String
    var name: String
    var details: String
    var type: String
    var target: Int
    var amount: Int
    var order: Int
    var reference: String
    var message: String
    var once: Bool
    var difficulty: Int
    var maximumFloor: Int
    var weight: Int
    var protocolID: String
    var tutorialSteps: [TutorialStepDefinition]

    var nameOrUntitled: String { name.isEmpty ? "Untitled" : name }
    var rewardSymbol: String { type == "Card" ? "rectangle.stack.fill" : type == "Energy" ? "bolt.fill" : type == "Item" ? "shippingbox.fill" : "creditcard.fill" }
    func summary(_ kind: SDKDefinitionStudioView.Kind) -> String { kind == .mission ? "\(type) · target \(target)" : kind == .reward ? "\(type) ×\(amount)" : "\(tutorialSteps.count) steps · \(type)" }

    static func new(_ kind: SDKDefinitionStudioView.Kind) -> SDKDefinition {
        SDKDefinition(file: nil, stableID: "", name: "", details: "", type: kind == .mission ? "Points" : kind == .reward ? "Credits" : "Menu Open", target: 100, amount: 100, order: 1, reference: "", message: "", once: true, difficulty: 1, maximumFloor: 0, weight: 100, protocolID: "Any", tutorialSteps: kind == .tutorial ? [.init(instruction: "", portrait: "")] : [])
    }

    static func load(folder: URL, kind: SDKDefinitionStudioView.Kind) -> [SDKDefinition] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return urls.filter { $0.pathExtension.lowercased() == "xml" }.compactMap { url in
            guard let root = try? XMLDocument(contentsOf: url).rootElement(), root.name == "Custom\(kind.rawValue)" else { return nil }
            func attribute(_ key: String, _ fallback: String = "") -> String { root.attribute(forName: key)?.stringValue ?? fallback }
            let steps = root.elements(forName: "Step").map {
                TutorialStepDefinition(instruction: $0.attribute(forName: "Message")?.stringValue ?? "", portrait: $0.attribute(forName: "Portrait")?.stringValue ?? "")
            }
            return SDKDefinition(file: url, stableID: attribute("Id", url.deletingPathExtension().lastPathComponent), name: attribute("Name"), details: attribute("Description"), type: attribute("Type"), target: Int(attribute("Target", "100")) ?? 100, amount: Int(attribute("Amount", "100")) ?? 100, order: Int(attribute("Order", "1")) ?? 1, reference: attribute("Reference"), message: attribute("Message"), once: attribute("Once", "1") != "0", difficulty: Int(attribute("Difficulty", "1")) ?? 1, maximumFloor: Int(attribute("MaximumFloor", "0")) ?? 0, weight: Int(attribute("Weight", "100")) ?? 100, protocolID: attribute("Protocol", "Any"), tutorialSteps: steps.isEmpty && kind == .tutorial ? [.init(instruction: attribute("Message"), portrait: attribute("Reference"))] : steps)
        }.sorted { $0.order == $1.order ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : $0.order < $1.order }
    }

    func write(folder: URL, kind: SDKDefinitionStudioView.Kind) throws -> URL {
        let clean = stableID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !clean.contains("/"), !clean.contains("\\") else { throw CocoaError(.fileWriteInvalidFileName) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let filename = clean.map { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" ? $0 : "_" }.reduce(into: "") { $0.append($1) } + ".xml"
        let destination = file ?? folder.appendingPathComponent(filename)
        let root = XMLElement(name: "Custom\(kind.rawValue)")
        let values = ["Id": clean, "Name": name, "Description": details, "Type": type, "Target": "\(target)", "Amount": "\(amount)", "Order": "\(order)", "Reference": reference, "Message": message, "Once": once ? "1" : "0", "Difficulty": "\(difficulty)", "MaximumFloor": "\(maximumFloor)", "Weight": "\(weight)", "Protocol": protocolID]
        for key in values.keys.sorted() where !values[key, default: ""].isEmpty {
            root.addAttribute(XMLNode.attribute(withName: key, stringValue: values[key, default: ""]) as! XMLNode)
        }
        if kind == .tutorial {
            for (index, step) in tutorialSteps.enumerated() where !step.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let node = XMLElement(name: "Step")
                node.addAttribute(XMLNode.attribute(withName: "Order", stringValue: "\(index + 1)") as! XMLNode)
                node.addAttribute(XMLNode.attribute(withName: "Message", stringValue: step.instruction) as! XMLNode)
                if !step.portrait.isEmpty { node.addAttribute(XMLNode.attribute(withName: "Portrait", stringValue: step.portrait) as! XMLNode) }
                root.addChild(node)
            }
        }
        let document = XMLDocument(rootElement: root); document.version = "1.0"; document.characterEncoding = "utf-8"
        try document.xmlData(options: .nodePrettyPrint).write(to: destination, options: .atomic)
        return destination
    }
}
