import Foundation

/// Front-end stories: Playwright tests written as a person would tell them ("Ana adds a mug to
/// her cart"), one file per feature and one test per scenario, each step photographed. They
/// live in a `stories/` folder inside the web app, with their own config so the project's other
/// Playwright tests stay as they are, and a small helper (`dante-story.ts`) that records every
/// step, the console, page errors and failed calls, which Dante reads to tell why a story broke.
public enum StoryKit {
    public static let folderName = "stories"
    public static let configName = "playwright.config.ts"
    public static let helperName = "dante-story.ts"
    /// Each scenario's record, written by the helper beside its screenshots.
    public static let recordName = "dante-story"
    /// Bumped when the helper changes, so Dante rewrites older copies.
    public static let version = 1
    static let marker = "Written by Dante (story kit "

    /// The stories folder for a web app in `frontend` ("" or "." for the repo root).
    public static func folder(frontend: String) -> String {
        frontend.isEmpty || frontend == "." ? folderName : frontend + "/" + folderName
    }

    /// Which kit version a file was written by, or nil for a file Dante didn't write.
    public static func version(of text: String) -> Int? {
        guard let range = text.range(of: marker) else { return nil }
        return Int(text[range.upperBound...].prefix { $0.isNumber })
    }

    /// The files to write into the stories folder: the config only when there's none (people
    /// change it), the helper when missing or written by an older kit, and a .gitignore for the
    /// run's output. `existing` reads a file in the folder by name.
    /// `ownPackage` adds a package.json for Playwright alone, for pages a backend serves, which
    /// have no node project to add it to.
    public static func files(existing: (String) -> String?, ownPackage: Bool = false) -> [(name: String, text: String)] {
        var out: [(String, String)] = []
        if existing(configName) == nil { out.append((configName, config)) }
        if ownPackage, existing("package.json") == nil { out.append(("package.json", package)) }
        if let helper = existing(helperName) {
            if let written = version(of: helper), written < version { out.append((helperName, self.helper)) }
        } else {
            out.append((helperName, self.helper))
        }
        if existing(".gitignore") == nil { out.append((".gitignore", "test-results/\nplaywright-report/\n" + (ownPackage ? "node_modules/\n" : ""))) }
        return out
    }

    /// Story files in the project, by path.
    public static func storyFiles(_ files: [String], folder: String) -> [String] {
        files.filter { $0.hasPrefix(folder + "/") && $0.hasSuffix(".story.ts") && !$0.contains("/node_modules/") }.sorted()
    }

