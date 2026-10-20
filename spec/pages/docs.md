---
id: docs
title: Docs
phrases: [docs, documentation, readme, library, documents, motion, studio, video, videos, deck, slides, presentation, animation, explainer, brand kit]
---
# Docs

Docs is the project's documentation library: markdown with diagrams, PDFs and Word files, grouped by folder, and the Studio, where the agent makes videos, decks and explainers that move.

## Highlights
- Studio: describe a piece and the agent in charge storyboards it, builds it as a scene drawn from the real system map and infrastructure in the project's brand, looks at its own frames and fixes them.
- A piece plays in Docs with its narration in Dante's natural voice, and renders frame by frame to a 1080p or 4K MP4.

## Shows
- The library: recently changed docs, a card per group with excerpts and thumbnails.
- A doc: markdown rendered with Mermaid diagrams (flowchart, sequence, ER) drawn natively; PDFs, images and Word files in a viewer.
- Beside a markdown doc: its outline (On this page) and the project files it names in `code` (Files it mentions, shown only when there are some).
- A sidebar of groups and sections with a filter.
- The Studio card at the top of the library, and a Motion group with every piece (docs/motion/<name>/motion.yaml).
- A piece: the scene on a dark stage, captions of the narration, a timeline with its narration lines and a deck's slide stops, and script errors when the scene has any.

## Actions
- Open a doc; filter; edit a markdown doc in Code.
- Back and forward between docs.
- New piece, in four steps (the step chips in the header jump between them once there's an idea; Next is the default button, Cancel the cancel one):
  1. Idea: pick one of four ideas or describe one; title, kind (video, slide deck, animated explainer), length (15 s to 2 min) and shape (16:9, 9:16, 1:1, 4:5).
  2. Look: a live gallery of twenty animation styles (Particles, Liquid morph, Holographic, Neon glow, Wireframe 3D, Glassmorphism, Kinetic type, Isometric, Clay 3D, ASCII art, Gradient mesh, Comic book, Split-flap, Retro VHS, Halftone, Bauhaus, Pixel art, Blueprint, Art deco, Neo-brutalism) and four illustration choices (Hairline figures, Open Peeps, drawn by the agent, none), each tile animating in its own style and the kits drawn live by the bundled libraries. Up to two styles: the first leads (badge "1 · leads"), the second accents ("2 · accent"); a third replaces the second; picking a style lifts the same-named ban. "No illustrations" excludes the kits.
  3. Brief: the studio's questions by section (purpose, audience, message, format, story, look, motion, sound, rules), each as chips plus "in your words", with sensible answers already in; the footer counts the answered ones.
  4. Who makes it: the agent in charge, the other one in a job, or both (two versions of the same brief at once, "Make both versions"); the project data it draws (system map, infrastructure, numbers); a line saying the look.
  The answers become BRIEF.md; each picked style and kit adds its recipe (how to build it inside the scene contract) to the brief.
- Play, pause and scrub a piece (Space plays; arrows step a deck's slides); ask the agent to change it at the moment shown; ask it to fix script errors.
- Render 1080p or 4K MP4 into the piece's renders/ folder, with the narration mixed in; play it or show it in Finder.
- Brand kit opens .dante/brand.yaml (written from the project's own colours, fonts and logo the first time); Refresh project data rebuilds data.json from the code.

## States
- No docs: says where it looks (docs/, documentation/, .dante/ and markdown anywhere), with New motion piece.
- A piece loading, playing, paused, voicing its narration, rendering (with progress and Cancel), rendered, or failed with the reason.

## Edge cases
- PDFs, images and Word files count as docs only under docs/, documentation/ and .dante/; elsewhere they're app assets.
- HTML blocks in a README (a centred header) become images, headings and paragraphs.
- A scene draws any moment from its time alone (no timers), so playing, presenting and rendering show the same frames; Math.random is seeded.
- Scenes load from their own folder, Dante's fonts and the project's images and models, never env files or the rules' never paths, and nothing from the network.
- Bundled libraries (three.js, hairline, DiceBear Open Peeps) are imported by name through an import map Dante adds to the page; a page with its own import map keeps it. In a render, requestAnimationFrame and performance.now follow the frame being drawn, so a library with its own clock renders the same every time.
- The Look gallery's animations pause when the window is hidden, like any web page; picks still work from the keyboard (Tab, Return or Space) and VoiceOver reads each tile's name and summary.
- Renders stay out of git (the piece's .gitignore); the scene, manifest, storyboard and data are committed.
- Narration needs the natural voice (Settings › Claude); without it pieces play and render silent, with captions.

## Acceptance
- Every Mermaid diagram the parser supports draws without a browser.
- A rendered frame matches the preview at the same time.
- 4K renders at 3840×2160 without upscaling.
- Every style and kit in MotionLooks has a tile in the gallery, and a picked one's recipe is in the brief.
