import CoreGraphics
import Foundation
import Testing
@testable import DanteKit

struct DiagramTests {
    /// Users → ALB (in an Edge group) → two services (in Compute), all inside an AWS boundary.
    static func sample() -> Diagram {
        var d = Diagram(title: "Umbrella")
        d.nodes = [
            .init(id: "aws", kind: .boundary, title: "AWS cloud", frame: .init(x: 20, y: 20, width: 700, height: 400)),
            .init(id: "edge", kind: .group, title: "Edge", hue: .purple, frame: .init(x: 120, y: 80, width: 220, height: 120), parent: "aws"),
            .init(id: "alb", kind: .card, title: "Shared ALB", subtitle: "Load balancer", hue: .purple, frame: .init(x: 132, y: 112, width: 196, height: 64), parent: "edge"),
            .init(id: "compute", kind: .group, title: "Compute", hue: .amber, frame: .init(x: 400, y: 80, width: 220, height: 200), parent: "aws"),
            .init(id: "grc", kind: .card, title: "GRC Information Service", hue: .amber, frame: .init(x: 412, y: 112, width: 196, height: 64), parent: "compute"),
            .init(id: "risk", kind: .card, title: "Pricing Engine", hue: .amber, frame: .init(x: 412, y: 190, width: 196, height: 64), parent: "compute"),
            .init(id: "users", kind: .person, title: "Users", frame: .init(x: 40, y: 110, width: 64, height: 72), parent: "aws"),
        ]
        d.links = [
            .init(id: "u-alb", from: "users", to: "alb", line: .flowing, pulse: true, arrow: false),
            .traffic(id: "alb-grc", from: "alb", to: "grc", label: "/grc", hue: .amber),
            .traffic(id: "alb-risk", from: "alb", to: "risk", label: "/risk", hue: .amber),
        ]
        return d
    }

    // MARK: The file

    @Test func roundTripsThroughTheFile() throws {
        let diagram = Self.sample()
        let data = try diagram.encoded()
        #expect(try Diagram.decode(data) == diagram)
        let text = String(decoding: data, as: UTF8.self)
        // Defaults stay out of the file, frames are a short array, and keys keep their order.
        #expect(text.contains("\"frame\" : [\n        132,"))
        #expect(!text.contains("\"dashed\""))
        #expect(!text.contains("\"chips\""))
        #expect(try diagram.encoded() == data)
    }

    @Test func readsAHandWrittenFileLeniently() throws {
        let json = """
        {"title": "Draft", "nodes": [
          {"id": "a", "title": "Edge", "kind": "group", "hue": "edge"},
          {"title": "Shared ALB", "kind": "spaceship", "hue": "nonsense", "frame": {"x": 1, "y": 2, "w": 3, "h": 4}, "parent": "a"},
          {"id": "b", "kind": "person", "title": "Users"}
        ], "links": [{"from": "b", "to": "shared-alb"}, {"from": "b", "to": "shared-alb", "label": "again"}]}
        """
        let diagram = try Diagram.decode(Data(json.utf8))
        #expect(diagram.nodes[0].hue == .purple)
        #expect(diagram.nodes[0].icon == "square.stack.3d.up")
        #expect(diagram.nodes[1].id == "shared-alb")
        #expect(diagram.nodes[1].kind == .card)
        #expect(diagram.nodes[1].hue == .blue)
        #expect(diagram.nodes[1].frame == .init(x: 1, y: 2, width: 3, height: 4))
        #expect(diagram.links.map(\.id) == ["b-shared-alb", "b-shared-alb-2"])
        #expect(diagram.links[0].arrow && diagram.links[0].line == .solid)
    }

    @Test func explainsAFileItCantRead() {
        #expect(throws: Diagram.Failure.self) { try Diagram.decode(Data("{\"nodes\": 3}".utf8)) }
        #expect(throws: Diagram.Failure.self) { try Diagram.decode(Data("not json".utf8)) }
    }

