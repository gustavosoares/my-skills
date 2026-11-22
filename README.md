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
npx skills add gustavosoares/my-skills --skill troubleshoot-github-aws-runners -g -a claude-code -a cursor -y
```

List several names after `--skill` to install more than one. Drop
`-g -a … -y` to pick scope and agents in the interactive prompt instead.

### Update

**All installed skills:**

```bash
npx skills update -g -y
```

**A specific skill:**

```bash
npx skills update troubleshoot-github-aws-runners -g -y
```

`update` covers every globally installed skill, including ones from other
repos. Use `npx skills ls -g` to see what's installed. Updating doesn't pick up
skills added to this repo after you installed; re-run the **All skills**
command above for those.

## Layout

```
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

| Skill | Description | Requires |
|-------|-------------|----------|
| [`troubleshoot-github-aws-runners`](skills/troubleshoot-github-aws-runners/SKILL.md) | Diagnose self-hosted GitHub Actions jobs stuck in Queued, scale-up not launching, fleets at cap, DLQ messages and JIT registration failures | Runners deployed with [terraform-aws-github-runner](https://github.com/github-aws-runners/terraform-aws-github-runner); `aws`, `jq`; optional `gh`, [Granted](https://granted.dev) |

## Contributing

Issues and PRs are welcome. Conventions for writing skills (frontmatter,
scripts, keeping skills generic, verification) are in [AGENTS.md](AGENTS.md),
which `CLAUDE.md` imports so every agent follows the same rules.

## License

[MIT](LICENSE)
