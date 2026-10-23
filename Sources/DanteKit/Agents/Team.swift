import Foundation

/// The team the lead (Claude or Codex) hands work to. For Claude each role is a Claude Code
/// sub-agent passed with `--agents`, on its own model, so easy work runs on a cheaper model and
/// independent roles (front end and back end, with the Documenter beside them) run at once.
public enum TeamRole: String, CaseIterable, Codable, Sendable, Identifiable {
    case documenter, researcher, frontend, backend, marketing, security, tester

    public var id: String { rawValue }

    /// The sub-agent's name in Claude Code: the `subagent_type` the lead passes.
    public var agentID: String {
        switch self {
        case .frontend: "frontend-engineer"
        case .backend: "backend-engineer"
        case .security: "security-officer"
        default: rawValue
        }
    }

    public var title: String {
        switch self {
        case .documenter: "Documenter"
        case .researcher: "Researcher"
        case .frontend: "Front-end engineer"
        case .backend: "Back-end engineer"
        case .marketing: "Marketing"
        case .security: "Security Officer"
        case .tester: "Tester"
        }
    }

    public var symbol: String {
        switch self {
        case .documenter: "doc.text"
        case .researcher: "magnifyingglass"
        case .frontend: "macwindow"
        case .backend: "server.rack"
        case .marketing: "megaphone"
        case .security: "lock.shield"
        case .tester: "checkmark.seal"
        }
    }

    /// What the role is for, in a line: the sub-agent's description, which the lead reads to choose.
    public var summary: String {
        switch self {
        case .documenter: "Keeps the docs up to date as the team works: decisions, how things work, what changed."
        case .researcher: "Reads the code, docs and web to answer a question or find where something lives. Doesn't edit."
        case .frontend: "Builds and fixes the user interface: screens, components, styles, client-side state."
        case .backend: "Builds and fixes servers, APIs, data access, jobs and infrastructure code."
        case .marketing: "Writes words for people outside the team: release notes, README intros, landing copy, announcements."
        case .security: "Reviews code and changes for security and privacy problems and says how to fix them. Doesn't edit."
        case .tester: "Writes and runs tests, reproduces bugs and reports what fails and why."
        }
    }

    /// The model it starts on: the cheapest one that does the job well.
    public var defaultModel: TeamModel {
        switch self {
        case .documenter, .researcher, .marketing: .haiku
        case .frontend, .backend, .security, .tester: .sonnet
        }
    }

    /// Claude Code tools it may use; nil for all of them.
    var tools: [String]? {
        switch self {
        case .researcher: ["Read", "Grep", "Glob", "WebFetch", "WebSearch"]
        case .security: ["Read", "Grep", "Glob", "Bash"]
        case .documenter, .marketing: ["Read", "Grep", "Glob", "Edit", "Write"]
        case .frontend, .backend, .tester: nil
        }
    }

    /// The roles Codex can hand work to through Dante's `team` tool. The engineers and the
    /// Tester are left out: Codex does that work itself, where Dante can show and undo it.
    public static let forCodexLead: [TeamRole] = [.researcher, .security, .marketing, .documenter]

    /// Tools for a role run by `claude -p` for Codex: read-only, except that the Documenter
    /// may edit and write under docs/ (rules relative to the project folder).
    var forCodex: (tools: [String], allowed: [String]) {
        switch self {
        case .researcher: (["Read", "Grep", "Glob", "WebFetch", "WebSearch"], ["WebFetch", "WebSearch"])
        case .documenter: (["Read", "Grep", "Glob", "Edit", "Write"], ["Edit(docs/**)", "Write(docs/**)"])
        default: (["Read", "Grep", "Glob"], [])
        }
    }

    var prompt: String {
        let common = "You are the \(title) on a small software team led by the agent that called you. Do only the job you were given, stay inside the project, and finish with a short report: what you did, files touched, anything the lead must decide."
        switch self {
        case .documenter:
            return common + """
             You keep documentation current while the others work. For a decision (an approach, a library, a trade-off), write or update a short decision record in docs/decisions/ named NNNN-short-title.md (the next number), with Context, Decision, Consequences and the date. For a change in how something works, update the doc that covers it, or the README, rather than starting new files. Write plainly and briefly; never invent details the lead didn't give you or the code doesn't show.
            """
        case .researcher:
            return common + " Answer with file paths and line numbers, quote only what's needed, and say clearly when something isn't there."
        case .frontend:
            return common + " Follow the project's existing components, styles and patterns. Run the project's build or type check before reporting."
        case .backend:
            return common + " Follow the project's existing structure, keep changes small, and run the relevant tests or build before reporting."
        case .marketing:
            return common + " Write for people outside the team: clear, concrete, no hype, and true to what the product actually does."
        case .security:
            return common + " Look for secrets, injection, missing auth, unsafe input handling and personal data exposure. Rank findings by severity with file:line and a fix. You review; you don't edit."
        case .tester:
            return common + " Use the project's own test runner and conventions. Report the command you ran and the failures in full."
        }
    }

