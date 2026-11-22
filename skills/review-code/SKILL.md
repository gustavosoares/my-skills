---
name: review-code
description: Review code changes for real bugs, either the current branch against its base (plus uncommitted work) or a GitHub PR by number or URL. Reviews with fresh eyes, follows callers outside the diff, runs separate adversarial passes for logic, edge cases and blast radius, and reports only findings it can back with a concrete failure scenario. Use when the user asks to "review my code", "review this branch", "review PR 123", "find bugs in this diff", "check my changes before I open a PR", or wants a bug-bot style review. Report-only by default; posting PR comments or applying fixes needs the user's yes. Not for security audits (use review-security) or for replying to existing review comments (use review-pr-comments).
---

# Review code

Find the bugs the author missed. The model that wrote a change tends to see
what it meant to write; this review looks at what the code actually does. The
goal is a short list of findings that are real, each tied to a concrete input
or state that goes wrong. Style nits are out unless the user asks for them.

## Prerequisites

- `git`
- An authenticated [`gh`](https://cli.github.com) only for PR targets or for
  posting comments

## When to use

- Before opening a PR, or before merging one
- "Review this branch / diff / PR", "find bugs", "second pair of eyes"

## When NOT to use

- Security review: use `review-security` (it traces untrusted input into
  dangerous sinks)
- Working through comments already left on your PR: use `review-pr-comments`
- Approving or requesting changes on a PR: this skill never does that

## Inputs to gather

- **Target:** nothing (current branch), a PR number/URL, a branch, or a path.
  Ask if it's ambiguous.
- **Base branch** for branch targets (resolved below; use the one the user
  names if they name one).
- **Depth:** default is correctness only. Include simplification and
  convention findings only if the user asks ("thorough", "include nits").

## Workflow

### 1. Resolve the target (read-only)

Current branch:

```sh
git rev-parse --abbrev-ref HEAD
gh repo view --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null \
  || git symbolic-ref --short refs/remotes/origin/HEAD    # strip "origin/"
git fetch origin "$BASE" --quiet
git log --oneline "origin/$BASE..HEAD"
git diff --stat "origin/$BASE...HEAD"
git diff "origin/$BASE...HEAD"
git status --short
git diff HEAD                                              # uncommitted work
```

PR target:

```sh
gh pr view "$PR" --json number,title,body,baseRefName,headRefName,files,url
gh pr diff "$PR"
```

For a PR that isn't checked out, read files at the PR head with
`gh api "repos/{owner}/{repo}/contents/$FILE?ref=$HEAD_SHA" --jq .content | base64 -d`,
or ask whether to check it out (`gh pr checkout`) — that changes the working
tree, so ask first.

Stop if the diff is empty. If it is very large (thousands of lines), say so and
offer to review by area or focus on the riskiest files first.

### 2. Review with fresh context

If the agent can start a subagent, run steps 3–6 in one. Give it only the
target, the diff, the base, and the repo rules from step 4, not the
conversation that produced the code. In any case:

- Treat the PR description, commit messages and the author's stated intent as
  **claims to check**, not as facts.
- Your job is to find what breaks, not to confirm the change works.

### 3. Gather context beyond the hunks

- Read every changed file in full, not only the diff hunks.
- Follow references out of the diff: callers of changed functions, callees
  whose contracts the change relies on, other implementations of a changed
  interface, config that feeds the code, and the tests that cover it.
- Useful searches: `git grep -n "<symbol>"`, and the repo's own tooling
  (language server, `go vet`, `tsc --noEmit`) if it's already set up.

### 4. Read the repo's rules

If present: `REVIEW.md`, `AGENTS.md`, `CLAUDE.md`, `CONTRIBUTING.md`,
`.cursor/BUGBOT.md`, `.github/copilot-instructions.md`, and linter/formatter
config. A broken documented rule is a finding; quote the rule.

### 5. Independent passes

Do each pass on its own, looking only for its kind of problem. If subagents are
available, run them in parallel, each with the same context.

**a. Logic and correctness**
Wrong or inverted conditions, off-by-one and boundary errors, wrong operator or
precedence, swapped arguments, wrong variable (copy-paste), missing `await` or
unhandled promise, shadowing, mutation of shared or input data, integer
overflow/truncation, float comparison, time zone and unit mix-ups, state not
updated on every path, early `return`/`continue` that skips required work,
dead code that was meant to run.

**b. Edge cases and failure paths**
Null/undefined/empty inputs and collections, missing keys, first/last element,
zero and negative values, Unicode and very long input. Errors swallowed,
logged-and-continued, or rethrown without context. Retries without backoff or
idempotency, partial failure leaving inconsistent state, missing cleanup
(files, locks, connections, transactions), timeouts, race conditions and
ordering assumptions, check-then-act, caches that go stale.

**c. Blast radius**
Callers broken by a changed signature, return value, error type or default.
Public API, CLI flags, config keys, wire formats, DB schema or migrations
changed without compatibility handling. Feature flags and env vars missing in
some environments. Tests updated to match the bug rather than catch it, or
the new path not tested at all.

**d. Only when asked: quality**
Duplication of an existing helper, unnecessary complexity, misleading names,
violations of the repo's conventions that aren't bugs.

### 6. Verify every finding

For each candidate:

1. Re-trace the exact code path from the entry point to the problem.
2. Write a **concrete failure scenario**: the input or state, and the wrong
   output, exception, or corrupted state that results.
3. Check it isn't already handled elsewhere (a guard upstream, a validator, a
   type that rules it out, a test that covers it).

