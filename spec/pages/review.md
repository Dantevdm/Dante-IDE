---
id: review
title: Review
phrases: [review, code review, reviewed, eyes on it, read the code, reviewers, who reviewed, review coverage]
---
# Review (Quality › Review)

Review shows which code files someone has read and understood as they are now, who read them, and what's been asked of whom. A mark goes stale the moment its file changes.

## Highlights
- Marks are kept in the repo, in .dante/reviews.jsonl, so they travel with git to GitHub, Bitbucket or Azure DevOps and show in pull requests.
- A project can ask for more than one reviewer per file with `review: required: 2` in .dante/project.yaml.
- Walk me through it asks the agent in charge to explain a file before you mark it.

## Shows
- The count of code files reviewed out of all of them, a bar split into reviewed, needing another reviewer, with concerns and changed since review, and a chip per state that filters the list.
- What counts: files git tracks whose extension or name is code (Swift, Go, Java, TypeScript, Python, SQL, shell, Terraform, Dockerfiles and the like), leaving out vendored, generated, built and minified files; `review: include:` and `exclude:` (globs or folders) in project.yaml change that.
- People: everyone who has marked files, with how many of their marks are on current versions, concerns raised and when they last marked.
- Asked for: open requests, who asked whom to read what (a file, a folder or every code file), the note and how many files are still to go.
- Files: folders with a progress bar and reviewed count, folded until opened or filtered; each file with its state dot, the concern's note, reviewers' initials (filled for this version, outlined for an earlier one; the tooltip names who and when, and who has been asked) and Mark reviewed.
- The status bar, for the open file: Mark reviewed, You reviewed it, "2 reviewed · Mark", Changed since review or Concern raised, coloured by state.

## Actions
- Mark reviewed (a file's button, the status bar chip, Git › Mark File as Reviewed, ⌃⇧R): records that you read and understood the file as it is on disk now; the open file is saved first. Pressing it again on a file you've marked takes your mark back.
- Raise a concern…: a mark with a note saying what should be looked at; the file shows as having concerns until a later mark replaces it.
- Walk me through it: asks the agent in charge to explain the file for a reviewer without changing anything.
- Mark all of a folder as reviewed, from the folder's menu.
- Ask for a review…: a person (their git name, with chips for commit authors and earlier reviewers), what (the open file, a folder or every code file) and a note. It's written as a line in the reviews file and reaches them when you push.
- Filter by state, by Asked of you, or by text in the path.
- Open a file in Code by clicking its name.

## States
- Loading: a spinner while the hashes are read.
- No code files: says what counts and how to include more.
- Git has no user.name in the repository: marking says so and how to set it.

## Edge cases
- A mark holds the file's git blob hash; a file edited and not yet committed is hashed as it is on disk, so marking it and then committing keeps the mark current.
- Several people's marks merge cleanly: each line stands alone and .gitattributes gets `.dante/reviews.jsonl merge=union` when the file is first written.
- The latest mark per person and file decides, by time, since a union merge puts one side's lines after the other's.
- A request stands for each file until that reviewer marks its current version; a request made before a file changed still covers the new version.
- Files in a merge conflict are left out until it's resolved.
- Reviewer names come from git's user.name only, never an email address.

## Acceptance
- Marking a file and then changing it shows it as changed since review.
- A file reaches reviewed only with as many current marks as the project asks for.
- Nothing is pushed or sent anywhere by Review; the reviews file is a change like any other, committed and pushed by you.
