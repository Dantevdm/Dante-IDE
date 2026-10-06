import AppKit
import DanteKit
import Observation
import SwiftUI

/// A suggestion the editor can insert. Built from a language server's completion items by
/// the app; the editor only needs what to show and what to insert.
public struct EditorCompletion: Identifiable, Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case function, variable, property, type, keyword, module, constant, snippet, other
    }

    public var id: String
    public var label: String
    public var detail: String?
    public var documentation: String?
    public var kind: Kind
    public var insertText: String
    public var isSnippet: Bool
    /// The UTF-16 range the item replaces, as of the request; it's widened to the caret
    /// when inserted. nil means the identifier before the caret.
    public var replaceRange: NSRange?
    public var sortText: String
    public var filterText: String

    public init(id: String, label: String, detail: String? = nil, documentation: String? = nil, kind: Kind, insertText: String,
                isSnippet: Bool = false, replaceRange: NSRange? = nil, sortText: String, filterText: String) {
        self.id = id
        self.label = label
        self.detail = detail
        self.documentation = documentation
        self.kind = kind
        self.insertText = insertText
        self.isSnippet = isSnippet
        self.replaceRange = replaceRange
        self.sortText = sortText
        self.filterText = filterText
    }

    /// Ranks items for what's been typed: prefix matches first, then fuzzy score, then the
    /// server's own order.
    public static func rank(_ items: [EditorCompletion], for query: String, limit: Int = 200) -> [EditorCompletion] {
        guard !query.isEmpty else { return Array(items.sorted { $0.sortText < $1.sortText }.prefix(limit)) }
        let lower = query.lowercased()
        var scored: [(item: EditorCompletion, score: Int)] = []
        for item in items {
            guard let match = FuzzyMatch.match(query, in: item.filterText) else { continue }
            var score = match.score
            if item.filterText.hasPrefix(query) { score += 100 } else if item.filterText.lowercased().hasPrefix(lower) { score += 60 }
            scored.append((item, score))
        }
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.item.sortText < $1.item.sortText }
        return Array(scored.prefix(limit).map(\.item))
    }
}

/// Where completions come from for one editor.
public struct CompletionSource {
    /// Characters that open the list straight away, such as `.`.
    public var triggers: Set<Character>
    /// Suggestions at a UTF-16 offset; the character is the one just typed, if any.
    public var fetch: @MainActor (Int, Character?) async -> [EditorCompletion]

    public init(triggers: Set<Character>, fetch: @escaping @MainActor (Int, Character?) async -> [EditorCompletion]) {
        self.triggers = triggers
        self.fetch = fetch
    }
}

@MainActor
@Observable
final class CompletionModel {
    var items: [EditorCompletion] = []
    var selected = 0
    var query = ""
    var theme: Theme = .dark
    var fontSize: CGFloat = 13
    var accept: (EditorCompletion) -> Void = { _ in }

    var current: EditorCompletion? { items.indices.contains(selected) ? items[selected] : nil }
}

/// Opens, filters and inserts completions for a text view. The list floats over the editor
/// under the caret (above it near the bottom); while it shows, the arrow keys, Return, Tab
/// and Escape belong to it.
@MainActor
final class CompletionController {
    private weak var textView: NSTextView?
    private let model = CompletionModel()
    private var panel: NSHostingView<CompletionList>?
    private var all: [EditorCompletion] = []
    /// Where the word being completed starts.
    private var anchor = 0
    private var fetchTask: Task<Void, Never>?
    var source: CompletionSource?
    /// Off: typing doesn't open the list (⌃Space still does), though it still filters an open one.
    var autoTriggers = true

    var isShowing: Bool { panel?.superview != nil && panel?.isHidden == false }

    init(textView: NSTextView) {
        self.textView = textView
        model.accept = { [weak self] item in self?.insert(item) }
    }

    func apply(theme: Theme, fontSize: CGFloat) {
        model.theme = theme
        model.fontSize = fontSize
    }

    /// Called after every edit with the character typed, if a single one was.
    func textChanged(typed: Character?) {
        guard let textView, let source else { return }
        let caret = textView.selectedRange().location
        if isShowing {
            let prefix = identifierStart(before: caret)
            if prefix != anchor && !(typed.map { source.triggers.contains($0) } ?? false) {
                close()
            } else {
                refilter()
                scheduleFetch(trigger: nil, delay: 0.12)
                return
            }
        }
        guard let typed, autoTriggers else { return }
        if source.triggers.contains(typed) {
            anchor = caret
            scheduleFetch(trigger: typed, delay: 0)
        } else if Self.isIdentifier(typed), caret - identifierStart(before: caret) >= 2 {
            anchor = identifierStart(before: caret)
            scheduleFetch(trigger: nil, delay: 0.12)
        }
    }

