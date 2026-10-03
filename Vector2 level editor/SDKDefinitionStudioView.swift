import Foundation
import SwiftUI

/// Edit mission, reward and tutorial XML from project forms.
struct SDKDefinitionStudioView: View {
    enum Kind: String {
        case mission = "Mission"
        case reward = "Reward"
        case tutorial = "Tutorial"

        var plural: String { rawValue + "s" }
        var symbol: String { self == .mission ? "scope" : self == .reward ? "gift.fill" : "graduationcap.fill" }
        var tint: Color { self == .mission ? .red : self == .reward ? .orange : .indigo }
        var subtitle: String {
            switch self {
            case .mission: return "Choose the target, goal, and reward for each mission."
            case .reward: return "Set up rewards used by quests and missions."
            case .tutorial: return "Write the steps shown to the player, in order."
            }
        }
    }

    let kind: Kind
    let folder: URL
    let onStatus: (String) -> Void

    @State private var items: [SDKDefinition] = []
    @State private var selectedID: UUID?
    @State private var query = ""
    @State private var confirmingDelete = false

    private var selectedIndex: Int? { items.firstIndex { $0.id == selectedID } }
    private var filtered: [SDKDefinition] {
        query.isEmpty ? items : items.filter { $0.name.localizedCaseInsensitiveContains(query) || $0.stableID.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                catalogue.frame(minWidth: 250, idealWidth: 285, maxWidth: 330, maxHeight: .infinity)
                if let index = selectedIndex {
                    editor(item: $items[index]).frame(minWidth: 620)
                } else {
                    ContentUnavailableView("No \(kind.rawValue) selected", systemImage: kind.symbol,
                                           description: Text("Create one to begin designing it."))
                        .frame(minWidth: 620, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { reload() }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: kind.symbol).font(.system(size: 22, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 48, height: 48).background(kind.tint.gradient, in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.plural).font(.system(size: 27, weight: .bold))
                Text(kind.subtitle).foregroundStyle(.secondary)
            }
            Spacer()
            Button { reload() } label: { Label("Reload", systemImage: "arrow.clockwise") }
            Button { createItem() } label: { Label("New \(kind.rawValue)", systemImage: "plus") }.buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 24).padding(.vertical, 16)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.94))
    }

    private var catalogue: some View {
        VStack(spacing: 10) {
            TextField("Find \(kind.rawValue.lowercased())", text: $query).textFieldStyle(.roundedBorder).padding(14)
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(filtered) { item in
                        Button { selectedID = item.id; confirmingDelete = false } label: {
                            HStack(spacing: 11) {
                                Image(systemName: kind.symbol).foregroundStyle(kind.tint)
                                    .frame(width: 38, height: 38).background(kind.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.name.isEmpty ? "Untitled \(kind.rawValue)" : item.name).fontWeight(.semibold).lineLimit(1)
                                    Text(item.summary(kind)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                            }.padding(9).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .background(selectedID == item.id ? kind.tint.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 11))
                    }
                }.padding(.horizontal, 9)
            }
            Text("\(items.count) \(kind.plural.lowercased())").font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(14)
        }.background(Color(nsColor: .controlBackgroundColor).opacity(0.8))
    }

    private func editor(item: Binding<SDKDefinition>) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                preview(item.wrappedValue)
                section("Details", "The name and ID used by this \(kind.rawValue.lowercased()).") {
                    field("Name", text: item.name)
                    field("Stable ID", text: item.stableID)
                    field("Description", text: item.details, multiline: true)
                }
                switch kind {
                case .mission: MissionDesignerFields(item: item)
                case .reward: RewardDesignerFields(item: item)
                case .tutorial: TutorialDesignerFields(item: item)
                }
                saveBar(item)
            }.frame(maxWidth: 940).padding(24).frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder private func preview(_ item: SDKDefinition) -> some View {
        switch kind {
        case .mission:
            HStack(spacing: 18) {
                Image(systemName: "scope").font(.system(size: 48)).foregroundStyle(.red)
                VStack(alignment: .leading) { Text(item.nameOrUntitled).font(.title2.bold()); Text(item.details).foregroundStyle(.secondary).lineLimit(2) }
                Spacer(); Text("\(item.target)").font(.system(size: 34, weight: .bold, design: .rounded)); Text(item.type)
            }.padding(22).background(LinearGradient(colors: [.red.opacity(0.14), .orange.opacity(0.05)], startPoint: .leading, endPoint: .trailing), in: RoundedRectangle(cornerRadius: 20))
        case .reward:
            HStack(spacing: 18) {
                Image(systemName: item.rewardSymbol).font(.system(size: 42)).foregroundStyle(.orange)
                    .frame(width: 86, height: 86).background(.orange.opacity(0.13), in: Circle())
                VStack(alignment: .leading, spacing: 5) { Text(item.nameOrUntitled).font(.title2.bold()); Text(item.type).foregroundStyle(.secondary); Text("×\(item.amount)").font(.title.bold()) }
                Spacer()
            }.padding(22).background(LinearGradient(colors: [.orange.opacity(0.15), .yellow.opacity(0.04)], startPoint: .leading, endPoint: .trailing), in: RoundedRectangle(cornerRadius: 20))
        case .tutorial:
            HStack(spacing: 16) {
                Text("\(item.order)").font(.title.bold()).foregroundStyle(.white).frame(width: 54, height: 54).background(.indigo, in: Circle())
                VStack(alignment: .leading, spacing: 4) { Text(item.nameOrUntitled).font(.title2.bold()); Text(item.details).foregroundStyle(.secondary).lineLimit(2) }
                Spacer(); Label(item.type, systemImage: "play.circle")
            }.padding(22).background(.indigo.opacity(0.1), in: RoundedRectangle(cornerRadius: 20))
        }
    }

    private func section<Content: View>(_ title: String, _ subtitle: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(title).font(.title3.bold()); Text(subtitle).font(.caption).foregroundStyle(.secondary); Divider(); content()
        }.padding(18).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 17))
            .overlay(RoundedRectangle(cornerRadius: 17).stroke(Color.secondary.opacity(0.15)))
    }

    private func field(_ title: String, text: Binding<String>, multiline: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            TextField(title, text: text, axis: multiline ? .vertical : .horizontal).textFieldStyle(.roundedBorder).lineLimit(multiline ? 2...5 : 1...1)
        }
    }

    private func saveBar(_ item: Binding<SDKDefinition>) -> some View {
        HStack {
            if confirmingDelete {
                Text("Delete this \(kind.rawValue.lowercased())?").foregroundStyle(.red)
                Button("Keep It") { confirmingDelete = false }
                Button("Delete", role: .destructive) { delete(item.wrappedValue) }
            } else { Button("Delete", role: .destructive) { confirmingDelete = true } }
            Spacer(); Button("Revert") { reload(selectingPath: item.wrappedValue.file?.path) }
            Button("Save \(kind.rawValue)") { save(item.wrappedValue) }.buttonStyle(.borderedProminent).controlSize(.large)
        }
    }

    private func createItem() {
        let item = SDKDefinition.new(kind)
        items.insert(item, at: 0); selectedID = item.id; confirmingDelete = false
    }

    private func reload(selectingPath: String? = nil) {
        items = SDKDefinition.load(folder: folder, kind: kind)
        selectedID = items.first(where: { $0.file?.path == selectingPath })?.id ?? items.first?.id
        confirmingDelete = false
    }

    private func save(_ item: SDKDefinition) {
        do {
            let path = try item.write(folder: folder, kind: kind)
            onStatus("Saved \(item.nameOrUntitled).")
            reload(selectingPath: path.path)
        } catch { onStatus("Could not save: \(error.localizedDescription)") }
    }

    private func delete(_ item: SDKDefinition) {
        do { if let file = item.file { try FileManager.default.removeItem(at: file) }; onStatus("Deleted \(item.nameOrUntitled)."); reload() }
        catch { onStatus("Could not delete: \(error.localizedDescription)") }
    }
}
