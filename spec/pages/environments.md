---
id: environments
title: Services
phrases: [services, env, environment, environments, local, docker, compose, containers, ports, local setup]
---
# Services (Local › Services)

Services is the local environment: the docker compose services and their logs, the project's apps you can run, its other containers, and the ports in use.

## Highlights
- It says why a service isn't up and can move a port that's taken.
- Apps in this project can be run, or added to compose by the agent.
- Keep running brings a crashed service back on its own, and applies compose file changes to what's running.

## Shows
- The compose file and each service: image, ports, state and health.
- How they connect: services in columns by what they depend on, each link moving while both ends run, red where a service runs but its dependency doesn't, faint while stopped (shown with two or more services and a depends_on).
- Apps in this project: the runnable apps found in the code (React, Spring Boot, Go and others) with their run commands.
- This project's containers started outside compose.
- Ports: what's listening on the project's ports, with the process, folder and uptime.
- Logs: every service's log lines, filterable by service, level and text, with health checks hidden by default.
- A start, stop or rebuild as one line per service (building step 4 of 7 with the step, started, healthy, failed; how many build steps ran and came from cache) and its errors, with Docker's raw output behind Raw output.
- What Keep running did lately: the last three services brought back, left down or updated, with the time.
- Docker files: whether a Dockerfile or compose file exists, with an offer to have the agent write it.

## Actions
- Start all, stop all, rebuild; start, stop or restart one service.
- Find the cause: a note on why a service isn't up, from its health check and the ports.
- Move a service to a free port when its port is taken; stop the process holding it.
- Run an app in a terminal tab (a Node app with a package.json and no node_modules shows Install and run instead, which installs its dependencies with its package manager first); add an app, or all of them, to compose with the agent.
- Open a service's logs or a shell in it.
- Keep running (header switch, on by default, per project on this Mac): every 20 seconds while the project is open, a service that exited with an error or died, or has been unhealthy for 90 seconds, is restarted with `docker compose up -d <service>`, at most three times in 15 minutes, after which it's left down once with a note; when the compose file changes while services run, `docker compose up -d --remove-orphans` brings them up to date.

## States
- Docker not running: says so and waits.
- No compose file: offers to have the agent write one.
- Remote project: compose runs on the host and ports are forwarded here.

## Edge cases
- A port held by a process this project didn't start is named, and stopping it asks first.
- A service that exited cleanly (status 0) or was stopped by Docker (137, 143) isn't restarted; one you stopped from Dante stays stopped until you start it again. Docker's own restart policy (state restarting) is left to it.
- Mass log output is capped to the last 500 lines per view.

## Acceptance
- Every "not up" service has a reason or says it couldn't find one.
- Nothing starts without a button press, except Keep running restarting a service that crashed or applying a changed compose file while services run.
- Raw build lines (`#18 sha256:…`) never show unless Raw output is open.
- A dependency link is red only when the service runs and what it needs is down.
