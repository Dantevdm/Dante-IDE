import Foundation

/// Finds a file in a SwiftPM resource bundle. SwiftPM puts `<bundle>.bundle` next to the binary
/// and the app bundle copies them into Contents/Resources, but the generated `Bundle.module`
/// looks beside the .app and then in this Mac's build folder (and traps when both are missing),
/// so it would work here and crash anywhere else. Under `swift test` the main bundle is
/// SwiftPM's helper, so the search also starts from the image this code was loaded from.
public enum ResourceBundles {
    public static func url(bundle: String, path: String) -> URL? {
        var folders = [Bundle.main.resourceURL, Bundle.main.executableURL?.deletingLastPathComponent()].compactMap { $0 }
        var info = Dl_info()
        if dladdr(#dsohandle, &info) != 0, let image = info.dli_fname {
            var folder = URL(filePath: String(cString: image)).deletingLastPathComponent()
            for _ in 0..<4 {
                folders += [folder, folder.appending(path: "Resources")]
                folder = folder.deletingLastPathComponent()
            }
        }
        for folder in folders {
            for relative in [path, "Contents/Resources/\(path)"] {
                let url = folder.appending(path: "\(bundle).bundle/\(relative)")
                if FileManager.default.fileExists(atPath: url.path) { return url }
            }
        }
        return nil
    }
}
