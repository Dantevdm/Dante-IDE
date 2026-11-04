import Foundation

/// A mind map, stored as an XMind file (`.xmind`: a zip with `content.json`, or `content.xml`
/// from XMind 8 and older), so it opens in XMind and back. Dante edits titles, notes, labels,
/// links, folding and the tree; everything else XMind wrote (styles, markers, relationships,
/// images, the theme) is kept as it was.
public struct MindMap: Equatable, Sendable {
    public var sheets: [Sheet]
    /// The archive's other files (resources, thumbnail, metadata), written back unchanged.
    public var otherFiles: [String: Data] = [:]

    public static let fileExtension = "xmind"
    /// Where New puts them.
    public static let folder = "docs/mindmaps"

    public struct Sheet: Equatable, Sendable, Identifiable {
        public var id: String
        public var title: String
        public var root: Topic
        public var extra: [String: JSONValue] = [:]

        public init(id: String = MindMap.newID(), title: String, root: Topic, extra: [String: JSONValue] = [:]) {
            self.id = id
            self.title = title
            self.root = root
            self.extra = extra
        }
    }

    public struct Topic: Equatable, Sendable, Identifiable {
        public var id: String
        public var title: String
        public var notes: String?
        public var labels: [String]
        public var link: String?
        public var folded: Bool
        public var children: [Topic]
        /// Floating topics beside the tree (only the root has them in practice).
        public var floating: [Topic]
        public var extra: [String: JSONValue]

        public init(id: String = MindMap.newID(), title: String, notes: String? = nil, labels: [String] = [], link: String? = nil,
                    folded: Bool = false, children: [Topic] = [], floating: [Topic] = [], extra: [String: JSONValue] = [:]) {
            self.id = id
            self.title = title
            self.notes = notes
            self.labels = labels
            self.link = link
            self.folded = folded
            self.children = children
            self.floating = floating
            self.extra = extra
        }

        /// This topic and every one below it, depth first.
        public var all: [Topic] { [self] + children.flatMap(\.all) }
    }

    public init(sheets: [Sheet], otherFiles: [String: Data] = [:]) {
        self.sheets = sheets
        self.otherFiles = otherFiles
    }

    /// A new map with a central topic and nothing else.
    public init(title: String) {
        self.init(sheets: [Sheet(title: "Map 1", root: Topic(title: title, extra: ["structureClass": .string(Self.structure)]))])
    }

    /// "docs/mindmaps/shop-launch.xmind" reads "Shop launch".
    public static func title(ofPath path: String) -> String {
        let base = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let words = base.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    public static func isMindMap(_ path: String) -> Bool {
        (path as NSString).pathExtension.lowercased() == fileExtension
    }

    /// XMind's ids are 26 lower-case letters and digits; any unique string works.
    public static func newID() -> String {
        UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(26).description
    }

    static let structure = "org.xmind.ui.map.unbalanced"

    // MARK: Reading

    public enum Failure: Error, Equatable, LocalizedError {
        case unreadable(String)

        public var errorDescription: String? {
            switch self {
            case .unreadable(let why): "This mind map can't be read: \(why)."
            }
        }
    }

    public static func read(_ data: Data) throws -> MindMap {
        let files: [String: Data]
        do { files = try ZipArchive.read(data) } catch { throw Failure.unreadable("it isn't an XMind file") }
        var others = files
        let sheets: [Sheet]
        if let json = files["content.json"] {
            sheets = try parse(contentJSON: json)
            others["content.json"] = nil
            // XMind 2020+ also writes a content.xml telling old versions to upgrade.
            others["content.xml"] = nil
        } else if let xml = files["content.xml"] {
            sheets = try parse(contentXML: xml)
            others["content.xml"] = nil
        } else {
            throw Failure.unreadable("it has no content.json or content.xml")
        }
        guard !sheets.isEmpty else { throw Failure.unreadable("it has no sheets") }
        // These are written fresh.
        others["manifest.json"] = nil
        others["META-INF/manifest.xml"] = nil
        return MindMap(sheets: sheets, otherFiles: others)
    }

    static func parse(contentJSON data: Data) throws -> [Sheet] {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data), let array = value.array else {
            throw Failure.unreadable("its content.json isn't a list of sheets")
        }
        return array.compactMap { sheet -> Sheet? in
            guard var object = sheet.object, let root = object["rootTopic"].flatMap(topic(from:)) else { return nil }
            let id = object["id"]?.string ?? newID()
            let title = object["title"]?.string ?? "Map"
            for key in ["id", "class", "title", "rootTopic"] { object[key] = nil }
            return Sheet(id: id, title: title, root: root, extra: object)
        }
    }

