# Dante

A native macOS IDE organised around the whole software lifecycle: Discover, Define, Design, Build, Test, Release, Operate. Claude works alongside you as a pair, proposing changes you approve.

Dante keeps a project's plan, tasks, docs and decisions in the repo under `.dante/`, so you and Claude are reading the same source of truth.

**Status:** milestone 2, the app shell, the editor, and Claude as a pair. Most of the lifecycle areas (Plan, Map, Tests, Environments, Ship, Run, Docs, Spec) are designed but not built yet. See the [design canvas](https://claude.ai/artifact/KFxwBAj14jL7w1MHNcc5Pi).

## What works today

- Launch screen with recent projects, plus new project, open folder and clone
- Dark, Light and Paper themes (⌥⌘T to cycle)
- File explorer, tabs, and a TextKit 2 code editor with syntax highlighting, line numbers and auto-indent
- Integrated terminal running your login shell (⌃`)
- Claude pair panel (⌘L): runs Claude Code headless in the project. Every edit arrives as a diff to apply or decline, and every command waits for your go-ahead. Claude knows the `.dante` format and the current phase, and sees which file you have open
- Lifecycle ribbon read from `.dante/project.yaml`

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

Run the tests:

```bash
swift test
```

## Layout

| Path | What's there |
| --- | --- |
| `Sources/DanteKit` | Models: themes, workspace, documents, file tree, lifecycle, git, recents, and the Claude Code session |
| `Sources/DanteEditor` | The TextKit 2 editor, line-number gutter and highlighters |
| `Sources/DanteApp` | The SwiftUI app: launch screen, workspace, terminal, menus |
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

`lifecycle.current` sets the highlighted phase. You can set your own phase list with `lifecycle.phases: [Discover, Build, Ship]`. Phases are guidance and never block anything. Tasks (`.dante/tasks.yaml`) and phase docs are coming in a later milestone.
