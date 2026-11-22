---
name: new-terraform-module
description: Scaffold a new reusable Terraform module (AWS by default), or bring an existing one into a modules repo, so it is generic, safe by default, version-constrained and documented. Follows the conventions of the modules already in the repo, with sensible defaults when there are none. Checks first that no existing module already covers it, and warns when a change to an existing module isn't backwards compatible. Use when the user asks to create, add, scaffold, port, copy in, update, or clean up a Terraform module, or to check a module is generic and publishable.
---

# New Terraform module

Create, import or update a reusable module that anyone can call: generic, safe
by default, documented, backwards compatible, and with minimum-only version
constraints.

## 0. Learn the repo first

Reuse the repo's conventions before applying the defaults below:

```sh
git rev-parse --show-toplevel
find . -name versions.tf -not -path '*/.terraform/*'    # where modules live
ls .github/workflows/ 2>/dev/null                       # CI that checks modules
```

- **Layout:** modules as top-level directories, under `modules/`, or a single
  module at the root? Put the new module in the same place.
- **Exemplars:** pick one or two well-documented existing modules. Copy their
  file split, variable grouping, README structure and `versions.tf` floors.
- **Index:** if the root README has a modules table, the new module gets a row.
- **CI:** note which checks run on modules (fmt, validate, tflint, docs) so you
  can run the same ones locally.

Ask the user for anything you can't infer: module name, provider, and the core
resources and features.

## 0.5. Check for an existing module

Before scaffolding anything, make sure the module doesn't already exist:

```sh
ls -d */ modules/*/ 2>/dev/null                          # module directories
grep -rlE 'resource "<main resource type>"' --include='*.tf' .   # e.g. aws_s3_bucket
grep -iE '<name>|<resource>' README.md                   # root module list
```

- **A module in the repo already covers it** (same name, same main resource or
  overlapping purpose): stop and tell the user. Suggest extending that module
  (follow "Changing an existing module" below) rather than adding a second one
  that does the same job.
- **Close but different** (e.g. an `s3-bucket` module exists and the user wants
  a static-website bucket): ask whether to add a feature to the existing module
  or create a separate one, and recommend one.
- **A well-maintained public module already does this** (e.g. the
  `terraform-aws-modules` collection on the Terraform Registry): mention it so
  the user can choose between calling it and writing their own. Don't decide
  for them.

Only continue with a new module once the user confirms.

## 1. Layout

```
<module>/
  main.tf        # resources; locals and data sources may live here too
  variables.tf   # inputs, grouped by feature with section comments
  outputs.tf     # every output has a description
  versions.tf    # required_version + required_providers
  README.md
```

Split large features into their own files (e.g. `flow-logs.tf`,
`vpn-gateway.tf`). Add `examples/` only if the repo's modules have them.

## 2. versions.tf

Match the repo's existing floors. If there are no other modules:

```hcl
terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0"
    }
  }
}
```

- **Minimums only**, never pins or upper bounds; callers pin in their root stacks.
- Raise the provider minimum only when an argument needs it, with a comment
  naming that argument. Check the provider CHANGELOG rather than guessing.
- Don't set `required_version` higher than the features used need. A wider range
  also lets OpenTofu users call the module.
- Never commit `.terraform.lock.hcl` or `.terraform/` in a reusable module.

## 3. Inputs and outputs

- Every variable has a `type` and a `description`. Every output has a `description`.
- Keep required inputs few. Default everything else to the **safe** choice:
  encryption on, public access blocked, TLS-only, least-privilege IAM, bounded
  retention.
- Optional maps and lists default to `{}` or `[]`. `tags` defaults to `{}` and is
  applied to every taggable resource.
- `validation` blocks for enums and ranges; `lifecycle { precondition }` for
  cross-variable rules ("X is required when Y is enabled").
- Optional features use `count = var.enable_x ? 1 : 0` (or `for_each`
  consistently). Their outputs return `null` when disabled, via `try(...)` or a
  ternary. Never return placeholder strings like `"NOT_ENCRYPTED"`.
- Don't declare variables nothing uses: remove them or implement them.
- Get account ID and region from `data "aws_caller_identity"` /
  `data "aws_region"` instead of requiring them (an optional override is fine).
