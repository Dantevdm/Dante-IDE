import Foundation

/// Where the spec's files are: in the resource bundle next to the app or the `dante` command,
/// or, in a checkout, this folder. Found without `Bundle.module`, which traps when the bundle
/// isn't where it expects (the command runs from Contents/Resources/bin).
public enum DanteSpec {
    public static let folder: URL? = locate()

    static func locate() -> URL? {
        let name = "Dante_DanteSpec.bundle"
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL { candidates.append(resources.appending(path: name)) }
        if let executable = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent() {
            candidates += [executable.appending(path: name), executable.deletingLastPathComponent().appending(path: name)]
        }
        candidates += Bundle.allBundles.map { $0.bundleURL.deletingLastPathComponent().appending(path: name) }
        for candidate in candidates {
            if let resources = Bundle(url: candidate)?.resourceURL, has(resources) { return resources }
        }
        let source = URL(filePath: #filePath).deletingLastPathComponent()
        return has(source) ? source : nil
    }

    private static func has(_ folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appending(path: "places.yaml").path)
    }
}
