import Darwin
import Foundation
import Security

/// Agents that run on someone else's servers, with the user's own API key: Grok (xAI) for a
/// second opinion, Jev for fast typed decisions. Both are off until a key is added in Settings.
public enum CloudAgent: String, Sendable, CaseIterable, Identifiable, Codable {
    case grok
    case jev

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .grok: "Grok"
        case .jev: "Jev"
        }
    }

    public var company: String {
        switch self {
        case .grok: "xAI"
        case .jev: "TypeSafe AI"
        }
    }

    public var role: String {
        switch self {
        case .grok: "Second opinions and drafts"
        case .jev: "Fast typed decisions"
        }
    }

    /// Where the key reaches the `dante mcp` server, and where a key in the shell is found.
    public var environmentVariable: String {
        switch self {
        case .grok: "XAI_API_KEY"
        case .jev: "JEV_API_KEY"
        }
    }

    /// What a key looks like, for the placeholder.
    public var keyHint: String {
        switch self {
        case .grok: "xai-…"
        case .jev: "jv_live_…"
        }
    }

    public var keysPage: URL {
        switch self {
        case .grok: URL(string: "https://console.x.ai")!
        case .jev: URL(string: "https://jevtypesafeai.com")!
        }
    }

    public var provider: AgentJob.Provider {
        switch self {
        case .grok: .grok
        case .jev: .jev
        }
    }
}

/// API keys for cloud agents, in the login Keychain. Never written to the repo, a command
/// line or Claude's environment.
public enum AgentKeys {
    static let service = "dev.dante.ide.agents"

    public static func key(for agent: CloudAgent) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: agent.rawValue,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data,
              let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        return key
    }

    /// Saves a key, or removes it when nil or empty.
    @discardableResult
    public static func set(_ key: String?, for agent: CloudAgent) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: agent.rawValue,
        ]
        SecItemDelete(base as CFDictionary)
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return true }
        var item = base
        item[kSecValueData as String] = Data(trimmed.utf8)
        item[kSecAttrLabel as String] = "Dante: \(agent.title) API key"
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    /// The keys there are, by environment variable, for the MCP server's config.
    public static func environment() -> [String: String] {
        var result: [String: String] = [:]
        for agent in CloudAgent.allCases {
            if let key = key(for: agent) { result[agent.environmentVariable] = key }
        }
        return result
    }

    /// "xai-abcd…wxyz": enough to recognise a key without showing it.
    public static func masked(_ key: String) -> String {
        guard key.count > 12 else { return String(repeating: "•", count: 8) }
        return "\(key.prefix(6))…\(key.suffix(4))"
    }
}

/// The MCP config Claude Code reads to start `dante mcp`, written to a file only this user
/// can read when it carries keys, so they never appear on a command line. Each file is named
/// after the app's process, and files of processes that have gone are removed.
public enum MCPConfigFile {
    public static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Dante/mcp")
    }

    /// The config's JSON: the dante server with its environment.
    public static func json(command: String, environment: [String: String]) -> String {
        var server: [String: JSONValue] = ["type": "stdio", "command": .string(command), "args": ["mcp"]]
        if !environment.isEmpty { server["env"] = .object(environment.mapValues { .string($0) }) }
        return JSONValue.object(["mcpServers": ["dante": .object(server)]]).jsonLine
    }

    /// Writes a config into `folder` (0700) as a 0600 file and returns its path.
    public static func write(_ json: String, in folder: URL = folder, pid: Int32 = ProcessInfo.processInfo.processIdentifier) throws -> URL {
        let manager = FileManager.default
        try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        let url = folder.appending(path: "\(pid)-\(UUID().uuidString).json")
        guard manager.createFile(atPath: url.path, contents: Data(json.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return url
    }

    /// Removes configs left by app processes that are no longer running.
    public static func removeStale(in folder: URL = folder, isRunning: (Int32) -> Bool = { kill($0, 0) == 0 }) {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: folder.path) else { return }
        for name in names where name.hasSuffix(".json") {
            guard let pid = name.split(separator: "-").first.flatMap({ Int32($0) }), !isRunning(pid) else { continue }
            try? manager.removeItem(at: folder.appending(path: name))
        }
    }
}

/// Settings for the `dante mcp` server that aren't secret, passed in its environment.
public enum DelegateEnvironment {
    /// "0" leaves out the local-model tools (delegation to Ollama is off).
    public static let local = "DANTE_LOCAL"
    /// The Grok model chosen in Settings.
    public static let grokModel = "DANTE_GROK_MODEL"
    /// The Codex CLI to ask, when the user lets Claude ask Codex.
    public static let codex = "DANTE_CODEX"
    /// The model Codex uses; unset for its default.
    public static let codexModel = "DANTE_CODEX_MODEL"
    /// Claude Code, for Codex's second opinions when Codex is in charge.
    public static let claude = "DANTE_CLAUDE"
    /// The model Claude answers with; unset for the user's default.
    public static let claudeModel = "DANTE_CLAUDE_MODEL"
    /// Who calls the tools, "claude" or "codex", so the ledger says who asked.
    public static let requester = "DANTE_REQUESTER"
}
