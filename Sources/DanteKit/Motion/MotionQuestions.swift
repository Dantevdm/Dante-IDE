import Foundation

/// The questions a motion studio asks before it starts, as the New piece sheet asks them:
/// purpose, audience, message, format, story, look, motion, sound, data and bans. Each has
/// options to tap and room for the user's own words; the answers become the opening of the
/// agent's brief (BRIEF.md), so the piece is made to a studio's brief rather than a one-liner.
public enum MotionQuestions {
    public struct Question: Identifiable, Equatable, Sendable {
        public var id: String
        public var title: String
        /// Shown under the title: why it matters.
        public var help: String
        public var options: [String]
        /// More than one option may be picked.
        public var multiple: Bool
        /// The heading it goes under in the brief.
        public var brief: String

        init(_ id: String, _ title: String, help: String, options: [String], multiple: Bool = false, brief: String) {
            self.id = id
            self.title = title
            self.help = help
            self.options = options
            self.multiple = multiple
            self.brief = brief
        }
    }

    public struct Section: Identifiable, Equatable, Sendable {
        public var id: String
        public var title: String
        public var symbol: String
        public var questions: [Question]
    }

    /// One question's answer: options picked and the user's own words.
    public struct Answer: Equatable, Sendable, Codable {
        public var picked: [String] = []
        public var note = ""

        public init(picked: [String] = [], note: String = "") {
            self.picked = picked
            self.note = note
        }

        public var isEmpty: Bool { picked.isEmpty && note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        var text: String {
            let note = self.note.trimmingCharacters(in: .whitespacesAndNewlines)
            return (picked + (note.isEmpty ? [] : [note])).joined(separator: "; ")
        }
    }

