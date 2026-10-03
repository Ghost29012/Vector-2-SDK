import Foundation

struct TriggerTemplateEntry: Identifiable, Equatable {
    enum Kind: String { case whole, loop, event, condition, action }
    var id: String { "\(kind.rawValue):\(reference)" }
    var title: String
    var reference: String
    var detail: String
    var kind: Kind
}

enum TriggerTemplateSelection: Equatable {
    case whole(String), loop(String), event(String), condition(String), action(String)
}

/// Exact names exposed by Vector 2's trigger_templates.xml. These are runtime
/// references, not editor-authored lookalikes.
enum TriggerTemplateCatalogue {
    static let whole: [TriggerTemplateEntry] = [
        entry("Camera zoom", "CameraZoom", "Changes camera zoom when entered.", .whole),
        entry("Camera smoothness", "CameraSmoothness", "Smooth camera movement while inside.", .whole),
        entry("Camera follow", "CameraFollow", "Makes the camera follow a model.", .whole),
        entry("Forced animation", "ForcedAnimation", "Forces a player animation on entry.", .whole),
        entry("Death area", "Death", "Uses Vector's stock player/bot death behavior.", .whole),
        entry("Control toggle", "Control", "Turns player control on or off.", .whole),
        entry("Model animation", "ModelAnimation", "Runs an animation on a referenced model.", .whole),
        entry("Standard door opener", "standard_door_opener", "Receives the stock door open/kill signals.", .whole),
        entry("No-type collision", "NoneType", "Stock one-shot collision trigger.", .whole)
    ]

    static let loops: [TriggerTemplateEntry] = [
        entry("Camera zoom loop", "CameraZoom.Only", "The stock CameraZoom loop.", .loop),
        entry("Enter", "FreqUsed.Enter", "Runs when the trigger is entered.", .event),
        entry("Exit", "FreqUsed.Exit", "Runs when the trigger is exited.", .event),
        entry("Enter or exit", "FreqUsed.EnterOrExit", "Runs on either boundary crossing.", .event),
        entry("Activated", "FreqUsed.Activate", "Runs when an ActionID activates it.", .event),
        entry("Collision", "FreqUsed.OnCollision", "Runs on model collision.", .event),
        entry("Player only", "FreqUsed.TriggeredByPlayer", "Requires the triggering model to be the player.", .condition),
        entry("Any bot", "FreqUsed.TriggeredByAnyBot", "Requires a non-player model.", .condition),
        entry("Player alive", "FreqUsed.CheckIfAlive", "Requires the player to be alive.", .condition),
        entry("Required animation", "CommonLib.RequiredAnimation", "Requires the configured player animation.", .condition),
        entry("Play configured sound", "CommonLib.Sound", "Runs Vector's reusable sound action.", .action),
        entry("Wait configured delay", "CommonLib.Delay", "Runs Vector's reusable delay action.", .action),
        entry("Switch trigger on", "FreqUsed.SwitchOn", "Sets $Active to 1.", .action),
        entry("Switch trigger off", "FreqUsed.SwitchOff", "Sets $Active to 0.", .action),
        entry("Dispatch event", "FreqUsed.DispatchEvent", "Dispatches the configured ActionID.", .action)
    ]

    static func apply(_ selection: TriggerTemplateSelection, to definition: inout TriggerDefinition, selectedLoop: Int = 0) {
        switch selection {
        case .whole(let name):
            definition.otherContent.removeAll { $0.name == "Template" }
            definition.otherContent.insert(.init(name: "Template", attributes: ["Name": name]), at: 0)
            definition.loops.removeAll()
        case .loop(let name):
            definition.loops.append(.init(attributes: ["Template": name]))
        case .event(let name):
            guard definition.loops.indices.contains(selectedLoop) else { return }
            definition.loops[selectedLoop].events.append(.init(node: .init(name: "EventBlock", attributes: ["Template": name])))
        case .condition(let name):
            guard definition.loops.indices.contains(selectedLoop) else { return }
            definition.loops[selectedLoop].conditions.append(.init(name: "ConditionBlock", attributes: ["Template": name]))
        case .action(let name):
            guard definition.loops.indices.contains(selectedLoop) else { return }
            definition.loops[selectedLoop].actions.append(.init(node: .init(name: "ActionBlock", attributes: ["Template": name])))
        }
    }

    private static func entry(_ title: String, _ reference: String, _ detail: String, _ kind: TriggerTemplateEntry.Kind) -> TriggerTemplateEntry {
        .init(title: title, reference: reference, detail: detail, kind: kind)
    }
}
