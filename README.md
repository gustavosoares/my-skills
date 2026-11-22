# my-skills

My personal library of agent skills: small, focused workflows I use for
platform, infrastructure and day-to-day engineering work.

Each skill is a single `SKILL.md`, sometimes with a helper script. They work in
Claude Code, Cursor, Codex and other agents that support the
[Agent Skills](https://github.com/vercel-labs/skills) format. They aim to be
read-only by default, explicit about what they need (tools, credentials,
infrastructure), and easy to fork and adapt to your setup.

Some skills target a specific tool or stack. The
[inventory](#skills-inventory) lists what each one requires.

## Install

Install with the [Skills CLI](https://github.com/vercel-labs/skills)
(`npx skills add`). The examples below install globally (`-g`) for Claude Code
and Cursor (`-a`) without prompts (`-y`). Swap or drop `-a` for other agents.

**All skills:**

```bash
npx skills add gustavosoares/my-skills --skill '*' -g -a claude-code -a cursor -y
```

**A specific skill** (any name from the [inventory](#skills-inventory)):

```bash
npx skills add gustavosoares/my-skills --skill git-commit -g -a claude-code -a cursor -y
```

List several names after `--skill` to install more than one
(`--skill git-commit git-create-pr`). Drop
`-g -a … -y` to pick scope and agents in the interactive prompt instead.

### Update

**All installed skills:**

```bash
npx skills update -g -y
```

**A specific skill:**

```bash
npx skills update git-commit -g -y
```

`update` covers every globally installed skill, including ones from other
repos. Use `npx skills ls -g` to see what's installed. Updating doesn't pick up
skills added to this repo after you installed; re-run the **All skills**
command above for those.

## Layout

```text
my-skills/
└── skills/
    └── <skill-name>/
        ├── SKILL.md          # required: frontmatter (name, description) + instructions
        ├── scripts/          # optional: helper scripts the skill runs
        └── references/       # optional: supporting docs loaded on demand
```

- One directory per skill under `skills/`, named the same as the `name` in its
  `SKILL.md` frontmatter.
- The `description` says what the skill does **and** when to use it; agents
  use it to decide when to load the skill.
- Scripts are read-only unless the skill says otherwise, and document their
  required tools and permissions in their header.

## Skills inventory

### Onboarding & docs

| Skill | Description | Requires |
|-------|-------------|----------|
| [`i-know-kungfu`](skills/i-know-kungfu/SKILL.md) | Read-only overview of the repo you're in: purpose, tech stack, code map, local setup, Mermaid diagrams of key workflows, CI/CD pipeline and PR checks, deploys and environments, gotchas; offers to save it as Markdown | `git`; optional authenticated [`gh`](https://cli.github.com) for rulesets and branch protection |

### Git workflow

| Skill | Description | Requires |
|-------|-------------|----------|
| [`git-commit`](skills/git-commit/SKILL.md) | Commit message from staged changes in the repo's convention (Conventional Commits by default); asks before committing and pushing | `git` |
| [`git-create-pr`](skills/git-create-pr/SKILL.md) | Open a GitHub PR: checks branch and base, asks before pushing, drafts a short title and description (or fills the repo's PR template) for your review, then creates it | `git`, authenticated [`gh`](https://cli.github.com) |
| [`pr-description`](skills/pr-description/SKILL.md) | Short, natural PR description from the branch, ready to paste; doesn't push or touch GitHub | `git` |

### Code review

| Skill | Description | Requires |
|-------|-------------|----------|
| [`review-code`](skills/review-code/SKILL.md) | Bug-focused review of the current branch or a PR: fresh context, follows callers outside the diff, separate passes for logic, edge cases and blast radius, and only findings backed by a concrete failure scenario; report-only unless you ask it to post or fix | `git`; authenticated [`gh`](https://cli.github.com) for PR targets |
| [`review-security`](skills/review-security/SKILL.md) | Security review of the current branch or a PR: maps trust boundaries, traces untrusted input to sinks, checks auth, secrets, crypto, IaC, CI workflows and dependencies, with severity and confidence | `git`; authenticated `gh` for PR targets; optional `gitleaks`, `semgrep`, `trivy`, ecosystem audit tools |
| [`review-pr-comments`](skills/review-pr-comments/SKILL.md) | Work through review comments on your PR: fetches unresolved threads, checks each against the code, triages, applies agreed fixes and drafts replies; asks before committing, pushing, replying or resolving | `git`, `jq`, authenticated `gh` |

### GitHub repo setup

| Skill | Description | Requires |
|-------|-------------|----------|
| [`github-branch-protection`](skills/github-branch-protection/SKILL.md) | Protect the default branch with a ruleset: PRs required, code-owner approval, required CI checks, merge methods, fork-PR workflow approval; solo-maintainer bypass handled | Admin on the repo; authenticated `gh`, `jq`; rulesets need a public repo or GitHub Pro/Team/Enterprise |

### CI/CD

| Skill | Description | Requires |
|-------|-------------|----------|
| [`troubleshoot-github-aws-runners`](skills/troubleshoot-github-aws-runners/SKILL.md) | Diagnose self-hosted GitHub Actions jobs stuck in Queued, scale-up not launching, fleets at cap, DLQ messages and JIT registration failures | Runners deployed with [terraform-aws-github-runner](https://github.com/github-aws-runners/terraform-aws-github-runner); `aws`, `jq`; optional `gh`, [Granted](https://granted.dev) |

### Infrastructure as code

| Skill | Description | Requires |
|-------|-------------|----------|
| [`new-terraform-module`](skills/new-terraform-module/SKILL.md) | Scaffold or import a reusable Terraform module (AWS by default) that is generic, safe by default, minimum-version constrained and documented, following the repo's existing module conventions | `terraform` (or `tofu`) to validate |

## Contributing

Issues and PRs are welcome. Conventions for writing skills (frontmatter,
scripts, keeping skills generic, verification) are in [AGENTS.md](AGENTS.md),
which `CLAUDE.md` imports so every agent follows the same rules.

CI ([`.github/workflows/ci.yml`](.github/workflows/ci.yml)) runs on every PR
and push to `main`: `bash -n` and `shellcheck` on scripts,
[`scripts/check-skills.sh`](scripts/check-skills.sh) on every `SKILL.md`, and
`markdownlint` with the relaxed rules in
[`.markdownlint-cli2.yaml`](.markdownlint-cli2.yaml). Run
`scripts/check-skills.sh` locally before opening a PR.

## License

[MIT](LICENSE)