    public static let sections: [Section] = [
        Section(id: "purpose", title: "Purpose", symbol: "scope", questions: [
            Question("goal", "What should it achieve?", help: "An observable change: what people do or understand after watching.",
                     options: ["Explain how it works", "Launch a feature", "Win a decision or budget", "Onboard new engineers", "Show progress", "Recruit"], brief: "Goal"),
            Question("where", "Where will it be seen?", help: "Decides the format, pace and whether it must work without sound.",
                     options: ["Presented on a screen", "A meeting, played", "Social feed", "Website or README", "Internal channel", "Conference talk"], multiple: true, brief: "Where it's shown"),
            Question("cta", "What should they do at the end?", help: "The last frame holds on it.",
                     options: ["Nothing: just understand", "Try it", "Approve it", "Read the docs", "Get in touch"], brief: "Ending and call to action"),
        ]),
        Section(id: "audience", title: "Audience", symbol: "person.2", questions: [
            Question("who", "Who is it for?", help: "The person you picture watching.",
                     options: ["Engineers on the team", "New joiners", "Leadership", "Customers", "Investors", "Non-technical stakeholders"], multiple: true, brief: "Audience"),
            Question("knows", "What do they already know?", help: "So it neither bores nor loses them.",
                     options: ["Nothing about it", "The product, not the code", "The code, not this part", "Everything: just the change"], brief: "What they already know"),
        ]),
        Section(id: "message", title: "Message", symbol: "text.quote", questions: [
            Question("message", "The one thing they must remember", help: "One sentence. Everything else serves it.",
                     options: [], brief: "The one message"),
            Question("points", "Points to make on the way", help: "Three or four at most, in order.",
                     options: [], brief: "Supporting points"),
            Question("facts", "Facts and numbers to show", help: "Give them exactly: the agent won't check facts.",
                     options: ["Use the project's own numbers", "I'll give them here"], brief: "Facts and numbers (exact)"),
            Question("avoid", "Anything it must not say or show?", help: "Claims, names, internal details, competitors.",
                     options: ["No customer names", "No internal URLs or hosts", "No secrets or keys", "No prices"], multiple: true, brief: "Must not say or show"),
        ]),
        Section(id: "format", title: "Format", symbol: "rectangle.ratio.16.to.9", questions: [
            Question("aspect", "Shape", help: "16:9 for screens and meetings, 9:16 for phones and reels, 1:1 or 4:5 for feeds.",
                     options: ["16:9", "9:16", "1:1", "4:5"], brief: "Aspect ratio"),
            Question("length", "Length", help: "Shorter is almost always better.",
                     options: ["15 s", "30 s", "45 s", "60 s", "90 s", "2 min"], brief: "Length"),
            Question("loop", "Does it loop?", help: "A loop's last frame matches its first.",
                     options: ["No, it ends", "Yes, seamless loop"], brief: "Loop"),
            Question("captions", "Captions", help: "Most feeds play muted.",
                     options: ["Burn in the narration", "No captions", "Words on screen carry it, no narration"], brief: "Captions"),
        ]),
        Section(id: "story", title: "Story", symbol: "list.number", questions: [
            Question("structure", "How should it unfold?", help: "The shape of the story.",
                     options: ["Problem → solution", "A journey (follow one request)", "Anatomy (take it apart)", "Before → after", "Countdown of highlights", "One idea, building up"], brief: "Structure"),
            Question("hook", "The first three seconds", help: "What stops someone scrolling or looking at their phone.",
                     options: ["A bold statement", "A surprising number", "The finished result first", "A question", "Straight into the visual"], brief: "Hook"),
            Question("continuity", "What ties the beats together?", help: "One shape, colour or motion that carries through, so it doesn't feel like slides.",
                     options: ["A request travelling as a light", "One shape that morphs", "The logo mark", "A line that draws itself", "The camera moving through one world", "Let the agent propose"], brief: "Continuity device"),
        ]),
        Section(id: "look", title: "Look", symbol: "paintpalette", questions: [
            Question("look", "Animation style", help: "One, or two where one leads and the other accents. Each comes with the way to build it.",
                     options: MotionLooks.styles.map(\.name), multiple: true, brief: "Animation style"),
            Question("kit", "Illustrations", help: "Kits bundled with Dante, or the agent's own drawings.",
                     options: MotionLooks.kits.map(\.name), multiple: true, brief: "Illustrations"),
            Question("style", "Approach", help: "What it's mostly made of: the production path, not a mood word.",
                     options: ["Editorial typography", "Technical diagram, flat", "Cinematic 3D, lit", "Product UI in motion", "Data visualisation", "Isometric system"], brief: "Visual style"),
            Question("depth", "How much 3D?", help: "3D costs render time and attention.",
                     options: ["Flat 2D", "Layered 2.5D parallax", "Full 3D scenes", "3D for one hero moment"], brief: "Depth"),
            Question("references", "References you like", help: "Links or descriptions: what to take from them (pace, type, light), not what to copy.",
                     options: ["Apple keynote", "Stripe", "Linear", "Vercel", "A24 title cards", "Editorial magazine"], multiple: true, brief: "References"),
            Question("mood", "Mood", help: "How it should feel.",
                     options: ["Calm and confident", "Energetic", "Premium and quiet", "Playful", "Serious and technical", "Awe"], brief: "Mood"),
        ]),
        Section(id: "motion", title: "Motion", symbol: "wind", questions: [
            Question("pace", "Pace", help: "Overrides the brand kit's default for this piece.",
                     options: ["Calm: long holds", "Lively: quick cuts, springs", "Cinematic: slow camera, depth"], brief: "Pace"),
            Question("camera", "Camera", help: "How we move through it.",
                     options: ["Locked off, things move", "Slow push-ins", "Fly-throughs", "Orbit around the hero", "Cuts only"], brief: "Camera"),
            Question("transitions", "Transitions", help: "Between beats.",
                     options: ["Match cuts on a shape", "Wipes along the motion", "Zoom through", "Morphs", "Hard cuts on the beat"], multiple: true, brief: "Transitions"),
        ]),
        Section(id: "sound", title: "Sound", symbol: "waveform", questions: [
            Question("narration", "Narration", help: "Spoken in Dante's natural voice, timed to the beats.",
                     options: ["Narrated throughout", "Only at key moments", "No narration"], brief: "Narration"),
            Question("voice", "Voice and tone", help: "How the words sound.",
                     options: ["Warm and plain", "Crisp and technical", "Story-teller", "The brand kit's tone"], brief: "Voice and tone"),
        ]),
        Section(id: "rules", title: "Rules", symbol: "nosign", questions: [
            Question("bans", "Never use", help: "The tells that make it look generated.",
                     options: ["Neon glow", "Particle bursts", "Bouncy easing", "Hue-shifting gradients", "Glassmorphism", "Fake UI", "Corner labels and timecodes", "Stock spinning objects"], multiple: true, brief: "Banned"),
            Question("must", "Must include", help: "Logo, a screen, a person's name, a line of copy.",
                     options: ["The logo at the end", "Real screens of the app", "The architecture", "The team's name"], multiple: true, brief: "Must include"),
            Question("approve", "Before it's animated", help: "The storyboard stills are the cheapest place to change your mind.",
                     options: ["Show me the storyboard stills first", "Go straight through"], brief: "Approval"),
        ]),
    ]

