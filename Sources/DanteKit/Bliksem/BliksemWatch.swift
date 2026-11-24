import Foundation

/// What Bliksem watches on the target while it runs: CPU and memory of the process or
/// container serving it, and, for a JVM, where its threads spend their time (stack samples
/// from `jcmd Thread.print`, a sampling profiler that needs no agent in the app).
public enum WatchSource: Equatable, Sendable {
    /// A program running on this Mac.
    case process(pid: Int32, command: String)
    /// A container of this project's compose services.
    case container(name: String, service: String)

    public var label: String {
        switch self {
        case .process(let pid, let command): "\(command) (pid \(pid))"
        case .container(_, let service): "the compose service \(service)"
        }
    }
}

/// One reading of the target's CPU and memory.
public struct ResourceSample: Equatable, Sendable, Codable {
    /// Seconds from the start of the run.
    public var t: Double
    /// Percent of one core (200 is two cores busy).
    public var cpu: Double
    public var memory: Double

    public init(t: Double, cpu: Double, memory: Double) {
        self.t = t
        self.cpu = cpu
        self.memory = memory
    }
}

public enum ResourceReading {
    /// `ps -o time=,rss=`: CPU time used so far ("1:02.34", "01:02:03", "2-01:02:03") and
    /// resident memory in KB.
    public static func ps(_ output: String) -> (cpuSeconds: Double, memory: Double)? {
        let words = output.split(whereSeparator: \.isWhitespace)
        guard words.count >= 2, let rss = Double(words[1]) else { return nil }
        var text = String(words[0])
        var days = 0.0
        if let dash = text.firstIndex(of: "-") {
            days = Double(text[..<dash]) ?? 0
            text = String(text[text.index(after: dash)...])
        }
        let parts = text.split(separator: ":").compactMap { Double($0) }
        guard !parts.isEmpty else { return nil }
        let seconds = parts.reduce(0) { $0 * 60 + $1 } + days * 86_400
        return (seconds, rss * 1024)
    }

    /// One line of `docker stats --format '{{json .}}'`: CPU percent and memory in bytes.
    public static func dockerStats(_ line: String) -> (cpu: Double, memory: Double)? {
        // Streaming output starts each refresh with terminal clear codes.
        guard let start = line.firstIndex(of: "{"), let json = JSONValue(line: String(line[start...])),
              let cpuText = json["CPUPerc"]?.string, let memText = json["MemUsage"]?.string else { return nil }
        guard let cpu = Double(cpuText.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)) else { return nil }
        let used = memText.components(separatedBy: "/").first?.trimmingCharacters(in: .whitespaces) ?? ""
        return (cpu, bytes(used) ?? 0)
    }

    /// "512MiB", "1.2GiB", "800kB", "12MB".
    static func bytes(_ text: String) -> Double? {
        let units: [(String, Double)] = [("TiB", 1_099_511_627_776), ("GiB", 1_073_741_824), ("MiB", 1_048_576), ("KiB", 1024),
                                         ("TB", 1e12), ("GB", 1e9), ("MB", 1e6), ("kB", 1e3), ("KB", 1e3), ("B", 1)]
        for (unit, scale) in units where text.hasSuffix(unit) {
            return Double(text.dropLast(unit.count).trimmingCharacters(in: .whitespaces)).map { $0 * scale }
        }
        return Double(text)
    }

    /// "512 MB", "1.4 GB".
    public static func memory(_ bytes: Double) -> String {
        bytes >= 1e9 ? String(format: "%.1f GB", bytes / 1e9) : "\(Int((bytes / 1e6).rounded())) MB"
    }
}

// MARK: Profile

/// A stack frame from a JVM thread dump.
public struct StackFrame: Equatable, Hashable, Sendable {
    /// `shop.orders.OrderService`, `shop.orders.OrderRoutesKt$orderRoutes$1`.
    public var type: String
    public var method: String
    /// `OrderService.kt`, when the dump names it.
    public var file: String?
    public var line: Int?

    /// The class without its package or lambda suffixes: `OrderRoutesKt`.
    public var simpleType: String {
        let last = type.split(separator: ".").last.map(String.init) ?? type
        return last.components(separatedBy: "$").first ?? last
    }

    /// `OrderService.quote`, or for a lambda `orderRoutes (lambda)`.
    public var label: String {
        let pieces = type.split(separator: ".").last.map(String.init)?.components(separatedBy: "$") ?? []
        if pieces.count > 1, ["invokeSuspend", "invoke"].contains(method), let inner = pieces.dropFirst().first(where: { Int($0) == nil }) {
            return "\(inner) (lambda)"
        }
        return "\(simpleType.hasSuffix("Kt") ? String(simpleType.dropLast(2)) : simpleType).\(method)"
    }
}

