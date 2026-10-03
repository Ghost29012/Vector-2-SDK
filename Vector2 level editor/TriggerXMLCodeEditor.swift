import AppKit
import SwiftUI

/// AppKit's ruler stays in step with the editor when XML wraps or scrolls.
struct TriggerXMLCodeEditor: NSViewRepresentable {
    @Binding var text: String
    var predictiveCoding = true
    var sceneXML = false
    var templates = XMLAssistantTemplateIndex()
    var review: TriggerRuntimeSchema.DraftReview = .init(messages: [], proposedXML: nil)

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .noBorder
        let editor = TriggerXMLTextView(frame: .zero)
        editor.isEditable = true
        editor.isRichText = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextCompletionEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.isGrammarCheckingEnabled = false
        editor.allowsUndo = true
        editor.usesFindBar = true
        editor.isIncrementalSearchingEnabled = true
        editor.backgroundColor = .textBackgroundColor
        editor.insertionPointColor = .controlAccentColor
        editor.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        editor.textContainerInset = NSSize(width: 12, height: 12)
        editor.minSize = .zero
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                height: CGFloat.greatestFiniteMagnitude)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = true
        editor.textContainer?.widthTracksTextView = false
        editor.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                     height: CGFloat.greatestFiniteMagnitude)
        editor.delegate = context.coordinator
        editor.predictiveCoding = predictiveCoding
        editor.sceneXML = sceneXML
        editor.templates = templates
        editor.string = text
        editor.review = review
        editor.highlightXML()
        scroll.documentView = editor
        scroll.hasVerticalRuler = true
        scroll.verticalRulerView = XMLLineNumberRuler(scrollView: scroll, orientation: .verticalRuler)
        scroll.rulersVisible = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.owner = self
        guard let editor = scroll.documentView as? TriggerXMLTextView else { return }
        editor.predictiveCoding = predictiveCoding
        editor.sceneXML = sceneXML
        editor.templates = templates
        if editor.review != review {
            editor.review = review
            editor.highlightXML()
            editor.needsDisplay = true
        }
        if editor.string != text {
            let selection = editor.selectedRange()
            editor.string = text
            editor.highlightXML()
            editor.setSelectedRange(NSRange(location: min(selection.location, (text as NSString).length), length: 0))
            scroll.verticalRulerView?.needsDisplay = true
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var owner: TriggerXMLCodeEditor
        init(_ owner: TriggerXMLCodeEditor) { self.owner = owner }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            owner.text = editor.string
            editor.enclosingScrollView?.verticalRulerView?.needsDisplay = true
            editor.needsDisplay = true
            (editor as? TriggerXMLTextView)?.highlightXML()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            (notification.object as? NSTextView)?.needsDisplay = true
            (notification.object as? TriggerXMLTextView)?.dismissStaleSuggestions()
        }
    }
}

