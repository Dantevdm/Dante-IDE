---
id: data
title: Data
phrases: [data, database, databases, tables, sql, queries, postgres, schema, sql server, backups, restore a backup]
---
# Data (Local › Data)

Data connects to the project's databases: browse tables, run queries, read query plans with index suggestions and preview migrations before they run.

## Highlights
- It finds databases from compose, env files and the project's containers.
- Passwords are kept in the Keychain.
- Postgres, MySQL, SQLite and SQL Server; SQL Server backups (.bak) can be restored into its container, and backed up from it.

## Shows
- Databases: each connection found or added, with its engine, where it runs and whether it's reachable.
- Overview: the connection's details, size, tables and views, the largest tables, and in the code: the libraries and the evidence the connection came from.
- Suggestions, from the repo's SQL and the code that queries it: indexes for foreign keys and filtered columns, primary keys, money and time types, SELECT * and queries in loops, each with why, where and the SQL.
- Tables with columns, keys and indexes; a schema diagram.
- The schema diagram's relationship lines carry a moving dash while the connection is online.
- Query results in a grid.
- Query insights: the plan in plain words with index suggestions.
- Migration preview: what a DDL script would change, checked against the schema.
- Backups (SQL Server): `.bak` files in the project (outside node_modules, bin, obj and vendor) and in the container's /var/opt/mssql/backup, each with where it is, its size and age.


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
- Restore… a backup (or Restore from a file… anywhere on this Mac): Dante copies it into the container's backup folder, reads RESTORE HEADERONLY and FILELISTONLY, and shows what it holds (database, server, date, SQL Server version, files). Restore as names the database (the backup's own name first); when that database exists the button says Replace and a warning says everything in it goes and connected apps are put out. Make sa the owner (on by default) runs ALTER AUTHORIZATION afterwards, since a backup from another server keeps an owner this one doesn't know. The restore runs against master: SINGLE_USER WITH ROLLBACK IMMEDIATE, RESTORE … WITH MOVE (files to /var/opt/mssql/data as `<db>.mdf`, `_log.ldf`), REPLACE, RECOVERY, then MULTI_USER.
- Back up now…: a COPY_ONLY backup (`<db>-yyyy-MM-dd-HHmm.bak`) made in the container and copied to a folder you choose, beside the project's other backups by default; Show in Finder when it's done.

## States
- No database: options to create one, connect, or design one with the agent.
- Unreachable: the error, with a hint (container stopped, wrong port, password).
- Backups for a SQL Server outside a container Dante knows: a sentence saying to restore it on the server itself.
- Restore sheet: reading, ready, restoring, done or failed with SQL Server's own message.
- A table from the Map that isn't in the database yet: a note that the migrations haven't run against it.


## Edge cases
- A deployed app's database isn't shown here: DigitalOcean lets only the app reach a dev database. Connections an earlier version saved as "<db> on DigitalOcean" are forgotten, with their passwords.
- SQLite files kept by tools aren't databases: anything inside a dot folder (`.angular/cache`'s `angular-compiler.db`, `.next`, `.dante`) or a cache, tmp or coverage folder is left out.
- Remove from Dante… on a detected connection hides it in Data on this Mac (the file and the code that found it stay); a saved one is forgotten with its password.
- A compose database that doesn't publish its port (no `ports:`) is reached with the client inside its container ("psql inside the db container"), even when psql is installed on this Mac, since nothing listens on localhost for it.
- Statements run one per argument with a marker after each, so results line up.
- Saved connections are per Mac, never in the repo.
- SQL Server is found from compose services running an mssql image (in any folder, each with its own .env), JDBC URLs in a service's environment, appsettings*.json ConnectionStrings (matched to a compose service by port), and .csproj packages (SqlClient, EF Core SqlServer). `.\SQLEXPRESS` and `(localdb)` strings are Windows-only and skipped.
- SQL Server runs through sqlcmd (on this Mac, or the image's /opt/mssql-tools18 inside the container), with the password in SQLCMDPASSWORD and the script on stdin in GO batches; tables browse with OFFSET … FETCH, names quote as [name], and plans come from SHOWPLAN_TEXT.
- A compose file in a subfolder runs its commands in that folder.


## Acceptance
- A read-only connection refuses statements that change data.
- Passwords never appear on a command line or in a log.
- A SQL Server compose service in a subfolder shows as a connection, browses its tables, and restoring a backup into a new name leaves the original database untouched.
