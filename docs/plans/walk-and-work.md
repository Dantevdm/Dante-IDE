# Walk and work

Hand Dante jobs, go for a walk, and talk to it through earbuds. The Mac does the work; the iPhone is a voice in your ear; the iPad is a desk away from the desk.

Status: steps 1 (jobs on the Mac) and 2 (away mode, the job guard and `dante job`) are built; the rest is a plan.

## Decisions so far

- Earbuds first: hands-free voice on the iPhone, glancing at it only when it's convenient.
- No paid Apple Developer account for now. The companion app is installed from Xcode with free provisioning and reinstalled every 7 days. That rules out remote push notifications (APNs); everything else here works without them.
- One repo: the companion app lives in this codebase beside the Mac app.
- Pair mode stays the default. Running jobs unattended ("away mode") is opt-in, per job, and bounded by the rules in `project.yaml`.

## Jobs

A job is a piece of work with its own Claude Code session: a role, a brief, what starts it, what it may touch, and what it hands back. Jobs run in parallel, each in its own git worktree, so two jobs never edit the same checkout.

| Job | Starts when | Hands back |
|---|---|---|
| Builder | you hand it a task ("take DI-97") | a branch and a pull request; the task moves to review |
| Pipeline watcher | a push, or a CI run goes red | the failing step, its cause, and a fix on the branch |
| Verifier | a deploy finishes, or you ask | browser checks of the running app, with screenshots |
| Reviewer | a pull request opens | findings (`BranchReview`) |
| Triage | an alarm fires (`AlarmMonitor`) | a task with the alarm linked, and a first diagnosis |
| Test gardener | on request, or weekly | tests for untested code; flaky tests named |
| Docs keeper | after merges | README, `.dante/architecture.md` and phase docs brought up to date |
| Scout | you ask a question worth an afternoon | a decision doc in `docs/` |

Job types are defined in the repo, in `.dante/jobs/<name>.md`: front matter for the trigger, scope (paths and tools), approval policy and budget, and the brief as markdown. Where a Claude Code agent already exists in `.claude/agents/`, a job can name it instead of repeating the brief.

### The foreman

You don't talk to eight agents. You talk to one voice, the foreman, which knows every job's state and the project's lifecycle. It starts and stops jobs, answers "what's going on?", and brings you the questions jobs are waiting on, one at a time. A walk starts with a standup ("Build has ten tasks in review, CI is red on main, the verifier found a broken login page") and ends with a summary of what moved.

### Waiting is Dante's job, not Claude's

A job waiting on a pipeline shouldn't keep a model polling. Dante watches CI runs (`CIRun`, `gh`), deploys, alarms and timers itself, and wakes the job with what happened. That keeps plan usage for the work.

### Away mode policy

- Edits inside `propose` are applied without asking, on the job's branch only.
- `flag` paths and anything outside `propose` wait for you.
- `never` paths stay refused.
- Shell commands go through an allowlist per job type. No pushes to the main branch, no deploys, no tags.
- Every turn keeps its checkpoint, so a job's work can be undone turn by turn.
- Each job has a budget (turns, time, and a share of the plan's five-hour window from `ClaudeUsage`); it stops and asks when it runs out.

## Devices

**Mac: the brain.** Runs Dante, the jobs, git, tests and browser checks; stays awake while jobs run. A `CompanionServer` in Dante sends job events and accepts answers and approvals.

**iPhone: the voice.**
- Speech recognition and speech run on the phone; only text crosses to the Mac, so it holds up on a weak signal.
- AirPods stem press is push-to-talk (it arrives as a play/pause remote command).
- An audio session stays active for the walk, which keeps the app running with the screen locked.
- A Live Activity shows the foreman's state ("waiting on CI, 4 min", "1 question"); local notifications with Approve / Reject / Tell me more buttons cover the moments when talking isn't convenient.
- Voice mode has its own brief: short answers, summaries instead of code, file names said naturally.

**iPad: the desk away from the desk.** The jobs board, diffs, the task board, CI runs and the verifier's screenshots, for proper review on a bench with a keyboard.

**Connection.** Tailscale on all three devices; Dante listens on its tailnet address only, so it works on Wi-Fi and cellular without a server, and nothing passes through anyone else. Pairing: Dante shows a QR code, the phone scans it and keeps the key, and the server refuses anything without it.

## Code layout

- `Package.swift` and `Sources/` stay as they are for the Mac app.
- `Sources/DanteCore`: a new target that builds for macOS and iOS: job definitions, job and Claude event models, the companion wire protocol, diffs and tasks. Pieces of `DanteKit` move here when the companion needs them; anything that runs a process stays in `DanteKit`.
- `Mobile/`: one universal app for iPhone and iPad, built with Xcode (it has to be, to install on a device). `Mobile/Common` for the connection and shared views, `Mobile/Phone` for the voice screens, `Mobile/Pad` for the desk layout.

## Order

1. Jobs on the Mac: several Claude sessions at once, each in a worktree, a jobs board in the Claude area, and one inbox for every job's questions and approvals. Useful at the desk on its own.
2. Away mode policy and budgets.
3. Job types from `.dante/jobs/`, with the Builder and the pipeline watcher first.
4. `DanteCore` and `CompanionServer` with QR pairing.
5. iPhone: the voice loop with AirPods push-to-talk and the foreman.
6. iPhone: Live Activity and actionable notifications.
7. iPad: the desk layout.
8. Verifier: a browser MCP server passed to the job's `claude`, so it drives its own browser instead of yours.

## Open questions

- How many jobs at once before the plan's five-hour window runs dry? Measure with real tasks.
- Does the foreman run as its own Claude session, or is it Dante summarising job events with a cheap one-shot call (`ClaudeQuick`) and only waking a full session to act?
- What the Verifier is allowed to log in to.
