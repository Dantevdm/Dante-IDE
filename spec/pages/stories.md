---
id: stories
title: Stories
phrases: [stories, frontend stories, front end stories, user stories, storyboard, feature stories, how does it work, show me how it works, front-end tests, end-to-end stories, e2e stories, scenarios, playwright stories, ui walkthrough]
---
# Stories (Quality › Stories)

Stories tell how each feature of the web app works, step by step, in a real browser: one file per feature, one Playwright test per scenario (the usual way, nothing there yet, wrong input, the server failing, a slow network, a phone, signed out), every step said in plain words and photographed. They run as the app's end-to-end tests, and when one breaks Dante says where and why: the call that failed and the code that serves it, an error the page threw, or what the screen showed instead, with what changed since it last passed.

## Highlights
- Ideas come from what the Map understood of the app: its screens, the calls each makes, what's on them (forms, buttons, links), the journey a person takes through them, and how people get in. The agent in charge writes the chosen ones after looking at the running app.
- Stories live in the web app's `stories/` folder with their own Playwright config and Dante's helper (`dante-story.ts`), which records every step, failed calls, page errors and the console. The app's other tests stay as they are; the Tests page counts stories as end-to-end tests.
- Scenarios simulate trouble without touching the server: the helper can make calls fail, answer empty or slow down, inside the browser only.
- A broken story says whether the app or the story looks wrong, shows the step as it looked when it last passed beside how it looks now, and lists the files changed since.
- Pictures are kept on this Mac (Application Support), so they survive Playwright clearing its output.

## Shows
- The app card: a chip per web app when there are several; whether it answers on its port (with Start it), whether Playwright is installed (with Type the install command), and whether stories are set up (with Set up stories, or Update when the kit is older).
- While running: a spinner, how many scenarios were told and how many broke, and Playwright's latest line.
- A sentence over the stories: "All 12 scenarios in 4 stories went as told." in green, or "2 of 12 scenarios broke. Open one to see where and why." in red, and when they last ran.
- A card per story: its name and what a person does there, a strip of pictures from its broken (or happy) scenario with the broken step outlined red, each scenario with a status dot, its kind and how long it took, and the first broken one's reason in red. Story files that haven't run show "Not run yet." with Run it.
- An opened story: All stories to go back, its name and file, Run this story; a tab per scenario; how it went (Went as told, Broke, Didn't run) with steps, time, phone size and when it ran; Play, Video, Trace and run again.
- Why it broke (an opened broken scenario): the reason, who likely needs to change (The app looks wrong, The story looks wrong, The app or the story, Nothing to fix in the code), supporting sentences, Open <file>:<line> for the code serving the failed call, the files changed since it last passed, the server's log lines, the step's picture when it last passed beside now, and Ask the agent to fix it.
- The storyboard: a card per step with its picture, number (green or red), caption, page path and time, and the error under a broken one.
- Stories to tell: ideas with a tick each, the file it would be, a sentence, its scenarios and how many calls it makes, and Ask the agent to write N.

## Actions
- Run all / Run this story / Run it / run a scenario again: runs them against the app's address through the app's own Playwright; Stop ends the run.
- Start it: runs the app's start command in a terminal tab of its own and waits up to 150 s for its port.
- Type the install command: types the command that adds @playwright/test and Chromium into the terminal, for the person to run.
- Set up stories / Update: writes the config (only when missing), the helper and a .gitignore into the stories folder.
- Ask the agent to write N: sets up the kit when needed, then sends the chosen ideas with what Dante understood of the app (screens, calls, sign-in, API, data), the kit's API and the rules a story keeps.
- Ask the agent to fix it: sends the story, its steps, where it broke, Dante's reading, the changed files, the server log, the picture's path and the command to run it again; the agent decides whether the app or the story changes.
- Play: shows the steps one after another, large, with captions (arrows to step, space to pause, Esc to close).
- Open the picture, Video (the browser's recording), Trace (Playwright's trace viewer in a terminal tab), and the code links.

## States
- No web app in the project: says stories need a web front-end and the Map found none.
- The app isn't running, Playwright isn't installed or the kit isn't set up: the app card says so with the way forward, and runs are disabled.
- No stories yet: says to pick the stories to tell and ask the agent.
- A run that broke before any story ran (a syntax error in a story): its reason from Playwright's output in an amber line.
- A scenario that never used story.step: says no steps were recorded, with Playwright's message.
- Never passed: a broken scenario that hasn't passed before leans to the story being wrong.

## Edge cases
- The app's address is its dev server's port (from package.json, the framework config or the env file), or the compose service that runs it.
- The helper is rewritten only when Dante wrote it and its kit version is older; the config is never rewritten.
- A call the story failed on purpose (failApi, fakeApi) is never blamed.
- Changed files are those since the commit at the scenario's last pass, committed or not, limited to the web app's code and the handlers its calls reached.
- Server log lines come from the project's compose services during the run, errors only, health checks left out.
- Running some stories replaces only their scenarios; running all drops scenarios whose files are gone.
- Stories never run on a remote project's host; they need the app on this Mac.

## Acceptance
- On a project with a React app on localhost, Set up stories writes stories/playwright.config.ts and dante-story.ts, and Run all tells each scenario with a picture per step.
- A scenario whose POST /api/orders answers 500 says so, names the handler's file and line, and blames the app.
- A scenario that can't find getByRole('button', { name: 'Pay' }) after the screen's file changed says the screen never showed it and lists the file.
- After a story is run again, the broken step shows its picture from the last pass beside the new one.
- Ticking ideas and pressing Ask the agent to write sends one message naming each chosen story's file and scenarios.
