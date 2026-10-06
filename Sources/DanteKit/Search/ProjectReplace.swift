import Foundation

/// Replace across the project. Matches are found again in the text being changed and picked
/// by their `ProjectSearch.Match.id`, so a file that changed since the search loses only the
/// matches that moved.
public enum ProjectReplace {
    /// The NSRegularExpression template: a regex query may use `$1`; a plain one is taken literally.
    public static func template(_ replacement: String, for query: ProjectSearch.Query) -> String {
        query.isRegex ? replacement : NSRegularExpression.escapedTemplate(for: replacement)
    }

    /// What `matched` becomes, for previews.
    public static func preview(of matched: String, query: ProjectSearch.Query, replacement: String) -> String {
        guard let expression = query.expression else { return replacement }
        let range = NSRange(location: 0, length: (matched as NSString).length)
        guard let found = expression.firstMatch(in: matched, range: range) else { return replacement }
        return expression.replacementString(for: found, in: matched, offset: 0, template: template(replacement, for: query))
    }

    /// Replaces the matches `include` accepts, by match id ("line:column").
    public static func apply(_ query: ProjectSearch.Query, replacement: String, to text: String,
                             include: (String) -> Bool = { _ in true }) -> (text: String, count: Int) {
        guard let expression = query.expression else { return (text, 0) }
        let source = text as NSString
        let template = template(replacement, for: query)
        let output = NSMutableString()
        var copied = 0, count = 0
        var line = 0, lineStart = 0, scanned = 0
        expression.enumerateMatches(in: text, range: NSRange(location: 0, length: source.length)) { found, _, _ in
            guard let found, found.range.length > 0 else { return }
            while scanned < found.range.location {
                if source.character(at: scanned) == 0x0A {
                    line += 1
                    lineStart = scanned + 1
                }
                scanned += 1
            }
            guard include("\(line):\(found.range.location - lineStart)") else { return }
            output.append(source.substring(with: NSRange(location: copied, length: found.range.location - copied)))
            output.append(expression.replacementString(for: found, in: text, offset: 0, template: template))
            copied = NSMaxRange(found.range)
            count += 1
        }
        guard count > 0 else { return (text, 0) }
        output.append(source.substring(from: copied))
        return (output as String, count)
    }
}
