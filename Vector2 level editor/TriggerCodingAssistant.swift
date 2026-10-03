import Foundation

// Shared XML scanning, repair and reference-index types used by both XML editors.
// MARK: - XMLAssistantLexing.swift
// UTF-16 offsets match NSTextView. Quotes decide whether < and > are markup.
nonisolated enum XMLAssistantLexing {
    static func escapedAmpersandRepair(_ source: String) -> TriggerRuntimeSchema.DraftReview? {
        // Entity escaping doesn't apply to comments, CDATA or processing instructions.
        guard let tokens = try? NSRegularExpression(pattern: #"<!--[\s\S]*?-->|<!\[CDATA\[[\s\S]*?\]\]>|<\?[\s\S]*?\?>|&(?!amp;|lt;|gt;|quot;|apos;|#[0-9]+;|#x[0-9A-Fa-f]+;)(?![A-Za-z_:][A-Za-z0-9_:.-]*;)"#) else { return nil }
        let text = source as NSString
        let matches = tokens.matches(in: source, range: NSRange(location: 0, length: text.length)).filter { text.substring(with: $0.range) == "&" }
        guard let first = matches.first else { return nil }
        let replacement = NSMutableString(string: source)
        for match in matches.reversed() { replacement.replaceCharacters(in: match.range, with: "&amp;") }
        let code = replacement as String
        let parser = XMLParser(data: Data(code.utf8)); parser.shouldResolveExternalEntities = false
        guard parser.parse() else { return nil }
        let line = text.substring(to: first.range.location).filter { $0 == "\n" }.count + 1
        let solution = TriggerRuntimeSchema.DraftSolution(title: "Escape literal ampersands", explanation: "XML writes a literal & as &amp;. This preserves the displayed text and leaves existing entities, comments and CDATA untouched.", code: code, recommended: true)
        return .init(messages: ["Line \(line): Unescaped ampersand"], proposedXML: nil, source: source, issues: [.init(line: line, message: "Unescaped ampersand", explanation: "An & starts an XML entity. Escape it when it is ordinary text, including inside attribute values.", options: [], solutions: [solution])])
    }
    static func duplicateAttributeRepair(_ source: String) -> TriggerRuntimeSchema.DraftReview? {
        let text = source as NSString
        guard let tags = try? NSRegularExpression(pattern: #"<!--[\s\S]*?-->|<(?:[^>"']|"[^"]*"|'[^']*')*>"#),
              let attributes = try? NSRegularExpression(pattern: #"([A-Za-z_][A-Za-z0-9_:.-]*)\s*=\s*(?:"([^"]*)"|'([^']*)')"#) else { return nil }
        for tag in tags.matches(in: source, range: NSRange(location: 0, length: text.length)) {
            let token = text.substring(with: tag.range)
            if token.hasPrefix("<!") || token.hasPrefix("<?") || token.hasPrefix("</") { continue }
            let ns = token as NSString
            let matches = attributes.matches(in: token, range: NSRange(location: 0, length: ns.length))
            let names = matches.map { ns.substring(with: $0.range(at: 1)) }
            for name in Array(Set(names)).sorted() {
                let duplicates = matches.filter { ns.substring(with: $0.range(at: 1)) == name }
                guard duplicates.count > 1 else { continue }
                var solutions: [TriggerRuntimeSchema.DraftSolution] = []
                var seen: Set<String> = []
                let values = duplicates.map { match in ns.substring(with: match.range(at: match.range(at: 2).location == NSNotFound ? 3 : 2)) }
                for (index, match) in duplicates.enumerated() {
                    guard seen.insert(values[index]).inserted else { continue }
                    let mutable = NSMutableString(string: token)
                    for duplicate in duplicates.reversed() where duplicate.range != match.range {
                        mutable.deleteCharacters(in: duplicate.range)
                    }
                    let code = text.replacingCharacters(in: tag.range, with: mutable as String)
                    let check = XMLParser(data: Data(code.utf8)); check.shouldResolveExternalEntities = false
                    guard check.parse() else { continue }
                    solutions.append(.init(title: "Keep \(name)=\"\(values[index])\"", explanation: "Removes the other copies of \(name). Choose the value you intended; conflicting values aren't ranked by guessing.", code: code, recommended: Set(values).count == 1))
                }
                if !solutions.isEmpty {
                    let line = text.substring(to: tag.range.location).filter { $0 == "\n" }.count + 1
                    let message = "Attribute \(name) appears more than once."
                    return .init(messages: ["Line \(line): \(message)"], proposedXML: nil, source: source, issues: [.init(line: line, message: message, explanation: "XML allows each attribute only once on an element. Review the competing values below.", options: [], solutions: solutions)])
                }
            }
        }
        return nil
    }
    static func unfinishedTag(in source: String, at caret: Int) -> (start: Int, text: String)? {
        let text = source as NSString
        guard caret >= 0, caret <= text.length else { return nil }
        let prefix = text.substring(to: caret)
        guard let token = XMLAssistantContext.tokens(prefix).last, !token.complete,
              NSMaxRange(token.range) == caret else { return nil }
        return (token.range.location, text.substring(with: NSRange(location: token.range.location + 1, length: caret - token.range.location - 1)))
    }

    static func completionRange(in source: String, caret: Int) -> NSRange {
        let text = source as NSString, units = Array(source.utf16)
        let caret = max(0, min(caret, units.count))
        if let tag = unfinishedTag(in: source, at: caret) {
            var quote: UInt16?, valueStart = 0
            for index in (tag.start + 1)..<caret {
                let unit = units[index]
                if let current = quote { if unit == current { quote = nil } }
                else if unit == 34 || unit == 39 { quote = unit; valueStart = index + 1 }
            }
            if let quote {
                var end = caret
                while end < units.count && units[end] != quote { end += 1 }
                return NSRange(location: valueStart, length: end - valueStart)
            }
        }
        func nameUnit(_ unit: UInt16) -> Bool {
            guard let scalar = UnicodeScalar(unit) else { return false }
            return CharacterSet.alphanumerics.contains(scalar) || unit == 95 || unit == 58 || unit == 45 || unit == 46
        }
        var start = caret, end = caret
        while start > 0 && nameUnit(units[start - 1]) { start -= 1 }
        while end < text.length && nameUnit(units[end]) { end += 1 }
        return NSRange(location: start, length: end - start)
    }

    static func modelVariables(in prefix: String) -> [String] {
        let text = prefix as NSString
        guard let tags = try? NSRegularExpression(pattern: #"<!--[\s\S]*?-->|<(?:[^>"']|"[^"]*"|'[^']*')*>"#),
              let attrs = try? NSRegularExpression(pattern: #"([A-Za-z_][A-Za-z0-9_:.-]*)\s*=\s*(?:"([^"]*)"|'([^']*)')"#) else { return [] }
        var stack: [String] = [], scope: [String] = [], scopes: [[String]] = []
        for match in tags.matches(in: prefix, range: NSRange(location: 0, length: text.length)) {
            let token = text.substring(with: match.range)
            if token.hasPrefix("<!") || token.hasPrefix("<?") { continue }
            let closing = token.hasPrefix("</")
            let name = String(token.dropFirst(closing ? 2 : 1).prefix { !$0.isWhitespace && $0 != ">" && $0 != "/" })
            if closing {
                if name == "Trigger" { scope = scopes.popLast() ?? [] }
                if stack.last == name { stack.removeLast() }
                continue
            }
            if name == "Trigger" { scopes.append(scope); scope = [] }
            if name == "SetVariable", stack.last == "Init" {
                let ns = token as NSString
                var values: [String: String] = [:]
                for attribute in attrs.matches(in: token, range: NSRange(location: 0, length: ns.length)) {
                    let range = attribute.range(at: attribute.range(at: 2).location == NSNotFound ? 3 : 2)
                    values[ns.substring(with: attribute.range(at: 1))] = ns.substring(with: range)
                }
                if values["Type"] == "AI", let value = values["Name"], !value.isEmpty { scope.append(value) }
            }
            if !token.hasSuffix("/>") { stack.append(name) }
        }
        return Array(Set(scope)).sorted()
    }
}

// MARK: - XMLAssistantStructuralRepairs.swift
// Conservative XML edits. Every complete proposal must parse before it reaches the UI.
nonisolated enum XMLAssistantStructuralRepairs {
    static func review(_ source: String) -> TriggerRuntimeSchema.DraftReview? {
        let text = source as NSString
        guard let expression = try? NSRegularExpression(pattern: #"<!--[\s\S]*?-->|<!\[CDATA\[[\s\S]*?\]\]>|<\?[\s\S]*?\?>|<(?:[^>"']|"[^"]*"|'[^']*')*>"#) else { return nil }
        let tokens = expression.matches(in: source, range: NSRange(location: 0, length: text.length))
        var stack: [String] = []
        var localRepair: TriggerRuntimeSchema.DraftReview?
        for match in tokens {
            let token = text.substring(with: match.range)
            if token.hasPrefix("<!") || token.hasPrefix("<?") { continue }
            let closing = token.hasPrefix("</")
            let name = String(token.dropFirst(closing ? 2 : 1).prefix { $0.isLetter || $0.isNumber || "_:.-".contains($0) })
            guard !name.isEmpty else { continue }
            if closing {
                if stack.last == name { stack.removeLast() }
                else {
                    var choices: [TriggerRuntimeSchema.DraftSolution] = []
                    if let expected = stack.last {
                        let code = text.replacingCharacters(in: match.range, with: "</\(expected)>")
                        let complete = parses(code)
                        if complete || advancesParser(from: source, to: code) {
                            choices.append(.init(title: "Close \(expected)", explanation: "Replace </\(name)> with </\(expected)> to match the open section. Only this closing tag changes; existing content stays in place. Check that this is the section you intended to close." + (complete ? "" : " This fixes this tag only; another unfinished or invalid section remains later in the draft."), code: code, recommended: complete && distance(name, expected) <= 2))
                        }
                    }
                    let code = removing(match.range, from: source)
                    if parses(code) { choices.append(.init(title: "Remove the unmatched closing tag", explanation: "There is no matching opening tag at this position. Removes only this closing tag; review the diff first.", code: code, recommended: choices.isEmpty)) }
                    if let ancestor = stack.lastIndex(of: name) {
                        let unclosed = Array(stack.dropFirst(ancestor + 1))
                        let suffix = unclosed.reversed().map { "</\($0)>" }.joined(separator: "\n")
                        let closed = text.replacingCharacters(in: NSRange(location: match.range.location, length: 0), with: suffix + "\n")
                        if parses(closed) {
                            choices.append(.init(title: "Close the open section before \(name)", explanation: "Adds the missing closing tags without removing existing content. This fixes XML nesting; Apply XML still checks whether these sections are supported by the game.", code: closed, recommended: true))
                        }
                        if unclosed.count == 1, let open = tokens.last(where: { token in
                            guard token.range.location < match.range.location else { return false }
                            let value = text.substring(with: token.range)
                            let openingName = String(value.dropFirst().prefix { $0.isLetter || $0.isNumber || "_:.-".contains($0) })
                            return !value.hasPrefix("</") && openingName == unclosed[0]
                        }) {
                            let gap = text.substring(with: NSRange(location: NSMaxRange(open.range), length: match.range.location - NSMaxRange(open.range)))
                            let removed = removing(open.range, from: source)
                            if gap.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && parses(removed) {
                                choices = choices.map { var item = $0; item.recommended = false; return item }
                                choices.insert(.init(title: "Remove the stray opening tag", explanation: "This section is empty. Removes its accidental opening tag and keeps the existing parent closing tag and all other content.", code: removed, recommended: true), at: 0)
                            }
                        }
                    }
                    if choices.contains(where: { parses($0.code) }) { choices.removeAll { !parses($0.code) } }
                    if !choices.isEmpty {
                        var review = issue(source, at: match.range.location, title: "Closing tag does not match", explanation: "</\(name)> doesn't match the open XML structure here." + (stack.last.map { " <\($0)> is still open." } ?? ""), choices: choices)
                        review.proposedXML = choices.first(where: { $0.recommended && parses($0.code) })?.code
                        review.issues[0].options = choices.map(\.explanation)
                        if choices.contains(where: { parses($0.code) }) { return review }
                        if localRepair == nil { localRepair = review }
                    }
                }
            } else if !token.hasSuffix("/>") { stack.append(name) }
            if stack.isEmpty {
                let end = NSMaxRange(match.range)
                let prefix = text.substring(to: end)
                let suffix = text.substring(from: end)
                // A completed prefix plus invalid trailing content is not a nesting error.
                if parses(prefix), !TriggerRuntimeSchema.isEmptyXMLDraft(suffix), !parses(source) {
                    let preserved = suffix.replacingOccurrences(of: "--", with: "- -") + (suffix.hasSuffix("-") ? " " : "")
                    let commented = prefix + "\n<!-- Trailing draft kept for reference:\n" + preserved + "\n-->"
                    var choices: [TriggerRuntimeSchema.DraftSolution] = [.init(title: "Keep the completed root", explanation: "The first XML element is complete. Removes the extra fragment after it; inspect the red deleted lines before applying.", code: prefix, recommended: true)]
                    if parses(commented) { choices.append(.init(title: "Keep the extra draft as a comment", explanation: "Preserves the trailing text for reference without making it executable XML. Comment-invalid double hyphens are separated.", code: commented)) }
                    let whitespace = suffix.prefix { $0.isWhitespace }.utf16.count
                    return issue(source, at: end + whitespace, title: "Content after the completed root", explanation: "An XML document has one root element. The first root is already closed, but more markup or text follows it. Choose whether to remove that fragment or retain it as a comment.", choices: choices)
                }
            }
        }
        if let unfinished = XMLAssistantLexing.unfinishedTag(in: source, at: text.length),
           !unfinished.text.hasPrefix("!"), !unfinished.text.hasPrefix("?") {
            var code: String?
            if unfinished.text.hasPrefix("/"), let expected = stack.last {
                let typed = String(unfinished.text.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
                if expected.hasPrefix(typed) || distance(typed, expected) <= 2 {
                    let rest = stack.dropLast().reversed().map { "</\($0)>" }.joined()
                    code = text.substring(to: unfinished.start) + "</\(expected)>" + rest
                }
            } else {
                let name = unfinished.text.prefix { $0.isLetter || $0.isNumber || "_:.-".contains($0) }
                if !name.isEmpty {
                    var quote: Character?
                    for character in unfinished.text {
                        if let current = quote { if character == current { quote = nil } }
                        else if character == "\"" || character == "'" { quote = character }
                    }
                    let endQuote = quote.map(String.init) ?? ""
                    let ending = unfinished.text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("/") && quote == nil ? ">" : "/>"
                    code = source + endQuote + ending + stack.reversed().map { "</\($0)>" }.joined()
                }
            }
            if let code, parses(code) {
                return issue(source, at: unfinished.start, title: "Unfinished XML tag", explanation: "The document ends inside a tag or quoted value. This completes the existing text and closes any enclosing sections; it does not invent attribute values.", choices: [.init(title: "Complete the unfinished XML", explanation: "Keeps the draft text, adds the missing delimiters and closes the open hierarchy. Run Apply XML afterward to check the game-specific fields.", code: code, recommended: true)])
            }
        }
        // Quote bare attribute values, never words found inside an already quoted value.
        var edits: [(NSRange, String)] = []
        for token in tokens {
            let value = text.substring(with: token.range)
            if value.hasPrefix("<!") || value.hasPrefix("<?") || value.hasPrefix("</") { continue }
            let units = Array(value.utf16)
            var quote: UInt16?, index = 0
            while index < units.count {
                let unit = units[index]
                if let current = quote { if unit == current { quote = nil }; index += 1; continue }
                if unit == 34 || unit == 39 { quote = unit; index += 1; continue }
                if unit != 61 { index += 1; continue }
                index += 1
                while index < units.count, isWhitespace(units[index]) { index += 1 }
                guard index < units.count else { break }
                if units[index] == 34 || units[index] == 39 { continue }
                let start = index
                while index < units.count, units[index] != 62, !(units[index] == 47 && index + 1 < units.count && units[index + 1] == 62), !isWhitespace(units[index]) { index += 1 }
                if index > start {
                    let range = NSRange(location: token.range.location + start, length: index - start)
                    let original = text.substring(with: range)
                    edits.append((range, "\"" + original + "\""))
                }
            }
        }
        if let first = edits.first {
            let code = NSMutableString(string: source)
            for (range, replacement) in edits.reversed() { code.replaceCharacters(in: range, with: replacement) }
            if parses(code as String) {
                return issue(source, at: first.0.location, title: "Attribute value needs quotes", explanation: "XML attribute values must be enclosed in matching quotes. This keeps the existing values and adds their quotes.", choices: [.init(title: "Quote the existing attribute values", explanation: "Adds quotes around bare values without inventing or changing them.", code: code as String, recommended: true)])
            }
        }
        var combined: [TriggerRuntimeSchema.DraftSolution] = []
        var firstNestingError = 0
        for removeEmpty in [false, true] {
            if let result = normalizeNesting(source, tokens: tokens, removeEmpty: removeEmpty), !combined.contains(where: { $0.code == result.solution.code }) {
                if combined.isEmpty { firstNestingError = result.offset }
                combined.append(result.solution)
            }
        }
        if !combined.isEmpty {
            return issue(source, at: firstNestingError, title: "Several XML nesting errors", explanation: "More than one closing tag is missing or mismatched. These proposals repair the whole nesting chain together while preserving existing values and content. Review every changed line before applying.", choices: combined)
        }
        return localRepair
    }

    private static func normalizeNesting(_ source: String, tokens: [NSTextCheckingResult], removeEmpty: Bool) -> (solution: TriggerRuntimeSchema.DraftSolution, offset: Int)? {
        let text = source as NSString
        var stack: [(name: String, range: NSRange)] = []
        var edits: [(range: NSRange, replacement: String)] = []
        var uncertain = false
        var nestingErrors = 0
        var firstError: Int?
        for match in tokens {
            let token = text.substring(with: match.range)
            if token.hasPrefix("<!") || token.hasPrefix("<?") { continue }
            let closing = token.hasPrefix("</")
            let name = String(token.dropFirst(closing ? 2 : 1).prefix { $0.isLetter || $0.isNumber || "_:.-".contains($0) })
            guard !name.isEmpty else { continue }
            if !closing { if !token.hasSuffix("/>") { stack.append((name, match.range)) }; continue }
            if stack.last?.name == name { stack.removeLast(); continue }
            if firstError == nil { firstError = match.range.location }
            if let ancestor = stack.lastIndex(where: { $0.name == name }) {
                let unfinished = Array(stack.dropFirst(ancestor + 1))
                nestingErrors += unfinished.count
                var empty = false
                if let first = unfinished.first {
                    let gap = text.substring(with: NSRange(location: first.range.location, length: match.range.location - first.range.location)) as NSString
                    let stripped = NSMutableString(string: gap as String)
                    for open in unfinished.reversed() { stripped.deleteCharacters(in: NSRange(location: open.range.location - first.range.location, length: open.range.length)) }
                    empty = (stripped as String).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
                if removeEmpty && empty {
                    for open in unfinished { edits.append((open.range, "")) }
                    uncertain = true
                } else {
                    edits.append((NSRange(location: match.range.location, length: 0), unfinished.reversed().map { "</\($0.name)>" }.joined()))
                }
                stack.removeSubrange(ancestor...)
            } else if let open = stack.last, distance(name, open.name) <= 2 {
                nestingErrors += 1
                edits.append((match.range, "</\(open.name)>"))
                stack.removeLast()
            } else {
                nestingErrors += 1
                edits.append((match.range, ""))
                uncertain = true
            }
        }
        if !stack.isEmpty { edits.append((NSRange(location: text.length, length: 0), stack.reversed().map { "</\($0.name)>" }.joined())) }
        // EOF-only closure already has a focused, line-formatted proposal.
        guard nestingErrors > 0 else { return nil }
        nestingErrors += stack.count
        // Single errors retain the focused repair choices and whitespace policy below.
        guard nestingErrors > 1, !edits.isEmpty else { return nil }
        let candidate = NSMutableString(string: source)
        for edit in edits.sorted(by: { $0.range.location > $1.range.location }) { candidate.replaceCharacters(in: edit.range, with: edit.replacement) }
        let code = candidate as String
        guard parses(code) else { return nil }
        let solution = TriggerRuntimeSchema.DraftSolution(title: removeEmpty ? "Repair nesting and remove stray empty sections" : "Repair the closing-tag chain", explanation: "Corrects nearby closing names, closes open ancestors in order and removes unmatched closing tags. Existing attribute values are preserved." + (uncertain ? " This includes a removal, so confirm that the removed markup was accidental." : " No content or attribute values are removed."), code: code, recommended: !uncertain && !removeEmpty)
        return (solution, firstError ?? text.length)
    }

    static func parses(_ source: String) -> Bool {
        let parser = XMLParser(data: Data(source.utf8)); parser.shouldResolveExternalEntities = false
        return parser.parse()
    }

    private static func advancesParser(from source: String, to candidate: String) -> Bool {
        func stop(_ text: String) -> (line: Int, column: Int) {
            let parser = XMLParser(data: Data(text.utf8))
            parser.shouldResolveExternalEntities = false
            _ = parser.parse()
            return (parser.lineNumber, parser.columnNumber)
        }
        let before = stop(source), after = stop(candidate)
        return after.line > before.line || (after.line == before.line && after.column > before.column)
    }
    private static func isWhitespace(_ unit: UInt16) -> Bool {
        UnicodeScalar(unit).map { CharacterSet.whitespacesAndNewlines.contains($0) } ?? false
    }
    private static func issue(_ source: String, at offset: Int, title: String, explanation: String, choices: [TriggerRuntimeSchema.DraftSolution]) -> TriggerRuntimeSchema.DraftReview {
        let line = (source as NSString).substring(to: offset).filter { $0 == "\n" }.count + 1
        return .init(messages: ["Line \(line): \(title)"], proposedXML: nil, source: source, issues: [.init(line: line, message: title, explanation: explanation, options: [], solutions: choices)])
    }
    private static func removing(_ range: NSRange, from source: String) -> String {
        let text = source as NSString, line = (source as NSString).lineRange(for: range)
        let remainder = (text.substring(with: line) as NSString).replacingCharacters(in: NSRange(location: range.location - line.location, length: range.length), with: "")
        return text.replacingCharacters(in: remainder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? line : range, with: "")
    }
    private static func distance(_ left: String, _ right: String) -> Int {
        let a = Array(left), b = Array(right)
        guard a.count <= 80, b.count <= 80, abs(a.count - b.count) <= 2 else { return 3 }
        var previous = Array(0...b.count)
        for (i, character) in a.enumerated() {
            var row = [i + 1]
            for (j, other) in b.enumerated() { row.append(min(row[j] + 1, previous[j + 1] + 1, previous[j] + (character == other ? 0 : 1))) }
            previous = row
        }
        return previous[b.count]
    }
}

// MARK: - XMLAssistantTemplateIndex.swift
// A snapshot of real runtime definitions, passed into checks instead of reading files per keypress.
nonisolated struct XMLAssistantTemplateIndex: Hashable, Sendable {
    struct SchemaRule: Hashable, Sendable {
        var root: String
        var path: String
        var whenAttribute = ""
        var whenValue = ""
        var fields: [XMLAssistantContext.ProjectFieldRule]
    }
    struct Entry: Hashable, Sendable {
        var reference: String
        var section: String
        var tags: [String]
        var parameters: [String]
    }
    var entries: [Entry] = []
    var references: [String: [String]] = [:]
    var schemas: [SchemaRule] = []
    func withModels(_ names: [String]) -> Self {
        var snapshot = self
        snapshot.references["Model"] = Array(Set(["Player"] + names.filter { !$0.isEmpty })).sorted()
        return snapshot
    }

    static func parse(_ source: String) -> Self {
        guard XMLAssistantStructuralRepairs.parses(source), let document = try? XMLDocument(xmlString: source, options: [.nodeLoadExternalEntitiesNever]), let root = document.rootElement() else { return .init() }
        if root.name == "XMLAssistantSchema" {
            func safeName(_ value: String) -> Bool {
                value.utf16.count <= 80 && value.range(of: #"^[A-Za-z_][A-Za-z0-9_.:-]*$"#, options: .regularExpression) != nil
            }
            var schemas: [SchemaRule] = []
            for node in root.elements(forName: "Rule").prefix(32) {
                let domain = node.attribute(forName: "Root")?.stringValue ?? ""
                let path = node.attribute(forName: "Path")?.stringValue ?? "."
                let when = node.attribute(forName: "WhenAttribute")?.stringValue ?? ""
                guard safeName(domain), path.utf16.count <= 240,
                      path == "." || (!path.isEmpty && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { safeName(String($0)) }),
                      when.isEmpty || safeName(when) else { continue }
                let fields = node.elements(forName: "Field").prefix(16).compactMap { field -> XMLAssistantContext.ProjectFieldRule? in
                    let key = field.attribute(forName: "Name")?.stringValue ?? ""
                    let kind = field.attribute(forName: "Kind")?.stringValue ?? "text"
                    let reference = field.attribute(forName: "Reference")?.stringValue ?? ""
                    guard safeName(key), ["text", "integer", "number", "enum", "reference"].contains(kind),
                          kind != "reference" || safeName(reference) else { return nil }
                    let values = (field.attribute(forName: "Values")?.stringValue ?? "").split(separator: "|").prefix(16).map(String.init).filter { $0.utf16.count <= 120 }
                    return .init(key: key, kind: kind, required: field.attribute(forName: "Required")?.stringValue == "1", values: values, reference: reference)
                }
                schemas.append(.init(root: domain, path: path, whenAttribute: when, whenValue: node.attribute(forName: "WhenValue")?.stringValue ?? "", fields: fields))
            }
            return .init(schemas: schemas)
        }
        guard root.name == "Templates" else { return .init() }
        var entries: [Entry] = []
        for template in document.rootElement()?.elements(forName: "Template") ?? [] {
            guard let name = template.attribute(forName: "Name")?.stringValue, !name.isEmpty else { continue }
            for loop in template.elements(forName: "Loop") {
                guard let loopName = loop.attribute(forName: "Name")?.stringValue, !loopName.isEmpty else { continue }
                let parameters = loop.elements(forName: "Using").flatMap { $0.elements(forName: "Variable") }.compactMap { $0.attribute(forName: "Name")?.stringValue }
                for section in ["Events", "Conditions", "Actions"] {
                    for content in loop.elements(forName: section) where (content.children ?? []).contains(where: { $0.kind == .element }) || content.attribute(forName: "Template") != nil {
                        let tags = (content.children ?? []).filter { $0.kind == .element }.compactMap(\.name)
                        entries.append(.init(reference: name + "." + loopName, section: section, tags: tags, parameters: parameters))
                    }
                }
            }
        }
        return .init(entries: entries)
    }

    static func load(roots: [URL], packageRoots: [URL] = []) -> Self {
        var values: [Entry] = [], seen: Set<String> = []
        var references: [String: [String]] = [:]
        var schemas: [SchemaRule] = []
        var remainingFiles = 128
        for root in roots {
            let scoped = root.startAccessingSecurityScopedResource()
            defer { if scoped { root.stopAccessingSecurityScopedResource() } }
            let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])) ?? []
            for file in files.filter({ $0.pathExtension.lowercased() == "xml" }).sorted(by: { $0.path < $1.path }) {
                guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 5_000_000,
                      let source = try? String(contentsOf: file, encoding: .utf8) else { continue }
                let parsed = parse(source)
                for entry in parsed.entries where seen.insert(entry.section + ":" + entry.reference).inserted { values.append(entry) }
                if schemas.count < 32 { schemas += parsed.schemas.prefix(32 - schemas.count) }
            }
            let library = root.deletingLastPathComponent().appendingPathComponent("libraries")
            let libraryFiles = (try? FileManager.default.contentsOfDirectory(at: library, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])) ?? []
            for file in libraryFiles.filter({ $0.pathExtension.lowercased() == "xml" }).sorted(by: { $0.path < $1.path }).prefix(remainingFiles) {
                remainingFiles -= 1
                guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 5_000_000,
                      let data = try? Data(contentsOf: file),
                      let document = try? XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever]) else { continue }
                let objects = ((try? document.nodes(forXPath: "/Root/Objects/Object/@Name")) ?? []).compactMap(\.stringValue)
                references["ObjectClass:" + file.lastPathComponent, default: []] += objects
                references["ObjectClass", default: []] += objects
                if !objects.isEmpty { references["ObjectFile", default: []].append(file.lastPathComponent) }
                if file.lastPathComponent == "moves_new.xml" {
                    references["Animation", default: []] += ((try? document.nodes(forXPath: "//*[@AreaName]/@AreaName")) ?? []).compactMap(\.stringValue)
                    references["AnimationMove", default: []] += ((try? document.nodes(forXPath: "//*[@FileName]")) ?? []).compactMap(\.name)
                }
            }
        }
        // Package namespaces are deliberately not runtime character/animator namespaces.
        let inferred = roots.flatMap { root -> [URL] in
            let base = root.deletingLastPathComponent()
            return [base.appendingPathComponent("custom_models"), base.appendingPathComponent("custom_tricks")]
        }
        var visited: Set<String> = []
        var remainingEntries = 2048, remainingPackages = 128, remainingFileEntries = 2048
        for root in packageRoots + inferred where visited.insert(root.standardizedFileURL.path).inserted {
            let scoped = root.startAccessingSecurityScopedResource()
            defer { if scoped { root.stopAccessingSecurityScopedResource() } }
            guard remainingEntries > 0, remainingPackages > 0,
                  let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { continue }
            for case let file as URL in files {
                guard remainingEntries > 0, remainingPackages > 0 else { break }
                remainingEntries -= 1
                let properties = try? file.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .fileSizeKey])
                if properties?.isSymbolicLink == true { files.skipDescendants(); continue }
                if file.pathComponents.count - root.pathComponents.count > 6 { files.skipDescendants(); continue }
                guard ["manifest.xml", "trick.xml"].contains(file.lastPathComponent),
                      let size = properties?.fileSize, size <= 5_000_000 else { continue }
                remainingPackages -= 1
                guard let data = try? Data(contentsOf: file), let document = try? XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever]),
                      let node = document.rootElement() else { continue }
                let package = file.deletingLastPathComponent()
                var modelFiles: [String] = [], trickFiles: [String] = []
                if let contents = FileManager.default.enumerator(at: package, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey], options: [.skipsHiddenFiles]) {
                    var localEntries = 256
                    let prefix = package.standardizedFileURL.path + "/"
                    for case let payload as URL in contents {
                        guard localEntries > 0, remainingFileEntries > 0 else { break }
                        localEntries -= 1; remainingFileEntries -= 1
                        let values = try? payload.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
                        if values?.isSymbolicLink == true { contents.skipDescendants(); continue }
                        if payload.pathComponents.count - package.pathComponents.count > 6 { contents.skipDescendants(); continue }
                        let path = payload.standardizedFileURL.path
                        guard values?.isRegularFile == true, path.hasPrefix(prefix) else { continue }
                        let relative = String(path.dropFirst(prefix.count))
                        if payload.pathExtension.lowercased() == "xml", payload.lastPathComponent != "manifest.xml" { modelFiles.append(relative) }
                        if payload.pathExtension.lowercased() == "bytes" { trickFiles.append(relative) }
                    }
                }
                if node.name == "CustomModel", let id = node.attribute(forName: "ID")?.stringValue, !id.isEmpty {
                    references["ModelPackage", default: []].append("custom:" + id)
                    references["ModelFile:" + id, default: []] += modelFiles
                } else if node.name == "CustomTrick", let name = node.attribute(forName: "Name")?.stringValue, !name.isEmpty {
                    references["Animation", default: []].append(name)
                    references["AnimationMove", default: []].append(name)
                    references["TrickFile:" + name, default: []] += trickFiles
                }
            }
        }
        return .init(entries: values, references: references.mapValues { Array(Set($0)).sorted() }, schemas: schemas)
    }

    func candidates(section: String, query: String = "", nearbyTags: Set<String> = []) -> [Entry] {
        entries.filter { $0.section == section && (query.isEmpty || $0.reference.lowercased().contains(query.lowercased())) }.sorted {
            let left = Set($0.tags).intersection(nearbyTags).count, right = Set($1.tags).intersection(nearbyTags).count
            return left == right ? $0.reference < $1.reference : left > right
        }
    }
}

