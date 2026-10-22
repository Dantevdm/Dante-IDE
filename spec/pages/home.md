---
id: home
title: Home
phrases: [home, overview, start page, dashboard, summary]
---
# Home

Home is the project at a glance, drawn rather than listed: the system as a living map, five vital-sign tiles, then what changed since you were last here, recent commits, the local environment, the docs and what the agent knows about the project.

## Highlights
- How it fits together: the project's system map in miniature, with traffic running along its links.
- Vital signs: Code, Security, Tests, Activity and Agents tiles, each a picture that opens its page.
- Since you were last here lists new commits and changed tasks.
- Local environment says which services are up.
- What the agent knows shows the CLAUDE.md memory it reads.

## Shows
- How it fits together: the Map's system (`SystemMap`, built the same way as the Map, or the Map's own build for this revision) cut down by `HomePulse.sketch` to the four best-linked parts per lane (clients, API, backend, data, outside services), in the lane's order, with "+N more" under a lane that has more. Lane titles sit in a row along the top in each lane's colour; links between the shown parts are dashed and moving, with a packet running along each, like the Infra view. Shown only when the system has at least two lanes.
- Code tile: a ring of the languages' shares of the code files (the top four, the rest as Other), the largest's percentage in the middle; the file count under it.
- Security tile: the saved report's grade in a ring that fills with the score, coloured by the worst finding (green with none); "N serious problems", "N to tidy up", "Nothing found" or "Not scanned yet" under it.
- Tests tile: the last recorded run as a bar of passed, failed and skipped, with "N passed" or "N failing" above it; "No run yet" without one.
- Activity tile: a grid of commit days for the last twelve weeks, a column per week from Monday, darker green for busier days, days still to come left empty; "N commits this week" under it.
- Agents tile: Agent HQ's rooms as dots (bigger for higher levels, fainter when quiet, dashed while unopened) and "HQ: a <era>, N jobs".
- The tiles share one row when they fit (each at least 150 points wide), else they split into even rows (three and two, never four and one); the cards below are two columns (at least 340 points each, one when narrower), and every card in a row is as tall as the tallest, so their edges line up.
- Since you were last here: commits since the project was last closed on this Mac, with files changed, lines added and removed, and "and N more" past the first few.
- Recent commits: the latest commits on the current branch, with author and age.
- Local environment: each compose service and whether it's up, or a note when the project has no compose file.
- Documentation: the project's markdown docs, newest first.
- What Claude knows: the memory files (CLAUDE.md and friends) the agent reads on every message, with their size in tokens.

## Actions
- A part on the map opens the Map on the system view with that part selected and its inspector open; Open the map opens it as it was.
- Each tile opens its page: Code, Quality › Security, Quality › Tests, Ship › History, Agents › HQ.
- Read opens a doc in Docs.
- Manage opens Agents › Setup at the memory files.
- Release opens Ship › Release.
- A service row opens Local › Services.

## States
- A project whose system the Map can't tell apart (fewer than two lanes): no map; the tiles come first.
- While loading: the tiles show what's ready (Agents spins until the ledger is read) and the map appears once built.
- First open of a project: no "since you were last here" card, since there's no previous visit.
- Not a git repository: the commit cards say so instead of listing commits.
- No compose file: the environment card says "No docker-compose.yml".
- No markdown docs: "No markdown docs yet."

## Edge cases
- The last visit is recorded per Mac when the project closes (`ProjectVisit`), so a second Mac has its own "since".
- A force-pushed branch can leave the last visit's HEAD unknown: Home shows recent commits only.

## Acceptance
- On a project with a web client, an API and a database, Home shows the map with moving links, and clicking a table opens the Map with that table selected.
- The five tiles fit one row at the usual window width and look right in Light, Paper and Dark.
- Opening a project shows Home's cards within a second for a repo of a few thousand files.
- Every card's link lands on the page it names.
- Nothing on Home starts a process that changes the project.
