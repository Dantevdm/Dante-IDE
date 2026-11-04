import CoreGraphics
import Foundation
import Testing
@testable import DanteKit

struct MindMapTests {
    @Test func zipRoundTrips() throws {
        let long = Data(String(repeating: "orders and refunds ", count: 400).utf8)
        let archive = ZipArchive.write([("a.txt", Data("hello".utf8)), ("folder/b.json", long), ("empty", Data())])
        let files = try ZipArchive.read(archive)
        #expect(files["a.txt"] == Data("hello".utf8))
        #expect(files["folder/b.json"] == long)
        #expect(files["empty"] == Data())
        #expect(archive.count < long.count) // the long one was deflated
        #expect(ZipArchive.crc32(Data("123456789".utf8)) == 0xCBF4_3926)
        #expect(throws: ZipArchive.Failure.self) { try ZipArchive.read(Data("not a zip".utf8)) }
    }

    /// Shaped like XMind 2020's content.json, with a style, a marker and a relationship Dante
    /// doesn't edit.
    static let content = """
    [{"id":"s1","class":"sheet","title":"Shop","theme":{"id":"t"},"relationships":[{"id":"r1","end1Id":"a","end2Id":"b"}],
      "rootTopic":{"id":"root","class":"topic","title":"Shop launch","structureClass":"org.xmind.ui.map.unbalanced",
        "children":{"attached":[
          {"id":"a","title":"Orders","markers":[{"markerId":"priority-1"}],"notes":{"plain":{"content":"Ana owns it"}},
           "children":{"attached":[{"id":"a1","title":"Refunds","labels":["later"]}]}},
          {"id":"b","title":"Delivery","branch":"folded","href":"https://example.test/delivery",
           "children":{"attached":[{"id":"b1","title":"Couriers"}]}}],
          "detached":[{"id":"f","title":"Ideas"}]}}}]
    """

    static func sample() throws -> MindMap {
        let archive = ZipArchive.write([("content.json", Data(content.utf8)), ("metadata.json", Data("{}".utf8)),
                                        ("resources/logo.png", Data([1, 2, 3]))])
        return try MindMap.read(archive)
    }

    @Test func readsXMind() throws {
        let map = try Self.sample()
        let root = map.sheets[0].root
        #expect(map.sheets[0].title == "Shop")
        #expect(root.title == "Shop launch")
        #expect(root.children.map(\.title) == ["Orders", "Delivery"])
        #expect(root.children[0].notes == "Ana owns it")
        #expect(root.children[0].children[0].labels == ["later"])
        #expect(root.children[1].folded)
        #expect(root.children[1].link == "https://example.test/delivery")
        #expect(root.floating.map(\.title) == ["Ideas"])
        #expect(map.otherFiles["resources/logo.png"] == Data([1, 2, 3]))
    }

    @Test func writesWhatItReadAndKeepsTheRest() throws {
        var map = try Self.sample()
        map.sheets[0].root.update("a1") { $0.title = "Refunds and returns" }
        let again = try MindMap.read(map.data())
        #expect(again.sheets == map.sheets)
        #expect(again.otherFiles["resources/logo.png"] == Data([1, 2, 3]))
        let files = try ZipArchive.read(map.data())
        let json = try #require(files["content.json"].flatMap { String(data: $0, encoding: .utf8) })
        #expect(json.contains("priority-1"))
        #expect(json.contains("relationships"))
        #expect(json.contains("Refunds and returns"))
        #expect(files["manifest.json"] != nil)
    }