    /// The role behind a sub-agent's `subagent_type`.
    public init?(agentID: String) {
        guard let role = Self.allCases.first(where: { $0.agentID == agentID || $0.rawValue == agentID }) else { return nil }
        self = role
    }
}

/// The Claude model a role runs on; `lead` uses whatever the lead uses.
public enum TeamModel: String, CaseIterable, Codable, Sendable, Identifiable {
    case lead, opus, sonnet, haiku

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .lead: "Same as the lead"
        case .opus: "Opus"
        case .sonnet: "Sonnet"
        case .haiku: "Haiku"
        }
    }

    /// Claude Code's `model` field for an agent.
    var argument: String { self == .lead ? "inherit" : rawValue }
}

public enum Team {
    /// The `--agents` JSON for the roles that are on, each on its chosen model.
    public static func agentsJSON(models: [TeamRole: TeamModel], off: Set<TeamRole> = []) -> String {
        var agents: [String: Any] = [:]
        for role in TeamRole.allCases where !off.contains(role) {
            var agent: [String: Any] = ["description": role.summary, "prompt": role.prompt, "model": (models[role] ?? role.defaultModel).argument]
            if let tools = role.tools { agent["tools"] = tools }
            agents[role.agentID] = agent
        }
        let data = (try? JSONSerialization.data(withJSONObject: agents, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// For the lead's system prompt: who's on the team and how to use them.
    public static func brief(off: Set<TeamRole> = [], documents: Bool) -> String {
        let roles = TeamRole.allCases.filter { !off.contains($0) }
        guard !roles.isEmpty else { return "" }
        var text = """
        You lead a team. Hand work to a team member with the Task tool (subagent_type is the name in brackets) when it's self-contained, and do small things yourself:
        \(roles.map { "- \($0.title) [\($0.agentID)]: \($0.summary)" }.joined(separator: "\n"))
        Start independent pieces at the same time by calling Task several times in one message, for example the front-end and back-end engineers on the two halves of a feature. Give each a complete brief: they don't see this conversation. Check their reports before telling the user it's done.
        """
        if documents, roles.contains(.documenter) {
            text += "\nDocument as you go: when a decision is made or something works differently afterwards, start the Documenter [documenter] alongside the work with the decision, the reasons and the files involved, so docs/decisions/ and the project's docs stay current."
        }
        return text
    }
}

extension Team {
    /// The roles Codex may use from the `--agents` JSON, each with its Claude model (nil for
    /// the lead's, "inherit").
    public static func codexRoles(agentsJSON: String) -> [(role: TeamRole, model: String?)] {
        guard let object = try? JSONSerialization.jsonObject(with: Data(agentsJSON.utf8)) as? [String: Any] else { return [] }
        return TeamRole.forCodexLead.compactMap { role in
            guard let agent = object[role.agentID] as? [String: Any] else { return nil }
            let model = agent["model"] as? String
            return (role, model == "inherit" ? nil : model)
        }
    }

    /// For Codex's instructions: the `team` tool and who's on it.
    public static func codexBrief(roles: [TeamRole]) -> String {
        guard !roles.isEmpty else { return "" }
        var text = """
        # Your team
        You lead a team of Claude agents. Hand a self-contained piece of work to one with the `team` tool (role is the name in brackets) and keep the coding yourself:
        \(roles.map { "- \($0.title) [\($0.agentID)]: \($0.summary)" }.joined(separator: "\n"))
        They don't see this conversation, so give each a complete brief. You can call `team` for several roles at once. Check what they report before relying on it.
        """
        if roles.contains(.documenter) {
            text += "\nThe Documenter can write only under docs/: when a decision is made or something works differently, hand it the decision, the reasons and the files involved."
        }
        return text
    }
}
