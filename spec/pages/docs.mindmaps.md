---
id: docs.mindmaps
title: Mind maps
phrases: [mind map, mind maps, mindmap, mindmaps, xmind, brainstorm, ideas map]
---
# Mind maps (Docs › Mind maps)

Mind maps are ideas round a central topic, saved as XMind files (.xmind) in the repo, so they open in XMind and back. Draw one by hand with the keyboard, or have the agent in charge draft one from the project.

## Highlights
- Real XMind files: maps made in XMind open here, and what Dante saves opens in XMind, keeping XMind's styles, markers, relationships, images and other sheets.
- Typing builds the map: Tab adds a subtopic, Return the next topic, and you're straight into its name.
- The agent drafts a map from the project's code, docs and history, or suggests what's missing from one.
- Copy a map as a markdown outline or a Mermaid mind map for a doc.

## Shows
- A Mind maps group in the Docs sidebar and library, each map by its file name.
- A map: the central topic in the middle in the accent colour; main branches round it, the first on the right and then round to the left so both sides are about as tall, each in its own colour (blue, purple, teal, green, amber, pink, orange, indigo, cyan, red, then again) as a tinted box with a curved line from the centre; deeper topics as text on a line in their branch's colour. A topic with notes or a link shows a small mark after its title, and its labels under it.
- A folded topic: a dot in its branch's colour on the far side with the number of topics hidden under it.
- The bar: the map's name, a sheet picker when the file has several, Saved or Saving…, Add a subtopic, Add a topic after this one, Fold or unfold, Delete, Share (Copy as Outline, Copy as Mermaid, Open in XMind, Show in Finder), Ask the agent in charge, and the notes button.
- The notes panel on the right: the chosen topic's title, notes, labels (commas between them) and link (with a button to open a web link), and how many topics are under it.
- Zoom: the wheel, a pinch, or the −, percentage (fit) and + controls at the bottom right; the map opens fitted.

## Actions
- New mind map (Docs' New sheet, Mind map, or an empty library): the central topic and optionally what it should cover; Create saves docs/mindmaps/<name>.xmind (numbered when taken) and opens it; Create and draft also asks the agent in charge to fill it in from the project.
- Click a topic to choose it; double-click, Space or Rename to rename it in place (Return keeps it, Esc leaves it as it was).
- Tab adds a subtopic under the chosen topic; Return adds a topic after it (a main branch when the centre is chosen). Delete or ⌫ removes it and everything under it.
- Arrows move between topics: ↑ and ↓ to the nearest topic above or below on the same side, → and ← along the branch (outward goes to its first subtopic, inward to its parent; from the centre, into that side).
- ⌥↑ and ⌥↓ move a topic among its siblings; . or the dot folds and unfolds a branch.
- Right-click a topic: Add Subtopic, Add Topic After, Rename, Fold or Unfold, Move Up, Move Down, Delete.
- ⌘Z and ⇧⌘Z undo and redo every change, including changes read back from the file; typing a title or notes undoes as one step.
- Ask the agent: it reads the map as an outline, says what's missing or unclear and offers to add it.
- `dante mindmap outline|mermaid|write|new` does the same from a terminal or an agent: an outline is "# Central topic" then "-" items nested by two spaces.

## States
- A new map: just the central topic, chosen, ready for Tab.
- Saving half a second after each change, Saved after; a save that fails says why.
- A file that isn't an XMind file (or has no sheets): the reason and Show in Finder.

## Edge cases
- XMind 2020 and later store content.json; XMind 8 and older content.xml, which is read (titles, notes, labels, links, folding, floating topics) and saved back as content.json.
- Only the first sheet's tree changes when the agent writes an outline; topics whose title stays the same keep their notes, labels, link and XMind styling, and the map keeps its other sheets, floating topics, theme and pictures.
- Changes made to the file outside Dante (XMind, an agent, git) are read back as one undoable change.
- Long titles wrap at about 240 points; nothing overlaps however many topics a side has.
- Phone and iPad companions read a map as its outline.

## Acceptance
- A map made in XMind, opened, changed and saved here opens in XMind with its styles, markers and other sheets intact.
- A map saved here passes `unzip -t` and opens in XMind.
- Writing an outline and reading it back gives the same outline.
- Every theme draws the branches, the centre and folded dots legibly, light and at night.