    /// ⌃Space or ⌥Escape: ask now, whatever was typed.
    func requestNow() {
        guard let textView, source != nil else { return }
        anchor = identifierStart(before: textView.selectedRange().location)
        scheduleFetch(trigger: nil, delay: 0)
    }

    /// Keys the list handles while it's open. Returns true when it used the key.
    func handle(_ selector: Selector) -> Bool {
        guard isShowing else { return false }
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            model.selected = min(model.selected + 1, model.items.count - 1)
        case #selector(NSResponder.moveUp(_:)):
            model.selected = max(model.selected - 1, 0)
        case #selector(NSResponder.pageDown(_:)), #selector(NSResponder.scrollPageDown(_:)):
            model.selected = min(model.selected + 8, model.items.count - 1)
        case #selector(NSResponder.pageUp(_:)), #selector(NSResponder.scrollPageUp(_:)):
            model.selected = max(model.selected - 8, 0)
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
            if let item = model.current { insert(item) } else { close() }
        case #selector(NSResponder.cancelOperation(_:)):
            close()
        case #selector(NSResponder.moveLeft(_:)), #selector(NSResponder.moveRight(_:)):
            close()
            return false
        default:
            return false
        }
        return true
    }

    func close() {
        fetchTask?.cancel()
        panel?.isHidden = true
        all = []
        model.items = []
    }

    // MARK: Private

    private func scheduleFetch(trigger: Character?, delay: Double) {
        guard let textView, let source else { return }
        fetchTask?.cancel()
        fetchTask = Task { @MainActor [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled else { return }
            let offset = textView.selectedRange().location
            let items = await source.fetch(offset, trigger)
            guard !Task.isCancelled, let self else { return }
            // The caret may have moved on while the server thought; drop stale answers.
            guard self.identifierStart(before: textView.selectedRange().location) == self.anchor || trigger != nil else { return }
            self.all = items
            self.refilter()
        }
    }

    private func refilter() {
        guard let textView else { return }
        let caret = textView.selectedRange().location
        let text = textView.string as NSString
        let query = caret >= anchor && caret <= text.length ? text.substring(with: NSRange(location: anchor, length: caret - anchor)) : ""
        let previous = model.current?.id
        model.query = query
        model.items = EditorCompletion.rank(all, for: query)
        model.selected = model.items.firstIndex { $0.id == previous } ?? 0
        // Nothing to offer, or the only suggestion is exactly what's typed: get out of the way.
        if model.items.isEmpty || (model.items.count == 1 && model.items[0].insertText == query) {
            close()
        } else {
            show()
        }
    }

    private func show() {
        guard let textView, let scrollView = textView.enclosingScrollView, let window = textView.window else { return }
        var actual = NSRange()
        let screenRect = textView.firstRect(forCharacterRange: NSRange(location: anchor, length: 0), actualRange: &actual)
        guard screenRect != .zero else { return }
        // Caret rect in the scroll view, which isn't flipped: y grows upwards.
        let caret = scrollView.convert(window.convertFromScreen(screenRect), from: nil)
        let panel = self.panel ?? makePanel(in: scrollView)
        let rows = min(model.items.count, 10)
        let rowHeight = (model.fontSize * 1.75).rounded()
        let docHeight: CGFloat = model.current?.documentation == nil && model.current?.detail == nil ? 0 : 44
        let size = NSSize(width: min(460, scrollView.bounds.width - 16), height: CGFloat(rows) * rowHeight + 10 + docHeight)
        var origin = NSPoint(x: caret.minX - 30, y: caret.minY - size.height - 4)
        if origin.y < 4 { origin.y = caret.maxY + 4 }
        origin.x = max(8, min(origin.x, scrollView.bounds.width - size.width - 8))
        panel.frame = NSRect(origin: origin, size: size)
        panel.isHidden = false
    }

    private func makePanel(in scrollView: NSScrollView) -> NSHostingView<CompletionList> {
        let panel = NSHostingView(rootView: CompletionList(model: model))
        panel.wantsLayer = true
        panel.shadow = {
            let shadow = NSShadow()
            shadow.shadowBlurRadius = 12
            shadow.shadowOffset = NSSize(width: 0, height: -4)
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
            return shadow
        }()
        scrollView.addSubview(panel, positioned: .above, relativeTo: nil)
        self.panel = panel
        return panel
    }

    private func insert(_ item: EditorCompletion) {
        guard let textView else { return }
        let caret = textView.selectedRange().location
        let start = min(item.replaceRange?.location ?? anchor, caret)
        // A server range ends where the request was made; take in what's been typed since.
        let end = max(caret, item.replaceRange.map(NSMaxRange) ?? caret)
        let range = NSRange(location: start, length: end - start)
        let expanded = item.isSnippet ? Snippet.expand(item.insertText) : (item.insertText, nil)
        close()
        guard textView.shouldChangeText(in: range, replacementString: expanded.0) else { return }
        textView.insertText(expanded.0, replacementRange: range)
        if let selection = expanded.1 {
            textView.setSelectedRange(NSRange(location: start + selection.location, length: selection.length))
        }
    }

    private func identifierStart(before caret: Int) -> Int {
        guard let textView else { return caret }
        let text = textView.string as NSString
        var start = min(caret, text.length)
        while start > 0, let scalar = Unicode.Scalar(text.character(at: start - 1)), Self.isIdentifier(Character(scalar)) {
            start -= 1
        }
        return start
    }

    static func isIdentifier(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_" || character == "$"
    }
}

