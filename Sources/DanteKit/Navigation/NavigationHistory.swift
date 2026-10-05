import Foundation

/// Back and forward through the places a window has shown, like a browser's history.
public struct NavigationHistory<Place: Equatable & Sendable>: Equatable, Sendable {
    public private(set) var back: [Place] = []
    public private(set) var forward: [Place] = []
    public static var limit: Int { 50 }

    public init() {}

    public var canGoBack: Bool { !back.isEmpty }
    public var canGoForward: Bool { !forward.isEmpty }

    /// The user moved from `previous` somewhere new: remember it, and drop the forward trail.
    public mutating func moved(from previous: Place) {
        guard back.last != previous else { return }
        back.append(previous)
        if back.count > Self.limit { back.removeFirst(back.count - Self.limit) }
        forward = []
    }

    /// The place to go back to from `current`, if any.
    public mutating func goBack(from current: Place) -> Place? {
        guard let place = back.popLast() else { return nil }
        forward.append(current)
        return place
    }

    public mutating func goForward(from current: Place) -> Place? {
        guard let place = forward.popLast() else { return nil }
        back.append(current)
        return place
    }

    /// Forgets places that no longer exist, such as files that were deleted.
    public mutating func removeAll(where shouldRemove: (Place) -> Bool) {
        back.removeAll(where: shouldRemove)
        forward.removeAll(where: shouldRemove)
    }
}
