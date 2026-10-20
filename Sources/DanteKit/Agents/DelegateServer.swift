import Foundation

/// The MCP server `dante mcp` runs for Claude Code: a `delegate` tool that hands a job to a
/// model in Ollama on this Mac and returns its answer for Claude to check, and, when the user
/// has added their keys, `decide` (Jev's typed decisions) and `ask_grok` (xAI's Grok). Each
/// job goes in the `AgentLedger`. Speaks MCP's stdio transport: one JSON-RPC message per line.
public struct DelegateServer: Sendable {
    /// Runs a job on a local model: the model's name and its reply.
    public typealias Runner = @Sendable (DelegateKind, _ prompt: String) async throws -> (model: String, reply: OllamaReply)
    public typealias Decider = @Sendable (_ state: JSONValue, _ questions: [(name: String, question: JevQuestion)]) async throws -> JevDecision
    public typealias Asker = @Sendable (_ system: String?, _ prompt: String) async throws -> GrokReply
    public typealias CodexAsker = @Sendable (_ prompt: String) async throws -> CodexReply
    public typealias ClaudeAsker = @Sendable (_ prompt: String) async throws -> ClaudeReply

    public var project: String
    public var ledger: AgentLedger?
    public var models: @Sendable () async -> [OllamaModel]?
    public var run: Runner
    /// Off when the user has turned delegation to local models off but has a cloud agent.
    public var offersLocal = true
    public var decide: Decider?
    public var askGrok: Asker?
    public var askCodex: CodexAsker?
    /// Claude for Codex's second opinions, when Codex is the one in charge.
    public var askClaude: ClaudeAsker?
    /// Who's in charge and calling these tools: "claude" or "codex", for the ledger.
    public var requester = "claude"
    /// Searches the project by meaning: the question and how many pieces, as text for the agent.
    public var searchCode: (@Sendable (_ question: String, _ limit: Int) async throws -> String)?
    /// Runs Dante's security scan of the project, saves it for the Security page and returns
    /// the summary.
    public var securityReport: (@Sendable () async -> String)?
    /// Waits for the app to render a motion piece's frames: the folder and times, answered in words.
    public var motionFrames: (@Sendable (_ folder: String, _ times: [Double]) async -> (text: String, isError: Bool))?
    /// Looker's vision model, when a capable one is installed.
    public var lookerModel: (@Sendable () async -> String?)?
    /// Reads an image file (a path in the project or absolute) and answers about it with a model.
    public var look: (@Sendable (_ model: String, _ path: String, _ question: String) async throws -> OllamaReply)?

    public static let protocolVersion = "2025-06-18"

    public init(project: String, ledger: AgentLedger?, models: @escaping @Sendable () async -> [OllamaModel]?, run: @escaping Runner) {
        self.project = project
        self.ledger = ledger
        self.models = models
        self.run = run
    }