    @Test func namesFilesAndIds() {
        #expect(Diagram.slug("OrdersPortal FargateService") == "orders-portal-fargate-service")
        #expect(Diagram.slug("GRC Information Service") == "grc-information-service")
        #expect(Diagram.path(for: "Umbrella target", existing: []) == "docs/diagrams/umbrella-target.dante-diagram.json")
        #expect(Diagram.path(for: "Umbrella target", existing: ["docs/diagrams/umbrella-target.dante-diagram.json"]) == "docs/diagrams/umbrella-target-2.dante-diagram.json")
        #expect(Diagram.title(ofPath: "docs/diagrams/umbrella-target.dante-diagram.json") == "Umbrella target")
        #expect(Self.sample().uniqueID(for: "Shared ALB") == "shared-alb")
        #expect(Self.sample().uniqueID(for: "alb") == "alb-2")
    }

    @Test func docsListsDiagramsInTheirOwnGroup() {
        let library = DocLibrary(paths: ["README.md", "docs/diagrams/umbrella.dante-diagram.json", "src/app.json"])
        #expect(library.groups.map(\.title) == ["Project", "Diagrams"])
        let doc = library.groups[1].docs[0]
        #expect(doc.kind == .diagram)
        #expect(doc.title == "Umbrella")
    }

    // MARK: Editing

    @Test func movingAGroupMovesWhatsInIt() {
        var d = Self.sample()
        d.move(["compute"], by: CGSize(width: 10, height: 20))
        #expect(d.node("grc")?.frame?.x == 422)
        #expect(d.node("risk")?.frame?.y == 210)
        #expect(d.node("alb")?.frame?.x == 132)
    }

    @Test func aCardDraggedOutLeavesItsGroupAndOneDroppedInJoins() {
        var d = Self.sample()
        d.move(["risk"], by: CGSize(width: -260, height: -40), grows: false)
        d.adopt(["risk"])
        #expect(d.node("risk")?.parent == "edge")
        #expect(d.count(of: "edge") == 2)
        #expect(d.count(of: "compute") == 1)
        // The group grew to hold it.
        let edge = d.node("edge")!.rect
        #expect(edge.contains(d.node("risk")!.rect))
        // Out past every container: on its own.
        d.move(["risk"], by: CGSize(width: 0, height: 600), grows: false)
        d.adopt(["risk"])
        #expect(d.node("risk")?.parent == nil)
    }

    @Test func aNewCardFindsRoomBesideTheCardsAlreadyThere() {
        var d = Self.sample()
        let grc = d.node("grc")!.rect
        let id = d.add(.card, at: CGPoint(x: grc.midX, y: grc.midY), findsRoom: true)
        let added = d.node(id)!.rect
        #expect(!d.nodes.filter { $0.id != id && !$0.kind.isContainer }.contains { $0.rect.intersects(added) })
        #expect(hypot(added.midX - grc.midX, added.midY - grc.midY) < 200)
        // Without it, it goes where it's asked.
        let exact = d.add(.card, at: CGPoint(x: grc.midX, y: grc.midY))
        #expect(d.node(exact)!.rect.intersects(grc))
    }

    @Test func aContainerNeverShrinksPastWhatItHolds() {
        var d = Self.sample()
        d.resize("compute", to: CGRect(x: 400, y: 80, width: 50, height: 50))
        let compute = d.node("compute")!.rect
        #expect(compute.contains(d.node("grc")!.rect))
        #expect(compute.contains(d.node("risk")!.rect))
        d.fit("compute")
        #expect(d.node("compute")!.rect == CGRect(x: 400, y: 80, width: 220, height: 186))
    }

    @Test func nudgingGrowsTheContainers() {
        var d = Self.sample()
        d.move(["risk"], by: CGSize(width: 0, height: 300))
        #expect(d.node("compute")!.rect.maxY >= d.node("risk")!.rect.maxY + Diagram.inset)
        #expect(d.node("aws")!.rect.contains(d.node("compute")!.rect))
    }

    @Test func deletingTakesWhatsInsideAndTheLinks() {
        var d = Self.sample()
        d.delete(["compute"])
        #expect(d.node("grc") == nil && d.node("risk") == nil)
        #expect(d.links.map(\.id) == ["u-alb"])
        d.delete(["u-alb"])
        #expect(d.links.isEmpty)
    }

