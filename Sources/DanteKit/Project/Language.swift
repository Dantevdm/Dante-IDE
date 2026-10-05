import Foundation

/// The languages Dante recognises, by file name.
public enum Language: String, CaseIterable, Sendable {
    case swift, typescript, javascript, python, go, rust, java, kotlin
    case c, cpp, csharp, ruby, php, shell, sql, html, css
    case json, yaml, toml, markdown, dockerfile, plain

    public init(url: URL) {
        let name = url.lastPathComponent.lowercased()
        if name == "dockerfile" || name.hasPrefix("dockerfile.") || name.hasSuffix(".dockerfile") {
            self = .dockerfile
            return
        }
        if name == "makefile" || name.hasPrefix(".zshrc") || name.hasPrefix(".bashrc") {
            self = .shell
            return
        }
        switch url.pathExtension.lowercased() {
        case "swift": self = .swift
        case "ts", "tsx", "mts", "cts": self = .typescript
        case "js", "jsx", "mjs", "cjs": self = .javascript
        case "py", "pyi": self = .python
        case "go": self = .go
        case "rs": self = .rust
        case "java": self = .java
        case "kt", "kts": self = .kotlin
        case "c", "h": self = .c
        case "cc", "cpp", "cxx", "hpp", "hh", "m", "mm": self = .cpp
        case "cs": self = .csharp
        case "rb": self = .ruby
        case "php": self = .php
        case "sh", "bash", "zsh", "fish": self = .shell
        case "sql": self = .sql
        case "html", "htm", "xml", "svg", "plist": self = .html
        case "css", "scss", "less": self = .css
        case "json", "jsonc": self = .json
        case "yaml", "yml": self = .yaml
        case "toml": self = .toml
        case "md", "markdown", "mdx": self = .markdown
        default: self = .plain
        }
    }

    public var displayName: String {
        switch self {
        case .swift: "Swift"
        case .typescript: "TypeScript"
        case .javascript: "JavaScript"
        case .python: "Python"
        case .go: "Go"
        case .rust: "Rust"
        case .java: "Java"
        case .kotlin: "Kotlin"
        case .c: "C"
        case .cpp: "C++"
        case .csharp: "C#"
        case .ruby: "Ruby"
        case .php: "PHP"
        case .shell: "Shell"
        case .sql: "SQL"
        case .html: "HTML"
        case .css: "CSS"
        case .json: "JSON"
        case .yaml: "YAML"
        case .toml: "TOML"
        case .markdown: "Markdown"
        case .dockerfile: "Dockerfile"
        case .plain: "Plain text"
        }
    }
}