    /// The server Dante ships: Ollama on this Mac, the standard ledger, and models chosen
    /// per job in Settings (`DANTE_MODEL_<KIND>` from the app, else the best installed).
    public static func live(project: String, root: String = FileManager.default.currentDirectoryPath,
                            environment: [String: String] = ProcessInfo.processInfo.environment) -> DelegateServer {
        let ollama = Ollama(base: environment["OLLAMA_HOST"].flatMap { URL(string: $0.hasPrefix("http") ? $0 : "http://\($0)") } ?? Ollama().base)
        var server = DelegateServer(project: project, ledger: .standard, models: { await ollama.models() }) { kind, prompt in
            let installed = await ollama.models() ?? []
            let chosen = environment["DANTE_MODEL_\(kind.rawValue.uppercased())"]
            guard let model = ModelRouting.model(for: kind, installed: installed, chosen: chosen) else {
                throw Ollama.Failure(message: "No local model for \(kind.title.lowercased()). Pull one with ollama, or do this yourself.")
            }
            return (model, try await ollama.chat(model: model, system: system(for: kind), prompt: prompt))
        }
        server.offersLocal = environment[DelegateEnvironment.local] != "0"
        if let key = environment[CloudAgent.jev.environmentVariable], !key.isEmpty {
            let jev = Jev(key: key)
            server.decide = { state, questions in try await jev.decide(state: state, questions: questions) }
        }
        if let key = environment[CloudAgent.grok.environmentVariable], !key.isEmpty {
            let grok = Grok(key: key)
            let chosen = environment[DelegateEnvironment.grokModel]
            server.askGrok = { system, prompt in
                // A chosen model is used as is; listing first would only cost a round trip.
                let available = chosen?.isEmpty == false ? [] : try await grok.models()
                guard let model = Grok.model(chosen: chosen, available: available) else {
                    throw Grok.Failure(message: "The xAI key has no chat models.")
                }
                return try await grok.chat(model: model, system: system, prompt: prompt)
            }
        }
        server.requester = environment[DelegateEnvironment.requester] ?? "claude"
        if server.offersLocal {
            let chosenVision = environment[DelegateEnvironment.lookerModel]
            server.lookerModel = { Looker.model(installed: await ollama.models() ?? [], chosen: chosenVision) }
            let rules = ClaudeRules.load(projectRoot: URL(filePath: root, directoryHint: .isDirectory))
            server.look = { model, path, question in
                let url = URL(filePath: path, relativeTo: URL(filePath: root, directoryHint: .isDirectory)).standardizedFileURL
                let relative = ProposedChange.relativePath(of: url, in: URL(filePath: root, directoryHint: .isDirectory))
                if rules.never.contains(where: { ClaudeRules.path(relative, matches: $0) }) {
                    throw Ollama.Failure(message: "This project’s rules don’t allow reading \(relative).")
                }
                let image = try Looker.prepare(try Data(contentsOf: url))
                return try await ollama.look(model: model, images: [image], question: question)
            }
        }
        if server.offersLocal {
            let rootURL = URL(filePath: root, directoryHint: .isDirectory)
            let search = SemanticSearch(ollama: ollama)
            server.searchCode = { question, limit in
                let index = try await search.update(root: rootURL)
                let hits = try await search.search(question, in: index, limit: limit)
                return SemanticSearch.report(hits, root: rootURL, index: index)
            }
        }
        let projectRoot = URL(filePath: root, directoryHint: .isDirectory)
        server.motionFrames = { folder, times in await MotionFrames.await(root: projectRoot, folder: folder, times: times) }
        let online = environment[DelegateEnvironment.securityOnline] == "1"
        server.securityReport = {
            let report = await ProjectSecurity.refresh(root: projectRoot, onlineAdvisories: online)
            return ProjectSecurity.summary(report, root: projectRoot, limit: 30)
        }
        if let path = environment[DelegateEnvironment.claude], !path.isEmpty {
            let claude = ClaudeOpinion(executable: path)
            let model = environment[DelegateEnvironment.claudeModel]
            server.askClaude = { prompt in try await claude.ask(prompt, in: root, model: model) }
        }
        if let path = environment[DelegateEnvironment.codex], !path.isEmpty {
            let codex = Codex(executable: path)
            let model = environment[DelegateEnvironment.codexModel]
            server.askCodex = { prompt in try await codex.ask(prompt, in: root, model: model) }
        }
        return server
    }

    static func system(for kind: DelegateKind) -> String {
        "You are a focused assistant doing one job for a senior engineer, who will check your work: \(kind.guidance). Be accurate and concise. Don't invent facts, files or APIs; say when you're unsure. Reply with the result only."
    }

