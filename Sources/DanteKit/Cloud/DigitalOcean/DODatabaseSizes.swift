import Foundation

/// A managed cluster's daily backup.
public struct DODatabaseBackup: Decodable, Equatable, Sendable, Identifiable {
    public var createdAt: String
    public var sizeGigabytes: Double?
    public var id: String { createdAt }

    public init(createdAt: String, sizeGigabytes: Double?) {
        self.createdAt = createdAt
        self.sizeGigabytes = sizeGigabytes
    }

    public var date: Date? { DOJSON.date(createdAt) }
}

/// Managed database sizes and their list prices (DigitalOcean doesn't give prices through the
/// API): a node a month, before standby nodes, which cost the same here as a rough guide.
public enum DODatabaseSizes {
    public static let pg: [(slug: String, title: String, monthly: Double)] = [
        ("db-s-1vcpu-1gb", "1 vCPU · 1 GB", 15), ("db-s-1vcpu-2gb", "1 vCPU · 2 GB", 30), ("db-s-2vcpu-4gb", "2 vCPU · 4 GB", 60),
        ("db-s-4vcpu-8gb", "4 vCPU · 8 GB", 120), ("db-s-6vcpu-16gb", "6 vCPU · 16 GB", 240), ("db-s-8vcpu-32gb", "8 vCPU · 32 GB", 480),
        ("db-s-16vcpu-64gb", "16 vCPU · 64 GB", 960),
    ]

    public static func title(_ slug: String?) -> String? { pg.first { $0.slug == slug }?.title ?? slug }

    public static func monthly(_ slug: String?, nodes: Int = 1) -> Double? {
        pg.first { $0.slug == slug }.map { $0.monthly * Double(max(1, nodes)) }
    }

    /// A restored cluster's name: the original's with the backup's day, cut to DigitalOcean's limit.
    public static func restoredName(_ name: String, backup: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMdd-HHmm"
        return String((name + "-restored-" + formatter.string(from: backup)).prefix(63))
    }
}
