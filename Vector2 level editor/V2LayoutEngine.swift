//
//  V2LayoutEngine.swift
//  Vector2 level editor
//
//  Game-faithful room layout helpers for RoomWeaver.
//  This intentionally does not call or mutate RuntimeGraph/XMLSceneParser.
//

import Foundation

enum V2LayoutEngine {
    typealias ChoiceMap = [String: String]

    static func choiceOptions(in rootElement: XMLElement) -> [RoomWeaverChoiceOption] {
        guard let selection = selectionElement(in: rootElement) else {
            return []
        }

        var options: [RoomWeaverChoiceOption] = []
        for choice in childElements(of: selection) where choice.name == "Choice" {
            appendChoiceOptions(from: choice, parentPath: nil, into: &options)
        }
        return options
    }

    static func roomChoiceMap(in rootElement: XMLElement, roomName: String, selectedVariants: ChoiceMap) -> ChoiceMap {
        guard let selection = selectionElement(in: rootElement) else {
            return [:]
        }

        var choices: ChoiceMap = [:]
        choices["__RoomName"] = roomName
        for choice in childElements(of: selection) where choice.name == "Choice" {
            chooseVariant(from: choice, roomName: roomName, parentPath: nil, selectedVariants: selectedVariants, into: &choices)
        }
        return choices
    }

    static func shouldIncludeElement(_ element: XMLElement, choices: ChoiceMap) -> Bool {
        guard attribute("Phantom", on: element) != "1" else {
            return false
        }
        guard isEnabled(element) else {
            return false
        }
        return checkSelection(in: firstElement(fromXPath: "./Properties/Static", on: element), choices: choices)
    }

    private static func appendChoiceOptions(from choice: XMLElement, parentPath: String?, into options: inout [RoomWeaverChoiceOption]) {
        guard let choiceName = attribute("Name", on: choice), !choiceName.isEmpty else {
            return
        }

        let variants = childElements(of: choice).filter { $0.name == "Variant" }
        let variantNames = variants.compactMap { attribute("Name", on: $0) }.filter { !$0.isEmpty }
        guard !variantNames.isEmpty else { return }

        let qualifiedChoice = parentPath.map { "\($0)/\(choiceName)" } ?? choiceName
        let label = parentPath.map { "\($0) / \(choiceName)" } ?? choiceName
        options.append(.init(
            id: qualifiedChoice,
            name: label,
            description: choiceDescription(for: choiceName, parentPath: parentPath),
            variants: variantNames
        ))

        for variant in variants {
            guard let variantName = attribute("Name", on: variant), !variantName.isEmpty else {
                continue
            }
            let nestedParentPath = parentPath.map { "\($0).\(variantName)" } ?? "\(choiceName).\(variantName)"
            for nestedChoice in childElements(of: variant) where nestedChoice.name == "Choice" {
                appendChoiceOptions(from: nestedChoice, parentPath: nestedParentPath, into: &options)
            }
        }
    }

    private static func chooseVariant(
        from choice: XMLElement,
        roomName: String,
        parentPath: String?,
        selectedVariants: ChoiceMap,
        into choices: inout ChoiceMap
    ) {
        guard let choiceName = attribute("Name", on: choice), !choiceName.isEmpty else {
            return
        }

        let qualifiedChoice = parentPath.map { "\($0)/\(choiceName)" } ?? choiceName
        let prefixedChoice = "\(roomName)_\(qualifiedChoice)"
        let variants = childElements(of: choice).filter { $0.name == "Variant" }
        guard let variant = selectedVariant(
            for: choiceName,
            qualifiedChoice: qualifiedChoice,
            prefixedChoice: prefixedChoice,
            variants: variants,
            selectedVariants: selectedVariants
        ),
              let variantName = attribute("Name", on: variant),
              !variantName.isEmpty else {
            return
        }

        if parentPath == nil {
            choices[choiceName] = variantName
        }
        choices[qualifiedChoice] = variantName
        choices[prefixedChoice] = variantName

        let nestedParentPath = parentPath.map { "\($0).\(variantName)" } ?? "\(choiceName).\(variantName)"
        for nestedChoice in childElements(of: variant) where nestedChoice.name == "Choice" {
            chooseVariant(
                from: nestedChoice,
                roomName: roomName,
                parentPath: nestedParentPath,
                selectedVariants: selectedVariants,
                into: &choices
            )
        }
    }

