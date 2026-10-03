import Foundation

/// These are gameplay behaviours the shipped game adapter genuinely executes.
/// Keeping the list here means the UI cannot promise a mechanic the runtime
/// does not know how to perform.
struct GameplayEffectDefinition: Identifiable {
    struct Parameter {
        let key: String
        let title: String
        let defaultValue: String
    }

    let id: String
    let title: String
    let explanation: String
    let parameters: [Parameter]
}

enum GameplayEffectCatalog {
    static let effects = [
        GameplayEffectDefinition(
            id: "None",
            title: "Collectible only",
            explanation: "The card can be collected and displayed, but does not alter gameplay.",
            parameters: []
        ),
        GameplayEffectDefinition(
            id: "RegenerateCharges",
            title: "Regenerate gadget charges",
            explanation: "Restores charges over time while the player is running.",
            parameters: [
                .init(key: "Interval", title: "Seconds between refills", defaultValue: "5"),
                .init(key: "Amount", title: "Charges restored", defaultValue: "1"),
                .init(key: "Maximum", title: "Charge limit", defaultValue: "12")
            ]
        ),
        GameplayEffectDefinition(
            id: "RestoreChargesOnFloorStart",
            title: "Restore charges each floor",
            explanation: "Restores a fixed number of charges when gameplay for a floor begins.",
            parameters: [
                .init(key: "Amount", title: "Charges restored", defaultValue: "2")
            ]
        ),
        GameplayEffectDefinition(
            id: "FillChargesOnFloorStart",
            title: "Refill gadgets each floor",
            explanation: "Fills every equipped gadget to its normal capacity when a floor begins.",
            parameters: []
        )
    ]

    static var knownParameterKeys: Set<String> {
        Set(effects.flatMap(\.parameters).map(\.key))
    }

    // Charge regeneration belongs to protocols, not user-authored upgrade
    // cards. This keeps the card creator honest without removing protocol support.
    static var upgradeCardEffects: [GameplayEffectDefinition] {
        effects.filter { $0.id != "RegenerateCharges" }
    }

    static func definition(_ id: String) -> GameplayEffectDefinition? {
        effects.first { $0.id.caseInsensitiveCompare(id) == .orderedSame }
    }

    static func title(forParameter key: String) -> String {
        effects.flatMap(\.parameters).first { $0.key == key }?.title ?? key
    }
}
