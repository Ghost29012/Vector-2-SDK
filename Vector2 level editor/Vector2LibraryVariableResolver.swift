//
//  Vector2LibraryVariableResolver.swift
//  Vector2 level editor
//
//  Vector 2 library objects are basically tiny configurable templates. This
//  file resolves their variables, expressions, overrides, and selected variants
//  before visual pieces are built. If the right object loads but the wrong
//  variant appears, this is the lane to inspect.
//
//  Unknown expressions intentionally stay unresolved. Guessing a value here can
//  make an import look believable while silently being wrong, which is worse.
//

import Foundation

extension Vector2LibraryObjectBuilder {
static func resolvedVariables(for object: XMLElement, settings: XMLElement?, choices: ChoiceMap) -> [String: String] {
    // Runtime Graph variable resolver. It handles the common Variable,
    // Constant, Expression, and OverrideVariable cases without expanding
    // every obscure converter behavior.
    if importPipeline == .convertXmlObject2 {
        return resolvedVariablesConvertXmlObject2(for: object, settings: settings)
    }

    var values: [String: String] = [:]
    var expressions: [(name: String, value: String)] = []

    if let contentVariable = firstElement(fromXPath: "./Properties/Static/ContentVariable", on: object) {
        for child in childElements(of: contentVariable) {
            guard let variableName = attribute("Name", on: child), !variableName.isEmpty else { continue }
            switch child.name {
            case "Variable", "Constant":
                let rawValue = attribute("Default", on: child) ?? attribute("Value", on: child) ?? ""
                values[variableName] = resolveExpressionValue(rawValue, values: values)
            case "Expression":
                guard let expression = attribute("Value", on: child) else { continue }
                expressions.append((name: variableName, value: expression))
            default:
                break
            }
        }
    }

    applyOverrideVariables(from: settings ?? object, choices: choices, into: &values, respectSelection: true)
    resolveExpressions(expressions, into: &values)
    applyOverrideVariables(from: settings ?? object, choices: choices, into: &values, respectSelection: true)

    return values
}

static func resolvedVariablesConvertXmlObject2(for object: XMLElement, settings: XMLElement?) -> [String: String] {
    // Experimental resolver closer to Vision's ConvertXmlObject2 model.
    // Keep separate from Runtime Graph so public imports stay predictable.
    var values: [String: String] = [:]
    var expressions: [(name: String, value: String)] = []

    if let contentVariable = firstElement(fromXPath: "./Properties/Static/ContentVariable", on: object) {
        for child in childElements(of: contentVariable) {
            guard let variableName = attribute("Name", on: child), !variableName.isEmpty else { continue }
            switch child.name {
            case "Variable":
                if values[variableName] == nil {
                    let defaultValue = resolveExpressionValue(attribute("Default", on: child) ?? "", values: values)
                    values[variableName] = defaultValue
                }
            case "Constant":
                if values[variableName] == nil {
                    let constantValue = resolveExpressionValue(attribute("Value", on: child) ?? "", values: values)
                    values[variableName] = constantValue
                }
            case "Expression":
                if values[variableName] == nil, let expression = attribute("Value", on: child) {
                    expressions.append((name: variableName, value: expression))
                }
            default:
                break
            }
        }
    }

    applyOverrideVariables(from: settings ?? object, choices: [:], into: &values, respectSelection: false)
    resolveExpressions(expressions, into: &values)
    applyOverrideVariables(from: settings ?? object, choices: [:], into: &values, respectSelection: false)

    return values
}

static func applyOverrideVariables(
    from element: XMLElement?,
    choices: ChoiceMap,
    into values: inout [String: String],
    respectSelection: Bool
) {
    guard let element else { return }
    guard let overrideVariables = firstElement(fromXPath: "./Properties/Static/OverrideVariable", on: element) else { return }
    for child in childElements(of: overrideVariables) where child.name == "Variable" {
        if respectSelection, !overrideSelectionMatches(child, choices: choices) {
            continue
        }
        guard let variableName = attribute("Name", on: child), !variableName.isEmpty else { continue }
        let rawValue = attribute("Value", on: child) ?? values[variableName] ?? ""
        values[variableName] = resolveExpressionValue(rawValue, values: values)
    }
}

static func resolveExpressions(_ expressions: [(name: String, value: String)], into values: inout [String: String]) {
    guard !expressions.isEmpty else { return }
    for _ in 0..<4 {
        var changed = false
        for expression in expressions {
            let substituted = substituteInlineVariables(in: expression.value, values: values)
            let resolved = evaluateExpression(substituted, values: values) ?? substituted
            guard !resolved.contains("~"), !resolved.hasPrefix("?") else { continue }
            if values[expression.name] != resolved {
                values[expression.name] = resolved
                changed = true
            }
        }
        if !changed { break }
    }
}

static func applyVariableSubstitution(to element: XMLElement, values: [String: String]) {
    // Recursive attribute substitution. Example: Width="~Width" becomes a
    // concrete number before piece collection reads it.
    for attribute in element.attributes ?? [] {
        guard let name = attribute.name, let rawValue = attribute.stringValue else { continue }
        let substituted = substituteAttributeValue(rawValue, values: values)
        if substituted != rawValue {
            element.removeAttribute(forName: name)
            element.addAttribute(XMLNode.attribute(withName: name, stringValue: substituted) as! XMLNode)
        }
    }

    for child in childElements(of: element) {
        applyVariableSubstitution(to: child, values: values)
    }
}

static func substituteAttributeValue(_ rawValue: String, values: [String: String]) -> String {
    // Resolve attribute variables when cloning library XML.
    resolveExpressionValue(rawValue, values: values)
}

static func substituteInlineVariables(in rawValue: String, values: [String: String]) -> String {
    // Replaces Vector 2's `~VariableName` placeholders inside larger
    // strings. Some library objects store numbers directly as variables,
    // while others embed them in mini expressions.
    var result = rawValue
    for (key, value) in values {
        result = result.replacingOccurrences(of: "~\(key)", with: value)
    }
    return result
}

static func resolveExpressionValue(_ rawValue: String, values: [String: String]) -> String {
    // Resolves one value from the library variable system. It supports:
    // - direct variable references: `~Width`
    // - inline variables: `{~Width}` or `foo_~Variant`
    // - simple expression wrappers and switch expressions below
    let directValue: String
    if rawValue.hasPrefix("~") {
        let key = String(rawValue.dropFirst())
        directValue = values[key] ?? rawValue
    } else {
        directValue = substituteInlineVariables(in: rawValue, values: values)
    }
    return evaluateExpression(directValue, values: values) ?? directValue
}

static func evaluateExpression(_ rawValue: String, values: [String: String]) -> String? {
    // Tiny evaluator for the XML expression subset we actually see in
    // Vector 2 libraries. This is deliberately not a general scripting
    // engine; if an expression is unknown, returning nil preserves the raw
    // value instead of inventing a broken visual.
    let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "" }

