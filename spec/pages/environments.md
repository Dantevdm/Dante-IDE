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

## Shows
- The compose file and each service: image, ports, state and health.
- Apps in this project: the runnable apps found in the code (React, Spring Boot, Go and others) with their run commands.
- This project's containers started outside compose.
- Ports: what's listening on the project's ports, with the process, folder and uptime.
- Logs: every service's log lines, filterable by service, level and text, with health checks hidden by default.
- Docker files: whether a Dockerfile or compose file exists, with an offer to have the agent write it.

## Actions
- Start all, stop all, rebuild; start, stop or restart one service.
- Find the cause: a note on why a service isn't up, from its health check and the ports.
- Move a service to a free port when its port is taken; stop the process holding it.
- Run an app in a terminal tab (a Node app with a package.json and no node_modules in its folder or above it shows Install and run instead, which installs its dependencies with its package manager first); add an app, or all of them, to compose with the agent.
- Open a service's logs or a shell in it.

## States
- Docker not running: says so and waits.
- No compose file: offers to have the agent write one.
- Remote project: compose runs on the host and ports are forwarded here.

## Edge cases
- A port held by a process this project didn't start is named, and stopping it asks first.
- Mass log output is capped to the last 500 lines per view.

## Acceptance
- Every "not up" service has a reason or says it couldn't find one.
- Nothing starts without a button press.
