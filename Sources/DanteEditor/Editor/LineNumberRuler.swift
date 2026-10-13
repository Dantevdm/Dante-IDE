import AppKit
import DanteKit

/// The editor gutter: line numbers for the visible lines, drawn from TextKit 2 layout fragments.
final class LineNumberRuler: NSRulerView {
    var font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular) { didSet { needsDisplay = true } }
    var textColor = NSColor.secondaryLabelColor { didSet { needsDisplay = true } }
    var activeTextColor = NSColor.labelColor { didSet { needsDisplay = true } }
    var backgroundColor = NSColor.textBackgroundColor { didSet { needsDisplay = true } }
    /// Lines that differ from the last commit, and the colour to mark them in.
    var changeMarks: [Int: (change: LineChange, color: NSColor)] = [:] { didSet { needsDisplay = true } }
    /// Lines with a diagnostic, and the colour of the most severe one.
    var diagnosticMarks: [Int: NSColor] = [:] { didSet { if diagnosticMarks != oldValue { needsDisplay = true } } }

    /// Zero-based lines with a breakpoint, drawn as a tag behind the number.
    var breakpoints: Set<Int> = [] { didSet { if breakpoints != oldValue { needsDisplay = true } } }
    var breakpointColor = NSColor.systemBlue { didSet { needsDisplay = true } }
    var breakpointTextColor = NSColor.white { didSet { needsDisplay = true } }
    /// The zero-based line the debugger is stopped on.
    var executionLine: Int? { didSet { if executionLine != oldValue { needsDisplay = true } } }
    var executionColor = NSColor.systemYellow { didSet { needsDisplay = true } }
    /// Clicking a line number toggles a breakpoint there; nil leaves the gutter inert.
    var onToggleBreakpoint: ((Int) -> Void)?

    /// UTF-16 offsets where each line starts.
    private var lineStarts: [Int] = [0]
    private var activeLine = 0

    private weak var textView: NSTextView?

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 52
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    func textDidChange(_ text: NSString) {
        var starts = [0]
        let length = text.length
        var index = 0
        while index < length {
            let range = text.lineRange(for: NSRange(location: index, length: 0))
            index = NSMaxRange(range)
            if index < length || (index == length && length > 0 && text.character(at: length - 1) == 10) {
                starts.append(index)
            }
        }
        lineStarts = starts
        let digits = max(3, String(starts.count).count)
        ruleThickness = CGFloat(digits) * 8 + 28
        needsDisplay = true
    }

    func selectionDidChange(to location: Int) {
        let line = lineIndex(forOffset: location)
        if line != activeLine {
            activeLine = line
            needsDisplay = true
        }
    }

    func lineIndex(forOffset offset: Int) -> Int {
        var low = 0, high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return low
    }

    override func mouseDown(with event: NSEvent) {
        guard let onToggleBreakpoint, let line = line(at: convert(event.locationInWindow, from: nil)) else {
            return super.mouseDown(with: event)
        }
        onToggleBreakpoint(line)
    }

    /// NSRulerView's own press action asks for a tab-stop marker in a sheet. A press has no
    /// line to act on, so it does nothing; Toggle Breakpoint works from the keyboard.
    override func accessibilityPerformPress() -> Bool { true }

    override func resetCursorRects() {
        if onToggleBreakpoint != nil { addCursorRect(bounds, cursor: .pointingHand) }
    }

    /// The zero-based line drawn at a point in the ruler.
    private func line(at point: NSPoint) -> Int? {
        guard let textView, let layoutManager = textView.textLayoutManager,
              let contentManager = layoutManager.textContentManager else { return nil }
        let inText = textView.convert(point, from: self)
        let y = inText.y - textView.textContainerOrigin.y
        guard let fragment = layoutManager.textLayoutFragment(for: NSPoint(x: 0, y: max(y, 0))) else {
            return lineStarts.count - 1
        }
        let offset = contentManager.offset(from: contentManager.documentRange.location, to: fragment.rangeInElement.location)
        var line = lineIndex(forOffset: offset)
        // Wrapped lines and the empty last line: count the line fragments above the point.
        let frame = fragment.layoutFragmentFrame
        if y > frame.minY, let lines = fragment.textLineFragments.last(where: { $0.typographicBounds.minY <= y - frame.minY }),
           lines.characterRange.length == 0, line + 1 < lineStarts.count {
            line += 1
        }
        return line
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        backgroundColor.setFill()
        bounds.fill()

        guard let textView,
              let layoutManager = textView.textLayoutManager,
              let contentManager = layoutManager.textContentManager else { return }

        let visible = textView.visibleRect
        let documentStart = contentManager.documentRange.location
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .right

        func draw(line: Int, top: CGFloat, height: CGFloat) {
            let hasBreakpoint = breakpoints.contains(line)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: hasBreakpoint ? breakpointTextColor : (line == activeLine ? activeTextColor : textColor),
                .paragraphStyle: paragraph,
            ]
            let label = "\(line + 1)" as NSString
            let size = label.size(withAttributes: attributes)
            let point = convert(NSPoint(x: 0, y: top + textView.textContainerOrigin.y), from: textView)
            let box = NSRect(x: 0, y: point.y + (height - size.height) / 2, width: ruleThickness - 14, height: size.height)
            if hasBreakpoint {
                // A tag pointing at the code, like Xcode's.
                let tag = NSRect(x: 4, y: point.y + 2, width: ruleThickness - 12, height: max(height - 4, 10))
                let path = NSBezierPath()
                let tip: CGFloat = 5
                path.move(to: NSPoint(x: tag.minX + 2, y: tag.minY))
                path.line(to: NSPoint(x: tag.maxX - tip, y: tag.minY))
                path.line(to: NSPoint(x: tag.maxX, y: tag.midY))
                path.line(to: NSPoint(x: tag.maxX - tip, y: tag.maxY))
                path.line(to: NSPoint(x: tag.minX + 2, y: tag.maxY))
                path.appendArc(withCenter: NSPoint(x: tag.minX + 2, y: tag.midY), radius: tag.height / 2, startAngle: 90, endAngle: 270)
                path.close()
                breakpointColor.setFill()
                path.fill()
            }
            label.draw(in: box, withAttributes: attributes)
            if line == executionLine {
                // An arrow at the gutter's edge for the line the program is stopped on.
                let mid = point.y + height / 2
                let arrow = NSBezierPath()
                arrow.move(to: NSPoint(x: ruleThickness - 9, y: mid - 5))
                arrow.line(to: NSPoint(x: ruleThickness - 2, y: mid))
                arrow.line(to: NSPoint(x: ruleThickness - 9, y: mid + 5))
                arrow.close()
                executionColor.setFill()
                arrow.fill()
            }
            if let mark = changeMarks[line] {
                mark.color.setFill()
                let x = ruleThickness - 5
                let lineTop = point.y
                switch mark.change {
                case .added, .modified:
                    NSRect(x: x, y: lineTop, width: 3, height: height).fill()
                case .deleted:
                    let path = NSBezierPath()
                    path.move(to: NSPoint(x: x - 1, y: lineTop - 4))
                    path.line(to: NSPoint(x: x + 4, y: lineTop))
                    path.line(to: NSPoint(x: x - 1, y: lineTop + 4))
                    path.close()
                    path.fill()
                }
            }
            if let marker = diagnosticMarks[line] {
                marker.setFill()
                NSBezierPath(ovalIn: NSRect(x: 7, y: box.midY - 3, width: 6, height: 6)).fill()
            }
        }

        var lastLine = -1
        var lastBottom: CGFloat = 0
        var lastHeight: CGFloat = 18
        let start = layoutManager.textLayoutFragment(for: NSPoint(x: 0, y: visible.minY))?.rangeInElement.location ?? documentStart
        layoutManager.enumerateTextLayoutFragments(from: start, options: [.ensuresLayout]) { fragment in
            let frame = fragment.layoutFragmentFrame
            if frame.minY > visible.maxY { return false }
            let offset = contentManager.offset(from: documentStart, to: fragment.rangeInElement.location)
            let line = lineIndex(forOffset: offset)
            let lineHeight = fragment.textLineFragments.first?.typographicBounds.height ?? frame.height
            draw(line: line, top: frame.minY, height: lineHeight)
            lastLine = line
            lastHeight = lineHeight
            // The last paragraph's fragment also holds the empty line after a trailing newline,
            // so its frame is one line taller than the text in it.
            let textBottom = fragment.textLineFragments.last { $0.characterRange.length > 0 }?.typographicBounds.maxY
            lastBottom = textBottom.map { frame.minY + $0 } ?? frame.maxY
            return true
        }
        // The empty line after a trailing newline has no paragraph of its own.
        if lastLine >= 0, lastLine + 1 < lineStarts.count, lastBottom <= visible.maxY {
            draw(line: lastLine + 1, top: lastBottom, height: lastHeight)
        } else if lastLine < 0 {
            draw(line: 0, top: 0, height: lastHeight)
        }
    }
}
