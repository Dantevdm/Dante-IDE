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
- Values compose needs that .env doesn't set (`${POSTGRES_PASSWORD:?…}`) are caught before a start and filled in with one button: a new password for a secret.

## Shows
- The compose file and each service: image, ports, state and health.
- How they connect: services in columns by what they depend on, each link moving while both ends run, red where a service runs but its dependency doesn't, faint while stopped (shown with two or more services and a depends_on).
- Apps in this project: the runnable apps found in the code (React, Spring Boot, Go and others) with their run commands.
- This project's containers started outside compose.
- Ports: what's listening on the project's ports, with the process, folder and uptime.
- Logs: every service's log lines, filterable by service, level and text, with health checks hidden by default.
- A start, stop or rebuild as one line per service (building step 4 of 7 with the step, started, healthy, failed; how many build steps ran and came from cache) and its errors, with Docker's raw output behind Raw output.
- What Keep running did lately: the last three services brought back, left down or updated, with the time, and under a crash the line from its logs that names the error (`KeyError: 'QUEUE_URL'`).
- Missing values: a card listing each variable the compose file needs that neither .env nor the environment compose runs in sets: required ones (`${VAR:?…}`, `${VAR?…}`, empty counts for the `:` form) and secrets used with no default (`${DB_PASSWORD}`), which would start blank ("would start blank"). Each shows how it'll be filled: "a new random password" for a secret (a name ending in PASSWORD, SECRET, TOKEN, API_KEY, SALT…), the value from .env.example (or .sample, .template, .dist) in an editable field when it isn't a placeholder, or an empty field to type. Names in compose's own error ("required variable X is missing a value") are added too, and that error's banner is then left out.
- Docker files: whether a Dockerfile or compose file exists, with an offer to have the agent write it.

## Actions
- Start all, stop all, rebuild; start, stop or restart one service.
- Find the cause: a note on why a service isn't up, from its health check and the ports.
- Move a service to a free port when its port is taken; stop the process holding it.
- Run an app in a terminal tab (a Node app with a package.json and no node_modules shows Install and run instead, which installs its dependencies with its package manager first); add an app, or all of them, to compose with the agent.
- Open a running service where it's used (`ServiceOpening`): a database (postgres, mysql, mariadb, mongo, sql server, cockroach…) shows Browse, which opens Data on that connection; a service publishing a port shows Open, which opens http://localhost:<port> in the default browser (with several ports, the one most likely to serve pages: 80, 3000, 5173, 4200, 8080, 8000…). Caches, queues and brokers (redis, kafka, nats, rabbitmq…) have no Open, except their admin console when it's published (rabbitmq 15672, minio 9001, mailpit 8025, jaeger 16686).
- Open a service's logs or a shell in it.
- Add to .env: writes the values into .env under a comment (existing lines kept, a key already there replaced), adds .env to .gitignore in a git repo when it isn't there, and refreshes. Start all, Rebuild or a service's Start while a required value is missing doesn't run compose: the card reads "… needed before the services can start" with Add to .env and Start (writes, then runs the start that waited) and Cancel.
- Keep running (header switch, on by default, per project on this Mac): every 20 seconds while the project is open, a service that exited with an error or died, or has been unhealthy for 90 seconds, is restarted with `docker compose up -d <service>`, at most three times in 15 minutes, after which it's left down once with a note. Before each restart and when it gives up it reads the service's last 150 log lines (`CrashReport`): the line naming the error, and the last crash's lines without compose's prefixes (a crash loop's earlier crashes left out). The Find the cause card for a service left down then reads Fix the cause and shows that line; the button hands the agent in charge the excerpt and asks for the fix as a diff, leaving restarts to Dante. A service brought back but crashing gets its own Fix the cause on its newest event. Nothing is sent until you press it; when the compose file changes while services run, `docker compose up -d --remove-orphans` brings them up to date.

## States
- Docker not running: says so and waits.
- No compose file: offers to have the agent write one.
- Remote project: compose runs on the host and ports are forwarded here.

## Edge cases
- A port held by a process this project didn't start is named, and stopping it asks first.
- A service that exited cleanly (status 0) or was stopped by Docker (137, 143) isn't restarted; one you stopped from Dante stays stopped until you start it again. Docker's own restart policy (state restarting) is left to it.
- A database that already has data keeps the password it was created with; the card says so when it generates one.
- Data's Start on a database whose compose service needs a missing value says which and points to Services.
- A remote project checks only its .env, since compose runs in the host's environment.
- `$$` is a literal dollar and commented-out lines are ignored.
- Mass log output is capped to the last 500 lines per view.

## Acceptance
- A running app publishing :4317 has Open, which opens http://localhost:4317 in the browser; a running postgres has Browse, which opens it in Data; a redis has neither.
- Every "not up" service has a reason or says it couldn't find one.
- A compose file with `${POSTGRES_PASSWORD:?Set POSTGRES_PASSWORD in .env}` and no .env shows the card before anything starts; Add to .env writes a generated password, .env is git-ignored, and the next Start all doesn't fail on it.
- Nothing starts without a button press, except Keep running restarting a service that crashed or applying a changed compose file while services run.
- Raw build lines (`#18 sha256:…`) never show unless Raw output is open.
- A dependency link is red only when the service runs and what it needs is down.
