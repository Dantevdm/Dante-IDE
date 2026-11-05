---
id: bliksem
title: Bliksem
phrases: [bliksem, load test, load testing, stress test, hammer it, fuzz, fuzzing, fuzz test, chaos, chaos testing, break things, throw garbage, performance test, how much load can it take]
---
# Bliksem (Quality › Bliksem)

Bliksem puts the running system under strain in three ways: Hammer it (load: ramp up virtual users, spike, and find where it breaks), Throw garbage (fuzz: odd, huge and hostile input on every route, looking for crashes, leaks and hangs) and Break things (chaos: stop, freeze or kill one of the project's compose services under a light load, put it back and time the recovery). It only ever sends to this Mac and test hosts.

## Highlights
- The routes come from the Map: every route the code serves, reads chosen, writes only when you turn them on.
- Dante suggests only servers this project runs (its compose services, and programs listening here from inside the project's folder), asks each for the first few routes, and fills in the one that knows them. Nothing else on this Mac is asked, since a usual port may be another project's server.
- Fuzz probes look for injection without doing harm: nothing drops, deletes or updates.
- A chaos run always puts the service back, even when you press Stop; a run cut off by a quit is put right the next time the page opens.
- Ask the agent to fix it hands the run's figures or findings to the agent in charge.

## Shows
- Three mode tiles: Hammer it, Throw garbage, Break things, each with a line on what it does; the one running shows a spinner.
- Target: an address field and chips for the project's servers that answered (on hover, what runs there and "which knows 3 of 3 routes"), and a line saying which hosts are allowed.
- The mode's settings. Load: users at peak (a stepper, 1 to 100; the spike doubles it, at most 200), how long (30 s, 1, 2 or 5 min), and a strip of the stages (Warm-up, Ramp, Spike, Cool-down) that fills as the run goes. Garbage: chips for each kind (empty and null, wrong types, too long and too big, odd characters, SQL, NoSQL, script and template injection, path traversal, format strings, broken JSON). Break: the service (this project's running compose services, a database first) and how (Stop it, Freeze it, Kill it, Restart it) with what that does.
- Results. Load: the stage and users while running, then a verdict ("It held up to 40 users: 850 requests a second, 95% within 42 ms" in green, or "It broke at 60 users, 31 s in: 12% of requests failed" in red), figures (requests, a second, p50, p95, p99, failed), and a chart of requests a second as bars (failed requests red), the 95th percentile as an amber line, users as a faint area and the breaking point as a red rule; while running the newest bar and the line's end pulse. Fuzz: a progress bar, then problems worst first, each with its severity, what it is ("Shows a database error", "Crashes with a server error", "Shows a stack trace", "Echoes a script back unescaped", "Hangs"), the route, what was sent and what came back, the line that gave it away, advice, and how many requests hit it; or a green line when nothing did. Chaos: the phase (Measuring normal, Breaking it, Broken, Putting it back, Watching it recover) and a chart with the outage shaded red, then a sentence ("With db stopped, 100% of requests failed, mostly 503. It recovered 3 s after it was back.") and figures.
- Routes: every route with its method (reads green, writes amber), a tick for the chosen ones, and during a load run each route's requests, usual answer and p95. Include writes, All and None sit in its header.

## Actions
- Hammer it / Throw garbage / Break <service>: starts a run of the chosen mode on the chosen routes. Stop ends it (a chaos run puts the service back first).
- A suggestion chip fills the target.
- Click a route to choose it or leave it out; writes can be chosen only with Include writes on.
- Ask the agent to fix it: sends the run's figures, slowest routes, findings or recovery to the agent in charge.

## States
- No routes in the code: says the routes come from the Map, which found none.
- Nothing this project runs is listening: says to start the app or type its address.
- No compose service running (Break things): says so, with Open Services.
- An address that isn't local or a test host: refused with a sentence saying how to allow a test host.
- Nothing answered during a load run: the verdict asks whether the app is running at that address.

## Edge cases
- Allowed hosts are the agents' browser's: localhost, 127.0.0.1, ::1, .localhost and .test names, and hosts under `browser: hosts:` in .dante/project.yaml (their subdomains too). Every request is checked, and redirects aren't followed.
- A 404 for a made-up id isn't a failure; a 5xx, a 429 or no answer is. The breaking point is the first second with at least five requests that had more than 5% failing or a p95 over a second, and the next second too, so one hiccup doesn't count.
- Path parameters in any style ({id}, :id, <int:id>, [slug]) get a sample value: 1 for ids, a fixed uuid for uuids, "sample" otherwise. Load sends `{}` as the body of a write.
- A fuzz response is judged against the route's normal answer, so a route that already fails isn't blamed on the garbage. Stack traces count only on error answers.
- Chaos only touches services declared in this project's compose file and running; Keep running is told to leave the service alone during the run.
- Fuzz with writes on sends bodies to write routes; without, writes are skipped.

## Acceptance
- Against an app on localhost, Hammer it draws bars each second and ends with a verdict and per-route figures.
- An address outside this Mac and the test hosts is refused before anything is sent.
- A route that returns a database error to a quote shows as a critical "Shows a database error" finding.
- After Break things with Stop it, the service is running again whether the run ended or was stopped.
