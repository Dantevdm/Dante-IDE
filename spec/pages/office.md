---
id: office
title: HQ
phrases: [hq, agent hq, the office, office, headquarters, the campus, watch it grow, the agents' office]
---
# HQ (Agents › HQ)

HQ is a little isometric office where the agents work, and it grows with the project: every job an agent does and every commit makes it bigger. It starts as an empty lot and becomes a garage, a studio, an office, headquarters and finally a campus. It's for fun as much as for information.

## Highlights
- Eight rooms around the brain, one per kind of work: Research, Backend, Front-end, DevOps, Quality, Docs, Security and Data.
- Rooms open with their first job and get furnished as their work adds up. Rooms nobody has used in a while go dusty.
- Watch it grow replays the office from the first job to now.

## Shows
- The rooms. A job's room comes from the files it changed, from its kind (audits in Security, image reading in Front-end, triage in Quality, summaries and questions in Research) or from the words of its title (`OfficeRole.of(job:)`).
- Each room's level, from its jobs (`AgentOffice.levels`: 1, 4, 12, 30 and 75):
  - Vacant: a dashed outline.
  - Opened: low walls and a desk.
  - Settled: a rug, a lamp and a window.
  - Team room: a second desk and a plant.
  - Established: a screen wall, a bookshelf and another plant.
  - Flagship: a glowing ring and gold trim.
  - After that, every hundred jobs puts a trophy on the floor and a star on the sign, five at most.
- How lived-in each room is. A room is bright when it worked in the last hour and dims and loses colour over a quiet month.
- Roads from the brain to each room. All the work ever done in a room wears its road wider. This week's work lights the road and sends packets along it.
- The era, which needs both work and days with work. A commit counts as a fifth of a job, and days with commits count too.
  - Garage: from the start.
  - Studio: 10 jobs and 2 days.
  - Office: 50 jobs and 5 days.
  - Headquarters: 200 jobs and 14 days.
  - Campus: 600 jobs and 40 days.
- The brain grows with each era: rings, a beam, arcs to the rooms, a plaza, then a ring road. A floor is added under it for every 150 commits (six at most).
- Trees between the rooms, one for every 40 files (sixteen at most).
- It follows the app's theme. In Dark the scene is set at night under the hour's sky. In Light and Paper it has a daylit ground, pale roads and a pale brain platform tinted by the hour, and the panel, signs and tags use the theme's colours. Windows and lamps glow at night.
- Who is at work now, in the room of what they're doing (`OfficeWorker.from`).
  - The lead goes to the room of the file it's editing or the command it's running; reading and searching is Research.
  - Sub-agents stand in Research.
  - Local models, Looker and reviewers go to their rooms.
  - Each worker has a tag saying what it's doing. Jobs from the Jobs board show too, marked "job".
  - An idle room shows its regular agent dimmed at the desk.
- The side panel shows:
  - The era, with progress to the next one.
  - Anything waiting for you.
  - Who's at work.
  - The story so far: milestones such as rooms opening, furnishings arriving, new eras and round numbers of jobs and commits, newest first.
- A room's panel, opened by clicking its sign, shows:
  - Its level and what the next level brings.
  - Its jobs this week and their average time.
  - Who opened it, its crew and its recent work.

## Actions
- Click a room's sign to open its panel. Click it again, or the cross, to close it.
- Watch it grow: replays the office from the first job to now, with the date and era in the corner.
- Open, on something waiting, shows that conversation in the agent panel.

## States
- No jobs yet: an empty lot. Every room is vacant and the story says the first job opens the doors.
- Nobody working: "quiet", and the caption shows the latest milestone.
- New milestones since you last looked: a toast with confetti, shown once.
- A narrow window: the side panel hides behind a button.

## Edge cases
- Only this project's jobs count, so the ledger of other projects never shows.
- A job that changed files in several rooms goes to the room with most of them, the first-listed on a tie.
- A busy afternoon doesn't make a campus, because eras need days with work as well as jobs.
- In a replay the files grow with the commits, because the app was smaller back then.

## Acceptance
- With no jobs the office is an empty lot. One job opens one room.
- The level, era and milestones match `AgentOffice.build` for the project's ledger and git history.
- Something waiting for you shows in the panel and as a pink tag in its room.
- Watch it grow ends on the office as it is now.