    /// How a run goes: in the stories folder, against `baseURL`, through the project's own
    /// Playwright (never npx), reported as JSON where `TestRun` reads it. `files` (relative to
    /// the stories folder) and `grep` narrow it.
    public static func command(folder: String, baseURL: String, files: [String] = [], grep: [String] = []) -> TestCommand {
        var arguments = files.map(Shell.quote)
        if !grep.isEmpty {
            arguments += ["--grep", Shell.quote(grep.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|"))]
        }
        let script = "cd \(Shell.quote(folder)) && export STORY_BASE_URL=\(Shell.quote(baseURL)) && " + Playwright.script(arguments: arguments)
        var label = "Stories"
        if files.count == 1 { label += " · " + ((files[0] as NSString).lastPathComponent as NSString).deletingPathExtension.replacingOccurrences(of: ".story", with: "") }
        else if !grep.isEmpty { label += " · " + (grep.count == 1 ? grep[0] : "\(grep.count) scenarios") }
        var command = TestCommand(label: label, arguments: ["sh", "-c", script], readsXUnit: false)
        command.playwrightReports = [folder + "/" + Playwright.reportFile]
        return command
    }

    /// The command that adds Playwright and its Chromium to a web app: typed for the person to
    /// run, never run by Dante, since it downloads a browser.
    public static func installCommand(frontend: String, tool: String) -> String {
        let cd = frontend.isEmpty || frontend == "." ? "" : "cd \(Shell.quote(frontend)) && "
        let add = switch tool {
        case "pnpm": "pnpm add -D @playwright/test"
        case "yarn": "yarn add -D @playwright/test"
        case "bun": "bun add -d @playwright/test"
        default: "npm install -D @playwright/test"
        }
        return cd + add + " && ./node_modules/.bin/playwright install chromium"
    }

    /// The same for stories with their own package.json (`files(ownPackage:)`): Playwright goes
    /// into the stories folder, not the backend.
    public static func installCommand(storiesFolder folder: String) -> String {
        "cd \(Shell.quote(folder)) && npm install -D @playwright/test && ./node_modules/.bin/playwright install chromium"
    }

    static let package = """
    {
      "name": "stories",
      "private": true,
      "description": "Front-end stories for the pages the backend serves, run by Dante with Playwright.",
      "scripts": { "stories": "playwright test" }
    }

    """

    public static let config = """
    // \(marker)\(version)). Stories run with their own settings, so the project's other
    // Playwright tests stay as they are. Change what you like: Dante won't write it again.
    import { defineConfig, devices } from '@playwright/test';

    export default defineConfig({
      testDir: '.',
      testMatch: '**/*.story.ts',
      outputDir: 'test-results',
      workers: 1,
      retries: 0,
      timeout: 60_000,
      expect: { timeout: 7_000 },
      use: {
        // Dante passes the address the app answers on.
        baseURL: process.env.STORY_BASE_URL || 'http://localhost:5173',
        video: 'on',
        trace: 'retain-on-failure',
        actionTimeout: 10_000,
      },
      projects: [{ name: 'chromium', use: { ...devices['Desktop Chrome'] } }],
    });

    """

    public static let helper = """
    // \(marker)\(version)). Dante rewrites this file when its story kit changes:
    // keep your own helpers in another file.
    //
    // A story is a feature told as a person would: one test.describe per feature, one test per
    // scenario, tagged with what kind it is (@happy, @empty, @invalid, @error, @slow, @mobile,
    // @access), and every step in plain words through story.step. Each step is photographed;
    // the console, page errors and failed calls are recorded, so Dante can say why one broke.
    import { test as base, expect } from '@playwright/test';
    import * as fs from 'node:fs';

    export { expect };

    type Step = { title: string; status: 'passed' | 'failed'; started: number; ms: number; shot?: string; url?: string; error?: string };
    type Call = { method: string; url: string; status: number; failure?: string; body?: string; at: number; step: number; faked?: boolean };
    type Line = { type?: string; text: string; at: number; step: number };

    export type Story = {
      /** One step, said the way a person would: "Ana adds a mug to her cart". */
      step: (title: string, body: () => Promise<void>) => Promise<void>;
      /** Calls matching the pattern fail with this status, to see the screen cope. */
      failApi: (pattern: string | RegExp, status?: number, body?: string) => Promise<void>;
      /** Calls matching the pattern answer this JSON instead, for empty lists and odd data. */
      fakeApi: (pattern: string | RegExp, json: unknown, status?: number) => Promise<void>;
      /** Calls matching the pattern wait this long first. */
      slowApi: (pattern: string | RegExp, ms: number) => Promise<void>;
    };

    export const test = base.extend<{ story: Story }>({
      story: async ({ page }, use, testInfo) => {
        const steps: Step[] = [];
        const calls: Call[] = [];
        const console: Line[] = [];
        const pageErrors: Line[] = [];
        const pending: Promise<unknown>[] = [];
        const faked = new Set<string>();
        const now = () => steps.length;

        page.on('console', (m) => {
          if (m.type() === 'error' || m.type() === 'warning') console.push({ type: m.type(), text: m.text().slice(0, 2000), at: Date.now(), step: now() });
        });
        page.on('pageerror', (e) => pageErrors.push({ text: String(e.stack || e.message || e).slice(0, 4000), at: Date.now(), step: now() }));
        page.on('response', (r) => {
          if (r.status() < 400) return;
          const call: Call = { method: r.request().method(), url: r.url(), status: r.status(), at: Date.now(), step: now(), faked: faked.has(r.url()) };
          calls.push(call);
          pending.push(r.text().then((t) => { call.body = t.slice(0, 2000); }).catch(() => {}));
        });
        page.on('requestfailed', (r) => {
          calls.push({ method: r.method(), url: r.url(), status: 0, failure: r.failure()?.errorText, at: Date.now(), step: now(), faked: faked.has(r.url()) });
        });

        const step = async (title: string, body: () => Promise<void>) => {
          const record: Step = { title, status: 'passed', started: Date.now(), ms: 0 };
          steps.push(record);
          const index = steps.length;
          try {
            await base.step(title, body);
          } catch (error) {
            record.status = 'failed';
            record.error = String((error as Error)?.message ?? error).slice(0, 4000);
            throw error;
          } finally {
            record.ms = Date.now() - record.started;
            record.url = page.url();
            const file = testInfo.outputPath(`step-${String(index).padStart(2, '0')}.png`);
            try { await page.screenshot({ path: file, timeout: 5_000 }); record.shot = file; } catch {}
          }
        };
        const failApi = async (pattern: string | RegExp, status = 500, body = '{"error":"made to fail by the story"}') => {
          await page.route(pattern, (route) => { faked.add(route.request().url()); return route.fulfill({ status, contentType: 'application/json', body }); });
        };
        const fakeApi = async (pattern: string | RegExp, json: unknown, status = 200) => {
          await page.route(pattern, (route) => { faked.add(route.request().url()); return route.fulfill({ status, contentType: 'application/json', body: JSON.stringify(json) }); });
        };
        const slowApi = async (pattern: string | RegExp, ms: number) => {
          await page.route(pattern, async (route) => { await new Promise((done) => setTimeout(done, ms)); await route.continue(); });
        };

        await use({ step, failApi, fakeApi, slowApi });

        await Promise.all(pending);
        const file = testInfo.outputPath('\(recordName).json');
        fs.writeFileSync(file, JSON.stringify({
          kit: \(version),
          titlePath: testInfo.titlePath,
          tags: (testInfo as any).tags ?? [],
          annotations: testInfo.annotations,
          viewport: page.viewportSize(),
          steps, calls: calls.slice(-80), console: console.slice(-60), pageErrors: pageErrors.slice(-20),
        }));
        await testInfo.attach('\(recordName)', { path: file, contentType: 'application/json' });
      },
    });

    """
}