public enum ThreadDump {
    private static let frame = try! NSRegularExpression(pattern: #"^\s+at\s+([\w$.<>/]+)\.([\w$<>]+)\((?:[^:)]*/)?([^:)]*?)(?::(\d+))?\)"#)

    /// The stacks of threads that were running (RUNNABLE and not parked in a poll or a
    /// socket read, which only wait for work), top frame first.
    public static func busyStacks(_ dump: String) -> [[StackFrame]] {
        var stacks: [[StackFrame]] = []
        var current: [StackFrame] = []
        var runnable = false
        func flush() {
            if runnable, let top = current.first, !idle(top) { stacks.append(current) }
            current = []
            runnable = false
        }
        for line in dump.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("\"") { flush(); continue }
            if line.contains("java.lang.Thread.State:") { runnable = line.contains("RUNNABLE"); continue }
            guard line.contains("at "), runnable else { continue }
            let text = String(line)
            let ns = text as NSString
            guard let match = frame.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { continue }
            let file = ns.substring(with: match.range(at: 3))
            let number = match.range(at: 4).location == NSNotFound ? nil : Int(ns.substring(with: match.range(at: 4)))
            current.append(StackFrame(type: ns.substring(with: match.range(at: 1)), method: ns.substring(with: match.range(at: 2)),
                                      file: file.isEmpty || file.contains(" ") ? nil : file, line: number))
        }
        flush()
        return stacks
    }

    /// Threads that look busy but only wait: selectors, accepts, socket reads, the JVM's own.
    static func idle(_ top: StackFrame) -> Bool {
        let name = top.type + "." + top.method
        return ["KQueue.poll", "EPoll.wait", "EPoll.epollWait", "KQueue.keventPoll", "Net.accept", "Net.poll", "SocketDispatcher.read",
                "NioSocketImpl", "SocketInputStream", "FileDispatcherImpl.read", "Native.epollWait", "Native.kqueueWait",
                "ProcessHandleImpl.waitForProcessExit", "Reference.waitForReferencePendingList", "Signal.dispatch",
                "Thread.sleep", "Thread.dumpThreads", "Thread.getStackTrace", "ThreadImpl.dumpThreads", "AttachListener"]
            .contains { name.contains($0) }
    }
}

/// Stack samples gathered over a run, read for the project's own code.
public struct Profile: Equatable, Sendable {
    public private(set) var samples = 0
    public private(set) var stacks: [[StackFrame]] = []
    /// Package prefixes of the project's code (`shop.orders`), from its sources.
    public var packages: [String]

    public init(packages: [String]) { self.packages = packages }

    public mutating func add(_ dump: [[StackFrame]]) {
        samples += 1
        stacks += dump
    }

    public func isOwn(_ frame: StackFrame) -> Bool {
        packages.contains { frame.type.hasPrefix($0 + ".") || frame.type == $0 }
    }

    /// A method's share of the busy stacks: `own` when it's the project's frame nearest the
    /// top (time in it or the libraries it calls), `total` when it's anywhere on the stack.
    public struct Method: Equatable, Sendable, Identifiable {
        public var label: String
        public var frame: StackFrame
        public var own: Int
        public var total: Int
        public var id: String { label }
    }

    /// The project's methods by time, from the stacks `matching` keeps (all of them by default).
    public func methods(matching keep: ([StackFrame]) -> Bool = { _ in true }) -> (busy: Int, methods: [Method]) {
        var own: [String: Int] = [:]
        var total: [String: Int] = [:]
        var frames: [String: StackFrame] = [:]
        var busy = 0
        for stack in stacks where keep(stack) {
            let mine = stack.filter(isOwn)
            guard !mine.isEmpty else { continue }
            busy += 1
            own[mine[0].label, default: 0] += 1
            var seen = Set<String>()
            for frame in mine where seen.insert(frame.label).inserted {
                total[frame.label, default: 0] += 1
                if frames[frame.label] == nil { frames[frame.label] = frame }
            }
        }
        let list = total.map { label, count in Method(label: label, frame: frames[label]!, own: own[label] ?? 0, total: count) }
            .sorted { ($0.total, $0.own, $1.label) > ($1.total, $1.own, $0.label) }
        return (busy, list)
    }

