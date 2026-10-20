---
id: map.services
title: Services
phrases: [services view, compose services, service graph]
---
# Services (Map › Services)

The Services view on the Map shows the docker compose services and how they depend on each other.

## Shows
- Each compose service, its image or build folder and its ports, linked by depends_on.

## Actions
- Select a service to see its settings; open Local › Services to run it.

## States
- Only offered when the project has a compose file.

## Acceptance
- The links match depends_on in the compose file exactly.
