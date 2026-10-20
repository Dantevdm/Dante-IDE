# Dante's spec

What every page in Dante is for, what it shows and does, and how it behaves, as flat files
any build of Dante reads. The Mac app bundles this folder: voice opens and explains pages from
it, the agents get it in their brief, and `dante mcp` serves it through `dante_pages` and
`show_page`. Another build (Windows, say) reads the same files and runs the same fixtures.

## Layout

- `places.yaml`: the rail, top to bottom. A place with several pages shows them as tabs.
- `pages/<id>.md`: one file per page, and per view inside a page (`map.infra.md` is the Map's
  Infra view). The id is the page's name in code, so never rename one.
- `fixtures/`: cases every build must pass. `voice.yaml` is what people say and what Dante does.

## A page's file

```markdown
---
id: map.infra            # page, or page.view
title: Infrastructure    # what the tab or view is called
area: settings           # only for pages outside the rail (settings, stage)
phrases: [infra, cloud]  # words that name it, for voice
---
# Infrastructure (Map › Infra)

One paragraph: what it's for. Voice reads this aloud, so it's a sentence or two.

## Highlights
- What voice adds when asked to explain it, a sentence each.

## Shows
## Actions
## States
## Edge cases
## Acceptance
```

Every section is a list of plain sentences. Shows is what's on screen, Actions what the user
can do, States the loading, empty and error cases, Edge cases what's easy to get wrong, and
Acceptance what must hold for the page to be right.

## Keeping it current

A new page or view gets its file in the same change that adds it; `FeatureGuideTests` fails
when an area has no file or a place names a page that doesn't exist.
