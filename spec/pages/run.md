---
id: run
title: Health
phrases: [run, runtime, health, errors, alarms, logs, running app, monitoring]
---
# Health (Local › Health)

Health watches the running app, live or on this Mac: its health and the errors in its logs since the window opened.

## Shows
- Live or This Mac (a switch at the top when the project has both, remembered per project on this Mac): Live is the deployed app from `operate:` in .dante/project.yaml; This Mac is the compose services running here. A project with nothing live set up opens on This Mac.
- On This Mac: a check per compose service that builds from the repo and publishes a port, on `http://localhost:<port>` and the health route its code names (`/actuator/health` when the build has Spring's actuator, then `/api/healthz`, `/api/health`, `/healthz`, `/health`, `/livez`, `/readyz`, `/ready`, `/ping`, `/status`, else `/`; tests don't count); errors come from `docker compose logs -f --tail 200`. Alarms are Live only.
- Health checks: each endpoint's state, uptime and when it was last checked.
- Errors since this window opened, grouped, with counts and when last seen.
- Alarms from CloudWatch or a command, when `operate.alarms` is set in project.yaml.

## Actions
- Investigate an error or a failing check with the agent.
- Restart a service.
- Set up health checks and production logs with the agent.

## States
- This Mac with no service built from the repo publishing a port: says there's nothing to check over HTTP and that Docker's own health checks are on Services.
- Nothing set up: says what it can watch and offers to set it up.
- Checking: a check is running.

## Edge cases
- The live app is gone or its tools are missing (a deleted DigitalOcean app, doctl not installed): Live shows the failure; This Mac still works from the compose file.

## Acceptance
- With a compose file and no `operate:` block, the page checks the compose services here instead of offering setup.
- An alarm that starts firing notifies, even when the page isn't open.
