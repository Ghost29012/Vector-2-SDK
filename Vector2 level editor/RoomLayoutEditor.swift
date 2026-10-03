//
//  RoomLayoutEditor.swift
//  Vector2 level editor
//
//  Start, Middle and Finish layouts map to Vector 2 Choice/Variant values.
//  Bounds only show the layout; hierarchy membership decides what belongs to it.
//

import Foundation
import SwiftUI

enum RoomLayoutSection: String, CaseIterable, Hashable, Identifiable {
    case start = "Start"
    case middle = "Middle"
    case finish = "Finish"
    case dynamic = "Dynamic"

    // Dynamic remains parse/export compatible for older editor-authored rooms,
    // but it is object-level scene behaviour—not a fourth generated route.
    static let authoringCases: [RoomLayoutSection] = [.start, .middle, .finish]

    var id: String { rawValue }
    var choiceName: String {
        switch self {
        case .dynamic: return "Dynamic"
        default: return "\(rawValue)_Zone"
        }
    }
    var color: Color {
        switch self {
        case .start: return .blue
        case .middle: return .orange
        case .finish: return .green
        case .dynamic: return .purple
        }
    }
    var icon: String {
        switch self {
        case .start: return "rectangle.leadinghalf.inset.filled"
        case .middle: return "rectangle.center.inset.filled"
        case .finish: return "rectangle.trailinghalf.inset.filled"
        case .dynamic: return "waveform.path.ecg.rectangle"
        }
    }

    static func matching(choice: String) -> RoomLayoutSection? {
        let folded = choice.lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        switch folded {
        case "start", "start zone": return .start
        case "middle", "middle zone": return .middle
        case "finish", "finish zone": return .finish
        case "dynamic", "dynamic zone": return .dynamic
        default: return nil
        }
    }
}

struct RoomLayoutKey: Hashable, Identifiable {
    var section: RoomLayoutSection
    var variant: String
    var id: String { "\(section.rawValue)|\(variant)" }
    var displayName: String {
        variant.replacingOccurrences(of: "_", with: " ")
    }
}

struct RoomLayoutOption: Identifiable, Equatable {
    var key: RoomLayoutKey
    var nodeIDs: [LevelNode.ID]
    var id: String { key.id }
}

struct RoomLayoutBounds: Identifiable {
    var section: RoomLayoutSection
    var variant: String
    var transform: LevelNode.Transform
    var id: String { "\(section.rawValue)|\(variant)" }
    var displayName: String { variant.replacingOccurrences(of: "_", with: " ") }
}

extension LevelDocument {
    private func roomLayoutSelectionRules(for node: LevelNode) -> [LevelNode.XMLSummary.SelectionRule] {
        var rules: [LevelNode.XMLSummary.SelectionRule] = []
        if !node.xml.choice.isEmpty, !node.xml.variant.isEmpty {
            rules.append(.init(choice: node.xml.choice, variant: node.xml.variant, parentChoice: node.xml.parentChoice))
        }
        rules.append(contentsOf: node.xml.additionalSelections)
        return rules.filter { RoomLayoutSection.matching(choice: $0.choice) != nil }
    }

    private func roomLayoutKey(for rule: LevelNode.XMLSummary.SelectionRule) -> RoomLayoutKey? {
        guard let section = RoomLayoutSection.matching(choice: rule.choice), !rule.variant.isEmpty else { return nil }
        return RoomLayoutKey(section: section, variant: rule.variant)
    }

    /// Vector stores the room-wide choice catalogue inside Track/Properties.
    /// Individual objects then point at one of these choices with their own
    /// Selection guard. Keep both halves in one room file so Save, Play and a
    /// manually copied XML all behave exactly the same.
    func exportedRoomLayoutSelectionElement() -> XMLElement? {
        guard !roomLayoutOptions.isEmpty else { return nil }
        let selection = XMLElement(name: "Selection")
        let roots = roomLayoutOptions.filter { roomLayoutParents[$0.key] == nil }
        for section in RoomLayoutSection.allCases {
            let options = roots.filter { $0.key.section == section }
            if let choice = exportedRoomLayoutChoice(section: section, options: options) {
                selection.addChild(choice)
            }
        }
        return selection.childCount == 0 ? nil : selection
    }

