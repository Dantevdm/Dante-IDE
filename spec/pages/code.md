---
id: code
title: Code
phrases: [code, editor, files, explorer, source]
---
# Code

Code is the editor: the file explorer, search, problems and the debugger beside it, the terminal below and the agent's panel on the right.

## Highlights
- Command I edits the selection with the agent.
- Search finds text, or code by meaning.
- Changes shows the git diff and commits.

## Shows
- The sidebar's tabs: Explorer (the project's files with git status marks), Search (text or regex, and Meaning), Changes (staged and unstaged files, branch, commit box), Problems (language server diagnostics by file) and Debug.
- The editor: tabs, a split pane, syntax highlighting, line numbers with breakpoints, the blame of the caret's line in the status bar.
- Files that aren't text open in a viewer: PDFs, images, Word, media.
- The terminal below, with tabs, shown and hidden by Terminal at the left of the status bar (⌃` as before); the agent's panel on the right. The status bar no longer shows the branch: it's in the title bar.

## Actions
- Open, create, rename, move and delete files and folders. Drag rows onto a folder to move them (a selected row takes the whole selection), and drag files in from Finder to copy them into the folder under the pointer, or the project when dropped below the tree.
- Drop files from Finder or the explorer onto the editor (the text, the tabs or the empty editor) to open each in a tab; folders are ignored, and dragging selected text within the editor still moves it.
- Edit with completion, go to definition, find references, rename and format from the language server. Without a server that completes (none installed for TypeScript, Python or Java, say), completion still offers the file's declarations and words, the project's declarations (with their file) and the language's keywords; prose files get none.
- Command I: edit the selection with the agent and accept or reject its proposal.
- Search and replace across the project; search by meaning with a local embedding model.
- Stage, commit (with a drafted message and a secret check), push, pull, switch and create branches; resolve merge conflicts hunk by hunk.
- Set breakpoints and debug Go and Python.
- Split the editor; back and forward through places.
- Right-click a tab, as in IntelliJ: Split Right and Split Left show that file beside the one you're in (any file: code, a PDF, an image, a Word file), and focus it; Close Split; Close, Close Others, Close Tabs to the Right and Close All (unsaved edits among them ask once); Copy Path, Copy Relative Path and Show in Finder.
- Edit › Find (⌘F) opens the find bar in the file you're in; ⌥⌘F finds and replaces, ⌘G and ⇧⌘G go to the next and previous match, ⌘E uses the selection.
- Middle-click a tab (editor, terminal or Data query) to close it, as in a browser; an editor tab with unsaved edits asks first, like its ×.

## States
- No file open: the editor shows the shortcuts to start.
- A file changed on disk with unsaved edits: a conflict banner offers to keep yours or reload.
- Merge or rebase in progress: Changes shows Continue and Abort.
- Split: the focused pane's tab has the accent bar, the other pane's tab a fainter one; Split Right is greyed out on the tab already on the right.

## Edge cases
- Remote projects work on a local mirror kept in sync over ssh; commands run on the host.
- Unsaved edits are used by search and blame, so lines don't shift.
- Auto-save writes on focus change without tidying whitespace; Save tidies and can format.

## Acceptance
- Typing never waits on highlighting or the language server.
- Every edit the agent makes can be undone with its turn.
- Right-click a tab other than the open one › Split Right: the open file stays on the left and the tab's file opens on the right with focus; a PDF tab split right shows the PDF beside the code.