final class TriggerXMLTextView: NSTextView {
    var sceneXML = false
    var templates = XMLAssistantTemplateIndex()
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == .command && event.charactersIgnoringModifiers?.lowercased() == "a" {
            cancelOperation(nil)
            issuePopover.close()
            selectAll(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
    var review: TriggerRuntimeSchema.DraftReview = .init(messages: [], proposedXML: nil)
    private let issuePopover = NSPopover()

    func issueRange(line: Int) -> NSRange? {
        let source = string as NSString
        var offset = 0
        for number in 1...max(1, line) {
            guard offset < source.length else { return nil }
            let range = source.lineRange(for: NSRange(location: offset, length: 0))
            if number == line { return range }
            offset = NSMaxRange(range)
        }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        guard predictiveCoding, review.source == string else { return }
        let caret = selectedRange().location
        guard let issue = review.issues.first(where: { issueRange(line: $0.line).map { NSLocationInRange(caret, $0) } ?? false }),
              let window else { return }
        let snapshot = review
        issuePopover.behavior = .semitransient
        issuePopover.contentViewController = NSHostingController(rootView: TriggerXMLIssueCard(issue: issue, proposal: snapshot.proposedXML, source: snapshot.source) { [weak self] proposal in
            guard let self, self.string == snapshot.source else { return }
            self.issuePopover.close()
            self.insertText(proposal, replacementRange: NSRange(location: 0, length: (self.string as NSString).length))
        })
        var anchor = convert(window.convertFromScreen(firstRect(forCharacterRange: selectedRange(), actualRange: nil)), from: nil)
        anchor.size.width = max(1, anchor.width)
        issuePopover.show(relativeTo: anchor, of: self, preferredEdge: .maxY)
    }
    var predictiveCoding = true {
        didSet { if !predictiveCoding { cancelOperation(nil); issuePopover.close() } }
    }
    private var completionRequest = 0
    private var suggestions: [String] = []
    private var suggestionIndex = 0
    private var suggestionCaret = 0
    private let suggestionPopover = NSPopover()

    override func complete(_ sender: Any?) {
        refreshSuggestions()
    }

    private func refreshSuggestions() {
        suggestions = predictiveCoding ? Array(TriggerCodingAssistant.completionNames(in: string, at: selectedRange().location, sceneXML: sceneXML, templates: templates).prefix(10)) : []
        suggestionIndex = 0
        suggestionCaret = selectedRange().location
        showSuggestions()
    }

    private func showSuggestions() {
        guard !suggestions.isEmpty, window != nil else { suggestionPopover.close(); return }
        suggestionPopover.behavior = .semitransient
        suggestionPopover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let entries = suggestions
        let openingPopup = !suggestionPopover.isShown
        let typed = (string as NSString).substring(with: rangeForUserCompletion)
        let recommended = entries.count == 1 ? entries.first : entries.first(where: { $0.caseInsensitiveCompare(typed) == .orderedSame })
        let highlightedIndex = suggestionIndex
        let accept: (Int) -> Void = { [weak self] index in
            self?.suggestionIndex = index
            self?.acceptSuggestion()
        }
        suggestionPopover.contentViewController = NSHostingController(rootView:
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Image(systemName: "curlybraces").foregroundStyle(Color.accentColor)
                    Text("XML Assistant").font(.system(size: 11, weight: .semibold))
                    Spacer()
                    Text("\(entries.count)").font(.caption2).foregroundStyle(.secondary)
                }.padding(.horizontal, 8).padding(.vertical, 5)
                Divider().opacity(0.4)
                ForEach(Array(entries.enumerated()), id: \.offset) { index, name in
                    Button { accept(index) } label: {
                        HStack { Image(systemName: "chevron.left.forwardslash.chevron.right").foregroundStyle(.secondary)
                            Text(name).font(.system(size: 13, weight: .medium)); Spacer()
                            if name == recommended {
                                Text("Recommended").font(.system(size: 9, weight: .semibold)).foregroundStyle(.blue)
                                    .padding(4).background(Color.blue.opacity(0.1), in: Capsule())
                            }
                        }
                            .padding(.horizontal, 9).padding(.vertical, 8).frame(width: 290)
                            .background(index == highlightedIndex ? Color.accentColor.opacity(0.16) : .clear,
                                        in: RoundedRectangle(cornerRadius: 7))
                            .modifier(XMLRecommendationStyle(active: name == recommended, animateEntrance: openingPopup))
                    }.buttonStyle(.plain)
                }
                Text("↑↓ choose · Tab accept · Esc dismiss").font(.caption2).foregroundStyle(.secondary).padding(5)
            }.padding(7))
        suggestionPopover.contentSize = NSSize(width: 304, height: 70 + entries.count * 36)
        let screenRect = firstRect(forCharacterRange: selectedRange(), actualRange: nil)
        var local = convert(window!.convertFromScreen(screenRect), from: nil)
        // A caret has no selected text, so AppKit may give it zero width.
        local.size.width = max(1, local.width)
        local.size.height = max(14, local.height)
        guard local.intersects(visibleRect) else { suggestionPopover.close(); return }
        if !suggestionPopover.isShown {
            suggestionPopover.show(relativeTo: local, of: self, preferredEdge: .maxY)
            window?.makeFirstResponder(self)
        } else {
            suggestionPopover.positioningRect = local
        }
    }

