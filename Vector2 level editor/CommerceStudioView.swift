import AppKit
import Foundation
import SwiftUI

/// The shop and upgrade pages are two views of the same real card catalogue.
/// Keeping one model prevents the shop preview and progression editor drifting apart.
struct CommerceStudioView: View {
    enum Mode { case shop, upgrades }

    let mode: Mode
    let projectRoot: URL
    let onOpenTrickStudio: () -> Void
    let onStatus: (String) -> Void
    @Environment(\.colorScheme) private var colorScheme

    @State private var cards: [CommerceCard] = []
    @State private var selectedID: String?
    @State private var search = ""
    @State private var savedPulse = false
    @State private var creatingCard = false
    @State private var confirmingDelete = false

    private var filteredCards: [CommerceCard] {
        guard !search.isEmpty else { return cards }
        return cards.filter { $0.visualName.localizedCaseInsensitiveContains(search) || $0.cardName.localizedCaseInsensitiveContains(search) }
    }

    private var selectedIndex: Int? { cards.firstIndex { $0.id == selectedID } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if cards.isEmpty && !creatingCard { emptyState }
            else {
                HSplitView {
                    catalogue
                        .frame(minWidth: 250, idealWidth: 280, maxWidth: 320)
                    if creatingCard {
                        CommerceCardCreator(projectRoot: projectRoot, artwork: availableArtwork, onCancel: { creatingCard = false }) { card in
                            creatingCard = false
                            reload(selecting: card.id)
                            onStatus("Created \(card.visualName). Its shop card and upgrade path are ready.")
                        }.frame(minWidth: 670)
                    } else if let index = selectedIndex {
                        editor(card: $cards[index])
                            .frame(minWidth: 670)
                    } else {
                        ContentUnavailableView("Choose a card", systemImage: "rectangle.stack")
                    }
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { reload() }
        .alert("Delete this card package?", isPresented: $confirmingDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive, action: deleteSelectedCard)
        } message: {
            Text("For tricks, this removes the animation package, shop card and upgrade path together. Install Changes removes its old game copy.")
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: mode == .shop ? "cart.fill" : "arrow.up.circle.fill")
                .font(.system(size: 22, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .background((mode == .shop ? Color.blue : Color.purple).gradient, in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 2) {
                Text(mode == .shop ? "Shop" : "Upgrades").font(.system(size: 27, weight: .bold))
                Text(mode == .shop ? "Choose how each card appears and what it costs." : "Set the cost and effect of each upgrade level.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if savedPulse { Label("Saved", systemImage: "checkmark.circle.fill").foregroundStyle(.green).transition(.opacity) }
            if selectedIndex != nil, !creatingCard {
                Button(role: .destructive) { confirmingDelete = true } label: { Label("Delete", systemImage: "trash") }
            }
            Button { reload() } label: { Label("Reload", systemImage: "arrow.clockwise") }
            Button { creatingCard = true } label: { Label("New Card", systemImage: "rectangle.stack.badge.plus") }
            Button { onOpenTrickStudio() } label: { Label("New Trick & Card", systemImage: "plus") }
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 24).padding(.vertical, 16).background(Color(nsColor: .controlBackgroundColor).opacity(0.94))
    }

    private var catalogue: some View {
        VStack(spacing: 12) {
            TextField("Find a card", text: $search).textFieldStyle(.roundedBorder).padding(.horizontal, 14).padding(.top, 14)
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(filteredCards) { card in
                        Button { selectedID = card.id; creatingCard = false } label: {
                            HStack(spacing: 11) {
                                cardArtwork(card, size: 48)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(card.visualName).fontWeight(.semibold).lineLimit(1)
                                    Text("\(card.rarityName) · \(card.price) credits").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if !card.shopEnabled { Image(systemName: "eye.slash").foregroundStyle(.secondary) }
                            }.padding(9).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(selectedID == card.id ? Color.accentColor.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 11))
                    }
                }.padding(.horizontal, 9)
            }
            HStack { Text("\(cards.count) custom cards").font(.caption).foregroundStyle(.secondary); Spacer() }.padding(14)
        }.background(Color(nsColor: .controlBackgroundColor).opacity(0.82))
    }

    @ViewBuilder
    private func editor(card: Binding<CommerceCard>) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if mode == .shop { shopEditor(card: card) }
                else { upgradeEditor(card: card) }
            }
            .frame(maxWidth: 1050).padding(24).frame(maxWidth: .infinity)
        }
    }

    private func shopEditor(card: Binding<CommerceCard>) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 22) {
                    gameCardPreview(card.wrappedValue, width: 270)
                    shopDetails(card)
                }
                VStack(alignment: .leading, spacing: 18) {
                    gameCardPreview(card.wrappedValue, width: 330)
                    shopDetails(card)
                }
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 245), spacing: 14)], alignment: .leading, spacing: 14) {
                settingsCard("Pricing", "creditcard.fill", .green) {
                    integerStepper("Price", value: card.price, range: 0...100_000, step: 100, suffix: "credits")
                    integerStepper("Selection weight", value: card.weight, range: 1...100_000, step: 25, suffix: "")
                    Text("Higher weight makes this card more likely to be offered.").font(.caption).foregroundStyle(.secondary)
                }
                settingsCard("Availability", "slider.horizontal.3", .blue) {
                    integerStepper("Minimum progression", value: card.setupMin, range: 0...999, step: 1, suffix: "")
                    integerStepper("Maximum progression", value: card.setupMax, range: 0...999, step: 1, suffix: "")
                    labeledField("Shop group", text: card.group)
                }
                settingsCard("Gameplay", "figure.run", .orange) {
                    labeledField("Card ID", text: card.cardName)
                    Picker("Card type", selection: card.cardType) {
                        Text("Passive upgrade").tag("Passive")
                        Text("Trick").tag("Stunts")
                        Text("Story note").tag("Notes")
                        Text("Story item").tag("StoryItems")
                    }.pickerStyle(.menu)
                    labeledField("Category", text: card.category)
                    if card.wrappedValue.cardType == "Passive" { effectPicker(card) }
                    labeledField("Equipment slot", text: card.slot)
                }
            }
            saveBar(card)
        }
    }

    private func shopDetails(_ card: Binding<CommerceCard>) -> some View {
        VStack(alignment: .leading, spacing: 14) {
                    sectionTitle("Player-facing card", "Exactly what appears in Vector 2")
                    labeledField("Display name", text: card.visualName)
                    labeledField("Description", text: card.description, axis: .vertical)
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Artwork").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Picker("Artwork", selection: card.image) {
                                Text("Built-in fallback").tag("")
                                ForEach(availableArtwork, id: \.self) { Text($0).tag($0) }
                            }.labelsHidden().pickerStyle(.menu).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Rarity").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Picker("Rarity", selection: card.rarity) {
                                Text("Common").tag(1); Text("Rare").tag(2); Text("Epic").tag(3)
                            }.labelsHidden().pickerStyle(.segmented)
                        }
                    }
                    Toggle("Available in the shop", isOn: card.shopEnabled).toggleStyle(.switch)
        }.frame(minWidth: 320, maxWidth: .infinity, alignment: .topLeading)
    }

    private func upgradeEditor(card: Binding<CommerceCard>) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 18) {
                    gameCardPreview(card.wrappedValue, width: 285)
                    upgradeSummary(card)
                }
                VStack(alignment: .leading, spacing: 16) {
                    gameCardPreview(card.wrappedValue, width: 330)
                    upgradeSummary(card)
                }
            }

            effectCard(card)
            sectionTitle("Upgrade path", "Copies control when a level unlocks. The effect values below are applied at that level.")
            VStack(spacing: 9) {
                ForEach(0..<card.wrappedValue.maxLevel, id: \.self) { index in
                    levelRow(number: index + 1, level: card.levels[index], previous: index == 0 ? 0 : card.wrappedValue.levels[index - 1].points)
                }
            }
            saveBar(card)
        }
    }

    private func upgradeSummary(_ card: Binding<CommerceCard>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
                    Text(card.wrappedValue.visualName).font(.system(size: 26, weight: .bold))
                    Text("Set what each upgrade level costs and how much power it adds.").foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        statPill("Levels", "\(card.wrappedValue.maxLevel)", "flag.checkered", .purple)
                        statPill("Total copies", "\(card.wrappedValue.levels.prefix(card.wrappedValue.maxLevel).reduce(0) { $0 + $1.cards })", "rectangle.stack.fill", .blue)
                        statPill("Final power", "\(card.wrappedValue.levels.prefix(card.wrappedValue.maxLevel).last?.points ?? 0)", "bolt.fill", .orange)
                    }
                    integerStepper("Maximum level", value: card.maxLevel, range: 1...10, step: 1, suffix: "")
        }.frame(minWidth: 320, maxWidth: .infinity, alignment: .leading)
    }

    private func effectPicker(_ card: Binding<CommerceCard>) -> some View {
        Picker("Player effect", selection: Binding(get: { card.wrappedValue.effectID }, set: { value in
            card.wrappedValue.effectID = value
            configureProperties(for: value, card: card)
        })) {
            ForEach(GameplayEffectCatalog.upgradeCardEffects) { effect in Text(effect.title).tag(effect.id) }
            if GameplayEffectCatalog.definition(card.wrappedValue.effectID) == nil,
               card.wrappedValue.effectID != "RegenerateCharges" {
                Text("Existing custom effect: \(card.wrappedValue.effectID)").tag(card.wrappedValue.effectID)
            }
        }.pickerStyle(.menu)
    }

    private func effectCard(_ card: Binding<CommerceCard>) -> some View {
        settingsCard("What does this upgrade do?", "sparkles", .purple) {
            effectPicker(card)
            Text(GameplayEffectCatalog.definition(card.wrappedValue.effectID)?.explanation
                 ?? "This older effect ID is preserved, but the current runtime does not execute it.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func configureProperties(for effect: String, card: Binding<CommerceCard>) {
        guard let definition = GameplayEffectCatalog.definition(effect) else { return }
        for index in card.wrappedValue.levels.indices {
            card.wrappedValue.levels[index].properties.removeAll { GameplayEffectCatalog.knownParameterKeys.contains($0.name) }
            for parameter in definition.parameters {
                let value = CommerceProperty(name: parameter.key, value: parameter.defaultValue)
                card.wrappedValue.levels[index].properties.append(value)
            }
        }
    }

    private func levelRow(number: Int, level: Binding<CommerceLevel>, previous: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                Text("\(number)").font(.title2.bold()).foregroundStyle(.white).frame(width: 44, height: 44)
                    .background(Color.purple.gradient, in: Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text(number == 1 ? "Unlock card" : "Upgrade to level \(number)").fontWeight(.semibold)
                    Text("\(level.wrappedValue.cards) copies · +\(max(0, level.wrappedValue.points - previous)) power")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Stepper("Copies: \(level.wrappedValue.cards)", value: level.cards, in: 1...99).frame(width: 150)
                Stepper("Power: \(level.wrappedValue.points)", value: level.points, in: 0...100_000, step: 5).frame(width: 170)
            }
            if !level.wrappedValue.properties.isEmpty {
                Divider()
                HStack(spacing: 12) {
                    ForEach(level.wrappedValue.properties.indices, id: \.self) { index in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(propertyLabel(level.wrappedValue.properties[index].name)).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                            TextField("Value", text: level.properties[index].value).textFieldStyle(.roundedBorder).frame(width: 112)
                        }
                    }
                    Spacer()
                }
            }
        }
        .padding(14).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 15))
        .overlay(RoundedRectangle(cornerRadius: 15).stroke(Color.purple.opacity(0.18)))
    }

    private func propertyLabel(_ name: String) -> String {
        GameplayEffectCatalog.title(forParameter: name)
    }

    private func saveBar(_ card: Binding<CommerceCard>) -> some View {
        HStack {
            Label("Unknown animation settings and intervals are preserved.", systemImage: "checkmark.shield")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Revert") { reload(selecting: card.wrappedValue.id) }
            Button("Save Card") { save(card.wrappedValue) }.buttonStyle(.borderedProminent).controlSize(.large)
        }.padding(.top, 4)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No custom cards yet", systemImage: "rectangle.stack.badge.plus")
        } description: {
            Text("Create a trick with a shop card, then edit its price and upgrades here.")
        } actions: {
            Button("Create Card") { creatingCard = true }.buttonStyle(.borderedProminent)
            Button("Create Trick & Card", action: onOpenTrickStudio)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func gameCardPreview(_ card: CommerceCard, width: CGFloat) -> some View {
        let contentWidth = width - 28
        return VStack(alignment: .leading, spacing: 12) {
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 18).fill(LinearGradient(colors: [card.color.opacity(0.9), .black], startPoint: .topLeading, endPoint: .bottomTrailing))
                if let image = artwork(for: card.image) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: contentWidth, height: 230)
                        .clipped()
                    LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .center, endPoint: .bottom)
                        .frame(width: contentWidth, height: 230)
                } else {
                    Image(systemName: "figure.run").font(.system(size: 72, weight: .thin)).foregroundStyle(.white.opacity(0.8)).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(card.rarityName.uppercased()).font(.caption2.bold()).foregroundStyle(card.color)
                    Text(card.visualName).font(.title3.bold()).foregroundStyle(.white).lineLimit(2)
                }.padding(15)
            }.frame(width: contentWidth, height: 230).clipShape(RoundedRectangle(cornerRadius: 18))
            Text(card.description.isEmpty ? "No description yet." : card.description)
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack { Label("\(card.price)", systemImage: "creditcard.fill"); Spacer(); Label("Level \(card.maxLevel)", systemImage: "arrow.up.circle") }.font(.caption.bold())
        }.frame(width: contentWidth).padding(14).frame(width: width)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(card.color.opacity(0.35)))
    }

    private func cardArtwork(_ card: CommerceCard, size: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(card.color.opacity(0.13))
            if let image = artwork(for: card.image) { Image(nsImage: image).resizable().scaledToFill().frame(width: size, height: size).clipped() }
            else { Image(systemName: "figure.run").foregroundStyle(card.color) }
        }.frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func settingsCard<Content: View>(_ title: String, _ symbol: String, _ tint: Color, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol).font(.headline).foregroundStyle(tint)
            content()
        }.padding(16).frame(maxWidth: .infinity, alignment: .topLeading).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 17))
    }

    private func sectionTitle(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 3) { Text(title).font(.title3.bold()); Text(subtitle).font(.caption).foregroundStyle(.secondary) }
    }

    private func labeledField(_ title: String, text: Binding<String>, axis: Axis = .horizontal) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            TextField(title, text: text, axis: axis).textFieldStyle(.roundedBorder).lineLimit(axis == .vertical ? 2...4 : 1...1)
        }
    }

    private func integerStepper(_ title: String, value: Binding<Int>, range: ClosedRange<Int>, step: Int, suffix: String) -> some View {
        Stepper(value: value, in: range, step: step) {
            HStack { Text(title); Spacer(); Text("\(value.wrappedValue)\(suffix.isEmpty ? "" : " \(suffix)")").foregroundStyle(.secondary) }
        }
    }

    private func statPill(_ title: String, _ value: String, _ symbol: String, _ color: Color) -> some View {
        HStack(spacing: 8) { Image(systemName: symbol).foregroundStyle(color); VStack(alignment: .leading) { Text(value).fontWeight(.bold); Text(title).font(.caption2).foregroundStyle(.secondary) } }
            .padding(.horizontal, 12).padding(.vertical, 9).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }

    private var availableArtwork: [String] {
        let roots = [projectRoot.appendingPathComponent("custom_textures"), projectRoot.appendingPathComponent("custom_backgrounds")]
        let supported = Set(["png", "jpg", "jpeg", "bmp", "gif", "tif", "tiff", "webp"])
        return roots.flatMap { root -> [String] in
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return [] }
            return enumerator.compactMap { $0 as? URL }.filter { supported.contains($0.pathExtension.lowercased()) }.map(\.lastPathComponent)
        }.uniqued().sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func artwork(for name: String) -> NSImage? {
        guard !name.isEmpty else { return nil }
        for folder in ["custom_textures", "custom_backgrounds"] {
            let root = projectRoot.appendingPathComponent(folder)
            if let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil),
               let match = enumerator.compactMap({ $0 as? URL }).first(where: { $0.lastPathComponent.caseInsensitiveCompare(name) == .orderedSame }) {
                return NSImage(contentsOf: match)
            }
        }
        return nil
    }

    private func reload(selecting preferred: String? = nil) {
        cards = (CommerceCard.load(from: projectRoot.appendingPathComponent("custom_tricks"))
            + CommerceCard.load(from: projectRoot.appendingPathComponent("custom_upgrades")))
            .reduce(into: [String: CommerceCard]()) { $0[$1.cardName.lowercased()] = $1 }.map(\.value)
            .sorted { $0.visualName.localizedCaseInsensitiveCompare($1.visualName) == .orderedAscending }
        let wanted = preferred ?? selectedID
        selectedID = cards.contains(where: { $0.id == wanted }) ? wanted : cards.first?.id
    }

    private func save(_ card: CommerceCard) {
        do {
            try card.write()
            onStatus("Saved \(card.visualName)'s shop card and \(card.maxLevel)-level upgrade path.")
            withAnimation { savedPulse = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { withAnimation { savedPulse = false } }
            reload(selecting: card.id)
        } catch { onStatus("Could not save card: \(error.localizedDescription)") }
    }

    private func deleteSelectedCard() {
        guard let index = selectedIndex else { return }
        let card = cards[index]
        let tricksRoot = projectRoot.appendingPathComponent("custom_tricks", isDirectory: true).standardizedFileURL
        let upgradesRoot = projectRoot.appendingPathComponent("custom_upgrades", isDirectory: true).standardizedFileURL
        let package = card.manifest.deletingLastPathComponent().standardizedFileURL
        let target = package == tricksRoot || package == upgradesRoot ? card.manifest : package
        guard target.path.hasPrefix(projectRoot.standardizedFileURL.path + "/") else {
            onStatus("Delete stopped because the card package is outside this project.")
            return
        }
        do {
            try FileManager.default.removeItem(at: target)
            selectedID = nil
            reload()
            onStatus("Deleted \(card.visualName). Install Changes removes its old Vector 2 copy.")
        } catch {
            reload(selecting: card.id)
            onStatus("Could not delete \(card.visualName): \(error.localizedDescription)")
        }
    }
}