nonisolated struct XMLAssistantDraftRequest: Hashable {
    var source: String
    var templates: XMLAssistantTemplateIndex
    var scopeID: String = ""
}


nonisolated private final class TriggerXMLLocations: NSObject, XMLParserDelegate {
    struct Element { var name: String; var parent: String?; var line: Int }
    var elements: [Element] = []
    var stack: [String] = []
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        elements.append(.init(name: name, parent: stack.last, line: parser.lineNumber))
        stack.append(name)
    }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if !stack.isEmpty { stack.removeLast() }
    }
}

// Draft checks and repair proposals stay separate from the game's runtime catalogue.
extension TriggerRuntimeSchema {
    nonisolated private static func runtimeSectionPath(_ section: String) -> String {
        // Only traverse built-in Operator chains. Custom containers remain opaque.
        section == "Conditions" ? "(//Conditions/* | //Conditions//Operator/*[count(ancestor::Operator) = count(ancestor::*[ancestor::Conditions])])" : "//\(section)/*"
    }
    nonisolated static func isEmptyXMLDraft(_ source: String) -> Bool {
        if source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        guard let regex = try? NSRegularExpression(pattern: #"\A\s*(?:<!--[\s\S]*?-->\s*)+\z"#),
              regex.firstMatch(in: source, range: NSRange(location: 0, length: source.utf16.count)) != nil else { return false }
        let parser = XMLParser(data: Data(("<Draft>" + source + "</Draft>").utf8))
        parser.shouldResolveExternalEntities = false
        return parser.parse()
    }
    nonisolated struct DraftSolution: Sendable, Equatable {
        var title: String
        var explanation: String
        var code: String
        var recommended: Bool = false
        var contextualSuggestion: Bool = false
        // nil means malformed/unchecked; zero means current catalogue checks pass.
        var remainingIssues: Int? = nil
    }
    nonisolated struct DraftIssue: Sendable, Equatable {
        var line: Int
        var message: String
        var explanation: String
        var options: [String]
        var solutions: [DraftSolution] = []
        var intent: DraftIntent? = nil
    }
    nonisolated struct DraftIntent: Sendable, Equatable {
        var xpath: String
        var keys: [String]
        var choices: [String: [String]]
        func code(in source: String, values: [String: String]) throws -> String {
            let document = try XMLDocument(xmlString: source, options: [.nodeLoadExternalEntitiesNever])
            let targets = try document.nodes(forXPath: xpath)
            guard targets.count == 1, let target = targets.first as? XMLElement,
                  keys.allSatisfy({ values[$0]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }) else {
                throw NSError(domain: "XMLAssistant", code: 1, userInfo: [NSLocalizedDescriptionKey: "Choose a value for every missing field before previewing."])
            }
            for key in keys {
                target.removeAttribute(forName: key)
                target.addAttribute(XMLNode.attribute(withName: key, stringValue: values[key]!) as! XMLNode)
            }
            return document.xmlString(options: [.nodePrettyPrint])
        }
    }
    nonisolated struct DraftReview: Sendable, Equatable {
        var messages: [String]
        var proposedXML: String?
        var source: String = ""
        var issues: [DraftIssue] = []
    }

    nonisolated static func reviewDraft(_ source: String, catalogues: [String: [TriggerRuntimeItem]], requiresTriggerRoot: Bool = true, templates: XMLAssistantTemplateIndex = .init(), previousSource: String? = nil) -> DraftReview {
        // Keep large drafts editable: strict structure checks continue, but repair search
        // and cloning are intentionally bounded rather than stalling every keypress.
        if source.utf16.count > 200_000 {
            let parser = XMLParser(data: Data(source.utf8))
            parser.shouldResolveExternalEntities = false
            if parser.parse() { return .init(messages: [], proposedXML: nil, source: source) }
            let line = max(1, parser.lineNumber)
            return .init(messages: ["Line \(line): XML syntax error"], proposedXML: nil, source: source,
                issues: [.init(line: line, message: "XML syntax error in a large draft", explanation: "The XML parser found broken structure. Detailed repair search is limited to 200,000 UTF-16 units to keep typing responsive. Edit a smaller selected object or section to get contextual fixes. Game catalogue checks were not run for this large draft.", options: [parser.parserError?.localizedDescription ?? "Check the XML structure near this line."])])
        }
        var review = reviewDraftCore(source, catalogues: catalogues, requiresTriggerRoot: requiresTriggerRoot, templates: templates)
        if !XMLAssistantStructuralRepairs.parses(source), let normalized = XMLAssistantContext.normalizingLexemes(source) {
            var combined: [DraftSolution] = []
            if XMLAssistantStructuralRepairs.parses(normalized) {
                combined.append(.init(title: "Repair XML delimiters and escaping", explanation: "Quotes bare attribute values and escapes literal ampersands. Existing quoted values, comments and CDATA stay intact; review the diff.", code: normalized, recommended: true))
            } else {
                let next = reviewDraftCore(normalized, catalogues: catalogues, requiresTriggerRoot: requiresTriggerRoot, templates: templates)
                for solution in next.issues.flatMap(\.solutions).prefix(8) where XMLAssistantStructuralRepairs.parses(solution.code) {
                    combined.append(.init(title: "Repair attributes and structure: " + solution.title,
                        explanation: "First quotes bare values and escapes literal ampersands, then applies the structural edit. " + solution.explanation,
                        code: solution.code, recommended: solution.recommended))
                }
            }
            if !combined.isEmpty, !review.issues.isEmpty { review.issues[0].solutions += combined }
        }
        if !review.issues.isEmpty, let previousSource,
           let code = XMLAssistantContext.restoringErasedValues(source: source, previous: previousSource) {
            review.issues[0].solutions.insert(.init(title: "Restore the previous values", explanation: "Restores values from this editor's last checked draft. All other markup and values must still match. Choose this only if erasing them was accidental; nothing is restored automatically.", code: code), at: 0)
        }
        var budget = 32
        var offeredBudget = 32
        for index in review.issues.indices {
            var seen: Set<String> = []
            review.issues[index].solutions = Array(review.issues[index].solutions.filter { $0.code != source && seen.insert($0.code).inserted }.prefix(offeredBudget))
            offeredBudget -= review.issues[index].solutions.count
            for candidate in review.issues[index].solutions.indices {
                var solution = review.issues[index].solutions[candidate]
                if budget > 0, solution.code.utf16.count <= 200_000, XMLAssistantStructuralRepairs.parses(solution.code) {
                    budget -= 1
                    let checked = reviewDraftCore(solution.code, catalogues: catalogues, requiresTriggerRoot: requiresTriggerRoot, templates: templates, diagnosticsOnly: true)
                    solution.remainingIssues = checked.issues.count
                } else {
                    solution.recommended = false
                }
                review.issues[index].solutions[candidate] = solution
            }
            let recommended = review.issues[index].solutions.filter(\.recommended)
            if recommended.count > 1 {
                for candidate in review.issues[index].solutions.indices { review.issues[index].solutions[candidate].recommended = false }
            }
            if !review.issues[index].solutions.contains(where: \.recommended),
               review.issues[index].intent?.keys.count == 1,
               let best = review.issues[index].solutions.firstIndex(where: {
                   $0.contextualSuggestion && ($0.remainingIssues.map { $0 < review.issues.count } ?? false)
               }) {
                // Candidate generation orders scoped evidence before weaker alternatives.
                // This recommends a checked suggestion, not an inferred gameplay intention.
                review.issues[index].solutions[best].recommended = true
                review.issues[index].solutions[best].explanation += " Recommended as the first context-supported choice that reduces the checks, not a guarantee of intended gameplay. Other errors do not prevent this local recommendation. Review the alternatives before applying."
            }
        }
        if offeredBudget > 0, !review.issues.isEmpty,
           let combined = XMLAssistantContext.combinedLiteralCorrections(source, templates: templates) {
            let checked = diagnosticReview(combined, catalogues: catalogues, requiresTriggerRoot: requiresTriggerRoot, templates: templates)
            let solution = DraftSolution(title: "Apply compatible field corrections", explanation: "Combines supported literal capitalization/whitespace corrections on separate fields. Does not choose targets, timing values or missing gameplay intent. Review all changed lines before applying.", code: combined, remainingIssues: checked.issues.count)
            review.issues[0].solutions.append(solution)
            offeredBudget -= 1
        }
        if offeredBudget > 0, !review.issues.isEmpty,
           let layout = XMLAssistantContext.compatibleSectionLayout(source) {
            let code = XMLAssistantContext.combinedLiteralCorrections(layout, templates: templates) ?? layout
            let checked = diagnosticReview(code, catalogues: catalogues, requiresTriggerRoot: requiresTriggerRoot, templates: templates)
            review.issues[0].solutions.append(.init(title: "Repair compatible section layout", explanation: "Moves Loop out of Init, promotes nested sections, and combines attribute-free duplicate sections in source order. Statements, comments and attributes are preserved. Combining sections can enable previously ignored behavior; review the full diff. Compatible literal spelling corrections may be included; targets and arbitrary values are not guessed.", code: code, remainingIssues: checked.issues.count))
        }
        return review
    }

    nonisolated private static func reviewDraftCore(_ source: String, catalogues: [String: [TriggerRuntimeItem]], requiresTriggerRoot: Bool, templates: XMLAssistantTemplateIndex, diagnosticsOnly: Bool = false) -> DraftReview {
        if diagnosticsOnly { return diagnosticReview(source, catalogues: catalogues, requiresTriggerRoot: requiresTriggerRoot, templates: templates) }
        if isEmptyXMLDraft(source) { return .init(messages: [], proposedXML: nil, source: source) }
        if let declaration = try? NSRegularExpression(pattern: #"\A\s*<\?xml\s[\s\S]*?\?>\s*\z"#), declaration.firstMatch(in: source, range: NSRange(location: 0, length: source.utf16.count)) != nil {
            let rootName = requiresTriggerRoot ? "Trigger" : "Root"
            let bare = XMLElement(name: rootName)
            let structured = XMLElement(name: rootName)
            if requiresTriggerRoot { structured.addChild(XMLElement(name: "Content")) }
            let minimal = source.trimmingCharacters(in: .whitespacesAndNewlines) + "\n" + bare.xmlString
            let withContent = source.trimmingCharacters(in: .whitespacesAndNewlines) + "\n" + structured.xmlString
            if requiresTriggerRoot && XMLAssistantStructuralRepairs.parses(withContent) {
                let fixes = [DraftSolution(title: "Start a Trigger document", explanation: "Keeps your declaration and inserts a Trigger root with an empty Content section. Add your events and actions next; no gameplay behavior is guessed.", code: withContent, recommended: true), DraftSolution(title: "Insert only the root element", explanation: "Keeps your declaration and adds an empty Trigger root so you can write its structure manually.", code: minimal)]
                return .init(messages: ["Line 1: XML declaration needs a document root"], proposedXML: withContent, source: source, issues: [.init(line: 1, message: "Missing document root", explanation: "The declaration describes the XML file, but it is not the document itself. Trigger Designer needs a Trigger element after it.", options: [], solutions: fixes)])
            }
        }
        let locator = TriggerXMLLocations()
        let parser = XMLParser(data: Data(source.utf8))
        parser.shouldResolveExternalEntities = false
        parser.delegate = locator
        guard parser.parse() else {
            if let repair = XMLAssistantLexing.duplicateAttributeRepair(source) { return repair }
            if let repair = XMLAssistantLexing.escapedAmpersandRepair(source) { return repair }
            if let repair = XMLAssistantStructuralRepairs.review(source) { return repair }
            if let repair = syntaxRepair(source) { return repair }
            let line = max(1, parser.lineNumber)
            let message = parser.parserError?.localizedDescription ?? "XML could not be parsed."
            let issue = DraftIssue(line: line, message: "XML syntax error", explanation: "The XML structure could not be read. Look for an unfinished tag, a missing closing tag, or an attribute without matching quotes near line \(line). The parser stopped here; the mistake may start earlier.",
                options: ["Check quotes and closing tags on this line and the line before it.", "Use Revert to restore the last visual trigger definition if you want to start over."])
            return .init(messages: ["Line \(line): \(message)"], proposedXML: nil, source: source, issues: [issue])
        }
        do {
            var messages: [String] = []
            var issues: [DraftIssue] = []
            var remainingCandidateBudget = 32
            // No single field may consume the whole draft's search allowance.
            var candidateBudget: Int { min(3, remainingCandidateBudget) }
            func report(_ message: String, line: Int, explanation: String, options: [String], solutions: [DraftSolution] = [], intent: DraftIntent? = nil) {
                let accepted = Array(solutions.prefix(candidateBudget))
                remainingCandidateBudget -= accepted.count
                messages.append("Line \(line): \(message)")
                issues.append(.init(line: line, message: message, explanation: explanation, options: options, solutions: accepted, intent: intent))
            }
            let document = try XMLDocument(xmlString: source, options: [.nodeLoadExternalEntitiesNever])
            if requiresTriggerRoot && document.rootElement()?.name != "Trigger" {
                report("The root element must be Trigger.", line: locator.elements.first?.line ?? 1,
                    explanation: "This tool edits one trigger, not a whole room or library.", options: ["Wrap its Content in a Trigger element.", "Open room XML in the room editor instead."])
            }
            var changed = false
            let sourceElements = try document.nodes(forXPath: "//*")
            let sourceOrdinals = Dictionary(uniqueKeysWithValues: sourceElements.enumerated().map { (ObjectIdentifier($0.element), $0.offset) })
            for (loopIndex, node) in (try document.nodes(forXPath: "//Loop")).enumerated() {
                guard let loop = node as? XMLElement else { continue }
                for name in ["Events", "Conditions", "Actions"] {
                    let sections = (loop.children ?? []).compactMap { $0 as? XMLElement }.filter { $0.name == name }
                    guard sections.count > 1 else { continue }
                    let ordinal = try document.nodes(forXPath: "//*").firstIndex { $0 === sections[1] }
                    let line = ordinal.flatMap { locator.elements.indices.contains($0) ? locator.elements[$0].line : nil } ?? 1
                    var fixes: [DraftSolution] = []
                    // Attribute-bearing containers may be extensions with different semantics.
                    if !diagnosticsOnly, sections.allSatisfy({ ($0.attributes ?? []).isEmpty }) {
                        for merge in [true, false].prefix(candidateBudget) {
                            let copy = try XMLDocument(xmlString: source, options: [.nodeLoadExternalEntitiesNever])
                            let targetLoop = try copy.nodes(forXPath: "//Loop")[loopIndex] as! XMLElement
                            let targets = (targetLoop.children ?? []).compactMap { $0 as? XMLElement }.filter { $0.name == name }
                            for duplicate in targets.dropFirst() {
                                if merge {
                                    for child in duplicate.children ?? [] { child.detach(); targets[0].addChild(child) }
                                }
                                duplicate.detach()
                            }
                            fixes.append(.init(title: merge ? "Combine \(name) sections" : "Keep only the first \(name) section",
                                explanation: merge ? "Preserves all statements and comments in section order. The game normally reads the first section only, so this can enable previously ignored behavior. Review before applying." : "Keeps the section the runtime reads and removes later duplicate sections. The preview shows all deleted code; choose this only if those duplicates were accidental.",
                                code: copy.xmlString(options: [.nodePrettyPrint]), recommended: merge))
                        }
                    }
                    report("Loop has duplicate \(name) sections.", line: line, explanation: "TriggerRunnerLoop reads one section of each kind. Later duplicate sections may be ignored. Attribute-bearing custom containers require manual review rather than an automatic merge.", options: [], solutions: fixes)
                }
            }
            for section in catalogues.keys.sorted() {
                if candidateBudget == 0 { break }
                let catalogue = catalogues[section] ?? []
                let sectionXPath = runtimeSectionPath(section)
                for (position, node) in (try document.nodes(forXPath: sectionXPath)).enumerated() {
                    if candidateBudget == 0 { break }
                    guard let element = node as? XMLElement else { continue }
                    let line = sourceOrdinals[ObjectIdentifier(element)].flatMap { locator.elements.indices.contains($0) ? locator.elements[$0].line : nil } ?? 1
                    guard let item = catalogue.first(where: { $0.xmlName.lowercased() == element.name?.lowercased() }) else {
                        let loopSections = ["Events", "Conditions", "Actions"]
                        if loopSections.contains(section), loopSections.contains(element.name ?? ""),
                           element.parent?.parent?.name == "Loop" {
                            var fixes: [DraftSolution] = []
                            if !diagnosticsOnly {
                                let copy = try XMLDocument(xmlString: source, options: [.nodeLoadExternalEntitiesNever])
                                if let misplaced = try copy.nodes(forXPath: sectionXPath)[position] as? XMLElement,
                                   let wrapper = misplaced.parent as? XMLElement,
                                   let loop = wrapper.parent as? XMLElement {
                                    // Promote section containers, never their statements. Preserve
                                    // source order and leave extension tags and ordinary conditions intact.
                                    var scan = 0
                                    while scan < loop.childCount {
                                        if let sectionNode = loop.child(at: scan) as? XMLElement,
                                           loopSections.contains(sectionNode.name ?? "") {
                                            let nested = (sectionNode.children ?? []).compactMap { $0 as? XMLElement }
                                                .filter { loopSections.contains($0.name ?? "") }
                                            var insertion = scan + 1
                                            for child in nested {
                                                child.detach()
                                                loop.insertChild(child, at: insertion)
                                                insertion += 1
                                            }
                                        }
                                        scan += 1
                                    }
                                    for empty in (loop.children ?? []).compactMap({ $0 as? XMLElement }) where loopSections.contains(empty.name ?? "") {
                                        let siblings = (loop.children ?? []).filter { $0.kind == .element && $0.name == empty.name }
                                        if siblings.count > 1, (empty.attributes ?? []).isEmpty,
                                           (empty.children ?? []).allSatisfy({ $0.kind == .text && ($0.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                                            empty.detach()
                                        }
                                    }
                                    fixes = [.init(title: "Repair Loop sections", explanation: "Moves the nested Events, Conditions or Actions containers beside their enclosing section under Loop. All statements, attributes and their order inside each section are preserved. Review the preview before applying.", code: copy.xmlString(options: [.nodePrettyPrint]), recommended: true)]
                                }
                            }
                            report("\(element.name ?? "Section") belongs directly inside Loop.", line: line,
                                   explanation: "Events, Conditions and Actions are sibling Loop sections, not statements inside one another. Their contents do not need renaming.",
                                   options: [], solutions: fixes)
                            continue
                        }
                        if section == "Init", element.name == "Loop", element.parent?.parent?.name == "Content" {
                            let copy = try XMLDocument(xmlString: source, options: [.nodeLoadExternalEntitiesNever])
                            if let loop = try copy.nodes(forXPath: "//Init/*")[position] as? XMLElement,
                               let initElement = loop.parent as? XMLElement,
                               let content = initElement.parent as? XMLElement {
                                loop.detach()
                                let insertion = content.children?.firstIndex(where: { $0 === initElement }).map { $0 + 1 } ?? content.childCount
                                content.insertChild(loop, at: insertion)
                                let code = copy.xmlString(options: [.nodePrettyPrint])
                                let check = XMLParser(data: Data(code.utf8))
                                check.shouldResolveExternalEntities = false
                                if check.parse() {
                                    report("Loop belongs beside Init, not inside it.", line: line,
                                        explanation: "Init sets starting variables. Loop contains events and actions, so it must be a direct child of Content. This often happens when </Init> is in the wrong place.",
                                        options: [], solutions: [.init(title: "Move Loop out of Init", explanation: "Keeps the variables and the entire loop intact, and places Loop immediately after Init. Review the code before applying.", code: code, recommended: true)])
                                    continue
                                }
                            }
                        }
                        let name = element.name ?? ""
                        if loopSections.contains(section), element.parent?.parent?.name == "Loop" {
                            let destinations = loopSections.filter { destination in
                                destination != section && (catalogues[destination] ?? []).contains { $0.xmlName == name }
                            }
                            if !destinations.isEmpty {
                                var moves: [DraftSolution] = []
                                if !diagnosticsOnly {
                                    for destination in destinations.prefix(candidateBudget) {
                                        let copy = try XMLDocument(xmlString: source, options: [.nodeLoadExternalEntitiesNever])
                                        guard let target = try copy.nodes(forXPath: sectionXPath)[position] as? XMLElement,
                                              let wrapper = target.parent as? XMLElement,
                                              let loop = wrapper.parent as? XMLElement else { continue }
                                        let containers = (loop.children ?? []).compactMap { $0 as? XMLElement }.filter { $0.name == destination }
                                        // Multiple destination containers have ambiguous ordering.
                                        guard containers.count <= 1 else { continue }
                                        let container: XMLElement
                                        if let existing = containers.first { container = existing }
                                        else {
                                            container = XMLElement(name: destination)
                                            loop.addChild(container)
                                        }
                                        target.detach()
                                        container.addChild(target)
                                        moves.append(.init(title: "Move \(name) to \(destination)", explanation: "The current schema supports \(name) in \(destination), not \(section). Keeps its attributes and children and appends it to that section; existing statements retain their order. Review execution order before applying.", code: copy.xmlString(options: [.nodePrettyPrint]), recommended: destinations.count == 1))
                                    }
                                }
                                report("\(name) is in the wrong Loop section.", line: line,
                                       explanation: "The schema supports this tag in \(destinations.joined(separator: " or ")). Move it rather than rename it; when multiple destinations are supported, choose the intended role.", options: [], solutions: moves)
                                continue
                            }
                        }
                        var nearby: [(TriggerRuntimeItem, Int)] = []
                        for candidate in catalogue {
                            let distance = spellingDistance(name, candidate.xmlName)
                            if distance <= 2 { nearby.append((candidate, distance)) }
                        }
                        nearby.sort { left, right in
                            if left.1 == right.1 { return left.0.xmlName < right.0.xmlName }
                            return left.1 < right.1
                        }
                        var suggestions: [DraftSolution] = []
                        for (candidate, distance) in nearby.prefix(min(3, candidateBudget)) {
                            let copy = try XMLDocument(xmlString: source, options: [.nodeLoadExternalEntitiesNever])
                            let target = try copy.nodes(forXPath: sectionXPath)[position] as? XMLElement
                            target?.name = candidate.xmlName
                            let unique = nearby.filter { $0.1 == distance }.count == 1
                            let solution = DraftSolution(title: "Use \(candidate.xmlName)", explanation: "This is a nearby supported \(section.lowercased()) tag. Existing attributes and children are kept; check that this is the behavior you intended.", code: copy.xmlString(options: [.nodePrettyPrint]), recommended: distance == 1 && unique)
                            suggestions.append(solution)
                        }
                        report("Unknown \(section) tag: \(element.name ?? "?").", line: line,
                            explanation: "This tag isn't in the game's known \(section.lowercased()) list. It may be misspelled or in the wrong section.",
                            options: ["Use XML Assistant here to choose a supported tag.", "If this is a game extension, verify its name and section against the game code before keeping it."], solutions: suggestions); continue
                    }
                    if element.name != item.xmlName {
                        let copy = try XMLDocument(xmlString: source, options: [.nodeLoadExternalEntitiesNever])
                        let target = try copy.nodes(forXPath: sectionXPath)[position] as? XMLElement
                        target?.name = item.xmlName
                        report("Use \(item.xmlName), not \(element.name ?? "?").", line: line,
                            explanation: "XML tag names are case-sensitive. The game expects \(item.xmlName).", options: ["Change the opening and closing tag to \(item.xmlName)."], solutions: [.init(title: "Correct tag capitalization", explanation: "Changes only this tag's spelling to the game's supported name.", code: copy.xmlString(options: [.nodePrettyPrint]), recommended: true)])
                        element.name = item.xmlName; changed = true
                    }
                    for problem in XMLAssistantContext.fieldProblems(element, section: section) {
                        var fixes: [DraftSolution] = []
                        if !diagnosticsOnly {
                            for value in problem.choices.prefix(candidateBudget) {
                                let copy = try XMLDocument(xmlString: source, options: [.nodeLoadExternalEntitiesNever])
                                let target = try copy.nodes(forXPath: sectionXPath)[position] as? XMLElement
                                target?.attribute(forName: problem.key)?.stringValue = value
                                let explanation = value == problem.correction
                                    ? "Corrects the spelling or capitalization to the runtime-supported value. Only \(problem.key) changes; the existing meaning is preserved."
                                    : "Uses a supported value or a declared numeric variable. This is a gameplay choice, not inferred intent; review before applying."
                                fixes.append(.init(title: "Set \(problem.key) to \(value)", explanation: explanation, code: copy.xmlString(options: [.nodePrettyPrint]), recommended: value == problem.correction))
                            }
                        }
                        report("\(item.xmlName).\(problem.key) has an unsupported literal.", line: line,
                               explanation: "The game reads this field as \(problem.expected). Runtime variable expressions and unknown extension fields are left alone.", options: [], solutions: fixes,
                               intent: .init(xpath: "(\(sectionXPath))[\(position + 1)]", keys: [problem.key], choices: [problem.key: problem.choices]))
                    }
                    if section == "Conditions", ["Equal", "Greater", "Less", "GreaterEqual", "LessEqual"].contains(item.xmlName) {
                        var scope: XMLNode = element
                        while scope.name != "Trigger", let parent = scope.parent { scope = parent }
                        // Template expansion may introduce declarations not present in this draft.
                        let templateNodes = (try? scope.nodes(forXPath: ".//*[@Template]")) ?? []
                        if scope.name == "Trigger", templateNodes.isEmpty {
                            let variables = XMLAssistantContext.declaredVariables(for: element)
                            let known = Set(XMLAssistantContext.declaredVariables(for: element, includeRepeated: true).map(\.reference)).union(["_$ActionID", "_$WaypointKey", "_$Model", "_$Key"])
                            for operand in ["Value1", "Value2"] {
                                guard let value = element.attribute(forName: operand)?.stringValue,
                                      value.hasPrefix("_"), !known.contains(value) else { continue }
                                let alternatives = variables.filter(\.numeric).sorted {
                                    spellingDistance(value, $0.reference) < spellingDistance(value, $1.reference)
                                }
                                var replacements: [DraftSolution] = []
                                for alternative in alternatives.prefix(min(8, candidateBudget)) {
                                    let copy = try XMLDocument(xmlString: source, options: [.nodeLoadExternalEntitiesNever])
                                    let target = try copy.nodes(forXPath: sectionXPath)[position] as? XMLElement
                                    target?.attribute(forName: operand)?.stringValue = alternative.reference
                                    let distance = spellingDistance(value, alternative.reference)
                                    let unique = alternatives.filter { spellingDistance(value, $0.reference) == distance }.count == 1
                                    replacements.append(.init(title: "Use \(alternative.reference)", explanation: "This numeric variable is declared in the same trigger. Changes only \(operand); verify that it is the intended quantity. Other operands remain unchanged.", code: copy.xmlString(options: [.nodePrettyPrint]), recommended: distance == 1 && unique))
                                }
                                report("Unknown variable reference: \(value).", line: line,
                                    explanation: "Comparison values beginning with _ are variable lookups, not text literals. No matching declaration was found in this trigger. Template-backed scopes are not guessed.",
                                    options: ["Declare the intended variable in Init, or choose an existing scoped variable."], solutions: replacements)
                            }
                        }
                    }
                    let requiredFields = XMLAssistantContext.requiredFields(element, section: section, base: item.requiredAttributes)
                    for key in requiredFields {
                        if candidateBudget == 0 { break }
                        guard element.attribute(forName: key)?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false else { continue }
                        if element.attribute(forName: key) == nil {
                            let known = Set(requiredFields + Array(item.suggestedAttributes.keys))
                            let nearby = (element.attributes ?? []).filter { attribute in
                                guard let name = attribute.name else { return false }
                                return !known.contains(name) && spellingDistance(name, key) <= 2
                            }
                            if nearby.count == 1, let attribute = nearby.first, let actualName = attribute.name,
                               attribute.stringValue?.isEmpty == false {
                                let destinations = known.filter { spellingDistance(actualName, $0) <= 2 }
                                if destinations.count == 1 {
                                    let copy = try XMLDocument(xmlString: source, options: [.nodeLoadExternalEntitiesNever])
                                    let target = try copy.nodes(forXPath: sectionXPath)[position] as? XMLElement
                                    target?.attribute(forName: actualName)?.name = key
                                    report("Use \(key), not \(actualName).", line: line,
                                        explanation: "An existing attribute has a nearby spelling and already contains a value. Review this rename before substituting a default.", options: [],
                                        solutions: [.init(title: "Rename \(actualName) to \(key)", explanation: "Preserves your existing value. This is the only nearby known attribute name for this tag; extension attributes should be kept if intentional.", code: copy.xmlString(options: [.nodePrettyPrint]), recommended: actualName.lowercased() == key.lowercased())])
                                    continue
                                }
                            }
                        }
                        if element.attribute(forName: key) == nil,
                           let wrongCase = element.attributes?.first(where: { $0.name?.lowercased() == key.lowercased() }),
                           let actualName = wrongCase.name {
                            let copy = try XMLDocument(xmlString: source, options: [.nodeLoadExternalEntitiesNever])
                            let target = try copy.nodes(forXPath: sectionXPath)[position] as? XMLElement
                            target?.attribute(forName: actualName)?.name = key
                            report("Use \(key), not \(actualName).", line: line,
                                explanation: "Attribute names are case-sensitive. Your value is already present, but the game can't read it under the wrong spelling.", options: [],
                                solutions: [.init(title: "Correct attribute capitalization", explanation: "Renames \(actualName) to \(key) and keeps its existing value.", code: copy.xmlString(options: [.nodePrettyPrint]), recommended: true)])
                            continue
                        }
                        let choices = key == "Model" ? ["Choose the player or an AI variable declared in this trigger."] : ["Add \(key)=\"…\" with the value this \(section.lowercased()) tag needs."]
                        var solutions: [DraftSolution] = []
                        var values: [String] = []
                        var recommendedTemplate: String?
                        let contextual = XMLAssistantContext.requiredValueChoices(element: element, key: key)
                        if key == "Model" {
                            values = ["Player"] + (templates.references["Model"] ?? [])
                            var scope: XMLNode? = element
                            while scope?.name != "Trigger", scope?.parent != nil { scope = scope?.parent }
                            let variables = try scope?.nodes(forXPath: "./Content/Init/SetVariable[@Type='AI'] | ./Init/SetVariable[@Type='AI']") ?? []
                            values += variables.compactMap { ($0 as? XMLElement)?.attribute(forName: "Name")?.stringValue }.filter { !$0.isEmpty }
                            values = Array(Set(values)).sorted()
                        } else if key == "Template" {
                            let nearby = Set((element.parent?.children ?? []).filter { $0 !== element && $0.kind == .element }.compactMap(\.name))
                            let candidates = templates.candidates(section: section, nearbyTags: nearby)
                            values = candidates.prefix(12).map(\.reference)
                            if let first = candidates.first {
                                let score = Set(first.tags).intersection(nearby).count
                                if score > 0, candidates.filter({ Set($0.tags).intersection(nearby).count == score }).count == 1 { recommendedTemplate = first.reference }
                            }
                        } else if let value = item.suggestedAttributes[key] { values = [value] }
                        if values.isEmpty { values = contextual.map(\.value) }
                        if values.isEmpty { values = XMLAssistantContext.referenceFields(element, references: templates.references, schemas: templates.schemas).first(where: { $0.key == key })?.values ?? [] }
                        for value in values.prefix(candidateBudget) {
                            let copy = try XMLDocument(xmlString: source, options: [.nodeLoadExternalEntitiesNever])
                            if let target = try copy.nodes(forXPath: sectionXPath)[position] as? XMLElement {
                                target.removeAttribute(forName: key)
                                if let attribute = XMLNode.attribute(withName: key, stringValue: value) as? XMLNode { target.addAttribute(attribute) }
                                let entry = templates.entries.first { $0.section == section && $0.reference == value }
                                let details = entry.map { "Loads \($0.tags.joined(separator: ", ")) from the indexed \(section.lowercased()) definition." + ($0.parameters.isEmpty ? "" : " Template parameters: \($0.parameters.joined(separator: ", ")). Review their configuration before use.") }
                                let evidence = contextual.first { $0.value == value }?.reason
                                let indexedChoice = XMLAssistantContext.referenceFields(element, references: templates.references, schemas: templates.schemas).contains { $0.key == key && $0.values.contains(value) }
                                solutions.append(.init(title: "Set \(key) to \(value)", explanation: key == "Model" ? "Choose this if \(value == "Player" ? "the player" : "the defined AI") is the intended target. This choice changes behavior; it isn't guessed for you." : details ?? evidence ?? (indexedChoice ? "Uses an indexed definition. Choose this only if it is the intended reference; an incomplete index does not determine gameplay intent." : "Uses the game's known default for \(key)."), code: copy.xmlString(options: [.nodePrettyPrint]), recommended: key == "Template" ? value == recommendedTemplate : key != "Model" && evidence == nil && !indexedChoice, contextualSuggestion: evidence != nil && key != "Model" && key != "Template"))
                            }
                        }
                        if key == "Template", (element.children ?? []).allSatisfy({ $0.kind == .text && ($0.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                            let siblings = (element.parent?.children ?? []).compactMap { $0 as? XMLElement }.filter { $0 !== element }
                            let hasValidSibling = siblings.contains { sibling in
                                guard let supported = catalogue.first(where: { $0.xmlName == sibling.name }) else { return false }
                                return supported.requiredAttributes.allSatisfy { sibling.attribute(forName: $0)?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }
                            }
                            if hasValidSibling {
                                let copy = try XMLDocument(xmlString: source, options: [.nodeLoadExternalEntitiesNever])
                                let target = try copy.nodes(forXPath: sectionXPath)[position]
                                target.detach()
                                solutions.append(.init(title: "Remove the unused empty block", explanation: "Keeps the existing valid \(section.lowercased()) and removes only this empty block. Choose this if you added the block by mistake.", code: copy.xmlString(options: [.nodePrettyPrint]), recommended: values.isEmpty))
                            }
                        }
                        let missing = requiredFields.filter { element.attribute(forName: $0)?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false }
                        var intentChoices: [String: [String]] = [:]
                        for field in missing {
                            intentChoices[field] = XMLAssistantContext.requiredValueChoices(element: element, key: field).map(\.value)
                            if intentChoices[field]?.isEmpty == true {
                                intentChoices[field] = XMLAssistantContext.referenceFields(element, references: templates.references, schemas: templates.schemas).first(where: { $0.key == field })?.values ?? []
                            }
                        }
                        let intent = DraftIntent(xpath: "(\(sectionXPath))[\(position + 1)]", keys: missing, choices: intentChoices)
                        report("\(item.xmlName) needs \(key).", line: line,
                            explanation: key == "Template" ? "This block has no template reference. Choose a real \(section.lowercased()) definition below, or remove an accidentally added empty block. References come from the connected game/project; no template name is invented." : "The \(key) attribute is missing or empty. The game needs it to know what \(item.xmlName) should act on. Review the proposed values before applying because choosing a target can change behavior.", options: solutions.isEmpty && key == "Template" ? ["No compatible template definitions were indexed. Connect the game source or add a Templates XML file under custom_gamedata/run_data/templates, then refresh."] : choices, solutions: solutions, intent: intent)
                        guard element.attribute(forName: key) == nil, let value = item.suggestedAttributes[key] else { continue }
                        guard let attribute = XMLNode.attribute(withName: key, stringValue: value) as? XMLNode else { continue }
                        element.addAttribute(attribute)
                        changed = true
                    }
                }
            }
            for (ordinal, node) in sourceElements.enumerated() {
                guard candidateBudget > 0, let element = node as? XMLElement else { continue }
                for problem in XMLAssistantContext.fieldProblems(element, section: "Scene") + XMLAssistantContext.projectFieldProblems(element, schemas: templates.schemas, references: templates.references) {
                    var fixes: [DraftSolution] = []
                    if !diagnosticsOnly {
                        for value in problem.choices.prefix(candidateBudget) {
                            let copy = try XMLDocument(xmlString: source, options: [.nodeLoadExternalEntitiesNever])
                            let target = try copy.nodes(forXPath: "//*")[ordinal] as? XMLElement
                            target?.removeAttribute(forName: problem.key)
                            target?.addAttribute(XMLNode.attribute(withName: problem.key, stringValue: value) as! XMLNode)
                            fixes.append(.init(title: "Set \(problem.key) to \(value)", explanation: "Uses a value supported by this field's schema. Case or spacing corrections preserve the intended spelling; other choices need your review. No identifier or coordinate is invented.", code: copy.xmlString(options: [.nodePrettyPrint]), recommended: value == problem.correction))
                        }
                    }
                    let line = locator.elements.indices.contains(ordinal) ? locator.elements[ordinal].line : 1
                    report("\(element.name ?? "Element").\(problem.key) needs a valid value.", line: line, explanation: "The matching scene or project reader expects \(problem.expected). Enter the intended value or choose a supported alternative; unrelated custom fields are preserved.", options: [], solutions: fixes,
                           intent: .init(xpath: "(//*)[\(ordinal + 1)]", keys: [problem.key], choices: [problem.key: problem.choices]))
                }
                for field in XMLAssistantContext.referenceFields(element, references: templates.references, schemas: templates.schemas) {
                    guard let current = element.attribute(forName: field.key)?.stringValue, !current.isEmpty,
                          !["_", "?", "$"].contains(where: { current.hasPrefix($0) }), !XMLAssistantContext.knownReference(current, key: field.key, element: element, choices: field.values) else { continue }
                    var nearby: [(String, Int)] = []
                    for value in field.values {
                        let distance = spellingDistance(current, value)
                        if distance <= 2 { nearby.append((value, distance)) }
                    }
                    nearby.sort { left, right in left.1 == right.1 ? left.0 < right.0 : left.1 < right.1 }
                    guard !nearby.isEmpty else { continue } // An incomplete index must not reject arbitrary custom names.
                    var fixes: [DraftSolution] = []
                    if !diagnosticsOnly {
                        for (value, _) in nearby.prefix(min(6, candidateBudget)) {
                            let copy = try XMLDocument(xmlString: source, options: [.nodeLoadExternalEntitiesNever])
                            let target = try copy.nodes(forXPath: "//*")[ordinal] as? XMLElement
                            target?.attribute(forName: field.key)?.stringValue = value
                            fixes.append(.init(title: "Use indexed \(value)", explanation: "This name exists in the connected definition index. Only \(field.key) changes. If your original name is an extension defined elsewhere, keep it and refresh the index instead.", code: copy.xmlString(options: [.nodePrettyPrint]), recommended: nearby.count == 1 && current.caseInsensitiveCompare(value) == .orderedSame))
                        }
                    }
                    let line = locator.elements.indices.contains(ordinal) ? locator.elements[ordinal].line : 1
                    report("\(element.name ?? "Element").\(field.key) resembles an indexed reference.", line: line, explanation: "The current spelling is not in the available index, but nearby definitions exist. This may be a typo or a custom definition not loaded here; suggestions are optional.", options: [], solutions: fixes)
                }
            }
            if !templates.entries.isEmpty {
                // Template references are checked separately from runtime symbol fields.
                for (position, node) in (try document.nodes(forXPath: "//*[@Template]")).enumerated() {
                    if candidateBudget == 0 { break }
                    guard let element = node as? XMLElement,
                          let current = element.attribute(forName: "Template")?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !current.isEmpty else { continue }
                    let section = ["EventBlock": "Events", "ConditionBlock": "Conditions", "ActionBlock": "Actions"][element.name ?? ""] ?? element.name ?? ""
                    guard ["Events", "Conditions", "Actions"].contains(section), !current.hasPrefix("_"), !current.hasPrefix("?"), !current.hasPrefix("$") else { continue }
                    let compatible = templates.candidates(section: section)
                    if compatible.contains(where: { $0.reference == current }) { continue }
                    var nearby: [(XMLAssistantTemplateIndex.Entry, Int)] = []
                    for candidate in compatible {
                        let distance = spellingDistance(current, candidate.reference)
                        if distance <= 2 { nearby.append((candidate, distance)) }
                    }
                    nearby.sort { left, right in left.1 == right.1 ? left.0.reference < right.0.reference : left.1 < right.1 }
                    if nearby.isEmpty { nearby = compatible.prefix(12).map { ($0, 3) } }
                    let closest = nearby.first?.1
                    let closestCount = nearby.filter { $0.1 == closest }.count
                    var fixes: [DraftSolution] = []
                    for (entry, distance) in nearby.prefix(min(6, candidateBudget)) {
                        let copy = try XMLDocument(xmlString: source, options: [.nodeLoadExternalEntitiesNever])
                        let target = try copy.nodes(forXPath: "//*[@Template]")[position] as? XMLElement
                        target?.attribute(forName: "Template")?.stringValue = entry.reference
                        let reason = distance <= 2 ? "a nearby spelling" : "an alternative compatible definition, not a guessed spelling correction"
                        let explanation = "This indexed \(section.lowercased()) template is \(reason) and provides \(entry.tags.joined(separator: ", ")). Existing attributes are kept."
                        fixes.append(.init(title: "Use \(entry.reference)", explanation: explanation, code: copy.xmlString(options: [.nodePrettyPrint]), recommended: distance <= 2 && closestCount == 1 && distance == closest))
                    }
                    let ordinal = try document.nodes(forXPath: "//*").firstIndex { $0 === element }
                    let line = ordinal.flatMap { locator.elements.indices.contains($0) ? locator.elements[$0].line : nil } ?? 1
                    report("Template \(current) wasn't found for \(section).", line: line, explanation: "The connected definitions do not provide that reference in this section. Check the spelling or reconnect the source if it is defined elsewhere.", options: fixes.isEmpty ? ["Choose a compatible indexed template with completion, or connect the file containing this definition."] : [], solutions: fixes)
                }
            }
            if candidateBudget == 0 {
                let remaining = diagnosticReview(source, catalogues: catalogues, requiresTriggerRoot: requiresTriggerRoot, templates: templates)
                // Count occurrences: distinct elements can share a line and message.
                var covered = Dictionary(grouping: issues, by: { "\($0.line):\($0.message)" }).mapValues(\.count)
                for issue in remaining.issues {
                    let key = "\(issue.line):\(issue.message)"
                    if let count = covered[key], count > 0 { covered[key] = count - 1; continue }
                    issues.append(issue); messages.append("Line \(issue.line): \(issue.message)")
                }
            }
            return .init(messages: messages, proposedXML: changed ? document.xmlString(options: [.nodePrettyPrint]) : nil, source: source, issues: issues)
        } catch {
            return .init(messages: [error.localizedDescription], proposedXML: nil, source: source)
        }
    }
    // Validation must never generate more repair candidates or clone per error.
    nonisolated private static func diagnosticReview(_ source: String, catalogues: [String: [TriggerRuntimeItem]], requiresTriggerRoot: Bool, templates: XMLAssistantTemplateIndex) -> DraftReview {
        let locator = TriggerXMLLocations()
        let parser = XMLParser(data: Data(source.utf8)); parser.shouldResolveExternalEntities = false; parser.delegate = locator
        guard parser.parse(), let document = try? XMLDocument(xmlString: source, options: [.nodeLoadExternalEntitiesNever]) else {
            return .init(messages: ["XML syntax error"], proposedXML: nil, source: source,
                issues: [.init(line: max(1, parser.lineNumber), message: "XML syntax error", explanation: "This draft still needs structural repair.", options: [])])
        }
        var issues: [DraftIssue] = []
        let diagnosticElements = (try? document.nodes(forXPath: "//*")) ?? []
        let diagnosticOrdinals = Dictionary(uniqueKeysWithValues: diagnosticElements.enumerated().map { (ObjectIdentifier($0.element), $0.offset) })
        func report(_ message: String, _ line: Int, intent: DraftIntent? = nil) {
            issues.append(.init(line: line, message: message, explanation: "This draft still needs this correction. Choose the intended value below where available, or recheck after applying another fix.", options: [], intent: intent))
        }
        if requiresTriggerRoot && document.rootElement()?.name != "Trigger" { report("The root element must be Trigger.", locator.elements.first?.line ?? 1) }
        for node in (try? document.nodes(forXPath: "//Loop")) ?? [] {
            for name in ["Events", "Conditions", "Actions"] {
                let sections = (node.children ?? []).filter { $0.name == name && $0.kind == .element }
                if sections.count > 1 {
                    let ordinal = diagnosticOrdinals[ObjectIdentifier(sections[1])]
                    let line = ordinal.flatMap { locator.elements.indices.contains($0) ? locator.elements[$0].line : nil } ?? 1
                    report("Loop has duplicate \(name) sections.", line)
                }
            }
        }
        for section in catalogues.keys.sorted() {
            let catalogue = catalogues[section] ?? []
            let sectionXPath = runtimeSectionPath(section)
            let nodes = (try? document.nodes(forXPath: sectionXPath)) ?? []
            for (position, node) in nodes.enumerated() {
                guard let element = node as? XMLElement else { continue }
                let ordinal = diagnosticOrdinals[ObjectIdentifier(element)]
                let line = ordinal.flatMap { locator.elements.indices.contains($0) ? locator.elements[$0].line : nil } ?? 1
                guard let item = catalogue.first(where: { $0.xmlName.lowercased() == element.name?.lowercased() }) else {
                    report("Unknown \(section) tag: \(element.name ?? "?").", line); continue
                }
                if element.name != item.xmlName { report("Use \(item.xmlName), not \(element.name ?? "?").", line) }
                for problem in XMLAssistantContext.fieldProblems(element, section: section) {
                    report("\(item.xmlName).\(problem.key) has an unsupported literal.", line, intent: .init(xpath: "(\(sectionXPath))[\(position + 1)]", keys: [problem.key], choices: [problem.key: problem.choices]))
                }
                for key in XMLAssistantContext.requiredFields(element, section: section, base: item.requiredAttributes) where element.attribute(forName: key)?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                    report("\(item.xmlName) needs \(key).", line, intent: .init(xpath: "(\(sectionXPath))[\(position + 1)]", keys: [key], choices: [:]))
                }
                if section == "Conditions", ["Equal", "Greater", "Less", "GreaterEqual", "LessEqual"].contains(item.xmlName) {
                    var scope: XMLNode = element
                    while scope.name != "Trigger", let parent = scope.parent { scope = parent }
                    if scope.name == "Trigger", ((try? scope.nodes(forXPath: ".//*[@Template]")) ?? []).isEmpty {
                        let known = Set(XMLAssistantContext.declaredVariables(for: element, includeRepeated: true).map(\.reference)).union(["_$ActionID", "_$WaypointKey", "_$Model", "_$Key"])
                        for key in ["Value1", "Value2"] {
                            if let value = element.attribute(forName: key)?.stringValue, value.hasPrefix("_"), !known.contains(value) { report("Unknown variable reference: \(value).", line) }
                        }
                    }
                }
            }
        }
        for (ordinal, node) in diagnosticElements.enumerated() {
            guard let element = node as? XMLElement else { continue }
            let line = locator.elements.indices.contains(ordinal) ? locator.elements[ordinal].line : 1
            for problem in XMLAssistantContext.fieldProblems(element, section: "Scene") + XMLAssistantContext.projectFieldProblems(element, schemas: templates.schemas, references: templates.references) {
                report("\(element.name ?? "Element").\(problem.key) needs a valid value.", line, intent: .init(xpath: "(//*)[\(ordinal + 1)]", keys: [problem.key], choices: [problem.key: problem.choices]))
            }
            for field in XMLAssistantContext.referenceFields(element, references: templates.references, schemas: templates.schemas) {
                guard let current = element.attribute(forName: field.key)?.stringValue, !current.isEmpty,
                      !["_", "?", "$"].contains(where: { current.hasPrefix($0) }), !XMLAssistantContext.knownReference(current, key: field.key, element: element, choices: field.values) else { continue }
                if field.values.contains(where: { spellingDistance(current, $0) <= 2 }) {
                    report("\(element.name ?? "Element").\(field.key) resembles an indexed reference.", line)
                }
            }
        }
        if !templates.entries.isEmpty {
            for node in (try? document.nodes(forXPath: "//*[@Template]")) ?? [] {
                guard let element = node as? XMLElement, let current = element.attribute(forName: "Template")?.stringValue,
                      !current.isEmpty, !["_", "?", "$"].contains(where: { current.hasPrefix($0) }) else { continue }
                let section = ["EventBlock": "Events", "ConditionBlock": "Conditions", "ActionBlock": "Actions"][element.name ?? ""] ?? element.name ?? ""
                if ["Events", "Conditions", "Actions"].contains(section), !templates.candidates(section: section).contains(where: { $0.reference == current }) {
                    report("Template \(current) wasn't found for \(section).", 1)
                }
            }
        }
        return .init(messages: issues.map { "Line \($0.line): \($0.message)" }, proposedXML: nil, source: source, issues: issues)
    }
    nonisolated private static func spellingDistance(_ left: String, _ right: String) -> Int {
        let a = Array(left.lowercased()), b = Array(right.lowercased())
        guard abs(a.count - b.count) <= 2, a.count <= 80 else { return 3 }
        var previous = Array(0...b.count)
        for (i, character) in a.enumerated() {
            var row = [i + 1]
            for (j, other) in b.enumerated() {
                row.append(min(row[j] + 1, previous[j + 1] + 1, previous[j] + (character == other ? 0 : 1)))
            }
            previous = row
        }
        return previous[b.count]
    }
    nonisolated private static func syntaxRepair(_ source: String) -> DraftReview? {
        let text = source as NSString
        if let declaration = try? NSRegularExpression(pattern: #"(?im)^[\t ]*<\??xml\b[^\r\n<>]*(?:>|$)"#),
           let match = declaration.firstMatch(in: source, range: NSRange(location: 0, length: text.length)) {
            let original = text.substring(with: match.range).trimmingCharacters(in: .whitespacesAndNewlines)
            if !original.hasPrefix("<?xml ") || !original.hasSuffix("?>") {
                let code = text.replacingCharacters(in: match.range, with: "<?xml version=\"1.0\" encoding=\"utf-8\"?>")
                let explanation = "An XML declaration starts with <?xml and ends with ?>. The version must be a quoted attribute, not bare text. This fixes the header only; the document still needs its root element and content."
                let line = text.substring(to: match.range.location).filter { $0 == "\n" }.count + 1
                let solution = DraftSolution(title: "Correct the XML declaration", explanation: explanation, code: code, recommended: true)
                return .init(messages: ["Line \(line): Malformed XML declaration"], proposedXML: nil, source: source, issues: [.init(line: line, message: "Malformed XML declaration", explanation: explanation, options: [], solutions: [solution])])
            }
        }
        guard let regex = try? NSRegularExpression(pattern: #"<!--[\s\S]*?-->|<(?:[^>"']|"[^"]*"|'[^']*')*>"#) else { return nil }
        var stack: [(name: String, range: NSRange)] = []
        for match in regex.matches(in: source, range: NSRange(location: 0, length: text.length)) {
            let token = text.substring(with: match.range)
            if token.hasPrefix("<!") || token.hasPrefix("<?") { continue }
            let closing = token.hasPrefix("</")
            let name = String(token.dropFirst(closing ? 2 : 1).prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == ":" })
            if closing, let open = stack.last, open.name != name {
                let line = text.substring(to: open.range.location).filter { $0 == "\n" }.count + 1
                let gap = text.substring(with: NSRange(location: NSMaxRange(open.range), length: match.range.location - NSMaxRange(open.range)))
                var proposal: String?
                if stack.dropLast().last?.name == name && gap.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let lineRange = text.lineRange(for: open.range)
                    let withoutTag = (text.substring(with: lineRange) as NSString).replacingCharacters(in: NSRange(location: open.range.location - lineRange.location, length: open.range.length), with: "")
                    let removalRange = withoutTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? lineRange : open.range
                    let candidate = text.replacingCharacters(in: removalRange, with: "")
                    let check = XMLParser(data: Data(candidate.utf8))
                    check.shouldResolveExternalEntities = false
                    if check.parse() { proposal = candidate }
                }
                let explanation = "<\(open.name)> is still open when </\(name)> appears. Close \(open.name) first, or remove its opening tag if it was added by mistake."
                var solutions: [DraftSolution] = []
                if let proposal {
                    solutions.append(.init(title: "Remove the stray opening tag", explanation: "The section is empty. Removing this tag restores the existing nesting without adding another section.", code: proposal, recommended: true))
                }
                let ancestor = stack.lastIndex(where: { $0.name == name })
                let unclosed = ancestor.map { Array(stack.dropFirst($0 + 1)) } ?? [open]
                let closingTags = unclosed.reversed().map { "</\($0.name)>" }.joined(separator: "\n")
                let closed = text.replacingCharacters(in: NSRange(location: match.range.location, length: 0), with: closingTags + "\n")
                let check = XMLParser(data: Data(closed.utf8))
                check.shouldResolveExternalEntities = false
                if check.parse() {
                    solutions.append(.init(title: "Keep the section and close it", explanation: "Use this only if the section was intentional. This repairs XML nesting, but an extra section may not be supported by the game. Apply XML to run the full trigger checks.", code: closed))
                }
                let options = solutions.isEmpty ? ["Check whether <\(open.name)> was meant to be a closing tag."] : solutions.map(\.explanation)
                let issue = DraftIssue(line: line, message: "Unclosed \(open.name) section", explanation: explanation, options: options, solutions: solutions)
                return .init(messages: ["Line \(line): \(explanation)"], proposedXML: proposal, source: source, issues: [issue])
            }
            if closing { if stack.last?.name == name { stack.removeLast() } }
            else if !token.hasSuffix("/>") { stack.append((name, match.range)) }
        }
        if !stack.isEmpty {
            let suffix = stack.reversed().map { "</\($0.name)>" }.joined(separator: "\n")
            let candidate = source + "\n" + suffix
            let check = XMLParser(data: Data(candidate.utf8))
            check.shouldResolveExternalEntities = false
            if check.parse() {
                let line = source.filter { $0 == "\n" }.count + 1
                let explanation = "The document ends while \(stack.map(\.name).joined(separator: ", ")) is still open. Closing tags must appear in reverse opening order."
                let solution = DraftSolution(title: "Close the unfinished sections", explanation: "Adds only the missing closing tags at the end. Existing XML and values are unchanged.", code: candidate, recommended: true)
                let issue = DraftIssue(line: line, message: "Missing closing tags", explanation: explanation, options: [], solutions: [solution])
                return .init(messages: ["Line \(line): \(explanation)"], proposedXML: nil, source: source, issues: [issue])
            }
        }
        return nil
    }
}

enum TriggerCodingAssistant {
    enum Kind { case event, condition, action }

    static func suggestions(for prefix: String, kind: Kind) -> [TriggerRuntimeItem] {
        let source: [TriggerRuntimeItem]
        switch kind {
        case .event: source = TriggerRuntimeSchema.events
        case .condition: source = TriggerRuntimeSchema.conditions
        case .action: source = TriggerRuntimeSchema.actions
        }
        let needle = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "</>"))
        guard !needle.isEmpty else { return source }
        return source.filter {
            $0.xmlName.localizedCaseInsensitiveContains(needle) ||
            $0.title.localizedCaseInsensitiveContains(needle)
        }
    }

    static func variableNames(in nodes: [TriggerXMLNode]) -> [String] {
        Array(Set(nodes.compactMap { node in
            guard node.name == "SetVariable" else { return nil }
            let name = node.attributes["Name"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return name.isEmpty ? nil : name
        })).sorted()
    }

    static func completionNames(in source: String, at caret: Int, sceneXML: Bool = false, templates: XMLAssistantTemplateIndex = .init()) -> [String] {
        let text = source as NSString
        guard caret >= 0, caret <= text.length, text.length <= 200_000 else { return [] }
        let prefix = text.substring(to: caret)
        if let comment = prefix.range(of: "<!--", options: .backwards),
           prefix.range(of: "-->", range: comment.upperBound..<prefix.endIndex) == nil { return [] }
        guard let opening = XMLAssistantLexing.unfinishedTag(in: source, at: caret) else { return [] }
        let partial = opening.text
        if partial.hasPrefix("?"), "?xml".hasPrefix(partial.lowercased()) {
            return ["xml version=\"1.0\" encoding=\"utf-8\"?>"]
        }
        let context = text.substring(to: opening.start)
        var stack: [String] = []
        for token in XMLAssistantContext.tokens(context) {
            if token.closing {
                if let position = stack.lastIndex(of: token.name) { stack.removeSubrange(position...) }
            } else if !token.selfClosing && token.complete { stack.append(token.name) }
        }
        if partial.hasPrefix("/") {
            let query = String(partial.dropFirst())
            return stack.last.map { $0.lowercased().hasPrefix(query.lowercased()) ? [$0] : [] } ?? []
        }
        let active: Kind?
        switch stack.last {
        case "Events": active = .event
        case "Conditions": active = .condition
        case "Actions", "Init": active = .action
        default: active = nil
        }
        var catalogue: [TriggerRuntimeItem]
        switch active {
        case .event: catalogue = TriggerRuntimeSchema.events
        case .condition: catalogue = TriggerRuntimeSchema.conditions
        case .action: catalogue = TriggerRuntimeSchema.actions
        case nil: catalogue = []
        }
        var structural: [String: [String]] = ["Trigger": ["Name", "X", "Y", "Width", "Height"],
            "Loop": ["Template"], "Template": ["Name"], "SetVariable": ["Name", "Type", "Value"]]
        if sceneXML {
            structural["Object"] = ["Name", "X", "Y", "Factor", "Template", "File", "Class", "Rotation"]
            structural["Image"] = ["Name", "Class", "X", "Y", "Width", "Height", "Rotation", "Layer", "Factor", "Blend"]
            for name in ["Platform", "Area"] { structural[name] = ["Name", "X", "Y", "Width", "Height", "Rotation", "Class", "Template"] }
        }
        for (name, attributes) in structural {
            if let index = catalogue.firstIndex(where: { $0.xmlName == name }) {
                catalogue[index].requiredAttributes = Array(Set(catalogue[index].requiredAttributes + attributes)).sorted()
            } else {
                catalogue.append(.init(xmlName: name, title: name, requiredAttributes: attributes, suggestedAttributes: [:]))
            }
        }
        let tag = String(partial.prefix { $0.isLetter || $0.isNumber || "_:.-".contains($0) })
        let completionDocument = XMLAssistantContext.completionDocument(source, at: caret)
        let completionElement = (try? completionDocument?.nodes(forXPath: "//*").last) as? XMLElement
        let projectRules = completionElement.map { XMLAssistantContext.projectFieldRules($0, schemas: templates.schemas) } ?? []
        if partial.contains(where: { $0.isWhitespace }), !tag.isEmpty {
            let remainder = String(partial.dropFirst(tag.count))
            let ns = remainder as NSString
            if let regex = try? NSRegularExpression(pattern: "([A-Za-z_][A-Za-z0-9_]*)\\s*=\\s*[\"']([^\"']*)$"),
               let match = regex.firstMatch(in: remainder, range: NSRange(location: 0, length: ns.length)) {
                let attribute = ns.substring(with: match.range(at: 1))
                let value = ns.substring(with: match.range(at: 2))
                var candidates: [String] = []
                if attribute == "Template" {
                    let section = ["EventBlock": "Events", "ConditionBlock": "Conditions", "ActionBlock": "Actions"][tag] ?? tag
                    candidates = templates.candidates(section: section).map(\.reference)
                }
                if attribute == "Model", !["Armor", "Protocol"].contains(tag) { candidates = ["Player"] + XMLAssistantLexing.modelVariables(in: context) }
                if attribute == "Switch" { candidates = ["On", "Off"] }
                if tag == "SetVariable", attribute == "Type" { candidates = ["Bool", "Int", "Float", "String", "Node", "AI"] }
                if tag == "EndGame", attribute == "Result" { candidates = ["Win", "Loss", "Death"] }
                if tag == "GlobalTimer", attribute == "Action" { candidates = ["increment", "pause"] }
                if tag == "Swarm", attribute == "Type" { candidates = ["Spawn", "Activate", "Stop"] }
                if tag == "SetModelParameter", attribute == "Type" { candidates = ["bool", "int", "float"] }
                if tag == "Choose", attribute == "Order" { candidates = ["Sync", "Straight", "Random"] }
                if tag == "Sound", attribute == "Action" { candidates = ["Play", "Stop"] }
                if tag == "Sound", attribute == "Channel" { candidates = ["Sound", "Cutscene", "Ambient"] }
                if tag == "Music", attribute == "Action" { candidates = ["Play", "Stop", "Pause", "Resume"] }
                if (tag == "ForceAnimation" && attribute == "Name") || (tag == "ModelExecute" && attribute == "AnimName") { candidates += templates.references["Animation"] ?? [] }
                if attribute == "Model", !["Armor", "Protocol"].contains(tag) { candidates += templates.references["Model"] ?? [] }
                if tag == "SetModelParameter", attribute == "ModelName" { candidates += templates.references["Animator"] ?? [] }
                if attribute == "Class", tag == "Image" { candidates += templates.references["Texture"] ?? [] }
                if attribute == "Class", ["Object", "ObjectReference"].contains(tag) { candidates += templates.references["ObjectClass"] ?? [] }
                if let completionElement {
                    candidates += XMLAssistantContext.referenceFields(completionElement, references: templates.references, schemas: templates.schemas).first(where: { $0.key == attribute })?.values ?? []
                    for rule in projectRules where rule.key == attribute {
                        candidates += rule.kind == "reference" ? templates.references[rule.reference] ?? [] : rule.values
                    }
                }
                let attrs = XMLAssistantContext.attributes(in: "<" + partial)
                candidates += XMLAssistantContext.valueChoices(tag: tag, attribute: attribute, attributes: attrs,
                    variables: XMLAssistantContext.variables(in: source, at: caret)).map(\.value)
                if let item = catalogue.first(where: { $0.xmlName == tag }), let suggested = item.suggestedAttributes[attribute] {
                    candidates.append(suggested)
                }
                let replacement = XMLAssistantLexing.completionRange(in: source, caret: caret)
                let hasClosingQuote = NSMaxRange(replacement) < text.length && [34, 39].contains(text.character(at: NSMaxRange(replacement)))
                let fullValue = text.substring(with: replacement)
                return Array(Set(candidates)).sorted().filter {
                    guard $0.lowercased().hasPrefix(value.lowercased()) else { return false }
                    let encoded = XMLAssistantContext.encodedCompletion($0, source: source, range: replacement)
                    // An accepted value is not another edit. Don't keep proposing the
                    // exact same whole token after the caret moves to its closing quote.
                    return !(hasClosingQuote && fullValue == encoded && value == encoded)
                }
            }
            // A closed quote is not an attribute-name prefix.
            let tail = remainder.last?.isWhitespace == true ? "" : String(remainder.split(whereSeparator: { $0.isWhitespace }).last ?? "")
            guard tail.isEmpty || tail.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return [] }
            let item = catalogue.first(where: { $0.xmlName == tag })
            let keys = Set((item?.requiredAttributes ?? []) + Array(item?.suggestedAttributes.keys ?? Dictionary<String, String>().keys) + projectRules.map(\.key) + (completionElement.map { XMLAssistantContext.conditionalRequiredFields($0, section: $0.parent?.name ?? "") } ?? []))
            let attributePattern = #"([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(?:"[^"]*"|'[^']*')"#
            let attributeRegex = try? NSRegularExpression(pattern: attributePattern)
            let existing = Set(attributeRegex?.matches(in: remainder, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) } ?? [])
            return keys.sorted().filter { $0.lowercased().hasPrefix(tail.lowercased()) && !existing.contains($0) }
        }
        guard partial.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return [] }
        if let active { return suggestions(for: partial, kind: active).map(\.xmlName) }
        let children: [String]
        switch stack.last {
        case nil: children = sceneXML ? ["Room", "Object", "Image", "Platform", "Area", "Trigger"] : ["Trigger"]
        case "Trigger": children = ["Content"]
        case "Content": children = sceneXML && !stack.contains("Trigger") ? ["Object", "Image", "Platform", "Area", "Trigger", "Dynamic"] : ["Init", "Loop", "Template"]
        case "Room", "Object": children = sceneXML ? ["Content", "Properties"] : []
        case "Loop": children = ["Events", "Conditions", "Actions"]
        default: children = []
        }
        return children.filter { $0.lowercased().hasPrefix(partial.lowercased()) }
    }

