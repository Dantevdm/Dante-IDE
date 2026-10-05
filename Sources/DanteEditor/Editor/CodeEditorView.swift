import AppKit
import DanteKit
import SwiftUI

/// Where the caret is, 1-based, for the status bar.
public struct CursorPosition: Equatable, Sendable {
    public var line = 1
    public var column = 1
    public init(line: Int = 1, column: Int = 1) {
        self.line = line
        self.column = column
    }
}

/// A problem a language server reported, already converted to a range in the editor's text.
public struct EditorDiagnostic: Equatable, Sendable {
    public enum Severity: Sendable { case error, warning, note }

    public var range: NSRange
    public var severity: Severity
    public var message: String

    public init(range: NSRange, severity: Severity, message: String) {
        self.range = range
        self.severity = severity
        self.message = message
    }
}

/// A TextKit 2 code editor: monospaced, unwrapped, with a line-number gutter,
/// syntax colours from the theme and auto-indent.
///
/// Give each document its own view (`.id(document.id)`) so undo history stays per document.
public struct CodeEditorView: NSViewRepresentable {
    @Binding var text: String
    let language: Language
    let theme: Theme
    var fontSize: CGFloat
    var diagnostics: [EditorDiagnostic]
    @Binding var reveal: NSRange?
    var onCursorChange: (CursorPosition) -> Void
    /// Called with the UTF-16 offset of a ⌘-click or "Jump to Definition".
    var onDefinition: ((Int) -> Void)?

    public init(
        text: Binding<String>,
        language: Language,
        theme: Theme,
        fontSize: CGFloat = 13,
        diagnostics: [EditorDiagnostic] = [],
        reveal: Binding<NSRange?> = .constant(nil),
        onCursorChange: @escaping (CursorPosition) -> Void = { _ in },
        onDefinition: ((Int) -> Void)? = nil
    ) {
        _text = text
        self.language = language
        self.theme = theme
        self.fontSize = fontSize
        self.diagnostics = diagnostics
        _reveal = reveal
        self.onCursorChange = onCursorChange
        self.onDefinition = onDefinition
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    public func makeNSView(context: Context) -> NSScrollView {
        let textView = CodeTextView(usingTextLayoutManager: true)
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.textContainerInset = NSSize(width: 8, height: 12)

        // Code doesn't wrap: the text container grows sideways and the view scrolls.
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width, .height]
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.lineFragmentPadding = 6

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.scrollerStyle = .overlay

        let ruler = LineNumberRuler(textView: textView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true

        let coordinator = context.coordinator
        coordinator.textView = textView
        coordinator.ruler = ruler
        textView.onDefinition = { [weak coordinator] offset in coordinator?.parent.onDefinition?(offset) }
        coordinator.apply(theme: theme, fontSize: fontSize)
        textView.string = text
        coordinator.textDidChangeExternally()

        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            coordinator,
            selector: #selector(Coordinator.viewDidScroll),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        DispatchQueue.main.async {
            textView.window?.makeFirstResponder(textView)
        }
        return scrollView
    }

