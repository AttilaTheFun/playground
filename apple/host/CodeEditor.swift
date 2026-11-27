// The Playground's code editor on the iPhone and the Mac: one SwiftUI view
// over the platform's text view (a UITextView on the iPhone, an NSTextView
// in an NSScrollView on the Mac), with the code-unfriendly behaviors turned
// off (smart quotes and dashes, autocorrection, capitals, spelling), Swift
// syntax highlighting (SwiftHighlighter: a small built-in lexer over
// NSAttributedString, no third-party package; docs/playground.md for the
// RSPM alternatives), a syntax check as you type (the compiler's parse-only
// pass) whose errors are underlined and the first shown under the text, and
// the previous line's indentation kept on Return. The iPhone adds a
// "coding keyboard" accessory row of the characters code needs.
// PlaygroundApp installs it as PlaygroundSurfaces.codeEditor on both.

import SwiftUI
#if canImport(UIKit)
import UIKit
typealias PlatformColor = UIColor
typealias PlatformFont = UIFont
#else
import AppKit
typealias PlatformColor = NSColor
typealias PlatformFont = NSFont
#endif

/// The editor: the text view over a one-line footer naming the first syntax
/// error, if any.
struct CodeEditor: View {
    @Binding var text: String
    /// File name for the syntax check's diagnostics.
    var fileName: String = "Untitled.swift"
    @State private var message: String?

    var body: some View {
        VStack(spacing: 0) {
            CodeTextView(text: $text, fileName: fileName, message: $message)
                .accessibilityIdentifier("editor")
            if let message {
                Text(message)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.red)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.secondary.opacity(0.12))
                    .accessibilityIdentifier("editor-diagnostic")
            }
        }
    }
}

/// The platform's text view, as SwiftUI sees it: UIViewRepresentable on the
/// iPhone, NSViewRepresentable on the Mac (below), the same coordinator.
@MainActor
struct CodeTextView {
    @Binding var text: String
    var fileName: String
    @Binding var message: String?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    /// Shows `text` when the binding changed from outside (a load, a revert).
    fileprivate func show(_ text: String, in view: some EditableCode, coordinator: Coordinator) {
        coordinator.parent = self
        guard view.code != text else { return }
        let selection = view.codeSelection
        view.replaceCode(with: SwiftHighlighter.highlight(text))
        view.codeSelection = NSRange(location: min(selection.location, (text as NSString).length), length: 0)
        coordinator.diagnostics = []
        // Not during SwiftUI's update of this view: just after it.
        let message = $message
        Task { @MainActor in message.wrappedValue = nil }
        coordinator.scheduleCheck(view)
    }

    /// What both platforms' delegates do: highlighting after typing settles,
    /// the syntax check after it stops, and indentation kept on Return.
    @MainActor
    final class Coordinator: NSObject {
        var parent: CodeTextView
        var diagnostics: [SyntaxDiagnostic] = []
        private var rehighlight: Task<Void, Never>?
        private var check: Task<Void, Never>?

        init(_ parent: CodeTextView) { self.parent = parent }

        func changed(_ view: some EditableCode) {
            parent.text = view.code
            // Re-color shortly after typing settles; keeps keystrokes cheap
            // and the caret stable (the attributes change in place).
            rehighlight?.cancel()
            rehighlight = Task { [weak self, weak view] in
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, let self, let view else { return }
                self.recolor(view)
            }
            scheduleCheck(view)
        }

        /// Syntax check half a second after typing stops (the parse-only
        /// frontend pass, off the main thread); squiggles the error lines.
        func scheduleCheck(_ view: some EditableCode) {
            check?.cancel()
            let source = view.code
            let name = parent.fileName
            check = Task { [weak self, weak view] in
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                let found = await Task.detached(priority: .userInitiated) {
                    ToolchainCompiler.syntaxCheck(source: source, fileName: name).filter { $0.severity == "error" }
                }.value
                guard !Task.isCancelled, let self, let view, view.code == source else { return }
                self.diagnostics = found
                self.recolor(view)
                self.parent.message = found.first.map { "Line \($0.line): \($0.message)" }
                    .map { found.count > 1 ? "\($0)  (+\(found.count - 1) more)" : $0 }
            }
        }

