---
id: docs
title: Docs
phrases: [docs, documentation, readme, library, documents, new document, decision record, runbook, how-to guide, architecture overview, motion, studio, video, videos, deck, slides, presentation, animation, explainer, brand kit]
---
# Docs

Docs is the project's documentation library: markdown with diagrams, PDFs and Word files, grouped by what they describe, where New starts a document from a template (written by you or drafted by the agent from the code), the Studio, where the agent makes videos, decks and explainers that move, and diagrams drawn in the Map's style.

## Highlights
- New document: a README, decision record, runbook, how-to guide or architecture overview with its outline, in the folder the project keeps them in, written by you or drafted by the agent from the code.
- The library reads like a directory: docs kept beside the code are named after what they describe (portal-alb-stack, orders-portal), and every group and folder folds.
- Diagrams: draw in the Map's style, or copy the Map's Infra or System view and change it; export as PNG, PDF, SVG or Mermaid.
- Studio: describe a piece and the agent in charge storyboards it, builds it as a scene drawn from the real system map and infrastructure in the project's brand, looks at its own frames and fixes them.
- A piece plays in Docs with its narration in Dante's natural voice, and renders frame by frame to a 1080p or 4K MP4.
- Made by both agents, a piece has two versions to switch between, play side by side and choose from; the other agent critiques either one from stills of its beats.
- Share a piece as one HTML file that plays in any browser, or a PDF of its slides or storyboard; present a deck full screen on the Stage.

