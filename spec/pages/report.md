---
id: report
title: Report
phrases: [quality report, report, quality gate, gate, executive report, ratings, grades, sonarqube, sonar, quality overview, how good is the code]
---
# Report (Quality › Report)

Report is the project's quality on one page, in the manner of SonarQube's executive report: a quality gate that passed or failed, and Tests, Security, Review and Coverage each graded A to E, for all the code and for new code. It exports as a PDF to hand on.

## Highlights
- New code is this branch's changes since it left the main branch, plus the working tree; on the main branch itself it's the last 30 days.
- Every letter says why it is what it is when you hover it.
- Nothing is run to make the report: it reads the last test runs on this Mac, the saved security scan, the review marks and a coverage report the tests already wrote.

## Shows
- A header: the project, the branch, when it was checked, the number of code files with the main languages, and the quality gate as PASSED (green), FAILED (red) or INCOMPLETE (amber: nothing fails, but a condition can't be judged yet because no test has run or the code was never scanned) with each condition beneath it, its value and a tick, a cross or a question mark.
- Four rating cards, Tests, Security, Review and Coverage: a large letter in a circle coloured from green (A) through amber (C) to red (E), the figure behind it ("3 failing", "2 serious", "92%", "61%") and what it's out of, and a tinted On new code box with that code's letter and figure. A dash means there's nothing to grade (no tests, not scanned, no coverage report).
- Security findings by severity: Critical, High, Medium and Low rows, each tinted, with the count in all the code and in new code.
- Coverage: a ring filled to the share of measured lines covered, the lines, and new code's figure.
- Tests passing: a ring for the tests with a result that passed, and how many are written.

## Actions
- Click a rating card or a lower card to open its page (Tests, Security or Review).
- Check again: reads everything afresh.
- Export PDF: saves the report as one page, without the animations, and shows it in Finder.

## States
- Loading: a spinner until the tests have been read from the code.
- No tests in the code, never scanned, no review marks, no coverage report: that card shows a dash and says what would grade it.

## Edge cases
- Grades. Tests: E when more than a tenth fail, D when any fail or when the latest run failed outside the tests (a package that doesn't build, a setup step: "Run failed", and No failing tests fails with "the last run failed outside them"), C when some are flaky or most haven't run on this Mac, B when some haven't run or changed since their run, A when every test passed on its latest run. Security: by the worst finding, E critical, D high, C medium, B low, A none (info doesn't count). Review: the share of files read as they are now, A from 90%, B 75%, C 50%, D 25%; a concern holds it at C at best. Coverage: A from 80%, B 70%, C 50%, D 30%.
- The gate's conditions: no failing tests; no high or critical security findings in new code; changed files reviewed, once anyone has marked a file in Review; coverage on new code at least 80%, when a coverage report is there.
- A project whose repository is a folder inside it compares new code in that folder's repository and names files as the project does.
- Tests count as new code when their file changed, or when they go with a changed file.

## Acceptance
- A failing test anywhere fails the gate, and the Tests card shows D or E.
- A critical finding only in old code leaves the gate's security condition passing but grades Security E.
- Export PDF writes a PDF that opens in Preview and shows the same letters as the page.
