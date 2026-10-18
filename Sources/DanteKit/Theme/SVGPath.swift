import Foundation

/// The commands in an SVG path's `d` attribute, as absolute points: enough to draw a logo
/// as a shape. Reads M, L, H, V, C and Z in either case; arcs and smooth curves aren't needed yet.
public enum SVGPath {
    public enum Command: Equatable, Sendable {
        case move(Point)
        case line(Point)
        case curve(Point, Point, to: Point)
        case close
    }

    public struct Point: Equatable, Sendable {
        public var x, y: Double
        public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
    }

    public static func parse(_ d: String) -> [Command] {
        var commands: [Command] = []
        var scanner = Tokens(d)
        var current = Point(0, 0), start = Point(0, 0)
        var letter: Character?
        while let next = scanner.next() {
            if case .letter(let found) = next { letter = found } else { scanner.pushBack(next) }
            guard let command = letter else { break }
            let relative = command.isLowercase
            func point() -> Point? {
                guard let x = scanner.number(), let y = scanner.number() else { return nil }
                return relative ? Point(current.x + x, current.y + y) : Point(x, y)
            }
            switch command.uppercased() {
            case "M":
                guard let p = point() else { return commands }
                commands.append(.move(p))
                current = p; start = p
                // Further pairs after a move are lines.
                letter = relative ? "l" : "L"
            case "L":
                guard let p = point() else { return commands }
                commands.append(.line(p)); current = p
            case "H":
                guard let x = scanner.number() else { return commands }
                current = Point(relative ? current.x + x : x, current.y)
                commands.append(.line(current))
            case "V":
                guard let y = scanner.number() else { return commands }
                current = Point(current.x, relative ? current.y + y : y)
                commands.append(.line(current))
            case "C":
                guard let a = point(), let b = point(), let p = point() else { return commands }
                commands.append(.curve(a, b, to: p)); current = p
            case "Z":
                commands.append(.close)
                current = start
                letter = nil
            default:
                return commands
            }
        }
        return commands
    }

    private enum Token { case letter(Character), number(Double) }

    private struct Tokens {
        let characters: [Character]
        var index = 0
        var pending: Token?

        init(_ text: String) { characters = Array(text) }

        mutating func pushBack(_ token: Token) { pending = token }

        mutating func number() -> Double? {
            guard let token = next() else { return nil }
            if case .number(let value) = token { return value }
            pushBack(token)
            return nil
        }

        mutating func next() -> Token? {
            if let token = pending { pending = nil; return token }
            while index < characters.count, characters[index] == " " || characters[index] == "," || characters[index].isNewline { index += 1 }
            guard index < characters.count else { return nil }
            let character = characters[index]
            if character.isLetter, character != "e", character != "E" {
                index += 1
                return .letter(character)
            }
            var text = ""
            var seenDot = false
            while index < characters.count {
                let c = characters[index]
                if c.isNumber { text.append(c) }
                else if c == "." && !seenDot { seenDot = true; text.append(c) }
                else if (c == "-" || c == "+") && (text.isEmpty || text.last == "e" || text.last == "E") { text.append(c) }
                else if (c == "e" || c == "E") && !text.isEmpty { text.append(c) }
                else { break }
                index += 1
            }
            guard let value = Double(text) else { index += 1; return next() }
            return .number(value)
        }
    }
}
