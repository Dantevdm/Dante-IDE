# Remote projects over SSH

Open a project that lives on another machine (a dev box, a cloud VM, a Linux server) and work on it as if it were local: edit files, run Claude Code, tests, git, language servers and the terminal there, with Dante's UI on this Mac.

Status: scoped, not started (DI-99). This document is the plan; nothing below exists yet.

## What has to change

Dante assumes the project is on the local disk in three ways:

| Seam | Today | Size |
|---|---|---|
| Processes | `Shell.run` / `Shell.stream` for most commands, plus six direct `Process()` sites (Claude Code, language servers, the debugger, git helpers, the CLI) | 27 files call `Shell`; 6 start processes themselves |
| Files | `FileManager` and `String(contentsOf:)` / `write(to:)` straight against `Workspace.url` | 84 reads/writes in 41 files; `FileManager` in 52 files |
| Watching | `DirectoryWatcher` (FSEvents) drives `Workspace.reloadSpec`, the file index and external-change reloads | 2 files |

Everything process-based moves to a remote host almost for free once commands can be sent there. The file system calls are the bulk of the work.

## Approach

No agent installed on the remote and no FUSE. Dante drives the remote with plain `ssh` and POSIX tools that every Linux and macOS host has (`sh`, `cat`, `find`, `git`, `mv`, `stat`), so the only requirement is SSH access with a key (or an agent): Dante never asks for passwords, like git's network commands today (`BatchMode=yes`).

One multiplexed connection per window: `ssh -o ControlMaster=auto -o ControlPath=~/Library/Caches/Dante/ssh/%C -o ControlPersist=10m -o BatchMode=yes <host>`. Each command after the first costs a round trip, not a handshake.

### 1. A `Host` seam (no behaviour change)

- `enum Host { case local; case ssh(alias: String) }` on `Workspace`.
- `Shell.run`/`stream` take a host; `.ssh` wraps the command as `ssh … <host> 'cd <root> && exec <quoted args>'` (`Shell.quote` already exists). The six `Process()` sites move behind the same call, keeping their stdin/stdout pipes (Claude Code's stream-json, LSP and DAP over stdio work unchanged over an ssh pipe).
- Tests: the wrapped command lines, quoting of awkward paths.

### 2. A `ProjectFiles` protocol

- `read(path) / write(path, data) / list(folder) / exists / remove / move / modified(path)`, with `LocalFiles` (today's code) and `RemoteFiles` (`cat`, `cat > tmp && mv tmp path` for atomic writes, `find -printf` / `stat` for listings).
- Port in order of value: the editor's open and save, `FileIndex.scan` (remotely `git ls-files -co --exclude-standard`, falling back to `find` with the skipped names), `.dante/` (`Workspace.reloadSpec`), then the areas.
- Whole-project passes (Map, Tests inventory, Untested, search) read thousands of files. Run them where the files are rather than copying: search becomes `git grep -n -I` / `grep -rn` on the host and is parsed into `ProjectSearch.Result`; the others read through a single `tar -c <files> | …` stream per pass instead of one `cat` per file.

### 3. Watching

- Poll every few seconds over the shared connection: `git status --porcelain=v1 -z` plus `find .dante -newer <stamp>`; use `inotifywait -m -r` when the host has it.

### 4. Paths

- Language servers and the debugger report remote paths; `LSPClient` and `DebugSession` map `file://` URIs between the remote root and a local placeholder root (`dante-remote://<host>/<path>` as the document URL).
- Claude Code runs on the host (`ssh -T host claude --input-format stream-json …`), so its edits and tool calls already use remote paths. It must be installed and signed in there; the Claude area says so when `claude` isn't found.

### 5. UI

- File → Open Remote… lists `Host` aliases from `~/.ssh/config` (and a field for `user@host`), then a folder picker that browses over ssh.
- The title bar shows the host; the terminal opens `ssh -t <host>` in the project folder.
- Areas not yet ported show "Not available for remote projects yet" instead of reading the local disk.

## Out of scope for the first version

- Docker/Compose and Data against the remote's containers (they'd need port forwarding: `ssh -L`).
- Password and keyboard-interactive auth, jump hosts beyond what `~/.ssh/config` already does.
- Windows hosts.

## Estimate and order

1. Host seam: about 2 days, all testable without a remote.
2. Editor, file index and `.dante/` over `RemoteFiles`, Open Remote…, terminal: about 1 week. This is the first useful version: edit, Claude, git, tests and the terminal on a remote box.
3. Language servers and debugger path mapping: 2–3 days.
4. Search, Map, Tests inventory and Untested on the host: about 1 week.
5. Polling watcher, reconnects after sleep, error states: 2–3 days.

Test against a local Linux VM or container with sshd (needs one image download, so ask first).
