---
id: docs.standards
title: Standards
phrases: [standards, ui standards, house standards, principles, design standards, themes, customer themes, frontend themes, theme, new theme, company library, style guide]
---
# Standards (Docs › Standards)

Standards are the house rules every app the team builds follows: principles and UI standards as docs, and the frontend themes (a folder per customer with a theme.json, its logos and its font) a frontend must take its colours, type, corners and logos from. They come from the project and from a company library kept outside every repo, and new themes are made here, by hand or by the agent in charge.

## Highlights
- Every themes folder in the project is found on its own (any `<folder>/<name>/theme.json`, builds and node_modules skipped), with its default theme from the folder's README.
- Each theme shows as its own sign-in page and app shell, drawn in its colours, font, corners and logos, with what's wrong with it (missing files, unreadable fields, a missing font licence, text on the primary colour below 4.5:1).
- When the frontend swaps themes live (`?theme=<name>` in its source), Open the app in it starts or opens the running app in that theme; when it picks one at build time (`VITE_THEME`), the variable to set is copied.
- New theme: a customer's name, colours, corners, font and pictures, with a live preview and contrast check, written as a folder beside the others or in the company library; or the agent in charge makes it.
- The Map's frontend boxes show their themes, and the inspector lists them to open the running app in.
- The agents are told the standards in their brief, and Dante's ui_standards tool gives them the docs, every theme and the theme.json format.

## Shows
- The header: the counts (docs and themes), Docs (back to the library), Company library… (a folder chooser; Library once one is chosen, its path in the tooltip), New standard and New theme.
- Docs: a row per standards doc, project ones first (docs/standards/, standards/, .dante/standards/ or documentation/standards/) then the company library's, each with its first line and where it lives.
- A section per themes folder: its folder (or Company library), the default theme, how the app picks a theme (a Live chip with `?theme=`, or the build variable's name), "Copy all to the library" and "New theme here"; then a card per theme: a small sign-in page, the name, the customer, the primary colours as dots, a Default chip and a problem count.
- The theme sheet: the sign-in page and app shell side by side, the running app's launch card when it's opening in this theme, problems, every colour with its hex and contrast, the font, corners, product, copyright and pictures (reversed ones on the primary colour), with "from <default>" beside each field the theme leaves to its default.
- The Docs library's Standards strip (after Diagrams and motion) and a Standards row in the Docs sidebar.
- On the Map's System view: a theme line on a frontend box (a primary-colour dot per theme, up to seven, the default's name and the count, and a green bolt when it swaps live); in the inspector, a Themes card listing them, each with Open in it when the app swaps live, else the build variable to copy.

## Actions
- Open a theme card for its sheet; Open the app in it; Copy VAR=name; New theme from this…; Copy to the company library (or, from the library, Copy into a project's themes folder); Open theme.json (in Code inside the project, else the default app); Show in Finder.
- New theme: Save in (each themes folder, the company library, or a new themes/ folder), Start from (a theme whose font and defaults it takes), customer (the folder name comes from it, lower case with dashes), product, copyright, tagline, primary, secondary and accent colours with the text colour on primary worked out, a separate sidebar colour, corners, and logo, reversed logo, mark and sign-in picture from files. Make theme writes theme.json and copies the pictures (and the starting theme's font files with their licence); Ask <agent> to make it sends the same as a request with the format.
- New standard: writes docs/standards/ui-standards.md from an outline naming the project's themes (never over an existing file) and opens it Side by Side.
- Company library…: choose a folder outside the project (a folder inside it is refused); its docs (markdown at its top level or under docs/) and its themes/ are shown for every project on this Mac.
- On the Map: Open in it on a theme starts or opens the app with `?theme=<name>`, through the same launch card as the Map's Open in browser.

## States
- No themes: an empty state saying what a theme is and where Dante finds them, with Company library… and New theme…; standards docs still list above it.
- A theme with problems shows an amber count on its card and the list in its sheet; a theme that can't be read as JSON isn't listed.
- A frontend that picks its theme at build time has no Open in it buttons; one with no themes folder shows no theme line.
- The app not running: Open the app in it says so and offers Start it, like the Map's Open in browser.

## Edge cases
- A theme falls back to its folder's default field by field, except the customer's own: customer name, copyright, tagline and pictures. A theme without pictures shows the customer's initials, never another customer's logo.
- Colours are read as `#rrggbb`, `#rgb` or `H S% L%`; anything else is listed as a problem and the default's is used.
- Files a theme names must be inside its folder; fonts are registered for the preview only, from the theme's woff2/ttf/otf files.
- The current theme of a build is read from the frontend's env files (`VITE_THEME=` and the like), else its default.
- The company library is per Mac and never copied into the repo; Dante passes it to the agents' tool as DANTE_STANDARDS.
- Theme folders inside dist, build, node_modules, .next and similar are ignored.

## Acceptance
- A project with web/themes/{base,acme}/theme.json and a `?theme=` reader shows both themes, base as Default, with the Live chip; Open the app in it opens `http://localhost:<port>/?theme=acme` (before any `#` route).
- A theme with an unreadable colour and a missing logo shows two problems.
- New theme with a customer "Kelp & Co." writes kelp-co/theme.json that reads back the same and shows as a card at once.
- The Map's frontend box for that app shows its themes' dots, base and a count of 2, with the bolt.
- Previews look right in the Light, Dark and Paper themes (the mock pages stay the customer's own colours).