        private func recolor(_ view: some EditableCode) {
            let code = view.code
            let colored = NSMutableAttributedString(attributedString: SwiftHighlighter.highlight(code))
            let ns = code as NSString
            for diagnostic in diagnostics {
                // Underline from the diagnostic's column to the end of its line.
                var lineStart = 0
                var current = 1
                while current < diagnostic.line, lineStart < ns.length {
                    let range = ns.lineRange(for: NSRange(location: lineStart, length: 0))
                    lineStart = NSMaxRange(range)
                    current += 1
                }
                guard lineStart <= ns.length else { continue }
                let lineRange = ns.lineRange(for: NSRange(location: lineStart, length: 0))
                var start = lineStart + max(diagnostic.column - 1, 0)
                var end = NSMaxRange(lineRange)
                if end > 0, ns.character(at: end - 1) == 10 { end -= 1 }
                if start >= end { start = lineStart }
                guard end > start else { continue }
                colored.addAttributes([
                    .underlineStyle: NSUnderlineStyle([.thick, .patternDot]).rawValue,
                    .underlineColor: PlatformColor.systemRed,
                ], range: NSRange(location: start, length: end - start))
            }
            view.recolor(with: colored)
        }

        /// What Return inserts: a newline with the line's indentation, and
        /// four spaces more after a `{`.
        func newline(in view: some EditableCode, at location: Int) -> String {
            let ns = view.code as NSString
            let line = ns.substring(with: ns.lineRange(for: NSRange(location: location, length: 0)))
            let indent = line.prefix { $0 == " " || $0 == "\t" }
            let opensBlock = line.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("{")
            return "\n" + indent + (opensBlock ? "    " : "")
        }
    }
}

/// What the coordinator needs of the platform's text view.
@MainActor
protocol EditableCode: AnyObject {
    var code: String { get }
    var codeSelection: NSRange { get set }
    /// The whole text replaced (a new string).
    func replaceCode(with attributed: NSAttributedString)
    /// The same string's attributes replaced IN PLACE: swapping the text
    /// replaces the text storage and resets the scroll position (the editor
    /// jumped to the top a beat after every keystroke further down a file).
    func recolor(with attributed: NSAttributedString)
}

extension NSTextStorage {
    /// `attributed`'s attributes on the same string; false when the strings'
    /// lengths differ (the text changed since).
    fileprivate func takeAttributes(of attributed: NSAttributedString) -> Bool {
        guard length == attributed.length else { return false }
        beginEditing()
        attributed.enumerateAttributes(in: NSRange(location: 0, length: attributed.length)) { attributes, range, _ in
            setAttributes(attributes, range: range)
        }
        endEditing()
        return true
    }
}

#if canImport(UIKit)
extension CodeTextView: UIViewRepresentable {
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.font = SwiftHighlighter.font
        view.backgroundColor = .systemBackground
        view.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 12, right: 8)
        view.alwaysBounceVertical = true
        // Code, not prose: no smart punctuation (straight quotes!), no
        // autocorrect/capitalization, ASCII-capable keyboard.
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.spellCheckingType = .no
        view.keyboardType = .asciiCapable
        view.inputAccessoryView = CodingKeyboard.make(for: view)
        view.attributedText = SwiftHighlighter.highlight(text)
        context.coordinator.scheduleCheck(view)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        show(text, in: view, coordinator: context.coordinator)
    }
}

extension CodeTextView.Coordinator: UITextViewDelegate {
    func textViewDidChange(_ view: UITextView) { changed(view) }

    func textView(_ view: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        // Keep the indentation of the previous line on Return.
        guard text == "\n" else { return true }
        let insertion = newline(in: view, at: range.location)
        view.textStorage.replaceCharacters(in: range, with: insertion)
        view.selectedRange = NSRange(location: range.location + (insertion as NSString).length, length: 0)
        changed(view)
        return false
    }
}

extension UITextView: EditableCode {
    var code: String { text ?? "" }
    var codeSelection: NSRange {
        get { selectedRange }
        set { selectedRange = newValue }
    }

    /// New text whole (a file opened, the agent's rewrite): the undo stack's
    /// ranges were the old text's, so it goes with it.
    func replaceCode(with attributed: NSAttributedString) {
        attributedText = attributed
        undoManager?.removeAllActions()
    }

    func recolor(with attributed: NSAttributedString) {
        let selection = selectedRange
        let offset = contentOffset
        if !textStorage.takeAttributes(of: attributed) { attributedText = attributed }
        selectedRange = selection
        setContentOffset(offset, animated: false)
    }
}

extension PlatformColor {
    /// The text's own color, light or dark.
    static var codeText: UIColor { .label }
}

/// The accessory row above the keyboard: the characters code needs that the
/// iOS keyboard buries (or "smartens"), plus Tab and a dismiss key. The
/// iPhone's alone: a Mac has its keyboard.
enum CodingKeyboard {
    static let keys = ["⇥", "\"", "'", "{", "}", "(", ")", "[", "]", "<", ">", "=", ":", ";", ".", ",", "_", "\\", "/", "$", "!", "?", "&", "|", "*", "+", "-", "@", "#"]

