import Foundation

/// A second agent's critique of a piece it didn't make: it looks at a contact sheet of the
/// piece's beats, reads the scene and Dante's lint, and answers as a senior motion designer,
/// one note a line. The player lists the notes at their moments and can hand them to the maker.
public enum MotionCritique {
    public struct Note: Equatable, Sendable, Hashable, Identifiable {
        public enum Kind: String, Sendable, CaseIterable {
            /// Something wrong: clipped type, a blank frame, a broken handoff.
            case fix
            /// It works, and could be better.
            case polish
            /// Worth keeping as it is.
            case good
        }

        public var kind: Kind
        /// Seconds into the piece, when the note names a moment.
        public var time: Double?
        public var text: String

        public var id: String { "\(kind.rawValue)|\(time ?? -1)|\(text)" }

        public init(kind: Kind, time: Double? = nil, text: String) {
            self.kind = kind
            self.time = time
            self.text = text
        }
    }

    public struct Critique: Equatable, Sendable {
        /// The verdict in a sentence or two, before the notes.
        public var summary: String?
        public var notes: [Note]
        /// Who wrote it.
        public var critic: String

        public init(summary: String?, notes: [Note], critic: String) {
            self.summary = summary
            self.notes = notes
            self.critic = critic
        }
    }

    /// The times to look at: each deck stop or narration line, the start and the end, at most
    /// twelve, in order.
    public static func times(for piece: MotionPiece) -> [Double] {
        var times = [0.4] + piece.stops + piece.narration.map { $0.at + 1 } + [piece.duration * 0.5, max(0, piece.duration - 0.05)]
        times = times.filter { $0 >= 0 && $0 <= piece.duration }.sorted()
        // Neighbours within half a second are one look.
        var kept: [Double] = []
        for t in times where kept.last.map({ t - $0 >= 0.5 }) ?? true { kept.append(t) }
        guard kept.count > 12 else { return kept }
        return (0..<12).map { kept[$0 * (kept.count - 1) / 11] }
    }

    /// The question for the critic. Paths are relative to the project.
    public static func prompt(piece: MotionPiece, folder: String, contactSheet: String, lint: [String], maker: String) -> String {
        """
        You're a senior motion designer giving a critique of a piece \(maker) made, which you didn't. \
        Don't change any files: this is a review.

        The piece: "\(piece.title)", a \(piece.kind.title.lowercased()) of \(Int(piece.duration.rounded())) s at \(piece.width)×\(piece.height). \
        Its brief: \(piece.brief.isEmpty ? "(none written)" : piece.brief)
        Its folder is \(folder): motion.yaml (timing\(piece.narration.isEmpty ? "" : ", narration")\(piece.kind == .deck ? ", slide stops" : "")) and \(piece.scene), the scene.
        Look at the contact sheet \(contactSheet)\(contactSheet.isEmpty ? "" : " (each still is labelled with its time)") and read the scene.
        \(lint.isEmpty ? "Dante's lint found nothing." : "Dante's lint found:\n" + lint.prefix(12).map { "- " + $0 }.joined(separator: "\n"))

        Judge it as it would be shown: clipped or overlapping type, blank or ghost frames, readability and contrast, \
        hierarchy (one idea per moment), pacing and dead stretches, how beats hand over, whether the motion explains \
        or only decorates, consistency with the brand, and the ending.

        Reply with one or two sentences of overall verdict, then at most eight notes, most important first, each on its own line exactly as:
        - [fix] 0:12 — what's wrong and the smallest change that fixes it
        - [polish] 0:30 — what would make it better
        - [good] 0:05 — what to keep
        Leave out the time when a note is about the whole piece. Nothing else after the notes.
        """
    }

