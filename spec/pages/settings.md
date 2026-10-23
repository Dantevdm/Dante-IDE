---
id: settings
area: settings
title: Settings
phrases: [settings, preferences, options, configuration]
---
# Settings

Settings holds the appearance, editor, keyboard shortcuts, language servers, files, agents and voice, tools and the project's own settings.

## Shows
- Appearance (theme, font size, Geist fonts), Editor, Keyboard (every shortcut, recordable), Languages (each language server: off, command, options), Files, Agents (who leads, Claude's model and effort, the team (each role's model or Off, and Document decisions as we work), Codex, automatic task effort and local routing, the agents' own browser, voice, cloud agents and their keys, Hands, and iPhone and iPad: the companion server), Tools (versions and install commands) and Project.
- Agents says when Claude Code isn't installed, under Claude's model.
- The agents' own browser (on by default): the agent in charge and every job get browser_ tools (open, read, click, type, back, resize, screenshot) backed by a private WebKit browser inside `dante mcp`. It visits only the app on this Mac (localhost, 127.0.0.1, ::1, *.localhost, *.test) and hosts listed under `browser: hosts:` in .dante/project.yaml (and their subdomains); a link or form that leaves them is stopped and the agent told. It keeps no cookies or sign-ins between runs and never uses the person's browser. Each read gives the page's text, numbered controls, page errors (console.error, uncaught errors, resources that didn't load) and failed fetch/XHR calls. Screenshots are kept a week in Application Support/Dante/browser/<project>. Its steps never ask, at any approval level or in away mode, since nothing leaves the Mac. Off for remote projects.
- Hands (off by default): lets the agent in charge open apps, find folders and use the keyboard and mouse; when on, the kill switch (⌃⌥⌘. anywhere, or Stop on the badge) and whether macOS allows Dante to control the Mac, with Open Accessibility Settings… when it doesn't.
- iPhone and iPad (off by default): when on, where Dante listens (this Mac's Tailscale address and port 47823), Show Pairing Code… (a QR code in a sheet, with Unpair All Devices…) and each connected device; without a Tailscale address it says to install Tailscale instead.

## Actions
- Change any setting; record a shortcut; reset to defaults.
- “Hey Dante” (off by default): while it's on the microphone stays open and speech is recognised on this Mac. Turn it on or off in Settings › Agents (Listen for “Hey Dante”), with the menu bar panel's Hey Dante button (filled while listening), the menu bar item's right-click menu or View › Listen for “Hey Dante”; turning it off closes the microphone at once unless you're talking.
- Hold ⌃⌥Space in any app to talk; release to send. Repeated key-down events don't restart recording. A quick release during permission/startup cancels the hold without opening the microphone later. Click Talk for the separate pause-to-send conversation mode.
- Paste a cloud agent's key (kept in the Keychain).
- Type a tool's install command into the terminal (never run by Dante).
- Project: move .dante to the Trash, set up again, forget saved connections.

## Edge cases
- A shortcut reset to its default can need a restart (noted beside it).
- Claude's effort (Claude Code's default, low, medium, high) is passed as `--effort`; changing it, the model or a team role's model starts Claude Code again on the next message, continuing the same conversation. The chat footer's model menu changes the model and effort too and shows them ("Sonnet · low").
- The chat footer shows what the last reply cost ("last 1.8M"): each step of a reply re-reads the whole conversation, so steps × context; its tooltip and the usage popover explain it and suggest compacting when the conversation is over 100k tokens.
- Automatic task effort (on by default) sorts each request on the Mac without spending tokens: anything mentioning security, auth, migrations, production, deploys, deletion and the like is complex; a few routine openings ("rename …", "fix the typo") are routine; the rest is standard. Codex runs routine work at low reasoning and the rest at medium; Claude keeps its chosen model. A self-contained rewrite or summary ("Summarise this: …", no attachments, nothing about the project or the conversation) goes to the smallest suitable Ollama model first, and to the agent after 30 seconds or on any failure. Each decision is a note in the conversation. Choosing a reasoning level in Codex's model menu turns it off; "Automatic by task" turns it back on.
- Click-to-talk and wake-word voice send after one second without a transcript change. Holding the talk shortcut disables that silence timer; recognition segments are joined until release. Release stops capture immediately and waits for the recognizer's final text, up to 600 ms, before sending once. Held turns don't automatically listen for a follow-up. A completed reply sentence is released for synthesis after 200 ms of stable text, without waiting for another sentence or for the turn to end; incomplete text and abbreviations wait.
- Natural speech uses chunks of at most 180 characters, split between words (a single longer word stays whole). Playback overlaps synthesis, with at most three outstanding chunks: one playing and two being prepared or ready. Cancelling speech clears queued audio and prevents requests cancelled during warm-up from being submitted.
- Spoken requests ask the current agent for brief, conversational replies, with long details on screen. The chosen model, reasoning level and approval rules still apply.
- When continued conversation is on, follow-up listening resumes once both the agent turn and its audio are finished, even if a short streamed answer finished playing before the turn ended.

## Acceptance
- Settings apply without a restart unless they say otherwise.
- The companion server listens only on the Tailscale address and refuses any device that can't prove it holds the pairing key; unpairing makes a new key.
- Hands' keyboard, mouse and screenshot steps ask every time at any approval level, jobs never get Hands, and Hands never type or click in Dante, terminals, System Settings or password apps.
- While the agent uses Hands a badge floats at the top of the screen saying what it did, with Stop; Stop or ⌃⌥⌘. refuses every further step at once (typing stops mid-word), turns Hands off and stops the conversation.
