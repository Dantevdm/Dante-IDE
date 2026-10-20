---
id: home
title: Home
phrases: [home, overview, start page, dashboard, summary]
---
# Home

Home is the project at a glance: what changed since you were last here, recent commits, the local environment, the docs and what the agent knows about the project.

## Highlights
- Since you were last here lists new commits and changed tasks.
- Local environment says which services are up.
- What the agent knows shows the CLAUDE.md memory it reads.

## Shows
- Since you were last here: commits since the project was last closed on this Mac, with files changed, lines added and removed, and "and N more" past the first few.
- Recent commits: the latest commits on the current branch, with author and age.
- Local environment: each compose service and whether it's up, or a note when the project has no compose file.
- Documentation: the project's markdown docs, newest first.
- What Claude knows: the memory files (CLAUDE.md and friends) the agent reads on every message, with their size in tokens.

## Actions
- Read opens a doc in Docs.
- Manage opens Agents › Setup at the memory files.
- Release opens Ship › Release.
- A service row opens Local › Services.

## States
- First open of a project: no "since you were last here" card, since there's no previous visit.
- Not a git repository: the commit cards say so instead of listing commits.
- No compose file: the environment card says "No docker-compose.yml".
- No markdown docs: "No markdown docs yet."

## Edge cases
- The last visit is recorded per Mac when the project closes (`ProjectVisit`), so a second Mac has its own "since".
- A force-pushed branch can leave the last visit's HEAD unknown: Home shows recent commits only.

## Acceptance
- Opening a project shows Home's cards within a second for a repo of a few thousand files.
- Every card's link lands on the page it names.
- Nothing on Home starts a process that changes the project.
