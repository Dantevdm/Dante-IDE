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
        // A workspace member: its packages are hoisted to the repo root.
        #expect(WebPreview.missing(target, exists: ["web/package.json", "node_modules"].contains, which: { _ in "/usr/local/bin/pnpm" }) == nil)
        #expect(WebPreview.needsInstall(folder: "apps/web", exists: ["apps/web/package.json", "apps/node_modules"].contains) == false)
        #expect(WebPreview.needsInstall(folder: "", exists: ["package.json"].contains))
        #expect(WebPreview.stopped(127, tool: "pnpm").contains("pnpm install"))
    }
}
