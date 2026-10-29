import Foundation

/// What to keep from a run that failed outside its tests. The reason is rarely at the end:
/// `go test ./...` prints a package's compile errors first and only a bare FAIL last, so the
/// lines that name the failure are picked from the whole output, then the end is added.
public enum BrokenRunLines {
    /// Lines that explain the failure, each with the line after it, and the last `ending`
    /// lines; "…" marks what was left out between them.
    public static func pick(_ output: [String], ending: Int = 12, limit: Int = 40) -> [String] {
        let lines = output.map { $0.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\t", with: "  ") }
        var keep = IndexSet()
        for (index, line) in lines.enumerated() where explains(line) {
            keep.insert(index)
            if index + 1 < lines.count, !passing(lines[index + 1]) { keep.insert(index + 1) }
            if keep.count >= limit { break }
        }
        let nonEmpty = lines.indices.filter { !lines[$0].trimmingCharacters(in: .whitespaces).isEmpty }
        keep.formUnion(IndexSet(nonEmpty.suffix(ending)))
        var picked: [String] = []
        var last: Int?
        for index in keep {
            if let last, index > last + 1 { picked.append("…") }
            picked.append(lines[index])
            last = index
        }
        return picked
    }

    /// What went wrong in a sentence, when the lines say.
    public static func reason(in lines: [String]) -> String? {
        let failed = lines.compactMap(failedPackage)
        if let build = failed.first(where: { $0.why == "build failed" }) {
            return failed.count == 1 ? "\(build.name) didn’t build" : "\(failed.count) packages failed, \(build.name) didn’t build"
        }
        if let setup = failed.first(where: { $0.why == "setup failed" }) { return "\(setup.name) failed to set up" }
        if lines.contains(where: { $0.hasPrefix("panic:") }) { return "A test panicked, so its package stopped" }
        if lines.contains(where: { $0.contains("ModuleNotFoundError") || $0.contains("Cannot find module") || $0.contains("cannot find package") }) {
            return "Something the tests import is missing"
        }
        if lines.contains(where: { $0.contains("COMPILATION ERROR") || $0.contains("Compilation failed") }) { return "The code didn’t compile" }
        if lines.contains(where: { $0.contains("BUILD FAILURE") || $0.contains("BUILD FAILED") }) { return "The build failed" }
        if lines.contains(where: { $0.contains("error:") || $0.contains(".go:") && $0.contains(": ") }) { return "The code didn’t compile" }
        return nil
    }

    public static func explains(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !passing(trimmed) else { return false }
        if trimmed.hasPrefix("# ") || trimmed.hasPrefix("panic:") || trimmed.hasPrefix("Traceback") { return true }
        if failedPackage(trimmed) != nil { return true }
        if goPosition.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) != nil { return true }
        return markers.contains { trimmed.contains($0) }
    }

    private static let markers = ["error:", "Error:", "ERROR", "npm ERR!", "ModuleNotFoundError", "ImportError", "SyntaxError",
                                  "Cannot find module", "cannot find package", "fatal:", "BUILD FAILURE", "BUILD FAILED",
                                  "COMPILATION ERROR", "[setup failed]", "[build failed]"]
    /// `./orders.go:12:5: undefined: Order`
    private static let goPosition = try! NSRegularExpression(pattern: "^\\S+\\.go:\\d+(:\\d+)?: ")

    private static func passing(_ line: String) -> Bool {
        line.hasPrefix("ok ") || line.hasPrefix("ok\t") || line.hasPrefix("--- PASS") || line.hasPrefix("=== RUN") || line == "PASS"
    }

    /// `FAIL	example.com/shop/orders [build failed]`: the package and why.
    private static func failedPackage(_ line: String) -> (name: String, why: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("FAIL"), let open = trimmed.lastIndex(of: "["), trimmed.hasSuffix("]") else { return nil }
        let name = trimmed.dropFirst(4).prefix(upTo: open).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        return (name.components(separatedBy: "/").suffix(2).joined(separator: "/"), String(trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)]))
    }
}
