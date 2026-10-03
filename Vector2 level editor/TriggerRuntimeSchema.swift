import Foundation

struct TriggerDiagnostic: Equatable {
    enum Severity: String { case error, warning }
    var severity: Severity
    var message: String
}

nonisolated struct TriggerRuntimeItem: Identifiable, Equatable, Sendable {
    var id: String { xmlName }
    var xmlName: String
    var title: String
    var requiredAttributes: [String]
    var suggestedAttributes: [String: String]
}

enum TriggerRuntimeSchema {
    static let events: [TriggerRuntimeItem] = [
        item("EventBlock", required: ["Template"]),
        item("Enter"), item("Exit"), item("Timeout"), item("KeyPressed"), item("Activate"),
        item("Line", required: ["Position", "Type"]), item("Collision"), item("OnShow"), item("OnHide"),
        item("OnShowWidescreen"), item("OnHideWidescreen"), item("ValueChange", required: ["Value"]),
        item("OnStartGame"), item("OnGlobalTimer"), item("SwarmArrival"), item("SwarmDeparture"),
        item("SwarmDec"), item("EndGame"), item("ActivateNearPlayer"), item("OnDeath")
    ]

    static let actions: [TriggerRuntimeItem] = [
        item("ActionBlock", required: ["Template"]),
        item("SoundSource", required: ["Name"], defaults: ["Switch": "On", "VolumeFactor": "1"]),
        item("Camera"), item("Wait", required: ["Frames"]), item("SetVariable", required: ["Name", "Value"]),
        item("AppendValue", required: ["Name", "Value"]), item("Press", required: ["Key", "Model"]),
        item("ForceAnimation", required: ["Name", "Model"], defaults: ["Frame": "-1", "Reversed": "0"]),
        item("Control", required: ["Model", "Switch"]), item("EndGame", required: ["Result", "Model"]),
        item("SetTimer", required: ["Frames"]), item("Spawn", required: ["Model"]), item("ExitAI", required: ["Model"]),
        item("Transform", required: ["Name"]), item("Choose", required: ["Set", "Order"]),
        item("Activate", required: ["ActionID"]), item("ModelExecute", required: ["AnimName", "AnimFrame"]),
        item("Kill", required: ["Model"]), item("ArmorDamage"), item("AddItem"),
        item("Sound", required: ["Name"], defaults: ["Action": "Play", "Channel": "Sound", "Volume": "1"]),
        item("Music", required: ["Track"], defaults: ["Action": "Play", "Time": "0"]),
        item("MakeRoom"), item("ChangeExit", required: ["Name"]),
        item("Impulse", required: ["Model", "Impulse", "R"], defaults: ["Absorption": "0.8"]),
        item("RunModelEffect", required: ["Name", "Model"]), item("Tutorial"),
        item("SetModelParameter", required: ["ModelName", "ParamName", "Type", "Value"]),
        item("FloatingText"), item("TutorialSequence", required: ["Name"]),
        item("GlobalTimer", required: ["Action"], defaults: ["Frames": "600"]),
        item("ExecuteCall", required: ["Message"]), item("Statistics", required: ["SignalMessage"]),
        item("GUI", required: ["Action"]), item("Swarm", required: ["Type", "SwarmName"]),
        item("Chapter"), item("ActivatePassiveEffect", required: ["ActionID"]),
        item("ActivateNearPlayer", required: ["ActionID"]), item("BlockAnimationKey", required: ["Key", "Value"])
    ]

    static let conditions: [TriggerRuntimeItem] = [
        item("ConditionBlock", required: ["Template"]),
        item("Equal", required: ["Value1", "Value2"]),
        item("Greater", required: ["Value1", "Value2"]),
        item("Less", required: ["Value1", "Value2"]),
        item("GreaterEqual", required: ["Value1", "Value2"]),
        item("LessEqual", required: ["Value1", "Value2"]),
        item("Operator", required: ["Type"]),
        item("Select", required: ["Object", "From", "Section"])
    ]

    static func validate(_ definition: TriggerDefinition) -> [TriggerDiagnostic] {
        var result: [TriggerDiagnostic] = []
        if definition.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.append(.init(severity: .error, message: "Trigger Name is required."))
        }
        if definition.bounds.width <= 0 || definition.bounds.height <= 0 {
            result.append(.init(severity: .error, message: "Trigger Width and Height must be greater than zero."))
        }
        let hasWholeTemplate = definition.otherContent.contains { $0.name == "Template" && $0.attributes["Name"]?.isEmpty == false }
        if definition.loops.isEmpty && !hasWholeTemplate {
            result.append(.init(severity: .error, message: "A trigger needs at least one Loop."))
        }
        for (index, loop) in definition.loops.enumerated() {
            let template = loop.attributes["Template"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if loop.events.isEmpty && template.isEmpty { result.append(.init(severity: .error, message: "Loop \(index + 1) needs an event.")) }
            if loop.actions.isEmpty && template.isEmpty { result.append(.init(severity: .warning, message: "Loop \(index + 1) has no actions.")) }
            loop.events.forEach { validate($0.node, against: events, location: "event", into: &result) }
            loop.conditions.forEach { validate($0, against: conditions, location: "condition", into: &result) }
            loop.actions.forEach { validate($0.node, against: actions, location: "action", into: &result) }
        }
        return result
    }

    private static func validate(_ node: TriggerXMLNode, against catalogue: [TriggerRuntimeItem], location: String, into diagnostics: inout [TriggerDiagnostic]) {
        guard let definition = catalogue.first(where: { $0.xmlName == node.name }) else {
            diagnostics.append(.init(severity: .warning, message: "Unknown \(location) <\(node.name)> is preserved as raw XML."))
            return
        }
        let element = XMLElement(name: node.name)
        for (key, value) in node.attributes { element.addAttribute(XMLNode.attribute(withName: key, stringValue: value) as! XMLNode) }
        let section = location == "action" ? "Actions" : location == "init" ? "Init" : ""
        for attribute in XMLAssistantContext.requiredFields(element, section: section, base: definition.requiredAttributes) where node.attributes[attribute]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            diagnostics.append(.init(severity: .error, message: "\(node.name) requires \(attribute)."))
        }
    }

    private static func item(_ xmlName: String, required: [String] = [], defaults: [String: String] = [:]) -> TriggerRuntimeItem {
        TriggerRuntimeItem(xmlName: xmlName, title: xmlName.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression), requiredAttributes: required, suggestedAttributes: defaults)
    }
}