    private func exportedRoomLayoutChoice(section: RoomLayoutSection, options: [RoomLayoutOption]) -> XMLElement? {
        guard !options.isEmpty else { return nil }
        let choice = XMLElement(name: "Choice")
        choice.addAttribute(XMLNode.attribute(withName: "Name", stringValue: section.choiceName) as! XMLNode)
        for option in options {
            let variant = XMLElement(name: "Variant")
            variant.addAttribute(XMLNode.attribute(withName: "Name", stringValue: option.key.variant) as! XMLNode)
            let children = roomLayoutOptions.filter { roomLayoutParents[$0.key] == option.key }
            for childSection in RoomLayoutSection.allCases {
                let childOptions = children.filter { $0.key.section == childSection }
                if let childChoice = exportedRoomLayoutChoice(section: childSection, options: childOptions) {
                    variant.addChild(childChoice)
                }
            }
            choice.addChild(variant)
        }
        return choice
    }

    var roomLayoutOptions: [RoomLayoutOption] {
        var grouped: [RoomLayoutKey: [LevelNode.ID]] = [:]
        for node in root.allDescendantsIncludingSelf() {
            for rule in roomLayoutSelectionRules(for: node) {
                guard let key = roomLayoutKey(for: rule) else { continue }
                grouped[key, default: []].append(node.id)
            }
        }
        return grouped.map { RoomLayoutOption(key: $0.key, nodeIDs: $0.value) }
            .sorted {
                let lhsSection = RoomLayoutSection.allCases.firstIndex(of: $0.key.section) ?? 0
                let rhsSection = RoomLayoutSection.allCases.firstIndex(of: $1.key.section) ?? 0
                return lhsSection == rhsSection
                    ? $0.key.variant.localizedStandardCompare($1.key.variant) == .orderedAscending
                    : lhsSection < rhsSection
            }
    }

    func roomLayoutOptions(in section: RoomLayoutSection) -> [RoomLayoutOption] {
        roomLayoutOptions.filter { $0.key.section == section }
    }

    mutating func prepareRoomLayouts() {
        restoreRoomLayoutParentsFromNodes()
        normalizeRoomLayoutSectionScopes()
        for section in RoomLayoutSection.allCases where activeRoomLayoutVariants[section] == nil {
            if let first = roomLayoutOptions(in: section).first {
                activeRoomLayoutVariants[section] = first.key.variant
            }
        }
        if editingRoomLayout == nil {
            editingRoomLayout = RoomLayoutSection.authoringCases.compactMap { section in
                activeRoomLayoutVariants[section].map { RoomLayoutKey(section: section, variant: $0) }
            }.first
        }
    }

    mutating func createRoomLayout(section: RoomLayoutSection, name rawName: String) -> String? {
        let name = safeVariantName(rawName)
        guard !name.isEmpty else { return "Give this layout a name first." }
        guard !effectiveSelectedNodeIDs.isEmpty else { return "Select the objects that belong to this layout first." }
        if roomLayoutOptions(in: section).contains(where: { $0.key.variant.caseInsensitiveCompare(name) == .orderedSame }) {
            let displayName = RoomLayoutKey(section: section, variant: name).displayName
            return "A \(section.rawValue.lowercased()) layout named \(displayName) already exists."
        }
        assignSelectedNodes(to: RoomLayoutKey(section: section, variant: name))
        return nil
    }

    mutating func assignSelectedNodes(to key: RoomLayoutKey) {
        let ids = effectiveSelectedNodeIDs
        guard !ids.isEmpty else { return }
        // Work this out before mutating root. Reading self again from inside
        // root.update overlaps Swift's exclusive write access to the document.
        let parentPath = roomLayoutParentPath(for: key)
        for id in ids {
            root.update(id: id) { node in
                node.xml.choice = key.section.choiceName
                node.xml.variant = key.variant
                node.xml.parentChoice = parentPath
                node.xml.additionalSelections = []
            }
        }
        activeRoomLayoutVariants[key.section] = key.variant
        editingRoomLayout = key
    }

    mutating func applyEditingRoomLayoutToSelection() {
        guard let editingRoomLayout else { return }
        assignSelectedNodes(to: editingRoomLayout)
    }