    static func inserting(_ fragment: String, kind: Kind, loopIndex: Int, into source: String) throws -> String {
        let document = try XMLDocument(xmlString: source, options: [.nodeLoadExternalEntitiesNever])
        let loops = ((try document.nodes(forXPath: "//Trigger/Content/Loop"))).compactMap { $0 as? XMLElement }
        guard loops.indices.contains(loopIndex) else {
            throw NSError(domain: "TriggerCoding", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Add or select a Loop before inserting a suggestion."])
        }
        let loop = loops[loopIndex]
        let sectionName: String
        switch kind {
        case .event: sectionName = "Events"
        case .condition: sectionName = "Conditions"
        case .action: sectionName = "Actions"
        }
        let block = loop.elements(forName: sectionName).first ?? XMLElement(name: sectionName)
        if block.parent == nil {
            let order = ["Events", "Conditions", "Actions"]
            let rank = order.firstIndex(of: sectionName)!
            let insertionIndex = (loop.children ?? []).firstIndex {
                guard let name = $0.name, let otherRank = order.firstIndex(of: name) else { return false }
                return otherRank > rank
            } ?? loop.childCount
            loop.insertChild(block, at: insertionIndex)
        }
        let inserted = try XMLDocument(xmlString: fragment, options: [.nodeLoadExternalEntitiesNever])
        guard let node = inserted.rootElement()?.copy() as? XMLElement else { return source }
        block.addChild(node)
        return document.xmlString(options: [.nodePrettyPrint])
    }
}
