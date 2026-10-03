import Foundation

struct QuestSequenceStep: Identifiable, Equatable {
    var id = UUID()
    var title: String
    var event: String
    var visualGroup = ""
    var visualGIF = ""
}

enum QuestSequenceCompiler {
    static func progressTriggers(questID: String, steps: [QuestSequenceStep], rewardPreset: String) -> [XMLElement] {
        steps.enumerated().map { index, step in
            let trigger = element("Trigger", ["Name": "Step_\(index + 1)", "EditorTitle": step.title, "EditorManaged": "Sequence"])
            let content = XMLElement(name: "Content")
            let loop = element("Loop", ["Name": "Step_\(index + 1)"])
            let events = XMLElement(name: "Events")
            events.addChild(element("OnCall", ["Name": "Trigger", "Message": step.event.trimmingCharacters(in: .whitespacesAndNewlines)]))
            let conditions = XMLElement(name: "Conditions")
            conditions.addChild(element("CounterRange", ["Name": questID, "Namespace": "ST_Quests", "Equal": "1"]))
            conditions.addChild(element("CounterRange", ["Name": "Step", "Namespace": questID, "Equal": "\(index)"]))
            let actions = XMLElement(name: "Actions")
            let group = step.visualGroup.trimmingCharacters(in: .whitespacesAndNewlines)
            let gif = step.visualGIF.trimmingCharacters(in: .whitespacesAndNewlines)
            if !group.isEmpty && !gif.isEmpty {
                let stem = URL(fileURLWithPath: gif).deletingPathExtension().lastPathComponent
                actions.addChild(element("ExecuteCall", ["Message": "Content.Visual:\(group):gif_\(stem).xml"]))
            }
            if index + 1 < steps.count {
                actions.addChild(element("SetCounter", ["Name": "Step", "Namespace": questID, "Value": "\(index + 1)"]))
            } else {
                if !rewardPreset.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    actions.addChild(element("AddItem", ["Preset": rewardPreset.trimmingCharacters(in: .whitespacesAndNewlines)]))
                }
                actions.addChild(XMLElement(name: "QuestComplete"))
            }
            [events, conditions, actions].forEach(loop.addChild)
            content.addChild(loop)
            trigger.addChild(content)
            return trigger
        }
    }

    private static func element(_ name: String, _ attributes: [(String, String)]) -> XMLElement {
        let node = XMLElement(name: name)
        for (key, value) in attributes where !value.isEmpty {
            node.addAttribute(XMLNode.attribute(withName: key, stringValue: value) as! XMLNode)
        }
        return node
    }

    private static func element(_ name: String, _ attributes: [String: String]) -> XMLElement {
        // Keep Vector-facing XML deterministic for readable diffs.
        let order = ["Name", "EditorTitle", "Namespace", "Equal", "Value", "Message", "Preset", "EditorManaged"]
        let pairs = order.compactMap { key in attributes[key].map { (key, $0) } }
            + attributes.keys.filter { !order.contains($0) }.sorted().map { ($0, attributes[$0] ?? "") }
        return element(name, pairs)
    }
}