    static func make(for textView: UITextView) -> UIView {
        let scroll = UIScrollView(frame: CGRect(x: 0, y: 0, width: 0, height: 44))
        scroll.showsHorizontalScrollIndicator = false
        scroll.backgroundColor = .secondarySystemBackground
        scroll.autoresizingMask = [.flexibleWidth]
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        for key in keys {
            let button = UIButton(type: .system)
            button.setTitle(key, for: .normal)
            button.titleLabel?.font = .monospacedSystemFont(ofSize: 17, weight: .regular)
            button.backgroundColor = .tertiarySystemBackground
            button.layer.cornerRadius = 6
            button.contentEdgeInsets = UIEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
            button.addAction(UIAction { [weak textView] _ in
                guard let textView else { return }
                let insertion = key == "⇥" ? "    " : key
                textView.insertText(insertion)
            }, for: .touchUpInside)
            row.addArrangedSubview(button)
        }
        let hide = UIButton(type: .system)
        hide.setImage(UIImage(systemName: "keyboard.chevron.compact.down"), for: .normal)
        hide.contentEdgeInsets = UIEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
        hide.addAction(UIAction { [weak textView] _ in textView?.resignFirstResponder() }, for: .touchUpInside)
        row.addArrangedSubview(hide)
        scroll.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -8),
            row.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 6),
            row.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -6),
            row.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor, constant: -12),
        ])
        return scroll
    }
}
#else
extension CodeTextView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = true
        guard let view = scroll.documentView as? NSTextView else { return scroll }
        view.delegate = context.coordinator
        view.font = SwiftHighlighter.font
        view.backgroundColor = .textBackgroundColor
        view.textContainerInset = NSSize(width: 8, height: 12)
        // Code, not prose: no smart quotes or dashes, text replacement,
        // spelling or grammar; plain text, with undo and the find bar.
        view.isRichText = false
        view.importsGraphics = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.isGrammarCheckingEnabled = false
        view.smartInsertDeleteEnabled = false
        view.allowsUndo = true
        view.usesFindBar = true
        view.isIncrementalSearchingEnabled = true
        view.typingAttributes = [.font: SwiftHighlighter.font, .foregroundColor: PlatformColor.codeText]
        view.textStorage?.setAttributedString(SwiftHighlighter.highlight(text))
        context.coordinator.scheduleCheck(view)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        show(text, in: view, coordinator: context.coordinator)
    }
}

extension CodeTextView.Coordinator: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        guard let view = notification.object as? NSTextView else { return }
        changed(view)
    }

    func textView(_ view: NSTextView, doCommandBy selector: Selector) -> Bool {
        // Keep the indentation of the previous line on Return (as one
        // insertion: undoable, and textDidChange follows).
        guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
        let range = view.selectedRange()
        view.insertText(newline(in: view, at: range.location), replacementRange: range)
        return true
    }
}

extension NSTextView: EditableCode {
    var code: String { string }
    var codeSelection: NSRange {
        get { selectedRange() }
        set { setSelectedRange(newValue) }
    }

    /// New text whole (a file opened, the agent's rewrite): the undo stack's
    /// ranges were the old text's, and ⌘Z would replay them against the new.
    func replaceCode(with attributed: NSAttributedString) {
        textStorage?.setAttributedString(attributed)
        undoManager?.removeAllActions()
    }

    func recolor(with attributed: NSAttributedString) {
        let selection = selectedRange()
        if textStorage?.takeAttributes(of: attributed) != true { textStorage?.setAttributedString(attributed) }
        setSelectedRange(selection)
    }
}

extension PlatformColor {
    /// The text's own color, light or dark.
    static var codeText: NSColor { .labelColor }
}
#endif

/// A small Swift lexer that colors keywords, types, strings (with
/// interpolation left plain), comments, numbers and attributes/directives.
/// Whole-buffer, single pass — playground files are small.
enum SwiftHighlighter {
    static let font = PlatformFont.monospacedSystemFont(ofSize: 14, weight: .regular)

    static let keywords: Set<String> = [
        "import", "struct", "class", "enum", "protocol", "extension", "func", "var", "let",
        "if", "else", "for", "in", "while", "repeat", "return", "switch", "case", "default",
        "break", "continue", "guard", "defer", "do", "try", "catch", "throw", "throws",
        "rethrows", "async", "await", "some", "any", "where", "is", "as", "self", "Self",
        "super", "init", "deinit", "static", "private", "fileprivate", "internal", "public",
        "open", "final", "override", "mutating", "nonmutating", "lazy", "weak", "unowned",
        "inout", "indirect", "typealias", "associatedtype", "subscript", "operator",
        "true", "false", "nil", "get", "set", "willSet", "didSet", "actor", "macro",
        "package", "consuming", "borrowing", "fallthrough", "convenience", "required",
    ]

