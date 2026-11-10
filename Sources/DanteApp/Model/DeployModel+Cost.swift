import DanteKit
import Foundation

/// The cost guard: the team's bill so far this month, a monthly budget, and a limit on how much
/// one deploy may raise the app's price before it has to be acknowledged. Both settings are this
/// Mac's (user defaults), not the repository's.
extension DeployModel {
    private static let budgetKey = "deploy.monthlyBudget"
    private static let raiseKey = "deploy.maxRaise"

    /// The monthly budget in dollars; nil for none.
    var budget: Double? {
        get { _ = spendingChanged; return UserDefaults.standard.object(forKey: Self.budgetKey) as? Double }
        set { UserDefaults.standard.set(newValue.flatMap { $0 > 0 ? $0 : nil }, forKey: Self.budgetKey); spendingChanged += 1 }
    }

    /// The most a deploy may add to the app's monthly price without asking; nil for no limit.
    var maxRaise: Double? {
        get { _ = spendingChanged; return UserDefaults.standard.object(forKey: Self.raiseKey) as? Double }
        set { UserDefaults.standard.set(newValue.flatMap { $0 >= 0 ? $0 : nil }, forKey: Self.raiseKey); spendingChanged += 1 }
    }

    /// The live app's monthly price from its sizes.
    var liveMonthly: Double? { app.flatMap { Self.estimate($0.spec, sizes: sizes) } }

    /// Said before deploying when the change raises the price past `maxRaise`. Estimates on both
    /// sides, so the sizes list's rounding doesn't read as a raise.
    var costWarning: String? {
        CostGuard.warning(current: app == nil ? nil : liveMonthly, new: estimate ?? proposal?.appCost, limit: maxRaise)
    }

    /// The month's bill so far, at most every ten minutes.
    func loadSpending(force: Bool = false) async {
        guard signedIn, !isDemoMode else { return }
        if !force, let loaded = spendingLoaded, loaded > .now.addingTimeInterval(-600) { return }
        do throws(DOClient.Failure) {
            monthToDate = try await client.monthToDate()
            spendingProblem = nil
        } catch {
            spendingProblem = error.status == 403 || error.status == 401
                ? "This sign-in can’t read the bill (billing:read). Sign in again to allow it."
                : DOClient.explain(error.message)
        }
        spendingLoaded = .now
    }
}
