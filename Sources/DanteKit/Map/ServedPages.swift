import Foundation

/// Pages a backend serves straight from its resources: hand-written HTML and scripts under
/// `resources/static` or `resources/public` (Ktor, Amper, Spring, Micronaut),
/// `META-INF/resources` (Quarkus) or `src/main/webapp`. They're a web client like any other,
/// though the Map skips `static/` and `public/` folders elsewhere as build output.
public enum ServedPages {
    /// Where a folder of pages sits: the backend module's folder ("" for the repo) and the URL
    /// path the folder is served under ("/debug", or "/" for the top).
    public static func place(of folder: String) -> (module: String, urlPath: String)? {
        let parts = folder.split(separator: "/").map(String.init)
        guard !parts.contains(where: { ["node_modules", "dist", "build", "target", "out"].contains($0) || $0.hasPrefix(".") }) else { return nil }
        for index in parts.indices {
            let name = parts[index]
            var module: [String]?
            if ["static", "public"].contains(name), index >= 1, parts[index - 1] == "resources" {
                module = Array(parts[..<(index - 1)])
            } else if name == "resources", index >= 1, parts[index - 1] == "META-INF", index >= 2, parts[index - 2] == "resources" {
                module = Array(parts[..<(index - 2)])
            } else if name == "webapp", index >= 2, parts[index - 1] == "main", parts[index - 2] == "src" {
                module = Array(parts[..<(index - 2)])
            }
            guard var module else { continue }
            if module.suffix(2) == ["src", "main"] { module.removeLast(2) }
            return (module.joined(separator: "/"), "/" + parts[(index + 1)...].joined(separator: "/"))
        }
        return nil
    }

    /// A page the backend serves: an HTML file in a served folder.
    public static func isPage(_ file: String) -> Bool {
        ["html", "htm"].contains((file as NSString).pathExtension.lowercased()) && place(of: (file as NSString).deletingLastPathComponent) != nil
    }

    /// A hand-written script beside such pages (minified copies of libraries aren't).
    public static func isScript(_ file: String) -> Bool {
        let name = (file as NSString).lastPathComponent.lowercased()
        guard ["js", "mjs", "ts"].contains((name as NSString).pathExtension), !name.contains(".min."), !name.hasSuffix(".d.ts") else { return false }
        return place(of: (file as NSString).deletingLastPathComponent) != nil
    }

    /// The screen a page is listed as: "debug" for debug/index.html, "debug/report" for
    /// debug/report.html, "home" for the top index.html.
    public static func screenName(of file: String) -> String? {
        guard isPage(file), let place = place(of: (file as NSString).deletingLastPathComponent) else { return nil }
        let stem = ((file as NSString).lastPathComponent as NSString).deletingPathExtension
        let folder = String(place.urlPath.dropFirst())
        let name = stem.lowercased() == "index" ? folder : (folder.isEmpty ? stem : folder + "/" + stem)
        return name.isEmpty ? "home" : name
    }

    /// The address a page opens at. An index page is its folder, with a trailing slash unless
    /// the page loads its assets by absolute path under the folder (then the backend likely
    /// routes the bare folder, as in `get("/debug")`).
    public static func urlPath(of file: String, text: String?) -> String {
        guard let place = place(of: (file as NSString).deletingLastPathComponent) else { return "/" }
        let name = (file as NSString).lastPathComponent
        if (name as NSString).deletingPathExtension.lowercased() != "index" {
            return (place.urlPath == "/" ? "" : place.urlPath) + "/" + name
        }
        if place.urlPath == "/" { return "/" }
        let absolute = text.map { $0.contains("\"\(place.urlPath)/") || $0.contains("'\(place.urlPath)/") } ?? false
        return absolute ? place.urlPath : place.urlPath + "/"
    }

    // MARK: The backend serving them

    /// The port the backend listens on, from its config, else the usual 8080.
    public static func port(module: String, files: [String], read: (String) -> String?) -> (port: Int, source: String) {
        let prefix = module.isEmpty ? "" : module + "/"
        let configs = ["resources/application.yaml", "resources/application.yml", "resources/application.conf",
                       "src/main/resources/application.yaml", "src/main/resources/application.yml",
                       "src/main/resources/application.conf", "src/main/resources/application.properties"]
        for config in configs {
            let path = prefix + config
            guard files.contains(path), let text = read(path) else { continue }
            if let port = configuredPort(text) { return (port, (config as NSString).lastPathComponent) }
        }
        for file in files where file.hasPrefix(prefix) && ["kt", "java"].contains((file as NSString).pathExtension) && !SystemMap.isTest(file) {
            guard let text = read(file), text.contains("embeddedServer(") else { continue }
            if let match = text.firstMatch(of: /embeddedServer\([^)]*?port\s*=\s*(\d{2,5})/), let port = Int(match.1) {
                return (port, (file as NSString).lastPathComponent)
            }
        }
        return (8080, "the usual 8080")
    }

    /// `port: 8080` (YAML, under ktor.deployment or server), `port = 8080` (HOCON),
    /// `server.port=8080` or `quarkus.http.port=8080` (properties).
    static func configuredPort(_ text: String) -> Int? {
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#") else { continue }
            if let match = trimmed.wholeMatch(of: /(?:server\.|quarkus\.http\.|micronaut\.server\.)?port\s*[:=]\s*"?(\d{2,5})"?/),
               let port = Int(match.1) {
                return port
            }
        }
        return nil
    }

    /// How the project starts the backend: its mise task for development, else the build
    /// tool's run command. Returns the command (from the repo root) and the tool it needs.
    public static func command(module: String, files: [String], read: (String) -> String?) -> (command: String, tool: String) {
        let prefix = module.isEmpty ? "" : module + "/"
        let cd = module.isEmpty ? "" : "cd \(Shell.quote(module)) && "
        for config in [prefix + "mise.toml", prefix + ".mise.toml", "mise.toml", ".mise.toml"] where files.contains(config) {
            guard let text = read(config) else { continue }
            for task in ["dev", "run", "start", "serve"] where text.contains("[tasks.\(task)]") || text.contains("[tasks.\"\(task)\"]") {
                return ((config.hasPrefix(prefix) && !prefix.isEmpty ? cd : "") + "mise run \(task)", "mise")
            }
        }
        if files.contains(prefix + "module.yaml"), files.contains(prefix + "kotlin") { return (cd + "./kotlin run", "java") }
        if files.contains(prefix + "module.yaml"), files.contains(prefix + "amper") { return (cd + "./amper run", "java") }
        let gradle = [prefix + "build.gradle.kts", prefix + "build.gradle"].first { files.contains($0) }
        let maven = files.contains(prefix + "pom.xml")
        let build = (gradle ?? (maven ? prefix + "pom.xml" : nil)).flatMap(read) ?? ""
        if gradle != nil {
            let wrapper = files.contains(prefix + "gradlew") ? "./gradlew" : "gradle"
            return (cd + wrapper + (build.contains("org.springframework.boot") ? " bootRun" : build.contains("io.quarkus") ? " quarkusDev" : " run"), "java")
        }
        if maven {
            let wrapper = files.contains(prefix + "mvnw") ? "./mvnw" : "mvn"
            let goal = build.contains("io.quarkus") ? "quarkus:dev" : build.contains("micronaut") ? "mn:run" : "spring-boot:run"
            return (cd + wrapper + " " + goal, "java")
        }
        return (cd + "./gradlew run", "java")
    }
}
