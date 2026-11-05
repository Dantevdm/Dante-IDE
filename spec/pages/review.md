---
id: review
title: Review
phrases: [review, code review, reviewed, eyes on it, read the code, reviewers, who reviewed, review coverage, pull request, pr comments, approvals]
---
# Review (Quality › Review)

Review shows which code files someone has read and understood as they are now, who read them, and what's been asked of whom. A mark goes stale the moment its file changes.

## Highlights
- Marks are kept in the repo, in .dante/reviews.jsonl, so they travel with git to GitHub, Bitbucket or Azure DevOps and show in pull requests.
- For a Bitbucket repository, the branch's pull request is right here: who approved, who asked for changes, who hasn't decided, and every comment thread by file and line. It's read with the sign-in git already saved for the remote: no new key, nothing to paste.
- A project can ask for more than one reviewer per file with `review: required: 2` in .dante/project.yaml.
- Walk me through it asks the agent in charge to explain a file before you mark it.

## Shows
- Pull request (Bitbucket Cloud remotes only; hidden otherwise): for the checked-out branch's open pull request, its number, title, branches, author and last update; a verdict (asked for changes, approved by everyone asked, 1 of 3 approved, waiting for reviewers, not reviewed yet) with open threads and tasks; a chip per reviewer (green tick approved, red mark asked for changes, grey circle hasn't decided; the tooltip says which); and the comment threads, open first, each with the file and line (a link that opens it there; a line the pull request removes isn't opened), the author's first line, the newest reply and Resolved. Six threads show, with Show all. Without a pull request for the branch: "No pull request for <branch> yet" with Create pull request, and the repository's other open pull requests (number, title, author, approvals), each opening on Bitbucket. On the default branch only the open list shows.
- The count of code files reviewed out of all of them, a bar split into reviewed, needing another reviewer, with concerns and changed since review, and a chip per state that filters the list.
- What counts: files git tracks whose extension or name is code (Swift, Go, Java, TypeScript, Python, SQL, shell, Terraform, Dockerfiles and the like), leaving out vendored, generated, built and minified files; `review: include:` and `exclude:` (globs or folders) in project.yaml change that.
- People: everyone who has marked files, with how many of their marks are on current versions, concerns raised and when they last marked.
- Asked for: open requests, who asked whom to read what (a file, a folder or every code file), the note and how many files are still to go.
- Files: folders with a progress bar and reviewed count, folded until opened or filtered; each file with its state dot, the concern's note, a comment chip with its open pull request threads, reviewers' initials (filled for this version, outlined for an earlier one; the tooltip names who and when, and who has been asked) and Mark reviewed.
- The status bar, for the open file: Mark reviewed, You reviewed it, "2 reviewed · Mark", Changed since review or Concern raised, coloured by state; and, when the pull request has open threads on the file, a comment count whose tooltip lists them by line (clicking opens Review).

## Actions
- Mark reviewed (a file's button, the status bar chip, Git › Mark File as Reviewed, ⌃⇧R): records that you read and understood the file as it is on disk now; the open file is saved first. Pressing it again on a file you've marked takes your mark back.
- Raise a concern…: a mark with a note saying what should be looked at; the file shows as having concerns until a later mark replaces it.
- Walk me through it: asks the agent in charge to explain the file for a reviewer without changing anything.
- Mark all of a folder as reviewed, from the folder's menu.
- Ask for a review…: a person (their git name, with chips for commit authors and earlier reviewers), what (the open file, a folder or every code file) and a note. It's written as a line in the reviews file and reaches them when you push.
- Filter by state, by Asked of you, or by text in the path.
- Open a file in Code by clicking its name.
- Pull request: Check again (the arrow) reads it again; Open in Bitbucket opens the pull request (or the repository's list) in the browser, where approving, commenting and adding reviewers happen; Create pull request opens Bitbucket's new pull request page for the branch against the default branch; a thread's file:line opens the file at that line.

## States
- Loading: a spinner while the hashes are read; the pull request card says it's reading from Bitbucket with git's sign-in.
- Pull request unavailable, with why: an ssh remote (git keeps no https sign-in to borrow), no saved sign-in (push or fetch once so git saves one), Bitbucket turning the sign-in down for pull requests (an API token needs read:pullrequest:bitbucket, an app password Pull requests: Read), the repository not found for that sign-in, or Bitbucket unreachable.
- No code files: says what counts and how to include more.
- Git has no user.name in the repository: marking says so and how to set it.

## Edge cases
- A mark holds the file's git blob hash; a file edited and not yet committed is hashed as it is on disk, so marking it and then committing keeps the mark current.
- Several people's marks merge cleanly: each line stands alone and .gitattributes gets `.dante/reviews.jsonl merge=union` when the file is first written.
- The latest mark per person and file decides, by time, since a union merge puts one side's lines after the other's.
- A request stands for each file until that reviewer marks its current version; a request made before a file changed still covers the new version.
- Files in a merge conflict are left out until it's resolved.
- Reviewer names come from git's user.name only, never an email address.
- The pull request is read when Review or the status bar first appears and then at most every two minutes, or on Check again; never on each edit.
- git's sign-in is asked for with `git credential fill` for the remote's own URL, with prompts, askpass and credential manager windows off; it stays in memory for the request, goes only to api.bitbucket.org (redirects aren't followed, nothing is cached on disk) and is never shown, saved or logged. An API token or access token goes as a bearer token, an app password with its user name.

## Acceptance
- Marking a file and then changing it shows it as changed since review.
- A file reaches reviewed only with as many current marks as the project asks for.
- Nothing is pushed or sent anywhere by Review; the reviews file is a change like any other, committed and pushed by you. Reading a pull request sends only the request for it to Bitbucket; Dante never approves, comments or adds reviewers itself.