    private static func topic(from value: JSONValue) -> Topic? {
        guard var object = value.object else { return nil }
        let children = object["children"]?.object
        var topic = Topic(
            id: object["id"]?.string ?? newID(),
            title: object["title"]?.string ?? "",
            notes: object["notes"]?["plain"]?["content"]?.string,
            labels: object["labels"]?.array?.compactMap(\.string) ?? [],
            link: object["href"]?.string,
            folded: object["branch"]?.string == "folded",
            children: children?["attached"]?.array?.compactMap(topic(from:)) ?? [],
            floating: children?["detached"]?.array?.compactMap(topic(from:)) ?? [])
        for key in ["id", "class", "title", "labels", "href", "branch"] { object[key] = nil }
        // Other child kinds (callouts, summaries) stay as they were.
        if var rest = children {
            rest["attached"] = nil
            rest["detached"] = nil
            object["children"] = rest.isEmpty ? nil : .object(rest)
        }
        // Rich notes (html) stay; the plain text is Dante's to edit.
        if var notes = object["notes"]?.object {
            notes["plain"] = nil
            object["notes"] = notes.isEmpty ? nil : .object(notes)
        }
        topic.extra = object
        return topic
    }

    /// XMind 8's XML: `<sheet><title/><topic><title/><children><topics type="attached">…`.
    static func parse(contentXML data: Data) throws -> [Sheet] {
        let reader = XMLTopicReader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        guard parser.parse() else { throw Failure.unreadable("its content.xml isn't valid XML") }
        return reader.sheets
    }

    // MARK: Writing

    public func data(date: Date = Date()) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let content = (try? encoder.encode(JSONValue.array(sheets.map(Self.json(of:))))) ?? Data("[]".utf8)
        var entries: [(path: String, data: Data)] = [("content.json", content)]
        var metadata = otherFiles["metadata.json"] ?? Data()
        if metadata.isEmpty {
            metadata = Data(#"{"creator":{"name":"Dante","version":"1"}}"#.utf8)
        }
        entries.append(("metadata.json", metadata))
        let kept = otherFiles.keys.filter { $0 != "metadata.json" }.sorted()
        for path in kept { entries.append((path, otherFiles[path]!)) }
        var manifest: [String: JSONValue] = [:]
        for entry in entries { manifest[entry.path] = .object([:]) }
        let manifestData = (try? encoder.encode(JSONValue.object(["file-entries": .object(manifest)]))) ?? Data()
        entries.append(("manifest.json", manifestData))
        return ZipArchive.write(entries, date: date)
    }

    static func json(of sheet: Sheet) -> JSONValue {
        var object = sheet.extra
        object["id"] = .string(sheet.id)
        object["class"] = .string("sheet")
        object["title"] = .string(sheet.title)
        object["rootTopic"] = json(of: sheet.root)
        return .object(object)
    }

