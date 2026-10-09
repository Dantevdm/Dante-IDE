import Foundation

/// The explorer's selected rows, with Finder's click rules: a plain click selects one,
/// ⌘-click adds or removes, ⇧-click selects the run of visible rows from the anchor.
public struct ExplorerSelection: Equatable, Sendable {
    public enum Click: Sendable {
        case plain, toggle, range
    }

    /// In the order they were selected.
    public private(set) var items: [URL] = []
    /// The row a ⇧-click range starts from, and where new files go.
    public private(set) var anchor: URL?

    public init() {}

    public var count: Int { items.count }
    public var isEmpty: Bool { items.isEmpty }

    public func contains(_ url: URL) -> Bool {
        items.contains { Self.same($0, url) }
    }

    /// `visible` is the tree's rows top to bottom, for ranges.
    public mutating func click(_ url: URL, _ click: Click, visible: [URL]) {
        switch click {
        case .plain:
            items = [url]
            anchor = url
        case .toggle:
            if contains(url) {
                items.removeAll { Self.same($0, url) }
                if anchor.map({ Self.same($0, url) }) == true { anchor = items.last }
            } else {
                items.append(url)
                anchor = url
            }
        case .range:
            guard let anchor, let start = visible.firstIndex(where: { Self.same($0, anchor) }),
                  let end = visible.firstIndex(where: { Self.same($0, url) }) else {
                items = [url]
                self.anchor = url
                return
            }
            items = Array(visible[min(start, end)...max(start, end)])
        }
    }

    public mutating func select(_ urls: [URL]) {
        items = urls
        anchor = urls.last
    }

    public mutating func clear() {
        items = []
        anchor = nil
    }

    /// Drops rows whose folder is also selected, so a folder and a file in it act once.
    public var topLevel: [URL] {
        items.filter { item in
            !items.contains { other in
                !Self.same(other, item) && item.standardizedFileURL.path.hasPrefix(other.standardizedFileURL.path + "/")
            }
        }
    }

    /// Keeps the selection pointing at moved or renamed items, and drops removed ones.
    public mutating func update(exists: (URL) -> Bool) {
        items = items.filter(exists)
        if let anchor, !exists(anchor) { self.anchor = items.last }
    }

    static func same(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL.path == b.standardizedFileURL.path
    }
}

extension FileOperations {
    /// A path URL for one Finder may hand over as a file reference (`file:///.file/id=…`),
    /// which has neither the real name nor the real folder.
    public static func resolved(_ url: URL) -> URL {
        guard url.isFileURL else { return url }
        return ((url as NSURL).filePathURL ?? url).standardizedFileURL
    }
}