    func acceptSuggestion() {
        guard selectedRange().location == suggestionCaret else { cancelOperation(nil); return }
        guard suggestions.indices.contains(suggestionIndex) else { return }
        let candidate = suggestions[suggestionIndex]
        suggestions = []; suggestionPopover.close()
        let replacement = rangeForUserCompletion
        let tag = XMLAssistantLexing.unfinishedTag(in: string, at: replacement.location)?.text ?? ""
        let attribute = !tag.hasPrefix("/") && tag.contains(where: { $0.isWhitespace }) && !tag.contains("=")
            || (!tag.hasPrefix("/") && tag.contains(where: { $0.isWhitespace }) && tag.last?.isWhitespace == true)
        insertText(attribute ? candidate + "=\"\"" : XMLAssistantContext.encodedCompletion(candidate, source: string, range: replacement), replacementRange: replacement)
        if attribute { setSelectedRange(NSRange(location: selectedRange().location - 1, length: 0)) }
    }

    override func insertCompletion(_ word: String, forPartialWordRange charRange: NSRange, movement: Int, isFinal: Bool) {
        super.insertCompletion(XMLAssistantContext.encodedCompletion(word, source: string, range: charRange),
            forPartialWordRange: charRange, movement: movement, isFinal: isFinal)
    }

    override func moveDown(_ sender: Any?) {
        guard suggestionPopover.isShown else { super.moveDown(sender); return }
        suggestionIndex = min(suggestions.count - 1, suggestionIndex + 1); showSuggestions()
    }
    override func moveUp(_ sender: Any?) {
        guard suggestionPopover.isShown else { super.moveUp(sender); return }
        suggestionIndex = max(0, suggestionIndex - 1); showSuggestions()
    }
    override func cancelOperation(_ sender: Any?) {
        completionRequest &+= 1
        suggestions = []; suggestionPopover.close()
    }

    func dismissStaleSuggestions() {
        if selectedRange().length > 0 || selectedRange().location != suggestionCaret { cancelOperation(nil) }
    }

    override var rangeForUserCompletion: NSRange {
        XMLAssistantLexing.completionRange(in: string, caret: selectedRange().location)
    }

    override func deleteBackward(_ sender: Any?) {
        issuePopover.close()
        completionRequest &+= 1
        super.deleteBackward(sender)
        refreshSuggestions()
    }

    override func insertTab(_ sender: Any?) {
        if suggestionPopover.isShown { acceptSuggestion(); return }
        insertText("    ", replacementRange: selectedRange())
    }

