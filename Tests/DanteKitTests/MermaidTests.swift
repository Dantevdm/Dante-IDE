import Foundation
import Testing
@testable import DanteKit

struct MermaidTests {
    @Test func flowchartNodesEdgesAndLabels() throws {
        guard case .flowchart(let chart) = Mermaid.parse("""
        flowchart LR
          %% a comment
          A[Client] -->|HTTPS| B(API)
          B --> C{Cached?}
          C -- yes --> D[(Redis)]
          C -.-> E((DB))
          B ==> F["Queue [jobs]"]
        """) else { Issue.record("not a flowchart"); return }
        #expect(chart.direction == .right)
        #expect(chart.nodes.map(\.id) == ["A", "B", "C", "D", "E", "F"])
        #expect(chart.node("B")?.shape == .round)
        #expect(chart.node("C")?.shape == .diamond)
        #expect(chart.node("D")?.shape == .database)
        #expect(chart.node("E")?.shape == .circle)
        #expect(chart.node("F")?.label == "Queue [jobs]")
        #expect(chart.edges.count == 5)
        #expect(chart.edges[0].label == "HTTPS")
        #expect(chart.edges[2].label == "yes")
        #expect(chart.edges[3].style == .dotted)
        #expect(chart.edges[4].style == .thick)
        #expect(chart.layers.map { $0.map(\.id) } == [["A"], ["B"], ["C", "F"], ["D", "E"]])
    }

    @Test func chainsSubgraphsAndCycles() {
        guard case .flowchart(let chart) = Mermaid.parse("""
        graph TD
          subgraph cloud [AWS]
            lb[Load balancer] --> app --> db
          end
          db --> lb
        """) else { Issue.record("not a flowchart"); return }
        #expect(chart.direction == .down)
        #expect(chart.edges.map { "\($0.from)>\($0.to)" } == ["lb>app", "app>db", "db>lb"])
        #expect(chart.groups == [Flowchart.Group(id: "cloud", title: "AWS", nodes: ["lb", "app", "db"])])
        // The cycle doesn't hang layout.
        #expect(chart.layers.flatMap { $0 }.count == 3)
    }

    @Test func sequence() {
        guard case .sequence(let diagram) = Mermaid.parse("""
        sequenceDiagram
          actor U as User
          participant API
          U->>API: POST /orders
          loop every item
            API->>DB: insert
          end
          API-->>U: 201 Created
          Note over U,API: logged
          API->DB: ping
        """) else { Issue.record("not a sequence diagram"); return }
        #expect(diagram.participants.map(\.id) == ["U", "API", "DB"])
        #expect(diagram.participants[0].label == "User")
        #expect(diagram.participants[0].isActor)
        #expect(diagram.items.count == 7)
        #expect(diagram.items[0] == .message(from: "U", to: "API", text: "POST /orders", dashed: false, arrow: true))
        #expect(diagram.items[1] == .blockStart(kind: "loop", label: "every item"))
        #expect(diagram.items[4] == .message(from: "API", to: "U", text: "201 Created", dashed: true, arrow: true))
        #expect(diagram.items[5] == .note(over: ["U", "API"], text: "logged"))
        #expect(diagram.items[6] == .message(from: "API", to: "DB", text: "ping", dashed: false, arrow: false))
    }

    @Test func entityRelationship() {
        guard case .entityRelationship(let diagram) = Mermaid.parse("""
        erDiagram
          CUSTOMER ||--o{ ORDER : places
          ORDER ||--|{ LINE_ITEM : contains
          CUSTOMER {
            string id PK
            string email UK
          }
        """) else { Issue.record("not an ER diagram"); return }
        #expect(diagram.entities.map(\.name) == ["CUSTOMER", "ORDER", "LINE_ITEM"])
        #expect(diagram.entities[0].attributes.map(\.name) == ["id", "email"])
        #expect(diagram.entities[0].attributes[0].keys == ["PK"])
        #expect(diagram.relationships[0].fromCardinality == "1")
        #expect(diagram.relationships[0].toCardinality == "0..N")
        #expect(diagram.relationships[1].toCardinality == "1..N")
        #expect(diagram.relationships[0].label == "places")
        #expect(diagram.layers.map { $0.map(\.name) } == [["CUSTOMER"], ["ORDER"], ["LINE_ITEM"]])
    }

    @Test func otherKindsStayAsSource() {
        #expect(Mermaid.parse("pie title Pets\n  \"Dogs\" : 3") == .unsupported("pie"))
    }
}
