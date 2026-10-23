---
id: tests
title: Tests
phrases: [tests, test, testing, test results, failures, coverage, quality]
---
# Tests (Quality › Tests)

Tests runs the project's tests and shows failures, flaky tests, the tests written per area and the functions no test names, which the agent can draft tests for.

## Highlights
- Run changed runs only the tests the changes touch.

## Shows
- Last run: results by suite or category, failures first with their output.
- How the run went: the runner, up to six suites (failing first, the rest as "N more") and the passed, failed and skipped totals, linked in the Infra view's ink.
- Written: the tests found in the code, sorted into categories (logic, views and screens, and so on).
- History: the last runs on this Mac, with flaky tests (passing and failing on the same code).
- Untested: files and declarations no test names, most lines first.

## Actions
- Run tests: the detected runner (swift test, go test, pytest, Maven, Gradle, jest, vitest and others; with nothing at the root, each app folder's runner in its folder, one after another); run changed, the open file's tests, one kind, or tests picked by hand.
- Repeat a narrowed run from the header's main button.
- Write tests: ask the agent to draft tests for ticked untested code.
- Ask the agent to set up tests when the project has none.
- Open a failure or test in Code at its line.

## States
- No test runner found: an offer to set tests up with the agent.
- Running: output streams as it runs; Stop ends it.
- Never run on this Mac: Last run and History are empty.

## Edge cases
- Runs are recorded per Mac (`TestRecord`), not in the repo.
- Test names are matched to code by name, so a test that calls code without naming it doesn't count it as tested.

## Acceptance
- A failure's line opens the failing assertion.
- Run changed picks only tests for the changed files.
- The run picture shows failing suites before passing ones.