    override func insertNewline(_ sender: Any?) {
        if suggestionPopover.isShown { acceptSuggestion(); return }
        let source = string as NSString
        let caret = min(selectedRange().location, source.length)
        let line = source.lineRange(for: NSRange(location: caret, length: 0))
        let prefix = source.substring(with: NSRange(location: line.location, length: caret - line.location))
        let indentation = String(prefix.prefix { $0 == " " || $0 == "\t" })
        insertText("\n" + indentation, replacementRange: selectedRange())
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        issuePopover.close()
        super.insertText(insertString, replacementRange: replacementRange)
        let inserted = (insertString as? String) ?? (insertString as? NSAttributedString)?.string ?? ""
        completionRequest &+= 1
        let request = completionRequest
        guard predictiveCoding, inserted.count == 1,
              inserted.first?.isLetter == true || ["<", "/", " ", "\"", "'", "$"].contains(inserted),
              !TriggerCodingAssistant.completionNames(in: string, at: selectedRange().location, sceneXML: sceneXML, templates: templates).isEmpty else {
            suggestions = []; suggestionPopover.close(); return
        }
        // Let the text system finish changing the caret before opening its popup.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.predictiveCoding, self.completionRequest == request else { return }
            self.complete(nil)
        }
    }

    override func completions(forPartialWordRange charRange: NSRange,
                              indexOfSelectedItem index: UnsafeMutablePointer<Int>) -> [String]? {
        guard predictiveCoding else { return nil }
        // Don't insert a provisional candidate. Backspace edits the user's text.
        index.pointee = -1
        let names = TriggerCodingAssistant.completionNames(in: string, at: NSMaxRange(charRange), sceneXML: sceneXML, templates: templates)
        return names.isEmpty ? nil : names
    }

    func highlightXML() {
        guard let storage = textStorage else { return }
        let source = string as NSString
        let full = NSRange(location: 0, length: source.length)
        storage.beginEditing()
        storage.removeAttribute(.underlineStyle, range: full)
        storage.removeAttribute(.underlineColor, range: full)
        storage.removeAttribute(.backgroundColor, range: full)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        let base: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.textColor,
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular), .paragraphStyle: paragraph]
        storage.addAttributes(base, range: full)
        for (pattern, color) in [("</?[A-Za-z_][A-Za-z0-9_:-]*", NSColor.textColor),
            ("[A-Za-z_][A-Za-z0-9_:-]*(?=\\s*=)", NSColor.secondaryLabelColor),
            ("\"[^\"]*\"|'[^']*'", NSColor.systemBlue.withAlphaComponent(0.85)),
            ("<!--[\\s\\S]*?-->", NSColor.secondaryLabelColor)] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: string, range: full) {
                storage.addAttribute(.foregroundColor, value: color, range: match.range)
            }
        }
        if review.source == string {
            for issue in review.issues {
                guard let range = issueRange(line: issue.line) else { continue }
                storage.addAttributes([.underlineStyle: NSUnderlineStyle.single.rawValue,
                    .underlineColor: NSColor.systemRed,
                    .backgroundColor: NSColor.systemRed.withAlphaComponent(0.08)], range: range)
            }
        }
        storage.endEditing()
        typingAttributes = base
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        if let layout = layoutManager, let container = textContainer, layout.numberOfGlyphs > 0 {
            let caret = min(selectedRange().location, (string as NSString).length)
            let range = (string as NSString).lineRange(for: NSRange(location: caret, length: 0))
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var box = layout.boundingRect(forGlyphRange: glyphs, in: container)
            box.origin.y += textContainerInset.height
            box.origin.x = visibleRect.minX
            box.size.width = visibleRect.width
            NSColor.controlAccentColor.withAlphaComponent(0.045).setFill()
            box.fill()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let layout = layoutManager, let container = textContainer, layout.numberOfGlyphs > 0 else { return }
        let glyphs = layout.glyphRange(forBoundingRect: visibleRect, in: container)
        NSColor.separatorColor.withAlphaComponent(0.14).setStroke()
        layout.enumerateLineFragments(forGlyphRange: glyphs) { box, _, _, _, _ in
            let y = box.maxY + self.textContainerInset.height - 0.5
            let line = NSBezierPath()
            line.lineWidth = 0.5
            line.move(to: NSPoint(x: self.visibleRect.minX, y: y))
            line.line(to: NSPoint(x: self.visibleRect.maxX, y: y))
            line.stroke()
        }
    }
}

