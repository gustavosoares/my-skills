---
name: review-pr-comments
description: Work through the review comments on your own GitHub pull request. Fetches unresolved review threads, review summaries and conversation comments with a bundled read-only script, checks each comment against the current code, triages it (fix, push back, answer, already done, outdated), applies the agreed fixes locally and drafts a reply per thread. Use when the user asks to "address the review comments", "go through the PR feedback", "fix what the reviewer said", "respond to review", "handle bugbot/copilot comments", or "what's left on my PR". Committing, pushing, posting replies and resolving threads each need the user's yes. Not for reviewing someone else's PR (use review-code).
---

# Review PR comments

Turn a PR's review feedback into fixes and replies. Each comment is checked
against the code as it is now, since reviewers (human or bot) can be wrong,
outdated or already addressed. Nothing is posted to GitHub without the user's
approval.

## Prerequisites

- `git`, `jq`
- An authenticated [`gh`](https://cli.github.com) with read access to the
  repo (write access only for posting replies or resolving threads)

## When to use

- A PR has review comments to address, from people or review bots
- "What's still open on my PR?"

## When NOT to use

- Reviewing a PR yourself: use `review-code` or `review-security`
- Opening the PR in the first place: use `git-create-pr`

## Inputs to gather

- **PR:** default is the PR for the current branch; the user can name a number
  or URL (pass the repo with `--repo OWNER/REPO` if it isn't the current one)
- **Scope:** unresolved threads only (default), or include resolved ones

## Workflow

### 1. Find the script

The working directory is the user's project, so resolve the script's absolute
path. First try this skill's base directory
(`<skill dir>/scripts/fetch-pr-threads.sh`), then:

```sh
for d in ~/.claude/skills ~/.agents/skills ~/.cursor/skills; do
  f="$d/review-pr-comments/scripts/fetch-pr-threads.sh"
  if [ -x "$f" ]; then echo "$f"; break; fi
done
```

If none exists, suggest reinstalling:
`npx skills add gustavosoares/my-skills --skill review-pr-comments`.

### 2. Check the local branch (read-only)

```sh
git rev-parse --abbrev-ref HEAD
git status --short
git fetch origin --quiet
git status -sb | head -n 1          # ahead/behind upstream
```

- **Uncommitted changes:** say so; ask whether to keep going on top of them.
- **Behind the PR head:** ask before pulling. Fixes should be made on the
  latest code.
- **Not on the PR's branch:** ask before `gh pr checkout <n>`.

### 3. Fetch the comments

```sh
"$SCRIPT"                    # PR for the current branch, unresolved threads
"$SCRIPT" --pr 123 --all     # a specific PR, including resolved threads
```

The JSON has `threads` (inline review threads with `path`, `line`,
`isOutdated` and every comment), `reviews` (review summaries with a body) and
`comments` (the PR conversation). Exit code 1 means a gh/API error, and the
script says whether it was auth, permission or not-found. Report that; don't
treat it as "no comments".

### 4. Triage each thread

For every thread (and any actionable review summary or conversation comment):

1. Read the comment and the code it points at **as it is now** (`path:line`,
   plus enough of the surrounding code to judge it).
2. Decide whether the reviewer is right. Check their claim the way
   `review-code` checks a finding: is there a concrete failure? Is it already
   handled elsewhere?
3. Classify:
   - **fix:** valid, change the code
   - **push back:** you disagree; say why, with evidence
   - **answer:** a question, no code change
   - **done:** already addressed by a later commit (cite it)
   - **outdated:** the code moved on and the comment no longer applies
   - **needs user:** a product or design decision only the user can make

Show the triage as a table and get the user's agreement before changing code:

```markdown
| # | Where | Reviewer | Ask (short) | Verdict | Plan |
|---|-------|----------|-------------|---------|------|
| 1 | `src/api.ts:42` | alice | handle empty list | fix | early return + test |
| 2 | `README.md:10` | bot | rename flag | push back | flag is public API; renaming breaks users |
```

### 5. Apply the agreed fixes

- One thread at a time, smallest change that addresses it. Don't refactor
  around it.
- Add or update a test when the comment points out a bug.
- After all fixes, run the repo's lint/test entry points if there are obvious
  ones, and report the results.
- Show `git diff --stat` and summarize the changes per thread.

### 6. Draft replies

One short reply per thread, written as the PR author:

- **fix:** what changed and where ("Fixed in `abc1234`: returns early on an
  empty list, test added.")
- **push back:** the reason, politely, with the evidence
- **answer / done / outdated:** one or two sentences

No filler ("Great catch!"), no apologies, no emojis. Show all drafts together
for review.

### 7. Publish (each step needs its own yes)

1. **Commit:** hand off to `git-commit`. A commit per thread or one commit for
   all, whichever the user prefers.
2. **Push:** `git push` (never `--force`; `--force-with-lease` only if the user
   asks).
3. **Post replies:** after the push, so commit SHAs in replies exist on GitHub.
   Use the first comment's `databaseId` in each thread:

   ```sh
   gh api "repos/$REPO/pulls/$PR/comments/$COMMENT_ID/replies" \
     --method POST -f body="$REPLY"
   ```

   For conversation comments, use `gh pr comment "$PR" --body-file -`.
4. **Resolve threads:** only threads that were fixed, done or outdated, and
   only if the user wants that. Many teams prefer the reviewer to resolve.
   Use the thread `id`:

   ```sh
   gh api graphql -f query='mutation($id: ID!) {
     resolveReviewThread(input: {threadId: $id}) { thread { isResolved } } }' \
     -f id="$THREAD_ID"
   ```

## Report

```markdown
## PR #<n>: review comments

<N> threads: <a> fixed, <b> pushed back, <c> answered, <d> already done/outdated, <e> need your call.

| # | Where | Verdict | What happened |
|---|-------|---------|---------------|
| 1 | `src/api.ts:42` | fixed | early return + test, commit `abc1234` |

**Needs your decision:** <threads marked "needs user", with the options>
**Checks:** <what ran, results>
**Not done yet:** <commit / push / replies / resolve: whichever the user hasn't approved>
```

## Never

- Post, resolve, commit or push without the user's yes for that step
- Agree with a comment just because a reviewer made it; check it against the code
- Dismiss reviews, request re-review, or edit other people's comments
- Force-push or rewrite history unless the user asks
