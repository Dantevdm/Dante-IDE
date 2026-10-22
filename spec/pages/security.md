---
id: security
title: Security
phrases: [security, vulnerabilities, secrets, popia, audit, score, findings]
---
# Security (Quality › Security)

Security scores the project out of a hundred and lists its findings, most serious first: secrets, personal information under POPIA, encryption, injection, containers, CI and dependencies.

## Highlights
- Fix with the agent sends findings to the agent in charge, and the other agent checks the fix.
- A deep audit asks for a read-only review.
- Accepted risks are kept in .dante/security.yaml.
- Findings in tests, docs and examples aren't graded: they're set aside, and a checkbox lists them.

## Shows
- The score and grade (a critical finding caps it at 49), with counts by severity and category. Only code that ships is graded.
- Set aside: findings in tests (each language's own convention: Go's `_test.go` and generated mocks, Python's `test_*.py`, `*_test.py` and `conftest.py`, JS/TS `.test.`, `.spec.`, `.cy.`, Java/Kotlin `…Test`, `…Tests`, `…IT`, Spock/Kotest `…Spec`, Swift and C# `…Tests`, Ruby `_spec.rb`, Dart `_test.dart`, C/C++ `_test.cc`; folders such as tests/, __tests__/, src/test/, testdata/, fixtures/, mocks/, e2e/, cypress/, `…Tests` and `.Tests`), and in docs and examples (docs/, documentation/, examples/, samples/, Markdown). The details line says "N in tests and docs not graded", and the "Tests and docs (N)" checkbox beside "Low and info" adds them to the list, each tagged "in tests" or "in docs". A real service's key (AWS, GitHub, Stripe, OpenAI, Anthropic, Slack, Google, a private key) and dependency advisories are graded wherever they are.
- A project can name more test paths in .dante/security.yaml: `tests:` with folders ("qa/") or globs ("*_it.go").
- What changed since the last scan that found something different: "N new", "N edited, still flagged" and "N fixed" chips. Scanning again without changes keeps them. A finding is the same finding while its rule, file and line text stay the same; the same text again further down a file is a finding of its own, and repeats are matched nearest line first, so moving code doesn't make them new. A line edited so it still has the same problem (same rule, same file, within three lines) is one edited finding, never one fixed and one new.
- New findings carry a "new" tag in the list.
- Findings grouped by category, each with the file and line, what's wrong and how to fix it, and the scanners that found it.
- Scanners: Dante's own rules plus the installed tools (Semgrep, Gitleaks, OSV-Scanner, govulncheck, npm audit, pip-audit), with install commands for missing ones.
- In CI: the command that fails a build on serious problems (`dante scan --fail-on high`, graded findings only; `--all` also lists those set aside).
- What the audit says: the last deep audit's findings.
- Accepted risks, with their reasons.

## Actions
- Scan again.
- Click "N new" to show only the findings new since the scan before. The card is titled "New since the scan at <time>". Click the chip again, or Show all findings, to go back.
- Click "N edited, still flagged" to show only those. Each carries an "edited, still flagged" tag, and opening it shows the line before the edit (struck through) above the line now.
- Click "N fixed" to see what the scan before found that this one didn't. Each row is ticked and struck through. Opening a row shows why it mattered, the line as it was, and Open the file now (or "The file is gone").
- Fix with the agent: sends chosen findings to the agent in charge; the other agent reviews the fix.
- Deep audit: a read-only review by the agent (POPIA sections 19, 22 and 72 included).
- Accept the risk, with a reason, saved to .dante/security.yaml for everyone on the project.
- Open a finding's file at its line.
- Check dependencies online (off by default; sends dependency names to OSV.dev).

## States
- Scanning, or the agent scanning through `security_report`: a progress line names who's scanning.
- No findings: the full score and a note on what was checked.

## Edge cases
- Comments, placeholders, example files, binaries, data files and `never` paths are skipped; tests are one step milder except for secrets.
- Bundled third-party libraries are skipped by every scanner: a folder that keeps its own LICENSE (or LICENCE, COPYING) inside a resources, assets, static, public, lib or third_party folder. A monorepo's own packages, which have licences too, are still scanned.
- A class-style test name needs its capital: `OrderServiceTest.java` is a test, `Latest.java` isn't; `…Spec` only counts on the JVM, so Swift's `PageSpec.swift` is code.
- A finding that becomes set aside (a new `tests:` path, or after updating Dante) is neither fixed nor new.
- No graded findings but some set aside: the card says how many aren't graded, with Show them.
- `nosec`, `dante:ignore` and `gitleaks:allow` on a line suppress it.
- SA ID numbers and card numbers are checked properly (date, citizenship digit, Luhn); providers' test cards are skipped.

## Acceptance
- After fixing a finding and scanning, "1 fixed" appears, and clicking it lists that finding with the line as it was.
- Editing a flagged line so it still has the problem and scanning shows "1 edited, still flagged", not "1 new" and "1 fixed".
- A log call whose only sensitive word is in its message ("password changed by its owner") isn't flagged; one that logs the value, or formats it in ("password: %s"), is.
- A secret in an agent's edit stops the edit for approval at any approval level.
- The score is the same from the page, `dante scan` and `security_report`.
- A hard-coded password in `api/users_test.go` doesn't lower the grade and shows only with "Tests and docs" ticked, tagged "in tests"; the same line in `api/users.go` does lower it. An AWS key in the test file lowers it too.