    @Test func duplicatingCopiesInsideAndLinksWithNewIds() {
        var d = Self.sample()
        let copies = d.duplicate(["compute"])
        #expect(copies.count == 1)
        let copy = d.node(copies.first!)!
        #expect(copy.id == "compute-2")
        #expect(copy.parent == "aws")
        #expect(d.children(of: copy.id).map(\.id).sorted() == ["grc-2", "risk-2"])
        #expect(d.links.count == 3)
        let pasted = d.paste(d.clipboard(["alb", "grc"]), offset: CGSize(width: 0, height: 300))
        #expect(pasted.count == 2)
        #expect(d.links.contains { $0.from == "alb-2" && $0.to == "grc-3" && $0.label == "/grc" })
    }

    @Test func connectsOnceEachWay() {
        var d = Self.sample()
        let id = d.connect("grc", to: "risk", label: "asks")
        #expect(id != nil)
        #expect(d.connect("grc", to: "risk") == id)
        #expect(d.connect("grc", to: "grc") == nil)
        let link = d.link(id!)!
        #expect(link.pulse && link.hue == .amber && link.label == "asks")
    }

    @Test func groupsAndUngroups() {
        var d = Self.sample()
        let group = d.group(["grc", "risk"], title: "Apps")!
        #expect(d.node(group)?.parent == "compute")
        #expect(d.node("grc")?.parent == group)
        #expect(d.count(of: "compute") == 0)
        #expect(d.nodes.firstIndex { $0.id == group }! < d.nodes.firstIndex { $0.id == "grc" }!)
        d.ungroup(group)
        #expect(d.node("grc")?.parent == "compute")
        #expect(d.node(group) == nil)
    }

    @Test func alignsAndDistributes() {
        var d = Self.sample()
        d.align(["grc", "risk", "alb"], .top)
        #expect(Set(["grc", "risk", "alb"].map { d.node($0)!.rect.minY }) == [112])
        var row = Diagram(title: "Row")
        row.nodes = [0, 50, 400].enumerated().map { index, x in
            .init(id: "n\(index)", kind: .card, title: "N", frame: .init(x: x, y: 0, width: 100, height: 40))
        }
        row.distribute(["n0", "n1", "n2"], horizontally: true)
        #expect(row.nodes.map { $0.rect.minX } == [0, 200, 400])
    }

    @Test func snapsToNeighboursThenToTheGrid() {
        let other = CGRect(x: 100, y: 100, width: 196, height: 64)
        let near = DiagramSnap.snap(CGRect(x: 103, y: 300, width: 196, height: 64), to: [other])
        #expect(near.offset.width == -3)
        #expect(near.guides.first?.vertical == true && near.guides.first?.position == 100)
        let far = DiagramSnap.snap(CGRect(x: 503, y: 301, width: 100, height: 40), to: [other])
        #expect(far.offset == CGSize(width: 1, height: 3))
        #expect(far.guides.isEmpty)
    }

    @Test func linkCurvesGoSideToSideOrDown() {
        let a = CGRect(x: 0, y: 0, width: 100, height: 40), beside = CGRect(x: 200, y: 0, width: 100, height: 40)
        let below = CGRect(x: 10, y: 200, width: 100, height: 40)
        #expect(LinkCurve.direct(a, beside).start == CGPoint(x: 100, y: 20))
        #expect(LinkCurve.direct(a, below).start == CGPoint(x: 50, y: 40))
        #expect(LinkCurve.loop(a, below).start == CGPoint(x: 100, y: 20))
        #expect(LinkCurve.direct(a, beside).distance(to: CGPoint(x: 150, y: 20)) < 2)
    }

    // MARK: Layout

