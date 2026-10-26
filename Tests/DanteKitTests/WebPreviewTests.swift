import Foundation
import Testing
@testable import DanteKit

/// Opening a frontend's screen in the browser: the port, the path and the start command.
struct WebPreviewTests {
    static let files: [String: String] = [
        "web/package.json": #"{"name":"web","scripts":{"dev":"vite","build":"vite build"},"dependencies":{"react":"18","react-router-dom":"6"},"devDependencies":{"vite":"5"}}"#,
        "web/vite.config.ts": "export default defineConfig({\n  server: {\n    port: 5180,\n  },\n})",
        "web/pnpm-lock.yaml": "",
        "web/src/main.tsx": """
        import { OrdersPage } from './pages/OrdersPage'
        import { OrderPage } from './pages/OrderPage'
        import { HomePage } from './pages/HomePage'
        const router = createBrowserRouter([
          { index: true, element: <HomePage /> },
          { path: "/orders", element: <OrdersPage /> },
          { path: "/orders/:id", element: <OrderPage /> },
        ])
        """,
        "web/src/pages/OrdersPage.tsx": "export function OrdersPage() {}",
        "web/src/pages/OrderPage.tsx": "export function OrderPage() {}",
        "web/src/pages/HomePage.tsx": "export function HomePage() {}",
        "site/package.json": #"{"scripts":{"dev":"next dev -p 3005"},"dependencies":{"next":"14"}}"#,
        "site/app/(shop)/basket/page.tsx": "export default function Page() {}",
        "site/app/orders/[id]/page.tsx": "export default function Page() {}",
        "admin/package.json": #"{"scripts":{"start":"react-scripts start"},"dependencies":{"react":"18","react-scripts":"5"}}"#,
        "admin/.env": "PORT=4100\nAPI_KEY=x",
        "admin/src/App.jsx": "<HashRouter><Routes><Route path=\"settings\" element={<Settings />} /></Routes></HashRouter>",
        "admin/src/views/Settings.jsx": "export default function Settings() {}",
    ]
    static var paths: [String] { Array(files.keys) }
    static func read(_ path: String) -> String? { files[path] }

    func target(_ folder: String, _ screen: String, _ file: String?) -> WebPreview.Target {
        WebPreview.target(folder: folder, name: folder, screen: (screen, file), files: Self.paths, read: Self.read)
    }

    @Test func viteAndReactRouter() {
        let orders = target("web", "OrdersPage", "web/src/pages/OrdersPage.tsx")
        #expect(orders.port == 5180 && orders.portSource == "vite.config.ts")
        #expect(orders.path == "/orders" && orders.routeFound)
        #expect(orders.command == "cd web && pnpm dev")
        #expect(orders.url.absoluteString == "http://localhost:5180/orders")
        // A screen behind an id opens where the ids are listed; the index route is home.
        #expect(target("web", "OrderPage", "web/src/pages/OrderPage.tsx").path == "/orders")
        #expect(target("web", "HomePage", "web/src/pages/HomePage.tsx").path == "/")
    }

    @Test func nextFoldersArePaths() {
        let basket = target("site", "basket", "site/app/(shop)/basket/page.tsx")
        #expect(basket.port == 3005 && basket.portSource == "package.json")
        #expect(basket.path == "/basket")
        #expect(target("site", "orders/:id", "site/app/orders/[id]/page.tsx").path == "/orders")
        #expect(target("site", "orders/:id", "site/app/orders/[id]/page.tsx").command == "cd site && npm run dev")
    }

    @Test func envPortAndHashRouter() {
        let settings = target("admin", "Settings", "admin/src/views/Settings.jsx")
        #expect(settings.port == 4100 && settings.portSource == ".env")
        #expect(settings.path == "/#/settings")
        #expect(settings.command == "cd admin && npm run start")
        // Unknown screens open the app.
        let unknown = target("admin", "Missing", nil)
        #expect(unknown.path == "/" && !unknown.routeFound)
    }

    @Test func saysWhatHasToHappenBeforeStarting() {
        let files = ["web/package.json", "web/pnpm-lock.yaml", "web/src/main.tsx"]
        let target = WebPreview.target(folder: "web", name: "web", files: files) { $0 == "web/package.json" ? #"{"scripts":{"dev":"vite"}}"# : nil }
        #expect(target.command == "cd web && pnpm dev" && target.installCommand == "cd web && pnpm install" && target.tool == "pnpm")
        let installed: Set<String> = ["web/package.json", "web/node_modules"]
        #expect(WebPreview.missing(target, exists: installed.contains, which: { _ in "/usr/local/bin/pnpm" }) == nil)
        #expect(WebPreview.missing(target, exists: ["web/package.json"].contains, which: { _ in "/usr/local/bin/pnpm" }) == .dependencies)
        #expect(WebPreview.missing(target, exists: installed.contains, which: { _ in nil }) == .tool("pnpm"))
        #expect(WebPreview.stopped(127, tool: "pnpm").contains("pnpm install"))
    }

    @Test func runsThroughComposeWhenAServiceBuildsTheFolder() {
        let files = ["services/web/package.json", "services/web/vite.config.ts"]
        let target = WebPreview.target(folder: "services/web", name: "web", files: files) {
            $0.hasSuffix("package.json") ? #"{"scripts":{"dev":"vite"},"devDependencies":{"vite":"5"}}"# : nil
        }
        #expect(target.port == 5173 && target.service == nil)
        let compose = ComposeFile(services: [
            .init(name: "db", image: "postgres:17", ports: ["5433:5432"]),
            .init(name: "frontend", build: "./services/web", ports: ["127.0.0.1:8080:5173"]),
        ])
        let viaCompose = WebPreview.throughCompose(target, compose: compose)
        #expect(viaCompose?.service == "frontend" && viaCompose?.port == 8080)
        #expect(viaCompose?.command == "docker compose up -d frontend" && viaCompose?.tool == "docker")
        #expect(viaCompose?.url.absoluteString == "http://localhost:8080/")
        // Only Docker is needed: no node_modules check.
        #expect(viaCompose.map { WebPreview.missing($0, exists: { _ in false }, which: { _ in "/usr/local/bin/docker" }) } == .some(nil))
        #expect(viaCompose.map { WebPreview.missing($0, exists: { _ in false }, which: { _ in nil }) } == .tool("docker"))
        // Another published port when the dev server's isn't mapped; none at all isn't reachable.
        let nginx = ComposeFile(services: [.init(name: "web", build: "services/web", ports: ["3000:80"])])
        #expect(WebPreview.throughCompose(target, compose: nginx)?.port == 3000)
        let unpublished = ComposeFile(services: [.init(name: "web", build: "services/web", ports: ["5173"])])
        #expect(WebPreview.throughCompose(target, compose: unpublished) == nil)
        #expect(WebPreview.throughCompose(target, compose: ComposeFile(services: [.init(name: "db", image: "postgres")])) == nil)
        #expect(WebPreview.stopped(1, tool: "docker").contains("docker compose"))
    }
}