    mutating func activateRoomLayout(_ option: RoomLayoutOption) {
        activeRoomLayoutVariants[option.key.section] = option.key.variant
        activateRoomLayoutAncestors(of: option.key)
        editingRoomLayout = option.key
        setSelected(ids: option.nodeIDs)
    }

    mutating func makeSelectionShared() {
        for id in effectiveSelectedNodeIDs {
            root.update(id: id) { node in
                Self.clearRoomLayoutSelections(from: &node)
            }
        }
    }

    var selectedSharedObjectsGroup: LevelNode? {
        guard let node = selectedNode,
              node.kind == .object,
              node.metadata.visualType == "RoomLayoutSharedGroup" else { return nil }
        return node
    }

    mutating func createSharedObjectsGroup() -> String? {
        let ids = Set(movableSelectedNodeIDs)
        guard !ids.isEmpty else { return "Select the objects you want to share first." }
        guard !ids.contains(where: { root.find(id: $0)?.metadata.visualType == "RoomLayoutSharedGroup" }) else {
            return "That selection already contains a Shared Objects group."
        }
        guard let bounds = selectedBounds() else { return "The selected objects do not have visible bounds." }

        var rules: [LevelNode.XMLSummary.SelectionRule] = []
        for id in ids {
            guard let node = root.find(id: id) else { continue }
            for rule in roomLayoutSelectionRules(for: node) where !rules.contains(rule) {
                rules.append(rule)
            }
        }
        if rules.isEmpty, let current = currentRoomLayoutKey() {
            rules = [selectionRule(for: current)]
        }

        var extracted: [LevelNode] = []
        root.extract(ids: ids, into: &extracted)
        guard !extracted.isEmpty else { return "Those objects could not be grouped." }
        extracted = extracted.map { source in
            var node = source
            Self.clearRoomLayoutSelections(from: &node)
            node.markHierarchyAttachment(false)
            return node
        }

        let existingNames = Set(root.allDescendantsIncludingSelf().map(\.name))
        var name = "Shared Objects"
        var suffix = 2
        while existingNames.contains(name) {
            name = "Shared Objects \(suffix)"
            suffix += 1
        }
        var xml = LevelNode.XMLSummary(template: "Object")
        Self.setSelectionRules(rules, on: &xml)
        var metadata = LevelNode.Metadata()
        metadata.tag = "Object"
        metadata.visualType = "RoomLayoutSharedGroup"
        metadata.sourceAttributes["EditorSharedObjects"] = "1"
        metadata.sourceAttributes["EditorSharedWidth"] = "\(bounds.width)"
        metadata.sourceAttributes["EditorSharedHeight"] = "\(bounds.height)"
        let group = LevelNode(
            name: name,
            kind: .object,
            factor: "1",
            transform: .init(
                x: bounds.x + bounds.width / 2,
                y: bounds.y + bounds.height / 2,
                width: bounds.width,
                height: bounds.height
            ),
            xml: xml,
            metadata: metadata,
            children: extracted
        )
        guard root.appendToFirstFactor(group) else {
            for child in extracted { _ = root.appendToFirstFactor(child) }
            return "The room has no scene container for this group."
        }
        selectedNodeID = group.id
        selectedNodeIDs = [group.id]
        return nil
    }

    mutating func ungroupSharedObjects(_ groupID: LevelNode.ID) -> Bool {
        guard let group = root.find(id: groupID),
              group.metadata.visualType == "RoomLayoutSharedGroup" else { return false }
        let rules = roomLayoutSelectionRules(for: group)
        var extracted: [LevelNode] = []
        root.extract(ids: [groupID], into: &extracted)
        guard let removed = extracted.first else { return false }
        var restoredIDs: [LevelNode.ID] = []
        for source in removed.children {
            var child = source
            Self.setSelectionRules(rules, on: &child.xml)
            child.markHierarchyAttachment(false)
            guard root.appendToFirstFactor(child) else { continue }
            restoredIDs.append(child.id)
        }
        setSelected(ids: restoredIDs)
        return !restoredIDs.isEmpty
    }

