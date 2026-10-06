import Foundation

/// One file's diagnostics, for the Problems panel.
public struct ProblemFile: Equatable, Sendable, Identifiable {
    public var url: URL
    /// Relative to the project root.
    public var path: String
    public var diagnostics: [LSPDiagnostic]

    public var id: String { path }
    public var errors: Int { diagnostics.count { $0.severity == .error } }
    public var warnings: Int { diagnostics.count { $0.severity == .warning } }
}

/// Every language server's diagnostics in the project, grouped by file: files with errors
/// first, then by path. Files outside the project (and in `.build`) are left out.
public enum Problems {
    public static func files(_ byPath: [String: [LSPDiagnostic]], root: URL, includeHints: Bool = false) -> [ProblemFile] {
        let prefix = root.standardizedFileURL.path + "/"
        let files = byPath.compactMap { path, diagnostics -> ProblemFile? in
            guard path.hasPrefix(prefix) else { return nil }
            let relative = String(path.dropFirst(prefix.count))
            guard !relative.hasPrefix(".build/"), !relative.hasPrefix("node_modules/") else { return nil }
            let kept = includeHints ? diagnostics : diagnostics.filter { $0.severity <= .warning }
            guard !kept.isEmpty else { return nil }
            return ProblemFile(url: URL(filePath: path), path: relative, diagnostics: kept)
        }
        return files.sorted { a, b in
            if (a.errors > 0) != (b.errors > 0) { return a.errors > 0 }
            return a.path.localizedStandardCompare(b.path) == .orderedAscending
        }
    }
}