    public static var all: [Question] { sections.flatMap(\.questions) }

    /// Sensible answers to start from, so a quick piece needs only the description.
    public static func defaults(for kind: MotionPiece.Kind) -> [String: Answer] {
        var answers: [String: Answer] = [
            "aspect": Answer(picked: ["16:9"]),
            "loop": Answer(picked: [kind == .explainer ? "Yes, seamless loop" : "No, it ends"]),
            "continuity": Answer(picked: ["Let the agent propose"]),
            "narration": Answer(picked: [kind == .explainer ? "No narration" : "Narrated throughout"]),
            "voice": Answer(picked: ["The brand kit's tone"]),
            "bans": Answer(picked: ["Neon glow", "Hue-shifting gradients", "Fake UI", "Corner labels and timecodes", "Stock spinning objects"]),
            "avoid": Answer(picked: ["No secrets or keys", "No internal URLs or hosts"]),
            "approve": Answer(picked: ["Show me the storyboard stills first"]),
        ]
        if kind == .deck { answers["captions"] = Answer(picked: ["No captions"]) }
        return answers
    }

    /// The design size for an aspect ratio answer.
    public static func size(for answers: [String: Answer]) -> (width: Int, height: Int) {
        switch answers["aspect"]?.picked.first {
        case "9:16": (1080, 1920)
        case "1:1": (1080, 1080)
        case "4:5": (1080, 1350)
        default: (1920, 1080)
        }
    }

    /// Seconds from the length answer, if one was picked.
    public static func length(for answers: [String: Answer]) -> Double? {
        guard let picked = answers["length"]?.picked.first else { return nil }
        if picked.hasSuffix("min") { return Double(picked.split(separator: " ").first ?? "").map { $0 * 60 } }
        return Double(picked.split(separator: " ").first ?? "")
    }

    /// Whether the user wants to approve the storyboard stills before animation.
    public static func approvesStoryboard(_ answers: [String: Answer]) -> Bool {
        answers["approve"]?.picked.first != "Go straight through"
    }

    /// Whether the piece is narrated at all.
    public static func isNarrated(_ answers: [String: Answer]) -> Bool {
        let picked = answers["narration"]?.picked.first
        return picked != "No narration" && answers["captions"]?.picked.first != "Words on screen carry it, no narration"
    }

    /// How many questions have an answer.
    public static func answered(_ answers: [String: Answer]) -> Int {
        all.filter { answers[$0.id].map { !$0.isEmpty } ?? false }.count
    }

    /// The answers as the brief's opening: one line per answered question, under its section.
    public static func brief(_ answers: [String: Answer]) -> String {
        var lines: [String] = []
        for section in sections {
            let answered = section.questions.compactMap { question -> String? in
                guard let answer = answers[question.id], !answer.isEmpty else { return nil }
                return "- \(question.brief): \(answer.text)"
            }
            guard !answered.isEmpty else { continue }
            lines.append("### \(section.title)")
            lines += answered
        }
        let open = all.filter { answers[$0.id]?.isEmpty ?? true }.map(\.brief)
        if !open.isEmpty { lines.append("\nNot answered yet: \(open.joined(separator: ", ")).") }
        return lines.joined(separator: "\n")
    }
}
