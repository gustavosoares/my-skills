# Security review checklist

Per-category guide for `review-security`. For each category: what to look for,
typical sinks, and what the safe version looks like. Check only the
categories the change touches.

## 1. Injection

- **SQL/NoSQL:** string concatenation, f-strings, template literals or
  `format()` into queries; raw-query escape hatches in ORMs (`raw()`,
  `extra()`, `$where`, `sequelize.literal`). Mongo operators from JSON bodies
  (`{"$ne": null}`).
  Safe: parameterized queries or bound ORM methods; allow-lists for
  identifiers (column names, sort order) that can't be parameterized.
- **OS command:** `shell=True`, `os.system`, `exec`/`child_process.exec`,
  backticks, `sh -c "… $var"`. Arguments starting with `-` (option injection).
  Safe: argument arrays without a shell, `--` before user arguments.
- **Template (SSTI):** user input used as the template itself (`render_template_string`,
  `new Function`, Handlebars/Jinja compile on input).
- **Header/log injection:** CR/LF in values written to headers or logs.
- **LDAP/XPath/GraphQL:** filters built by concatenation.

## 2. Path traversal and file handling

- User input in file paths (`../`, absolute paths, URL-encoded variants,
  Windows `\`), `path.join(base, input)` without checking the result stays
  under `base`.
- Archive extraction (zip slip), symlink following, temp files with
  predictable names, world-writable permissions.
- Uploads: content type trusted from the client, files served from the web
  root, no size limit.
  Safe: resolve the real path and check it's inside the allowed directory;
  generate server-side file names.

## 3. SSRF and outbound requests

- Server fetches a URL or host that the user controls (webhooks, image
  proxies, "import from URL", PDF renderers).
- Checks on the hostname string that DNS rebinding or redirects get around;
  access to `169.254.169.254`, `localhost`, internal ranges, `file://`,
  `gopher://`.
  Safe: allow-list of destinations; resolve and check the IP at connect time;
  disable redirects or re-check each one; IMDSv2 on cloud hosts.

## 4. XSS, CSRF, redirects, CORS

- **XSS:** `innerHTML`, `dangerouslySetInnerHTML`, `v-html`, `|safe`,
  `{{{ }}}`, `mark_safe`, building HTML strings, user input in `href`/`src`
  (`javascript:`), in inline scripts, or in event handlers.
- **CSRF:** state-changing GET routes; cookie auth without SameSite or tokens;
  CSRF protection disabled for a route.
- **Open redirect:** `redirect(request.args["next"])` without an allow-list.
- **CORS:** reflecting `Origin` with `Allow-Credentials: true`; `*` on
  authenticated APIs.

## 5. Authentication and sessions

- Endpoints added without the auth middleware or decorator the rest use.
- JWT: `alg: none` accepted, signature not verified, `decode` used instead of
  `verify`, no expiry check, secret in code.
- Passwords: plain or fast hashes (MD5/SHA-1/SHA-256) instead of bcrypt,
  scrypt or Argon2; timing-unsafe comparisons of tokens.
- Sessions not rotated on login, long-lived tokens, tokens in URLs.
- Rate limiting removed from login or reset flows.

## 6. Authorization

- Object fetched by an ID from the request without checking it belongs to the
  caller (IDOR).
- Role checks only in the UI, or only on some HTTP methods.
- Mass assignment: request body bound straight to a model (`is_admin`,
  `owner_id`, `role`).
- Multi-tenant queries missing the tenant filter.
- Admin or debug routes exposed.

## 7. Deserialization and dynamic code

- `pickle`, `yaml.load` (non-safe loader), Java/PHP native deserialization,
  `Marshal`, `BinaryFormatter` on untrusted data.
- `eval`, `exec`, `Function()`, `vm.runInContext`, reflection driven by input.
- Prototype pollution from merging user JSON into objects (`__proto__`,
  `constructor`).

## 8. Cryptography

- MD5/SHA-1 for security, ECB mode, static IVs or nonces, home-made
  encryption, `Math.random()` / `random` for tokens (use a CSPRNG).
- TLS verification turned off (`verify=False`, `rejectUnauthorized: false`,
  `InsecureSkipVerify`).
- Keys or salts hardcoded or committed.

## 9. Secrets

- Credentials, tokens or private keys in code, tests, fixtures, configs, or
  example files. Common shapes: `AKIA…`, `ghp_`/`gho_`/`github_pat_`,
  `xox[abp]-`, `sk_live_`, `-----BEGIN … PRIVATE KEY-----`.
- Secrets logged, included in error messages, sent to analytics, or bundled
  into client-side code (`NEXT_PUBLIC_*`, `VITE_*`).
- `.env` files or state files (`*.tfstate`) committed.

## 10. Infrastructure as code

- Storage buckets or blobs public, or with public ACLs and policies.
- IAM with `"Action": "*"`, `"Resource": "*"`, or `iam:PassRole` that is too
  broad; trust policies any principal can assume.
- Security groups / firewall rules open to `0.0.0.0/0` on admin or DB ports.
- Encryption at rest or in transit turned off; databases publicly
  accessible; logging or audit trails disabled.
- Kubernetes: `privileged: true`, `hostPath`, `hostNetwork`, running as root,
  wildcard RBAC.

## 11. CI/CD workflows

- `pull_request_target` or `workflow_run` that checks out and runs PR code
  with secrets available.
- `${{ github.event.issue.title }}`, `…pull_request.title`, `…head_ref`,
  `…comment.body` interpolated straight into `run:` (script injection). Safe:
  pass through `env:` and quote it.
- Third-party actions pinned to a tag or branch instead of a full commit SHA.
- `permissions: write-all` or no `permissions:` block on workflows that
  don't need write access.
- Secrets echoed, or passed to steps that don't need them.
- Self-hosted runners used by workflows that public fork PRs can trigger.

## 12. Dependencies

- New packages: check the name (typosquats), maintainer, download count, and
  whether it has install scripts.
- Bumps: changelog for breaking security changes; known CVEs via the
  ecosystem's audit tool.
- Lockfile changes that don't match the manifest; dependencies pulled from git
  URLs or unpinned versions.

## 13. Denial of service

- No limit on request, file, or collection size; recursion on user input;
  regexes with nested quantifiers on user input (ReDoS); missing timeouts on
  outbound calls; work done before auth.