    /// The packages declared by the project's Kotlin and Java sources, cut to their first
    /// three parts so one prefix covers a module.
    public static func packages(files: [String], read: (String) -> String?) -> [String] {
        var found = Set<String>()
        for file in files where (file.hasSuffix(".kt") || file.hasSuffix(".java")) && !SystemMap.isTest(file) {
            guard let text = read(file), let range = text.range(of: #"(?m)^\s*package\s+([\w.]+)"#, options: .regularExpression) else { continue }
            let name = text[range].replacingOccurrences(of: "package", with: "").trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ";", with: "")
            found.insert(name.split(separator: ".").prefix(3).joined(separator: "."))
        }
        // Drop prefixes another one already covers.
        return found.sorted().filter { name in !found.contains { $0 != name && name.hasPrefix($0 + ".") } }
    }
}

// MARK: Watching

public enum BliksemWatcher {
    /// Reads the source's CPU and memory about once a second until cancelled.
    public static func resources(_ source: WatchSource, root: URL, since start: ContinuousClock.Instant,
                                 sink: @escaping @Sendable (ResourceSample) -> Void) async {
        func now() -> Double { (ContinuousClock.now - start).seconds }
        switch source {
        case .process(let pid, _):
            var last: (cpu: Double, at: Double)?
            while !Task.isCancelled {
                let output = await Shell.run(["ps", "-o", "time=,rss=", "-p", String(pid)], in: root, timeout: .seconds(3), withoutMise: true)
                guard output.succeeded, let reading = ResourceReading.ps(output.stdout) else { return }
                let at = now()
                if let last, at > last.at {
                    sink(ResourceSample(t: at, cpu: max(0, (reading.cpuSeconds - last.cpu) / (at - last.at) * 100), memory: reading.memory))
                }
                last = (reading.cpuSeconds, at)
                try? await Task.sleep(for: .seconds(1))
            }
        case .container(let name, _):
            guard let running = try? Shell.stream(["docker", "stats", "--format", "{{json .}}", name], in: root) else { return }
            await withTaskCancellationHandler {
                for await line in running.lines {
                    if Task.isCancelled { break }
                    if let reading = ResourceReading.dockerStats(line) { sink(ResourceSample(t: now(), cpu: reading.cpu, memory: reading.memory)) }
                }
            } onCancel: {
                running.terminate()
            }
            running.terminate()
        }
    }

    /// The command that prints the target's thread dump, or why it can't be profiled.
    public static func dumpCommand(_ source: WatchSource, root: URL) async -> Result<[String], ProfileRefusal> {
        switch source {
        case .process(let pid, _):
            let output = await Shell.run(["ps", "-o", "comm=", "-p", String(pid)], in: root, timeout: .seconds(3), withoutMise: true)
            let executable = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (executable as NSString).lastPathComponent == "java" else { return .failure(.notJVM) }
            let sibling = ((executable as NSString).deletingLastPathComponent as NSString).appendingPathComponent("jcmd")
            let jcmd = FileManager.default.isExecutableFile(atPath: sibling) ? sibling : Shell.which("jcmd")
            guard let jcmd else { return .failure(.noJcmd) }
            return .success([jcmd, String(pid), "Thread.print"])
        case .container(let name, _):
            // The JVM is often not pid 1 (a shell starts it), so ask jcmd for it.
            let script = #"p=$(jcmd -l 2>/dev/null | grep -v JCmd | head -1 | cut -d' ' -f1); [ -n "$p" ] || exit 3; jcmd "$p" Thread.print"#
            let probe = await Shell.run(["docker", "exec", name, "sh", "-c", script], in: root, timeout: .seconds(8), withoutMise: true)
            if probe.succeeded, probe.stdout.contains("java.lang.Thread.State") { return .success(["docker", "exec", name, "sh", "-c", script]) }
            return .failure(probe.status == 3 || probe.message.contains("not found") ? .noJcmdInContainer : .notJVM)
        }
    }

    /// Takes a thread dump about four times a second until cancelled.
    public static func profile(command: [String], root: URL, sink: @escaping @Sendable ([[StackFrame]]) -> Void) async {
        while !Task.isCancelled {
            let output = await Shell.run(command, in: root, trimming: false, timeout: .seconds(4), withoutMise: true)
            if output.succeeded { sink(ThreadDump.busyStacks(output.stdout)) }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }
}

public enum ProfileRefusal: Error, Equatable, Sendable {
    case notJVM, noJcmd, noJcmdInContainer

    public var explanation: String {
        switch self {
        case .notJVM: "The profiler reads JVM thread dumps, and this target isn’t a JVM. CPU and memory are still watched."
        case .noJcmd: "The profiler needs jcmd, which comes with a JDK; this JVM is a JRE without it."
        case .noJcmdInContainer: "The container runs a JRE without jcmd, so it can’t be profiled there. Run the app on this Mac (or from a JDK image) to profile it."
        }
    }
}
