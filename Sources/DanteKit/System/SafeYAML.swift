import Foundation
import Yams

/// `Yams.load` for files Dante doesn't control (project.yaml, compose files, job types,
/// templates). Yams force-unwraps every mapping key as a string, so a list or map used as a
/// key (`[a]: b`, `? {x: y}`) traps the whole app; such YAML is read as invalid instead.
public enum SafeYAML {
    public static func load(_ yaml: String) throws -> Any? {
        guard let node = try Yams.compose(yaml: yaml) else { return nil }
        guard keysAreScalars(node) else { throw Invalid() }
        return try Yams.load(yaml: yaml)
    }

    public struct Invalid: LocalizedError {
        public var errorDescription: String? { "Only plain text can be a key in this YAML." }
    }

    static func keysAreScalars(_ node: Node) -> Bool {
        switch node {
        case .scalar: return true
        case .mapping(let mapping): return mapping.allSatisfy { key, value in key.scalar != nil && keysAreScalars(value) }
        case .sequence(let sequence): return sequence.allSatisfy(keysAreScalars)
        case .alias: return true
        }
    }
}
