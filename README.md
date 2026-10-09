# Dante

A native macOS IDE organised around the whole software lifecycle: Discover, Define, Design, Build, Test, Release, Operate. Claude works alongside you as a pair, proposing changes you approve.

Dante keeps a project's plan, tasks, docs and decisions in the repo under `.dante/`, so you and Claude are reading the same source of truth.

**Status:** milestone 3. Every lifecycle area has a working screen: Home, Plan, Map, Code, Tests, Env, Ship, Run, Docs and Spec, and the editor has tree-sitter highlighting and language servers. See the [design canvas](https://claude.ai/artifact/KFxwBAj14jL7w1MHNcc5Pi).

## What works today

- Launch screen with recent projects, plus new project, open folder and clone
- Dark, Light and Paper themes (⌥⌘T to cycle), set in Geist and Geist Mono (bundled; a setting switches to the system fonts)
- File explorer, tabs, and a TextKit 2 code editor with tree-sitter highlighting (Swift, Python, JavaScript, TypeScript, Go, Rust, JSON; regex for the rest), line numbers and auto-indent
- Language servers for diagnostics, hover info (rest the pointer on a symbol) Jump to Definition (⌘-click or ⌃⌘J) and Go to Symbol (⌘⇧O: the file's symbols, then matches across the project, with Dante's own declaration scan where no server covers a language or its index is empty): SourceKit-LSP, typescript-language-server, Pyright, gopls, rust-analyzer and clangd, whichever are installed. Problems are underlined, marked in the gutter, listed from the status bar and gathered for the whole project in the sidebar's Problems tab (⇧⌘M), and Fix hands one, or all of them, to Claude. Claude always sees the open file's problems
- Split editor (⌘\): two panes side by side over the same tabs; a tab opens in the focused pane (marked in its path bar), click a pane or press ⌥⌘\ to switch, × closes the split
- Code completion from the language server as you type (or ⌃Space), fuzzy-filtered, with snippets whose first placeholder is selected; Tab or Return accepts. Find References (⌃⇧⌘F) lists every use in the Search tab; Rename Symbol (⌃⌘E) renames across open and closed files; Format Document (⌃⇧I). Rename and format are undoable
- Claude in the editor: ⌘I (or Edit with Claude… in the editor's menu) opens a bar above the code. Describe a change to the selected lines, or code to write at the caret; Claude's proposal shows as a diff to accept (⌘↩), refine with another instruction, or reject. Nothing changes until you accept, and accepting is one undo. Ask Claude About Selection attaches the selected lines to the Claude panel
- Settings (⌘,): theme, font size and Geist or system fonts; indent width, line wrapping and completion while typing; on save, format with the language server, trim trailing whitespace and end with a newline; auto-save after a delay or when Dante loses focus; Claude's model and whether it asks clarifying questions first
- Git changes in the gutter: added, modified and deleted lines since the last commit, updated as you type and when HEAD moves
- Blame for the caret's line in the status bar (who and when; unsaved edits show as not committed yet). Click it for the commit, Show Commit, Copy Hash or the line's whole history
- Find in Project (⇧⌘F): search every file (open ones as edited) with match case, whole word and regex, grouped by file; click a result to open it with the match selected. The chevron opens Replace: each result previews its change, hover to replace one match, a file, or leave a match out, and Replace All (⌥⌘↩) asks first. Open files change in the editor, undoable; others are saved
- Integrated terminal running your login shell (⌃`)
- Claude pair panel (⌘L): runs Claude Code headless in the project. Every edit arrives as a diff to apply or decline, and every command waits for your go-ahead. Claude knows the `.dante` format and the current phase, and sees which file you have open
- Command palette (⌘K, or ⌘P for files): fuzzy file search, docs, actions, and Tab to ask Claude
- Live file watching: the explorer, open tabs and branch stay current when files change outside the editor
- Plan: lifecycle phases, "ready" and "done" checklists from `.dante/phases/<phase>.md`, and a drag-and-drop task board stored in `.dante/tasks.yaml`. "Work on this with Claude" hands a task to the pair panel
- Lifecycle ribbon read from `.dante/project.yaml`; click a phase to open it in Plan
- Home: the project at a glance, with the lifecycle timeline, the current phase's tasks, recent commits, local services, and what Claude is told about the project. When you come back to a project, "Since you were last here" lists the commits, changed files, task moves and any branch switch since Dante last closed it
- Explorer: new file and new folder buttons (type `folders/like/this.swift` to create the folders too), and right-click to rename, duplicate, move to the Trash, copy paths or ask Claude about a file. ⌘-click and ⇧-click select several items, and the menu, ⌘C, ⌘V and ⌫ act on all of them. Copy files or folders in Finder and paste them into a folder (⌘V or Paste), or drop them from Finder to copy them in; drag files onto folders to move them (open tabs follow). Changed files are coloured by their git status
- Source control: a Changes tab beside Explorer and Search lists staged, unstaged and conflicted files; click one for its diff, hover to stage, unstage or discard (new files go to the Trash). Commit with ⌘↩ (everything, when nothing is staged), amend, or commit and push; ✦ has Claude write the message from the staged diff in the repository's own style. The branch in the title bar switches, creates and publishes branches, and shows ↑↓ to push or pull. Git menu: Source Control (⌃⇧G), Push, Pull, Fetch, Switch Branch (⌃⇧B)
- Finish a task (Git › Finish Task…, or Finish on an in-progress card): makes a branch named for the task when you're on the default branch, commits with a message Claude drafts, pushes, opens a pull request with a title and description Claude drafts (via the GitHub CLI), and moves the task to review. Every draft is editable first, and a failed step can be retried from where it stopped
- Docs: renders the project's markdown with an outline, links tasks that use a doc as their spec, and opens files it mentions. ```mermaid blocks (flowcharts, sequence and ER diagrams) are drawn natively in the theme's colours. PDFs, images and Word files under docs/ show alongside; drop files on Docs to add them, then ask Claude about one or have it written up as a markdown spec. Markdown images render inline. Export a doc as a PDF or print it (⇧⌘E, ⌘P), set in the Paper theme with page breaks between blocks. Switch a doc between Preview, Markdown and Side by Side: edit the source without leaving Docs, with a live preview that follows the cursor; it shares unsaved changes and ⌘S with the Code tab
- Attach files for Claude: drop, paste or pick images, PDFs, Word/RTF/HTML documents or code into the Claude panel. Images and PDFs go to Claude as themselves; documents are converted to text
- Claude asks before it guesses: with Ask first on (the default), Claude asks clarifying questions before ambiguous work, and you answer them as cards in the panel
- Back and forward through the screens you've visited: the mouse's back and forward buttons, ⌃⌘← / ⌃⌘→, or the arrows in the title bar
- Several terminals as tabs (⌃⇧` for a new one); hidden tabs keep running
- Cloning shows git's progress, and if the server wants a password git can't ask for, Dante finishes the clone in Terminal and opens it when done
- Layouts follow the window: pages fill wide and ultra-wide screens, panels can be dragged much wider, and Docs can switch to full width
- Spec: the `.dante` folder with validation, plus exactly what Claude receives and roughly how many tokens it costs
- Tests (⌘U): runs the project's tests (Swift, cargo, go, npm/pnpm/yarn/bun, pytest, or `test.command`), groups results by suite, re-runs just the failures (⇧⌘U) or any single test, and hands failures to Claude
- Env: Docker Compose services with start, stop, logs, and Dockerfiles that are missing. Start and Rebuild show compose's output as it runs, and each service that isn't up says why: a failing health check (with the check's own error), a port something else on this Mac already holds, or a dependency it's waiting on. Find the cause hands that to Claude
- Data: the project's databases (PostgreSQL, MySQL, SQLite). Dante finds them in compose files, `.env` URLs, Prisma/Rails/Django config and SQLite files, and says what the code uses (drivers, ORMs, migrations) even before there's a database. Browse tables a page at a time with sorting and a WHERE filter, see columns and foreign keys both ways, run SQL scripts in one session (⌘↩, with a check before anything that drops or rewrites whole tables), explain queries (with the tables read row by row to filter, the index that would help, and Claude to talk the plan through), preview what a script or migration file changes before it runs (checked against the live schema: missing tables, NOT NULL columns with no default, locking index builds, rows a drop deletes), export results, and see the live schema as an ER diagram you can save to docs. New database sets up a Docker Compose service (or a SQLite file) with a generated password in `.env`, on a free port, and starts it. Talks through `psql`, `mysql` and `sqlite3`, or the client inside the compose container; passwords live in the Keychain, connections stay on this Mac, and anything not on this Mac opens read-only. Claude writes queries from a description and fixes failing ones, with the schema as context
- Map: the architecture from `Package.swift`, Docker Compose or source folders, with an inspector and drift against `.dante/architecture.md`
- Ship: CI runs from `gh`, a changelog drafted from conventional commits since the last tag, a release checklist, and local tagging
- Run: alarms, health checks and a production log stream from `operate:` in `.dante/project.yaml`. Alarms come from CloudWatch (read-only, through the `aws` command line and its existing login) or any command that prints them as JSON (`[{ name, state, reason, updated, url }]`, for Datadog, Grafana, Alertmanager…). Firing alarms sort first; one click makes a task linked to the alarm, an alarm that fires again after its task is done is flagged with Reopen, Investigate hands the alarm and matching log errors to Claude, and Notify me (off by default) sends a macOS notification when one starts firing. Log errors are grouped so each can become a task
- Timeline: commits and tags, Claude Code sessions run in the project folder, test runs and GitHub Actions runs in one stream grouped by day. Click a commit to show it, a Claude session to resume it in the terminal, a CI run to open it
- Claude rules in `.dante/project.yaml` (`claude: propose / flag / never`): flagged paths are called out on the diff, and never-paths are refused, reads included
- Quitting with unsaved files asks once for every window: save, discard or cancel

## Requirements

- macOS 15 or later
- Xcode 16 or later (Swift 6)
- [Claude Code](https://claude.com/claude-code), installed and signed in (`claude auth login`), for the Claude panel

## Build and run

```bash
scripts/bundle.sh --open
```

This builds a release binary and wraps it in `build/Dante.app`. Use `scripts/bundle.sh debug --open` for a debug build. To open a folder straight away:

```bash
open build/Dante.app --args ~/path/to/project
```

Files after the folder open in tabs: `--args ~/project ~/project/Sources/main.swift`.

Run the tests:

```bash
swift test
```

## Layout

| Path | What's there |
| --- | --- |
| `Sources/DanteKit` | Models: themes, workspace, documents, lifecycle, git, the Claude Code session, and the data behind each area (Docs, Testing, Environments, Map, Release, Operate) |
| `Sources/DanteEditor` | The TextKit 2 editor, line-number gutter and highlighters |
| `Sources/DanteApp` | The SwiftUI app: launch screen, workspace, the area screens (`Views/Areas`), terminal, menus |
| `Tests/` | Swift Testing suites for DanteKit and DanteEditor |
| `design/` | Generator for the design canvas and its HTML screens |
| `.dante/` | Dante's own project spec |

## The `.dante` folder

```yaml
# .dante/project.yaml
name: My App
lifecycle:
  template: app@1
  current: build
```

`lifecycle.current` sets the highlighted phase. `lifecycle.template` picks the phases and starting checklists for the kind of project:

| Template | Phases |
| --- | --- |
| `app@1` (web or backend) | Discover, Define, Design, Build, Test, Release, Operate |
| `infra@1` (infrastructure and cloud) | Discover, Design, Build, Validate, Release, Operate |
| `apple@1` (Swift and Apple platforms) | Discover, Define, Design, Build, Test, Beta, Release, Operate |
| `data@1` (data and scripts) | Explore, Define, Build, Validate, Schedule, Monitor |

You can also list your own with `lifecycle.phases: [Discover, Build, Ship]`. Phases are guidance and never block anything. When you open a project without `.dante/`, Dante offers to set it up. It works out the stack, lifecycle and current phase from the files and git history (no Claude needed), and spots secrets such as `.env` files. You then pick what Claude should fill in: the summary and goals, phase checklists for this codebase, tasks from TODOs and open issues, the test command, never-rules for the secrets, architecture notes, and Operate checks. Dante writes the skeleton straight away and Claude's edits come through for review. "Not now" is remembered per project; File › Set Up Project for Dante… brings the sheet back.

```yaml
# .dante/tasks.yaml
prefix: APP
tasks:
- id: APP-1
  title: Sign-in screen
  phase: build
  state: in_progress   # ready, in_progress, review or done
  spec: specs/sign-in.md
```

```markdown
<!-- .dante/phases/build.md -->
# Build

Turn the agreed design into working, reviewed code.

## Ready when
- [x] Design phase done

## Done when
- [ ] All Build tasks done
```

```yaml
# .dante/project.yaml, optional extras
test:
  command: make test           # otherwise Dante works it out
operate:
  checks:
    - { name: api, url: "https://api.example.com/health" }
  logs: fly logs -a my-app     # any command that streams production logs
```

Dante's own `.dante/` folder is a working example.

Geist and Geist Mono are © The Geist Project Authors, from [vercel/geist-font](https://github.com/vercel/geist-font), under the SIL Open Font License 1.1 (`Sources/DanteEditor/Resources/Fonts/OFL.txt`).