    public func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let textView = coordinator.textView else { return }
        if coordinator.appliedTheme != theme || coordinator.appliedFontSize != fontSize {
            coordinator.apply(theme: theme, fontSize: fontSize)
            coordinator.highlightNow()
        }
        // Only replace text that changed outside the editor (e.g. a reload from disk).
        if textView.string != text {
            textView.string = text
            coordinator.textDidChangeExternally()
        }
        textView.canJumpToDefinition = onDefinition != nil
        if coordinator.diagnostics != diagnostics {
            coordinator.diagnostics = diagnostics
            coordinator.applyTokens()
        }
        if let range = reveal {
            let length = (textView.string as NSString).length
            let clamped = NSRange(location: min(range.location, length), length: min(range.length, length - min(range.location, length)))
            textView.setSelectedRange(clamped)
            textView.scrollRangeToVisible(clamped)
            textView.window?.makeFirstResponder(textView)
            if clamped.length > 0 { textView.showFindIndicator(for: clamped) }
            DispatchQueue.main.async { reveal = nil }
        }
    }

    @MainActor
    public final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditorView
        weak var textView: CodeTextView?
        weak var ruler: LineNumberRuler?
        var appliedTheme: Theme?
        var appliedFontSize: CGFloat = 0
        private let highlighter: any Highlighter
        private var highlightTask: Task<Void, Never>?
        /// The last tokens computed, and the text they were computed for.
        private var tokens: (text: String, tokens: [Token])?
        var diagnostics: [EditorDiagnostic] = []
        private var baseAttributes: [NSAttributedString.Key: Any] = [:]
        /// NSTextView reports the new selection before `textDidChange`, so an edit marks the
        /// line index stale and whichever callback runs first rebuilds it.
        private var linesNeedRefresh = false

        init(_ parent: CodeEditorView) {
            self.parent = parent
            highlighter = Highlighters.make(for: parent.language)
        }

        func apply(theme: Theme, fontSize: CGFloat) {
            guard let textView else { return }
            appliedTheme = theme
            appliedFontSize = fontSize
            let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            let paragraph = NSMutableParagraphStyle()
            let lineHeight = (fontSize * 1.65).rounded()
            paragraph.minimumLineHeight = lineHeight
            paragraph.maximumLineHeight = lineHeight
            baseAttributes = [.font: font, .foregroundColor: theme.syntax.plain.nsColor, .paragraphStyle: paragraph]

            textView.font = font
            textView.typingAttributes = baseAttributes
            textView.defaultParagraphStyle = paragraph
            textView.backgroundColor = theme.codeBackground.nsColor
            textView.insertionPointColor = theme.accent.nsColor
            textView.selectedTextAttributes = [.backgroundColor: theme.accent.opacity(theme.isDark ? 0.28 : 0.2).nsColor]
            textView.currentLineColor = theme.currentLine.nsColor
            textView.enclosingScrollView?.backgroundColor = theme.codeBackground.nsColor
            textView.enclosingScrollView?.scrollerKnobStyle = theme.isDark ? .light : .dark

            ruler?.font = NSFont.monospacedDigitSystemFont(ofSize: fontSize - 1.5, weight: .regular)
            ruler?.textColor = theme.lineNumber.nsColor
            ruler?.activeTextColor = theme.lineNumberActive.nsColor
            ruler?.backgroundColor = theme.codeBackground.nsColor
            textView.needsDisplay = true
        }

        func textDidChangeExternally() {
            guard let textView else { return }
            ruler?.textDidChange(textView.string as NSString)
            linesNeedRefresh = false
            highlightNow()
        }

        private func refreshLinesIfNeeded(_ textView: NSTextView) {
            guard linesNeedRefresh else { return }
            linesNeedRefresh = false
            ruler?.textDidChange(textView.string as NSString)
        }

        public func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
            linesNeedRefresh = true
            return true
        }

        public func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            refreshLinesIfNeeded(textView)
            scheduleHighlight()
        }

        public func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView else { return }
            refreshLinesIfNeeded(textView)
            let location = textView.selectedRange().location
            ruler?.selectionDidChange(to: location)
            textView.needsDisplay = true
            let text = textView.string as NSString
            let line = ruler?.lineIndex(forOffset: location) ?? 0
            let lineStart = text.lineRange(for: NSRange(location: min(location, text.length), length: 0)).location
            parent.onCursorChange(CursorPosition(line: line + 1, column: location - lineStart + 1))
        }

        public func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) {
                insertNewlineKeepingIndent(textView)
                return true
            }
            if selector == #selector(NSResponder.insertTab(_:)) {
                textView.insertText(String(repeating: " ", count: indentWidth), replacementRange: textView.selectedRange())
                return true
            }
            return false
        }

        @objc func viewDidScroll() {
            ruler?.needsDisplay = true
        }

        private var indentWidth: Int {
            switch parent.language {
            case .python, .swift, .java, .kotlin, .csharp, .rust, .php: 4
            default: 2
            }
        }

        private func insertNewlineKeepingIndent(_ textView: NSTextView) {
            let text = textView.string as NSString
            let selection = textView.selectedRange()
            let lineRange = text.lineRange(for: NSRange(location: selection.location, length: 0))
            let beforeCaret = text.substring(with: NSRange(location: lineRange.location, length: selection.location - lineRange.location))
            var indent = String(beforeCaret.prefix { $0 == " " || $0 == "\t" })
            let trimmed = beforeCaret.trimmingCharacters(in: .whitespaces)
            if let last = trimmed.last, "{[(:".contains(last) {
                if last != ":" || parent.language == .python || parent.language == .yaml {
                    indent += String(repeating: " ", count: indentWidth)
                }
            }
            textView.insertText("\n" + indent, replacementRange: selection)
        }

        /// Re-highlights after typing pauses. Tokens are computed off the main thread (a
        /// tree-sitter pass over a few thousand lines takes tens of milliseconds) and only
        /// applied if the text hasn't changed since.
        private func scheduleHighlight() {
            highlightTask?.cancel()
            highlightTask = Task { @MainActor [weak self, highlighter] in
                try? await Task.sleep(for: .milliseconds(60))
                guard !Task.isCancelled, let text = self?.textView?.string else { return }
                let tokens = await Task.detached(priority: .userInitiated) { highlighter.tokens(in: text) }.value
                guard !Task.isCancelled, let self, self.textView?.string == text else { return }
                self.tokens = (text, tokens)
                self.applyTokens()
            }
        }

        /// Colours the whole document now, reusing the last tokens when the text is unchanged
        /// (for example after a theme switch).
        func highlightNow() {
            guard let text = textView?.string else { return }
            if tokens?.text != text {
                tokens = (text, highlighter.tokens(in: text))
            }
            applyTokens()
        }

        /// Attributes go straight onto the text storage, which doesn't touch undo or the selection.
        func applyTokens() {
            guard let textView, let storage = textView.textStorage, let theme = appliedTheme, let tokens else { return }
            let length = (textView.string as NSString).length
            storage.beginEditing()
            storage.setAttributes(baseAttributes, range: NSRange(location: 0, length: length))
            for token in tokens.tokens where NSMaxRange(token.range) <= length {
                storage.addAttribute(.foregroundColor, value: color(for: token.kind, in: theme), range: token.range)
            }
            var markers: [Int: NSColor] = [:]
            // Most severe last, so an error's underline wins where problems overlap.
            for diagnostic in diagnostics.sorted(by: { rank($0.severity) < rank($1.severity) }) where diagnostic.range.location < max(length, 1) {
                var range = NSIntersectionRange(diagnostic.range, NSRange(location: 0, length: length))
                // An empty range marks a point; underline the word there so it shows.
                if range.length == 0, length > 0 {
                    range = Self.word(at: min(range.location, length - 1), in: textView.string as NSString)
                }
                let color = diagnosticColor(diagnostic.severity, in: theme)
                storage.addAttributes([
                    .underlineStyle: NSUnderlineStyle.thick.rawValue | NSUnderlineStyle.patternDot.rawValue,
                    .underlineColor: color,
                    .toolTip: diagnostic.message,
                ], range: range)
                if let line = ruler?.lineIndex(forOffset: range.location) { markers[line] = color }
            }
            storage.endEditing()
            ruler?.diagnosticMarks = markers
        }

        static func word(at index: Int, in text: NSString) -> NSRange {
            func isWord(_ i: Int) -> Bool {
                guard let scalar = Unicode.Scalar(text.character(at: i)) else { return false }
                return CharacterSet.alphanumerics.contains(scalar) || scalar == "_"
            }
            guard isWord(index) else { return NSRange(location: index, length: 1) }
            var start = index
            var end = index + 1
            while start > 0, isWord(start - 1) { start -= 1 }
            while end < text.length, isWord(end) { end += 1 }
            return NSRange(location: start, length: end - start)
        }

        private func rank(_ severity: EditorDiagnostic.Severity) -> Int {
            switch severity {
            case .note: 0
            case .warning: 1
            case .error: 2
            }
        }

        private func diagnosticColor(_ severity: EditorDiagnostic.Severity, in theme: Theme) -> NSColor {
            switch severity {
            case .error: theme.red.nsColor
            case .warning: theme.amber.nsColor
            case .note: theme.text3.nsColor
            }
        }

        private func color(for kind: TokenKind, in theme: Theme) -> NSColor {
            switch kind {
            case .keyword: theme.syntax.keyword.nsColor
            case .string: theme.syntax.string.nsColor
            case .comment: theme.syntax.comment.nsColor
            case .number: theme.syntax.number.nsColor
            case .type: theme.syntax.type.nsColor
            case .function: theme.syntax.function.nsColor
            }
        }
    }
}

