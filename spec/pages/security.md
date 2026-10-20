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

## Shows
- The score and grade (a critical finding caps it at 49), with counts by severity and category.
- Findings grouped by category, each with the file and line, what's wrong and how to fix it, and the scanners that found it.
- Scanners: Dante's own rules plus the installed tools (Semgrep, Gitleaks, OSV-Scanner, govulncheck, npm audit, pip-audit), with install commands for missing ones.
- In CI: the command that fails a build on serious problems (`dante scan --fail-on high`).
- What the audit says: the last deep audit's findings.
- Accepted risks, with their reasons.

## Actions
- Scan again.
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
- `nosec`, `dante:ignore` and `gitleaks:allow` on a line suppress it.
- SA ID numbers and card numbers are checked properly (date, citizenship digit, Luhn); providers' test cards are skipped.

## Acceptance
- A secret in an agent's edit stops the edit for approval at any approval level.
- The score is the same from the page, `dante scan` and `security_report`.
