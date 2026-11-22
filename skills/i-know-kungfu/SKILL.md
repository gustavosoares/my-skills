---
name: i-know-kungfu
description: Gives a high-level overview of the repository it runs in, read-only. Covers what the repo does, its tech stack, a code map with entry points, how to run it locally, Mermaid diagrams of the architecture and key workflows, how the CI/CD pipeline and PR checks work, how deploys and environments work, plus conventions, gotchas and open questions. Every claim cites the file it came from. Prints the overview in chat and offers to save it as Markdown. Use when the user says "I know kung fu", "enlighten me", "explain this repo", "onboard me", "give me an overview of this codebase", "what does this repo do", "how does CI work here", or "walk me through this project". Not for reviewing a diff or PR, debugging a specific bug, deep-diving a single function, or changing code.
---

# I know kung fu

*"I know kung fu." "Show me."* Upload a working mental model of the current
repository: what it is, how it's built, how code gets from a branch to
production, and where to start reading.

The skill is **read-only**. It reads files and runs read-only `git`/`gh`
commands. It doesn't build, test, install or deploy anything unless the user
asks, and the only file it writes is the saved overview, after the user
says yes.

## Prerequisites

- `git`
- Optional: an authenticated [`gh`](https://cli.github.com) to read rulesets,
  branch protection and recent workflow runs for GitHub repos. Everything else
  works without it.

## When to use

- First time in a repo, or coming back after a long break
- Onboarding someone, or writing an `OVERVIEW.md` / architecture doc
- "How does CI/CD work here?" or "What checks must my PR pass?"

## When NOT to use

- Reviewing a diff or PR: use a code-review skill
- Debugging one failure or tracing one function: just investigate it directly
- Changing code, CI config or branch protection

## Inputs to gather

Ask only if the request doesn't make these clear. Otherwise use the defaults.

| Input | Default |
|-------|---------|
| **Scope**: whole repo, or one package/subdirectory of a monorepo | whole repo |
| **Depth**: quick (about one screen) or full | full |
| **Audience**: new contributor, reviewer, or ops/on-call | new contributor |

The audience sets the emphasis. Contributors care most about setup, the code
map and conventions. Reviewers care about PR checks and merge rules. Ops cares
about deploys, environments, integrations and rollback.

## Workflow

Run independent read-only commands in parallel. Read files with the agent's
own file tools. Use `references/detection.md` to turn files into facts.

### 1. Orient

```bash
git rev-parse --show-toplevel
git remote -v
git rev-parse --abbrev-ref HEAD
git log --oneline -20
git ls-files | wc -l
git ls-files | awk -F/ 'NF>1{print $1}' | sort | uniq -c | sort -rn | head -20   # where the files are
```

Read, if present: `README*`, `CONTRIBUTING*`, `AGENTS.md`, `CLAUDE.md`,
`.cursor/rules`, `docs/`, ADRs (`docs/adr/`, `adr/`, `decisions/`),
`ARCHITECTURE.md`, `CHANGELOG*`. These state the intent. The code shows what
actually happens. When they disagree, say so.

### 2. Detect the tech stack

Find manifests, lockfiles and toolchain pins (see `references/detection.md`):
language and runtime versions, frameworks, package manager, build tool, test
framework, linters/formatters, containers and IaC. Take versions from config
files (`.tool-versions`, `.nvmrc`, `go.mod`, `pyproject.toml`, `Dockerfile`
`FROM`…), never from memory. For a monorepo, list the workspaces/packages and
what each one is.

### 3. Map the code

- **Entry points**: `main` functions, `cmd/*`, `bin` in `package.json`, server
  bootstrap (`app.listen`, `uvicorn`, `http.ListenAndServe`), serverless
  handlers, CLI definitions, cron/worker definitions.
- **Key modules**: the 5–10 directories that matter, one line each.
- **Data**: schemas, migrations, ORM models, API specs (OpenAPI, protobuf,
  GraphQL).
- **Tests**: where they live, the kinds (unit, integration, e2e), and how they
  run.
- **Generated or vendored code**: flag it so nobody edits it by hand.

### 4. How to run it locally

Collect commands only from files that exist: `Makefile`, `Taskfile.yml`,
`justfile`, `package.json` scripts, `pyproject` scripts, `docker-compose*.yml`,
`.devcontainer/`, `Tiltfile`, `.env.example`. Cover setup, run, test, lint and
format, plus required services (DB, cache, queues) and env var **names**. If
there is no obvious way to run it, say so. Don't run any of these unless the
user asks.

### 5. CI/CD pipeline and PR checks

Find the CI system (see `references/detection.md`) and read each pipeline
file. For each workflow or pipeline, record:

- **Triggers**: `push`, `pull_request`, `pull_request_target`, tags,
  `schedule`, `workflow_dispatch`, `workflow_call`, path and branch filters
- **Jobs** and their `needs` graph, matrices, runners (hosted or self-hosted
  labels)
- **Gates**: `environment:` with approvals, `if:` conditions, manual steps
- **Reusable workflows and actions** it calls, and whether they're pinned to a
  SHA or a tag
- **Secrets and variables**: names only, never values
- **What it produces**: artifacts, images, packages, releases, deployments

Then work out what a PR has to pass:

- Workflows triggered by `pull_request`/`merge_group`, and their job names
  (these are the check names a PR shows)
- `CODEOWNERS`, the PR template, `.pre-commit-config.yaml`, commit lint, Danger,
  labelers, and Dependabot/Renovate config
- For GitHub, with `gh` available (`$BASE` is the default branch):

```bash
gh repo view --json nameWithOwner,defaultBranchRef,visibility
gh api "repos/OWNER/REPO/rulesets" --jq '.[] | {id,name,target,enforcement}'
gh api "repos/OWNER/REPO/rules/branches/$BASE"        # effective rules on the branch
gh api "repos/OWNER/REPO/branches/$BASE/protection"   # classic protection
gh run list --limit 20 --json workflowName,event,conclusion,headBranch,createdAt
```

A `403` or `404` here usually means **missing permission**, not "no
protection". Report it as "couldn't read (needs admin or a token with
access)", never as "unprotected". If `gh` isn't installed or authenticated,
say the merge rules come from config files only.

