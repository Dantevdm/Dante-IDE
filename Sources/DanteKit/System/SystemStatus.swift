import Foundation

/// What Dante can reach on this Mac, shown on the launch screen.
public struct SystemStatus: Equatable, Sendable {
    public var claudePath: String?
    public var dockerRunning: Bool

    public init(claudePath: String? = nil, dockerRunning: Bool = false) {
        self.claudePath = claudePath
        self.dockerRunning = dockerRunning
    }

    public static func detect(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> SystemStatus {
        SystemStatus(
            claudePath: findExecutable("claude", environment: environment, fileManager: fileManager),
            dockerRunning: dockerSocketExists(fileManager: fileManager)
        )
    }

    /// Searches PATH plus the usual install locations. Apps opened from Finder
    /// get a minimal PATH, so the common folders are checked explicitly.
    public static func findExecutable(
        _ name: String,
        environment: [String: String],
        fileManager: FileManager = .default
    ) -> String? {
        let home = fileManager.homeDirectoryForCurrentUser.path
        let fromPath = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let common = ["\(home)/.local/bin", "\(home)/.claude/local", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        var seen = Set<String>()
        for directory in fromPath + common where seen.insert(directory).inserted {
            let candidate = (directory as NSString).appendingPathComponent(name)
            if fileManager.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    static func dockerSocketExists(fileManager: FileManager) -> Bool {
        let home = fileManager.homeDirectoryForCurrentUser.path
        return ["/var/run/docker.sock", "\(home)/.docker/run/docker.sock", "\(home)/.orbstack/run/docker.sock"]
            .contains { fileManager.fileExists(atPath: $0) }
    }
}