    func sharedGroupRouteKeys(_ group: LevelNode) -> Set<RoomLayoutKey> {
        Set(roomLayoutSelectionRules(for: group).compactMap { roomLayoutKey(for: $0) })
    }

    mutating func setSharedGroup(_ groupID: LevelNode.ID, appearsIn keys: Set<RoomLayoutKey>) {
        let rules = keys.sorted { $0.id < $1.id }.map { selectionRule(for: $0) }
        root.update(id: groupID) { node in Self.setSelectionRules(rules, on: &node.xml) }
    }

    mutating func setSharedGroupToCurrentRoute(_ groupID: LevelNode.ID) -> Bool {
        guard let key = currentRoomLayoutKey() else { return false }
        setSharedGroup(groupID, appearsIn: [key])
        return true
    }

    func roomLayoutOpacity(for node: LevelNode, guidesVisible: Bool) -> Double {
        guard guidesVisible else { return 1 }
        let keys = roomLayoutSelectionRules(for: node).compactMap { roomLayoutKey(for: $0) }
        guard !keys.isEmpty else { return 1 }
        if keys.contains(where: { roomLayoutIsActive($0) }) { return 1 }
        return ghostInactiveRoomLayouts ? 0.16 : 0
    }

    private func roomLayoutIsActive(_ key: RoomLayoutKey) -> Bool {
        guard activeRoomLayoutVariants[key.section]?.caseInsensitiveCompare(key.variant) == .orderedSame else { return false }
        guard let parent = roomLayoutParents[key] else { return true }
        return roomLayoutIsActive(parent)
    }

    func roomLayoutIsInteractable(_ node: LevelNode, guidesVisible: Bool) -> Bool {
        roomLayoutOpacity(for: node, guidesVisible: guidesVisible) >= 0.99
    }

    var activeRoomLayoutBounds: [RoomLayoutBounds] {
        RoomLayoutSection.authoringCases.compactMap { section in
            guard let variant = activeRoomLayoutVariants[section] else { return nil }
            let nodes = root.allDescendantsIncludingSelf().filter {
                RoomLayoutSection.matching(choice: $0.xml.choice) == section &&
                    $0.xml.variant.caseInsensitiveCompare(variant) == .orderedSame
            }
            var rects: [CGRect] = []
            for node in nodes {
                if let rect = Self.roomLayoutRect(for: node) {
                    rects.append(rect)
                }
            }
            guard let first = rects.first else { return nil }
            let union = rects.dropFirst().reduce(first) { $0.union($1) }
            return RoomLayoutBounds(
                section: section,
                variant: variant,
                transform: .init(
                    x: Int(union.minX.rounded()), y: Int(union.minY.rounded()),
                    width: max(1, Int(union.width.rounded())), height: max(1, Int(union.height.rounded()))
                )
            )
        }
    }

    var roomLayoutCombinationCount: Int {
        let roots = roomLayoutOptions.filter { roomLayoutParents[$0.key] == nil }
        let grouped = Dictionary(grouping: roots, by: { $0.key.section })
        return RoomLayoutSection.authoringCases.reduce(1) { total, section in
            let count = grouped[section]?.reduce(0) { $0 + roomLayoutBranchCount(from: $1.key) } ?? 1
            return total * max(1, count)
        }
    }

    var roomLayoutIssues: [String] {
        var issues: [String] = []
        for option in roomLayoutOptions {
            let nodes = option.nodeIDs.compactMap { node(for: $0) }
            if option.key.section == .start && !nodes.contains(where: { $0.kind == .gateIn }) {
                issues.append("\(option.key.displayName) needs an entrance gate")
            }
            if option.key.section == .finish && !nodes.contains(where: { $0.kind == .gateOut }) {
                issues.append("\(option.key.displayName) needs an exit gate")
            }
            if let parent = roomLayoutParents[option.key], !roomLayoutOptions.contains(where: { $0.key == parent }) {
                issues.append("\(option.key.displayName) is linked to a layout that no longer exists")
            }
        }
        for section in RoomLayoutSection.authoringCases {
            let options = roomLayoutOptions(in: section)
            guard options.count > 1 else { continue }
            let optionBounds: [(RoomLayoutOption, CGRect)] = options.compactMap { option in
                let rects = option.nodeIDs.compactMap { node(for: $0) }.compactMap { Self.roomLayoutRect(for: $0) }
                guard let first = rects.first else { return nil }
                return (option, rects.dropFirst().reduce(first) { $0.union($1) })
            }
            for node in root.allDescendantsIncludingSelf() where node.xml.choice.isEmpty && Self.canKillPlayerIfShared(node) {
                guard let rect = Self.roomLayoutRect(for: node) else { continue }
                let overlapping = optionBounds.filter { $0.1.intersects(rect) }
                guard !overlapping.isEmpty, overlapping.count < optionBounds.count else { continue }
                let names = overlapping.map { $0.0.key.displayName }.joined(separator: ", ")
                issues.append("\(node.name) at \(node.transform?.x ?? 0), \(node.transform?.y ?? 0) is Shared but only overlaps \(names)")
            }
        }
        return issues
    }

