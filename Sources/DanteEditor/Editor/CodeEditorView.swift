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
    /// Zero-based lines that differ from the last commit.
    var lineChanges: [Int: LineChange]
    @Binding var reveal: NSRange?
    var onCursorChange: (CursorPosition) -> Void
    /// Called with the UTF-16 offset of a ⌘-click or "Jump to Definition".
    var onDefinition: ((Int) -> Void)?
    /// Markdown about the symbol at a UTF-16 offset, shown when the pointer rests on it.
    var hover: ((Int) async -> String?)?
    /// Suggestions while typing, from a language server.
    var completion: CompletionSource?
    /// Language-server actions for the editor's context menu.
    var actions: EditorActions?
    /// Spaces per indent level; nil uses the language's usual width.
    var indentWidth: Int?
    var wrapsLines: Bool
    /// Off: the completion list opens only with ⌃Space.
    var completesWhileTyping: Bool

    public init(
        text: Binding<String>,
        language: Language,
        theme: Theme,
        fontSize: CGFloat = 13,
        diagnostics: [EditorDiagnostic] = [],
        lineChanges: [Int: LineChange] = [:],
        reveal: Binding<NSRange?> = .constant(nil),
        onCursorChange: @escaping (CursorPosition) -> Void = { _ in },
        onDefinition: ((Int) -> Void)? = nil,
        hover: ((Int) async -> String?)? = nil,
        completion: CompletionSource? = nil,
        actions: EditorActions? = nil,
        indentWidth: Int? = nil,
        wrapsLines: Bool = false,
        completesWhileTyping: Bool = true
    ) {
        _text = text
        self.language = language
        self.theme = theme
        self.fontSize = fontSize
        self.diagnostics = diagnostics
        self.lineChanges = lineChanges
        _reveal = reveal
        self.onCursorChange = onCursorChange
        self.onDefinition = onDefinition
        self.hover = hover
        self.completion = completion
        self.actions = actions
        self.indentWidth = indentWidth
        self.wrapsLines = wrapsLines
        self.completesWhileTyping = completesWhileTyping
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

        textView.isVerticallyResizable = true
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width, .height]
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
        textView.onHover = { [weak coordinator] index in coordinator?.hover(at: index) }
        let completion = CompletionController(textView: textView)
        completion.source = self.completion
        coordinator.completion = completion
        textView.onCompleteRequest = { [weak completion] in completion?.requestNow() }
        textView.onResign = { [weak completion] in completion?.close() }
        textView.actions = actions
        coordinator.apply(theme: theme, fontSize: fontSize)
        coordinator.apply(wrapsLines: wrapsLines)
        textView.string = text
        coordinator.textDidChangeExternally()

        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            coordinator,
            selector: #selector(Coordinator.viewDidScroll),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        scrollView.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            coordinator,
            selector: #selector(Coordinator.clipViewResized),
            name: NSView.frameDidChangeNotification,
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
        let themeChanged = coordinator.appliedTheme != theme
        if themeChanged || coordinator.appliedFontSize != fontSize {
            coordinator.apply(theme: theme, fontSize: fontSize)
            coordinator.highlightNow()
        }
        if coordinator.appliedWrap != wrapsLines { coordinator.apply(wrapsLines: wrapsLines) }
        coordinator.completion?.autoTriggers = completesWhileTyping
        // Only replace text that changed outside the editor (a reload from disk, a rename or a format).
        if textView.string != text {
            coordinator.replaceExternally(with: text)
        }
        textView.canJumpToDefinition = onDefinition != nil
        textView.canHover = hover != nil
        textView.actions = actions
        coordinator.completion?.source = completion
        if themeChanged { coordinator.completion?.apply(theme: theme, fontSize: fontSize) }
        if coordinator.lineChanges != lineChanges || themeChanged {
            coordinator.lineChanges = lineChanges
            coordinator.applyLineChanges()
        }
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
        var lineChanges: [Int: LineChange] = [:]
        var completion: CompletionController?
        /// The character typed in the edit under way, for opening completions.
        private var typed: Character?
        private var isReplacingExternally = false
        private var isEditing = false

        func applyLineChanges() {
            guard let theme = appliedTheme else { return }
            ruler?.changeMarks = lineChanges.mapValues { change in
                let color: NSColor = switch change {
                case .added: theme.green.nsColor
                case .modified: theme.accent.nsColor
                case .deleted: theme.red.nsColor
                }
                return (change, color)
            }
        }
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
            completion?.apply(theme: theme, fontSize: fontSize)
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

        /// Swaps in text that changed elsewhere as one undoable edit covering only the part
        /// that differs, so the caret and scroll position stay put.
        func replaceExternally(with text: String) {
            guard let textView else { return }
            let old = textView.string as NSString, new = text as NSString
            var prefix = 0
            let shorter = min(old.length, new.length)
            while prefix < shorter, old.character(at: prefix) == new.character(at: prefix) { prefix += 1 }
            var suffix = 0
            while suffix < shorter - prefix, old.character(at: old.length - 1 - suffix) == new.character(at: new.length - 1 - suffix) { suffix += 1 }
            let range = NSRange(location: prefix, length: old.length - prefix - suffix)
            let replacement = new.substring(with: NSRange(location: prefix, length: new.length - prefix - suffix))
            isReplacingExternally = true
            if textView.shouldChangeText(in: range, replacementString: replacement) {
                textView.textStorage?.replaceCharacters(in: range, with: replacement)
                textView.didChangeText()
            } else {
                textView.string = text
            }
            isReplacingExternally = false
            isEditing = false
            typed = nil
            textDidChangeExternally()
        }

        private(set) var appliedWrap: Bool?

        /// Unwrapped, the text container grows sideways and the view scrolls; wrapped, it is
        /// as wide as the visible area.
        func apply(wrapsLines: Bool) {
            guard let textView, let container = textView.textContainer else { return }
            appliedWrap = wrapsLines
            let huge = CGFloat.greatestFiniteMagnitude
            textView.isHorizontallyResizable = !wrapsLines
            textView.enclosingScrollView?.hasHorizontalScroller = !wrapsLines
            container.widthTracksTextView = wrapsLines
            if wrapsLines {
                fitWidthToClipView()
            } else {
                container.containerSize = NSSize(width: huge, height: huge)
            }
            ruler?.needsDisplay = true
        }

        @objc func clipViewResized() {
            if appliedWrap == true { fitWidthToClipView() }
        }

        private func fitWidthToClipView() {
            guard let textView, let clip = textView.enclosingScrollView?.contentView else { return }
            // The line-number gutter sits inside the clip view (its bounds start at minus the
            // gutter's width), so the text gets what lies right of zero.
            let width = clip.bounds.maxX
            guard width > 0, abs(textView.frame.width - width) > 0.5 else { return }
            textView.setFrameSize(NSSize(width: width, height: textView.frame.height))
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
            isEditing = true
            typed = replacementString?.count == 1 ? replacementString?.first : nil
            return true
        }

        public func textDidChange(_ notification: Notification) {
            guard let textView, !isReplacingExternally else { return }
            closeHover()
            parent.text = textView.string
            refreshLinesIfNeeded(textView)
            scheduleHighlight()
            isEditing = false
            completion?.textChanged(typed: typed)
            typed = nil
        }

        public func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView else { return }
            refreshLinesIfNeeded(textView)
            // Clicking or arrowing elsewhere closes the list; typing keeps it.
            if !isEditing, completion?.isShowing == true { completion?.close() }
            let location = textView.selectedRange().location
            ruler?.selectionDidChange(to: location)
            textView.needsDisplay = true
            let text = textView.string as NSString
            let line = ruler?.lineIndex(forOffset: location) ?? 0
            let lineStart = text.lineRange(for: NSRange(location: min(location, text.length), length: 0)).location
            parent.onCursorChange(CursorPosition(line: line + 1, column: location - lineStart + 1))
        }

        public func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if completion?.handle(selector) == true { return true }
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
            // The gutter widens when line numbers gain a digit.
            if appliedWrap == true { fitWidthToClipView() }
            if completion?.isShowing == true { completion?.close() }
        }

        private var indentWidth: Int {
            if let width = parent.indentWidth, width > 0 { return width }
            switch parent.language {
            case .python, .swift, .java, .kotlin, .csharp, .rust, .php: return 4
            default: return 2
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

        // MARK: Hover

        private var hoverTask: Task<Void, Never>?
        private var hoverPopover: NSPopover?
        private var hoverRange: NSRange?

        /// The pointer rested on `index` (nil when it left the text or typing started).
        func hover(at index: Int?) {
            guard let textView, let index else {
                hoverTask?.cancel()
                return
            }
            let text = textView.string as NSString
            guard index < text.length else { return closeHover() }
            let word = Self.word(at: index, in: text)
            if let hoverRange, NSLocationInRange(index, hoverRange) { return }
            closeHover()
            guard word.length > 1 || CharacterSet.alphanumerics.contains(Unicode.Scalar(text.character(at: index)) ?? " "),
                  let provider = parent.hover else { return }
            hoverTask?.cancel()
            hoverTask = Task { @MainActor [weak self] in
                guard let markdown = await provider(index), !Task.isCancelled, let self, let textView = self.textView,
                      let theme = self.appliedTheme else { return }
                self.showHover(markdown, for: word, in: textView, theme: theme)
            }
        }

        private func showHover(_ markdown: String, for range: NSRange, in textView: NSTextView, theme: Theme) {
            guard textView.window?.isKeyWindow == true else { return }
            var actual = NSRange()
            let screenRect = textView.firstRect(forCharacterRange: range, actualRange: &actual)
            guard let window = textView.window, screenRect != .zero else { return }
            let rect = textView.convert(window.convertFromScreen(screenRect), from: nil)
            let popover = NSPopover()
            popover.behavior = .semitransient
            popover.animates = false
            popover.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
            popover.contentViewController = NSHostingController(rootView: HoverView(markdown: markdown, theme: theme, fontSize: appliedFontSize))
            popover.show(relativeTo: rect, of: textView, preferredEdge: .maxY)
            hoverPopover = popover
            hoverRange = range
        }

        func closeHover() {
            hoverTask?.cancel()
            hoverPopover?.close()
            hoverPopover = nil
            hoverRange = nil
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

/// What the editor's context menu offers besides editing, each given the UTF-16 offset clicked.
public struct EditorActions {
    public var references: ((Int) -> Void)?
    public var rename: ((Int) -> Void)?
    public var format: (() -> Void)?
    public var askClaude: ((NSRange) -> Void)?

    public init(references: ((Int) -> Void)? = nil, rename: ((Int) -> Void)? = nil, format: (() -> Void)? = nil, askClaude: ((NSRange) -> Void)? = nil) {
        self.references = references
        self.rename = rename
        self.format = format
        self.askClaude = askClaude
    }
}

/// Draws a soft band behind the line with the caret.
public final class CodeTextView: NSTextView {
    var currentLineColor: NSColor = .clear
    var canJumpToDefinition = false
    var onDefinition: ((Int) -> Void)?
    var canHover = false
    /// Where the pointer rests, after a pause; nil when it moves off the text.
    var onHover: ((Int?) -> Void)?
    var onCompleteRequest: (() -> Void)?
    var onResign: (() -> Void)?
    var actions: EditorActions?

    /// ⌥Escape and F5 come here: show completions.
    public override func complete(_ sender: Any?) {
        if let onCompleteRequest { onCompleteRequest() } else { super.complete(sender) }
    }

    public override func keyDown(with event: NSEvent) {
        // ⌃Space also asks for completions.
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .control, event.charactersIgnoringModifiers == " " {
            onCompleteRequest?()
            return
        }
        super.keyDown(with: event)
    }

    public override func resignFirstResponder() -> Bool {
        onResign?()
        return super.resignFirstResponder()
    }
    private var hoverTimer: Timer?
    private var hoverTracking: NSTrackingArea?

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverTracking = area
    }

    public override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        guard canHover else { return }
        hoverTimer?.invalidate()
        let point = convert(event.locationInWindow, from: nil)
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.reportHover(at: point) }
        }
    }

    public override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hoverTimer?.invalidate()
        onHover?(nil)
    }

    private func reportHover(at point: NSPoint) {
        // Only over a glyph: past the end of a line, the nearest index isn't under the pointer.
        guard let layoutManager = textLayoutManager,
              let fragment = layoutManager.textLayoutFragment(for: CGPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)) else {
            return onHover?(nil) ?? ()
        }
        let local = CGPoint(x: point.x - textContainerOrigin.x - fragment.layoutFragmentFrame.minX,
                            y: point.y - textContainerOrigin.y - fragment.layoutFragmentFrame.minY)
        guard fragment.textLineFragments.contains(where: { $0.typographicBounds.contains(local) }) else {
            return onHover?(nil) ?? ()
        }
        guard let window else { return }
        // NSTextInputClient's lookup takes screen coordinates and returns the character under them.
        let screenPoint = window.convertToScreen(convert(NSRect(origin: point, size: .zero), to: nil)).origin
        onHover?(characterIndex(for: screenPoint))
    }


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
        let index = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
        var items: [NSMenuItem] = []
        func add(_ title: String, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = index
            items.append(item)
        }
        if canJumpToDefinition { add("Jump to Definition", #selector(jumpToDefinition(_:))) }
        if actions?.references != nil { add("Find References", #selector(findReferences(_:))) }
        if actions?.rename != nil { add("Rename Symbol…", #selector(renameSymbol(_:))) }
        if actions?.format != nil { add("Format Document", #selector(formatDocument(_:))) }
        if actions?.askClaude != nil, selectedRange().length > 0 { add("Ask Claude About Selection…", #selector(askClaude(_:))) }
        guard !items.isEmpty else { return menu }
        for (offset, item) in items.enumerated() { menu.insertItem(item, at: offset) }
        menu.insertItem(.separator(), at: items.count)
        return menu
    }

    @objc private func findReferences(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int else { return }
        actions?.references?(index)
    }

    @objc private func renameSymbol(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int else { return }
        setSelectedRange(NSRange(location: index, length: 0))
        actions?.rename?(index)
    }

    @objc private func formatDocument(_ sender: NSMenuItem) {
        actions?.format?()
    }

    @objc private func askClaude(_ sender: NSMenuItem) {
        actions?.askClaude?(selectedRange())
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