    @Test func laysOutAFileWithoutFramesAlongTheLinks() {
        var d = Diagram(title: "Agent's draft")
        d.nodes = [
            .init(id: "users", kind: .person, title: "Users"),
            .init(id: "edge", kind: .group, title: "Edge"),
            .init(id: "alb", kind: .card, title: "ALB", parent: "edge"),
            .init(id: "cert", kind: .card, title: "Certificate", parent: "edge"),
            .init(id: "app", kind: .card, title: "Catalogue"),
        ]
        d.links = [.init(id: "1", from: "users", to: "alb"), .init(id: "2", from: "alb", to: "app"), .init(id: "3", from: "app", to: "users")]
        let laid = d.laidOut()
        #expect(laid.nodes.allSatisfy { $0.frame != nil })
        let users = laid.node("users")!.rect, edge = laid.node("edge")!.rect, app = laid.node("app")!.rect
        #expect(users.maxX < edge.minX && edge.maxX < app.minX)
        #expect(edge.contains(laid.node("alb")!.rect) && edge.contains(laid.node("cert")!.rect))
        #expect(laid.node("alb")!.rect.maxY <= laid.node("cert")!.rect.minY)
    }

    // MARK: From the Map

    static func infra() -> Infrastructure {
        Infrastructure.detect(files: Array(InfrastructureTests.files.keys)) { InfrastructureTests.files[$0] }
    }

    @Test func copiesTheInfraViewWithItsGroupsAndLinks() throws {
        let infra = Self.infra()
        let diagram = Diagram.infrastructure(infra, title: "Shop today")
        let cloud = try #require(diagram.nodes.first { $0.kind == .boundary })
        #expect(cloud.title == "AWS cloud")
        #expect(cloud.dashed)
        let groups = diagram.nodes.filter { $0.kind == .group }
        #expect(!groups.isEmpty && groups.allSatisfy { $0.parent == cloud.id })
        // Every resource is a card in its tier's group, coloured like it.
        for resource in infra.resources {
            let card = try #require(diagram.nodes.first { $0.kind == .card && $0.title == resource.name && $0.subtitle == resource.service })
            let group = try #require(diagram.node(card.parent ?? ""))
            #expect(group.title == resource.tier.title)
            #expect(card.hue == Diagram.Hue(tier: resource.tier))
            #expect(group.rect.contains(card.rect))
        }
        #expect(diagram.nodes.filter { $0.kind == .stage }.count == infra.pipelines.reduce(0) { $0 + $1.stages.count })
        #expect(diagram.links.count >= infra.links.count)
        #expect(diagram.drawableLinks.count == diagram.links.count)
        #expect(!diagram.bounds.isNull && diagram.bounds.minX >= 0 && diagram.bounds.minY >= 0)
    }

    @Test func keepsTheViewsPositions() {
        let infra = Self.infra()
        let resource = infra.resources[0]
        let frames: [String: CGRect] = [
            resource.id: CGRect(x: 300, y: 300, width: 196, height: 70),
            "tier:\(resource.tier.rawValue)": CGRect(x: 288, y: 264, width: 220, height: 118),
            "cloud": CGRect(x: 24, y: 240, width: 600, height: 200),
        ]
        let diagram = Diagram.infrastructure(infra, title: "Shop", frames: frames)
        let card = diagram.nodes.first { $0.title == resource.name }!
        #expect(card.frame == .init(x: 300, y: 300, width: 196, height: 70))
        // The dashed panel keeps its place, with room above it for its title.
        let cloud = diagram.nodes.first { $0.kind == .boundary }!.rect
        #expect(cloud.origin == CGPoint(x: 24, y: 210))
        #expect(cloud.width >= 600)
    }

    @Test func copiesTheSystemMapAsLanes() {
        var map = SystemMap(parts: [
            .init(id: "client:web", name: "web", lane: .clients, kind: .web, items: [.init("Orders"), .init("Checkout")]),
            .init(id: "api:orders", name: "/orders", lane: .api, kind: .routes, detail: "4 routes"),
            .init(id: "db", name: "Postgres", lane: .data, kind: .database, container: "db"),
            .init(id: "stripe", name: "Stripe", lane: .outside, kind: .payments),
        ], links: [.init(from: "client:web", to: "api:orders", weight: 6), .init(from: "api:orders", to: "db", weight: 1)])
        map.laneTitles[.api] = "Routes"
        let diagram = Diagram.system(map, title: "System")
        #expect(diagram.nodes.filter { $0.kind == .group }.map(\.title) == ["Clients", "Routes", "Data", "Outside services"])
        let web = diagram.nodes.first { $0.title == "web" }!
        #expect(web.kind == .box && web.text == "Orders · Checkout" && web.icon == "macwindow")
        #expect(diagram.nodes.first { $0.title == "Postgres" }?.chips == ["db"])
        #expect(diagram.nodes.first { $0.title == "Stripe" }?.dashed == true)
        #expect(diagram.links.map(\.pulse) == [true, false])
        #expect(diagram.links.allSatisfy { $0.route == .loop })
        for node in diagram.nodes where node.kind == .box {
            #expect(diagram.node(node.parent!)!.rect.contains(node.rect))
        }
    }

