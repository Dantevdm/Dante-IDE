import AppKit
import DanteEditor
import DanteKit
import SwiftUI

/// Log lines in a read-only text view: new lines are appended to the text storage rather
/// than laid out again, so thousands of lines stay cheap. While `follows` is on it stays
/// pinned to the bottom; scrolling up turns it off, and scrolling back to the bottom turns
/// it on again.
struct LogTextView: NSViewRepresentable {
    let lines: [LogLine]
    let query: String
    let showsService: Bool
    let services: [String]
    let theme: Theme
    @Binding var follows: Bool

    func makeCoordinator() -> Coordinator { Coordinator(follows: $follows) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        let textView = scrollView.documentView as! NSTextView
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 10, height: 8)
        textView.textContainer?.lineFragmentPadding = 4
        textView.layoutManager?.allowsNonContiguousLayout = true
        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.didScroll),
                                               name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.follows = $follows
        let style = Style(query: query, showsService: showsService, services: services, theme: theme, geist: DanteFonts.usesGeist)
        guard let storage = coordinator.textView?.textStorage else { return }

        // Append when the new lines continue the shown ones; otherwise draw them all again.
        let shownIDs = coordinator.shownIDs
        let continues = style == coordinator.style && !shownIDs.isEmpty && lines.count >= shownIDs.count
            && lines.first?.id == shownIDs.first && lines[shownIDs.count - 1].id == shownIDs.last
        if continues {
            let added = lines[shownIDs.count...]
            if !added.isEmpty {
                storage.append(text(for: added, style: style, leadingNewline: true))
                coordinator.shownIDs.append(contentsOf: added.map(\.id))
            }
        } else if lines.map(\.id) != shownIDs || style != coordinator.style {
            storage.setAttributedString(text(for: lines[...], style: style, leadingNewline: false))
            coordinator.shownIDs = lines.map(\.id)
            coordinator.style = style
        }
        // After this update's layout, so the new lines have a height to scroll to.
        if follows { DispatchQueue.main.async { coordinator.scrollToBottom() } }
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
    }

    // MARK: Text

    struct Style: Equatable {
        var query: String
        var showsService: Bool
        var services: [String]
        var theme: Theme
        var geist: Bool
    }

    private func text(for lines: ArraySlice<LogLine>, style: Style, leadingNewline: Bool) -> NSAttributedString {
        let theme = style.theme
        let font = DanteFonts.mono(size: 12)
        let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: theme.text.nsColor]
        let palette = [theme.accent, theme.green, theme.amber, theme.text2].map(\.nsColor)
        let width = (style.services.map(\.count).max() ?? 0) + 2
        let result = NSMutableAttributedString()
        for (offset, line) in lines.enumerated() {
            if offset > 0 || leadingNewline { result.append(NSAttributedString(string: "\n", attributes: base)) }
            if style.showsService {
                let index = style.services.firstIndex(of: line.service) ?? 0
                let padded = line.service.padding(toLength: max(width, line.service.count + 1), withPad: " ", startingAt: 0)
                result.append(NSAttributedString(string: padded, attributes: base.merging([.foregroundColor: palette[index % palette.count]]) { $1 }))
            }
            if let timestamp = line.timestamp {
                result.append(highlighted(timestamp + "  ", color: theme.text3.nsColor, base: base, style: style))
            }
            let color: NSColor = switch line.level {
            case .error: theme.red.nsColor
            case .warning: theme.amber.nsColor
            case .debug: theme.text3.nsColor
            case .info: theme.text.nsColor
            }
            result.append(highlighted(line.message, color: color, base: base, style: style))
        }
        return result
    }

    private func highlighted(_ text: String, color: NSColor, base: [NSAttributedString.Key: Any], style: Style) -> NSAttributedString {
        let attributed = NSMutableAttributedString(string: text, attributes: base.merging([.foregroundColor: color]) { $1 })
        for range in LogFilter.ranges(of: style.query, in: text) {
            attributed.addAttributes([.backgroundColor: style.theme.amber.nsColor.withAlphaComponent(0.35),
                                      .foregroundColor: style.theme.text.nsColor], range: NSRange(range, in: text))
        }
        return attributed
    }

    // MARK: Scrolling

    @MainActor
    final class Coordinator: NSObject {
        var follows: Binding<Bool>
        weak var textView: NSTextView?
        weak var scrollView: NSScrollView?
        var shownIDs: [Int] = []
        var style: Style?
        /// Set while Dante moves the view itself, so that scroll isn't taken as the user's.
        private var scrollingItself = false

        init(follows: Binding<Bool>) {
            self.follows = follows
        }

        func scrollToBottom() {
            guard let textView, follows.wrappedValue else { return }
            scrollingItself = true
            textView.scrollRangeToVisible(NSRange(location: (textView.string as NSString).length, length: 0))
            scrollingItself = false
        }

        @objc func didScroll() {
            guard !scrollingItself, let textView, let scrollView else { return }
            let visible = scrollView.contentView.bounds
            let atBottom = visible.maxY >= textView.frame.height - 24
            if follows.wrappedValue != atBottom { follows.wrappedValue = atBottom }
        }
    }
}
