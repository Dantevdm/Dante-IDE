---
id: tests
title: Tests
phrases: [tests, test, testing, test results, failures, flaky tests, test map, coverage, quality]
---
# Tests (Quality › Tests)

Tests shows every test in the code as a map coloured by its last result, every run on this Mac whoever started it, what failed and why, and the code no test names.

## Highlights
- Every run counts: yours from this page, and the test commands Claude, Codex and jobs run, so the page always shows the latest result.
- The map has one square per test written in the code: green passing, red failing, amber flaky, grey skipped, an outline for never run, faded when the test's file changed after the run that coloured it.
- Choose a run in the strip to see the page as that run left it.

## Shows
- Overview: one sentence on where the tests stand ("2 failing of 32, 1 flaky", "All 32 passing", "32 tests in the code, none run on this Mac yet"), who ran last and when, and the passing, failing, flaky, not run and changed-since counts. While a run goes it says how long it has run and how many passed and failed so far.
- Runs on this Mac: a bar per run, oldest on the left (up to 32): red for the share that failed, green for the rest, grey for skipped, fully red when the build or runner broke before the tests; shorter bars are runs of only some tests. A glyph under each says who ran it (a person for you, sparkles for the agent in charge, a hammer for a job, a cloud for CI). Hovering or choosing a bar names the runner, time, command and outcome; the run going now pulses at the end.
- Failures: each failing test of the shown run (or of the run going now) with its suite, its messages and the file and line, marked flaky when it has also passed recently.
- Every test: a box per folder, failing folders first, each with its kind (Unit, Integration…) and a count, holding a square per test. A legend counts each state and filters the map to one when clicked. A failing test that is also flaky has an amber dot. Hovering a square names the test, its file and line, its last result with who ran it and when, and its message.
- When a run broke before its tests: the last lines it printed.
- Code no test names: how many functions and types no test names, a square per file shaded by how much of it is untested, and the files themselves on Show.

## Actions
- Run all: the detected runner (swift test, go test, pytest, Maven, Gradle, jest, vitest and others; with nothing at the root, each app folder's runner in its folder, one after another).
- Run some: the tests for changed files, or one kind of test.
- Re-run failed, or one failure from its row; Run these again repeats a narrowed run.
- Click a square to open the test at its line; ⌘-click squares to pick them, then Run N picked.
- Ask the agent to fix the failures, or one; ask what untested code matters most, or to write tests for a file.
- Back to the latest after choosing an older run.
- Ask the agent to set up tests when the project has none.

## States
- No tests and no runner: an offer to have the agent set tests up.
- Never run on this Mac: every square is an outline and the strip is hidden.
- Running: squares not reported yet pulse; results colour them as they arrive; Stop ends the run.
- An older run chosen: the overview says so, and the map, counts and failures are as that run left them (later runs don't count).

## Edge cases
- Runs are kept per Mac (Application Support/Dante/tests, the newest 40), never in the repo; Home, the timeline and the morning update read the same runs.
- An agent's or job's command counts as a test run when it starts with a known runner (swift test, go test, cargo test, pytest, npm/pnpm/yarn/bun test, jest, vitest, mvn, gradle, dotnet test, xcodebuild test, rspec…) or contains the project's test.command; its results are read from the output it got back, so a very long output may be cut short.
- Runs typed in the terminal aren't recorded.
- A test is matched to results by name; a display-named, generated or parameterised test the code reading doesn't find is counted under "don't match a test Dante read in the code".
- Flaky means a failure followed by a pass in the last twenty runs; a test that passed and then started failing is broken, not flaky.

## Acceptance
- A test Claude ran in a conversation shows in the strip with sparkles and colours the map.
- A failure's link opens the failing assertion.
- Choosing an older run shows that run's failures and the map as it stood then.
- A test whose file changed after its last run is faded.