    // MARK: Export

    @Test func exportsMermaidWithSubgraphs() {
        let text = Self.sample().mermaid()
        #expect(text.hasPrefix("flowchart LR\n"))
        #expect(text.contains("subgraph aws[\"AWS cloud\"]"))
        #expect(text.contains("    subgraph edge[\"Edge\"]"))
        #expect(text.contains("alb[\"Shared ALB<br/>Load balancer\"]"))
        #expect(text.contains("users((\"Users\"))"))
        #expect(text.contains("alb -->|/grc| grc"))
        #expect(text.contains("users -.- alb"))
        // Dante's own Mermaid reader takes it.
        if case .flowchart(let chart) = Mermaid.parse(text) {
            #expect(chart.nodes.count >= 4)
        } else {
            Issue.record("Not read as a flowchart")
        }
    }

    @Test func exportsSVGThatAnimatesInABrowser() {
        let svg = DiagramSVG.render(Self.sample(), theme: .light) { symbol, _, _ in "data:image/png;base64,\(symbol)" }
        #expect(svg.hasPrefix("<svg xmlns=\"http://www.w3.org/2000/svg\""))
        #expect(svg.contains("<title>Umbrella</title>"))
        #expect(svg.contains(">AWS CLOUD</text>"))
        #expect(svg.contains(">Shared ALB</text>"))
        #expect(svg.contains("<animateMotion"))
        #expect(svg.contains("stroke-dashoffset"))
        #expect(svg.contains(">/grc</text>"))
        #expect(svg.contains("data:image/png;base64,person.2.fill"))
        #expect(svg.contains(Theme.light.syntax.keyword.css))
        // The same picture gives the same file.
        #expect(svg == DiagramSVG.render(Self.sample(), theme: .light) { symbol, _, _ in "data:image/png;base64,\(symbol)" })
    }

    @Test func wrapsLongNamesAtCamelCase() {
        let lines = DiagramSVG.wrap("OrdersPortalServiceIngressFromAlb", width: 120, size: 12)
        #expect(lines.count == 2)
        #expect(lines[0].hasPrefix("OrdersPortal"))
    }

