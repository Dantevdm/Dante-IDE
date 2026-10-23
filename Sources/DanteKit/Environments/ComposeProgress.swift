import Foundation

/// `docker compose --progress plain` output read into what matters: one line per service
/// (building step 3 of 7, started, healthy, failed) and the errors, so the raw stream of
/// `#18 sha256:…` lines can stay folded away.
public struct ComposeProgress: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case building(step: String?, detail: String)
        case built
        case starting(String)
        case running(String)
        case stopped(String)
        case failed(String)

        public var text: String {
            switch self {
            case .building(let step, let detail): "Building" + (step.map { " \($0)" } ?? "") + (detail.isEmpty ? "" : " · \(detail)")
            case .built: "Built"
            case .starting(let word), .running(let word), .stopped(let word), .failed(let word): word
            }
        }

        public var isFailed: Bool { if case .failed = self { true } else { false } }
        public var isBusy: Bool {
            switch self {
            case .building, .starting: true
            default: false
            }
        }
    }

    public struct Service: Equatable, Sendable, Identifiable {
        public var name: String
        public var phase: Phase
        /// Build steps that came from cache, and that ran.
        public var cached = 0
        public var ran = 0
        public var id: String { name }
    }

    public var services: [Service] = []
    /// Error lines, without repeats, in the order they came.
    public var errors: [String] = []

    /// `known` are the compose file's services, for telling them apart in container names.
    public static func parse(_ lines: [String], known: [String] = []) -> ComposeProgress {
        var progress = ComposeProgress()
        var stepService: [String: String] = [:]
        var stepTitle: [String: (step: String?, detail: String)] = [:]

        func set(_ name: String, _ phase: Phase, cached: Int = 0, ran: Int = 0) {
            if let index = progress.services.firstIndex(where: { $0.name == name }) {
                // A failure stays until something newer than it succeeds for the service.
                progress.services[index].phase = phase
                progress.services[index].cached += cached
                progress.services[index].ran += ran
            } else {
                progress.services.append(Service(name: name, phase: phase, cached: cached, ran: ran))
            }
        }
        func error(_ text: String) {
            let line = text.trimmingCharacters(in: .whitespaces)
            if !line.isEmpty, !progress.errors.contains(line), progress.errors.count < 8 { progress.errors.append(line) }
        }

        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#"), let space = line.firstIndex(of: " ") {
                // BuildKit: `#18 [backend 6/7] RUN npm run build`, `#18 DONE 2.1s`, `#18 CACHED`, `#18 ERROR: …`.
                let number = String(line[line.index(after: line.startIndex)..<space])
                let rest = line[line.index(after: space)...].trimmingCharacters(in: .whitespaces)
                if rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                    let tag = rest[rest.index(after: rest.startIndex)..<close].split(separator: " ").map(String.init)
                    guard let service = tag.first, service != "internal" else { continue }
                    let step = tag.count > 1 && tag[1] != "internal" && tag[1].contains("/") ? tag[1] : nil
                    let detail = step == nil ? "" : String(rest[rest.index(after: close)...]).trimmingCharacters(in: .whitespaces)
                    stepService[number] = service
                    stepTitle[number] = (step, String(detail.prefix(80)))
                    set(service, .building(step: step, detail: String(detail.prefix(80))))
                } else if let service = stepService[number] {
                    if rest == "CACHED" {
                        set(service, progressPhase(service, in: progress, fallback: stepTitle[number]), cached: 1)
                    } else if rest.hasPrefix("DONE") {
                        if stepTitle[number]?.step != nil { set(service, progressPhase(service, in: progress, fallback: stepTitle[number]), ran: 1) }
                    } else if rest.hasPrefix("ERROR") {
                        set(service, .failed("Build failed"))
                        error("\(service): " + rest.replacingOccurrences(of: "ERROR: ", with: ""))
                    }
                } else if rest.hasPrefix("ERROR") {
                    error(rest.replacingOccurrences(of: "ERROR: ", with: ""))
                }
                continue
            }
            let words = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            // Compose: `Container shop-db-1  Started`, `backend  Built`, `Network shop_default  Created`.
            if words.count >= 3, ["Container", "Service"].contains(words[0]) {
                let name = service(fromContainer: words[1], known: known)
                let state = words[2...].joined(separator: " ")
                set(name, phase(for: state))
                if state.hasPrefix("Error") { error(line) }
            } else if words.count == 2, words[1] == "Built" {
                set(words[0], .built)
            } else if ["Network", "Volume", "Image"].contains(words.first ?? "") {
                continue
            } else if line.localizedCaseInsensitiveContains("error") || line.hasPrefix("dependency failed") || line.contains("is unhealthy") {
                error(line)
            }
        }
        return progress
    }

    /// While building, a cached or finished step leaves the service on its newest step.
    private static func progressPhase(_ service: String, in progress: ComposeProgress, fallback: (step: String?, detail: String)?) -> Phase {
        if let current = progress.services.first(where: { $0.name == service })?.phase { return current }
        return .building(step: fallback?.step, detail: fallback?.detail ?? "")
    }

    static func phase(for state: String) -> Phase {
        switch state.split(separator: " ").first.map(String.init) ?? state {
        case "Creating", "Created", "Recreate", "Recreated", "Starting", "Waiting", "Pulling", "Pulled": .starting(state)
        case "Started", "Running", "Healthy": .running(state)
        case "Stopping", "Stopped", "Removing", "Removed", "Killing", "Killed": .stopped(state)
        case "Error", "Unhealthy", "Exited": .failed(state)
        default: .starting(state)
        }
    }

    /// `shop-db-1` (or `shop_db_1`) → `db`, matched against the compose file's services when given.
    static func service(fromContainer name: String, known: [String]) -> String {
        for service in known.sorted(by: { $0.count > $1.count }) {
            if name == service { return service }
            for separator in ["-", "_"] {
                let marker = separator + service + separator
                if let range = name.range(of: marker, options: .backwards), Int(name[range.upperBound...]) != nil { return service }
            }
        }
        var parts = name.split(whereSeparator: { $0 == "-" || $0 == "_" }).map(String.init)
        guard parts.count >= 3, Int(parts.last!) != nil else { return name }
        parts.removeLast()
        return parts.dropFirst().joined(separator: "-")
    }
}
