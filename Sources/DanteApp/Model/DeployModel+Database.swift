import DanteKit
import Foundation

/// The live app's databases. Nothing here connects to a database from this Mac: DigitalOcean's
/// firewall lets only the app into a dev database, so the card describes them, and a managed
/// cluster's daily backups, restoring one to a new cluster and resizing go through the API.
extension DeployModel {
    var liveDatabases: [DOAppSpec.Database] { app?.spec?.databases ?? [] }

    func cluster(for database: DOAppSpec.Database) -> DODatabaseCluster? {
        guard let name = database.clusterName else { return nil }
        return clusters.first { $0.name == name }
    }

    /// The managed clusters and their daily backups.
    func loadDatabases() async {
        let databases = liveDatabases
        guard databases.contains(where: { $0.clusterName != nil }), signedIn, !isDemoMode else { return }
        if let found = try? await client.databaseClusters() { clusters = found }
        for database in databases {
            guard let cluster = cluster(for: database) else { continue }
            if let backups = try? await client.databaseBackups(cluster.id) { clusterBackups[cluster.id] = backups }
        }
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
            } catch let failure as DOClient.Failure {
                databaseProblem = DOSignIn.explain(failure.message)
            } catch {
                databaseProblem = error.localizedDescription
            }
            await loadDatabases()
        }
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

    /// Opens the wizard on the variables alone: change a value, or give a secret a new one, and
    /// deploy without going through the other steps.
    func openVariables() {
        openWizard()
        guard wizardStep != nil else { return }
        editingVariables = true
        wizardStep = .variables
    }

    /// Opens the wizard on the database step, to move the app to another cluster.
    func openDatabaseStep() {
        openWizard()
        if wizardStep != nil { wizardStep = .data }
    }
}
