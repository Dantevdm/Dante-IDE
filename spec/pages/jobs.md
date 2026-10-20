---
id: jobs
title: Jobs
phrases: [jobs, job, background jobs, worktrees, board]
---
# Jobs (Agents › Jobs)

Jobs are agents working beside the main conversation, each in its own git worktree, with their changes to merge or discard, and job types that start on their own when CI fails.

## Highlights
- Away mode lets a job carry on without asking for routine steps for a set time.

## Shows
- New job: a brief, a type and a task to work on.
- Waiting for you: jobs with an approval or question.
- Running and finished jobs: their phase, changes (files, lines, commits) and outcome.
- Job types: the built-in ones (builder, pipeline-watcher) and the project's own in .dante/jobs, with Watch CI for ci-failed types.

## Actions
- Start a job; open it in the panel; answer its approvals.
- Merge (commits what's left and merges the branch into the main checkout) or discard (removes the worktree and branch); both are confirmed.
- Away mode: let a job carry on for a set number of minutes without asking for edits, builds, tests and local git steps.
- Make a new job type, or copy a built-in one to edit.
- Watch CI: start a job for each new CI failure.

## States
- Making its worktree; running; waiting; paused after a restart (opening it picks up the conversation); merged; discarded.

## Edge cases
- Jobs never push, tag, merge, rebase, pull, switch branches, delete, deploy or edit outside their worktree.
- Off for remote projects and folders without git.
- A job link without the local key is confirmed and never runs away.

## Acceptance
- A job's edits never touch the main checkout until Merge.
