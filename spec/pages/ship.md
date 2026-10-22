---
id: ship
title: Release
phrases: [ship, release, releases, ci, ci runs, pull requests, deploy, shipping, pipelines, pipeline, azure devops, deployments, prod, non-prod, heal the pipeline]
---
# Release (Ship › Release)

Release is for shipping: the pipelines and how each environment stands, pull requests and a release checklist.

## Shows
- The next release: a version and changelog drafted from the commits since the last tag.
- Release checklist: what's done and what's left.
- Pipelines (Azure DevOps when the git remote is on dev.azure.com or visualstudio.com, else GitHub Actions): a lane per environment, non-prod then prod (from the pipeline's name, its YAML file and its stage names: nonprod, uat, dev, test, staging are before production; prod, production, live are production), each with its latest run (number, branch, commit, age, status), its stages as chips joined by a line (the running one pulses and a packet travels into it, as in the Infra view), the last good run and its commit, how many of the last twenty passed and how long a good run usually takes.
- A failed run: where it failed (stage › job › step), the first error Azure DevOps reported (or the log's last error line), whether it looks like a flake (a timeout, the network, a busy registry, a lost agent), and the end of the failing step's log (Show the log).
- History: every run Dante has seen in this project on this Mac (up to 300, kept in Application Support/Dante/pipelines, so it outlasts the service's first page and shows while offline), newest first, eight at a time (All N), each with its environment, status, number, branch, why it started, how long it took and when; click one for its stages, failure, who started it, its file and Open the run.
- Watching: while the project is open Dante looks every 20 seconds while a run is going and every 90 seconds otherwise; the status bar shows a running pipeline and its stage, or that the latest run of an environment failed (click for Release).
- With no pipelines found (no Azure remote and no workflows): the old CI card, which offers to have the agent add CI.
- Pull requests for the branch.

## Actions
- Polish the changelog with the agent.
- Create the tag.
- Ask the agent why a CI run failed, or to add CI.
- Azure DevOps token: paste a personal access token (Build: Read & execute) and Save; it's kept in the Keychain per organisation and only sent to dev.azure.com; Make one in <organisation> opens the tokens page. Use another token when it's refused.
- Heal it: the agent in charge gets the run, its pipeline file, each failed step's errors and the end of its log, and is asked to say what went wrong (code, pipeline definition, environment such as a secret or permission, or a flake), fix what's in the repo and check it, say exactly what has to change elsewhere, and never run, deploy or push. It runs in a job of its own when jobs can run here, else in the main conversation.
- Re-run <failed stage> (Azure DevOps: the failed stage's jobs again; GitHub: gh run rerun --failed). In prod it asks first, saying it deploys what's in that run. The first button is Re-run when the failure looks like a flake, else Heal it.
- Notify me: a notification when a run starts or finishes, with a sound when one fails or prod finishes (asks macOS for permission when turned on).
- Heal by itself (per project, on this Mac): when a non-prod run fails, a flake runs its failed stage once more and anything else starts a heal job, once per run. Prod is never touched without you.
- Look now, and Open (the project's pipelines in Azure DevOps, or the workflow runs).
- Open all runs.

## States
- Not a git repository: offers git init in the terminal.
- No GitHub CLI or not signed in: says what to run (gh auth login).
- Azure DevOps without a token, or a refused one: says what the token needs; the history seen before still shows.
- No workflows: offers to have the agent write one.
- Nothing new since the last tag.

## Acceptance
- A tag is only created after the user presses Create tag.
- A prod stage only runs again after the user confirms; Heal by itself never acts on prod, and acts on a failed run at most once.
- The token is never on a command line, in a file or in an agent's environment.
