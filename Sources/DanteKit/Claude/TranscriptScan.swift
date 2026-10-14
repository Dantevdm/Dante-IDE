import Foundation

/// Reads Claude Code transcripts as bytes. A long session's transcript runs to hundreds of
/// megabytes, where splitting a `String` into lines and parsing each as JSON took seconds:
/// here lines are found with memchr, needles with memmem, and only the pieces needed are
/// decoded.
enum TranscriptScan {
    typealias Line = UnsafeBufferPointer<UInt8>

    /// Calls `body` with each non-empty line.
    static func lines(_ text: String, _ body: (Line) -> Void) {
        var text = text
        text.withUTF8 { all in
            guard var cursor = all.baseAddress else { return }
            let end = cursor + all.count
            while cursor < end {
                let next = memchr(cursor, 0x0A, end - cursor).map { $0.assumingMemoryBound(to: UInt8.self) }
                let stop = next.map { UnsafePointer($0) } ?? end
                if stop > cursor { body(Line(start: cursor, count: stop - cursor)) }
                cursor = stop + 1
            }
        }
    }

    static func has(_ line: Line, _ needle: [UInt8]) -> Bool {
        find(needle, in: line) != nil
    }

    /// Where `needle` starts in `line`.
    static func find(_ needle: [UInt8], in line: Line) -> Int? {
        guard let base = line.baseAddress, line.count >= needle.count else { return nil }
        return needle.withUnsafeBufferPointer { word in
            memmem(base, line.count, word.baseAddress, word.count).map { UnsafePointer($0.assumingMemoryBound(to: UInt8.self)) - base }
        }
    }

    /// The string value after `"key":"` (the first one in the line), without unescaping:
    /// for ids, timestamps and model names.
    static func string(_ key: String, in line: Line, startingWith prefix: String = "") -> String? {
        let pattern = Array("\"\(key)\":\"\(prefix)".utf8)
        guard let at = find(pattern, in: line) else { return nil }
        let start = at + pattern.count - prefix.utf8.count
        guard let end = line[start...].firstIndex(of: UInt8(ascii: "\"")) else { return nil }
        return String(decoding: UnsafeBufferPointer(rebasing: line[start..<end]), as: UTF8.self)
    }

    /// The `usage` object's token counts, read in place; parsing it as JSON cost ten times
    /// more than everything else on a line.
    static func usage(in line: Line) -> TokenUsage? {
        guard let at = find(usageKey, in: line) else { return nil }
        let start = at + usageKey.count - 1
        var depth = 0, end = start
        for index in start..<line.count {
            if line[index] == UInt8(ascii: "{") { depth += 1 }
            if line[index] == UInt8(ascii: "}") { depth -= 1; if depth == 0 { end = index; break } }
        }
        guard end > start else { return nil }
        let object = UnsafeBufferPointer(rebasing: line[start...end])
        let input = int("input_tokens", in: object), output = int("output_tokens", in: object)
        guard input != nil || output != nil else { return nil }
        return TokenUsage(input: input ?? 0, output: output ?? 0,
                          cacheWrite: int("cache_creation_input_tokens", in: object) ?? 0, cacheRead: int("cache_read_input_tokens", in: object) ?? 0)
    }

    private static let usageKey = Array(#""usage":{"#.utf8)

    static func int(_ key: String, in line: Line) -> Int? {
        guard let at = find(Array("\"\(key)\":".utf8), in: line) else { return nil }
        var index = at + key.utf8.count + 3, value = 0, digits = 0
        while index < line.count, line[index] == UInt8(ascii: " ") { index += 1 }
        while index < line.count, line[index] >= UInt8(ascii: "0"), line[index] <= UInt8(ascii: "9") {
            value = value * 10 + Int(line[index] - UInt8(ascii: "0"))
            digits += 1
            index += 1
        }
        return digits > 0 ? value : nil
    }

    /// Claude Code's timestamps (`2026-05-01T10:00:05.123Z`) without a date formatter,
    /// which cost more than the rest of reading a line; other shapes go to one.
    static func date(_ stamp: String) -> Date? {
        let bytes = Array(stamp.utf8)
        func number(_ from: Int, _ length: Int) -> Int? {
            guard from + length <= bytes.count else { return nil }
            var value = 0
            for byte in bytes[from..<(from + length)] {
                guard byte >= 48, byte <= 57 else { return nil }
                value = value * 10 + Int(byte - 48)
            }
            return value
        }
        guard bytes.count >= 20, bytes[4] == UInt8(ascii: "-"), bytes[10] == UInt8(ascii: "T"), bytes.last == UInt8(ascii: "Z"),
              let year = number(0, 4), let month = number(5, 2), let day = number(8, 2),
              let hour = number(11, 2), let minute = number(14, 2), let second = number(17, 2), (1...12).contains(month) else {
            return fallback.date(from: stamp) ?? ISO8601DateFormatter().date(from: stamp)
        }
        var fraction = 0.0
        if bytes[19] == UInt8(ascii: ".") {
            var scale = 0.1
            for byte in bytes[20..<(bytes.count - 1)] where byte >= 48 && byte <= 57 {
                fraction += Double(byte - 48) * scale
                scale /= 10
            }
        }
        // Days since 1970 for a proleptic Gregorian date (Howard Hinnant's days_from_civil).
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        let days = era * 146_097 + dayOfEra - 719_468
        return Date(timeIntervalSince1970: Double(days * 86_400 + hour * 3_600 + minute * 60 + second) + fraction)
    }

    nonisolated(unsafe) private static let fallback: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// The line's own `type`, which assistant lines write after their `message` (whose own
    /// `type` would otherwise be found first): the first `"type"` key at the outer level.
    static func topLevelType(_ line: Line) -> String? {
        guard let base = line.baseAddress else { return nil }
        let quote = UInt8(ascii: "\""), backslash = UInt8(ascii: "\\"), count = line.count
        var depth = 0, index = 0
        while index < count {
            let byte = base[index]
            if byte == quote {
                if depth == 1, index + typeKey.count <= count, memcmp(base + index, typeKey, typeKey.count) == 0 {
                    let start = index + typeKey.count
                    guard let end = memchr(base + start, Int32(quote), count - start) else { return nil }
                    return String(decoding: UnsafeBufferPointer(start: base + start, count: UnsafePointer(end.assumingMemoryBound(to: UInt8.self)) - (base + start)), as: UTF8.self)
                }
                // Skip the string: to the next quote not escaped by an odd run of backslashes.
                var from = index + 1
                while true {
                    guard let found = memchr(base + from, Int32(quote), count - from) else { return nil }
                    let at = UnsafePointer(found.assumingMemoryBound(to: UInt8.self)) - base
                    var slashes = 0
                    while at - slashes - 1 > index, base[at - slashes - 1] == backslash { slashes += 1 }
                    if slashes % 2 == 0 { index = at; break }
                    from = at + 1
                }
            } else if byte == UInt8(ascii: "{") || byte == UInt8(ascii: "[") {
                depth += 1
            } else if byte == UInt8(ascii: "}") || byte == UInt8(ascii: "]") {
                depth -= 1
            }
            index += 1
        }
        return nil
    }

    private static let typeKey = Array(#""type":""#.utf8)

    static func text(_ line: Line) -> String { String(decoding: line, as: UTF8.self) }
}
