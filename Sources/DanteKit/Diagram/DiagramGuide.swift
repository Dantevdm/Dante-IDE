import Foundation

/// Ready-made cards for the editor's library and the agents' guide: the cloud resources the
/// Infra view knows, then the everyday parts of a system.
public enum DiagramLibrary {
    public struct Component: Equatable, Sendable, Identifiable, Hashable {
        public var title: String
        public var icon: String
        public var hue: Diagram.Hue
        public var section: String
        public var id: String { section + "/" + title }
    }

    public static let components: [Component] = {
        var seen: Set<String> = []
        var list: [Component] = []
        for rule in Infrastructure.Catalog.rules where seen.insert(rule.service).inserted {
            list.append(Component(title: rule.service, icon: rule.symbol, hue: Diagram.Hue(tier: rule.tier), section: rule.tier.title))
        }
        let everyday: [(String, String, Diagram.Hue)] = [
            ("Web app", "macwindow", .blue),
            ("Mobile app", "iphone", .blue),
            ("API", "arrow.left.arrow.right", .purple),
            ("Service", "shippingbox", .teal),
            ("Worker", "gearshape.2", .teal),
            ("Identity provider", "person.badge.shield.checkmark", .red),
            ("Access governance", "person.2.badge.gearshape", .red),
            ("Single sign-on", "key.horizontal", .red),
            ("Email", "envelope", .green),
            ("Notifications", "bell.badge", .green),
            ("Outside service", "globe", .green),
            ("AI model", "sparkles", .green),
            ("Payments", "creditcard", .green),
            ("Repository", "chevron.left.forwardslash.chevron.right", .gray),
            ("Document", "doc.text", .gray),
        ]
        list += everyday.map { Component(title: $0.0, icon: $0.1, hue: $0.2, section: "Apps and services") }
        return list
    }()

    public static var sections: [String] {
        var order: [String] = []
        for component in components where !order.contains(component.section) { order.append(component.section) }
        return order
    }
}

/// What an agent needs to write or change a diagram: the file format, by example.
public enum DiagramGuide {
    public static var format: String {
        let icons = DiagramLibrary.components.map { "\($0.title): \($0.icon)" }.joined(separator: "; ")
        return """
        Dante diagrams are JSON files named docs/diagrams/<name>.dante-diagram.json. The user edits them in Docs, where they draw in the Map's style (the Infra and System views): cards, groups with a coloured header and a count, a dashed boundary, people and labelled links with moving pulses. Write the file with your normal file tools, then call open_file on it so the user sees it.

        Top level: {"version": 1, "title": "…", "note": "optional line under the title", "nodes": […], "links": […]}

        A node: {"id": "shared-alb", "kind": "card", "title": "Shared ALB", "subtitle": "Load balancer", "detail": "portal-alb-stack", "icon": "arrow.left.arrow.right.square", "hue": "purple", "frame": [x, y, width, height], "parent": "edge"}
        - kind: card (a resource: icon tile, title, kind line, monospaced detail), box (a part with a coloured stripe, as on the System map), group (a titled box holding cards, its header counts them), boundary (dashed outer frame with its title above, like "AWS cloud"; subtitle lists the stacks), person (round badge, like "Users"), stage (a pipeline stage; icons is its steps as SF Symbols), source (where a pipeline starts; chips are branches, tag is the environment), title (a band heading), text (a note; put the words in text).
        - hue: blue, purple, teal, green, amber, red or gray (the Map's), or indigo, pink, orange, yellow, cyan, lime or brown. The Map's colours: edge purple, compute amber, data and images blue, messaging and network teal, security red, observability green.
        - icon: an SF Symbol name. Library: \(icons).
        - parent: the id of the group or boundary it sits in. Groups can sit in a boundary.
        - frame is optional: leave it out and Dante lays the picture out by the links (left to right) and stacks each group's contents. Give frames when the layout matters: cards are about 196×64, people 64×72, stages 196×76, groups 12 points wider than their cards on each side with 32 points for the header, a boundary 30 points taller than its contents' box plus 40 at the top. Leave 56 points between columns, and 120 where the links between them have labels, so each label sits clear of the cards; stack cards 12 points apart in a group and groups 32 apart. A card's title is one line at about 7 points a character beside a 66-point icon, so widen the cards in a column for long titles (\"GRC Information Service\" needs about 225) rather than letting it wrap; a card with a subtitle and a detail is 64 tall. Dante's Tidy button applies these rules to any diagram.
        - optional: dashed (true for something outside the system or not built yet), chips, tag, icons, text.

        A link: {"id": "alb-to-catalogue", "from": "shared-alb", "to": "catalogue", "label": "/catalogue", "pulse": true, "hue": "amber"}
        - line: solid (default), dashed (inferred or planned) or flowing (moving dashes, as from Users and between pipeline stages).
        - pulse: true sends a glowing packet along it (traffic). hue colours it; without one it's a quiet grey line and its pulse takes the colour of where it goes.
        - arrow (default true), width (default 1.5), route: auto or loop (side to side, looping to the right within a column).

        Keep ids short and readable; links name nodes by id. Change an existing diagram by editing its file: the editor reloads it.
        """
    }
}