    enum Token { case keyword, type, string, comment, number, attribute, plain }

    static func color(_ token: Token) -> PlatformColor {
        switch token {
        case .keyword: return PlatformColor(red: 0.98, green: 0.30, blue: 0.62, alpha: 1)
        case .type: return PlatformColor(red: 0.36, green: 0.85, blue: 0.93, alpha: 1)
        case .string: return PlatformColor(red: 0.99, green: 0.42, blue: 0.36, alpha: 1)
        case .comment: return PlatformColor(red: 0.45, green: 0.55, blue: 0.45, alpha: 1)
        case .number: return PlatformColor(red: 0.85, green: 0.78, blue: 0.40, alpha: 1)
        case .attribute: return PlatformColor(red: 0.75, green: 0.55, blue: 0.95, alpha: 1)
        case .plain: return .codeText
        }
    }

    static func highlight(_ text: String) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: color(.plain),
        ])
        let utf16 = Array(text.utf16)
        var i = 0
        func at(_ k: Int) -> UInt16 { k < utf16.count ? utf16[k] : 0 }
        func isIdentStart(_ c: UInt16) -> Bool { (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 }
        func isIdent(_ c: UInt16) -> Bool { isIdentStart(c) || (c >= 48 && c <= 57) }
        func paint(_ from: Int, _ to: Int, _ token: Token) {
            guard to > from else { return }
            result.addAttribute(.foregroundColor, value: color(token), range: NSRange(location: from, length: to - from))
        }
        while i < utf16.count {
            let c = at(i)
            // Comments.
            if c == 47, at(i + 1) == 47 { // //
                var j = i
                while j < utf16.count, at(j) != 10 { j += 1 }
                paint(i, j, .comment); i = j; continue
            }
            if c == 47, at(i + 1) == 42 { // /* ... */ (nesting)
                var j = i + 2, depth = 1
                while j < utf16.count, depth > 0 {
                    if at(j) == 47, at(j + 1) == 42 { depth += 1; j += 2; continue }
                    if at(j) == 42, at(j + 1) == 47 { depth -= 1; j += 2; continue }
                    j += 1
                }
                paint(i, j, .comment); i = j; continue
            }
            // Strings: "…", """…""", with \( … ) interpolation left plain.
            if c == 34 {
                let triple = at(i + 1) == 34 && at(i + 2) == 34
                var j = i + (triple ? 3 : 1)
                var segmentStart = i
                while j < utf16.count {
                    if at(j) == 92 { // backslash
                        if at(j + 1) == 40 { // \( interpolation
                            paint(segmentStart, j, .string)
                            var k = j + 2, depth = 1
                            while k < utf16.count, depth > 0 {
                                if at(k) == 40 { depth += 1 } else if at(k) == 41 { depth -= 1 }
                                k += 1
                            }
                            j = k; segmentStart = k; continue
                        }
                        j += 2; continue
                    }
                    if triple {
                        if at(j) == 34, at(j + 1) == 34, at(j + 2) == 34 { j += 3; break }
                    } else if at(j) == 34 || at(j) == 10 {
                        j += at(j) == 34 ? 1 : 0; break
                    }
                    j += 1
                }
                paint(segmentStart, j, .string); i = j; continue
            }
            // Attributes and directives: @State, #if, #Preview.
            if c == 64 || c == 35, isIdentStart(at(i + 1)) {
                var j = i + 1
                while isIdent(at(j)) { j += 1 }
                paint(i, j, .attribute); i = j; continue
            }
            // Numbers.
            if c >= 48 && c <= 57 {
                var j = i
                while isIdent(at(j)) || at(j) == 46 && (at(j + 1) >= 48 && at(j + 1) <= 57) { j += 1 }
                paint(i, j, .number); i = j; continue
            }
            // Identifiers: keywords, or Capitalized → type.
            if isIdentStart(c) {
                var j = i
                while isIdent(at(j)) { j += 1 }
                let word = String(utf16CodeUnits: Array(utf16[i..<j]), count: j - i)
                if keywords.contains(word) {
                    paint(i, j, .keyword)
                } else if c >= 65 && c <= 90 {
                    paint(i, j, .type)
                }
                i = j; continue
            }
            i += 1
        }
        return result
    }
}
