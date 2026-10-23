---
id: agents
title: Activity
phrases: [agents, agent activity, activity, models, local models, ollama, who did what, ledger]
---
# Activity (Agents › Activity)

Activity shows who did the work: Claude and Codex, who lead, and the team they hand work to (Documenter, Researcher, Front-end engineer, Back-end engineer, Marketing, Security Officer and Tester), with the local models, the jobs each did, who checked whose work, and the models on this Mac.

## Shows
- Who did the work: each agent and model, its jobs, tokens and time. Claude and Codex lead; each team role shows its Claude model (Haiku for Documenter, Researcher and Marketing, Sonnet for the engineers, Security Officer and Tester by default) and the local model that does its small jobs (summaries for the Researcher, triage for the Tester, drafts for the Back-end engineer, commit messages and writing for the Documenter).
- How the work flows: you to the agent in charge and on to the others, each link labelled with its jobs in the range and moving while that agent worked in the last two minutes; the five busiest show, the rest share one node.
- The story: sentences on who did what, who checked whose work, and requests as threads.
- When: jobs over time.
- Models on this Mac (Ollama) and which job each would get.
- For Claude, each role on is a Claude Code sub-agent passed with `--agents` (Researcher and Security Officer can only read; Documenter and Marketing read and write files; the engineers and Tester have every tool), on its own model; the lead's brief says when to hand work over and to start independent roles in one message so they run at the same time.
- With Document decisions as we work on, the lead starts the Documenter beside the work when a decision is made; it writes `docs/decisions/NNNN-title.md` (context, decision, consequences, date) and updates the docs that cover what changed.
- In the conversation a hand-over is its own card: the role's symbol, "Handed to Back-end engineer", its model and the brief; the report opens under it.
- Jobs (Agents › Jobs) are one role's work already, so they don't get the team.
- Routine steps (reads, searches, listings, commands, steps that recover on their own, and the short notes between them) fold into one line once there are two in a row: "Read 4 files, 2 searches", or while one runs, what it's doing now and how many are done. Click to see each step. Edits, approvals, questions, rule and security notes and hand-overs never fold.
- Return sends; Shift+Return starts a new line at the caret.

## Actions
- Let Claude and Codex delegate to local models (on or off).
- Type the command to install a model into the terminal.
- Open a job's conversation or answer.
- Each role's model, or Off, and Document decisions as we work, in Settings › Agents › Team.

## States
- Ollama not running or no models: says so and how to start.
- An agent that can't run says so on its card: Claude without Claude Code, Codex without the Codex CLI or ChatGPT app, a cloud agent without its key.

## Acceptance
- Every job in the ledger appears once, with its project.
- The flow picture never shows more than six agents beside the one in charge.
