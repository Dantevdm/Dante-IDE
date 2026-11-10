import AppKit
import DanteKit
import Foundation

/// The live app's databases: backups made here (pg_dump over the connection the app itself is
/// given, read through its console), restoring one, starting fresh, and for a managed cluster
/// its daily backups, restoring one to a new cluster and resizing it. Everything that changes a
/// database backs it up first; everything that costs money is confirmed in the view.
extension DeployModel {
    var liveDatabases: [DOAppSpec.Database] { app?.spec?.databases ?? [] }

    func cluster(for database: DOAppSpec.Database) -> DODatabaseCluster? {
        guard let name = database.clusterName else { return nil }
        return clusters.first { $0.name == name }
    }

    /// Clusters, their backups and the backups on this Mac.
    func loadDatabases() async {
        guard let app else { return }
        let databases = liveDatabases
        guard !databases.isEmpty else { return }
        if databases.contains(where: { $0.clusterName != nil }), signedIn {
            if let found = try? await client.databaseClusters() { clusters = found }
            for database in databases {
                guard let cluster = cluster(for: database) else { continue }
                if let backups = try? await client.databaseBackups(cluster.id) { clusterBackups[cluster.id] = backups }
            }
        }
        let folder = PGTools.backupFolder(app: app.name)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for database in databases {
            localBackups[database.name] = files.filter { $0.lastPathComponent.hasPrefix(database.name + "-") && $0.pathExtension == "dump" }
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
        }
    }

    /// Asks the running app how it reaches `database`, through its console.
    private func connection(for database: DOAppSpec.Database) async throws -> PGConnection {
        guard let app, let spec = app.spec else { throw DOConsoleExec.Failure(message: "The app isn’t loaded.") }
        guard app.active != nil else { throw DOConsoleExec.Failure(message: "The app isn’t running, so Dante can’t ask it how to reach the database.") }
        guard let plan = DODatabaseAccess.plan(spec: spec, database: database.name) else {
            throw DOConsoleExec.Failure(message: "No running part of the app is given \(database.name)’s address. Bind DATABASE_URL to ${\(database.name).DATABASE_URL} in a service (Deploy again › Variables), deploy, and try again.")
        }
        let url: URL
        do { url = try await client.consoleURL(app.id, component: plan.component) } catch {
            throw DOConsoleExec.Failure(message: error.status == 403 ? "This sign-in can’t open the app’s console (app:access_console). Sign out and sign in again to allow it." : error.message)
        }
        let output = try await DOConsoleExec.run(url, line: DODatabaseAccess.script(for: plan))
        guard let values = DODatabaseAccess.values(in: output), let connection = DODatabaseAccess.connection(values, plan: plan) else {
            throw DOConsoleExec.Failure(message: "\(plan.component) didn’t say how it reaches \(database.name).")
        }
        return connection
    }

    private func tool(_ name: String) throws -> String {
        guard let path = PGTools.locate(name) else {
            throw DOConsoleExec.Failure(message: "\(name) isn’t on this Mac. Install it with “\(PGTools.installCommand)” in a terminal, then try again.")
        }
        return path
    }

    /// Runs `body` as the one database job, saying what it's doing and how it went.
    private func work(_ title: String, _ body: @escaping @MainActor () async throws -> String) {
        guard databaseWork == nil else { return }
        databaseWork = title
        databaseProblem = nil
        databaseNotice = nil
        Task {
            defer { databaseWork = nil }
            do {
                databaseNotice = try await body()
            } catch let failure as DOConsoleExec.Failure {
                databaseProblem = failure.message
            } catch let failure as DOClient.Failure {
                databaseProblem = DOSignIn.explain(failure.message)
            } catch {
                databaseProblem = error.localizedDescription
            }
            await loadDatabases()
        }
    }

    /// pg_dump into Application Support/Dante/backups/<app>; returns the file.
    private func dump(_ database: DOAppSpec.Database, _ connection: PGConnection, note: String?) async throws -> URL {
        guard let app else { throw DOConsoleExec.Failure(message: "The app isn’t loaded.") }
        let pgDump = try tool("pg_dump")
        let folder = PGTools.backupFolder(app: app.name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: PGTools.backupName(database: database.name, date: .now, note: note))
        let result = await Shell.run([pgDump] + PGTools.dumpArguments(connection, to: file), in: folder, extra: connection.environment, timeout: .seconds(1800), withoutMise: true)
        guard result.succeeded else {
            try? FileManager.default.removeItem(at: file)
            throw DOConsoleExec.Failure(message: PGTools.explain(result.message))
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return file
    }

    func backUp(_ database: DOAppSpec.Database) {
        work("Backing up \(database.name)…") { [self] in
            let file = try await dump(database, try await connection(for: database), note: nil)
            let size = ByteCountFormatter.string(fromByteCount: Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0), countStyle: .file)
            return "Backed up \(database.name) (\(size)) to this Mac."
        }
    }

