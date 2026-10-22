---
id: docs.diagrams
title: Diagrams
phrases: [diagram, diagrams, drawing, draw, architecture diagram, target architecture, picture, whiteboard, copy and edit]
---
# Diagrams (Docs › Diagrams)

Diagrams are pictures you draw in the Map's own style: cards, groups and moving links like the Infra and System views, saved as files in the repo so they're reviewed like any doc. Start blank, or copy what the Map shows and change it into what's next.

## Highlights
- Copy and edit on the Map turns the Infra or System view into a diagram with the same positions, groups, icons and links.
- Links move like the Map's: pulses run along traffic, dashes flow along pipelines.
- Groups are containers: drop a card on one and it joins and grows to hold it; groups can sit inside a cloud boundary.
- Export as PNG, PDF, SVG (its links still move in a browser) or a Mermaid flowchart.
- The agent in charge can draw or change a diagram: it reads the format through Dante's diagram_guide tool and writes the file.

## Shows
- In the Docs library, a thumbnail of each diagram in the Diagrams and motion strip; a Diagrams group in the sidebar lists them by title.
- A diagram: a dotted canvas with the picture, a bar of things to add on its left, and an inspector on the right.
- The bar above: back to Docs, the title (editable), Saved or Saving…, zoom out, the zoom level (click for 100%), zoom in, zoom to fit, Export, Ask the agent in charge, and the inspector button.
- The building blocks: card (an icon tile, a name, what it is and a monospaced detail), part (the System view's box with chips and a tag), group (a coloured header with an icon and a count of what's inside), boundary (a dashed outer panel such as a cloud, titled above), people, pipeline stage, pipeline source, band title and note text.
- Links: solid, dashed or flowing, with a label in a white capsule, a pulse, an arrowhead, a colour, a width, and a direct or looping route.
- Nothing selected: the inspector shows the title, a note, a count of items, groups and links, and how to use the canvas.
- One node: its kind, name, what it is, detail, chips, tag, icon (a searchable picker), colour (blue, purple, teal, green, amber, red, grey), dashed border, position and size, Fit to contents and Ungroup for containers, front and back, and its links.
- A link: from and to, label, Traffic, Pipeline and Quiet looks, line, pulse, arrow, colour, width, route and Reverse.
- Several: align (left, centre, right, top, middle, bottom), distribute, colour, Group them and Link them in order.
- While moving: guides where edges and middles line up with other nodes.

## Actions
- New diagram (Docs' New sheet, Diagram, or an empty library): a name, then Blank, Infrastructure or System map, and an optional description in your own words ("What should it show?" for Blank, "What should change?" after copying the Map); it's saved as docs/diagrams/<name>.dante-diagram.json (numbered when the name is taken) and opens. With a description the button reads Create and draw, and the agent draws it (or changes the copy) to match.
- Copy and edit (Map, Infra or System view, and inside an opened part): a name, then the view as a diagram, opened in Docs. The Map itself doesn't change.
- Add from the bar (it goes to free space near the middle of the view), or from the component library (cloud services by tier, and apps and services like an identity provider, access governance or single sign-on); double-click empty canvas for a card there.
- Drag to move (snapping to an 8-point grid and to other nodes' edges and middles; ⌥ moves freely); drag a corner to resize; a group moves by its header, or anywhere once selected.
- Drag from a selected node's edge dot to another node to link them; drop on empty canvas for a new linked card.
- Double-click a node to rename it in place, or a link's label to edit it.
- Drag on empty canvas to select several; ⇧-click adds or removes one; ⌘A selects all.
- Delete removes the selection and its links; ⌘C, ⌘X and ⌘V copy, cut and paste (as diagram JSON); ⌘D duplicates; ⌘G groups; ⇧⌘G ungroups; arrow keys nudge (⇧ for more); Esc clears the selection.
- ⌘Z and ⇧⌘Z undo and redo every change, including edits read back from the file.
- Pinch or the zoom buttons to zoom; scroll to pan.
- Export: PNG (twice the size), PDF, SVG or Mermaid through a save panel next to the diagram, Copy as Image, Copy Mermaid, Show the File in Code, Show in Finder.
- Ask the agent (the bar's menu): Draw from a description… (Describe a change… once there's something drawn) and Draw a future version of this… each open a box for your own words with Draw it (⌘↩); Review it against the code, Tidy the layout and Explain it in a paragraph go straight away. The agent saves to the same file (a future version beside it) and the canvas follows.
- What you typed is what the transcript shows ("Draw docs/diagrams/x.dante-diagram.json: …"); the diagram format and the ground rules go with it unseen. The agent draws what you described, takes names from the repo only where they fit it, adds nothing you didn't ask for, and asks when something is unclear.

## States
- An empty diagram: a card saying what to do, with a box for what it should show and Draw it (off until something is typed), and Open the Map.
- Saving shortly after each change, Saved after; a save that fails says why.
- A file that isn't a valid diagram: the reason, Open in Code, and Ask the agent to fix it.
- New diagram's Infrastructure or System map greyed out when the Map found nothing like it; before the Map has been opened they're read from the project on Create, with a message when there's nothing.

## Edge cases
- The file is JSON with sorted keys and default values left out, so diffs stay small; frames are [x, y, width, height].
- A file written by hand or by an agent is read leniently: unknown colours fall back to blue, colour names like compute or security are understood, and nodes without frames are laid out by their links (left to right) and stacked inside their groups.
- A container never shrinks smaller than what it holds; dragging a card out of a group leaves it, dropping it on one joins it, and a group dropped into another nests.
- Changes made to the file outside the editor (an agent, git) are read back as one undoable change; the editor saves before it closes.
- Copy and edit keeps the frames the Map drew, so the copy matches what was on screen at that size.
- PDF and PNG exports are drawn by the same views as the canvas; SVG draws icons as images and uses SMIL, so pulses move without scripts.
- Exports saved under docs/ are listed as docs too.

## Acceptance
- Copy and edit on the Infra view gives a diagram with every stage, resource, tier group, the cloud boundary, users and their links, at the positions the Map drew them.
- A diagram saved, closed and reopened draws the same.
- PNG, PDF and SVG exports look like the canvas in the current theme, and the Mermaid export parses as a flowchart.
- Every node kind and link style looks right in the Light, Dark and Paper themes.