    static func json(of topic: Topic) -> JSONValue {
        var object = topic.extra
        object["id"] = .string(topic.id)
        object["class"] = .string("topic")
        object["title"] = .string(topic.title)
        if !topic.labels.isEmpty { object["labels"] = .array(topic.labels.map(JSONValue.string)) }
        if let link = topic.link, !link.isEmpty { object["href"] = .string(link) }
        if topic.folded { object["branch"] = .string("folded") }
        if let notes = topic.notes, !notes.isEmpty {
            var all = object["notes"]?.object ?? [:]
            all["plain"] = .object(["content": .string(notes)])
            object["notes"] = .object(all)
        }
        var children = object["children"]?.object ?? [:]
        if !topic.children.isEmpty { children["attached"] = .array(topic.children.map(json(of:))) }
        if !topic.floating.isEmpty { children["detached"] = .array(topic.floating.map(json(of:))) }
        object["children"] = children.isEmpty ? nil : .object(children)
        return .object(object)
    }

    // MARK: Outlines

    /// The map as an indented markdown list under a heading, for agents and docs.
    public func outline(sheet index: Int = 0) -> String {
        guard sheets.indices.contains(index) else { return "" }
        let root = sheets[index].root
        var lines = ["# \(root.title)"]
        func walk(_ topic: Topic, depth: Int) {
            lines.append(String(repeating: "  ", count: depth) + "- " + topic.title.replacingOccurrences(of: "\n", with: " "))
            for child in topic.children { walk(child, depth: depth + 1) }
        }
        for child in root.children { walk(child, depth: 0) }
        return lines.joined(separator: "\n") + "\n"
    }

    /// A map from a markdown outline: the first heading (or first line) is the central topic,
    /// list items nest by indentation, and further headings become branches holding what
    /// follows them.
    public static func fromOutline(_ text: String, title fallback: String = "Central topic") -> MindMap {
        var rootTitle: String?
        var root: [Topic] = []
        // A stack of (indent, path of child indexes) for the list being read.
        var stack: [(indent: Int, path: [Int])] = []
        var headingPath: [Int]?
        func insert(_ topic: Topic, at path: [Int]) -> [Int] {
            func into(_ list: inout [Topic], _ rest: ArraySlice<Int>) -> [Int] {
                guard let first = rest.first else {
                    list.append(topic)
                    return [list.count - 1]
                }
                return [first] + into(&list[first].children, rest.dropFirst())
            }
            return into(&root, path[...])
        }
        for raw in text.components(separatedBy: .newlines) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if trimmed.hasPrefix("#") {
                let title = trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                guard !title.isEmpty else { continue }
                if rootTitle == nil { rootTitle = title; continue }
                headingPath = insert(Topic(title: title), at: [])
                stack = []
                continue
            }
            let indent = raw.prefix(while: { $0 == " " || $0 == "\t" }).reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
            var item = trimmed
            for marker in ["- ", "* ", "+ "] where item.hasPrefix(marker) { item = String(item.dropFirst(2)) }
            if let dot = item.firstIndex(of: "."), item[..<dot].allSatisfy(\.isNumber), !item[..<dot].isEmpty,
               item[item.index(after: dot)...].hasPrefix(" ") {
                item = String(item[item.index(dot, offsetBy: 2)...])
            }
            item = item.trimmingCharacters(in: .whitespaces)
            guard !item.isEmpty else { continue }
            if rootTitle == nil, root.isEmpty, stack.isEmpty, !trimmed.hasPrefix("-"), !trimmed.hasPrefix("*") {
                rootTitle = item
                continue
            }
            while let last = stack.last, last.indent >= indent { stack.removeLast() }
            let parent = stack.last?.path ?? headingPath ?? []
            let path = insert(Topic(title: item), at: parent)
            stack.append((indent, path))
        }
        var map = MindMap(title: rootTitle ?? fallback)
        map.sheets[0].root.children = root
        return map
    }

    /// A Mermaid `mindmap` of the first sheet, for markdown docs.
    public func mermaid(sheet index: Int = 0) -> String {
        guard sheets.indices.contains(index) else { return "" }
        func clean(_ title: String) -> String {
            title.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "(", with: "").replacingOccurrences(of: ")", with: "")
        }
        var lines = ["mindmap", "  root((\(clean(sheets[index].root.title))))"]
        func walk(_ topic: Topic, depth: Int) {
            lines.append(String(repeating: "  ", count: depth + 2) + clean(topic.title))
            for child in topic.children { walk(child, depth: depth + 1) }
        }
        for child in sheets[index].root.children { walk(child, depth: 0) }
        return lines.joined(separator: "\n") + "\n"
    }
}

