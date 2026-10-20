---
id: run
title: Health
phrases: [run, runtime, health, errors, alarms, logs, running app, monitoring]
---
# Health (Local › Health)

Health watches the running app: its health and the errors in its logs since the window opened.

## Shows
- Health checks: each endpoint's state, uptime and when it was last checked.
- Errors since this window opened, grouped, with counts and when last seen.
- Alarms from CloudWatch or a command, when `operate.alarms` is set in project.yaml.

## Actions
- Investigate an error or a failing check with the agent.
- Restart a service.
- Set up health checks and production logs with the agent.

## States
- Nothing set up: says what it can watch and offers to set it up.
- Checking: a check is running.

## Acceptance
- An alarm that starts firing notifies, even when the page isn't open.
