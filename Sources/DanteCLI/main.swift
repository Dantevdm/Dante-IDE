import DanteOpen
import Foundation

// `dante`: opens folders and files in Dante from the terminal. It lives in Dante.app at
// Contents/Resources/bin/dante and hands a dante://open URL to the app it's inside.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("dante: \(message)\n".utf8))
    exit(1)
}

/// The app this command is inside (following the symlink on the PATH), else the installed one.
func danteApp() -> URL? {
    if let path = Bundle.main.executablePath {
        let app = URL(filePath: path).resolvingSymlinksInPath()
            .deletingLastPathComponent() // bin
            .deletingLastPathComponent() // Resources
            .deletingLastPathComponent() // Contents
            .deletingLastPathComponent()
        if app.pathExtension == "app" { return app }
    }
    let found = Process()
    found.executableURL = URL(filePath: "/usr/bin/mdfind")
    found.arguments = ["kMDItemCFBundleIdentifier == 'dev.dante.ide'"]
    let pipe = Pipe()
    found.standardOutput = pipe
    try? found.run()
    found.waitUntilExit()
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    return output.split(separator: "\n").first.map { URL(filePath: String($0)) }
}

let command: OpenRequest.Command
do {
    command = try OpenRequest.parse(
        arguments: Array(CommandLine.arguments.dropFirst()),
        in: FileManager.default.currentDirectoryPath,
        exists: { FileManager.default.fileExists(atPath: $0) }
    )
} catch {
    fail("\(error)")
}

switch command {
case .help:
    print(OpenRequest.usage)
case .version:
    let info = danteApp().flatMap { Bundle(url: $0)?.infoDictionary }
    print("Dante \(info?["CFBundleShortVersionString"] as? String ?? "(not found)")")
case .open(let request):
    guard let app = danteApp() else { fail("can't find Dante.app") }
    let open = Process()
    open.executableURL = URL(filePath: "/usr/bin/open")
    open.arguments = ["-a", app.path, request.url.absoluteString]
    do {
        try open.run()
        open.waitUntilExit()
    } catch {
        fail("couldn't open Dante: \(error.localizedDescription)")
    }
    exit(open.terminationStatus)
}