    /// Puts a backup back, after backing up what's there now.
    func restore(_ database: DOAppSpec.Database, from file: URL) {
        work("Restoring \(database.name)…") { [self] in
            let connection = try await connection(for: database)
            let pgRestore = try tool("pg_restore")
            _ = try await dump(database, connection, note: "before-restore")
            let result = await Shell.run([pgRestore] + PGTools.restoreArguments(connection, from: file), in: file.deletingLastPathComponent(),
                                         extra: connection.environment, timeout: .seconds(1800), withoutMise: true)
            guard result.succeeded else { throw DOConsoleExec.Failure(message: PGTools.explain(result.message) + " Nothing was changed.") }
            return "Restored \(database.name) from \(file.lastPathComponent). What was there is backed up too."
        }
    }

    /// Empties the database (after backing it up) so the next deploy's migrations start over.
    func startFresh(_ database: DOAppSpec.Database) {
        work("Emptying \(database.name)…") { [self] in
            let connection = try await connection(for: database)
            let psql = try tool("psql")
            _ = try await dump(database, connection, note: "before-fresh")
            let result = await Shell.run([psql] + PGTools.freshArguments(connection), in: PGTools.backupFolder(app: app?.name ?? "app"),
                                         extra: connection.environment, timeout: .seconds(300), withoutMise: true)
            guard result.succeeded else { throw DOConsoleExec.Failure(message: PGTools.explain(result.message)) }
            return "\(database.name) is empty; a backup of what was there is on this Mac. Deploy again so the migrations make the tables."
        }
    }

    /// Adds the database to Data (read-only, password in the Keychain) and opens it there.
    func explore(_ database: DOAppSpec.Database, session: Session) {
        guard let app else { return }
        work("Connecting to \(database.name)…") { [self] in
            let found = try await connection(for: database)
            var connection = DatabaseConnection(name: "\(database.name) on DigitalOcean", engine: .postgres, host: found.host, port: found.port,
                                                database: found.database, user: found.user, readOnly: true, origin: .saved)
            connection.cloud = .init(provider: "DigitalOcean", app: app.name, appID: app.id,
                                     kind: database.clusterName.map { "managed cluster \($0)" } ?? "dev database", region: app.region)
            session.data.save(connection, password: found.password)
            session.area = .data
            return "\(database.name) is in Data, read-only."
        }
    }

    /// The Data connection for a database, once explored.
    func dataConnection(for database: DOAppSpec.Database, in data: DataModel) -> DatabaseConnection? {
        data.connections.first { $0.cloud?.appID == app?.id && $0.name == "\(database.name) on DigitalOcean" }
    }

    func revealBackups() {
        guard let app else { return }
        let folder = PGTools.backupFolder(app: app.name)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    /// A new cluster from a daily backup; the app keeps using the old one until it's switched.
    func restoreCluster(_ cluster: DODatabaseCluster, backup: DODatabaseBackup) {
        work("Making a cluster from the backup…") { [self] in
            let name = DODatabaseSizes.restoredName(cluster.name, backup: backup.date ?? .now)
            let made = try await client.restoreDatabase(cluster, backup: backup, name: name)
            clusters.append(made)
            return "DigitalOcean is making \(made.name) from the backup (it takes a few minutes). The app still uses \(cluster.name); switch it in Deploy again › Database once it’s online."
        }
    }

    func resizeCluster(_ cluster: DODatabaseCluster, size: String) {
        work("Resizing \(cluster.name)…") { [self] in
            try await client.resizeDatabase(cluster.id, size: size, nodes: cluster.numNodes ?? 1)
            return "DigitalOcean is moving \(cluster.name) to \(DODatabaseSizes.title(size) ?? size); it stays up apart from a short blip."
        }
    }

    /// Opens the wizard on one component's size, then straight to pricing and review.
    func openResize(_ component: String) {
        openWizard()
        guard wizardStep != nil else { return }
        resizing = component
        wizardStep = .parts
    }

    /// Opens the wizard on the database step, to move the app to another cluster.
    func openDatabaseStep() {
        openWizard()
        if wizardStep != nil { wizardStep = .data }
    }
}
