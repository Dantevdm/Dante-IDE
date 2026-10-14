import Foundation

/// Keeps breakpoints on their code while the file is edited. A breakpoint belongs to the
/// start of its line: an edit after that start leaves it alone, lines wholly below the edit
/// move by the newlines added or removed, and a line deleted with its newline loses it.
public enum BreakpointShift {
    /// `lines` are 1-based; `text` is the file before replacing `range` with `replacement`.
    public static func apply(_ lines: Set<Int>, in text: NSString, replacing range: NSRange, with replacement: String) -> Set<Int> {
        guard !lines.isEmpty, let last = lines.max() else { return lines }
        let added = newlines(in: replacement as NSString, range: NSRange(location: 0, length: (replacement as NSString).length))
        let end = min(range.location + range.length, text.length)
        let removed = newlines(in: text, range: NSRange(location: range.location, length: max(0, end - range.location)))
        guard added != removed || range.length > 0 else { return lines }

        // Each line's start and the position of its newline, up to the last breakpoint.
        var starts: [Int] = [0]
        var breaks: [Int] = []
        var index = 0
        while index < text.length, starts.count <= last {
            if text.character(at: index) == 0x0A {
                breaks.append(index)
                starts.append(index + 1)
            }
            index += 1
        }
        let editLine = starts.lastIndex { $0 <= range.location } ?? 0

        var result: Set<Int> = []
        for line in lines {
            let zero = line - 1
            guard zero < starts.count else { result.insert(line + added - removed); continue }
            let start = starts[zero]
            if start < range.location {
                result.insert(line)
            } else if start >= end {
                result.insert(line + added - removed)
            } else if zero < breaks.count, breaks[zero] < end {
                continue // the whole line went
            } else {
                result.insert(editLine + 1 + added)
            }
        }
        return Set(result.filter { $0 >= 1 })
    }

    private static func newlines(in text: NSString, range: NSRange) -> Int {
        var count = 0
        for index in range.location..<(range.location + range.length) where text.character(at: index) == 0x0A { count += 1 }
        return count
    }
}
