# Detection cheat sheet

Files that turn into facts. Read the file to confirm before reporting. A
filename alone is a hint, not proof.

## Languages, runtimes and package managers

| Files | Tells you |
|-------|-----------|
| `package.json`, `package-lock.json` / `yarn.lock` / `pnpm-lock.yaml` / `bun.lockb` | Node.js/JS/TS; package manager from the lockfile; `engines`, `scripts`, `workspaces` |
| `tsconfig*.json` | TypeScript; `paths`, project references |
| `.nvmrc`, `.node-version`, `.tool-versions`, `mise.toml`, `.mise.toml` | Pinned runtime versions |
| `pnpm-workspace.yaml`, `turbo.json`, `nx.json`, `lerna.json` | JS monorepo and its task runner |
| `go.mod`, `go.work` | Go version, module path, workspace |
| `pyproject.toml`, `requirements*.txt`, `Pipfile`, `poetry.lock`, `uv.lock`, `setup.py`, `.python-version` | Python; tool (poetry, uv, hatch, pip) and version |
| `Cargo.toml`, `Cargo.lock`, `rust-toolchain.toml` | Rust; workspace members, toolchain |
| `pom.xml`, `build.gradle(.kts)`, `settings.gradle(.kts)`, `gradle/libs.versions.toml` | JVM (Java/Kotlin); modules, versions |
| `Gemfile`, `Gemfile.lock`, `.ruby-version` | Ruby (Rails if `config/application.rb`) |
| `composer.json` | PHP (Laravel if `artisan`) |
| `*.csproj`, `*.sln`, `global.json` | .NET |
| `mix.exs` | Elixir (Phoenix if `lib/*_web`) |
| `Package.swift`, `*.xcodeproj`, `Podfile` | Swift / iOS |
| `pubspec.yaml` | Dart / Flutter |
| `*.tf`, `.terraform.lock.hcl`, `versions.tf` | Terraform/OpenTofu; `required_version`, providers |
| `*.sh`, `bin/` only | Shell tooling repo |

## Frameworks (confirm from dependencies)

- Web/API: express, fastify, nestjs, next, nuxt, remix, astro, django, flask,
  fastapi, rails, spring-boot, gin, echo, fiber, axum, actix, phoenix
- Front end: react, vue, svelte, angular, solid; bundlers vite, webpack,
  esbuild, turbopack
- Tests: jest, vitest, mocha, playwright, cypress, pytest, go `testing`, rspec,
  junit, cargo test
- Lint/format: eslint, biome, prettier, ruff, black, flake8, golangci-lint,
  rubocop, clippy, rustfmt, shellcheck, tflint, `.editorconfig`

## Entry points

- Go: `main.go`, `cmd/*/main.go`
- Node: `main`/`bin`/`exports` in `package.json`, `src/index.*`, `server.*`,
  Next.js `app/` or `pages/`
- Python: `__main__.py`, `[project.scripts]`, `manage.py`, `app.py`, `main.py`,
  `wsgi.py`/`asgi.py`
- JVM: `@SpringBootApplication`, `public static void main`
- Serverless: `serverless.yml`, `template.yaml` (SAM), `handler` functions,
  `functions/`
- Workers/cron: `Procfile`, `celery`, `sidekiq`, k8s `CronJob`, CI `schedule:`

## Local dev

`Makefile`, `Taskfile.yml`, `justfile`, `package.json` scripts,
`docker-compose*.yml` / `compose*.yaml`, `.devcontainer/`, `Tiltfile`,
`skaffold.yaml`, `.env.example` / `.env.sample`, `scripts/`, `bin/setup`,
`flake.nix`, `devbox.json`.

## CI/CD systems

| Files | System |
|-------|--------|
| `.github/workflows/*.yml` | GitHub Actions (also `.github/actions/*/action.yml` for local composite actions) |
| `.gitlab-ci.yml` (+ `include:`) | GitLab CI |
| `.circleci/config.yml` | CircleCI |
| `Jenkinsfile` | Jenkins |
| `azure-pipelines.yml` | Azure Pipelines |
| `.buildkite/pipeline.yml` | Buildkite |
| `bitbucket-pipelines.yml` | Bitbucket Pipelines |
| `.drone.yml`, `.woodpecker.yml` | Drone / Woodpecker |
| `cloudbuild.yaml`, `buildspec.yml` | Google Cloud Build / AWS CodeBuild |
| `.tekton/`, `argo-workflows` manifests | Tekton / Argo Workflows |

GitHub Actions details worth extracting:

- `on:` triggers and `paths`/`branches` filters. `pull_request_target` plus
  checking out the PR head is a security gotcha.
- `jobs.<id>.needs`, `strategy.matrix`, `runs-on` (hosted or self-hosted
  labels), `environment`, `concurrency`, `permissions`
- `uses: org/repo/.github/workflows/x.yml@ref` means a reusable workflow. Note
  it, because the real logic lives elsewhere.
- Action pins: `@<40-char sha>` (pinned) vs `@v4` (tag)
- `merge_group:` means the repo uses a merge queue

## PR rules and repo hygiene

| Files | Tells you |
|-------|-----------|
| `CODEOWNERS` (`.github/`, root, `docs/`) | Who must review which paths |
| `.github/pull_request_template.md`, `.github/PULL_REQUEST_TEMPLATE/` | PR expectations |
| `.github/ISSUE_TEMPLATE/` | Issue intake |
| `.pre-commit-config.yaml`, `.husky/`, `lefthook.yml` | Local hooks |
| `commitlint.config.*`, `.czrc` | Commit message rules |
| `dangerfile.*` | Danger checks on PRs |
| `.github/dependabot.yml`, `renovate.json`, `.renovaterc*` | Dependency updates |
| `.github/labeler.yml`, `release-drafter.yml` | Auto labels, release notes |
| `SECURITY.md`, `.github/codeql*`, `.snyk`, `trivy*` | Security scanning |

Server-side rules (rulesets, branch protection, required checks, merge queue)
live only in the GitHub API. Read them with `gh` (see SKILL.md step 5).

## Release and deploy

| Files | Tells you |
|-------|-----------|
| `.releaserc*`, `release.config.*` | semantic-release |
| `.changeset/` | Changesets |
| `release-please-config.json`, `.release-please-manifest.json` | release-please |
| `.goreleaser.y*ml` | GoReleaser |
| `Dockerfile*`, `.dockerignore`, `docker-bake.hcl` | Container images; base image versions |
| `Chart.yaml`, `values*.yaml` | Helm |
| `kustomization.yaml`, `overlays/<env>` | Kustomize; environments |
| `argocd`/`Application` manifests, `flux-system/` | GitOps |
| `*.tf` per directory/workspace, `terragrunt.hcl` | IaC; environments from dir names |
| `Pulumi*.yaml`, `cdk.json`, `template.yaml`, `serverless.yml` | Pulumi / CDK / SAM / Serverless |
| `vercel.json`, `netlify.toml`, `fly.toml`, `render.yaml`, `app.yaml`, `Procfile` | PaaS targets |

## Integrations

Find them through SDK dependencies (`@aws-sdk/*`, `boto3`, `stripe`,
`@sentry/*`, `launchdarkly`, `redis`, `pg`, `kafkajs`…), env var names in
`.env.example` and CI, connection config, and IaC resources. Report names
only, never values.
