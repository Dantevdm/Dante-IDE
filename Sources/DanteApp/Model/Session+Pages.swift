import AppKit
import DanteKit

extension Session {
    /// An agent's generated file, opened by Dante rather than a shell's default application.
    func openAgentFile(_ input: JSONValue, root: URL? = nil) {
        guard let root = root ?? workspace?.url, let path = input["path"]?.string else { return }
        do {
            let rules = ClaudeRules.load(projectRoot: root)
            let url = try ProjectFileOpen.resolve(path, root: root, rules: rules)
            let mode = input["mode"]?.string ?? "preview"
            guard ["preview", "code"].contains(mode) else {
                throw ProjectFileOpen.Failure(message: "Choose preview or code mode.")
            }
            if mode == "preview", ProjectFileOpen.isHTML(url) {
                htmlPresentation = HTMLPresentation(url: url, root: root, rules: rules)
            } else if let line = input["line"]?.int {
                open(file: url, line: line)
            } else if mode == "preview", root == workspace?.url, DocLibrary.isDoc(path) {
                showDoc(path)
            } else {
                open(file: url)
            }
            NSApp.activate()
            window?.makeKeyAndOrderFront(nil)
        } catch { errorMessage = error.localizedDescription }
    }

    /// Opens a page from the spec, for voice and the agents' `show_page`: an area and the view
    /// inside it, or the Settings window or the Stage. Returns a line to say about it.
    @discardableResult
    func show(_ feature: DanteFeature) -> String {
        if let line = Self.showOutsideWindow(feature) { return line }
        guard let area = Area(rawValue: feature.area) else { return "I don’t know that page." }
        if self.area != area { self.area = area }
        areaView = feature.view
        return feature.view == nil ? "Here’s \(feature.title)." : "Here’s the \(area.title)’s \(feature.title) view."
    }

    /// Settings and the Stage, which open without a project window; nil for anything else.
    static func showOutsideWindow(_ feature: DanteFeature) -> String? {
        switch feature.area {
        case "stage":
            StageController.shared.open(fullScreen: true)
            return "Here’s the Stage."
        case "settings":
            NSApp.activate()
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            return "Here are the settings."
        default:
            return nil
        }
    }

    /// A database from the Map, in Local › Data: the connection for its compose service or
    /// container, and a table opened when one is named.
    func showInData(service: String?, table: String? = nil) {
        data.focus = (service, table)
        if area != .data { area = .data }
    }
}
