#!/usr/bin/env bash
# Create or update a branch ruleset that requires PRs on the default branch.
# Idempotent: updates the ruleset with the same name if it exists.
#
# Usage: apply-ruleset.sh [options]
#   -r owner/repo     target repo (default: current repo via gh)
#   -n name           ruleset name (default: protect-main)
#   -c checks         comma-separated required status check names (default: none)
#   -m methods        comma-separated merge methods: squash,merge,rebase (default: squash)
#   -a count          required approvals (default: 1)
#   -B                no admin bypass (team repos where someone else can approve)
#   -d                dry run: print the JSON that would be sent and exit
#   -h, --help        print this help
#
# Updating an existing ruleset merges into it rather than replacing it:
#   - settings this script manages (listed above) are set to the given values
#   - every other field is kept: extra pull_request parameters, other rule
#     types, other bypass actors, and the ruleset's conditions
#   - an existing required_status_checks rule is kept as-is unless -c is given;
#     with -c its check list is replaced (integration_id kept per check name)
#
# Requires: gh (authenticated), jq.
# Permissions: reads and writes repository rulesets (repo admin). -d only reads.
# Exit codes: 0 success, 1 GitHub API error, 2 bad option, 64 bad argument.
set -euo pipefail

usage() { sed -n '2,/^set -euo/{/^set -euo/d;s/^# \{0,1\}//;p;}' "$0"; }

if [[ ${1:-} == --help ]]; then usage; exit 0; fi

repo="" name="protect-main" checks="" methods="squash" approvals=1 bypass=1 dry=0
while getopts "r:n:c:m:a:Bdh" o; do
  case $o in
    r) repo=$OPTARG ;; n) name=$OPTARG ;; c) checks=$OPTARG ;; m) methods=$OPTARG ;;
    a) approvals=$OPTARG ;; B) bypass=0 ;; d) dry=1 ;; h) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

if ! [[ $approvals =~ ^[0-9]+$ ]]; then
  echo "error: -a must be a non-negative integer (got '$approvals')" >&2
  exit 64
fi
if [[ -z ${methods//,/} ]]; then
  echo "error: -m needs at least one merge method" >&2
  exit 64
fi
IFS=',' read -r -a method_list <<< "$methods"
for m in "${method_list[@]}"; do
  case $m in
    squash|merge|rebase) ;;
    *) echo "error: -m accepts squash, merge, rebase (got '$m')" >&2; exit 64 ;;
  esac
done

if [[ -z $repo ]]; then
  if ! repo=$(gh repo view --json nameWithOwner -q .nameWithOwner); then
    echo "error: couldn't detect the repo; pass -r owner/repo" >&2
    exit 64
  fi
fi

# Settings this script manages.
desired=$(jq -n \
  --arg name "$name" --arg checks "$checks" --arg methods "$methods" \
  --argjson approvals "$approvals" '
  def csv: split(",") | map(select(length > 0));
  {
    name: $name,
    target: "branch",
    enforcement: "active",
    conditions: { ref_name: { include: ["~DEFAULT_BRANCH"], exclude: [] } },
    rules: ([
      { type: "deletion" },
      { type: "non_fast_forward" },
      { type: "pull_request", parameters: {
          required_approving_review_count: $approvals,
          dismiss_stale_reviews_on_push: true,
          require_code_owner_review: true,
          require_last_push_approval: false,
          required_review_thread_resolution: true,
          allowed_merge_methods: ($methods | csv)
      } }
    ] + (if ($checks | csv | length) > 0 then [
      { type: "required_status_checks", parameters: {
          strict_required_status_checks_policy: false,
          do_not_enforce_on_create: false,
          required_status_checks: ($checks | csv | map({ context: . }))
      } }
    ] else [] end))
  }')

# Look up an existing ruleset with this name. A failure here (403, 404, no
# auth) must not look like "no ruleset", or we'd create a duplicate.
if ! list=$(gh api "repos/$repo/rulesets" --paginate); then
  echo "error: couldn't list rulesets on $repo (needs admin access and an authenticated gh)" >&2
  exit 1
fi
id=$(jq -r --arg n "$name" '[.[] | select(.name == $n) | .id][0] // empty' <<< "$list")

if [[ -n $id ]]; then
  if ! existing=$(gh api "repos/$repo/rulesets/$id"); then
    echo "error: couldn't read ruleset $id on $repo" >&2
    exit 1
  fi
else
  existing='null'
fi

body=$(jq -n --argjson want "$desired" --argjson have "$existing" --argjson bypass "$bypass" '
  def admin: { actor_id: 5, actor_type: "RepositoryRole", bypass_mode: "pull_request" };
  def is_admin: .actor_type == "RepositoryRole" and .actor_id == 5;
  def bypass_from($cur):
    ($cur | map(select(is_admin | not))) + (if $bypass == 1 then [admin] else [] end);
  # Keep integration_id (and any other fields) for checks that already exist.
  def merge_checks($old):
    map(.context as $c
        | (($old // []) | map(select(.context == $c)) | .[0] // {}) * .);

  if $have == null then
    $want + { bypass_actors: bypass_from([]) }
  else
    ($have.rules // []) as $old_rules
    | ($want.rules | map(.type)) as $managed
    | {
        name: $want.name,
        target: ($have.target // $want.target),
        enforcement: $want.enforcement,
        conditions: ($have.conditions // $want.conditions),
        bypass_actors: bypass_from($have.bypass_actors // []),
        rules: (
          ($want.rules | map(
            . as $new
            | ($old_rules | map(select(.type == $new.type)) | .[0]) as $old
            | if $old == null then $new
              elif $new.type == "required_status_checks" then
                ($old * $new)
                | .parameters.required_status_checks =
                    ($new.parameters.required_status_checks
                     | merge_checks($old.parameters.required_status_checks))
              else $old * $new end))
          + ($old_rules | map(select(.type as $t | $managed | index($t) | not)))
        )
      }
  end')

if (( dry )); then
  if [[ -n $id ]]; then
    echo "dry run: would update ruleset '$name' ($id) on $repo" >&2
  else
    echo "dry run: would create ruleset '$name' on $repo" >&2
  fi
  echo "$body"
  exit 0
fi

if [[ -n $id ]]; then
  if ! echo "$body" | gh api -X PUT "repos/$repo/rulesets/$id" --input - >/dev/null; then
    echo "error: couldn't update ruleset $id on $repo" >&2
    exit 1
  fi
  echo "updated ruleset '$name' ($id) on $repo"
else
  if ! id=$(echo "$body" | gh api -X POST "repos/$repo/rulesets" --input - --jq .id); then
    echo "error: couldn't create ruleset on $repo (needs admin; private repos need a paid plan)" >&2
    exit 1
  fi
  echo "created ruleset '$name' ($id) on $repo"
fi
gh api "repos/$repo/rulesets/$id" --jq '{name, enforcement, current_user_can_bypass, rules: [.rules[].type]}'
