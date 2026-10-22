import Foundation

/// The kinds of document Docs can start: where each goes, what it's called and the outline it
/// starts with, and what to ask the agent when it drafts one from the code.
public enum DocTemplate: String, CaseIterable, Sendable, Identifiable {
    case document, readme, decision, runbook, howTo, architecture

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .document: "Document"
        case .readme: "README"
        case .decision: "Decision record"
        case .runbook: "Runbook"
        case .howTo: "How-to guide"
        case .architecture: "Architecture overview"
        }
    }

    public var symbol: String {
        switch self {
        case .document: "doc.text"
        case .readme: "book"
        case .decision: "signpost.right"
        case .runbook: "book.closed"
        case .howTo: "list.number"
        case .architecture: "square.3.layers.3d"
        }
    }

    public var summary: String {
        switch self {
        case .document: "A blank page with a title"
        case .readme: "What a folder is and how to run it"
        case .decision: "A choice that was made, and why"
        case .runbook: "Steps for when something needs doing"
        case .howTo: "One task, step by step"
        case .architecture: "The parts, the data and how it ships"
        }
    }

    /// The name a new one starts with.
    public var suggestedTitle: String {
        switch self {
        case .document: "Untitled"
        case .readme: "README"
        case .decision: "Use one load balancer for every app"
        case .runbook: "Restart a service"
        case .howTo: "Set up a development machine"
        case .architecture: "Architecture"
        }
    }

    /// A README is named by its folder, so it has no title to type.
    public var asksForTitle: Bool { self != .readme }

    /// Where a new one goes: the folder the project already keeps them in, else a sensible one.
    public func defaultFolder(existing paths: [String]) -> String {
        let folders = Set(paths.map { ($0 as NSString).deletingLastPathComponent.lowercased() })
        func first(_ candidates: [String], else fallback: String) -> String {
            candidates.first { folders.contains($0) } ?? fallback
        }
        switch self {
        case .document, .architecture: return "docs"
        case .readme: return paths.contains { $0.lowercased() == "readme.md" } ? "docs" : ""
        case .decision: return first([".dante/decisions", "docs/decisions", "docs/adr", "docs/adrs", "doc/adr", "adr"], else: "docs/decisions")
        case .runbook: return first([".dante/runbooks", "docs/runbooks", "runbooks"], else: "docs/runbooks")
        case .howTo: return first(["docs/guides", "docs/how-to", "docs/howto", "guides"], else: "docs/guides")
        }
    }

    /// The new file's path: `README.md` in the folder, a numbered `0004-title.md` for a
    /// decision, else the title as a file name, numbered when it's taken. Nil when the folder
    /// already has a README.
    public func path(title: String, folder: String, existing: [String]) -> String? {
        let taken = Set(existing.map { $0.lowercased() })
        let prefix = folder.isEmpty ? "" : folder + "/"
        if self == .readme {
            let path = prefix + "README.md"
            return taken.contains(path.lowercased()) ? nil : path
        }
        let slug = Diagram.slug(title).isEmpty ? "untitled" : Diagram.slug(title)
        if self == .decision {
            let number = Self.nextNumber(in: folder, existing: existing)
            return prefix + String(format: "%04d", number) + "-" + slug + ".md"
        }
        var candidate = prefix + slug + ".md"
        var number = 2
        while taken.contains(candidate.lowercased()) {
            candidate = prefix + "\(slug)-\(number).md"
            number += 1
        }
        return candidate
    }

    /// One more than the highest `0007-…` number in the folder.
    static func nextNumber(in folder: String, existing: [String]) -> Int {
        let prefix = folder.isEmpty ? "" : folder.lowercased() + "/"
        let numbers = existing.compactMap { path -> Int? in
            let lower = path.lowercased()
            guard lower.hasPrefix(prefix) else { return nil }
            let name = String(lower.dropFirst(prefix.count))
            guard !name.contains("/") else { return nil }
            return Int(name.prefix { $0.isNumber })
        }
        return (numbers.max() ?? 0) + 1
    }

    /// The file's first text: the title and the outline, with a line under each heading
    /// saying what goes there.
    public func body(title: String, project: String, folder: String, date: Date = Date(), number: Int? = nil) -> String {
        let day = Self.day.string(from: date)
        switch self {
        case .document:
            return "# \(title)\n\n"
        case .readme:
            let name = folder.isEmpty ? project : (folder as NSString).lastPathComponent
            return """
            # \(name)

            _One or two sentences: what this is and who it's for._

            ## Getting started

            _What to install, and the commands to build and run it._

            ## How it's laid out

            _The folders and files worth knowing about._

            ## Working on it

            _Tests, conventions, and where to ask._

            """
        case .decision:
            let heading = number.map { String(format: "%04d. ", $0) } ?? ""
            return """
            # \(heading)\(title)

            - Status: proposed
            - Date: \(day)

            ## Context

            _What made a decision necessary: the problem, the constraints, what was true at the time._

            ## Decision

            _What was decided, in a sentence or two._

            ## Options considered

            _Each option, with what speaks for and against it._

            ## Consequences

            _What gets easier, what gets harder, and what has to happen next._

            """
        case .runbook:
            return """
            # \(title)

            _When to use this runbook, in a sentence._

            ## Before you start

            _Access, tools and checks you need first._

            ## Steps

            1. _The first thing to do, with the exact command._
            2. _The next._

            ## Check it worked

            _What you should see when it's done._

            ## If it goes wrong

            _How to roll back, and who to call._

            """
        case .howTo:
            return """
            # \(title)

            _What you'll have when you're done._

            ## You'll need

            _Prerequisites._

            ## Steps

            1. _The first step._
            2. _The next._

            ## Troubleshooting

            _Problems people hit, and the fix for each._

            """
        case .architecture:
            return """
            # \(title)

            _What \(project) does and who uses it, in a paragraph._

            ## The picture

            ```mermaid
            flowchart LR
              users([Users]) --> app[\(project)]
            ```

            ## Parts

            _Each part: what it does, where its code is, what it talks to._

            ## Data

            _Where data is stored and who reads and writes it._

            ## How it ships

            _Build, pipelines, environments and where it runs._

            ## Decisions

            _Links to the decision records that shaped it._

            """
        }
    }

    /// What the agent is asked when it drafts the document from the code.
    public func draftRequest(path: String, title: String, about: String) -> String {
        let what: String = switch self {
        case .document: "a document titled \"\(title)\""
        case .readme: "the README for \((path as NSString).deletingLastPathComponent.isEmpty ? "the project" : (path as NSString).deletingLastPathComponent)"
        case .decision: "a decision record titled \"\(title)\""
        case .runbook: "a runbook titled \"\(title)\""
        case .howTo: "a how-to guide titled \"\(title)\""
        case .architecture: "an architecture overview titled \"\(title)\""
        }
        var request = "Write \(what) in \(path). "
        let note = about.trimmingCharacters(in: .whitespacesAndNewlines)
        if !note.isEmpty { request += "It's about: \(note)\n\n" }
        request += self == .document
            ? "Read the code, configuration, other docs and git history it touches, then write it in plain markdown."
            : "The file already has the outline. Replace each italic line with what's true of this project, from its code, configuration, other docs and git history; keep the headings unless one doesn't apply."
        request += " Don't invent anything: where you can't tell, write a short TODO saying what's missing. Keep it short and specific, and save the file."
        if self == .architecture { request += " Draw the picture as a Mermaid flowchart of the real parts." }
        return request
    }

    private static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// Folders to offer for a new document: the template's own, the project root, docs/ and
    /// every folder that already holds docs, most docs first.
    public static func folders(for template: DocTemplate, library: DocLibrary, existing paths: [String]) -> [String] {
        var counts: [String: Int] = [:]
        for doc in library.all where doc.kind == .markdown {
            counts[(doc.path as NSString).deletingLastPathComponent, default: 0] += 1
        }
        let known = counts.keys.sorted { (counts[$0]!, $1) > (counts[$1]!, $0) }
        var result: [String] = []
        for folder in [template.defaultFolder(existing: paths), "docs", ""] + known where !result.contains(folder) {
            result.append(folder)
        }
        return result
    }
}