    private static func selectedVariant(
        for choiceName: String,
        qualifiedChoice: String,
        prefixedChoice: String,
        variants: [XMLElement],
        selectedVariants: ChoiceMap
    ) -> XMLElement? {
        let requested = selectedVariants[prefixedChoice]
            ?? selectedVariants[qualifiedChoice]
            ?? selectedVariants[choiceName]
        if let requested {
            return variants.first { attribute("Name", on: $0) == requested } ?? variants.first
        }
        return variants.first
    }

    private static func checkSelection(in staticProperties: XMLElement?, choices: ChoiceMap) -> Bool {
        guard let staticProperties else { return true }
        var result = true
        for child in childElements(of: staticProperties) where child.name == "Selection" {
            guard let choice = attribute("Choice", on: child),
                  let variant = attribute("Variant", on: child) else {
                continue
            }
            let parent = attribute("Parent", on: child)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let candidates = selectionChoiceCandidates(choice: choice, parent: parent, choices: choices)
            if candidates.contains(where: { choices[$0] == variant }) {
                return true
            }
            if candidates.contains(where: { choices[$0] != nil }) {
                result = false
                continue
            }
            result = false
        }
        return result
    }

    private static func selectionChoiceCandidates(choice: String, parent: String, choices: ChoiceMap) -> [String] {
        var candidates: [String] = []
        func append(_ value: String) {
            guard !value.isEmpty, !candidates.contains(value) else { return }
            candidates.append(value)
        }

        let exactChoice = parent.isEmpty ? choice : "\(parent)/\(choice)"
        append(exactChoice)
        if parent.isEmpty {
            append(choice)
        }
        if let roomName = choices["__RoomName"], !roomName.isEmpty {
            append("\(roomName)_\(exactChoice)")
        }
        return candidates
    }

    private static func choiceDescription(for choiceName: String, parentPath: String?) -> String {
        let lower = choiceName.lowercased()
        if let parentPath {
            return "Only appears if this earlier pick is active: \(parentPath)."
        }
        if lower.contains("start") {
            return "The first playable chunk near the spawn."
        }
        if lower.contains("middle") {
            return "The middle playable chunk. Top/bottom means upper or lower route."
        }
        if lower.contains("finish") {
            return "The final playable chunk near the exit."
        }
        if lower.contains("wall") {
            return "Background wall art around the playable path."
        }
        if lower.contains("trap") || lower.contains("cosmetic") {
            return "Extra hazard/deco pieces attached to the room."
        }
        if lower.contains("zone") {
            return "A room segment choice used by Vector 2's generator."
        }
        return "A Vector 2 room choice. Pick the variant you want to preview."
    }

    private static func isEnabled(_ element: XMLElement) -> Bool {
        guard let enable = firstElement(fromXPath: "./Properties/Static/Enable", on: element),
              let raw = attribute("Value", on: enable)?.lowercased() else {
            return true
        }
        return !(raw == "0" || raw == "false")
    }

    private static func selectionElement(in rootElement: XMLElement) -> XMLElement? {
        firstElement(fromXPath: "./Track/Properties/Selection", on: rootElement)
            ?? firstElement(fromXPath: "./Properties/Selection", on: rootElement)
    }

    private static func childElements(of element: XMLElement) -> [XMLElement] {
        (element.children ?? []).compactMap { $0 as? XMLElement }
    }

    private static func firstElement(fromXPath xpath: String, on element: XMLElement) -> XMLElement? {
        (try? element.nodes(forXPath: xpath).first) as? XMLElement
    }

    private static func attribute(_ name: String, on element: XMLElement) -> String? {
        element.attribute(forName: name)?.stringValue
    }
}
