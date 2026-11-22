---
name: git-create-pr
description: Open a GitHub pull request for the current branch with the gh CLI. Checks the branch, base and existing PRs, asks before pushing, drafts a short, honest title and description (filling the repo's PR template if one exists), shows the draft for the user to review, and creates the PR only after approval. Use when the user asks to "open a PR", "create a pull request", "push and open a PR", "draft the PR", or "git create-pr". Never force-pushes, auto-merges or assigns reviewers without asking.
---

# Create a pull request

Open a reviewable PR for the current branch. Every step that publishes
something (push, PR creation) needs the user's explicit yes, and the user sees
the title and description before the PR exists.

## 1. Preconditions (read-only, run in parallel)

```bash
git rev-parse --abbrev-ref HEAD                             # current branch
git status --porcelain                                      # uncommitted work
git remote -v                                               # origin exists?
gh auth status                                              # gh logged in?
gh repo view --json defaultBranchRef -q .defaultBranchRef.name   # base branch
gh pr view --json number,state,url 2>/dev/null              # existing PR?
```

If `gh repo view` fails, fall back to
`git symbolic-ref --short refs/remotes/origin/HEAD` (strip `origin/`). Use the
base the user names if they name one.

Then, with `$BASE` known:

```bash
git fetch origin "$BASE" --quiet
git log --oneline "origin/$BASE..HEAD"       # commits in the PR
git diff --stat "origin/$BASE...HEAD"        # files in the PR
git diff "origin/$BASE...HEAD"               # the full diff reviewers will see
```

Stop and tell the user when:

- **On the base branch** (or another branch the repo protects): offer to create
  a feature branch from the current commit. Don't commit or push to the base.
- **An open PR already exists** for this branch: show its URL. Offer to update its
  description instead (same draft-and-approve flow) rather than creating a duplicate.
- **No commits ahead of base:** there's nothing to open.
- **`gh` isn't installed or authenticated:** ask the user to run `gh auth login`.

## 2. Branch hygiene

- **Uncommitted changes:** list them and ask whether to commit them (use the
  `git-commit` skill), leave them out, or stop. They're not part of the PR
  until committed.
- **Behind base:** say so and ask before rebasing or merging. Never rewrite
  history silently.
- **Guardrails:** scan the PR diff for likely secrets (`AKIA…`, private key
  headers, `gh*_` / `xox*-` tokens, `.env*`, `*.pem`) and large or generated
  files. Stop and warn if any turn up.
- **Project checks:** if the repo has an obvious lint/format/test entry point
  (`Makefile` target, `package.json` script, `.pre-commit-config.yaml`,
  `terraform fmt` for `*.tf`), offer to run it. Report what ran and what didn't.
  Don't run tools the repo doesn't use.

## 3. Push (ask first)

If the branch has no upstream or has unpushed commits, ask: *"Push
`<branch>` to origin?"* On yes:

```bash
git push -u origin HEAD
```

Never `--force`. Use `--force-with-lease` only if the user explicitly asks,
and never on the base branch.

## 4. Draft the title and description

**Title:** follow the repo's convention, taken from recent PR titles
(`gh pr list --state merged --limit 10 --json title`) and commit history:
Conventional Commits (`feat(scope): …`), a ticket prefix (`[ABC-123] …`, from
the branch name, never invented), or a short imperative sentence. ≤ 72
characters, no trailing period.

**Body:** if the repo has a PR template (`.github/pull_request_template.md`,
`PULL_REQUEST_TEMPLATE.md`, `docs/pull_request_template.md`, or
`.github/PULL_REQUEST_TEMPLATE/`), fill in its sections. Mark anything only the
user can supply (ticket links, screenshots, rollback steps) with `TODO:`.
Otherwise use this shape:

```markdown
<One or two sentences: what this PR does and, if not obvious, why.>

**<area or module>**: <what changed, 1–3 sentences>
**<area or module>**: ...

<Cross-cutting notes: breaking changes, defaults, migrations, required versions.>

<Testing: what actually ran, and what didn't.>
```

Writing rules:

- Cover **all** commits in `origin/$BASE..HEAD`, not just the latest.
- Short: typically 5–12 lines. Small PRs can be two sentences.
- Plain voice ("Adds…", "Fixes…"). Don't open with "This PR…". No
  marketing words (comprehensive, robust, seamless, leverage), no emojis, no
  file-by-file restatement of the diff.
- **Be honest about testing.** Name exactly what ran ("unit tests pass",
  "`terraform validate` passes"). Say what wasn't tested.
- Describe what the change does. Leave out private context (internal repo or
  ticket names, where code was copied from, people) unless the user includes it.
- Add any attribution line the project or your instructions require at the end.

## 5. Review with the user

Show the title and body in a fenced `markdown` block and ask:
*"Create the PR with this title and description?"* Mention whether it will be
a draft. Apply the user's edits and show the result again if the changes are
substantial. **Don't create the PR until the user approves.**

Optional flags to offer, not apply silently:

- `--draft` when the user says WIP/draft or checks are known to fail
- `--reviewer` suggestions from `CODEOWNERS` for the changed paths
- `--label` only if the repo clearly uses labels on PRs
- `--assignee @me`

## 6. Create

```bash
gh pr create --base "$BASE" --head "$(git rev-parse --abbrev-ref HEAD)" \
  --title "$TITLE" --body-file - <<'EOF'
<approved body>
EOF
```

To update an existing PR instead: `gh pr edit <number> --title … --body-file -`.

## 7. Hand off

1. Print the PR URL.
2. Show the checks: `gh pr checks <url>` (it's fine if none have started yet).
3. Ask whether to watch CI. If yes:
   `gh pr checks <url> --watch --interval 30`. Report failing check names and
   their log URLs; don't try to fix them without asking.

## Never

- Change git config
- Push, create or edit a PR without the user's yes
- Force-push (except `--force-with-lease` on explicit request, never to base)
- Merge, enable auto-merge, approve, or resolve review threads
- Skip hooks with `--no-verify`