    /// Answers one line from Claude Code. Nil for notifications, which get no reply.
    public func handle(_ line: String) async -> String? {
        guard let message = JSONValue(line: line), let method = message["method"]?.string else { return nil }
        let id = message["id"]
        guard let id, !id.isNull else { return nil }
        let result: JSONValue
        switch method {
        case "initialize":
            let version = message["params"]?["protocolVersion"]?.string ?? Self.protocolVersion
            result = [
                "protocolVersion": .string(version),
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": "dante", "version": "1"],
                "instructions": .string(instructions),
            ]
        case "ping":
            result = [:]
        case "tools/list":
            var list = tools
            if look != nil, await lookerModel?() != nil { list.append(Self.askingWhy(Self.lookTool)) }
            result = ["tools": .array(list)]
        case "tools/call":
            result = await call(message["params"]?["name"]?.string ?? "", arguments: message["params"]?["arguments"] ?? [:])
        default:
            return JSONValue.object(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": .string("Unknown method \(method)")]]).jsonLine
        }
        return JSONValue.object(["jsonrpc": "2.0", "id": id, "result": result]).jsonLine
    }

    var instructions: String {
        var parts: [String] = ["dante_pages describes the IDE the user is in, page by page; show_page opens one for them."]
        if motionFrames != nil { parts.append("motion_frames renders frames of a motion piece (docs/motion/…) so you can look at your own work.") }
        if offersLocal { parts.append("Local models on this Mac: delegate small, checkable jobs to save the user's Claude usage, and review what comes back.") }
        if securityReport != nil { parts.append("security_report runs Dante's security scan and returns the score and findings the user sees on the Security page: start there for any question about the project's security.") }
        if searchCode != nil { parts.append("search_code finds code by what it does, for questions grep can't answer.") }
        if look != nil { parts.append("look (Looker) reads screenshots and images on this Mac when a vision model is installed.") }
        if decide != nil { parts.append("Jev answers typed questions (pick one, rate, yes or no) about some material in well under a second.") }
        if askGrok != nil { parts.append("Grok (xAI) gives an independent second opinion or draft.") }
        if askCodex != nil { parts.append("Codex (OpenAI) reads the project itself, read-only, for a second opinion.") }
        if askClaude != nil { parts.append("Claude (Anthropic) reads the project itself, read-only, for a second opinion.") }
        return parts.joined(separator: " ")
    }

    var tools: [JSONValue] {
        var tools: [JSONValue] = Self.pageTools
        if motionFrames != nil { tools.append(Self.motionTool) }
        if offersLocal { tools += Self.localTools }
        if securityReport != nil { tools.append(Self.securityTool) }
        if searchCode != nil { tools.append(Self.searchTool) }
        if decide != nil { tools.append(Self.decideTool) }
        if askGrok != nil { tools.append(Self.grokTool) }
        if askCodex != nil { tools.append(Self.codexTool) }
        if askClaude != nil { tools.append(Self.claudeTool) }
        return tools.map(Self.askingWhy)
    }

    /// Every job tool takes a `why`, so the Agents area can say who checked what and why.
    static func askingWhy(_ tool: JSONValue) -> JSONValue {
        guard !["local_models", "search_code", "security_report", "dante_pages", "show_page", "motion_frames"].contains(tool["name"]?.string ?? ""), var object = tool.object,
              var schema = object["inputSchema"]?.object, var properties = schema["properties"]?.object else { return tool }
        properties["why"] = ["type": "string", "description": "One short sentence for the user: why you're asking (for example \"check the migration can't lock the table\")."]
        schema["properties"] = .object(properties)
        object["inputSchema"] = .object(schema)
        return .object(object)
    }

    static let decideTool: JSONValue = [
        "name": "decide",
        "description": "Ask Jev, a fast decision model, typed questions about some material: which of several options fits (choice), where it sits on a scale (score) or how likely something is (yes_no). Good for routing and triage at scale: which area a failure belongs to, how risky a command or diff is, whether a log line is an error worth reading. It answers in under a second for a fraction of a cent, but it judges only the material you pass, so include what it needs. Runs on Jev's servers with the user's key: never send secrets.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "material": ["type": "string", "description": "What to judge: a command, diff, log, message or description."],
                "title": ["type": "string", "description": "A few words saying what the decision is, for the user's stats."],
                "questions": [
                    "type": "array",
                    "description": "Up to eight questions, each answered separately.",
                    "items": [
                        "type": "object",
                        "properties": [
                            "name": ["type": "string", "description": "A short id for the answer, like route or risk."],
                            "type": ["type": "string", "enum": ["choice", "score", "yes_no"]],
                            "instructions": ["type": "string", "description": "The question, in a sentence."],
                            "options": ["type": "object", "description": "For choice: each label and what it means.", "additionalProperties": ["type": "string"]],
                            "levels": ["type": "array", "items": ["type": "string"], "description": "For score: 2–10 levels, low to high."],
                        ],
                        "required": ["name", "type", "instructions"],
                    ],
                ],
            ],
            "required": ["material", "questions"],
        ],
    ]

    static let grokTool: JSONValue = [
        "name": "ask_grok",
        "description": "Ask xAI's Grok for an independent second opinion: a review of a plan or diff, another way to solve a problem, or a draft to compare with yours. It can't see files or run tools, so put everything it needs in the prompt. Runs on xAI's servers with the user's key and is billed to them: use it when a second view is worth it, never send secrets, and weigh its answer rather than adopting it.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "prompt": ["type": "string", "description": "The question and all the material it needs."],
                "system": ["type": "string", "description": "Optional instructions on how to answer."],
                "title": ["type": "string", "description": "A few words saying what you asked, for the user's stats."],
            ],
            "required": ["prompt"],
        ],
    ]

    static let codexTool: JSONValue = [
        "name": "ask_codex",
        "description": "Ask OpenAI's Codex, signed in with the user's ChatGPT plan, for an independent take. Unlike ask_grok it can read this project itself (read-only: it can look around and run read-only commands, never edit), so give it the question and where to look rather than pasting files. Good for a second review of a diff or design, a bug you're stuck on, or checking an assumption about the codebase. It takes a minute or two and counts against the user's ChatGPT usage: use it when a second view is worth that, weigh its answer, and tell the user where it agreed or differed.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "prompt": ["type": "string", "description": "The question, with the files, functions or diff to look at."],
                "title": ["type": "string", "description": "A few words saying what you asked, for the user's stats."],
            ],
            "required": ["prompt"],
        ],
    ]

    static let claudeTool: JSONValue = [
        "name": "ask_claude",
        "description": "Ask Anthropic's Claude, signed in with the user's Claude plan, for an independent take. It can read and search this project itself (read-only: it never edits or runs commands), so give it the question and where to look rather than pasting files. Good for a second review of a diff or design, a bug you're stuck on, or checking an assumption about the codebase. It takes a minute or two and counts against the user's Claude usage: use it when a second view is worth that, weigh its answer, and tell the user where it agreed or differed.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "prompt": ["type": "string", "description": "The question, with the files, functions or diff to look at."],
                "title": ["type": "string", "description": "A few words saying what you asked, for the user's stats."],
            ],
            "required": ["prompt"],
        ],
    ]

    static let lookTool: JSONValue = [
        "name": "look",
        "description": "Ask Looker, a vision model on the user's Mac, about an image file: a screenshot of the app, a design mockup, a diagram, or a picture of an error. It quotes visible text and describes layout; it can miss small details, so check anything that matters. Saves the user's plan usage and keeps the image on their Mac.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "image": ["type": "string", "description": "Path to a PNG, JPEG, HEIC or similar image, relative to the project or absolute."],
                "question": ["type": "string", "description": "What to look for or read out."],
                "title": ["type": "string", "description": "A few words saying what you asked, for the user's stats."],
            ],
            "required": ["image", "question"],
        ],
    ]

    /// Dante's own pages, from spec/: always offered, since they never leave the Mac.
    static let pageTools: [JSONValue] = [
        [
            "name": "dante_pages",
            "description": "Describe Dante, the IDE the user is in: without a page, every page and view in a line each; with one, its full spec (what it shows, what the user can do there, its states and edge cases). Use it when the user asks where to find something in Dante or how a page works, before answering from memory.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "page": ["type": "string", "description": "A page id from the list, like map.infra or security. Leave out for the list."],
                ],
            ],
        ],
        [
            "name": "show_page",
            "description": "Open a page in Dante for the user, when what they asked about is shown there (the Security page for findings, Map › Infra for the pipelines). Say what they'll see on it.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "page": ["type": "string", "description": "A page id from dante_pages, like map.infra or data."],
                ],
                "required": ["page"],
            ],
        ],
    ]

    /// Frames of a motion piece, drawn by the app.
    static let motionTool: JSONValue = [
        "name": "motion_frames",
        "description": "Render frames of a motion piece you're making (a folder under docs/motion with motion.yaml and index.html) at the times you choose, and get PNG paths to read, plus any script errors. Dante draws them exactly as its renderer will. Use it after building or changing a scene, at beat starts, mid-transition and the end, then fix what looks wrong and look again.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "folder": ["type": "string", "description": "The piece's folder, project-relative, like docs/motion/anatomy-of-the-system."],
                "times": ["type": "array", "items": ["type": "number"], "description": "Seconds into the piece, up to 12."],
            ],
            "required": ["folder", "times"],
        ],
    ]

    /// `dante_pages`: the list, or one page's spec.
    static func pages(_ id: String?) -> String {
        guard let id, !id.isEmpty else {
            let lines = FeatureGuide.features.map { "- \($0.id): \(FeatureGuide.place($0)). \($0.summary)" }
            return "Dante's pages (ids for dante_pages and show_page):\n" + lines.joined(separator: "\n")
        }
        guard let feature = FeatureGuide.resolve(id) else {
            return "No page \(id). Pages: " + FeatureGuide.features.map(\.id).joined(separator: ", ")
        }
        return "Page \(feature.id), shown as \(FeatureGuide.place(feature)).\n\n" + feature.markdown
    }

    static let securityTool: JSONValue = [
        "name": "security_report",
        "description": "Run Dante's security scan of this project again and get what its Security page shows: the score out of 100, the grade, and the findings most severe first, each with where it is and how to fix it. Covers secrets, personal information (POPIA), encryption, injection, containers, CI, infrastructure and, with the scanners installed, dependencies. Use it first for any question about the project's security, a score or what's critical, instead of exploring the code or sending sub-agents; then read only what it names. Runs on the user's Mac in seconds and updates the page they see.",
        "inputSchema": ["type": "object", "properties": [:]],
    ]

    static let searchTool: JSONValue = [
        "name": "search_code",
        "description": "Search this project by meaning with a local embedding model: describe what the code does (\"where failed payments are retried\", \"how the session token is refreshed\") and get the best matching pieces with their lines. Use it when you don't know the names to grep for; use grep when you do. Fast and free: it runs on the user's Mac.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "question": ["type": "string", "description": "What the code you're looking for does, in plain words."],
                "limit": ["type": "integer", "description": "How many pieces to return (default 6, at most 20)."],
            ],
            "required": ["question"],
        ],
    ]

    static var localTools: [JSONValue] {
        let kinds = DelegateKind.allCases.map { "\($0.rawValue): \($0.guidance)" }.joined(separator: "; ")
        return [
            [
                "name": "delegate",
                "description": .string("Hand a self-contained job to a local model on the user's Mac, saving their Claude usage. Good for: \(kinds). The model can't see files or run tools: put everything it needs in the prompt. It's weaker than you, so check the answer before using it, and do the job yourself when it needs judgement across the codebase."),
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "kind": ["type": "string", "enum": .array(DelegateKind.allCases.map { .string($0.rawValue) })],
                        "title": ["type": "string", "description": "A few words saying what the job is, for the user's stats."],
                        "prompt": ["type": "string", "description": "The full instructions and material: the file, log or diff to work on."],
                    ],
                    "required": ["kind", "prompt"],
                ],
            ],
            [
                "name": "local_models",
                "description": "List the models in Ollama on the user's Mac and which job each would get.",
                "inputSchema": ["type": "object", "properties": [:]],
            ],
        ]
    }

    func call(_ name: String, arguments: JSONValue) async -> JSONValue {
        switch name {
        case "delegate":
            guard let kind = arguments["kind"]?.string.flatMap(DelegateKind.init(rawValue:)),
                  let prompt = arguments["prompt"]?.string, !prompt.isEmpty else {
                return Self.text("delegate needs a kind (\(DelegateKind.allCases.map(\.rawValue).joined(separator: ", "))) and a prompt.", isError: true)
            }
            let title = arguments["title"]?.string ?? String(prompt.prefix(60))
            do {
                let (model, reply) = try await run(kind, prompt)
                ledger?.append(AgentJob(kind: kind.rawValue, provider: .local, model: model, project: project,
                                        promptTokens: reply.promptTokens, outputTokens: reply.outputTokens, seconds: reply.seconds,
                                        requestedBy: requester, title: title, why: arguments["why"]?.string, gist: AgentJob.gist(of: reply.text)))
                let header = "[\(kind.agent) · \(model) · \(reply.promptTokens)→\(reply.outputTokens) tokens · \(String(format: "%.1f", reply.seconds))s] Check this before relying on it."
                return Self.text(header + "\n\n" + reply.text)
            } catch {
                ledger?.append(AgentJob(kind: kind.rawValue, provider: .local, model: "unavailable", project: project,
                                        outcome: .failed, requestedBy: requester, title: title, why: arguments["why"]?.string, gist: AgentJob.gist(of: error.localizedDescription)))
                return Self.text("The local model couldn’t do this: \(error.localizedDescription) Do it yourself.", isError: true)
            }
        case "decide":
            return await callDecide(arguments)
        case "ask_grok":
            return await callGrok(arguments)
        case "ask_codex":
            return await callCodex(arguments)
        case "ask_claude":
            return await callClaude(arguments)
        case "look":
            return await callLook(arguments)
        case "search_code":
            guard let searchCode, let question = arguments["question"]?.string, !question.isEmpty else {
                return Self.text("search_code needs a question.", isError: true)
            }
            let limit = min(max(arguments["limit"]?.int ?? 6, 1), 20)
            do {
                return Self.text(try await searchCode(question, limit))
            } catch {
                return Self.text("Couldn’t search by meaning: \(error.localizedDescription) Use grep instead.", isError: true)
            }
        case "dante_pages":
            return Self.text(Self.pages(arguments["page"]?.string))
        case "show_page":
            guard let id = arguments["page"]?.string, let feature = FeatureGuide.resolve(id) else {
                return Self.text("No page \(arguments["page"]?.string ?? "named"). Pages: " + FeatureGuide.features.map(\.id).joined(separator: ", "), isError: true)
            }
            // The app sees the call go by and opens the page; this only answers.
            return Self.text("Dante is showing \(FeatureGuide.place(feature)) to the user.")
        case "motion_frames":
            guard let motionFrames, let folder = MotionFrames.folder(arguments["folder"]?.string) else {
                return Self.text("motion_frames needs the piece's folder, like docs/motion/<name>.", isError: true)
            }
            let times = MotionFrames.times((arguments["times"]?.array ?? []).compactMap { $0.double ?? $0.int.map(Double.init) })
            guard !times.isEmpty else { return Self.text("motion_frames needs times in seconds.", isError: true) }
            let answer = await motionFrames(folder, times)
            return Self.text(answer.text, isError: answer.isError)
        case "security_report":
            guard let securityReport else { return Self.text("Dante's security scan isn’t available here.", isError: true) }
            let started = Date()
            let summary = await securityReport()
            ledger?.append(AgentJob(kind: "audit", provider: .local, model: "dante-scan", project: project, seconds: Date().timeIntervalSince(started),
                                    requestedBy: requester, title: "Security scan", gist: summary.split(separator: "\n").first.map(String.init)))
            return Self.text(summary + "\n\nThis is the Security page the user sees; Dante has opened it for them.")
        case "local_models":
            guard let installed = await models() else { return Self.text("Ollama isn’t running on this Mac.", isError: true) }
            let lines = installed.map { model -> String in
                let jobs = DelegateKind.allCases.filter { ModelRouting.model(for: $0, installed: installed) == model.name }.map(\.rawValue)
                let note = model.isCloud ? "cloud, not used" : model.isVision ? "images" : model.isEmbedding ? "embeddings" : (jobs.isEmpty ? "spare" : jobs.joined(separator: ", "))
                return "- \(model.name) (\(model.parameterSize.isEmpty ? "?" : model.parameterSize)): \(note)"
            }
            return Self.text(lines.isEmpty ? "No models installed." : lines.joined(separator: "\n"))
        default:
            return Self.text("Unknown tool \(name).", isError: true)
        }
    }

    func callLook(_ arguments: JSONValue) async -> JSONValue {
        guard let look, let path = arguments["image"]?.string, !path.isEmpty, let question = arguments["question"]?.string, !question.isEmpty else {
            return Self.text("look needs an image path and a question.", isError: true)
        }
        let title = arguments["title"]?.string ?? String(question.prefix(60))
        guard let model = await lookerModel?() else {
            return Self.text(Looker.missingReason(installed: await models() ?? []) + " Look at the image yourself.", isError: true)
        }
        do {
            let reply = try await look(model, path, question)
            ledger?.append(AgentJob(kind: Looker.kind, provider: .local, model: model, project: project,
                                    promptTokens: reply.promptTokens, outputTokens: reply.outputTokens, seconds: reply.seconds,
                                    requestedBy: requester, title: title, why: arguments["why"]?.string, gist: AgentJob.gist(of: reply.text)))
            let header = "[\(Looker.agent) · \(model) · \(String(format: "%.1f", reply.seconds))s] Check anything that matters."
            return Self.text(header + "\n\n" + reply.text)
        } catch {
            ledger?.append(AgentJob(kind: Looker.kind, provider: .local, model: model, project: project, outcome: .failed,
                                    requestedBy: requester, title: title, why: arguments["why"]?.string, gist: AgentJob.gist(of: error.localizedDescription)))
            return Self.text("Looker couldn’t read it: \(error.localizedDescription) Look at the image yourself.", isError: true)
        }
    }

    func callDecide(_ arguments: JSONValue) async -> JSONValue {
        guard let decide else { return Self.text("Jev isn’t set up: the user can add a key in Dante’s Settings.", isError: true) }
        let material = arguments["material"] ?? arguments["state"] ?? .null
        let questions = (arguments["questions"]?.array ?? []).compactMap { value -> (name: String, question: JevQuestion)? in
            guard let name = value["name"]?.string, !name.isEmpty, let question = JevQuestion.parse(value) else { return nil }
            return (name, question)
        }
        guard material.string.map({ !$0.isEmpty }) ?? !material.isNull, !questions.isEmpty else {
            return Self.text("decide needs material and at least one question with a name, a type (choice with two or more options, score with 2–10 levels, or yes_no) and instructions.", isError: true)
        }
        let title = arguments["title"]?.string ?? questions.map(\.name).joined(separator: ", ")
        let started = Date()
        do {
            let decision = try await decide(material, questions)
            let seconds = Date().timeIntervalSince(started)
            ledger?.append(AgentJob(kind: "decision", provider: .jev, model: decision.model, project: project,
                                    promptTokens: decision.inputTokens, seconds: seconds, requestedBy: requester,
                                    title: title, costUSD: decision.costUSD, why: arguments["why"]?.string, gist: AgentJob.gist(of: decision.summary(questions))))
            let header = "[Jev · \(decision.model) · \(decision.inputTokens) tokens · $\(String(format: "%.6f", decision.costUSD)) · \(String(format: "%.2f", seconds))s]"
            return Self.text(header + "\n\n" + decision.summary(questions))
        } catch {
            ledger?.append(AgentJob(kind: "decision", provider: .jev, model: "jev", project: project,
                                    seconds: Date().timeIntervalSince(started), outcome: .failed, requestedBy: requester, title: title, why: arguments["why"]?.string, gist: AgentJob.gist(of: error.localizedDescription)))
            return Self.text("Jev couldn’t decide: \(error.localizedDescription) Decide yourself.", isError: true)
        }
    }

    func callGrok(_ arguments: JSONValue) async -> JSONValue {
        guard let askGrok else { return Self.text("Grok isn’t set up: the user can add an xAI key in Dante’s Settings.", isError: true) }
        guard let prompt = arguments["prompt"]?.string, !prompt.isEmpty else {
            return Self.text("ask_grok needs a prompt.", isError: true)
        }
        let title = arguments["title"]?.string ?? String(prompt.prefix(60))
        let started = Date()
        do {
            let reply = try await askGrok(arguments["system"]?.string, prompt)
            ledger?.append(AgentJob(kind: "opinion", provider: .grok, model: reply.model, project: project,
                                    promptTokens: reply.promptTokens, outputTokens: reply.outputTokens, seconds: reply.seconds,
                                    requestedBy: requester, title: title, why: arguments["why"]?.string, gist: AgentJob.gist(of: reply.text)))
            let header = "[Grok · \(reply.model) · \(reply.promptTokens)→\(reply.outputTokens) tokens · \(String(format: "%.1f", reply.seconds))s] A second opinion: weigh it, don’t just adopt it."
            return Self.text(header + "\n\n" + reply.text)
        } catch {
            ledger?.append(AgentJob(kind: "opinion", provider: .grok, model: "grok", project: project,
                                    seconds: Date().timeIntervalSince(started), outcome: .failed, requestedBy: requester, title: title, why: arguments["why"]?.string, gist: AgentJob.gist(of: error.localizedDescription)))
            return Self.text("Grok couldn’t answer: \(error.localizedDescription)", isError: true)
        }
    }

    func callCodex(_ arguments: JSONValue) async -> JSONValue {
        guard let askCodex else { return Self.text("Codex isn’t set up: the user can turn it on in Dante’s Settings.", isError: true) }
        guard let prompt = arguments["prompt"]?.string, !prompt.isEmpty else {
            return Self.text("ask_codex needs a prompt.", isError: true)
        }
        let title = arguments["title"]?.string ?? String(prompt.prefix(60))
        let started = Date()
        do {
            let reply = try await askCodex(prompt)
            ledger?.append(AgentJob(kind: "opinion", provider: .codex, model: "codex", project: project,
                                    promptTokens: reply.inputTokens, outputTokens: reply.outputTokens, seconds: reply.seconds,
                                    requestedBy: requester, title: title, why: arguments["why"]?.string, gist: AgentJob.gist(of: reply.text)))
            let looked = reply.commands.isEmpty ? "" : " · looked with \(reply.commands.count) command\(reply.commands.count == 1 ? "" : "s")"
            let header = "[Codex · \(reply.inputTokens)→\(reply.outputTokens) tokens · \(String(format: "%.0f", reply.seconds))s\(looked)] A second opinion: weigh it, don’t just adopt it."
            return Self.text(header + "\n\n" + reply.text)
        } catch {
            ledger?.append(AgentJob(kind: "opinion", provider: .codex, model: "codex", project: project,
                                    seconds: Date().timeIntervalSince(started), outcome: .failed, requestedBy: requester, title: title, why: arguments["why"]?.string, gist: AgentJob.gist(of: error.localizedDescription)))
            return Self.text("Codex couldn’t answer: \(error.localizedDescription)", isError: true)
        }
    }

    func callClaude(_ arguments: JSONValue) async -> JSONValue {
        guard let askClaude else { return Self.text("Claude isn’t set up for second opinions here.", isError: true) }
        guard let prompt = arguments["prompt"]?.string, !prompt.isEmpty else {
            return Self.text("ask_claude needs a prompt.", isError: true)
        }
        let title = arguments["title"]?.string ?? String(prompt.prefix(60))
        let started = Date()
        do {
            let reply = try await askClaude(prompt)
            ledger?.append(AgentJob(kind: "opinion", provider: .claude, model: "claude", project: project,
                                    promptTokens: reply.inputTokens, outputTokens: reply.outputTokens, seconds: reply.seconds,
                                    requestedBy: requester, title: title, why: arguments["why"]?.string, gist: AgentJob.gist(of: reply.text)))
            let header = "[Claude · \(reply.inputTokens)→\(reply.outputTokens) tokens · \(String(format: "%.0f", reply.seconds))s] A second opinion: weigh it, don’t just adopt it."
            return Self.text(header + "\n\n" + reply.text)
        } catch {
            ledger?.append(AgentJob(kind: "opinion", provider: .claude, model: "claude", project: project,
                                    seconds: Date().timeIntervalSince(started), outcome: .failed, requestedBy: requester, title: title, why: arguments["why"]?.string, gist: AgentJob.gist(of: error.localizedDescription)))
            return Self.text("Claude couldn’t answer: \(error.localizedDescription)", isError: true)
        }
    }

    static func text(_ text: String, isError: Bool = false) -> JSONValue {
        ["content": [["type": "text", "text": .string(text)]], "isError": .bool(isError)]
    }

    /// Reads stdin until it closes, answering each line on stdout.
    public func serve() async {
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty, let reply = await handle(line) else { continue }
            FileHandle.standardOutput.write(Data((reply + "\n").utf8))
        }
    }
}
