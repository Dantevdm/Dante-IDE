---
id: data
title: Data
phrases: [data, database, databases, tables, sql, queries, postgres, schema]
---
# Data (Local › Data)

Data connects to the project's databases: browse tables, run queries, read query plans with index suggestions and preview migrations before they run.

## Highlights
- It finds databases from compose, env files and the project's containers.
- Passwords are kept in the Keychain.

## Shows
- Databases: each connection found or added, with its engine, where it runs and whether it's reachable.
- Overview: the connection's details, size, tables and views, the largest tables, and in the code: the libraries and the evidence the connection came from.
- Suggestions, from the repo's SQL and the code that queries it: indexes for foreign keys and filtered columns, primary keys, money and time types, SELECT * and queries in loops, each with why, where and the SQL.
- Tables with columns, keys and indexes; a schema diagram.
- The schema diagram's relationship lines carry a moving dash while the connection is online.
- Query results in a grid.
- Query insights: the plan in plain words with index suggestions.
- Migration preview: what a DDL script would change, checked against the schema.

- A database on DigitalOcean (added from Ship › Deploy's Explore in Data) shows a cloud mark in the sidebar with "DigitalOcean · <app>'s dev database · <city>" under its name, and a "DigitalOcean · dev database" chip in its header that opens Ship › Deploy.

## Actions
- Connect to a database (a URL or host details); create a new local one (a compose service or a SQLite file) with the wizard.
- Run queries; explain a query; preview a migration before running it.
- Completion while writing a query (`SQLCompletion`, from the connection's schema): after FROM, JOIN, INTO, UPDATE and TABLE the tables and views; after `alias.` or `table.` that table's columns (aliases defined later in the statement count); elsewhere the columns of the tables the statement names (all tables when it names none), then keywords in the case being typed, the engine's functions and tables. A space opens the list only after FROM/JOIN; names that need it are quoted (Postgres mixed case).
- Zoom the schema diagram: the mouse wheel or a pinch zooms around the pointer, ⌘ and a trackpad scroll zooms too, plain trackpad scrolling pans, and the corner has −, the percentage (back to fit) and +. It's drawn as vectors, so text stays sharp at any zoom.
- Turn read-only on or off for a connection (on for anything not on this Mac).
- Ask the agent about the data, or to design or compare the schema with the code.
- Copy a suggestion's SQL, or ask the agent to make the suggested changes as a new migration.
- Arrive from the Map (a database's chip, Browse in Data on a table) with that connection and table open.
- Delete a database the wizard created, with or without its data.

## States
- No database: options to create one, connect, or design one with the agent.
- Unreachable: the error, with a hint (container stopped, wrong port, password).
- A table from the Map that isn't in the database yet: a note that the migrations haven't run against it.

## Edge cases
- A compose database that doesn't publish its port (no `ports:`) is reached with the client inside its container ("psql inside the db container"), even when psql is installed on this Mac, since nothing listens on localhost for it.
- Statements run one per argument with a marker after each, so results line up.
- Saved connections are per Mac, never in the repo.

- A DigitalOcean database is read-only when added and keeps its password in the Keychain; if its password changes, Explore in Data on Ship › Deploy fetches it again.

## Acceptance
- A read-only connection refuses statements that change data.
- Passwords never appear on a command line or in a log.
