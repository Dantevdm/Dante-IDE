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
- Edit with completion, go to definition, find references, rename and format from the language server.
- Command I: edit the selection with the agent and accept or reject its proposal.
- Search and replace across the project; search by meaning with a local embedding model.
- Stage, commit (with a drafted message and a secret check), push, pull, switch and create branches; resolve merge conflicts hunk by hunk.
- Set breakpoints and debug Go and Python.
- Split the editor; back and forward through places.

## States
- No file open: the editor shows the shortcuts to start.
- A file changed on disk with unsaved edits: a conflict banner offers to keep yours or reload.
- Merge or rebase in progress: Changes shows Continue and Abort.

## Edge cases
- Remote projects work on a local mirror kept in sync over ssh; commands run on the host.
- Unsaved edits are used by search and blame, so lines don't shift.
- Auto-save writes on focus change without tidying whitespace; Save tidies and can format.

## Acceptance
- Typing never waits on highlighting or the language server.
- Every edit the agent makes can be undone with its turn.