struct CommerceLevel: Equatable {
    var number: Int
    var cards: Int
    var points: Int
    var properties: [CommerceProperty]
}

struct CommerceProperty: Equatable {
    var name: String
    var value: String
}

struct CommerceCard: Identifiable, Equatable {
    let id: String
    let manifest: URL
    var cardName: String
    var visualName: String
    var description: String
    var image: String
    var rarity: Int
    var price: Int
    var shopEnabled: Bool
    var group: String
    var setupMin: Int
    var setupMax: Int
    var weight: Int
    var effectID: String
    var slot: String
    var cardType: String
    var category: String
    var maxLevel: Int
    var levels: [CommerceLevel]

    var propertyKeys: [String] { levels.flatMap(\.properties).map(\.name).uniqued() }

    var rarityName: String { rarity >= 3 ? "Epic" : rarity == 2 ? "Rare" : "Common" }
    var color: Color { rarity >= 3 ? .red : rarity == 2 ? .orange : .cyan }

    static func load(from root: URL) -> [CommerceCard] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return [] }
        let manifests = enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension.lowercased() == "xml" }
        var cards: [CommerceCard] = []
        for manifest in manifests {
            if let card = load(manifest) { cards.append(card) }
        }
        return cards.sorted { $0.visualName.localizedCaseInsensitiveCompare($1.visualName) == .orderedAscending }
    }

    private static func load(_ url: URL) -> CommerceCard? {
        guard let document = try? XMLDocument(contentsOf: url), let root = document.rootElement(), ["CustomTrick", "CustomCard"].contains(root.name ?? "") else { return nil }
        func text(_ name: String, _ fallback: String) -> String { root.attribute(forName: name)?.stringValue?.nilIfBlank ?? fallback }
        func integer(_ name: String, _ fallback: Int) -> Int { Int(text(name, "\(fallback)")) ?? fallback }
        let trickName = text("Name", url.deletingLastPathComponent().lastPathComponent)
        let cardName = text("CardName", trickName + "_1")
        let maxLevel = min(10, max(1, integer("MaxLevel", 5)))
        let defaults = [(2, 100), (3, 120), (5, 145), (7, 175), (9, 210), (12, 250), (15, 300), (19, 360), (24, 430), (30, 510)]
        let parsedLevels = root.elements(forName: "Level").compactMap { node -> (Int, CommerceLevel)? in
            guard let number = Int(node.attribute(forName: "Number")?.stringValue ?? ""), (1...10).contains(number) else { return nil }
            let reserved = Set(["number", "cards", "points"])
            let properties = (node.attributes ?? []).compactMap { attribute -> CommerceProperty? in
                guard let name = attribute.name, !reserved.contains(name.lowercased()) else { return nil }
                return CommerceProperty(name: name, value: attribute.stringValue ?? "")
            }
            return (number, CommerceLevel(number: number, cards: max(1, Int(node.attribute(forName: "Cards")?.stringValue ?? "") ?? defaults[min(number - 1, defaults.count - 1)].0), points: max(0, Int(node.attribute(forName: "Points")?.stringValue ?? "") ?? defaults[min(number - 1, defaults.count - 1)].1), properties: properties))
        }
        let parsed = parsedLevels.reduce(into: [Int: CommerceLevel]()) { result, entry in
            result[entry.0] = entry.1
        }
        let knownKeys = parsed.values.flatMap(\.properties).map(\.name).uniqued()
        let levels = (1...10).map { number -> CommerceLevel in
            if var level = parsed[number] {
                for key in knownKeys where !level.properties.contains(where: { $0.name.caseInsensitiveCompare(key) == .orderedSame }) {
                    level.properties.append(CommerceProperty(name: key, value: "0"))
                }
                return level
            }
            return CommerceLevel(number: number, cards: defaults[number - 1].0, points: defaults[number - 1].1, properties: knownKeys.map { CommerceProperty(name: $0, value: "0") })
        }
        let cardType = text("CardType", root.name == "CustomTrick" ? "Stunts" : "Passive")
        let storedEffect = text("EffectID", cardType)
        let effectID = storedEffect == "RegenerateCharges" ? "None" : storedEffect
        return CommerceCard(id: url.path, manifest: url, cardName: cardName, visualName: text("VisualName", trickName), description: text("Description", "Custom card: \(trickName)"), image: text("Image", ""), rarity: min(3, max(1, integer("Rarity", 1))), price: max(0, integer("Price", 1100)), shopEnabled: text("ShopEnabled", "1") != "0", group: text("Group", root.name == "CustomTrick" ? "CustomTricks" : "CustomCards"), setupMin: max(0, integer("SetupMin", 0)), setupMax: max(0, integer("SetupMax", 99)), weight: max(1, integer("Weight", 1250)), effectID: effectID, slot: text("Slot", cardType), cardType: cardType, category: text("Category", cardType == "Notes" ? cardName.split(separator: "_").first.map(String.init) ?? "Notes" : cardType), maxLevel: maxLevel, levels: levels)
    }

    func write() throws {
        let document = try XMLDocument(contentsOf: manifest)
        guard let root = document.rootElement(), ["CustomTrick", "CustomCard"].contains(root.name ?? "") else { throw CocoaError(.fileReadCorruptFile) }
        let values = ["CardName": cardName, "VisualName": visualName, "Description": description, "Image": image, "Rarity": "\(rarity)", "Price": "\(price)", "ShopEnabled": shopEnabled ? "1" : "0", "Group": group, "SetupMin": "\(setupMin)", "SetupMax": "\(max(setupMin, setupMax))", "Weight": "\(weight)", "WeightForUse": "1", "CardType": cardType, "Category": category, "EffectID": effectID, "Slot": slot, "MaxLevel": "\(maxLevel)"]
        for (name, value) in values {
            if let attribute = root.attribute(forName: name) { attribute.stringValue = value }
            else { root.addAttribute(XMLNode.attribute(withName: name, stringValue: value) as! XMLNode) }
        }
        for node in root.elements(forName: "Level") { node.detach() }
        for level in levels.prefix(maxLevel) {
            let node = XMLElement(name: "Level")
            ["Number": "\(level.number)", "Cards": "\(level.cards)", "Points": "\(level.points)"].forEach { node.addAttribute(XMLNode.attribute(withName: $0.key, stringValue: $0.value) as! XMLNode) }
            for property in level.properties where !property.name.isEmpty {
                node.addAttribute(XMLNode.attribute(withName: property.name, stringValue: property.value) as! XMLNode)
            }
            root.addChild(node)
        }
        document.version = "1.0"; document.characterEncoding = "utf-8"
        try document.xmlData(options: [.nodePrettyPrint]).write(to: manifest, options: .atomic)
    }
}

private extension String {
    var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
