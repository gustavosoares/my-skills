---
name: git-commit
description: Write a commit message from the staged changes, following the repo's existing convention (Conventional Commits by default), show it for approval, then commit. Use when the user asks to "commit", "commit this", "write a commit message", "generate a commit message", or "git commit". Never stages unrelated files, skips hooks, amends or pushes without asking.
---

# Git commit

Turn the staged changes into one well-described commit. The user approves the
message before anything is committed, and pushing is a separate question.

## 1. Inspect (read-only, run in parallel)

```bash
git status --short
git diff --cached --stat
git diff --cached                 # what will actually be committed
git log -20 --format='%s'         # the repo's message convention
git rev-parse --abbrev-ref HEAD   # branch name (may carry a ticket ID)
```

- **Nothing staged:** show the unstaged/untracked files and ask what to stage.
  Never run `git add -A` / `git add .` on your own. Stage only the files the user
  agrees to, by path.
- **Staged changes mix unrelated work** (e.g. a feature plus an unrelated
  config tweak): suggest splitting into separate commits and ask.
- Read the diff itself, not just file names. The message must describe what
  changed.

## 2. Guardrails

Before proposing a message, scan the staged diff and **stop and warn** if you
find:

- Likely secrets: `AKIA[0-9A-Z]{16}`, `-----BEGIN .*PRIVATE KEY-----`,
  `gh[pousr]_[A-Za-z0-9]{36,}`, `xox[baprs]-`, `.env*`, `*.pem`, `*.p12`,
  `credentials*` files, long high-entropy strings
- Large binaries (>1 MB) or generated output (`dist/`, `build/`,
  `node_modules/`, `.terraform/`)

Don't commit until the user decides what to do.

## 3. Pick the convention

Match the recent history from `git log`:

1. **Conventional Commits** if the history uses it, or if there's no clear
   convention: `type(scope): description`
2. **Ticket prefix** (e.g. `[ABC-123] …`) if the history uses one. Take the ID
   from the branch name (`feature/ABC-123-…`) when it's there. **Never invent a
   ticket ID**; if one is expected but unknown, ask.
3. Whatever other pattern the history clearly follows.

Types: `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `build`,
`ci`, `chore`, `revert`. Scope is optional: the module, package or area touched.

## 4. Write the message

```text
<type>(<scope>): <description>

<body: what changed and why, wrapped at ~72 chars>

<footers: Refs/Closes, BREAKING CHANGE, required trailers>
```

- **Subject:** imperative mood ("add", not "added"), lowercase after the
  prefix, no trailing period, ≤ 50 characters when possible (hard limit 72).
- **Body:** optional for small, obvious changes. Otherwise explain the *why*
  and anything a future reader would wonder about. Use bullets for several
  parallel changes. Keep the whole message short; the diff has the details.
- **Breaking changes:** `!` after the type/scope and a `BREAKING CHANGE:` footer.
- **Trailers:** add any the project or your instructions require (e.g.
  `Co-Authored-By:`, `Signed-off-by:` for DCO repos). Don't add others.
- Avoid vague subjects ("update code", "fix stuff", "changes") and describing
  the diff line by line.
- Don't mention private context (internal repo names, where code was copied
  from, people) unless the user asks.

## 5. Get approval, then commit

Show the message in a fenced block and ask: *"Commit with this message?"*
Apply any edits the user asks for. Once they approve:

```bash
git commit -F - <<'EOF'
<approved message>
EOF
git log --oneline -1
```

- **Pre-commit hook fails:** show the error, fix the cause (or ask), re-stage,
  and make a **new** commit attempt. Don't `--amend` and don't `--no-verify`
  unless the user explicitly asks.
- **Hook reformats files:** re-stage only those files and commit again.

## 6. After committing

Report the short hash and subject. Then ask whether to push. Don't push
unprompted. If the user wants a PR next, use the `git-create-pr` skill.

## Never

- Change git config, or commit with another author identity
- `--amend`, rebase or rewrite history unless asked
- `--no-verify` unless asked
- Push as part of this skill without a separate yes
