---
id: tests
title: Tests
phrases: [tests, test, testing, test results, failures, flaky tests, test map, coverage, quality]
---
# Tests (Quality › Tests)

Tests shows every test in the code by kind (Front-end, Back-end, Integration, Security and so on) with how each kind stands and a Run button for it, every run on this Mac whoever started it, what failed and why, and the code no test names.

## Highlights
- Every run counts: yours from this page, and the test commands Claude, Codex and jobs run, so the page always shows the latest result.
- Tests are grouped by kind, not folder: Front-end (tests of the web app's code), Back-end (server code tested on its own), Unit (code on neither side), Integration, Security, End-to-end, UI and Performance, or the project's own kinds from test.categories.
- Each app folder with its own runner (Maven, Gradle, npm, Go, pytest, Cargo, Swift), up to four folders down, runs in its own folder; Maven and Gradle results are read from the JUnit reports they write.
- Choose a run in the strip to see the page as that run left it.

## Shows
- Overview: one sentence on where the tests stand ("2 failing of 32, 1 flaky", "All 32 passing", "32 tests in the code, none run on this Mac yet"), who ran last and when, and the passing, failing, flaky, not run and changed-since counts. While a run goes it says how long it has run and how many passed and failed so far.
- Runs on this Mac: a bar per run, oldest on the left (up to 32): red for the share that failed, green for the rest, grey for skipped, fully red when the build or runner broke before the tests; shorter bars are runs of only some tests. A glyph under each says who ran it (a person for you, sparkles for the agent in charge, a hammer for a job, a cloud for CI). Hovering or choosing a bar names the runner, time, command and outcome; the run going now pulses at the end.
- Failures: each failing test of the shown run (or of the run going now) with its suite, its messages and the file and line, marked flaky when it has also passed recently.
- A section per kind: its name, how many tests and which app folders they're in, a line saying what the kind is, its state in words ("3 failing · 40 passing · 12 not run") and as a bar (red failing, amber flaky, green passing, grey skipped, the rest not run), and Run. Show the tests by folder lists its folders (named without the part they all share), failing first, each with its state and a run button; a folder opens to its tests, each with a dot for its state, its file and line, "changed since" when its file changed after the run that set it, and a run button. Clicking a test opens it at its line; hovering says who ran it last and its message.
- When there are tests but no runner Dante recognises: a note saying what it looked for, with Ask the agent to work out the command and set test.command.
- When a run failed outside its tests (before any test ran, or with every test passing: a package that doesn't build, a setup step, a panic): a title that says which ("10 tests passed, but the run still failed"), the reason in a sentence when the output says ("shop/orders didn’t build"), and the lines that name it picked from the whole output (compile errors come first in `go test ./...`, a bare FAIL last), "…" where lines were left out, then the end. Ask the agent to fix it (sends the command and those lines; it finds the cause, fixes it and runs the tests again), Run again, and Copy.
- Code without tests: a sentence saying how many of the code's functions and types no test names, a bar of the share that is named, and the five files with the most, each with what's untested and Write tests; Show all lists every file.

## Actions
- Run all: every app folder's runner, each in its folder, one after another (or test.command when the project sets it); the runners show as chips beside it. Greyed out, with a reason, when there's none.
- Run a kind, a folder or one test from its section: each test runs with its own app's runner, narrowed (Maven -Dtest, Gradle --tests, the test files for npm and pytest, names for go, swift and cargo).
- Run for changes: the tests for the files changed in the working tree.
- Re-run failed, or one failure from its row; Run these again repeats a narrowed run.
- Ask the agent to fix the failures, or one; ask what untested code matters most, or to write tests for a file.
- Back to the latest after choosing an older run.
- Ask the agent to set up tests when the project has none.

## States
- No tests and no runner: an offer to have the agent set tests up.
- Never run on this Mac: every kind says "not run yet" and the strip is hidden.
- Running: results fill the kinds' bars as they arrive; the Run buttons wait; Stop ends the run.
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
- A test whose file changed after its last run says "changed since".
- In a repo with a Maven API and a React app under services/, Run all is enabled, runs both, and the tests sit under Back-end and Front-end, with security tests under Security.