    @Test func theGuideNamesEveryKindAndHue() {
        let guide = DiagramGuide.format
        for kind in Diagram.Node.Kind.allCases { #expect(guide.contains(kind.rawValue)) }
        for hue in Diagram.Hue.allCases { #expect(guide.contains(hue.rawValue)) }
        #expect(DiagramLibrary.components.contains { $0.title == "Load balancer" })
        #expect(DiagramLibrary.sections.last == "Apps and services")
    }

    // MARK: Tidying

    @Test func tidyingSpreadsLabelledColumnsAndKeepsTheArrangement() throws {
        var d = Self.sample()
        // Crowd it: compute hard against edge, a gap in the middle of the stack.
        d.nodes[d.nodes.firstIndex { $0.id == "compute" }!].frame = .init(x: 350, y: 80, width: 220, height: 260)
        d.nodes[d.nodes.firstIndex { $0.id == "grc" }!].frame = .init(x: 362, y: 112, width: 196, height: 54)
        d.nodes[d.nodes.firstIndex { $0.id == "risk" }!].frame = .init(x: 362, y: 260, width: 196, height: 54)
        let t = d.tidied()
        func r(_ id: String) -> CGRect { t.node(id)!.rect }
        // Same order, left to right and top to bottom.
        #expect(r("users").maxX < r("edge").minX)
        #expect(r("edge").maxX < r("compute").minX)
        #expect(r("grc").maxY < r("risk").minY)
        // Labelled links cross edge → compute, so the gap fits a label; users → edge has none.
        #expect(r("compute").minX - r("edge").maxX == Diagram.labelledColumnGap)
        #expect(r("edge").minX - r("users").maxX == Diagram.columnGap)
        // The stack closes up, and the long title gets a wider column shared by both cards.
        #expect(r("risk").minY - r("grc").maxY == 12)
        #expect(r("grc").width > 196)
        #expect(r("grc").width == r("risk").width)
        // Containers hold what's in them.
        for node in t.nodes where node.parent != nil {
            #expect(t.node(node.parent!)!.rect.contains(node.rect), "\(node.id) inside \(node.parent!)")
        }
        // Tidying a tidy picture changes nothing.
        #expect(t.tidied() == t)
    }

    @Test func tidyingKeepsCardsSizedForTheirLines() {
        var d = Diagram(title: "Cards")
        d.nodes = [
            .init(id: "a", kind: .card, title: "Bare", frame: .init(x: 40, y: 40, width: 196, height: 90)),
            .init(id: "b", kind: .card, title: "Full", subtitle: "ECS service", detail: "/risk", frame: .init(x: 40, y: 140, width: 196, height: 40)),
        ]
        let t = d.tidied()
        #expect(t.node("a")!.rect.height == 48)
        #expect(t.node("b")!.rect.height == 64)
    }

    @Test func tidyingOnlyTheSelectionLeavesTheRestAlone() {
        var d = Self.sample()
        d.nodes[d.nodes.firstIndex { $0.id == "risk" }!].frame = .init(x: 412, y: 300, width: 196, height: 64)
        let t = d.tidied(only: ["compute"])
        // Inside compute the stack closes up…
        #expect(t.node("risk")!.rect.minY - t.node("grc")!.rect.maxY == 12)
        // …and nothing outside it moves.
        for id in ["edge", "alb", "users"] { #expect(t.node(id)!.rect == d.node(id)!.rect, "\(id) stayed") }
        #expect(t.node("compute")!.rect.origin == d.node("compute")!.rect.origin)
    }

    @Test func tidyingPutsThingsNextToWhatTheyLinkTo() {
        var d = Diagram(title: "Order")
        d.nodes = [
            .init(id: "a", kind: .card, title: "A", frame: .init(x: 40, y: 40, width: 196, height: 48)),
            .init(id: "b", kind: .card, title: "B", frame: .init(x: 40, y: 100, width: 196, height: 48)),
            .init(id: "y", kind: .card, title: "Y", frame: .init(x: 400, y: 40, width: 196, height: 48)),
            .init(id: "x", kind: .card, title: "X", frame: .init(x: 400, y: 100, width: 196, height: 48)),
        ]
        // a links to x and b to y: crossed as drawn.
        d.links = [.init(id: "ax", from: "a", to: "x"), .init(id: "by", from: "b", to: "y")]
        let t = d.tidied()
        #expect(t.node("x")!.rect.minY < t.node("y")!.rect.minY)
    }

    @Test func arrangingByFlowPutsWhatLinksFirstOnTheLeft() {
        var d = Diagram(title: "Flow")
        d.nodes = [
            .init(id: "db", kind: .card, title: "Database", frame: .init(x: 40, y: 40, width: 196, height: 48)),
            .init(id: "api", kind: .card, title: "API", frame: .init(x: 300, y: 300, width: 196, height: 48)),
            .init(id: "users", kind: .person, title: "Users", frame: .init(x: 600, y: 40, width: 64, height: 72)),
        ]
        d.links = [.init(id: "u", from: "users", to: "api"), .init(id: "d", from: "api", to: "db")]
        let t = d.arrangedByFlow()
        #expect(t.node("users")!.rect.maxX < t.node("api")!.rect.minX)
        #expect(t.node("api")!.rect.maxX < t.node("db")!.rect.minX)
    }
}
