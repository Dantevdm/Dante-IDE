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

/// A TextKit 2 code editor: monospaced, unwrapped, with a line-number gutter,
/// syntax colours from the theme and auto-indent.
///
/// Give each document its own view (`.id(document.id)`) so undo history stays per document.
public struct CodeEditorView: NSViewRepresentable {
    @Binding var text: String
    let language: Language
    let theme: Theme
    var fontSize: CGFloat
    var onCursorChange: (CursorPosition) -> Void

    public init(
        text: Binding<String>,
        language: Language,
        theme: Theme,
        fontSize: CGFloat = 13,
        onCursorChange: @escaping (CursorPosition) -> Void = { _ in }
    ) {
        _text = text
        self.language = language
        self.theme = theme
        self.fontSize = fontSize
        self.onCursorChange = onCursorChange
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

        private func scheduleHighlight() {
            highlightTask?.cancel()
            highlightTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(60))
                guard !Task.isCancelled else { return }
                self?.highlightNow()
            }
        }

        /// Colours the whole document. Attributes go straight onto the text
        /// storage, which doesn't touch undo or the selection.
        func highlightNow() {
            guard let textView, let storage = textView.textStorage, let theme = appliedTheme else { return }
            let text = textView.string
            let tokens = highlighter.tokens(in: text)
            let length = (text as NSString).length
            storage.beginEditing()
            storage.setAttributes(baseAttributes, range: NSRange(location: 0, length: length))
            for token in tokens where NSMaxRange(token.range) <= length {
                storage.addAttribute(.foregroundColor, value: color(for: token.kind, in: theme), range: token.range)
            }
            storage.endEditing()
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
