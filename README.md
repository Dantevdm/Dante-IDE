# Dante

A native macOS IDE organised around the whole software lifecycle: Discover, Define, Design, Build, Test, Release, Operate. Claude works alongside you as a pair, proposing changes you approve.

Dante keeps a project's plan, tasks, docs and decisions in the repo under `.dante/`, so you and Claude are reading the same source of truth.

**Status:** milestone 3. Every lifecycle area has a working screen: Home, Plan, Map, Code, Tests, Env, Ship, Run, Docs and Spec, and the editor has tree-sitter highlighting and language servers. See the [design canvas](https://claude.ai/artifact/KFxwBAj14jL7w1MHNcc5Pi).

## What works today

- Launch screen with recent projects, plus new project, open folder and clone
- Dark, Light and Paper themes (⌥⌘T to cycle)
- File explorer, tabs, and a TextKit 2 code editor with tree-sitter highlighting (Swift, Python, JavaScript, TypeScript, Go, Rust, JSON; regex for the rest), line numbers and auto-indent
- Language servers for diagnostics, hover info (rest the pointer on a symbol) and Jump to Definition (⌘-click or ⌃⌘J): SourceKit-LSP, typescript-language-server, Pyright, gopls, rust-analyzer and clangd, whichever are installed. Problems are underlined, marked in the gutter and listed from the status bar, and Fix hands one, or all of them, to Claude. Claude always sees the open file's problems
- Integrated terminal running your login shell (⌃`)
- Claude pair panel (⌘L): runs Claude Code headless in the project. Every edit arrives as a diff to apply or decline, and every command waits for your go-ahead. Claude knows the `.dante` format and the current phase, and sees which file you have open
- Command palette (⌘K, or ⌘P for files): fuzzy file search, docs, actions, and Tab to ask Claude
- Live file watching: the explorer, open tabs and branch stay current when files change outside the editor
- Plan: lifecycle phases, "ready" and "done" checklists from `.dante/phases/<phase>.md`, and a drag-and-drop task board stored in `.dante/tasks.yaml`. "Work on this with Claude" hands a task to the pair panel
- Lifecycle ribbon read from `.dante/project.yaml`; click a phase to open it in Plan
- Home: the project at a glance, with the lifecycle timeline, the current phase's tasks, recent commits, local services, and what Claude is told about the project
- Docs: renders the project's markdown with an outline, links tasks that use a doc as their spec, and opens files it mentions
- Spec: the `.dante` folder with validation, plus exactly what Claude receives and roughly how many tokens it costs
- Tests (⌘U): runs the project's tests (Swift, cargo, go, npm/pnpm/yarn/bun, pytest, or `test.command`), groups results by suite, and hands failures to Claude
- Env: Docker Compose services with start, stop, logs, and Dockerfiles that are missing
- Map: the architecture from `Package.swift`, Docker Compose or source folders, with an inspector and drift against `.dante/architecture.md`
- Ship: CI runs from `gh`, a changelog drafted from conventional commits since the last tag, a release checklist, and local tagging
- Run: health checks and a production log stream from `operate:` in `.dante/project.yaml`, with errors grouped so each can become a task
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

`lifecycle.current` sets the highlighted phase. You can set your own phase list with `lifecycle.phases: [Discover, Build, Ship]`. Phases are guidance and never block anything.

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
