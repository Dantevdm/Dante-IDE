---
id: deploy
title: Deploy
phrases: [deploy, deploy it, deployments, digitalocean, digital ocean, app platform, hosting, go live, the live site, deploy to digitalocean, cloud deploy]
---
# Deploy (Ship › Deploy)

Deploy puts the project on DigitalOcean's App Platform and keeps an eye on it: sign in through the browser, let Dante write the app spec, deploy, then watch deployments, health, metrics and logs, with security findings and recommendations for the whole set-up.

## Highlights
- Signing in happens in your own browser, where you're already signed in to DigitalOcean; Dante never sees a password and keeps the sign-in in the Keychain.
- Dante writes `.do/app.yaml` from the code: Dockerfiles, the apps it recognises, plain HTML folders, compose's Postgres and the env examples. You review and commit it; it's what gets deployed.
- When the code is on GitHub, GitLab or Bitbucket, App Platform builds it and every push deploys; otherwise Dante builds the images here and pushes them to your DigitalOcean registry.
- Nothing is made or changed until you confirm the deploy, with the price in front of you.
- Security and recommendations checks the spec, the Dockerfiles, the live site's headers, and the app's health and alerts.

## Shows
- Not signed in: a DigitalOcean card saying what signing in does and what Dante asks for (App Platform, the registry, metrics, reading databases), with Sign in with DigitalOcean (Waiting for the browser… until the reply comes, five minutes at most), and the reason in amber when it was cancelled, refused or timed out.
- Before the first deploy: What Dante would deploy, a row per component (service, static site, worker, job) with where its code comes from, its folder, port and size (static sites say Free), and each database; where the code comes from overall and what was decided, sentence by sentence; anything it couldn't place in amber (an app without a Dockerfile when building here, a database engine App Platform has no dev database for); the region picker; Write .do/app.yaml. Once the file exists the card is The app spec, read from it, with Open .do/app.yaml. Signed in, Use an existing app lists the account's apps.
- The deploy sheet: the components, whose account it goes on first ("On the <team> team’s account and bill", from the sign-in, with how to switch teams), what will happen (a new app in the region, a container registry made on the free Starter plan, images built here for linux/amd64), warnings when a git-hosted branch has commits not pushed or uncommitted changes, a dev database's lack of backups, secret fields for every SECRET without a value that DigitalOcean doesn't already hold, and the price a month (DigitalOcean's own for the spec, else estimated from the instance sizes).
- Deploying: the step (checking the spec, making the registry, building or pushing each image, sending the spec, DigitalOcean deploying) with Show the build output; a failure in red with Try again, Ask the agent to fix it and, when App Platform can't read the repository, Let App Platform read the repository.
- The live app: its address (opens the site), the current deployment's state with a pulsing dot while it runs, the region and who's signed in; while deploying, its steps as chips joined by a line (done, running, failed); a failed deployment's step and reason with Ask the agent to fix it; the last deployments with their state, cause, commit and age (Live marked), All N deployments.
- Components: each with its health dot, kind, replicas ready, size, CPU and memory now with a sparkline of the last hour, and restarts today in amber.
- Logs: Build, Deploy or Runtime for every component or one, loaded on Load (runtime from the live deployment, build and deploy from the latest).
- Security and recommendations: a line counting security findings and recommendations (green when there's nothing to fix), then Security and Recommendations groups and tips behind Show tips; each row has a severity, title, where, why it matters and the fix, and its area (secrets, network and HTTPS, image, reliability, monitoring, cost, data); a line saying what was checked.

## Actions
- Sign in with DigitalOcean: Dante registers itself once per Mac as a public client (no secret exists) with the exact loopback address `http://127.0.0.1:<port>/callback` (DigitalOcean redirects to the registered address exactly, port included), listens on that port again on later sign-ins and updates the registration only when the port is taken, opens DigitalOcean's authorize page in the default browser with PKCE, takes the reply on a one-shot listener, and keeps the refresh token in the Keychain; access tokens live in memory for their hour. Signed in as <name · team> with Sign out sits under the plan, and Sign out is in the … menu once an app is linked; signing out revokes the token and forgets it.
- Write .do/app.yaml: writes the plan with a header saying what the file is, and opens it. Never overwrites an existing file.
- Deploy… / Deploy again…: reads the file, works out what to build and which secrets are missing, prices it, and opens the sheet. Deploy in the sheet then makes the registry if needed, builds and pushes the images (tagged with the commit, plus the time when there are uncommitted changes), creates or updates the app, links it to the project, and watches it every five seconds until it's live or failed, with a notification when Dante isn't in front.
- Use an existing app: links one of the account's apps to the project (kept per project on this Mac).
- Cancel deployment, Roll back to this (asks first), Refresh, and the … menu: Open in DigitalOcean, Unlink from this project, Delete app… (asks first, saying it can't be undone).
- Ask the agent to fix these / it: sends the findings, or the failure with the end of its log, to the agent in charge, who changes only the repo and never deploys.

## States
- No app found in the code: says so and suggests asking the agent for a Dockerfile.
- `.do/app.yaml` that can't be read: says which part is wrong, in red.
- The linked app was deleted elsewhere: the link is forgotten and the page says so.
- The sign-in is no longer accepted: back to the sign-in card.
- Signed out: the plan and the checks of the file and Dockerfiles still show.

## Edge cases
- App Platform builds static sites only from git; built here, a static site is served by nginx as a small service instead, which costs like one.
- Built here, all components share one registry repository named after the app, with a tag per component, because the free registry plan holds one repository. The registry is made in the region nearest the app's.
- The images are built for linux/amd64 whatever this Mac is. The push signs in with credentials that expire in half an hour, written to a Docker config in a folder of its own that's removed straight after; the person's own Docker config is never touched.
- A Dockerfile Dante writes for a static site is passed to the build only, never written into the project, and drops dot files (.env, .git) in a stage that isn't pushed.
- Secrets: the file holds SECRET variables without values. Typed values are sent once and not saved; on a later deploy DigitalOcean's encrypted value is sent back unchanged. A value written into the file is a critical finding.
- An update whose spec didn't change starts a deployment of what's pushed, so Deploy again always deploys.
- Pricing swaps images not yet built for a stand-in, so the size is priced before anything is built.
- Requests only go to api.digitalocean.com and DigitalOcean's sign-in, without following redirects; logs come from the signed links the API gives. The live site is asked only for its own headers.

## Acceptance
- Nothing is created, changed, deployed, rolled back or deleted on DigitalOcean without a button press, and creating, rolling back and deleting are confirmed with what they do; the deploy sheet shows the team and the price first.
- The sign-in is never on a command line, in a file or in an agent's environment, and Dante never reads doctl's config or the browser's cookies.
- A secret's value never goes into the repository or user defaults.
- With a Dockerfile and no git host, Write .do/app.yaml then Deploy builds, pushes and deploys the image, and the page shows the app live with its address.
