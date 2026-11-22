---
name: github-branch-protection
description: Protect a GitHub repo's default branch with a ruleset so changes go through pull requests, only code owners can approve, and required CI checks must pass. Use when the user asks to protect main, require PRs or reviews, restrict who can approve or merge, add CODEOWNERS, require status checks, or set up branch protection/rulesets, in any repo.
---

# GitHub branch protection

Set up a repository ruleset on the default branch. The result:

- No direct pushes, force pushes, or deletion of the default branch.
- Every change needs a PR, approved by a code owner, with review threads resolved and stale approvals dismissed on new pushes.
- Required CI checks must pass (optional).
- Only the chosen merge methods are allowed (default: squash).
- Fork PRs need maintainer approval before their workflows run (public repos).

This changes shared repo settings, so **show the plan and get a yes before applying anything**.

## 1. Inspect the current state

```sh
gh repo view --json nameWithOwner,visibility,defaultBranchRef,owner
gh api repos/{owner}/{repo}/rulesets --jq '.[] | {id, name, enforcement}'
gh api repos/{owner}/{repo}/branches/<default>/protection 2>&1   # classic protection, if any
gh api repos/{owner}/{repo}/collaborators --jq '.[].login'
ls .github/CODEOWNERS CODEOWNERS docs/CODEOWNERS 2>/dev/null
ls .github/workflows/ 2>/dev/null
```

Flag:

- Existing rulesets or classic branch protection that would overlap. Rules from all of them stack, and the strictest wins. Suggest removing leftovers, such as disabled duplicates.
- A **private repo on a free personal plan**. Rulesets aren't enforced there; they need GitHub Pro, Team, or Enterprise. Say so rather than applying a ruleset that does nothing.
- Whether the repo is **solo** (one maintainer) or **team**. That decides the bypass setting below.

## 2. Decide the settings

| Setting | Solo maintainer | Team |
|---------|-----------------|------|
| Required approvals | 1 | 1+ |
| Code owner review | yes | yes |
| Admin bypass | **yes, PR-only** (`bypass_mode: pull_request`) | usually none (`-B`) |
| Merge methods | squash | team's choice |

**Why the bypass for solo repos:** GitHub never lets you approve your own PR. With one maintainer, a required approval would block every merge. A repository-admin bypass with `bypass_mode: pull_request` keeps the PR requirement, so direct pushes stay blocked, but lets the admin merge their own PRs. Outside contributors still need the owner's approval.

**Required status checks:** the `context` must exactly match the check-run name GitHub reports. That is the job's `name:` (or job id), not the workflow name. A matrix job reports one check per entry (`validate (vpc)`), so make a single aggregator job that always runs and require that:

```yaml
checks:
  name: ci-checks
  needs: [validate]
  if: always()
  runs-on: ubuntu-latest
  steps:
    - run: |
        r="${{ needs.validate.result }}"
        [[ "$r" == success || "$r" == skipped ]] || { echo "validate: $r"; exit 1; }
```

Allowing `skipped` lets PRs that touch no relevant paths still merge. Don't require a check that never runs on some PRs, or those PRs will sit waiting forever.

## 3. CODEOWNERS

Create `.github/CODEOWNERS` if it's missing (ask who owns what for team repos):

```text
# Default owner for everything; requested automatically on every PR
* @<owner-login>
```

Use a real login or `@org/team`. In a team repo, the team needs write access. The CODEOWNERS file only takes effect once it's on the default branch.

## 4. Apply

The bundled script (`scripts/apply-ruleset.sh`) builds the ruleset JSON, then creates it or updates it in place if one with the same name exists. An update merges into the existing ruleset: it sets only the options below and keeps everything else (other rules, other bypass actors, conditions, pull request parameters it doesn't manage). Without `-c`, an existing required-checks rule is left as it is; with `-c`, its check list is replaced. Your working directory is the user's project, so resolve its absolute path first: use `<skill base directory>/scripts/apply-ruleset.sh` (the directory reported when this skill loaded), else the first that exists of:

```sh
for d in ~/.claude/skills ~/.agents/skills ~/.cursor/skills; do
  f="$d/github-branch-protection/scripts/apply-ruleset.sh"
  [[ -x "$f" ]] && { echo "$f"; break; }
done
```

If none exists, suggest reinstalling: `npx skills add gustavosoares/my-skills --skill github-branch-protection`. Then, always starting with a dry run:

```sh
S=<resolved path>
$S -d -c ci-checks                 # dry run: print the JSON that would be sent
$S -c ci-checks                    # solo: admin can merge own PRs
$S -B -a 1 -m squash,rebase        # team: no bypass
```

Options: `-r owner/repo`, `-n name` (default `protect-main`), `-c` checks, `-m` merge methods, `-a` approvals, `-B` no bypass, `-d` dry run, `-h` help. On an update, compare the dry-run JSON with the live ruleset (`gh api repos/{owner}/{repo}/rulesets/<id>`) and show the user what changes.

For **public repos**, require approval before workflows run on fork PRs. Send a JSON body; `-f` flags don't apply this setting:

```sh
echo '{"approval_policy":"all_external_contributors"}' \
  | gh api -X PUT repos/{owner}/{repo}/actions/permissions/fork-pr-contributor-approval --input -
```

Optionally tidy the merge settings to match the ruleset:

```sh
gh repo edit --enable-squash-merge --enable-merge-commit=false --enable-rebase-merge=false --delete-branch-on-merge
```

## 5. Verify and hand off

```sh
gh api repos/{owner}/{repo}/rulesets/<id> --jq '{enforcement, current_user_can_bypass, rules: [.rules[].type]}'
gh api repos/{owner}/{repo}/actions/permissions/fork-pr-contributor-approval
```

For a solo maintainer, `current_user_can_bypass` should be `pull_requests_only`. Report what changed, and tell a solo maintainer how to merge their own PRs:

- On the PR page, tick **"Merge without waiting for requirements to be met (bypass rules)"**. The newer PR UI can hide this checkbox; switching to the classic merge box shows it.
- Or from the CLI: `gh pr merge <n> --squash --admin`.

Don't push a test commit to the default branch to "prove" it's blocked unless the user asks.
