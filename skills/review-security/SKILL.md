---
name: review-security
description: Security review of code changes, either the current branch against its base (plus uncommitted work) or a GitHub PR by number or URL. Maps the trust boundaries the diff touches, traces untrusted input to dangerous sinks (injection, path traversal, SSRF, XSS, deserialization), and checks authn/authz, secrets, crypto, insecure IaC defaults, CI workflow risks and new dependencies. Reports only findings it can back with a source-to-sink path or a clearly unsafe setting, with severity and confidence. Use when the user asks for a "security review", "security check", "is this safe", "check for vulnerabilities", "audit this PR for security", or before shipping auth, input handling or infra changes. Report-only by default. Not for general bugs (use review-code), pentesting live systems, or compliance audits.
---

# Review security

Look for vulnerabilities the change introduces or makes reachable, and prove
each one by tracing how attacker-controlled data gets to a dangerous operation.
A short list of findings that can actually be exploited beats a long list of
"consider validating input".

## Prerequisites

- `git`
- An authenticated [`gh`](https://cli.github.com) only for PR targets
- Optional scanners, used only if already installed and the user agrees:
  [`gitleaks`](https://github.com/gitleaks/gitleaks),
  [`semgrep`](https://semgrep.dev), [`trivy`](https://trivy.dev), and the
  ecosystem's audit tool (`npm audit`, `pip-audit`, `govulncheck`,
  `cargo audit`, `bundle audit`)

## When to use

- Changes to auth, sessions, permissions, input parsing, file or shell access,
  outbound requests, templates, crypto, secrets, IaC, or CI workflows
- Before merging a PR from an outside contributor
- "Security review this", "is this safe to ship?"

## When NOT to use

- General correctness review: use `review-code`
- Testing a running system (scanning hosts, fuzzing endpoints): out of scope
- A whole-repo audit: offer to scope it to an area or entry point first

## Inputs to gather

- **Target:** nothing (current branch), a PR number/URL, a branch, or a path
- **Threat context**, if not obvious from the code: who can reach this
  (public internet, authenticated users, internal only), and what data it
  handles. Ask rather than assume; it changes severity.

## Workflow

### 1. Resolve the target (read-only)

Same as `review-code`:

```sh
gh repo view --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null \
  || git symbolic-ref --short refs/remotes/origin/HEAD    # strip "origin/"
git fetch origin "$BASE" --quiet
git diff --stat "origin/$BASE...HEAD"
git diff "origin/$BASE...HEAD"
git diff HEAD                                              # uncommitted work
# PR target:
gh pr view "$PR" --json number,title,headRefName,baseRefName,files,url
gh pr diff "$PR"
```

### 2. Fresh context

If the agent can start a subagent, run steps 3–6 in one with only the target,
diff and threat context. Treat the PR description's safety claims ("input is
already validated") as things to verify.

### 3. Map the trust boundaries

From the diff and the files around it, list:

- **Sources:** request params, headers, cookies, bodies, file uploads, CLI
  args, env vars, message queues, webhooks, DB rows written by users, PR
  titles/branch names in CI
- **Sinks:** SQL/NoSQL queries, shell commands, file paths, URLs fetched by
  the server, HTML/templates, deserializers, `eval`-like calls, redirects,
  logs, IAM/policy documents
- **Controls:** authentication, authorization checks, validation, encoding,
  parameterization, sandboxing

Read changed files in full and follow the data to its source and sink, even
outside the diff.

### 4. Check by category

Go through the categories that apply to the diff. Sources, sinks, and what
"safe" looks like for each are in
[references/checklist.md](references/checklist.md):

1. Injection: SQL/NoSQL, OS command, template, LDAP/XPath, header/log injection
2. Path traversal and unsafe file handling (uploads, archive extraction, symlinks)
3. SSRF and unsafe outbound requests
4. XSS, CSRF, open redirects, CORS
5. Authentication and session handling
6. Authorization: missing checks, IDOR, privilege escalation, mass assignment
7. Unsafe deserialization and dynamic code execution
8. Cryptography: weak algorithms, home-made crypto, bad randomness, missing
   verification
9. Secrets: hardcoded credentials, secrets in logs, errors or client bundles
10. Infrastructure as code: public access, wildcard IAM, missing encryption,
    open security groups
11. CI/CD: `pull_request_target` with checkout of PR code, untrusted
    `${{ github.event.* }}` in `run:`, unpinned third-party actions, broad
    `permissions:`
12. Dependencies: new or bumped packages, typosquats, install scripts, known CVEs
13. Denial of service the change makes easy: unbounded input, ReDoS, missing
    limits or timeouts

### 5. Optional scanners (ask first)

Run only tools that are already installed, scoped to the changed files where
possible, e.g. `gitleaks detect --no-git --source <path>`,
`semgrep scan --config auto <files>`, `trivy config <dir>`. Scanner output is
a lead, not a finding: verify each hit as in step 6.

### 6. Verify every finding

For each candidate, write down:

- **Source:** where attacker-controlled data enters, and who the attacker is
- **Path:** how it flows to the sink (`file:line` hops)
- **Sink:** the dangerous operation
- **Missing control:** the check, encoding or parameterization that isn't there
  (and confirm it isn't applied upstream by a framework, middleware or type)

For settings-type findings (IaC, CI, crypto choice), name the exact setting and
what an attacker can do because of it.

If you can't fill this in, drop the finding or list it as a **hardening note**,
not a vulnerability. Rate **confidence** (high/medium/low) honestly.

## Report

```markdown
## Security review: <branch or PR #N> against <base>

<One line: e.g. "1 high (SQL injection in search), 1 medium, no secrets found.">
Threat context assumed: <who can reach this code>

### Findings

1. **[high · confidence high] SQL injection in `searchUsers`** — `api/users.py:88`
   **Source → sink:** `q` query param → `build_filter()` (`api/filters.py:12`) →
   f-string into `cursor.execute()`
   **Exploit:** `GET /users?q=' OR 1=1--` returns every user
   **Fix:** use a parameterized query: `cursor.execute("… WHERE name LIKE %s", (f"%{q}%",))`

### Hardening notes

- <defence-in-depth suggestions that aren't exploitable as written>

### Scope

<Categories checked, files and flows traced, scanners run and their results.
What was out of scope or not checked.>
```

Severity (adjust for the threat context):

- **critical:** remote, unauthenticated compromise, RCE, or mass data exposure
- **high:** exploitable by any authenticated user, or leads to privilege escalation
- **medium:** needs unusual conditions, or the impact is limited
- **low:** minor information leak or hard to exploit

## After the report (each needs the user's yes)

- Apply fixes in the working tree; don't commit (hand off to `git-commit`).
- Post findings to a PR as a single `COMMENT` review, the same way as
  `review-code`. For a public repo, suggest reporting critical/high issues
  privately (a security advisory) rather than in PR comments.

## Never

- Run exploits or send requests to live systems
- Print secrets you find in full; show the location and a redacted prefix
- Approve PRs, or edit, commit or push without asking
