import Darwin
import Foundation
import Security

/// Connections added by hand or by the wizard. They're kept on this Mac, per project,
/// not in the repo, so hosts and user names don't end up in commits.
public struct ConnectionStore: Sendable {
    public var file: URL

    public init(file: URL = ConnectionStore.defaultFile) {
        self.file = file
    }

    public static var defaultFile: URL {
        URL.applicationSupportDirectory.appending(path: "Dante/connections.json")
    }

    public func connections(for project: URL) -> [DatabaseConnection] {
        all()[project.standardizedFileURL.path] ?? []
    }

    public func save(_ connection: DatabaseConnection, for project: URL) throws {
        var store = all()
        var list = store[project.standardizedFileURL.path] ?? []
        var saved = connection
        saved.origin = .saved
        if let index = list.firstIndex(where: { $0.id == connection.id }) { list[index] = saved } else { list.append(saved) }
        store[project.standardizedFileURL.path] = list
        try write(store)
    }

    public func remove(_ id: String, for project: URL) throws {
        var store = all()
        store[project.standardizedFileURL.path]?.removeAll { $0.id == id }
        try write(store)
    }

    private func all() -> [String: [DatabaseConnection]] {
        guard let data = try? Data(contentsOf: file) else { return [:] }
        return (try? JSONDecoder().decode([String: [DatabaseConnection]].self, from: data)) ?? [:]
    }

    private func write(_ store: [String: [DatabaseConnection]]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(store).write(to: file, options: .atomic)
    }
}

/// Database passwords, in the login Keychain.
public enum DatabasePasswords {
    static let service = "dev.dante.ide.database"

    static func account(_ connection: DatabaseConnection, project: URL) -> String {
        "\(project.standardizedFileURL.path)|\(connection.id)"
    }

    public static func password(for connection: DatabaseConnection, project: URL) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account(connection, project: project),
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    public static func set(_ password: String?, for connection: DatabaseConnection, project: URL) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account(connection, project: project),
        ]
        SecItemDelete(base as CFDictionary)
        guard let password, !password.isEmpty else { return true }
        var item = base
        item[kSecValueData as String] = Data(password.utf8)
        item[kSecAttrLabel as String] = "Dante: \(connection.name)"
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }
}

/// Local TCP ports, for picking one the new database can publish on.
public enum PortProbe {
    public static func isFree(_ port: Int) -> Bool {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { return false }
        defer { close(socket) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        return result == 0
    }

    public static func firstFree(from port: Int, skipping taken: Set<Int> = []) -> Int {
        var candidate = port
        while candidate < port + 100, taken.contains(candidate) || !isFree(candidate) { candidate += 1 }
        return candidate
    }
}