    func roomLayoutParentPath(for key: RoomLayoutKey) -> String {
        var ancestors: [RoomLayoutKey] = []
        var current = roomLayoutParents[key]
        var visited: Set<RoomLayoutKey> = []
        while let parent = current, visited.insert(parent).inserted {
            ancestors.insert(parent, at: 0)
            current = roomLayoutParents[parent]
        }
        return ancestors.map { "\($0.section.choiceName).\($0.variant)" }.joined(separator: "/")
    }

    mutating func setRoomLayoutParent(_ parent: RoomLayoutKey?, for child: RoomLayoutKey) {
        guard parent != child else { return }
        let sectionKeys = roomLayoutOptions(in: child.section).map(\.key)
        if let parent {
            // Vector selects every root Choice independently. Leaving one Middle
            // card at the root while another Middle card is nested would render
            // one variant from both choices. Once a section is linked, move its
            // still-independent siblings into that same route as a safe default.
            roomLayoutParents[child] = parent
            for key in sectionKeys where roomLayoutParents[key] == nil {
                roomLayoutParents[key] = parent
            }
        } else {
            // “Any” is a section-level mode. Keeping every sibling at the same
            // scope preserves one exclusive Vector Choice with several variants.
            for key in sectionKeys { roomLayoutParents.removeValue(forKey: key) }
        }
        for key in sectionKeys { refreshRoomLayoutParentPaths(startingAt: key) }
        activateRoomLayoutAncestors(of: child)
    }

    func roomLayoutParent(for key: RoomLayoutKey) -> RoomLayoutKey? {
        roomLayoutParents[key]
    }

    private func roomLayoutBranchCount(from key: RoomLayoutKey) -> Int {
        let children = roomLayoutOptions.filter { roomLayoutParents[$0.key] == key }
        let grouped = Dictionary(grouping: children, by: { $0.key.section })
        return grouped.values.reduce(1) { total, options in
            total * max(1, options.reduce(0) { $0 + roomLayoutBranchCount(from: $1.key) })
        }
    }

    private mutating func restoreRoomLayoutParentsFromNodes() {
        guard roomLayoutParents.isEmpty else { return }
        let options = roomLayoutOptions
        for option in options {
            guard let node = option.nodeIDs.compactMap({ node(for: $0) }).first else { continue }
            guard let rule = roomLayoutSelectionRules(for: node).first(where: { roomLayoutKey(for: $0) == option.key }) else { continue }
            let last = rule.parentChoice.split(separator: "/").last.map(String.init) ?? ""
            guard let dot = last.firstIndex(of: ".") else { continue }
            let choice = String(last[..<dot])
            let variant = String(last[last.index(after: dot)...])
            guard let section = RoomLayoutSection.matching(choice: choice) else { continue }
            let parent = RoomLayoutKey(section: section, variant: variant)
            if options.contains(where: { $0.key == parent }) { roomLayoutParents[option.key] = parent }
        }
    }

    private mutating func normalizeRoomLayoutSectionScopes() {
        for section in RoomLayoutSection.allCases {
            let keys = roomLayoutOptions(in: section).map(\.key)
            guard let fallbackParent = keys.compactMap({ roomLayoutParents[$0] }).first else { continue }
            for key in keys where roomLayoutParents[key] == nil {
                roomLayoutParents[key] = fallbackParent
            }
            for key in keys { refreshRoomLayoutParentPaths(startingAt: key) }
        }
    }