    /// Reads the critic's reply: the verdict, then `- [kind] time — note` lines. Lines without a
    /// kind count as polish; a time may be `0:12`, `1:02.5`, `12s` or `12.5 s`.
    public static func parse(_ reply: String, critic: String) -> Critique {
        var summary: [String] = []
        var notes: [Note] = []
        for raw in reply.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("```") else { continue }
            let bullet = line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") || line.first?.isNumber == true && line.contains(". ")
            guard bullet || line.hasPrefix("[") else {
                if notes.isEmpty, !line.hasPrefix("#") { summary.append(line.replacingOccurrences(of: "**", with: "")) }
                continue
            }
            var rest = Substring(line)
            if bullet { rest = rest.drop { $0 != " " }.dropFirst() }
            var kind = Note.Kind.polish
            if let match = rest.prefixMatch(of: /\s*\[\s*(\w+)\s*\]\s*/) {
                kind = Note.Kind(rawValue: match.1.lowercased()) ?? (match.1.lowercased().hasPrefix("keep") ? .good : .polish)
                rest = rest[match.range.upperBound...]
            }
            var time: Double?
            if let match = rest.prefixMatch(of: /(\d+):(\d{1,2}(?:\.\d+)?)\s*/) {
                time = Double(match.1).flatMap { m in Double(match.2).map { m * 60 + $0 } }
                rest = rest[match.range.upperBound...]
            } else if let match = rest.prefixMatch(of: /(\d+(?:\.\d+)?)\s?s\b\s*/) {
                time = Double(match.1)
                rest = rest[match.range.upperBound...]
            }
            let text = String(rest).trimmingCharacters(in: CharacterSet(charactersIn: "—–-:· ").union(.whitespaces)).replacingOccurrences(of: "**", with: "")
            guard !text.isEmpty else { continue }
            notes.append(Note(kind: kind, time: time, text: text))
        }
        let verdict = summary.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return Critique(summary: verdict.isEmpty ? nil : verdict, notes: Array(notes.prefix(12)), critic: critic)
    }

    /// What to ask the maker: the notes chosen, with their times.
    public static func request(_ notes: [Note], critic: String) -> String {
        let lines = notes.map { note in
            "- [\(note.kind.rawValue)] " + (note.time.map { clock($0) + " — " } ?? "") + note.text
        }
        return "\(critic) reviewed the piece. Work through these notes (keep what's marked good), then check the frames again:\n" + lines.joined(separator: "\n")
    }

    /// `m:ss`, with tenths when they matter.
    public static func clock(_ seconds: Double) -> String {
        let whole = Int(seconds)
        let tenths = Int(((seconds - Double(whole)) * 10).rounded())
        return String(format: "%d:%02d", whole / 60, whole % 60) + (tenths > 0 && tenths < 10 ? ".\(tenths)" : "")
    }
}

extension MotionPiece {
    /// A page of a PDF handout: the frame at `time` and what's said there.
    public struct HandoutPage: Equatable, Sendable {
        public var time: Double
        public var notes: [String]
    }

    /// The pages of a handout. A deck is its slides: the frame where each holds and the end,
    /// with the lines spoken on the way to it. Anything else is a storyboard: each narration
    /// line at its middle, else eight moments spread through it.
    public func handoutPages(lengths: [Double]) -> [HandoutPage] {
        let length = { (index: Int) in index < lengths.count ? lengths[index] : Double(narration[index].text.split(separator: " ").count) / 2.5 }
        if kind == .deck {
            var holds = stops.filter { $0 > 0.05 && $0 < duration - 0.05 }.sorted() + [duration]
            holds = holds.reduce(into: []) { kept, t in if kept.last.map({ t - $0 > 0.05 }) ?? true { kept.append(t) } }
            return holds.enumerated().map { index, hold in
                let from = index == 0 ? -1 : holds[index - 1]
                let said = narration.filter { $0.at >= from && ($0.at < hold || index == holds.count - 1) }.map(\.text)
                return HandoutPage(time: hold, notes: said)
            }
        }
        if !narration.isEmpty {
            return narration.indices.map { index in
                HandoutPage(time: min(duration, narration[index].at + length(index) / 2), notes: [narration[index].text])
            }
        }
        return (0..<8).map { HandoutPage(time: duration * (Double($0) + 0.5) / 8, notes: []) }
    }
}
