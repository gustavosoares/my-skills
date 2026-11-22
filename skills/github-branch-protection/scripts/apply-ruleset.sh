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
#   -d                dry run: print the JSON and exit
set -euo pipefail

repo="" name="protect-main" checks="" methods="squash" approvals=1 bypass=1 dry=0
while getopts "r:n:c:m:a:Bd" o; do
  case $o in
    r) repo=$OPTARG ;; n) name=$OPTARG ;; c) checks=$OPTARG ;; m) methods=$OPTARG ;;
    a) approvals=$OPTARG ;; B) bypass=0 ;; d) dry=1 ;; *) sed -n '2,13p' "$0"; exit 2 ;;
  esac
done
[[ -n $repo ]] || repo=$(gh repo view --json nameWithOwner -q .nameWithOwner)

body=$(jq -n \
  --arg name "$name" --arg checks "$checks" --arg methods "$methods" \
  --argjson approvals "$approvals" --argjson bypass "$bypass" '
  def csv: split(",") | map(select(length > 0));
  {
    name: $name,
    target: "branch",
    enforcement: "active",
    conditions: { ref_name: { include: ["~DEFAULT_BRANCH"], exclude: [] } },
    bypass_actors: (if $bypass == 1
      then [{ actor_id: 5, actor_type: "RepositoryRole", bypass_mode: "pull_request" }]
      else [] end),
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

if (( dry )); then echo "$body"; exit 0; fi

id=$(gh api "repos/$repo/rulesets" --jq ".[] | select(.name == \"$name\") | .id" | head -1)
if [[ -n $id ]]; then
  echo "$body" | gh api -X PUT "repos/$repo/rulesets/$id" --input - >/dev/null
  echo "updated ruleset '$name' ($id) on $repo"
else
  id=$(echo "$body" | gh api -X POST "repos/$repo/rulesets" --input - --jq .id)
  echo "created ruleset '$name' ($id) on $repo"
fi
gh api "repos/$repo/rulesets/$id" --jq '{name, enforcement, current_user_can_bypass, rules: [.rules[].type]}'
