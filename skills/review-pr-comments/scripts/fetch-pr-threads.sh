#!/usr/bin/env bash
#
# Read-only: fetch the review threads, review summaries and conversation
# comments on a GitHub pull request, as one JSON document on stdout.
#
# Usage: fetch-pr-threads.sh [--pr NUMBER] [--repo OWNER/REPO] [--all]
#
# Options:
#   --pr NUMBER        PR number (default: the PR for the current branch)
#   --repo OWNER/REPO  Repository (default: the repo of the current directory)
#   --all              Include resolved threads (default: unresolved only)
#   -h, --help         Show this help
#
# Output (JSON):
#   { repo, pr, url, title, state, headRefName, headRefOid,
#     threads:  [ { id, isResolved, isOutdated, path, line, startLine,
#                   comments: [ { id, databaseId, author, body, createdAt, url } ] } ],
#     reviews:  [ { author, state, body, submittedAt } ]   (only ones with a body)
#     comments: [ { author, body, createdAt, url } ] }     (PR conversation)
#   Thread `id` is the GraphQL node id (for resolveReviewThread); comment
#   `databaseId` is the REST id (for POST .../pulls/comments/{id}/replies).
#
# Requires: gh (authenticated), jq.
# Permissions used: read access to the repository's pull requests
#   (GraphQL pullRequest.reviewThreads, REST via `gh pr view`).
#
# Exit codes: 0 ok, 1 gh/API error (auth, permission, network),
#             2 missing dependency, 64 usage error or no PR found.
#
set -euo pipefail

usage() {
  sed -n '3,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
}

PR=""
REPO=""
ALL=0

while [ $# -gt 0 ]; do
  case "$1" in
    --pr)
      if [ $# -lt 2 ]; then echo "error: --pr needs a value" >&2; exit 64; fi
      PR="$2"; shift 2 ;;
    --repo)
      if [ $# -lt 2 ]; then echo "error: --repo needs a value" >&2; exit 64; fi
      REPO="$2"; shift 2 ;;
    --all) ALL=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1 (see --help)" >&2; exit 64 ;;
  esac
done

for tool in gh jq; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "error: '$tool' is required but not installed" >&2
    exit 2
  fi
done

if [ -n "$PR" ]; then
  case "$PR" in
    ''|*[!0-9]*) echo "error: --pr must be a number, got '$PR'" >&2; exit 64 ;;
  esac
fi
if [ -n "$REPO" ]; then
  case "$REPO" in
    */*) ;;
    *) echo "error: --repo must look like OWNER/REPO, got '$REPO'" >&2; exit 64 ;;
  esac
fi

ERR_FILE="$(mktemp "${TMPDIR:-/tmp}/fetch-pr-threads.XXXXXX")"
trap 'rm -f "$ERR_FILE"' EXIT

# Explain a failed gh call. Auth and permission errors must not look like
# "no comments".
gh_fail() {
  local what="$1"
  local msg
  msg="$(cat "$ERR_FILE")"
  if printf '%s' "$msg" | grep -qiE 'HTTP 401|bad credentials|not logged|gh auth login|authentication'; then
    echo "error: $what: gh is not authenticated. Run 'gh auth login'." >&2
  elif printf '%s' "$msg" | grep -qiE 'HTTP 403|resource not accessible|permission|forbidden|saml'; then
    echo "error: $what: permission denied (token scope, SSO authorization or repo access)." >&2
  elif printf '%s' "$msg" | grep -qiE 'HTTP 404|could not resolve|not found'; then
    echo "error: $what: not found (check --repo and --pr, or your access to the repo)." >&2
  else
    echo "error: $what failed." >&2
  fi
  if [ -n "$msg" ]; then
    printf '  gh said: %s\n' "$msg" >&2
  fi
  exit 1
}

if [ -z "$REPO" ]; then
  if ! REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>"$ERR_FILE")"; then
    gh_fail "resolving the current repository (pass --repo OWNER/REPO)"
  fi
fi
OWNER="${REPO%%/*}"
NAME="${REPO#*/}"

if [ -z "$PR" ]; then
  if ! PR="$(gh pr view --repo "$REPO" --json number -q .number 2>"$ERR_FILE")"; then
    if grep -qiE 'no pull requests found|no open pull requests' "$ERR_FILE"; then
      echo "error: no pull request found for the current branch (pass --pr NUMBER)" >&2
      exit 64
    fi
    gh_fail "finding the PR for the current branch"
  fi
fi

if ! META="$(gh pr view "$PR" --repo "$REPO" \
    --json number,url,title,state,headRefName,headRefOid,reviews,comments 2>"$ERR_FILE")"; then
  gh_fail "reading PR #$PR"
fi

# shellcheck disable=SC2016  # GraphQL variables, not shell expansions
QUERY='query($owner: String!, $name: String!, $number: Int!, $cursor: String) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      reviewThreads(first: 100, after: $cursor) {
        pageInfo { hasNextPage endCursor }
        nodes {
          id isResolved isOutdated path line startLine
          comments(first: 100) {
            nodes { id databaseId body createdAt url author { login } }
          }
        }
      }
    }
  }
}'

THREADS="[]"
CURSOR=""
while :; do
  if [ -n "$CURSOR" ]; then
    if ! PAGE="$(gh api graphql -f query="$QUERY" -F owner="$OWNER" -F name="$NAME" \
        -F number="$PR" -f cursor="$CURSOR" 2>"$ERR_FILE")"; then
      gh_fail "fetching review threads for PR #$PR"
    fi
  else
    if ! PAGE="$(gh api graphql -f query="$QUERY" -F owner="$OWNER" -F name="$NAME" \
        -F number="$PR" 2>"$ERR_FILE")"; then
      gh_fail "fetching review threads for PR #$PR"
    fi
  fi

  if printf '%s' "$PAGE" | jq -e '.errors' >/dev/null 2>&1; then
    printf '%s' "$PAGE" | jq -r '.errors[].message' >"$ERR_FILE"
    gh_fail "fetching review threads for PR #$PR"
  fi

  THREADS="$(printf '%s\n%s' "$THREADS" "$PAGE" | jq -s \
    '.[0] + (.[1].data.repository.pullRequest.reviewThreads.nodes // [])')"

  if [ "$(printf '%s' "$PAGE" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage')" = "true" ]; then
    CURSOR="$(printf '%s' "$PAGE" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.endCursor')"
  else
    break
  fi
done

printf '%s\n%s' "$META" "$THREADS" | jq -s --arg repo "$REPO" --argjson all "$ALL" '
  .[0] as $m | .[1] as $t |
  {
    repo: $repo,
    pr: $m.number,
    url: $m.url,
    title: $m.title,
    state: $m.state,
    headRefName: $m.headRefName,
    headRefOid: $m.headRefOid,
    threads: [
      $t[] | select($all == 1 or (.isResolved | not)) |
      {
        id, isResolved, isOutdated, path, line, startLine,
        comments: [ .comments.nodes[] | {
          id, databaseId, author: (.author.login // "ghost"), body, createdAt, url
        } ]
      }
    ],
    reviews: [
      ($m.reviews // [])[] | select((.body // "") != "") |
      { author: (.author.login // "ghost"), state, body, submittedAt }
    ],
    comments: [
      ($m.comments // [])[] |
      { author: (.author.login // "ghost"), body, createdAt, url }
    ]
  }'