/// Draws a soft band behind the line with the caret.
public final class CodeTextView: NSTextView {
    var currentLineColor: NSColor = .clear
    var canJumpToDefinition = false
    var onDefinition: ((Int) -> Void)?

    /// ⌘-click jumps to the definition of what's under the pointer.
    public override func mouseDown(with event: NSEvent) {
        if canJumpToDefinition, event.modifierFlags.contains(.command) {
            let index = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
            setSelectedRange(NSRange(location: index, length: 0))
            onDefinition?(index)
            return
        }
        super.mouseDown(with: event)
    }

    public override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        guard canJumpToDefinition else { return menu }
        let index = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
        let item = NSMenuItem(title: "Jump to Definition", action: #selector(jumpToDefinition(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = index
        menu.insertItem(item, at: 0)
        menu.insertItem(.separator(), at: 1)
        return menu
    }

    @objc private func jumpToDefinition(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int else { return }
        setSelectedRange(NSRange(location: index, length: 0))
        onDefinition?(index)
    }

    public override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard selectedRange().length == 0,
              let layoutManager = textLayoutManager,
              let contentManager = layoutManager.textContentManager,
              let caret = contentManager.location(contentManager.documentRange.location, offsetBy: selectedRange().location),
              let fragment = layoutManager.textLayoutFragment(for: caret) else { return }
        var frame = fragment.layoutFragmentFrame
        if let line = fragment.textLineFragments.first {
            frame.size.height = line.typographicBounds.height
        }
        let band = NSRect(x: 0, y: frame.minY + textContainerOrigin.y, width: bounds.width, height: frame.height)
        currentLineColor.setFill()
        band.fill()
    }
}