    if trimmed.hasPrefix("{"), trimmed.hasSuffix("}") {
        let inner = String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedInner = resolveExpressionValue(inner, values: values)
        if let number = Double(resolvedInner.replacingOccurrences(of: ",", with: ".")) {
            return formattedNumber(number)
        }
        var parser = Vector2ArithmeticParser(characters: Array(resolvedInner))
        if let number = parser.parse() {
            return formattedNumber(number)
        }
        return resolvedInner
    }

    var parser = Vector2ArithmeticParser(characters: Array(trimmed))
    if let number = parser.parse() {
        return formattedNumber(number)
    }

    guard trimmed.hasPrefix("?switch["), trimmed.hasSuffix("]") else {
        return nil
    }

    let body = String(trimmed.dropFirst("?switch[".count).dropLast())
    let parts = splitTopLevel(body, separator: ",").map {
        $0.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard let selectorRaw = parts.first else { return nil }
    let selector = resolveExpressionValue(selectorRaw, values: values)
    var fallback: String?

    for part in parts.dropFirst() {
        guard !part.isEmpty else { continue }
        if let colonIndex = part.firstIndex(of: ":") {
            let caseName = String(part[..<colonIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            let result = String(part[part.index(after: colonIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if caseName == selector {
                return resolveExpressionValue(result, values: values)
            }
        } else {
            fallback = part
        }
    }

    return fallback.map { resolveExpressionValue($0, values: values) }
}

static func splitTopLevel(_ text: String, separator: Character) -> [String] {
    // Splits switch expression arguments without breaking nested `{...}` or
    // `[...]`. A plain `components(separatedBy:)` is why these importers get
    // haunted later 💀.
    var result: [String] = []
    var current = ""
    var squareDepth = 0
    var braceDepth = 0

    for character in text {
        switch character {
        case "[":
            squareDepth += 1
        case "]":
            squareDepth = max(0, squareDepth - 1)
        case "{":
            braceDepth += 1
        case "}":
            braceDepth = max(0, braceDepth - 1)
        default:
            break
        }

        if character == separator, squareDepth == 0, braceDepth == 0 {
            result.append(current)
            current.removeAll(keepingCapacity: true)
        } else {
            current.append(character)
        }
    }

    if !current.isEmpty {
        result.append(current)
    }
    return result
}

static func formattedNumber(_ value: Double) -> String {
    // Keeps exported/resolved XML pleasant: `10` instead of `10.0`, while
    // preserving fractional values when they matter.
    if abs(value.rounded() - value) < 0.0001 {
        return String(Int(value.rounded()))
    }
    return String(value)
}

static func isEnabled(_ element: XMLElement, choices: ChoiceMap) -> Bool {
    // Library pieces can be disabled by XML. Runtime Graph respects this so
    // hidden/inactive internals do not become bogus editor boxes.
    guard let enable = firstElement(fromXPath: "./Properties/Static/Enable", on: element),
          let raw = attribute("Value", on: enable)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
        return true
    }
    if raw.hasPrefix("~") {
        let variable = String(raw.dropFirst())
        if let value = choices[variable]?.lowercased() {
            return !(value == "0" || value == "false")
        }
    }
    if raw.hasPrefix("!~") {
        let variable = String(raw.dropFirst(2))
        if let value = choices[variable]?.lowercased() {
            return value == "0" || value == "false"
        }
    }
    let normalized = raw.lowercased()
    return !(normalized == "0" || normalized == "false")
}

static func shouldIncludeElement(
    _ element: XMLElement,
    choices: ChoiceMap,
    includePhantomVisualizers: Bool = false
) -> Bool {
    // Gatekeeper for library child pieces. Runtime Graph filters disabled,
    // unselected, and phantom-only visualizers; ConvertXmlObject2 mode stays
    // looser for diagnostics when we need to compare against Vision's path.
    if importPipeline == .convertXmlObject2 {
        return true
    }
    guard isEnabled(element, choices: choices) else { return false }
    if !includePhantomVisualizers && attribute("Phantom", on: element) == "1" {
        return false
    }
    return checkSelection(in: firstElement(fromXPath: "./Properties/Static", on: element), choices: choices)
}

static func checkSelection(in staticProperties: XMLElement?, choices: ChoiceMap) -> Bool {
    // Applies `<Selection Choice=... Variant=...>` rules. This is why one
    // library object can resolve into different shapes based on its XML
    // settings.
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

static func selectionChoiceCandidates(choice: String, parent: String, choices: ChoiceMap) -> [String] {
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

static func overrideSelectionMatches(_ element: XMLElement, choices: ChoiceMap) -> Bool {
    // Override variables may also contain selection guards. Empty override
    // nodes apply globally.
    guard childElements(of: element).isEmpty == false else { return true }
    return checkSelection(in: element, choices: choices)
}

static func activeChoices(for element: XMLElement?) -> ChoiceMap {
    // Collects the selected variants from an object reference so nested
    // library objects can choose the same branch as the game.
    guard let element else { return [:] }
    var choices: ChoiceMap = [:]
    collectSelections(from: element, into: &choices)
    return choices
}

static func mergedChoices(_ inherited: [String: String], _ local: ChoiceMap) -> ChoiceMap {
    var choices = inherited
    for (key, value) in local {
        choices[key] = value
    }
    return choices
}

static func collectSelections(from element: XMLElement, into choices: inout ChoiceMap) {
    // Recursive selection scan. Choice nodes can live more than one level
    // down under Properties/Static, so keep this tree-based.
    for child in childElements(of: element) {
        if child.name == "Selection",
           let choice = attribute("Choice", on: child),
           let variant = attribute("Variant", on: child),
           !choice.isEmpty,
           !variant.isEmpty {
            let parent = attribute("Parent", on: child)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let exactChoice = parent.isEmpty ? choice : "\(parent)/\(choice)"
            choices[exactChoice] = variant
            if parent.isEmpty {
                choices[choice] = variant
            }
            if let roomName = choices["__RoomName"], !roomName.isEmpty {
                choices["\(roomName)_\(exactChoice)"] = variant
            }
        }
        collectSelections(from: child, into: &choices)
    }
}

}