struct TriggerXMLIssueCard: View {
    let issue: TriggerRuntimeSchema.DraftIssue
    let proposal: String?
    let source: String
    let apply: (String) -> Void
    @State private var preview = false
    @State private var selectedSolution: Int?
    @State private var intentValues: [String: String] = [:]
    @State private var intentCode: String?
    @State private var intentError = ""
    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 12) {
            Label("XML Assistant", systemImage: "sparkles").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Label("Line \(issue.line) · \(issue.message)", systemImage: "exclamationmark.circle.fill")
                .font(.headline).foregroundStyle(.red)
            Text(issue.explanation).font(.callout).fixedSize(horizontal: false, vertical: true)
            ForEach(Array(issue.solutions.enumerated()).sorted { $0.element.recommended && !$1.element.recommended }, id: \.offset) { index, solution in
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text(solution.title).font(.callout.weight(.semibold))
                        Spacer()
                        if solution.recommended { Label("Recommended", systemImage: "sparkles").font(.caption.weight(.semibold)).foregroundStyle(.blue) }
                    }
                    Text(solution.explanation).font(.caption).fixedSize(horizontal: false, vertical: true)
                    if let remaining = solution.remainingIssues {
                        Text(remaining == 0 ? "XML structure and current catalogue checks pass. Review gameplay intent before applying." : "Repairs this part of the draft. \(remaining) other check\(remaining == 1 ? "" : "s") remain.")
                            .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Partial or not fully validated. Review the code; further fixes may be needed.")
                            .font(.caption2).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                    Button(selectedSolution == index ? "Hide code" : "Preview code") { selectedSolution = selectedSolution == index ? nil : index }
                    if selectedSolution == index {
                        XMLSolutionDiffPreview(before: source, after: solution.code)
                        Button("Apply this fix") { apply(solution.code) }.buttonStyle(.borderedProminent)
                    }
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(solution.recommended ? Color.blue.opacity(0.09) : Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                    .modifier(XMLRecommendationStyle(active: solution.recommended))
            }
            if let intent = issue.intent {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Choose what you intended").font(.callout.weight(.semibold))
                    Text("These fields change behavior. Choose a contextual value or type your own; the assistant won't guess for you.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    ForEach(intent.keys, id: \.self) { key in
                        HStack {
                            Text(key).font(.caption.monospaced()).frame(width: 80, alignment: .leading)
                            TextField("Value", text: Binding(get: { intentValues[key] ?? "" }, set: { intentValues[key] = $0; intentCode = nil }))
                                .textFieldStyle(.roundedBorder)
                            if let values = intent.choices[key], !values.isEmpty {
                                Menu("Choose") {
                                    ForEach(values, id: \.self) { value in
                                        Button(value) { intentValues[key] = value; intentCode = nil }
                                    }
                                }
                            }
                        }
                    }
                    Button("Preview chosen values") {
                        do { intentCode = try intent.code(in: source, values: intentValues); intentError = "" }
                        catch { intentCode = nil; intentError = error.localizedDescription }
                    }
                    if !intentError.isEmpty { Text(intentError).font(.caption).foregroundStyle(.red) }
                    if let intentCode {
                        XMLSolutionDiffPreview(before: source, after: intentCode)
                        Text("Review these values. Applying reruns XML and game checks; this does not prove the intended gameplay.")
                            .font(.caption2).foregroundStyle(.secondary)
                        Button("Apply chosen values") { apply(intentCode) }.buttonStyle(.borderedProminent)
                    }
                }.padding(12).background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
            }
            if issue.solutions.isEmpty {
            ForEach(Array(issue.options.enumerated()), id: \.offset) { index, option in
                VStack(alignment: .leading, spacing: 4) {
                    Text("Suggestion \(index + 1)")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(option).font(.callout).fixedSize(horizontal: false, vertical: true)
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            }
            }
            if issue.solutions.isEmpty, let proposal {
                Button(preview ? "Hide preview" : "Preview safe fixes for this draft") { preview.toggle() }
                if preview {
                    Text("Review this draft before applying. Other errors may still need your input.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    XMLSolutionDiffPreview(before: source, after: proposal)
                    Button("Apply reviewed fixes") { apply(proposal) }.buttonStyle(.borderedProminent)
                }
            }
        }.padding(16)
        }.frame(width: 540).frame(maxHeight: 650)
    }
}