// MARK: Editing

extension MindMap.Topic {
    /// The topic with this id, anywhere below (or this one).
    public func find(_ id: String) -> MindMap.Topic? {
        if self.id == id { return self }
        for child in children + floating { if let found = child.find(id) { return found } }
        return nil
    }

    /// The parent of the topic with this id.
    public func parent(of id: String) -> MindMap.Topic? {
        if children.contains(where: { $0.id == id }) || floating.contains(where: { $0.id == id }) { return self }
        for child in children + floating { if let found = child.parent(of: id) { return found } }
        return nil
    }

    /// Changes the topic with this id in place; false when it isn't here.
    @discardableResult
    public mutating func update(_ id: String, _ change: (inout MindMap.Topic) -> Void) -> Bool {
        if self.id == id { change(&self); return true }
        for index in children.indices where children[index].update(id, change) { return true }
        for index in floating.indices where floating[index].update(id, change) { return true }
        return false
    }

    /// Takes the topic with this id out of the tree (never the root itself).
    @discardableResult
    public mutating func remove(_ id: String) -> MindMap.Topic? {
        if let index = children.firstIndex(where: { $0.id == id }) { return children.remove(at: index) }
        if let index = floating.firstIndex(where: { $0.id == id }) { return floating.remove(at: index) }
        for index in children.indices { if let removed = children[index].remove(id) { return removed } }
        for index in floating.indices { if let removed = floating[index].remove(id) { return removed } }
        return nil
    }

    /// Adds a child at the end (or at `index`) of the topic with this id.
    @discardableResult
    public mutating func add(_ topic: MindMap.Topic, under id: String, at index: Int? = nil) -> Bool {
        update(id) { parent in
            parent.folded = false
            parent.children.insert(topic, at: min(index ?? parent.children.count, parent.children.count))
        }
    }

    /// Adds a sibling just after the topic with this id.
    @discardableResult
    public mutating func add(_ topic: MindMap.Topic, after id: String) -> Bool {
        guard let parent = parent(of: id), let index = parent.children.firstIndex(where: { $0.id == id }) else { return false }
        return add(topic, under: parent.id, at: index + 1)
    }

    /// Moves a topic one place up or down among its siblings.
    @discardableResult
    public mutating func move(_ id: String, by offset: Int) -> Bool {
        guard let parent = parent(of: id), let index = parent.children.firstIndex(where: { $0.id == id }) else { return false }
        let target = index + offset
        guard parent.children.indices.contains(target) else { return false }
        return update(parent.id) { $0.children.swapAt(index, target) }
    }

    /// Puts a topic under another (not under itself or its own branch).
    @discardableResult
    public mutating func reparent(_ id: String, under target: String) -> Bool {
        guard id != self.id, let moving = find(id), moving.find(target) == nil, find(target) != nil else { return false }
        remove(id)
        return add(moving, under: target)
    }
}