### 6. Deploys and environments

- **Release flow**: tags, semantic-release, changesets, release-please,
  goreleaser, `CHANGELOG` automation, how versions are bumped
- **Where it runs**: container registry, Helm/Kustomize/ArgoCD/Flux,
  Terraform/OpenTofu/Pulumi/CDK/CloudFormation, serverless config, PaaS
  (`vercel.json`, `netlify.toml`, `fly.toml`, `Procfile`…)
- **Environments**: names from CI `environment:` keys, IaC workspaces or
  directories, config files per environment
- **Integrations**: databases, queues, caches, third-party APIs and feature
  flag services, taken from config, env var names, SDK dependencies and IaC
- **Rollback**: is there a documented or automated path? Say if there isn't.

### 7. Conventions, gotchas and health

- **Conventions**: commit style (from `git log`), branch naming, code style
  tools, review rules, and docs the repo expects to be updated
- **Hotspots**: files changed most often in the last 90 days

```bash
git log --since=90.days --name-only --pretty=format: | grep -v '^$' | sort | uniq -c | sort -rn | head -15
```

- **Debt markers**: count `TODO|FIXME|HACK|XXX` per directory and show the top
  few
- **Gaps**: no tests, CI that doesn't run tests, unpinned actions, no
  lockfile, no dependency bot, `pull_request_target` checking out PR code,
  docs that contradict the config
- **Open questions**: things the files don't answer. List them rather than
  guessing.

### 8. Diagrams

Draw 2–4 Mermaid diagrams, chosen from what you found. Only draw what the files
support:

- **Architecture** (`flowchart TB`): components, datastores, external services
- **Key workflow** (`sequenceDiagram`): the main request, job or data flow
- **CI/CD pipeline** (`flowchart LR`): triggers → jobs (from `needs`) → gates →
  environments
- **Release/deploy flow**, when it's separate from CI

Mermaid rules that avoid broken renders: quote labels that contain spaces or
punctuation (`A["api server"]`), use plain alphanumeric node IDs, no
parentheses or `:` in unquoted labels, keep each diagram under ~20 nodes. Split
a big one rather than cramming it.

### 9. Write the overview

Use `references/report-template.md`. Rules:

- **Cite sources**: every non-obvious claim links the file it came from
  (`path` or `path:line`).
- **Mark inferences**: write *(inferred)* when a claim comes from naming or
  structure rather than explicit config.
- Skip sections that don't apply rather than padding them. A library has no
  deploy section. Say "none found" once and move on.
- For **quick** depth: the TL;DR, tech stack, a code map, one diagram, and
  the CI/PR checks summary.
- Never print secret values, tokens, or the contents of `.env` files.

### 10. Offer to save

After printing the overview, ask: *"Save this as a Markdown file? (suggested:
`docs/OVERVIEW.md`)"*. If the target exists, show what's there and ask before
overwriting or merging. Don't commit the file. Leave that to the user (or
the `git-commit` skill).

## Never

- Build, test, install dependencies, run migrations or deploy without being
  asked
- Print secret values or `.env` contents. Names only.
- Invent commands, services or environments that aren't in the repo
- Report a permission error as "no protection" or "no checks"
- Write any file other than the saved overview, and only after a yes

## References

- [references/detection.md](references/detection.md): which files reveal the
  stack, CI, PR rules and deploy targets
- [references/report-template.md](references/report-template.md): the
  overview template, with Mermaid examples
