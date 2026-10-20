---
id: map.modules
title: Modules
phrases: [modules, packages, dependency graph, imports]
---
# Modules (Map › Modules)

The Modules view on the Map shows the code's packages or folders and which imports which.

## Shows
- Go projects: the packages from go.mod and their imports.
- Other projects: top-level folders as modules, linked by imports between them.

## Actions
- Select a module to highlight what it imports and what imports it; open its folder in Code.

## Edge cases
- Vendored and generated folders are left out.

## Acceptance
- Every link is an import the code has.
