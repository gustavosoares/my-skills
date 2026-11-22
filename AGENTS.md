# AGENTS.md

Conventions for working in this repo: a public library of agent skills
installed with the [Skills CLI](https://github.com/vercel-labs/skills)
(`npx skills add gustavosoares/my-skills`).

## Layout

```
skills/<skill-name>/
├── SKILL.md        # required
├── scripts/        # optional: helper scripts the skill runs
└── references/     # optional: long docs the skill loads on demand
```

- One directory per skill under `skills/`, flat (no category folders). Group by
  category in the README inventory instead.
- The directory name must equal the frontmatter `name`.

## SKILL.md

- Frontmatter has only `name` and `description`.
  - `name`: lowercase, hyphen-separated, verb-first when it reads naturally
    (`troubleshoot-…`, `review-…`).
  - `description`: under 1024 characters, third person. Say **what** the skill
    does, **when** to use it (the trigger phrases a user would type), and what
    it is **not** for. Agents decide whether to load the skill from this text
    alone.
- Body order: short intro → **Prerequisites** (only if it depends on a specific
  tool, module or stack; link it) → When to use / When NOT to use → Inputs to
  gather → numbered Workflow → report template → References.
- Keep it under ~500 lines. Move long reference material to `references/` and
  link it from the body.
- Ask the user for anything environment-specific (accounts, profiles, regions,
  repos, prefixes) rather than assuming a default.

## Keep skills generic

This repo is public. Skills must not contain:

- Organization, team or product names, internal hostnames, account IDs, or
  links to private repos, wikis or dashboards
- Ticket keys (e.g. `ABC-123`), people's names, Slack channels
- Snapshots of someone's config (caps, sizes, schedules, label names). Read live
  values at runtime or ask the user.

Use placeholders like `OWNER/REPO`, `<prefix>`, `$REGION`, `$PROFILE`. Before
committing, grep for any organization-specific names.

## Scripts

- Bash that runs on macOS's stock bash 3.2 and on Linux: no associative arrays,
  `mapfile` or `${var,,}`, and handle both BSD and GNU `date`.
- `set -euo pipefail`. Use `if …; then …; fi` rather than a trailing
  `cond && action`, which can trip `set -e`.
- Read-only by default. Anything that mutates must be opt-in and the skill must
  ask before running it.
- A header comment with usage, options, required tools, permissions used and
  exit codes. `--help` prints it.
- No hardcoded environment values. Take required ones as flags and fail with a
  clear message (exit `64`) if they're missing.
- Surface permission errors explicitly. Don't let a denied call look like a
  real "0" or "not found".
- SKILL.md must tell the agent how to resolve the script's absolute path
  (skill base directory first, then `~/.claude/skills`, `~/.agents/skills`,
  `~/.cursor/skills`), because the working directory is the user's project.

## Adding or changing a skill

1. Create or edit `skills/<name>/` following the rules above.
2. Add or update the skill's row in the README **Skills inventory**, including
   the **Requires** column.
3. Verify:
   - `scripts/check-skills.sh` passes (frontmatter, name/directory match,
     description length, line count, README inventory link)
   - `bash -n` on every script, plus `shellcheck` if it's installed
   - `--help` works, and missing required flags fail cleanly
   - Exercise the script against stubbed CLIs (fake `aws`/`gh` on `PATH`) when
     it can't run against real infrastructure
   - Scan for leftover org-specific names (see "Keep skills generic")
4. Use Conventional Commits (`feat(skills): …`, `fix(<skill>): …`, `docs: …`).

## Git and pull requests

- **Never commit, push or open a PR on your own.** When the change is ready,
  ask the operator whether they want to commit and push. Wait for a yes for
  each step.
- **Show the PR title and description first.** Put the draft in the
  conversation, apply any edits the operator asks for, and create the PR
  against `main` only once they approve it.
- PR descriptions, commit messages and other public text describe what the
  change does and how it was tested. Leave out where the work came from
  (other repos, employers, earlier private versions).
