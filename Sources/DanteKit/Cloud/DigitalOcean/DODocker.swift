import Foundation

/// Building a component's image on this Mac and pushing it to the account's DigitalOcean
/// registry. App Platform runs linux/amd64, so that's what's built, whatever this Mac is. The
/// push signs in with credentials that expire in half an hour, written to a Docker config in a
/// folder of its own (0700) that's removed straight after: never on a command line, never in
/// the person's own Docker config.
public enum DODocker {
    public static let registryHost = "registry.digitalocean.com"

    /// `web-1a2b3c4` for a clean checkout; a build with uncommitted changes adds the time, so
    /// two of them never share a tag.
    public static func tag(component: String, commit: String?, dirty: Bool, now: Date = .now) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let sha = commit.map { String($0.prefix(7)) } ?? "build"
        return "\(component)-\(sha)" + (dirty || commit == nil ? "-" + formatter.string(from: now) : "")
    }

    public static func reference(registry: String, repository: String, tag: String) -> String {
        "\(registryHost)/\(registry)/\(repository):\(tag)"
    }

    /// The `docker build` for one image. `dockerfile` is the file to build with: the
    /// project's own, or one Dante wrote for this build.
    public static func buildArguments(reference: String, context: URL, dockerfile: URL) -> [String] {
        ["docker", "build", "--platform", "linux/amd64", "--progress", "plain", "--pull", "-t", reference, "-f", dockerfile.path, context.path]
    }

    /// The images the deploy has to build: the planner's builds whose component the spec still
    /// takes from the registry. Others keep the image already there.
    public static func builds(for spec: [String: Any], planned: [DOImageBuild]) -> [(build: DOImageBuild, repository: String)] {
        var result: [(DOImageBuild, String)] = []
        for list in DOSpecSend.componentLists {
            for component in spec[list] as? [[String: Any]] ?? [] {
                guard let name = component["name"] as? String, let image = component["image"] as? [String: Any],
                      (image["registry_type"] as? String)?.uppercased() == "DOCR", let repository = image["repository"] as? String,
                      let build = planned.first(where: { $0.component == name }) else { continue }
                result.append((build, repository))
            }
        }
        return result
    }

    public struct Problem: Error, Equatable, Sendable {
        public var message: String
    }

    public enum Event: Sendable {
        case line(String)
        case step(String)
    }

    /// Builds and pushes each image; returns the tags by component, or what went wrong.
    public static func buildAndPush(_ builds: [(build: DOImageBuild, repository: String)], registry: String, commit: String?, dirty: Bool,
                                    projectRoot: URL, credentials: Data, event: @Sendable (Event) -> Void) async -> Result<[String: String], Problem> {
        let fileManager = FileManager.default
        let folder = fileManager.temporaryDirectory.appending(path: "dante-docr-\(UUID().uuidString)")
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try credentials.write(to: folder.appending(path: "config.json"), options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: folder.appending(path: "config.json").path)
        } catch {
            try? fileManager.removeItem(at: folder)
            return .failure(Problem(message: "Dante couldn't prepare the registry sign-in: \(error.localizedDescription)"))
        }
        defer { try? fileManager.removeItem(at: folder) }

        var tags: [String: String] = [:]
        for (build, repository) in builds {
            let tag = tag(component: build.component, commit: commit, dirty: dirty)
            let reference = reference(registry: registry, repository: repository, tag: tag)
            let context = build.context.isEmpty ? projectRoot : projectRoot.appending(path: build.context)
            let dockerfile: URL
            if let text = build.dockerfile {
                dockerfile = folder.appending(path: "Dockerfile.\(build.component)")
                do { try text.write(to: dockerfile, atomically: true, encoding: .utf8) } catch { return .failure(Problem(message: error.localizedDescription)) }
            } else {
                dockerfile = projectRoot.appending(path: build.dockerfilePath ?? "Dockerfile")
            }
            event(.step("Building \(build.component)"))
            if let problem = await stream(buildArguments(reference: reference, context: context, dockerfile: dockerfile), in: projectRoot, event: event) {
                return .failure(Problem(message: "Building \(build.component) failed: \(problem)"))
            }
            event(.step("Pushing \(build.component)"))
            if let problem = await stream(["docker", "--config", folder.path, "push", reference], in: projectRoot, event: event) {
                return .failure(Problem(message: "Pushing \(build.component) failed: \(problem)"))
            }
            tags[build.component] = tag
        }
        return .success(tags)
    }

    /// Runs a command, passing its lines on; nil when it succeeded, else its last lines.
    static func stream(_ arguments: [String], in directory: URL, event: @Sendable (Event) -> Void) async -> String? {
        let running: Shell.Running
        do { running = try Shell.stream(arguments, in: directory) } catch { return error.localizedDescription }
        var tail: [String] = []
        // Stop ends the process at once: a push can go quiet for minutes between lines.
        await withTaskCancellationHandler {
            for await line in running.lines {
                event(.line(line))
                tail.append(line)
                if tail.count > 6 { tail.removeFirst() }
            }
        } onCancel: {
            running.terminate()
        }
        let status = await running.exitStatus()
        if Task.isCancelled { return "Stopped." }
        return status == 0 ? nil : tail.joined(separator: "\n")
    }
}
