import Foundation

struct XMLAuthoringDiagnostic: Equatable, Identifiable {
    enum Severity { case error, warning, info }
    let id = UUID()
    var severity: Severity
    var message: String
}

struct XMLAuthoringCompletion: Identifiable, Equatable {
    var id: String { insertion }
    var title: String
    var detail: String
    var insertion: String
}

enum XMLAuthoringIntelligence {
    static func validate(_ source: String, knownLibraryObjects: Set<String>, knownTextures: Set<String>) -> [XMLAuthoringDiagnostic] {
        if TriggerRuntimeSchema.isEmptyXMLDraft(source) { return [.init(severity: .info, message: "No XML element to check yet.")] }
        guard let data = source.data(using: .utf8) else { return [.init(severity: .error, message: "XML is not UTF-8 text.")] }
        let document: XMLDocument
        do { document = try XMLDocument(data: data) }
        catch { return [.init(severity: .error, message: "Malformed XML: \(error.localizedDescription)")] }
        var result: [XMLAuthoringDiagnostic] = []
        if let trigger = try? TriggerXMLCodec.decode(source) {
            result += TriggerRuntimeSchema.validate(trigger).map { .init(severity: $0.severity == .error ? .error : .warning, message: $0.message) }
        }
        let nodes = (try? document.nodes(forXPath: "//*")) as? [XMLElement] ?? []
        let eventNames = Set(TriggerRuntimeSchema.events.map(\.xmlName))
        let conditionNames = Set(TriggerRuntimeSchema.conditions.map(\.xmlName))
        let actionNames = Set(TriggerRuntimeSchema.actions.map(\.xmlName))
        let runtimeItems = TriggerRuntimeSchema.events + TriggerRuntimeSchema.conditions + TriggerRuntimeSchema.actions
        for node in nodes {
            let contextualItems: [TriggerRuntimeItem]
            switch node.parent?.name {
            case "Events": contextualItems = TriggerRuntimeSchema.events
            case "Conditions": contextualItems = TriggerRuntimeSchema.conditions
            case "Actions", "Init": contextualItems = TriggerRuntimeSchema.actions
            default: contextualItems = runtimeItems
            }
            if let name = node.name, let schema = contextualItems.first(where: { $0.xmlName == name }) {
                for attribute in schema.requiredAttributes where node.attribute(forName: attribute)?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                    let message = "\(name) requires \(attribute)."
                    if !result.contains(where: { $0.message == message }) { result.append(.init(severity: .error, message: message)) }
                }
            }
            if node.name == "ObjectReference" || node.name == "LibraryObject" || (node.name == "Object" && node.attribute(forName: "Template")?.stringValue == "LibraryObject") {
                let name = node.attribute(forName: "Class")?.stringValue ?? node.attribute(forName: "Name")?.stringValue ?? ""
                if !name.isEmpty, !knownLibraryObjects.isEmpty, !knownLibraryObjects.contains(name) { result.append(.init(severity: .warning, message: "Unresolved library object '\(name)'. Import its library or obstacle package.")) }
            }
            if node.name == "Image" {
                let name = node.attribute(forName: "Class")?.stringValue ?? node.attribute(forName: "Name")?.stringValue ?? ""
                if !name.isEmpty, !knownTextures.isEmpty, !knownTextures.contains(name) { result.append(.init(severity: .warning, message: "Texture '\(name)' is not currently indexed.")) }
            }
            if let name = node.name, let parent = node.parent as? XMLElement {
                let allowed: Set<String>?
                switch parent.name {
                case "Events": allowed = eventNames
                case "Conditions": allowed = conditionNames
                case "Actions": allowed = actionNames
                default: allowed = nil
                }
                if let allowed, !allowed.contains(name) {
                    result.append(.init(severity: .warning, message: "Unknown <\(name)> inside <\(parent.name ?? "trigger section")>. Vector may ignore it or fail to create the trigger."))
                }
            }
        }
        var seen: Set<String> = []
        result = result.filter { seen.insert("\($0.severity):\($0.message)").inserted }
        if result.isEmpty { result.append(.init(severity: .info, message: "No issues found by the available XML checks.")) }
        return result
    }

    static func completions(prefix: String) -> [XMLAuthoringCompletion] {
        let catalogue = TriggerRuntimeSchema.events.map { ($0, "Event") } + TriggerRuntimeSchema.conditions.map { ($0, "Condition") } + TriggerRuntimeSchema.actions.map { ($0, "Action") }
        let clean = prefix.lowercased()
        let runtime: [XMLAuthoringCompletion] = catalogue.filter { clean.isEmpty || $0.0.xmlName.lowercased().hasPrefix(clean) }.map { item, kind in
            let attributes = (item.requiredAttributes.map { "\($0)=\"\"" } + item.suggestedAttributes.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\"\($0.value)\"" }).joined(separator: " ")
            let required = item.requiredAttributes.isEmpty ? "no required attributes" : "requires " + item.requiredAttributes.joined(separator: ", ")
            return XMLAuthoringCompletion(title: item.title, detail: "Vector runtime \(kind.lowercased()) · \(required)", insertion: "<\(item.xmlName)\(attributes.isEmpty ? "" : " \(attributes)")/>")
        }
        let scene: [XMLAuthoringCompletion] = [
            .init(title: "Object", detail: "Vector scene container", insertion: "<Object Name=\"Object\" Factor=\"1\"><Content></Content></Object>"),
            .init(title: "Library Object", detail: "Reference an object from a game or custom library", insertion: "<Object Name=\"Object\" Template=\"LibraryObject\" File=\"library.xml\" Class=\"ObjectName\" X=\"0\" Y=\"0\"/>") ,
            .init(title: "Image", detail: "Rendered Vector texture", insertion: "<Image Name=\"Image\" Class=\"texture.name\" Layer=\"Wall\" X=\"0\" Y=\"0\" Width=\"100\" Height=\"100\"/>") ,
            .init(title: "Platform", detail: "Player collision surface", insertion: "<Platform Name=\"Platform\" X=\"0\" Y=\"0\" Width=\"300\" Height=\"60\"/>") ,
            .init(title: "Area", detail: "Non-rendered gameplay region", insertion: "<Area Name=\"Area\" X=\"0\" Y=\"0\" Width=\"300\" Height=\"180\"/>") ,
            .init(title: "Trigger", detail: "Runtime event region", insertion: "<Trigger Name=\"Trigger\" X=\"0\" Y=\"0\" Width=\"300\" Height=\"180\"><Content><Loop><Events><Enter/></Events><Actions></Actions></Loop></Content></Trigger>")
        ].filter { clean.isEmpty || $0.title.replacingOccurrences(of: " ", with: "").lowercased().hasPrefix(clean) }
        return scene + runtime
    }
}