    @Test func readsXMind8() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <xmap-content xmlns="urn:xmind:xmap:xmlns:content:2.0" xmlns:xlink="http://www.w3.org/1999/xlink">
          <sheet id="s1"><topic id="r"><title>Studio</title><children><topics type="attached">
            <topic id="a" branch="folded"><title>Team</title><notes><plain>Sam leads</plain></notes><children><topics type="attached">
              <topic id="a1"><title>Ana</title><labels><label>design</label></labels></topic></topics></children></topic>
            <topic id="b" xlink:href="https://example.test"><title>Budget</title></topic>
          </topics><topics type="detached"><topic id="f"><title>Loose</title></topic></topics></children></topic>
          <title>Sheet one</title></sheet>
        </xmap-content>
        """
        let map = try MindMap.read(ZipArchive.write([("content.xml", Data(xml.utf8))]))
        let root = map.sheets[0].root
        #expect(map.sheets[0].title == "Sheet one")
        #expect(root.title == "Studio")
        #expect(root.children.map(\.title) == ["Team", "Budget"])
        #expect(root.children[0].folded)
        #expect(root.children[0].notes == "Sam leads")
        #expect(root.children[0].children[0].labels == ["design"])
        #expect(root.children[1].link == "https://example.test")
        #expect(root.floating.map(\.title) == ["Loose"])
    }

    @Test func outlinesBothWays() {
        let text = """
        # Shop launch
        - Orders
          - Refunds
          - Returns
        - Delivery
        ## Risks
        1. Couriers late
        """
        let map = MindMap.fromOutline(text)
        let root = map.sheets[0].root
        #expect(root.title == "Shop launch")
        #expect(root.children.map(\.title) == ["Orders", "Delivery", "Risks"])
        #expect(root.children[0].children.map(\.title) == ["Refunds", "Returns"])
        #expect(root.children[2].children.map(\.title) == ["Couriers late"])
        let back = MindMap.fromOutline(map.outline())
        #expect(back.outline() == map.outline())
        #expect(map.mermaid().hasPrefix("mindmap\n  root((Shop launch))\n    Orders\n      Refunds"))
    }

    @Test func outlineKeepsWhatItCan() throws {
        let map = try Self.sample()
        let outline = MindMap.fromOutline("# Shop launch\n- Orders\n  - Refunds\n  - Exchanges\n- Marketing\n")
        let merged = map.replacingTree(with: outline)
        let root = merged.sheets[0].root
        #expect(root.id == "root")
        #expect(root.children.map(\.title) == ["Orders", "Marketing"])
        let orders = root.children[0]
        #expect(orders.id == "a")
        #expect(orders.notes == "Ana owns it")
        #expect(orders.extra["markers"] != nil)
        #expect(orders.children.map(\.title) == ["Refunds", "Exchanges"])
        #expect(orders.children[0].labels == ["later"])
        #expect(root.floating.map(\.title) == ["Ideas"])
    }

    @Test func edits() throws {
        var root = try Self.sample().sheets[0].root
        let done1 = root.add(MindMap.Topic(id: "new", title: "Payments"), after: "a")
        #expect(done1)
        #expect(root.children.map(\.id) == ["a", "new", "b"])
        let done2 = root.move("new", by: 1)
        #expect(done2)
        #expect(root.children.map(\.id) == ["a", "b", "new"])
        let done3 = root.reparent("new", under: "a1")
        #expect(done3)
        #expect(root.find("a1")?.children.map(\.id) == ["new"])
        let done4 = root.reparent("a", under: "a1")
        #expect(!done4) // not under its own branch
        #expect(root.remove("new")?.title == "Payments")
        #expect(root.find("new") == nil)
        let done5 = root.add(MindMap.Topic(title: "Vans"), under: "b")
        #expect(done5)
        #expect(root.find("b")?.folded == false) // adding unfolds
        #expect(root.parent(of: "b1")?.id == "b")
    }

    @Test func laysOutBalancedWithoutOverlaps() {
        var root = MindMap.Topic(id: "root", title: "Centre")
        for n in 0..<5 {
            var main = MindMap.Topic(id: "m\(n)", title: "Main \(n)")
            for c in 0..<(n + 1) { main.children.append(MindMap.Topic(id: "m\(n)c\(c)", title: "Leaf")) }
            root.children.append(main)
        }
        let layout = MindMapLayout(root: root) { _, depth in CGSize(width: depth == 0 ? 120 : 80, height: 30) }
        let rights = root.children.filter { layout.places[$0.id]?.side == .right }.count
        #expect(rights > 0 && rights < 5)
        #expect(layout.places["m0"]?.side == .right)
        #expect(layout.places["m4"]?.side == .left)
        #expect(layout.places["m0c0"]?.branch == 0)
        #expect(layout.places["m4c0"]?.branch == 4)
        let frames = layout.order.compactMap { layout.places[$0]?.frame }
        for (i, a) in frames.enumerated() {
            for b in frames[(i + 1)...] { #expect(!a.insetBy(dx: 1, dy: 1).intersects(b)) }
        }
        // Children sit beyond their parent, on its side.
        let main = layout.places["m4"]!.frame, leaf = layout.places["m4c0"]!.frame
        #expect(leaf.maxX < main.minX)
        root.children[4].folded = true
        #expect(MindMapLayout(root: root) { _, _ in CGSize(width: 80, height: 30) }.places["m4c0"] == nil)
    }
}

struct GitLocationTests {
    @Test func findsARepositoryJustInside() throws {
        let project = FileManager.default.temporaryDirectory.appending(path: "dante-gitloc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: project) }
        try FileManager.default.createDirectory(at: project.appending(path: "Docs"), withIntermediateDirectories: true)
        // Without a repository anywhere, the project is its own (and git says so).
        #expect(GitLocation.find(projectRoot: project).root == project)
        try FileManager.default.createDirectory(at: project.appending(path: "Code/.git"), withIntermediateDirectories: true)
        let nested = GitLocation.find(projectRoot: project)
        #expect(nested.root.lastPathComponent == "Code")
        #expect(nested.prefix == "Code/")
        #expect(nested.projectPath("src/app.ts") == "Code/src/app.ts")
        #expect(nested.repoPath("Code/src/app.ts") == "src/app.ts")
        #expect(nested.repoPath("Docs/plan.md") == nil)
        let change = GitStatus.Change(path: "src/new.ts", oldPath: "src/old.ts", staged: .renamed)
        let shown = nested.projectChange(change)
        #expect(shown.path == "Code/src/new.ts" && shown.oldPath == "Code/src/old.ts")
        #expect(nested.repoChange(shown) == change)
        // Two repositories inside: neither is picked.
        try FileManager.default.createDirectory(at: project.appending(path: "Docs/.git"), withIntermediateDirectories: true)
        #expect(!GitLocation.find(projectRoot: project).isNested)
    }
}
