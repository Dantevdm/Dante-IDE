---
id: map
title: Map
phrases: [map, system map, architecture, system, diagram, how it fits together]
---
# Map

The Map draws the system from its code: the clients and their screens, the API routes, the backend, the data and outside services, with arrows along the real calls.

## Highlights
- Select a box to see what it uses and what uses it.
- Boxes with an expand mark open: a part into its folders, a folder into its classes, a class into its methods with their routes, tables and calls.
- Tables open the other way, back through the code to the routes that reach them, with their columns.
- A web app or one of its screens opens in the browser: when its dev server isn't running, Dante says so, starts it in a terminal tab and opens the page once it's up.
- Export writes the map as Mermaid into .dante/architecture.md.
- Routes carry a lock: secured, open for a reason (a health check, sign-in, a webhook, docs), or open with nothing to explain it, which is flagged.
- A table shows its columns, keys and what references it, with suggestions (missing indexes, keys, money in floating point) and copying at every level.
- Selecting a box glides it into view; links draw themselves and pulse along the busiest paths.

## Shows
- Five lanes, left to right: Clients (web and mobile apps and their screens), API (route groups), Backend (services and packages), Data (databases, tables, queues, caches) and Outside (third-party services).
- The Backend lane in the order the code runs, when its parts use each other: Starts here (what nothing else in the lane uses, like the app's main), Uses (the parts it calls, and parts linked to nothing else in the lane), Shared (what the rest lean on, like core), each a column of its own under the lane's name.
- Links between boxes along real code paths: fetch calls to routes, routes to their handlers, imports, queries naming tables, hosts called.
- A box's detail line: its kind, how many routes, screens or methods it has, its test coverage when a coverage report exists.
- The view picker: System (this view), Infra, Modules and, with a compose file, Services.
- An inspector beside the map for the selected box: what it uses, what uses it, its environment variables (secrets flagged), its files, and the code of a selected method.
- For a route group: Access, each open route with why it's open (health check, sign-in, webhook, docs, permitAll in the security config) or that nothing explains it.
- For a table: its columns (keys, types, nullability, what each foreign key names), what references it, the file and line of its CREATE TABLE, and its suggestions.
- For a database: its tables (click one to select it) and suggestions for the whole schema: foreign keys and filtered columns without an index, tables without a primary key, money in floating point, timestamps without a zone, SELECT *, and a query run once per item in a loop.

## Actions
- Click a box to select it and dim everything it isn't linked to.
- Copy and edit (in the header, for the System view and inside an opened part): name it, and what's shown becomes a diagram in Docs with the same positions, lanes as groups, icons and links (see docs.diagrams).
- Open a box with an expand mark (or double-click it): parts open into folders, folders into files or classes, a class into its methods; the breadcrumb leads back out.
- Open a table to trace it back: the code that reads or writes it, up to the routes that reach that code, with its columns and the tables its foreign keys name.
- Open in browser on a web app or a screen: finds the dev server's port and the screen's route, starts the dev server in a terminal tab when it isn't listening (after asking), waits for the port and opens the page. Before asking it checks the app can start: its package manager (npm, pnpm, yarn or bun, from the lockfile) must be installed, else it says so and points to Settings › Tools; a package.json without node_modules shows "Install and start", which runs `<tool> install` and then the start command in one terminal tab, waiting up to 15 minutes instead of 150 seconds. The command's exit status is written to a file in /tmp when it stops, so a dev server that stops shows why at once ("A command it needs wasn't found…" for 127) with Install dependencies and try again and Show the terminal.
- Open a file or method in Code.
- The container chip on a database box opens it in Local › Data; Browse in Data on a table opens that table there (with a note when migrations haven't created it yet).
- Copy a table as CREATE TABLE (with later ALTERs), Markdown, a SELECT query or its column names; a database as the whole schema, a Mermaid ER diagram, Markdown or table names; right-click a column to copy it.
- Copy a suggestion's SQL, or ask the agent to make the changes (a new migration, code fixed in place).
- Ask the agent to check open routes nothing explains.
- Export writes a Mermaid diagram into a marked section of .dante/architecture.md.

## States
- Building: the map is built off the main thread; the last map for the window shows meanwhile.
- No parts found (an empty or non-code folder): an empty state that says what the map looks for.
- Inside a part: lanes keep their names, with parts outside the backend that link to nothing removed.
- Web launch: finding, needs start (with the reason: nothing listening on the port), starting, waiting, opening, opened or failed with the reason.

## Edge cases
- Tables come only from CREATE TABLE statements in the repo (and ORM table names); a live database is never read.
- A file naming six or more services is a catalogue, not a caller, so it draws no links.
- Route examples in comments are skipped.
- A route annotation spread over several lines (`@GetMapping(` then `value = "/status",` then `produces = …)`, as generated controllers write them) is read whole; `value =` or `path =` wins over other strings in it.
- Parts that use each other in a loop keep their first tier rather than being stretched across.
- Access comes from Spring Security config (permitAll, authenticated, ignoring, anyRequest) and annotations, Express-style middleware, Python decorators and dependencies, and Go middleware; without any auth library, routes are open with that as the reason.
- Migrations apply in name order, so ALTERs and later CREATE INDEX statements change the table they name.
- Suggestions are static: table sizes are unknown, so index advice is for when tables grow.
- Tests and test folders aren't parts.
- Opening a backend folder retains project-wide security rules, including configuration and build files outside that folder; route access stays the same as in the whole-system map.
- A hash router's screens open at /#/path; a Vite base path is put in front.
- Dynamic route segments end the path, since there's no id to fill in.

## Acceptance
- Starting a frontend whose node_modules is missing offers Install and start rather than failing; one whose start command isn't found reports it within a few seconds and offers to install its dependencies.
- A 6,000-file repo maps in a few seconds.
- Every link on the map can be explained by a line of code the inspector can open.
- Opening then backing out returns to the same selection.
- Open in browser never starts a server without the user pressing Start.
