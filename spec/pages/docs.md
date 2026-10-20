---
id: docs
title: Docs
phrases: [docs, documentation, readme, library, documents]
---
# Docs

Docs is the project's documentation library: markdown with diagrams, PDFs and Word files, grouped by folder.

## Shows
- The library: recently changed docs, a card per group with excerpts and thumbnails.
- A doc: markdown rendered with Mermaid diagrams (flowchart, sequence, ER) drawn natively; PDFs, images and Word files in a viewer.
- A sidebar of groups and sections with a filter.

## Actions
- Open a doc; filter; edit a markdown doc in Code.
- Back and forward between docs.

## States
- No docs: says where it looks (docs/, documentation/, .dante/ and markdown anywhere).

## Edge cases
- PDFs, images and Word files count as docs only under docs/, documentation/ and .dante/; elsewhere they're app assets.
- HTML blocks in a README (a centred header) become images, headings and paragraphs.

## Acceptance
- Every Mermaid diagram the parser supports draws without a browser.