## Shows
- The library, top to bottom: the header (the doc and folder counts; Brand kit, Add files… and New), Recently changed (one row of as many as fit, two to four, each with what it belongs to, its age and first line; only past six docs), the Diagrams and motion strip (a thumbnail per diagram and per motion piece; only when there are some), then a section per group.
- Groups: the project's own (Project, Docs, Specs, Decisions, Runbooks, Notes, Phases), then one per top-level folder holding two or more docs (Infrastructure, Pipelines; titled from the folder, with the folder as `infrastructure/` beside it; a folder named like a built-in group shows as `notes/`), then Around the code for top-level folders with a single doc.
- In a group, a heading per folder named after what the docs belong to: the last folder that isn't documentation/, docs/ or doc/ (portal-alb-stack), with the folders above it in monospace (aws/cloudformation) and a count; under it a row per doc: title, first line and age, six before Show all N, images as a grid of thumbnails.
- Group and folder headings have a chevron and fold on a click; folds last while the window is open.
- The New document sheet: eight kinds in a grid (Document, README, Decision, Runbook, How-to, Architecture, Diagram, Video or deck) with a line each; Title (not for a README); Save in (the kind's usual folder, docs/, the project folder and every folder that holds docs, most docs first); the Draft it with <agent> from the code switch (remembered), with an About field when it's on; the path it will write; Cancel and Create (Create and draft when drafting).
- A diagram opens in its editor (see docs.diagrams).
- A doc: markdown rendered with Mermaid diagrams (flowchart, sequence, ER) drawn natively; PDFs, images and Word files in a viewer; HTML reports and slides in a built-in web preview.
- When an agent opens an HTML file for you (`open_file`), it shows in a sheet over the window, with Open in Code and Done.
- Beside a markdown doc: its outline (On this page) and the project files it names in `code` (Files it mentions, shown only when there are some).
- A sidebar of groups and sections with a filter.
- Every motion piece (docs/motion/<name>/motion.yaml) in the Diagrams and motion strip and the sidebar's Motion group.
- A piece: the scene on a dark stage, captions of the narration, a timeline with its narration lines and a deck's slide stops, and script errors when the scene has any.

## Actions
- Open a doc; filter; edit a markdown doc in Code.
- New (the header, or an empty library): the sheet starts on README when the project has none at its root, else Document. Picking Diagram or Video or deck swaps to that sheet. Create writes the file with its outline (never over an existing file) and opens it Side by Side for writing; Create and draft opens it to read and asks the agent in charge to fill in the outline from the code, configuration, other docs and git history, writing TODOs where it can't tell.
- Fold or unfold a group or a folder by clicking its heading.
- Back and forward between docs.
- New piece, in four steps (the step chips in the header jump between them once there's an idea; Next is the default button, Cancel the cancel one):
  1. Idea: pick one of four ideas or describe one; title, kind (video, slide deck, animated explainer), length (15 s to 2 min) and shape (16:9, 9:16, 1:1, 4:5).
  2. Look: a live gallery of twenty animation styles (Particles, Liquid morph, Holographic, Neon glow, Wireframe 3D, Glassmorphism, Kinetic type, Isometric, Clay 3D, ASCII art, Gradient mesh, Comic book, Split-flap, Retro VHS, Halftone, Bauhaus, Pixel art, Blueprint, Art deco, Neo-brutalism) and four illustration choices (Hairline figures, Open Peeps, drawn by the agent, none), each tile animating in its own style and the kits drawn live by the bundled libraries. Up to two styles: the first leads (badge "1 · leads"), the second accents ("2 · accent"); a third replaces the second; picking a style lifts the same-named ban. "No illustrations" excludes the kits.
  3. Brief: the studio's questions by section (purpose, audience, message, format, story, look, motion, sound, rules), each as chips plus "in your words", with sensible answers already in; the footer counts the answered ones.
  4. Who makes it: the agent in charge, the other one in a job, or both (two versions of the same brief at once, "Make both versions"); the project data it draws (system map, infrastructure, numbers); a line saying the look.
  The answers become BRIEF.md; each picked style and kit adds its recipe (how to build it inside the scene contract) to the brief.
- Play, pause and scrub a piece (Space plays; arrows step a deck's slides); ask the agent to change it at the moment shown; ask it to fix script errors.
- Export (into the piece's renders/ folder, then Open or Show in Finder): a 1080p or 4K MP4 with the narration mixed in; a web page, one HTML file carrying the scene, its modules and the libraries they import, its images, data and the fonts, that plays by itself in any browser from disk (a deck holds at each stop; arrows and Space move on); a PDF of a deck's slides (the frame where each holds), or a storyboard of anything else (the frame in the middle of each narration line with the line under it, else eight moments).
- Present: the piece full screen on the Stage (in its window when the Stage is already open in one). A deck holds at each stop until →, ↓, Page Down, Space, Return, a click or a clicker; ←, ↑ and Page Up go back a slide; C shows or hides the captions; Esc ends it (and closes the Stage when it opened for it). By voice, "next slide" and "go back a slide", and while presenting "next" and "back". The line being said at a hold finishes before the sound stops. The slide number and a hairline of progress sit faint at the bottom.
- Versions: when another agent made the piece too (its folder `<name>-codex` or `<name>-claude`, here or still in a job's worktree), a strip under the header names each maker's version (with "job" while it's in one). Pick one to play it; Compare plays both side by side in step (the timeline, Space and the arrows drive both; only the shown one is heard); Use <maker>'s version copies its files into the piece's folder, sending the files there to the Trash (renders stay), after a confirmation. Changes asked for a version still in a job go to that job's conversation.
- Notes (the header's count; amber when something breaks renders): Dante's lint of the scene, each finding opening its line, with Ask to fix them; and Critique: Ask <the other agent> for a critique renders stills of every stop and narration line onto a contact sheet in renders/critique/ and asks the other agent (or the same one with fresh eyes when it's alone), read-only, as a motion designer who didn't make it. Its verdict and notes come back marked fix, polish or good, each time a link to that moment; tick off what not to send, then Send the notes to the maker. Critiques are ledger jobs of kind critique.
- Brand kit opens .dante/brand.yaml (written from the project's own colours, fonts and logo the first time); Refresh project data rebuilds data.json from the code.

## States
- No docs: says where it looks (docs/, documentation/, .dante/ and markdown anywhere), with New document…, New diagram… and New motion piece….
- New document: a README in a folder that already has one can't be created (the path line says so in amber and Create is off).
- A piece loading, playing, paused, voicing its narration, rendering or drawing a PDF (with progress and Cancel), saved, or failed with the reason; an export that couldn't carry a file names it.
- A critique: not asked (says what the critic will do), running (with seconds), done, or failed with the reason.

## Edge cases
- Names: a decision is numbered after the highest in its folder (`docs/decisions/0008-share-one-certificate.md`, its heading `# 0008. …`); a README is named by its folder; any other doc is its title as a file name, with -2, -3 when taken. The kind's folder is the one the project already uses (.dante/decisions, docs/decisions, docs/adr…; docs/runbooks; docs/guides), else that default.
- Templates' placeholder lines are italic and say what goes there; the architecture overview starts with a Mermaid flowchart.
- PDFs, images, HTML and Word files count as docs only under docs/, documentation/ and .dante/; elsewhere they're app assets.
- The HTML preview loads only static files (pages, styles, scripts, images, fonts, media) from inside the project, never dot folders, env files or the rules' never paths, and nothing from the network; links elsewhere don't navigate. A file that can't load says why, with Try again.
- An agent can only open files inside the project (symlinks are followed and checked), never a URL or a never path.
- HTML blocks in a README (a centred header) become images, headings and paragraphs.
- A scene draws any moment from its time alone (no timers), so playing, presenting and rendering show the same frames; Math.random is seeded.
- Scenes load from their own folder, Dante's fonts and the project's images and models, never env files or the rules' never paths, and nothing from the network.
- Bundled libraries (three.js, hairline, DiceBear Open Peeps) are imported by name through an import map Dante adds to the page; a page with its own import map keeps it. In a render, requestAnimationFrame and performance.now follow the frame being drawn, so a library with its own clock renders the same every time.
- The Look gallery's animations pause when the window is hidden, like any web page; picks still work from the keyboard (Tab, Return or Space) and VoiceOver reads each tile's name and summary.
- Renders stay out of git (the piece's .gitignore); the scene, manifest, storyboard and data are committed. Nothing inside a piece's folder is listed as a doc, and another agent's version isn't listed beside the piece it's a version of.
- A manifest names its maker (`maker: Claude`), so versions are labelled after the agent that made them.
- An exported page can't carry modules that import each other in a circle; it says which.
- Served text files say they're UTF-8, so a scene without <meta charset> still reads right.
- Narration needs the natural voice (Settings › Claude); without it pieces play and render silent, with captions.

## Acceptance
- In a project whose docs sit in infrastructure/aws/cloudformation/<stack>/documentation/, the library shows an Infrastructure group with a heading per stack, not one Elsewhere pile.
- Each kind in the New sheet writes a file at the path the sheet showed and opens it.
- Every Mermaid diagram the parser supports draws without a browser.
- A rendered frame matches the preview at the same time.
- 4K renders at 3840×2160 without upscaling.
- An exported web page plays from disk with no server and no network, three.js included.
- Every style and kit in MotionLooks has a tile in the gallery, and a picked one's recipe is in the brief.
