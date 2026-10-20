---
id: ship
title: Release
phrases: [ship, release, releases, ci, ci runs, pull requests, deploy, shipping]
---
# Release (Ship › Release)

Release is for shipping: the CI runs, pull requests and a release checklist.

## Shows
- The next release: a version and changelog drafted from the commits since the last tag.
- Release checklist: what's done and what's left.
- CI: the latest GitHub Actions runs on each branch, with the failing step.
- Pull requests for the branch.

## Actions
- Polish the changelog with the agent.
- Create the tag.
- Ask the agent why a CI run failed, or to add CI.
- Open all runs.

## States
- Not a git repository: offers git init in the terminal.
- No GitHub CLI or not signed in: says what to run (gh auth login).
- No workflows: offers to have the agent write one.
- Nothing new since the last tag.

## Acceptance
- A tag is only created after the user presses Create tag.
