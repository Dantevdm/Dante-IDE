import Foundation

/// `.dante/phases/<phase>.md`: what a phase is for and its checklists, as plain markdown.
///
///     # Build
///
///     Turn the agreed design into working, reviewed code.
///
///     ## Ready when
///     - [x] Design phase done
///
///     ## Done when
///     - [ ] API contract frozen
///
/// Checklists are guidance, never gates.
public struct PhaseDoc: Equatable, Sendable {
    public struct Item: Equatable, Sendable, Identifiable {
        /// Line number in the file (0-based), used to toggle the box in place.
        public var line: Int
        public var text: String
        public var done: Bool
        public var id: Int { line }
    }

    public var summary: String
    public var readyWhen: [Item]
    public var doneWhen: [Item]
    public var markdown: String

    public static func parse(_ markdown: String) -> PhaseDoc {
        var summary: [String] = []
        var readyWhen: [Item] = [], doneWhen: [Item] = []
        var section = Section.intro

        for (number, line) in markdown.components(separatedBy: "\n").enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("## ") {
                let heading = trimmed.dropFirst(3).lowercased()
                section = heading.contains("ready") || heading.contains("start") ? .ready
                    : heading.contains("done") || heading.contains("exit") ? .done : .other
                continue
            }
            if trimmed.hasPrefix("# ") { continue }
            switch section {
            case .intro:
                if !trimmed.isEmpty { summary.append(trimmed) } else if !summary.isEmpty { section = .other }
            case .ready, .done:
                guard let item = checklistItem(trimmed, line: number) else { continue }
                if section == .ready { readyWhen.append(item) } else { doneWhen.append(item) }
            case .other:
                continue
            }
        }
        return PhaseDoc(summary: summary.joined(separator: " "), readyWhen: readyWhen, doneWhen: doneWhen, markdown: markdown)
    }

    /// The markdown with one item's box ticked or cleared.
    public func toggling(_ item: Item) -> String {
        var lines = markdown.components(separatedBy: "\n")
        guard lines.indices.contains(item.line) else { return markdown }
        let line = lines[item.line]
        lines[item.line] = item.done
            ? line.replacingOccurrences(of: "[x]", with: "[ ]").replacingOccurrences(of: "[X]", with: "[ ]")
            : line.replacingOccurrences(of: "[ ]", with: "[x]")
        return lines.joined(separator: "\n")
    }

    /// The app template's starting checklist; `Lifecycle.phaseDocTemplate` picks the project's own.
    public static func template(for phase: String) -> String {
        LifecycleTemplate.app.phaseDoc(phase)
    }

    private enum Section { case intro, ready, done, other }

    private static func checklistItem(_ line: String, line number: Int) -> Item? {
        for prefix in ["- [ ] ", "* [ ] "] where line.hasPrefix(prefix) {
            return Item(line: number, text: String(line.dropFirst(prefix.count)), done: false)
        }
        for prefix in ["- [x] ", "- [X] ", "* [x] ", "* [X] "] where line.hasPrefix(prefix) {
            return Item(line: number, text: String(line.dropFirst(prefix.count)), done: true)
        }
        return nil
    }
}

public extension Lifecycle {
    /// `project.yaml` with `lifecycle.current` set to `phase`, editing the line in place so
    /// comments and other keys survive. Adds the key or block if it's missing.
    static func settingCurrent(_ phase: String, inProjectYAML yaml: String) -> String {
        var lines = yaml.components(separatedBy: "\n")
        let value = phase.lowercased()
        guard let blockStart = lines.firstIndex(where: { $0.hasPrefix("lifecycle:") }) else {
            if lines.last == "" { lines.removeLast() }
            lines += ["", "lifecycle:", "  current: \(value)", ""]
            return lines.joined(separator: "\n")
        }
        var index = blockStart + 1
        var childIndent = "  "
        while index < lines.count {
            let line = lines[index]
            let indent = line.prefix { $0 == " " }
            if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                if indent.isEmpty { break }
                childIndent = String(indent)
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("current:") {
                    lines[index] = "\(indent)current: \(value)"
                    return lines.joined(separator: "\n")
                }
            }
            index += 1
        }
        lines.insert("\(childIndent)current: \(value)", at: blockStart + 1)
        return lines.joined(separator: "\n")
    }

    static func projectYAMLTemplate(name: String, current: String) -> String {
        """
        name: \(name)

        lifecycle:
          template: app@1
          current: \(current.lowercased())

        """
    }
}
