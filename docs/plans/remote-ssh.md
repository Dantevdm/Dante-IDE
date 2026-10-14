# Remote projects over SSH

Open a project that lives on another machine (a dev box, a cloud VM, a Linux server) and work on it as if it were local, with Dante's UI on this Mac.

Status: the first version is built (DI-99). File → Open Remote… (⌃⌘O), the launch screen and the project menu open one.

## How it works

Dante keeps a **mirror**: a copy of the project on this Mac, in `~/Library/Application Support/Dante/Remote/<host>/<hash>/<name>`, kept in step with the host by rsync. Everything that only reads files (the editor, Map, Docs, Plan, the test inventory, search) works on the mirror unchanged. Everything that runs a program runs **on the host**:

| What | Where it runs | How |
|---|---|---|
| git, tests, `Shell.run` / `Shell.stream` | host | `RemoteRegistry` maps a mirror folder to the host's folder; `Shell` sends the command over ssh in the user's login shell |
| Claude Code | host | `ClaudeSession` starts `claude` over ssh; paths in tool calls are mapped to the mirror for diffs and checks, and back for approvals |
| Terminal | host | `ssh -t` into the project folder |
| Language servers | host, when it has them | on opening, one ssh call asks the host which servers it has (`LanguageServer.hostProbeScript`); those start there over ssh and `LSPURIMap` rewrites URIs between the mirror and the host. Servers already running here move across. Servers the host lacks, or with a command set in Settings → Languages, run here on the mirror |
| Docker Compose, logs | host | `docker compose` goes through `Shell` like any command; the Env area says "On <host>" and skips checking ports on this Mac |
| Ports | forwarded | running services' published ports are forwarded to the same port here (`ssh -O forward -L 127.0.0.1:p:localhost:p` on the shared connection), so browsers, health checks and database tools on this Mac reach them. A port taken here isn't forwarded and is marked in Ports. Forwards are cancelled when the window closes |
| Data | host | psql/mysql/sqlite3 run there, through the compose service when there is one; "localhost" in a connection means the host. Passwords and other environment for a host command go on its stdin, never the ssh command line (`Shell.readingEnvironment`) |
| Debugger | off | it would run the program on this Mac |

There's no agent installed on the host and no FUSE. The host needs sshd and rsync. Dante connects with the user's keys or ssh agent, with `BatchMode=yes`, and never asks for a password. One shared connection per host (`ControlMaster`, sockets in `/tmp/dante-ssh-<uid>`) keeps each command to one round trip.

## Syncing

`RemoteSync` runs on local changes (FSEvents on the mirror), after every command or Claude tool that ran on the host, and on a timer (every 4 s while Dante is in front, 30 s otherwise). Each sync:

1. deletes on the host the files deleted here since the last sync. More than max(50, a quarter of the project) at once are held back as a likely accident, and copied back instead;
2. removes here what the host deleted, if it hasn't changed here since the last sync (an edit here outlives a deletion there);
3. pushes the files made or changed here since the last sync, and only those (`--files-from`), so a stale copy never overwrites the host's;
4. pulls what changed there (`-u`: when both sides changed a file, the newer wins).

The files and modification times after each sync are saved beside the mirror (`<name>.synced.json`), so a relaunch knows what changed while Dante was closed. Without that record, the host decides.

Not synced: `.git` (except `HEAD`, so the branch shows), dependency and build folders (`node_modules`, `.build`, `build`, `dist`, `target`, `vendor`, virtualenvs…), and files over 20 MB.

## Not yet

- Claude history, usage and the Timeline's Claude sessions: their transcripts are on the host.
- Password or keyboard-interactive auth.

## Testing

`RemoteSyncTests` sync a folder on this Mac through an ssh stand-in (`DANTE_SSH`) that skips the options and runs the command locally. The same stand-in works for the app: `open --env DANTE_SSH=<script> build/Dante.app`.
