import Foundation

// Shared, local-only context for completion and repairs. Offsets are UTF-16 for NSTextView.
nonisolated enum XMLAssistantContext {
    struct Token: Sendable {
        var name: String
        var range: NSRange
        var attributes: [String: String]
        var closing: Bool
        var selfClosing: Bool
        var complete: Bool
    }
    struct Variable: Sendable {
        var name: String
        var type: String
        var value: String
        var reference: String { "_" + name }
        // TriggerRunner.ParseVariable infers runtime type from Value, not the UI Type attribute.
        var numeric: Bool {
            guard !["AI", "Node"].contains(type), let first = value.first, "+-0123456789".contains(first) else { return false }
            if value.contains(".") { return Float(value)?.isFinite == true }
            return Int32(value) != nil
        }
    }
    struct ValueChoice: Sendable {
        var value: String
        var reason: String
    }

    struct FieldProblem {
        var key: String
        var expected: String
        var choices: [String]
        var correction: String?
    }
    struct ProjectFieldRule: Hashable, Sendable {
        var key: String
        var kind: String
        var required = false
        var values: [String] = []
        var reference = ""
    }
    // Opt-in domain boundaries are exact root/path matches from the editor's codecs.
    // Unknown elements and attributes remain extension data, not a closed schema.
    static func projectFieldRules(_ element: XMLElement, schemas: [XMLAssistantTemplateIndex.SchemaRule] = []) -> [ProjectFieldRule] {
        var root: XMLNode = element
        while let parent = root.parent, parent.kind != .document { root = parent }
        var rules: [ProjectFieldRule] = []
        switch root.name {
        case "CustomModel" where root === element:
            rules = [.init(key: "ID", kind: "text", required: true), .init(key: "FileName", kind: "text", required: true)]
        case "CustomTrick" where root === element, "AnimationOverride" where root === element:
            rules = [.init(key: root.name == "CustomTrick" ? "Name" : "Target", kind: "text", required: true), .init(key: "FileName", kind: "text", required: true)]
            if root.name == "CustomTrick" { rules += ["FirstFrame", "EndFrame", "MidFrames"].map { .init(key: $0, kind: "integer") } }
        case "CustomMission" where root === element, "CustomReward" where root === element, "CustomTutorial" where root === element:
            rules = ["Target", "Amount", "Order", "Difficulty", "MaximumFloor", "Weight"].map { .init(key: $0, kind: "integer") }
        case "CustomAudio":
            if element.name == "Pool", element.parent?.name == "MusicPools", element.parent?.parent === root {
                rules = [.init(key: "Scope", kind: "enum", required: true, values: ["Chapter", "Zone"]), .init(key: "AmbientVolume", kind: "number")]
            } else if element.name == "Track", element.parent?.name == "Pool", element.parent?.parent?.name == "MusicPools", element.parent?.parent?.parent === root {
                rules = [.init(key: "Id", kind: "text", required: true)] + ["Weight", "MinFloor", "MaxFloor"].map { .init(key: $0, kind: "integer") }
            }
        case "CustomTrap" where root === element:
            rules = ["Width", "Height", "CycleFrames", "Reach", "DamageAmount", "ChargeFrames", "HitFrames", "DangerX", "DangerY", "DangerWidth", "DangerHeight", "ActivationX", "ActivationY", "ActivationWidth", "ActivationHeight"].map { .init(key: $0, kind: "integer") }
            rules.append(.init(key: "SoundVolume", kind: "number"))
        case "Protocols":
            if element.name == "Protocol", element.parent === root {
                rules = [.init(key: "Id", kind: "text", required: true)] + ["StartFloor", "Order"].map { .init(key: $0, kind: "integer") }
            } else if element.parent?.name == "Protocol", element.parent?.parent === root {
                if element.name == "Gameplay" {
                    rules = [.init(key: "Interval", kind: "number")] + ["Amount", "Maximum"].map { .init(key: $0, kind: "integer") }
                } else if element.name == "ArmourDefense" {
                    rules = ["Capacity", "Impact", "Heat", "Electric", "Swarm", "Helmet", "Torso", "Hands", "Legs", "Belt"].map { .init(key: $0, kind: "integer") }
                }
            }
        default: break
        }
        var names: [String] = []
        var cursor: XMLNode? = element
        while let node = cursor, node !== root { names.append(node.name ?? ""); cursor = node.parent }
        let path = names.isEmpty ? "." : names.reversed().joined(separator: "/")
        for schema in schemas where schema.root == root.name && schema.path == path {
            guard schema.whenAttribute.isEmpty || element.attribute(forName: schema.whenAttribute)?.stringValue == schema.whenValue else { continue }
            let overridden = Set(schema.fields.map(\.key))
            rules.removeAll { overridden.contains($0.key) }
            rules += schema.fields
        }
        return rules
    }
    static func projectFieldProblems(_ element: XMLElement, schemas: [XMLAssistantTemplateIndex.SchemaRule] = [], references: [String: [String]] = [:]) -> [FieldProblem] {
        let rules = projectFieldRules(element, schemas: schemas).map { rule in
            var resolved = rule
            if rule.kind == "reference" { resolved.values = references[rule.reference] ?? [] }
            if rule.kind == "text", let field = referenceFields(element, references: references).first(where: { $0.key == rule.key }), !field.values.isEmpty {
                resolved.kind = "reference"
                resolved.values = field.values
            }
            return resolved
        }
        return problems(element, rules: rules)
    }
    private static func problems(_ element: XMLElement, rules: [ProjectFieldRule]) -> [FieldProblem] {
        rules.compactMap { rule in
            let value = element.attribute(forName: rule.key)?.stringValue
            if value == nil && !rule.required { return nil }
            let raw = value ?? ""
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            func valid(_ value: String) -> Bool {
                switch rule.kind {
                case "integer": return Int(value) != nil
                case "number": return Double(value)?.isFinite == true
                case "enum": return rule.values.contains(value)
                // A partial reference index cannot reject arbitrary extension names.
                case "reference": return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                default: return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
            }
            guard !valid(raw) else { return nil }
            let correction = rule.kind == "enum" ? rule.values.first { $0.caseInsensitiveCompare(trimmed) == .orderedSame } : (valid(trimmed) ? trimmed : nil)
            let choices = ["enum", "reference"].contains(rule.kind) ? rule.values : correction.map { [$0] } ?? []
            return .init(key: rule.key, expected: rule.kind == "enum" ? rule.values.joined(separator: ", ") : "a nonempty \(rule.kind) value", choices: choices, correction: correction)
        }
    }
    static func conditionalRequiredFields(_ element: XMLElement, section: String) -> [String] {
        guard ["Actions", "Init"].contains(section) else { return [] }
        if ["Sound", "Music"].contains(element.name ?? "") {
            let action = element.attribute(forName: "Action")?.stringValue ?? "Play"
            return action == "Play" ? [element.name == "Sound" ? "Name" : "Track"] : []
        }
        guard element.name == "Swarm" else { return [] }
        switch element.attribute(forName: "Type")?.stringValue {
        case "Spawn": return ["Waypoint"]
        case "Activate": return ["ActionID"]
        default: return []
        }
    }
    static func requiredFields(_ element: XMLElement, section: String, base: [String]) -> [String] {
        var fields = base
        if ["Actions", "Init"].contains(section), ["Sound", "Music"].contains(element.name ?? ""),
           (element.attribute(forName: "Action")?.stringValue ?? "Play") != "Play" {
            fields.removeAll { $0 == (element.name == "Sound" ? "Name" : "Track") }
        }
        return Array(Set(fields + conditionalRequiredFields(element, section: section))).sorted()
    }
    // Reconstruct only the open ancestry for typing context, not a speculative full draft.
    static func completionDocument(_ source: String, at caret: Int) -> XMLDocument? {
        let prefix = (source as NSString).substring(to: min(max(0, caret), source.utf16.count))
        var stack: [Token] = []
        for token in tokens(prefix) {
            if token.closing {
                if let match = stack.lastIndex(where: { $0.name == token.name }) { stack.removeSubrange(match...) }
            } else if !token.selfClosing, token.name != "?", !token.name.isEmpty {
                stack.append(token)
            }
        }
        guard !stack.isEmpty else { return nil }
        var root: XMLElement?, parent: XMLElement?
        for token in stack {
            let element = XMLElement(name: token.name)
            for (key, value) in token.attributes { element.addAttribute(XMLNode.attribute(withName: key, stringValue: value) as! XMLNode) }
            if let parent { parent.addChild(element) } else { root = element }
            parent = element
        }
        return root.map { XMLDocument(rootElement: $0) }
    }
    static func referenceFields(_ element: XMLElement, references: [String: [String]], schemas: [XMLAssistantTemplateIndex.SchemaRule] = []) -> [(key: String, values: [String])] {
        let explicit = projectFieldRules(element, schemas: schemas).filter { $0.kind == "reference" }.map { (key: $0.key, values: references[$0.reference] ?? []) }
        let overridden = Set(explicit.map(\.key))
        return builtInReferenceFields(element, references: references).filter { !overridden.contains($0.key) } + explicit
    }
    private static func builtInReferenceFields(_ element: XMLElement, references: [String: [String]]) -> [(key: String, values: [String])] {
        let name = element.name ?? ""
        if ["Actions", "Init"].contains(element.parent?.name ?? "") {
            var fields: [(key: String, values: [String])] = []
            if name == "ForceAnimation" { fields.append(("Name", references["Animation"] ?? [])) }
            if name == "ModelExecute" { fields.append(("AnimName", references["Animation"] ?? [])) }
            if ["Press", "ForceAnimation", "Control", "EndGame", "Spawn", "ExitAI", "Kill", "Impulse", "RunModelEffect"].contains(name) { fields.append(("Model", references["Model"] ?? [])) }
            if name == "SetModelParameter" { fields.append(("ModelName", references["Animator"] ?? [])) }
            return fields
        }
        if name == "Image" { return [("Class", references["Texture"] ?? [])] }
        if name == "ObjectReference" || (name == "Object" && element.attribute(forName: "Template")?.stringValue == "LibraryObject") {
            let file = element.attribute(forName: "File")?.stringValue ?? element.attribute(forName: "Filename")?.stringValue ?? ""
            return [("File", references["ObjectFile"] ?? []), ("Class", references["ObjectClass:" + URL(fileURLWithPath: file).lastPathComponent] ?? [])]
        }
        if name == "CustomModel", element.parent?.kind == .document || element.parent == nil {
            let id = element.attribute(forName: "ID")?.stringValue ?? ""
            return [("FileName", references["ModelFile:" + id] ?? [])]
        }
        if name == "CustomTrick", element.parent?.kind == .document || element.parent == nil {
            let id = element.attribute(forName: "Name")?.stringValue ?? ""
            return [("FileName", references["TrickFile:" + id] ?? [])]
        }
        if name == "AnimationOverride", element.parent?.kind == .document || element.parent == nil { return [("Target", references["AnimationMove"] ?? [])] }
        if name == "Protocol", element.parent?.name == "Protocols" {
            let value = element.attribute(forName: "PlayerModel")?.stringValue ?? ""
            let choices = references["ModelPackage"] ?? []
            return [("PlayerModel", value.lowercased().hasPrefix("custom:") || value.isEmpty ? choices : choices.map { String($0.dropFirst(7)) })]
        }
        if name == "Armor", element.parent?.name == "Protocol", element.parent?.parent?.name == "Protocols" {
            let value = element.attribute(forName: "Model")?.stringValue ?? ""
            let choices = references["ModelPackage"] ?? []
            return [("Model", value.lowercased().hasPrefix("custom:") || value.isEmpty ? choices : choices.map { String($0.dropFirst(7)) })]
        }
        return []
    }
    static func knownReference(_ value: String, key: String, element: XMLElement, choices: [String]) -> Bool {
        if choices.contains(value) { return true }
        let packageField = (element.name == "Protocol" && key == "PlayerModel" && element.parent?.name == "Protocols") ||
            (element.name == "Armor" && key == "Model" && element.parent?.name == "Protocol" && element.parent?.parent?.name == "Protocols")
        guard packageField else { return false }
        func normalized(_ name: String) -> String {
            var result = name.lowercased()
            if result.hasPrefix("custom:") { result = String(result.dropFirst(7)) }
            if result.hasSuffix(".xml") { result = String(result.dropLast(4)) }
            return result
        }
        return choices.contains { normalized($0) == normalized(value) }
    }
    static func combinedLiteralCorrections(_ source: String, templates: XMLAssistantTemplateIndex = .init()) -> String? {
        guard let document = try? XMLDocument(xmlString: source, options: [.nodeLoadExternalEntitiesNever]),
              let nodes = try? document.nodes(forXPath: "//*") else { return nil }
        var edits = 0
        for element in nodes.compactMap({ $0 as? XMLElement }) {
            for problem in fieldProblems(element, section: element.parent?.name ?? "") + fieldProblems(element, section: "Scene") + projectFieldProblems(element, schemas: templates.schemas, references: templates.references) {
                guard let correction = problem.correction else { continue }
                element.attribute(forName: problem.key)?.stringValue = correction
                edits += 1
                guard edits <= 16 else { return nil }
            }
        }
        return edits >= 2 ? document.xmlString(options: [.nodePrettyPrint]) : nil
    }
    static func compatibleSectionLayout(_ source: String) -> String? {
        guard let document = try? XMLDocument(xmlString: source, options: [.nodeLoadExternalEntitiesNever]),
              let misplaced = try? document.nodes(forXPath: "//Trigger/Content/Init/Loop") else { return nil }
        var edits = 0
        var insertionTails: [ObjectIdentifier: XMLNode] = [:]
        for loop in misplaced {
            guard let initializer = loop.parent as? XMLElement, let content = initializer.parent as? XMLElement else { continue }
            loop.detach()
            let anchor = insertionTails[ObjectIdentifier(initializer)] ?? initializer
            let insertion = (content.children ?? []).firstIndex { $0 === anchor }.map { $0 + 1 } ?? content.childCount
            content.insertChild(loop, at: insertion)
            insertionTails[ObjectIdentifier(initializer)] = loop
            edits += 1
            if edits > 16 { return nil }
        }
        let names = ["Events", "Conditions", "Actions"]
        for loop in ((try? document.nodes(forXPath: "//Trigger/Content/Loop")) ?? []).compactMap({ $0 as? XMLElement }) {
            var scan = 0
            while scan < loop.childCount {
                if let wrapper = loop.child(at: scan) as? XMLElement, names.contains(wrapper.name ?? "") {
                    let nested = (wrapper.children ?? []).compactMap { $0 as? XMLElement }.filter { names.contains($0.name ?? "") }
                    var insertion = scan + 1
                    for child in nested {
                        child.detach(); loop.insertChild(child, at: insertion); insertion += 1
                        edits += 1
                        if edits > 16 { return nil }
                    }
                }
                scan += 1
            }
            for name in names {
                let sections = (loop.children ?? []).compactMap { $0 as? XMLElement }.filter { $0.name == name }
                guard sections.count > 1, sections.allSatisfy({ ($0.attributes ?? []).isEmpty }) else { continue }
                for duplicate in sections.dropFirst() {
                    for child in duplicate.children ?? [] { child.detach(); sections[0].addChild(child) }
                    duplicate.detach()
                    edits += 1
                    if edits > 16 { return nil }
                }
            }
        }
        return edits >= 2 ? document.xmlString(options: [.nodePrettyPrint]) : nil
    }

    // Contracts from TRA_Wait/SetTimer/EndGame/Control/ForceAnimation/GlobalTimer.
    // Runtime _ references are expressions, not literals; extensions aren't closed-world.
    static func fieldProblems(_ element: XMLElement, section: String) -> [FieldProblem] {
        if section == "Scene", ["Image", "Object", "ObjectReference", "Platform", "Area", "Trigger"].contains(element.name ?? "") {
            return ["X", "Y", "Width", "Height", "Rotation", "Factor"].compactMap { key in
                guard let value = element.attribute(forName: key)?.stringValue,
                      !["_", "?", "$"].contains(where: { value.hasPrefix($0) }), Float(value)?.isFinite != true else { return nil }
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                let correction = Float(trimmed)?.isFinite == true ? trimmed : nil
                return .init(key: key, expected: "a finite scene-coordinate number", choices: correction.map { [$0] } ?? [], correction: correction)
            }
        }
        guard section == "Actions" || section == "Init" else { return [] }
        let tag = element.name ?? ""
        var numericFields: [String: [String]] = ["Wait": ["Frames"], "SetTimer": ["Frames"],
            "EndGame": ["Frames"], "ForceAnimation": ["Frame", "Reversed"], "GlobalTimer": ["Frames"],
            "ModelExecute": ["AnimFrame"], "Impulse": ["Impulse", "R", "Absorption"], "Sound": ["Volume", "DuckEffect", "Time"], "Music": ["Time"]]
        if tag == "SetModelParameter", ["bool", "int", "float"].contains(element.attribute(forName: "Type")?.stringValue?.lowercased() ?? "") { numericFields[tag] = ["Value"] }
        let enums: [String: [String: [String]]] = ["Control": ["Switch": ["On", "Off"]],
            "EndGame": ["Result": ["Win", "Loss", "Death"]],
            "GlobalTimer": ["Action": ["increment", "pause"]], "Swarm": ["Type": ["Spawn", "Activate", "Stop"]],
            "SetModelParameter": ["Type": ["bool", "int", "float"]], "Choose": ["Order": ["Sync", "Straight", "Random"]],
            "Sound": ["Action": ["Play", "Stop"], "Channel": ["Sound", "Cutscene", "Ambient"]], "Music": ["Action": ["Play", "Stop", "Pause", "Resume"]]]
        var problems: [FieldProblem] = []
        let fields = Set(numericFields[tag] ?? []).union((enums[tag] ?? [:]).keys)
        for key in fields.sorted() {
            guard let value = element.attribute(forName: key)?.stringValue, !value.isEmpty,
                  !["_", "?", "$"].contains(where: { value.hasPrefix($0) }) else { continue }
            if let allowed = enums[tag]?[key] {
                let valid = ["GlobalTimer", "SetModelParameter"].contains(tag) ? allowed.contains(value.lowercased()) : allowed.contains(value)
                guard !valid else { continue }
                let correction = allowed.first { $0.caseInsensitiveCompare(value.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame }
                problems.append(.init(key: key, expected: allowed.joined(separator: ", "), choices: allowed, correction: correction))
            } else {
                guard !Variable(name: "", type: "", value: value).numeric else { continue }
                var choices: [String] = []
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                let correction = Variable(name: "", type: "", value: trimmed).numeric ? trimmed : nil
                if let correction { choices.append(correction) }
                for variable in declaredVariables(for: element) where variable.numeric {
                    choices += [variable.reference, variable.value]
                }
                for choice in requiredValueChoices(element: element, key: key) where Variable(name: "", type: "", value: choice.value).numeric {
                    choices.append(choice.value)
                }
                var seen: Set<String> = []
                problems.append(.init(key: key, expected: "a numeric literal or runtime variable reference", choices: choices.filter { seen.insert($0).inserted }.prefix(12).map { $0 }, correction: correction))
            }
        }
        return problems
    }

    // Broken drafts still yield a prefix index. Protected blocks never become fake tags.
    static func tokens(_ source: String) -> [Token] {
        let text = source as NSString
        let units = Array(source.utf16)
        var index = 0
        var result: [Token] = []
        func starts(_ value: String, _ position: Int) -> Bool {
            let needle = Array(value.utf16)
            return position + needle.count <= units.count && Array(units[position..<(position + needle.count)]) == needle
        }
        func skip(_ terminator: String, from start: Int) -> Int {
            let range = text.range(of: terminator, options: [], range: NSRange(location: start, length: text.length - start))
            return range.location == NSNotFound ? text.length : NSMaxRange(range)
        }
        while index < units.count {
            guard units[index] == 60 else { index += 1; continue }
            if starts("<!--", index) { index = skip("-->", from: index + 4); continue }
            if starts("<![CDATA[", index) { index = skip("]]>", from: index + 9); continue }
            if starts("<?", index) {
                let end = text.range(of: "?>", options: [], range: NSRange(location: index + 2, length: text.length - index - 2))
                if end.location == NSNotFound {
                    result.append(.init(name: "?", range: NSRange(location: index, length: text.length - index), attributes: [:], closing: false, selfClosing: false, complete: false))
                }
                index = end.location == NSNotFound ? text.length : NSMaxRange(end)
                continue
            }
            if starts("<!", index) { index = skip(">", from: index + 2); continue }
            let start = index
            index += 1
            let closing = index < units.count && units[index] == 47
            if closing { index += 1 }
            let nameStart = index
            while index < units.count {
                let unit = units[index]
                guard let scalar = UnicodeScalar(unit), CharacterSet.alphanumerics.contains(scalar) || [95, 58, 45, 46].contains(unit) else { break }
                index += 1
            }
            let name = text.substring(with: NSRange(location: nameStart, length: index - nameStart))
            var quote: UInt16?
            var complete = false
            while index < units.count {
                let unit = units[index]
                if let current = quote {
                    if unit == current { quote = nil }
                } else if unit == 34 || unit == 39 { quote = unit }
                else if unit == 62 { index += 1; complete = true; break }
                else if unit == 60 { break }
                index += 1
            }
            let range = NSRange(location: start, length: index - start)
            let body = text.substring(with: range)
            let attributes = attributes(in: body)
            if !name.isEmpty || !complete {
                result.append(.init(name: name, range: range, attributes: attributes, closing: closing,
                                    selfClosing: body.hasSuffix("/>"), complete: complete))
            }
            if index <= start { index = start + 1 }
        }
        return result
    }

    static func attributes(in token: String) -> [String: String] {
        guard let regex = try? NSRegularExpression(pattern: #"([A-Za-z_][A-Za-z0-9_:.-]*)\s*=\s*(?:"([^"]*)"|'([^']*)')"#) else { return [:] }
        let text = token as NSString
        var result: [String: String] = [:]
        for match in regex.matches(in: token, range: NSRange(location: 0, length: text.length)) {
            let range = match.range(at: match.range(at: 2).location == NSNotFound ? 3 : 2)
            let encoded = text.substring(with: range)
            // Decode XML entities without interpreting escaped markup as elements.
            let wrapper = "<V>" + encoded.replacingOccurrences(of: "<", with: "&lt;") + "</V>"
            let value = (try? XMLDocument(xmlString: wrapper, options: [.nodeLoadExternalEntitiesNever]).rootElement()?.stringValue) ?? encoded
            result[text.substring(with: match.range(at: 1))] = value
        }
        return result
    }

    static func variables(in source: String, at caret: Int) -> [Variable] {
        var stack: [String] = []
        var scopes: [[Variable]] = []
        var variables: [Variable] = []
        for token in tokens(source) where token.range.location < caret {
            if token.closing {
                if token.name == "Trigger" { variables = scopes.popLast() ?? [] }
                if let last = stack.lastIndex(of: token.name) { stack.removeSubrange(last...) }
                continue
            }
            if token.name == "Trigger" { scopes.append(variables); variables = [] }
            if token.name == "SetVariable", stack.last == "Init",
               let name = token.attributes["Name"], !name.isEmpty {
                variables.append(.init(name: name, type: token.attributes["Type"] ?? "", value: token.attributes["Value"] ?? ""))
            }
            if token.complete && !token.selfClosing { stack.append(token.name) }
        }
        // Ambiguous duplicate declarations are not usable as inferred operands.
        let groups = Dictionary(grouping: variables, by: \.name)
        return variables.filter { groups[$0.name]?.count == 1 }.sorted { $0.name < $1.name }
    }

    static func valueChoices(tag: String, attribute: String, attributes: [String: String], variables: [Variable]) -> [ValueChoice] {
        guard ["Equal", "Greater", "Less", "GreaterEqual", "LessEqual"].contains(tag),
              ["Value1", "Value2"].contains(attribute) else { return [] }
        let other = attributes[attribute == "Value1" ? "Value2" : "Value1"] ?? ""
        let counterpart = variables.first { $0.reference == other }
        // TRC_Compare uses _ references, otherwise Variable.CreateVariable; comparisons use ValueInt.
        let compatible = variables.filter { $0.numeric && $0.reference != other }
        var values: [ValueChoice] = []
        if let counterpart, counterpart.numeric, Double(counterpart.value) != nil {
            values.append(.init(value: counterpart.value, reason: "Compares with \(other)'s declared starting value, not necessarily its current value. This is an explicit gameplay choice, not an inferred fix."))
            if counterpart.type == "Bool" {
                for value in ["0", "1"] where value != counterpart.value {
                    values.append(.init(value: value, reason: "Boolean state represented numerically by the game. Choose the state you want to test."))
                }
            }
        }
        values += compatible.map { ValueChoice(value: $0.reference, reason: "Uses the declared numeric variable \($0.name). The game resolves it as \($0.reference). Choose it only if this is the quantity you intended to compare.") }
        return values
    }

    static func declaredVariables(for element: XMLElement, includeRepeated: Bool = false) -> [Variable] {
        var scope: XMLNode = element
        while scope.name != "Trigger", let parent = scope.parent { scope = parent }
        guard scope.name == "Trigger" else { return [] }
        let declared = (try? scope.nodes(forXPath: "./Content/Init/SetVariable | ./Init/SetVariable")) ?? []
        let variables = declared.compactMap { node -> Variable? in
            guard let node = node as? XMLElement, let name = node.attribute(forName: "Name")?.stringValue else { return nil }
            return .init(name: name, type: node.attribute(forName: "Type")?.stringValue ?? "", value: node.attribute(forName: "Value")?.stringValue ?? "")
        }
        let groups = Dictionary(grouping: variables, by: \.name)
        if includeRepeated { return variables }
        return variables.filter { groups[$0.name]?.count == 1 }
    }

    static func encodedCompletion(_ value: String, source: String, range: NSRange) -> String {
        let text = source as NSString
        guard range.location > 0, range.location <= text.length,
              [34, 39].contains(text.character(at: range.location - 1)) else { return value }
        return value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    static func requiredValueChoices(element: XMLElement, key: String) -> [ValueChoice] {
        let unique = declaredVariables(for: element)
        let attrs = Dictionary(uniqueKeysWithValues: (element.attributes ?? []).compactMap { node -> (String, String)? in
            guard let name = node.name, let value = node.stringValue else { return nil }; return (name, value)
        })
        var choices = valueChoices(tag: element.name ?? "", attribute: key, attributes: attrs, variables: unique)
        // Same-tag sibling values are evidence-backed alternatives for any required field,
        // not defaults and never automatically recommended.
        for sibling in (element.parent?.children ?? []).compactMap({ $0 as? XMLElement }) where sibling !== element && sibling.name == element.name {
            if let value = sibling.attribute(forName: key)?.stringValue, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !( ["Equal", "Greater", "Less", "GreaterEqual", "LessEqual"].contains(element.name ?? "") &&
                  ["Value1", "Value2"].contains(key) && value == attrs[key == "Value1" ? "Value2" : "Value1"] ),
               !choices.contains(where: { $0.value == value }) {
                choices.append(.init(value: value, reason: "Reuses \(key) from another \(element.name ?? "element") in this section. Review whether the same value is intended here; matching structure does not prove matching behavior."))
            }
        }
        return Array(choices.prefix(12))
    }

    static func restoringErasedValues(source: String, previous: String) -> String? {
        guard source != previous, source.utf16.count <= 200_000, previous.utf16.count <= 200_000,
              XMLAssistantStructuralRepairs.parses(source), XMLAssistantStructuralRepairs.parses(previous) else { return nil }
        let current = tokens(source), old = tokens(previous)
        guard current.count == old.count else { return nil }
        var edits: [(NSRange, String)] = []
        for (token, prior) in zip(current, old) {
            guard token.name == prior.name, token.closing == prior.closing, token.selfClosing == prior.selfClosing else { return nil }
            var attrs = token.attributes
            for key in Set(attrs.keys).union(prior.attributes.keys) {
                if attrs[key] == prior.attributes[key] { continue }
                guard (attrs[key] ?? "").isEmpty, let value = prior.attributes[key], !value.isEmpty else { return nil }
                attrs[key] = value
            }
            if attrs != token.attributes {
                let element = XMLElement(name: token.name)
                for key in attrs.keys.sorted() { element.addAttribute(XMLNode.attribute(withName: key, stringValue: attrs[key]!) as! XMLNode) }
                var replacement = element.xmlString
                if !token.selfClosing, replacement.hasSuffix("/>") { replacement = String(replacement.dropLast(2)) + ">" }
                edits.append((token.range, replacement))
            }
        }
        // Ensure unrelated text/comments were not edited: token attributes alone are not identity.
        func skeleton(_ value: String, _ indexed: [Token]) -> String {
            let text = NSMutableString(string: value)
            for token in indexed.reversed() { text.replaceCharacters(in: token.range, with: "<\(token.closing ? "/" : "")\(token.name)\(token.selfClosing ? "/" : "")>") }
            return text as String
        }
        guard !edits.isEmpty, skeleton(source, current) == skeleton(previous, old) else { return nil }
        let text = NSMutableString(string: source)
        for (range, replacement) in edits.reversed() { text.replaceCharacters(in: range, with: replacement) }
        let code = text as String
        return XMLAssistantStructuralRepairs.parses(code) ? code : nil
    }

    // Lexical edits can be composed with structural repair instead of requiring each
    // isolated family to make a multiply-broken draft valid by itself.
    static func normalizingLexemes(_ source: String) -> String? {
        guard source.utf16.count <= 200_000,
              let bare = try? NSRegularExpression(pattern: #""[^"]*"|'[^']*'|([A-Za-z_][A-Za-z0-9_:.-]*)\s*=\s*([^\s"'=<>`]+)"#),
              let ampersands = try? NSRegularExpression(pattern: #"<!--[\s\S]*?-->|<!\[CDATA\[[\s\S]*?\]\]>|<\?[\s\S]*?\?>|&(?!amp;|lt;|gt;|quot;|apos;|#[0-9]+;|#x[0-9A-Fa-f]+;)(?![A-Za-z_:][A-Za-z0-9_:.-]*;)"#) else { return nil }
        let text = NSMutableString(string: source)
        for token in tokens(source).reversed() where token.complete && !token.closing {
            let body = (source as NSString).substring(with: token.range)
            let local = NSMutableString(string: body)
            for match in bare.matches(in: body, range: NSRange(location: 0, length: local.length)).reversed() where match.range(at: 1).location != NSNotFound {
                let name = (body as NSString).substring(with: match.range(at: 1))
                var value = (body as NSString).substring(with: match.range(at: 2))
                let closingSlash = value.hasSuffix("/") && NSMaxRange(match.range) == (body as NSString).length - 1
                if closingSlash { value.removeLast() }
                local.replaceCharacters(in: match.range, with: "\(name)=\"\(value)\"\(closingSlash ? "/" : "")")
            }
            text.replaceCharacters(in: token.range, with: local as String)
        }
        let quoted = text as String
        for match in ampersands.matches(in: quoted, range: NSRange(location: 0, length: text.length)).reversed() where (quoted as NSString).substring(with: match.range) == "&" {
            text.replaceCharacters(in: match.range, with: "&amp;")
        }
        return text as String == source ? nil : text as String
    }
}