- No `prevent_destroy` in shared modules; callers can't turn it off.

## 4. Keep it generic

Sweep the module, code **and** README, and remove or genericize:

- Company, product, team, app or service names (resource names, prefixes, tags,
  descriptions, comments, examples)
- Internal conventions: compliance-tool tags, house tag keys, internal role
  names used as defaults
- Real account IDs, ARNs, resource IDs, domains, emails, Kubernetes
  namespaces/service accounts
- References to sibling modules, repos or stacks that don't exist in this repo
- Company-specific or non-RFC1918 CIDRs (private ranges: `10.0.0.0/8`,
  `172.16.0.0/12`, `192.168.0.0/16`)
- An org's home region in defaults or examples
- Comments that tell one org's history ("legacy", "to avoid renaming our…")

Use placeholders: `acme`, `my-app`, `example`, `111111111111`,
`vgw-12345678`, `10.0.0.0/16`, `us-east-1`. Turn hardcoded org values into
inputs with neutral defaults (often `null`).

Quick sweep (review every hit by hand; no hits is not proof it's clean):

```sh
grep -rnE --exclude-dir=.git --exclude-dir=.terraform \
  '\b[0-9]{12}\b|[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}|https?://|\b(vpc|subnet|sg|vgw|igw)-[0-9a-f]{8,17}\b' <module>/
```

When importing an existing module, also check `git log -p -- <module>` in case
org content was ever committed. Public repos expose history.

## 5. README

Follow the repo's exemplar modules. Without one, use:

1. `# <Name> Module` and a one-line summary
2. `## Features` (bullets)
3. `## Usage`: a basic example first, then one `###` example per feature.
   Copy-pasteable, placeholders only, consistent regions and CIDRs.
4. Feature-specific notes or caveats
5. `## Requirements` table matching `versions.tf`
6. `## Inputs` (grouped like `variables.tf`) and `## Outputs` tables, matching
   the code exactly. Use `terraform-docs` if the repo does.

Add the module to the root README's module list if there is one.

## Changing an existing module: keep it backwards compatible

Callers depend on a module's inputs, outputs and resource addresses. Treat every
change to an existing module as a potential breaking change, and check the diff
against this list:

| Breaking change | Compatible alternative |
| --------------- | ---------------------- |
| Removing or renaming a variable | Keep the old name and deprecate it in its description; add the new one alongside |
| Adding a variable without a default (new required input) | Give it a default that preserves today's behavior |
| Changing a variable's `type` in a narrowing way, or adding stricter `validation` | Widen instead; validate only new values |
| Changing a default so existing callers get different infrastructure | Keep the old default; let callers opt in |
| Removing or renaming an output, or changing its type/shape | Keep the old output; add the new one |
| Renaming a resource or moving it into/out of `count`/`for_each` (address change → destroy and recreate) | Add a `moved` block from the old address |
| Changing an argument the provider can't update in place (forces replacement) | Make it opt-in, or call out the replacement explicitly |
| Raising `required_version` or a provider minimum | Only when a feature needs it; document why |

If a change is **not** backwards compatible, **you must warn the user before
finishing**, and say so again in the final summary:

- What breaks, and for whom (which inputs, outputs or resources)
- What callers will see on their next `plan` (errors, destroy/recreate, changed values)
- The migration steps callers need (rename inputs, `moved`/`terraform state mv`, pin the old version)
- That this needs a **major version bump** if the module is versioned, plus
  upgrade notes in the README or CHANGELOG

Don't make a breaking change silently, even if it's an improvement. Let the
user decide.

## 6. Verify

Find Terraform (`which terraform tofu`; also try `/opt/homebrew/bin/terraform`),
then from the module directory:

```sh
terraform fmt -recursive
terraform init -backend=false -input=false
terraform validate
rm -rf .terraform .terraform.lock.hcl   # don't leave init artifacts
```

Also run any other checks the repo's CI runs on modules (e.g. `tflint`). If
Terraform isn't installed, say so rather than claiming the module validates.
`validate` checks syntax and types, not real deploys, so don't call the module
"tested" on that basis.

## Don't

- Commit, push or open a PR without asking. If the user wants a PR, use the
  `git-create-pr` skill.
- Claim more testing than actually ran.