    private mutating func refreshRoomLayoutParentPaths(startingAt key: RoomLayoutKey) {
        let keys = [key] + roomLayoutParents.keys.filter { roomLayoutParentPath(for: $0).contains("\(key.section.choiceName).\(key.variant)") }
        for target in keys {
            let path = roomLayoutParentPath(for: target)
            for id in roomLayoutOptions.first(where: { $0.key == target })?.nodeIDs ?? [] {
                root.update(id: id) { node in
                    if RoomLayoutSection.matching(choice: node.xml.choice) == target.section,
                       node.xml.variant.caseInsensitiveCompare(target.variant) == .orderedSame {
                        node.xml.parentChoice = path
                    }
                    for index in node.xml.additionalSelections.indices {
                        let rule = node.xml.additionalSelections[index]
                        if RoomLayoutSection.matching(choice: rule.choice) == target.section,
                           rule.variant.caseInsensitiveCompare(target.variant) == .orderedSame {
                            node.xml.additionalSelections[index].parentChoice = path
                        }
                    }
                }
            }
        }
    }

    private mutating func activateRoomLayoutAncestors(of key: RoomLayoutKey) {
        var current = roomLayoutParents[key]
        var visited: Set<RoomLayoutKey> = []
        while let parent = current, visited.insert(parent).inserted {
            activeRoomLayoutVariants[parent.section] = parent.variant
            current = roomLayoutParents[parent]
        }
    }

    private static func canKillPlayerIfShared(_ node: LevelNode) -> Bool {
        switch node.kind {
        case .platform, .trapezoid, .trigger, .area, .objectReference, .dynamic:
            return true
        default:
            return false
        }
    }

    private static func roomLayoutRect(for node: LevelNode) -> CGRect? {
        guard let transform = node.transform else { return nil }
        if node.kind.usesVectorRectOrigin {
            return CGRect(x: transform.x, y: transform.y, width: max(1, transform.width), height: max(1, transform.height))
        }
        return CGRect(
            x: transform.x - transform.width / 2,
            y: transform.y - transform.height / 2,
            width: max(1, transform.width), height: max(1, transform.height)
        )
    }

    private func safeVariantName(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0 == "_" || $0 == "-" || $0.isWhitespace })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: "_")
    }

    private func currentRoomLayoutKey() -> RoomLayoutKey? {
        for section in [RoomLayoutSection.finish, .middle, .start] {
            guard let variant = activeRoomLayoutVariants[section] else { continue }
            let key = RoomLayoutKey(section: section, variant: variant)
            if roomLayoutOptions.contains(where: { $0.key == key }) && roomLayoutIsActive(key) { return key }
        }
        return editingRoomLayout
    }

    private func selectionRule(for key: RoomLayoutKey) -> LevelNode.XMLSummary.SelectionRule {
        .init(choice: key.section.choiceName, variant: key.variant, parentChoice: roomLayoutParentPath(for: key))
    }

    private static func setSelectionRules(_ rules: [LevelNode.XMLSummary.SelectionRule], on xml: inout LevelNode.XMLSummary) {
        guard let first = rules.first else {
            xml.choice = ""
            xml.variant = ""
            xml.parentChoice = ""
            xml.additionalSelections = []
            return
        }
        xml.choice = first.choice
        xml.variant = first.variant
        xml.parentChoice = first.parentChoice
        xml.additionalSelections = Array(rules.dropFirst())
    }

    private static func clearRoomLayoutSelections(from node: inout LevelNode) {
        let preserved = ([LevelNode.XMLSummary.SelectionRule(
            choice: node.xml.choice,
            variant: node.xml.variant,
            parentChoice: node.xml.parentChoice
        )] + node.xml.additionalSelections).filter {
            !$0.choice.isEmpty && !$0.variant.isEmpty && RoomLayoutSection.matching(choice: $0.choice) == nil
        }
        setSelectionRules(preserved, on: &node.xml)
        for index in node.children.indices {
            clearRoomLayoutSelections(from: &node.children[index])
        }
    }
}
