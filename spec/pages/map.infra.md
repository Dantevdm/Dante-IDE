---
id: map.infra
title: Infrastructure
phrases: [infra, infrastructure, pipelines, pipeline, cloud, aws, azure, cloudformation, terraform, deployment, devops]
---
# Infrastructure (Map › Infra)

The Infra view on the Map shows how a change is delivered and where it runs: the pipelines stage by stage, then the cloud resources by tier, with traffic flowing from users to the data.

## Highlights
- It reads CloudFormation, Terraform and ARM templates and Azure DevOps, GitHub Actions and GitLab pipelines.
- How it works says in sentences how a change ships and how a request travels.
- Select a stage or resource to see its steps or settings and open its file.
- The agent in charge can explain it, review it, write an architecture document, or write a missing pipeline or templates.

## Shows
- A summary: how many pipelines, stacks and resources, and the clouds they're on.
- How it works: a short story in sentences, from a push to running code and from a user's request to the data.
- Delivery band: each pipeline in a lane of its own, non-prod first, then prod, then any other: the lane has a coloured edge and a label (NON-PROD in the accent colour, PROD in red, as on Ship's Pipelines card) with the branches it deploys from and, at the right, a Runs button (the latest run's state and age when Dante has seen one for that environment) that opens Ship › Release, then the pipeline's source and its stages in order. Azure template conditions (`${{ if … }}:` around stages, jobs, steps or dependsOn) are opened up, so stages switched on by a parameter's default show.
- Cloud band: users, then tiers (edge, compute, data), with images, security and observability resources beside them; animated links show traffic between tiers.
- An inspector for the selected stage or resource: steps or properties, the template file and line.

## Actions
- Select a stage or resource to inspect it; Open goes to its file in Code.
- Copy and edit: name it, and the view becomes a diagram in Docs (docs/diagrams/) with the same positions, tier groups, cloud boundary, users and links, to change into what comes next and export (see docs.diagrams).
- Ask the agent in charge to explain the setup, review it for risks, write an architecture document, or write a missing pipeline or infrastructure templates.

## States
- No infrastructure files: an empty state naming the formats it reads, with the agent's offer to write them.
- Only pipelines or only templates: the band that has content shows; the other says what's missing.

## Edge cases
- Files over 2 MB are skipped.
- Template parameters and references are shown by name; values from parameter files aren't resolved.
- Long resource names wrap at camel-case boundaries.

## Acceptance
- Every resource and stage shown comes from a file the inspector can open.
- The story's sentences only name resources the files declare.