/// Reads XMind 8's content.xml: sheets, topics, titles, notes, labels, links and folding.
private final class XMLTopicReader: NSObject, XMLParserDelegate {
    var sheets: [MindMap.Sheet] = []
    private var stack: [MindMap.Topic] = []
    private var sheetTitle: String?
    private var sheetID: String?
    private var sheetRoot: MindMap.Topic?
    private var text = ""
    private var inNotes = false
    private var inLabel = false
    private var topicsType: [String] = []

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        text = ""
        switch name {
        case "sheet":
            sheetID = attributes["id"]
            sheetTitle = nil
            sheetRoot = nil
        case "topic":
            var topic = MindMap.Topic(id: attributes["id"] ?? MindMap.newID(), title: "")
            topic.link = attributes["xlink:href"]
            topic.folded = attributes["branch"] == "folded"
            stack.append(topic)
        case "topics": topicsType.append(attributes["type"] ?? "attached")
        case "notes": inNotes = true
        case "label": inLabel = true
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "title" where !inNotes:
            if stack.isEmpty { sheetTitle = value } else if stack[stack.count - 1].title.isEmpty { stack[stack.count - 1].title = value }
        case "plain" where inNotes:
            if !stack.isEmpty { stack[stack.count - 1].notes = value }
        case "notes": inNotes = false
        case "label":
            if inLabel, !stack.isEmpty, !value.isEmpty { stack[stack.count - 1].labels.append(value) }
            inLabel = false
        case "topics": _ = topicsType.popLast()
        case "sheet":
            if let root = sheetRoot {
                sheets.append(MindMap.Sheet(id: sheetID ?? MindMap.newID(), title: sheetTitle ?? "Map \(sheets.count + 1)", root: root))
            }
        case "topic":
            guard let topic = stack.popLast() else { break }
            if stack.isEmpty {
                sheetRoot = topic
            } else if topicsType.last == "detached" {
                stack[stack.count - 1].floating.append(topic)
            } else {
                stack[stack.count - 1].children.append(topic)
            }
        default: break
        }
        text = ""
    }
}

/// What the agent is asked when it drafts or adds to a mind map. It works on an outline and
/// lets `dante mindmap` write the XMind file, rather than editing the zip itself.
public enum MindMapBrief {
    /// How to read and write a map with `command` (the `dante` inside this copy of Dante).
    public static func howTo(command: String) -> String {
        let dante = Shell.quote(command)
        return """
        A mind map is an XMind file (.xmind, a zip). Don't edit it directly: read it with `\(dante) mindmap outline <file>` and \
        write it with `\(dante) mindmap write <file> <outline.md>` (or `-` to read the outline from stdin), where the outline is \
        markdown: `# Central topic`, then `-` list items nested by two spaces (`##` headings also make main branches). Writing \
        keeps the map's other sheets, and the notes and XMind styling of topics whose titles stay the same. Keep titles short \
        (a few words) and put detail in deeper topics. Dante shows the map as soon as the file changes.
        """
    }

    public static func draft(path: String, title: String, about: String, command: String) -> String {
        var text = "Draft the mind map \(path) (\"\(title)\") from what you can find in the project: its code, configuration, docs and git history."
        let topic = about.trimmingCharacters(in: .whitespacesAndNewlines)
        if !topic.isEmpty { text += " It's about: \(topic)" }
        return text + " Aim for four to seven main branches, each a few levels deep.\n\n" + howTo(command: command)
    }

    public static func extend(path: String, outline: String, command: String) -> String {
        "Look at the mind map \(path) and tell me what's missing or could be clearer, then offer to add it. It reads:\n\n\(outline)\n" + howTo(command: command)
    }
}

extension MindMap {
    /// The map with the outline's tree in place of the first sheet's. Topics whose title
    /// matches one at the same place keep their id, notes and XMind styling.
    public func replacingTree(with outline: MindMap, sheet index: Int = 0) -> MindMap {
        guard sheets.indices.contains(index), let fresh = outline.sheets.first?.root else { return self }
        func merge(_ new: Topic, into old: Topic?) -> Topic {
            var topic = new
            if let old, old.title == new.title {
                topic.id = old.id
                topic.notes = old.notes
                topic.labels = old.labels
                topic.link = old.link
                topic.extra = old.extra
                topic.floating = old.floating
            }
            topic.children = new.children.map { child in merge(child, into: old?.children.first { $0.title == child.title }) }
            return topic
        }
        var copy = self
        var root = merge(fresh, into: sheets[index].root)
        if root.id != sheets[index].root.id {
            // A new central title keeps the old root's look.
            root.id = sheets[index].root.id
            root.extra = sheets[index].root.extra
            root.floating = sheets[index].root.floating
        }
        copy.sheets[index].root = root
        return copy
    }
}
