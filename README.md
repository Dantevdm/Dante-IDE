<p align="center"><img src="docs/images/icon.png" width="128" alt="Dante's icon"></p>

<h1 align="center">Dante</h1>

<p align="center">A native macOS IDE where Claude and Codex work beside you, and Dante shows you the whole system they're working on.</p>

Dante reads a project and draws it: screens, API routes, packages, tables, outside services, pipelines and infrastructure, straight from the code. Claude or Codex leads, the other reviews, and local models take the small jobs. Every edit arrives as a diff you approve, a whole turn can be undone, and jobs run in their own worktrees beside you.

![The system map: clients, API routes, backend, data and outside services, with test coverage](docs/images/map.jpg)

| | |
| --- | --- |
| ![The editor with Claude beside it](docs/images/code.jpg) | ![Docs with a sequence diagram drawn natively](docs/images/docs.jpg) |

## Install

Download the DMG from [Releases](https://github.com/Dantevdm/Dante-IDE/releases), open it and drag Dante to Applications. Builds that aren't notarised yet need a right-click → Open the first time (or `xattr -dr com.apple.quarantine /Applications/Dante.app`).

To open projects from the terminal, Settings → Tools → dante command links `dante` onto your PATH; then `dante .`, `dante -n ~/other-project` or `dante src/main.go:42`.

You'll want [Claude Code](https://claude.com/claude-code) installed and signed in for the Claude features, and git. Settings → Tools lists the optional extras (language servers, database clients, the GitHub CLI, Docker) with the command to install each.

## The places

The rail has seven places; some have tabs.

- **Home**: the project at a glance, and what changed since you were last here
- **Map**: the system from the code itself: screens, API routes, packages, tables, outside services and webhooks, with coverage, open routes, table schemas and index suggestions; open any part to see inside it, down to a method's code; an Infra view of CloudFormation, Terraform, ARM and the pipelines that ship them
- **Code**: a TextKit 2 editor with tree-sitter highlighting, language servers, split panes, git gutter and blame, search (by text or by meaning) and replace, a debugger, merge conflicts, and ⌘I to edit with the agent
- **Quality**: Tests (run everything, only what your changes touch, or one test; history, flaky tests, untested code) and Security (secrets, POPIA personal information, dependencies, code and infrastructure, ranked, with fixes)
- **Local**: Services (Docker Compose with logs and port conflicts explained, the apps in the code), Data (Postgres, MySQL and SQLite browsing, query plans, migration previews) and Health (alarms, health checks, production logs)
- **Ship**: Release (changelog, CI, tags) and History (commits, agent sessions, test runs and CI in one stream)
- **Agents**: Jobs (agents working beside you in their own worktrees, with an inbox and away mode), Activity (who did what, local models included) and Setup (skills, memory, connectors, plugins, permissions)
- **Docs**, in the footer: markdown with native Mermaid diagrams, PDFs and Word files, and the motion studio

Beside them: the agent panel (Claude or Codex in charge, diffs to approve, undo a turn, `@file` and `/` commands), the menu bar orb that shows what the agents are doing, the Stage (Dante full screen on a TV), and voice (push to talk, replies read aloud in a natural voice).

<details>
<summary><b>Everything that works today</b></summary>


- Launch screen with recent projects, plus new project, open folder and clone
- Dark, Light and Paper themes (⌥⌘T to cycle), set in Geist and Geist Mono (bundled; a setting switches to the system fonts)
- File explorer, tabs, and a TextKit 2 code editor with tree-sitter highlighting (Swift, Python, JavaScript, TypeScript, Go, Rust, JSON; regex for the rest), line numbers and auto-indent
- Language servers for diagnostics, hover info (rest the pointer on a symbol) Jump to Definition (⌘-click or ⌃⌘J) and Go to Symbol (⌘⇧O: the file's symbols, then matches across the project, with Dante's own declaration scan where no server covers a language or its index is empty): SourceKit-LSP, typescript-language-server, Pyright, gopls, rust-analyzer and clangd, whichever are installed. Problems are underlined, marked in the gutter, listed from the status bar and gathered for the whole project in the sidebar's Problems tab (⇧⌘M), and Fix hands one, or all of them, to Claude. Claude always sees the open file's problems
- Split editor (⌘\): two panes side by side over the same tabs; a tab opens in the focused pane (marked in its path bar), click a pane or press ⌥⌘\ to switch, × closes the split
- Code completion from the language server as you type (or ⌃Space), fuzzy-filtered, with snippets whose first placeholder is selected; Tab or Return accepts. Find References (⌃⇧⌘F) lists every use in the Search tab; Rename Symbol (⌃⌘E) renames across open and closed files; Format Document (⌃⇧I). Rename and format are undoable
- Remote projects (⌃⌘O): open a folder on another machine over ssh. Dante keeps a copy here in step with rsync, and runs git, tests, Claude Code, the terminal, Docker and database clients, and the language servers it finds on the host, forwarding service ports here. Needs ssh keys or an agent, and rsync on the host
- Debugger (Debug tab, F5): click a line number to set a breakpoint, then run the open file's Go package (Delve) or Python script (debugpy) through the Debug Adapter Protocol. Paused lines are highlighted; the tab shows the call stack, variables to expand, the program's output and an Evaluate field. Step over, into and out with F6, F7 and F8, F9 toggles a breakpoint, ⇧F5 stops. Breakpoints are kept per project on this Mac
- Claude in the editor: ⌘I (or Edit with Claude… in the editor's menu) opens a bar above the code. Describe a change to the selected lines, or code to write at the caret; Claude's proposal shows as a diff to accept (⌘↩), refine with another instruction, or reject. Nothing changes until you accept, and accepting is one undo. Ask Claude About Selection attaches the selected lines to the Claude panel
- Settings (⌘,): theme, font size and Geist or system fonts; indent width, line wrapping and completion while typing; on save, format with the language server, trim trailing whitespace and end with a newline; auto-save after a delay or when Dante loses focus; Claude's model and whether it asks clarifying questions first
- Git changes in the gutter: added, modified and deleted lines since the last commit, updated as you type and when HEAD moves
- Blame for the caret's line in the status bar (who and when; unsaved edits show as not committed yet). Click it for the commit, Show Commit, Copy Hash or the line's whole history
- Find in Project (⇧⌘F): search every file (open ones as edited) with match case, whole word and regex, grouped by file; click a result to open it with the match selected. The chevron opens Replace: each result previews its change, hover to replace one match, a file, or leave a match out, and Replace All (⌥⌘↩) asks first. Open files change in the editor, undoable; others are saved
- Integrated terminal running your login shell (⌃`)
- Claude pair panel (⌘L): runs Claude Code headless in the project. Every edit arrives as a diff to apply or decline, and commands wait for your go-ahead at the approval level you choose. It sees which file you have open
- Command palette (⌘K, or ⌘P for files): fuzzy file search, docs, actions, and Tab to ask Claude
- Live file watching: the explorer, open tabs and branch stay current when files change outside the editor
- Home: the project at a glance, with recent commits, local services, and what Claude is told about the project. When you come back to a project, "Since you were last here" lists the commits, changed files and any branch switch since Dante last closed it
- Explorer: new file and new folder buttons (type `folders/like/this.swift` to create the folders too), and right-click to rename, duplicate, move to the Trash, copy paths or ask Claude about a file. ⌘-click and ⇧-click select several items, and the menu, ⌘C, ⌘V and ⌫ act on all of them. Copy files or folders in Finder and paste them into a folder (⌘V or Paste), or drop them from Finder to copy them in; drag files onto folders to move them (open tabs follow). Changed files are coloured by their git status
- Source control: a Changes tab beside Explorer and Search lists staged, unstaged and conflicted files; click one for its diff, hover to stage, unstage or discard (new files go to the Trash). Commit with ⌘↩ (everything, when nothing is staged), amend, or commit and push; ✦ has Claude write the message from the staged diff in the repository's own style. The branch in the title bar switches, creates and publishes branches, and shows ↑↓ to push or pull. Git menu: Source Control (⌃⇧G), Push, Pull, Fetch, Switch Branch (⌃⇧B)
- Docs: renders the project's markdown with an outline and opens files it mentions. ```mermaid blocks (flowcharts, sequence and ER diagrams) are drawn natively in the theme's colours. PDFs, images and Word files under docs/ show alongside; drop files on Docs to add them, then ask Claude about one or have it written up as a markdown spec. Markdown images render inline. Export a doc as a PDF or print it (⇧⌘E, ⌘P), set in the Paper theme with page breaks between blocks. Switch a doc between Preview, Markdown and Side by Side: edit the source without leaving Docs, with a live preview that follows the cursor; it shares unsaved changes and ⌘S with the Code tab
- Attach files for Claude: drop, paste or pick images, PDFs, Word/RTF/HTML documents or code into the Claude panel. Images and PDFs go to Claude as themselves; documents are converted to text
- Claude asks before it guesses: with Ask first on (the default), Claude asks clarifying questions before ambiguous work, and you answer them as cards in the panel
- Back and forward through the screens you've visited: the mouse's back and forward buttons, ⌃⌘← / ⌃⌘→, or the arrows in the title bar
- Several terminals as tabs (⌃⇧` for a new one); hidden tabs keep running
- Cloning shows git's progress, and if the server wants a password git can't ask for, Dante finishes the clone in Terminal and opens it when done
- Layouts follow the window: pages fill wide and ultra-wide screens, panels can be dragged much wider, and Docs can switch to full width
- Tests (⌘U): runs the project's tests (Swift, cargo, go, npm/pnpm/yarn/bun, pytest, or `test.command`), groups results by suite, re-runs just the failures (⇧⌘U) or any single test, and hands failures to Claude. Written lists every test in the code by category (Unit, Integration, End-to-end, UI, Performance, or your own from `test.categories` globs in project.yaml) and file, with each one's last result; results can be grouped by category too. History charts runs on this Mac and flags flaky and long-failing tests. Untested lists the functions and types no test names, logic before views, with Write tests per file and a concrete brief for Claude
- Env: Docker Compose services with start, stop, logs, and Dockerfiles that are missing. Logs follow every service or one, with search (highlighted, or only matching lines), a level filter, the app's timestamps set apart, errors and warnings marked, and copy. They open at the newest line and stay there as lines arrive; scroll up to read back (following stops) and Jump to latest to return. The last 500 lines load by default, or 2,000, 10,000 or everything. Start and Rebuild show compose's output as it runs, and each service that isn't up says why: a failing health check (with the check's own error), a port something else on this Mac already holds, or a dependency it's waiting on. Find the cause hands that to Claude. A Ports card shows every port the compose file publishes and anything else listening that was started from the project, with the process, its command line and uptime; Stop asks it to quit. Before each start Dante checks the ports and, if one is taken, offers to stop what holds it, publish the service on the next free port (editing only that line of the compose file), or start anyway
- Data: the project's databases (PostgreSQL, MySQL, SQLite). Dante finds them in compose files, `.env` URLs, Prisma/Rails/Django config and SQLite files, and says what the code uses (drivers, ORMs, migrations) even before there's a database. Browse tables a page at a time with sorting and a WHERE filter, see columns and foreign keys both ways, run SQL scripts in one session (⌘↩, with a check before anything that drops or rewrites whole tables), explain queries (with the tables read row by row to filter, the index that would help, and Claude to talk the plan through), preview what a script or migration file changes before it runs (checked against the live schema: missing tables, NOT NULL columns with no default, locking index builds, rows a drop deletes), export results, and see the live schema as an ER diagram you can save to docs. New database sets up a Docker Compose service (or a SQLite file) with a generated password in `.env`, on a free port, and starts it. Talks through `psql`, `mysql` and `sqlite3`, or the client inside the compose container; passwords live in the Keychain, connections stay on this Mac, and anything not on this Mac opens read-only. Claude writes queries from a description and fixes failing ones, with the schema as context
- Map: the system map (clients and their screens, API route groups, backend packages, data stores and tables, outside services and webhooks, linked by real calls), plus modules from `Package.swift` or Go imports and compose services; an inspector with environment variables and coverage, drift against `.dante/architecture.md`, and a Mermaid export into it
- Ship: CI runs from `gh`, a changelog drafted from conventional commits since the last tag, a release checklist, and local tagging.
- Health: alarms, health checks and a production log stream from `operate:` in `.dante/project.yaml`. Alarms come from CloudWatch (read-only, through the `aws` command line and its existing login) or any command that prints them as JSON (`[{ name, state, reason, updated, url }]`, for Datadog, Grafana, Alertmanager…). Firing alarms sort first; Investigate hands the alarm and matching log errors to Claude, and Notify me (off by default) sends a macOS notification when one starts firing. Log errors are grouped
- Timeline: commits and tags, Claude Code sessions run in the project folder, test runs and GitHub Actions runs in one stream grouped by day. Click a commit to show it, a Claude session to resume it in the terminal, a CI run to open it
- Claude rules in `.dante/project.yaml` (`claude: propose / flag / never`): flagged paths are called out on the diff, and never-paths are refused, reads included
- Quitting with unsaved files asks once for every window: save, discard or cancel

</details>

## Roadmap

Dante's own task list is [`.dante/tasks.yaml`](.dante/tasks.yaml); this is the short version.

**In progress**

- **Motion studio** (Docs): videos, slide decks and explainers made by the agents from the real system, in the project's brand, narrated in Dante's voice and rendered to 1080p or 4K. New piece asks like a studio: the idea, the look (a live gallery of twenty animation styles, from particles and clay 3D to split-flap and blueprint, plus illustration kits), the brief, and whether Claude, Codex or both make it. three.js, hairline and Open Peeps come bundled. Still to come: switching between and comparing two makers' versions, lint findings and a partner's critique in the player, HTML and PDF export, and presenting decks on the Stage. ([plan](docs/plans/motion-studio.md))
- **Walk and work**: jobs, away mode and job types are in ([plan](docs/plans/walk-and-work.md)); next are away budgets, then an iPhone and iPad companion (QR pairing, a voice loop with AirPods, Live Activities and actionable notifications, an iPad desk layout) and a verifier that drives its own browser.

**Next**

- **Agent HQ**: the agents as little people in an isometric office around a glowing brain (shared memory). Rooms are roles (research, backend, front-end, DevOps, quality, docs, security, data), each a job or job type you can hire for, with roads of light between them, thoughts made from their real tool calls, a sub-agent bay, a task board and a team panel. Frontier models are drawn in light, cloud models in dashed light coming in through the door that leaves the Mac, local models as pixel people. On the Stage and in the menu bar too.
- **Discovery**: a freshly opened project paints the picture of everything Dante found, on Home.
- **Motion everywhere**: the Infra view's animated links and pulses in Tests, Data, Services and Agents.
- **Hands**: let an agent open apps and control the Mac, with a visible kill switch (needs Accessibility, asked first).

**Waiting for review** (built, being tried in daily use)

Presence orb and constellation, the Stage, full voice, Codex or Claude in charge, local models and Looker, search by meaning, the security layer, cloud agents with your own keys, approvals, remote projects over SSH, the debugger, the native Settings window, alarms in Health, and the release build.

## Requirements

- macOS 15 or later
- Xcode 16 or later (Swift 6)
- [Claude Code](https://claude.com/claude-code), installed and signed in (`claude auth login`), for the Claude panel

## Build from source

```bash
scripts/bundle.sh --open
```

This builds a release binary and wraps it in `build/Dante.app`. Use `scripts/bundle.sh debug --open` for a debug build. To open a folder straight away:

```bash
open build/Dante.app --args ~/path/to/project
```

Files after the folder open in tabs: `--args ~/project ~/project/Sources/main.swift`.

`scripts/release.sh 0.2.0` builds `build/Dante-0.2.0.dmg`; it signs and notarises when `DEVELOPER_ID` and `NOTARY_PROFILE` are set (see the script).

Run the tests:

```bash
swift test
```

## Layout

| Path | What's there |
| --- | --- |
| `Sources/DanteKit` | Models: themes, workspace, documents, git, the Claude Code and Codex sessions, agents, security, search, motion, and the data behind each place (Docs, Testing, Environments, Data, Map, Infra, Release, Operate) |
| `Sources/DanteEditor` | The TextKit 2 editor, line-number gutter, highlighters and bundled fonts |
| `Sources/DanteApp` | The SwiftUI app: launch screen, workspace, the place screens (`Views/Areas`), the motion studio (`Views/Motion`, with the bundled libraries in `Resources/MotionLib`), presence, voice, terminal, menus |
| `spec/` | A spec for every page, which voice and the agents use to find their way |
| `Tests/` | Swift Testing suites for DanteKit and DanteEditor |
| `design/` | Generator for the design canvas and its HTML screens |
| `.dante/` | Dante's own project spec |

## The `.dante` folder

Everything here is optional; Dante works out the rest from the code.

```yaml
# .dante/project.yaml
name: My App
claude:                        # rules for Claude and Codex
  never: [secrets/, "**/*.pem"]   # refused, reads included
  flag: [migrations/]          # called out on the diff
  propose: [src/, tests/]      # edits elsewhere get a note
test:
  command: make test           # otherwise Dante works it out
  categories:
    Integration: ["tests/integration/**"]
operate:
  checks:
    - { name: api, url: "https://api.example.com/health" }
  logs: fly logs -a my-app     # any command that streams production logs
```

- `brand.yaml`: colours, fonts, logo, motion and voice for the motion studio (written from the project's own styles the first time)
- `security.yaml`: accepted risks, each with a reason
- `jobs/<id>.md`: job types (when one starts, what it may touch and run, the brief)
- `architecture.md`: notes the Map checks for drift, and where it exports its Mermaid diagram
- `tasks.yaml`: a plain task list, if you keep one

Dante's own `.dante/` folder is a working example.

Geist and Geist Mono are © The Geist Project Authors, from [vercel/geist-font](https://github.com/vercel/geist-font), under the SIL Open Font License 1.1 (`Sources/DanteEditor/Resources/Fonts/OFL.txt`).