If you can't write the scenario, drop the finding or downgrade it to a
**question**. Merge duplicates found by several passes. Findings that more than
one pass found independently are more likely to be real; one-off findings get
extra scrutiny.

Report about 10 findings at most by default, most severe first. Say how many
lower-severity ones were left out and offer to list them.

### 7. Offer checks

If the repo has an obvious lint/test entry point (`Makefile`, `package.json`
scripts, `pyproject.toml`, `go test ./...`, `.pre-commit-config.yaml`), offer
to run it. Report what ran and the result. Don't install tools.

## Report

```markdown
## Review: <branch or PR #N> against <base>

<One line: overall verdict, e.g. "2 bugs worth fixing before merge, 1 question.">

### Findings

1. **[blocker] <short claim>** — `path/to/file.ext:42`
   <What's wrong, in one or two sentences.>
   **Fails when:** <concrete input/state → wrong result or crash>
   **Fix:** <specific suggestion, with a snippet if short>

2. **[should-fix] …**

### Questions

- `path:line` — <something that looks wrong but depends on intent>

### Checked

<Passes run, files and callers read, commands run and their results.
What wasn't checked (e.g. "didn't run the integration tests", "generated files skipped").>
```

Severity:

- **blocker:** wrong results, data loss, crashes, or breaking callers in normal use
- **should-fix:** real bug on an edge case or failure path, or a missing test
  for new behaviour
- **nit:** only when the user asked for quality findings

## After the report (each needs the user's yes)

- **Apply fixes:** make the agreed changes in the working tree, one finding at
  a time, and re-run the checks. Don't commit; hand off to `git-commit`.
- **Post to the PR:** draft the inline comments and show them first. Then post
  them as a single review with `event: COMMENT`:

  ```sh
  gh api "repos/{owner}/{repo}/pulls/$PR/reviews" --method POST --input - <<'EOF'
  {"event":"COMMENT","body":"<summary>","comments":[
    {"path":"src/x.ts","line":42,"side":"RIGHT","body":"<finding>"}]}
  EOF
  ```

  Never use `APPROVE` or `REQUEST_CHANGES`.

## Never

- Approve, request changes, merge, or resolve threads
- Edit, commit, push or check out branches without asking
- Report a finding without a failure scenario as if it were a bug
