import Foundation
import Testing
@testable import DanteKit

struct TeamTests {
    @Test func everyRoleIsASubAgentOnItsModel() throws {
        let json = Team.agentsJSON(models: [.backend: .opus, .documenter: .lead], off: [.marketing])
        let agents = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: [String: Any]])
        #expect(agents.count == 6)
        #expect(agents["marketing"] == nil)
        #expect(agents["backend-engineer"]?["model"] as? String == "opus")
        #expect(agents["documenter"]?["model"] as? String == "inherit")
        #expect(agents["frontend-engineer"]?["model"] as? String == "sonnet")
        #expect(agents["researcher"]?["model"] as? String == "haiku")
        #expect(agents["researcher"]?["tools"] as? [String] == ["Read", "Grep", "Glob", "WebFetch", "WebSearch"])
        #expect(agents["tester"]?["tools"] == nil)
        #expect((agents["documenter"]?["prompt"] as? String)?.contains("docs/decisions/") == true)
    }

    @Test func theLeadIsToldHowToUseTheTeam() {
        let brief = Team.brief(documents: true)
        #expect(brief.contains("[security-officer]"))
        #expect(brief.contains("several times in one message"))
        #expect(brief.contains("Document as you go"))
        #expect(!Team.brief(off: [.documenter], documents: true).contains("Document as you go"))
        #expect(Team.brief(off: Set(TeamRole.allCases), documents: true).isEmpty)
    }

    @Test func delegationsAreNamedByRole() {
        #expect(TeamRole(agentID: "frontend-engineer") == .frontend)
        #expect(TeamRole(agentID: "Explore") == nil)
        let tool = ToolActivity(id: "1", name: "Task", input: .object(["subagent_type": .string("tester"), "description": .string("Run the tests")]), status: .done)
        #expect(tool.verb == "Handed to Tester")
        let running = ToolActivity(id: "2", name: "Task", input: .object(["subagent_type": .string("general-purpose")]), status: .running)
        #expect(running.verb == "A sub-agent is working on")
        #expect(AgentStats.agent(of: AgentJob(kind: "subagent", provider: .claude, model: "documenter", project: "p", requestedBy: "claude", title: "Record")) == "Documenter")
    }
}

@Test func codexGetsTheTeamThroughDantesServer() async throws {
    let agents = Team.agentsJSON(models: [.researcher: .opus, .documenter: .lead], off: [.marketing])
    let roles = Team.codexRoles(agentsJSON: agents)
    #expect(roles.map(\.role) == [.researcher, .security, .documenter])
    #expect(roles.first?.model == "opus")
    #expect(roles.last?.model == nil)
    #expect(Team.codexBrief(roles: roles.map(\.role)).contains("[security-officer]"))
    #expect(!Team.codexBrief(roles: []).contains("team"))

    let documenter = ClaudeOpinion.arguments(model: "haiku", tools: TeamRole.documenter.forCodex.tools, allowed: TeamRole.documenter.forCodex.allowed, system: "brief")
    #expect(documenter.contains("Write(docs/**)"))
    #expect(documenter.contains("dontAsk"))
    #expect(!TeamRole.security.forCodex.tools.contains("Bash"))
    #expect(ClaudeOpinion.arguments(model: nil) == ["-p", "--output-format", "json", "--tools", "Read,Grep,Glob", "--permission-mode", "dontAsk", "--no-session-persistence"])

    var server = DelegateServer(project: "shop", ledger: nil, models: { [] }) { _, _ in ("m", OllamaReply(text: "", promptTokens: 0, outputTokens: 0, seconds: 0, tokensPerSecond: 0)) }
    #expect(!server.tools.contains { $0["name"]?.string == "team" })
    server.teamRoles = [.researcher]
    server.team = { role, _ in ClaudeReply(text: "Found it in billing/api.py:12 for \(role.title).") }
    #expect(server.tools.contains { $0["name"]?.string == "team" })
    let reply = await server.callTeam(["role": "researcher", "brief": "Where are invoices made?"])
    #expect(reply["isError"]?.bool == false)
    let refused = await server.callTeam(["role": "frontend-engineer", "brief": "Build it"])
    #expect(refused["isError"]?.bool == true)
}
