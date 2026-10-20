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
- Tables with columns, keys and indexes; a schema diagram.
- Query results in a grid.
- Query insights: the plan in plain words with index suggestions.
- Migration preview: what a DDL script would change, checked against the schema.

## Actions
- Connect to a database (a URL or host details); create a new local one (a compose service or a SQLite file) with the wizard.
- Run queries; explain a query; preview a migration before running it.
- Turn read-only on or off for a connection (on for anything not on this Mac).
- Ask the agent about the data, or to design or compare the schema with the code.
- Delete a database the wizard created, with or without its data.

## States
- No database: options to create one, connect, or design one with the agent.
- Unreachable: the error, with a hint (container stopped, wrong port, password).

## Edge cases
- Statements run one per argument with a marker after each, so results line up.
- Saved connections are per Mac, never in the repo.

## Acceptance
- A read-only connection refuses statements that change data.
- Passwords never appear on a command line or in a log.
