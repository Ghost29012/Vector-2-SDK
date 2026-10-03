import SwiftUI

/// Tiny routing layer only. Each studio lives in its own file so one feature
/// cannot turn this screen back into a thousand-line grab bag.
struct ProjectSystemStudioView: View {
    let section: String
    let projectRoot: URL
    let gameDataRoot: URL?
    let onOpenTrickStudio: () -> Void
    let onStatus: (String) -> Void

    @ViewBuilder var body: some View {
        switch section {
        case "Shop": CommerceStudioView(mode: .shop, projectRoot: projectRoot, onOpenTrickStudio: onOpenTrickStudio, onStatus: onStatus)
        case "Upgrades": CommerceStudioView(mode: .upgrades, projectRoot: projectRoot, onOpenTrickStudio: onOpenTrickStudio, onStatus: onStatus)
        case "Save Data": SaveProfileStudio(projectRoot: projectRoot, gameDataRoot: gameDataRoot)
        case "Protocols": ProtocolDesignerView(projectRoot: projectRoot, onStatus: onStatus)
        case "Models": ModelDesignerView(projectRoot: projectRoot, onStatus: onStatus)
        case "Traps": CustomTrapDesignerView(projectRoot: projectRoot, onStatus: onStatus)
        case "Trigger Designer": ProjectTriggerStudioView(projectRoot: projectRoot, onStatus: onStatus)
        case "Audio": AudioDesignerView(projectRoot: projectRoot, onStatus: onStatus)
        case "Generator": GeneratorStudio(projectRoot: projectRoot)
        case "Missions": SDKDefinitionStudioView(kind: .mission, folder: projectRoot.appendingPathComponent("custom_missions"), onStatus: onStatus)
        case "Rewards": SDKDefinitionStudioView(kind: .reward, folder: projectRoot.appendingPathComponent("custom_rewards"), onStatus: onStatus)
        case "Tutorials": SDKDefinitionStudioView(kind: .tutorial, folder: projectRoot.appendingPathComponent("custom_tutorials"), onStatus: onStatus)
        default: ProjectCollectionStudio(title: section, subtitle: "Project content", symbol: "square.grid.2x2", tint: .blue, folder: projectRoot, empty: "Nothing here yet")
        }
    }
}