/// The list itself: a kind badge, the label with typed characters emphasised, the detail
/// on the right, and the selected item's documentation underneath.
struct CompletionList: View {
    let model: CompletionModel

    var body: some View {
        let theme = model.theme
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                            row(item, selected: index == model.selected)
                                .id(item.id)
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) { model.accept(item) }
                                .onTapGesture { model.selected = index }
                        }
                    }
                    .padding(5)
                }
                // A fresh list per query: reusing rows across filters can leave stale ones drawn.
                .id(model.query)
                .onChange(of: model.selected) { _, index in
                    if model.items.indices.contains(index) { proxy.scrollTo(model.items[index].id) }
                }
            }
            if let item = model.current, item.documentation != nil || item.detail != nil {
                Rectangle().fill(theme.line.color).frame(height: 1)
                VStack(alignment: .leading, spacing: 2) {
                    if let detail = item.detail {
                        Text(detail).font(.system(size: model.fontSize - 1.5, design: .monospaced)).foregroundStyle(theme.text2.color).lineLimit(1)
                    }
                    if let documentation = item.documentation {
                        Text(documentation.replacingOccurrences(of: "\n", with: " ")).font(.system(size: 11)).foregroundStyle(theme.text3.color).lineLimit(1)
                    }
                }
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: 43, alignment: .leading)
            }
        }
        .background(theme.card.color)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(theme.line2.color))
    }

    private func row(_ item: EditorCompletion, selected: Bool) -> some View {
        let theme = model.theme
        return HStack(spacing: 8) {
            Text(badge(item.kind))
                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                .foregroundStyle(tint(item.kind))
                .frame(width: 18, height: 16)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(tint(item.kind).opacity(0.14)))
            Text(highlighted(item.label))
                .font(.system(size: model.fontSize - 0.5, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            if let detail = item.detail {
                Text(detail)
                    .font(.system(size: model.fontSize - 2, design: .monospaced))
                    .foregroundStyle(theme.text3.color)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: 170, alignment: .trailing)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: (model.fontSize * 1.75).rounded())
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(selected ? theme.accentTint.color : .clear))
    }

    private func highlighted(_ label: String) -> AttributedString {
        var text = AttributedString(label)
        text.foregroundColor = model.theme.text.color
        guard let match = FuzzyMatch.match(model.query, in: label) else { return text }
        let characters = Array(label)
        for index in match.indices where index < characters.count {
            let lower = text.index(text.startIndex, offsetByCharacters: index)
            let upper = text.index(lower, offsetByCharacters: 1)
            text[lower..<upper].foregroundColor = model.theme.accent.color
            text[lower..<upper].font = .system(size: model.fontSize - 0.5, weight: .bold, design: .monospaced)
        }
        return text
    }

    private func badge(_ kind: EditorCompletion.Kind) -> String {
        switch kind {
        case .function: "ƒ"
        case .variable: "v"
        case .property: "p"
        case .type: "T"
        case .keyword: "k"
        case .module: "m"
        case .constant: "c"
        case .snippet: "{}"
        case .other: "·"
        }
    }

    private func tint(_ kind: EditorCompletion.Kind) -> Color {
        let theme = model.theme
        return switch kind {
        case .function: theme.syntax.function.color
        case .type: theme.syntax.type.color
        case .keyword: theme.syntax.keyword.color
        case .constant: theme.syntax.number.color
        case .snippet, .module: theme.amber.color
        default: theme.accent.color
        }
    }
}

