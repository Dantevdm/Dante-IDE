---
id: run
title: Health
phrases: [run, runtime, health, errors, alarms, logs, running app, monitoring, grafana, dashboards, metrics]
---
# Health (Local › Health)

Health watches the running app, live or on this Mac: its health and the errors in its logs since the window opened.

## Shows
- Live, This Mac or Grafana (a switch at the top when the project has two or more, remembered per project on this Mac): Live is the deployed app from `operate:` in .dante/project.yaml; This Mac is the compose services running here; Grafana is the project's own Grafana. A project with nothing live set up opens on This Mac.
- Grafana: found in any compose file at the project's top (`compose.monitoring.yaml`, `docker-compose.dev.yml` as well as the default one) as a service on a `grafana/grafana` image with a port published here (`${PORT:-3000}` filled from .env and the environment; development files win when two publish the same port). A tab per dashboard the repo provisions (JSON files in the folder mounted at Grafana's dashboards path, by title), plus All dashboards; the choice is remembered per project. Grafana shows inside Dante in Dante's light or night, with its own sign-in kept per project on this Mac (a website data store of its own; Dante never types the password). Panels only hides Grafana's menus (kiosk). Links to anything but that Grafana open in the browser. Errors and checks keep being watched while it's shown.
- On This Mac: a check per compose service that builds from the repo and publishes a port, on `http://localhost:<port>` and the health route its code names (`/actuator/health` when the build has Spring's actuator, then `/api/healthz`, `/api/health`, `/healthz`, `/health`, `/livez`, `/readyz`, `/ready`, `/ping`, `/status`, else `/`; tests don't count); errors come from `docker compose logs -f --tail 200`. Alarms are Live only.
- Health checks: each endpoint's state, uptime and when it was last checked.
- Errors since this window opened, grouped, with counts and when last seen.
- Alarms from CloudWatch or a command, when `operate.alarms` is set in project.yaml.

## Actions
- Grafana: switch dashboards, Panels only, Reload, Open in the browser; when it isn't running, Start it runs the project's own command in a terminal tab (the mise task that brings that compose file up, else `docker compose -f <file> up -d`).
- Investigate an error or a failing check with the agent.
- Restart a service.
- Set up health checks and production logs with the agent.

## States
- This Mac with no service built from the repo publishing a port: says there's nothing to check over HTTP and that Docker's own health checks are on Services.
- Nothing set up: says what it can watch and offers to set it up.
- Checking: a check is running.

## Edge cases
- Grafana not running: says which compose file runs it on which port, shows the start command, and checks again every few seconds.
- Grafana not published to this Mac (only `expose`), or a remote project: no Grafana view.
- The live app is gone or its tools are missing (a deleted DigitalOcean app, doctl not installed): Live shows the failure; This Mac still works from the compose file.

## Acceptance
- A project whose Grafana is in `compose.monitoring.yaml` gets a Grafana view with a tab per provisioned dashboard.
- With a compose file and no `operate:` block, the page checks the compose services here instead of offering setup.
- An alarm that starts firing notifies, even when the page isn't open.