private struct XMLSolutionDiffPreview: View {
    let before: String
    let after: String
    var body: some View {
        let lines = XMLSolutionDiff.lines(before: before, after: after)
        VStack(alignment: .leading, spacing: 6) {
            Text("− Removed · + Added").font(.caption2).foregroundStyle(.secondary)
            ScrollViewReader { reader in
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                            HStack(alignment: .top, spacing: 8) {
                                Text(line.kind == .removed ? "−" : line.kind == .added ? "+" : " ")
                                Text(line.text.isEmpty ? " " : line.text).strikethrough(line.kind == .removed)
                            }.font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(line.kind == .removed ? Color.red : line.kind == .added ? Color.green : Color.primary)
                                .textSelection(.enabled).id(index)
                        }
                    }.padding(10)
                }.frame(height: 210)
                    .background(Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                    .onAppear {
                        if let first = lines.firstIndex(where: { $0.kind != .unchanged }) { reader.scrollTo(first, anchor: .top) }
                    }
            }
        }
    }
}

private struct XMLRecommendationStyle: ViewModifier {
    let active: Bool
    var animateEntrance = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    @State private var glowPhase = false
    func body(content: Content) -> some View {
        content.overlay {
            if active {
                let colors: [Color] = [.cyan, .blue, .purple, .pink, .orange, .pink, .cyan]
                let gradient = AngularGradient(colors: colors, center: .center, angle: .degrees(glowPhase ? 360 : 0))
                ZStack {
                    RoundedRectangle(cornerRadius: 12).stroke(gradient, lineWidth: 6).blur(radius: 5).opacity(0.65)
                    RoundedRectangle(cornerRadius: 12).stroke(gradient, lineWidth: 1.8).opacity(0.9)
                }.allowsHitTesting(false)
            }
        }.onAppear {
            guard active, animateEntrance, !reduceMotion else { appeared = true; return }
            withAnimation(.easeOut(duration: 0.45)) { appeared = true }
            withAnimation(.linear(duration: 3.5).repeatForever(autoreverses: false)) { glowPhase = true }
        }
    }
}

private final class XMLLineNumberRuler: NSRulerView {
    override var requiredThickness: CGFloat { 39 }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let editor = scrollView?.documentView as? NSTextView,
              let layout = editor.layoutManager,
              let container = editor.textContainer else { return }
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.withAlphaComponent(0.45).setFill()
        NSRect(x: bounds.maxX - 1, y: bounds.minY, width: 1, height: bounds.height).fill()
        let source = editor.string as NSString
        guard layout.numberOfGlyphs > 0 else {
            ("1" as NSString).draw(at: NSPoint(x: bounds.maxX - 14, y: editor.textContainerInset.height),
                withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
                                 .foregroundColor: NSColor.secondaryLabelColor])
            return
        }
        let visible = editor.visibleRect
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        guard glyphs.length > 0, glyphs.location < layout.numberOfGlyphs else { return }
        let firstCharacter = layout.characterIndexForGlyph(at: glyphs.location)
        var line = 1
        if firstCharacter > 0 {
            let prefix = source.substring(to: min(firstCharacter, source.length))
            line += prefix.filter { $0 == "\n" }.count
        }
        var index = firstCharacter
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        while index <= source.length {
            let range = source.lineRange(for: NSRange(location: index, length: 0))
            let glyph = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let box = layout.boundingRect(forGlyphRange: glyph, in: container)
            let y = box.minY + editor.textContainerInset.height - visible.minY
            if y > bounds.maxY { break }
            let label = String(line) as NSString
            let width = label.size(withAttributes: attributes).width
            label.draw(at: NSPoint(x: bounds.maxX - width - 7, y: y), withAttributes: attributes)
            line += 1
            let next = NSMaxRange(range)
            if next <= index || next > source.length { break }
            index = next
        }
    }
}
