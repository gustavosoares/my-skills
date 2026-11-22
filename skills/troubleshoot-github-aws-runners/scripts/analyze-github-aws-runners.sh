#!/usr/bin/env bash
#
# Read-only health report for self-hosted GitHub Actions runners deployed with
# terraform-aws-github-runner (https://github.com/github-aws-runners/terraform-aws-github-runner).
# Discovers runner fleets from the module's Lambda/SQS naming, then reports EC2,
# SQS build queues + DLQs, fleet caps, Lambda health and (optionally) GitHub
# queued jobs vs idle runners.
#
# Usage: analyze-github-aws-runners.sh --prefix PREFIX --region REGION [options]
#
# Required:
#   --prefix PREFIX          The module's `prefix` variable (e.g. gha-prod). Fleets are
#                            discovered as Lambdas named PREFIX[-KEY]-scale-up.
#   --region REGION          AWS region of the runners (default: $AWS_REGION if set)
#
# Options:
#   --profile PROFILE        AWS profile (default: ambient credentials / $AWS_PROFILE)
#   --use-granted            Wrap AWS calls in Granted: `assume PROFILE --exec --`
#   --fleet KEY              Only analyze this fleet key (repeatable). Use "default" for
#                            a single-runner deployment (PREFIX-scale-up).
#   --hours N                CloudWatch lookback in hours (default: 1)
#   --github-repo OWNER/REPO Also scan this repo's queued jobs vs idle runners (needs gh)
#   --github-org ORG         Org whose runners to list (default: owner of --github-repo)
#   --github-run-limit N     Max queued + in_progress runs to inspect per status (default: 50)
#   --label-regex REGEX      Only count queued jobs with a label matching REGEX (default: any)
#   -h, --help               Show this help
#
# Read-only AWS permissions used: lambda:ListFunctions, lambda:GetFunctionConcurrency,
# sqs:ListQueues, sqs:GetQueueAttributes, ec2:DescribeInstances,
# cloudwatch:GetMetricStatistics.
#
# Exit codes: 0 ok, 1 missing dependency, 2 no runner resources found for prefix,
#             3 some AWS calls were denied (an ACCESS DENIED section is printed), 64 usage.
#
# Requires: aws, jq. Optional: gh (authenticated), Granted (`assume`).
#
set -euo pipefail

PREFIX=""
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
PROFILE=""
USE_GRANTED=0
FLEET_FILTER=""
HOURS=1
GITHUB_REPO=""
GITHUB_ORG=""
GITHUB_RUN_LIMIT=50
LABEL_REGEX="."

MODULE_URL="https://github.com/github-aws-runners/terraform-aws-github-runner"

usage() {
  sed -n '2,36p' "$0" | sed 's/^# \{0,1\}//'
  exit 64
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix) PREFIX="${2:?}"; shift 2 ;;
    --region) REGION="${2:?}"; shift 2 ;;
    --profile) PROFILE="${2:?}"; shift 2 ;;
    --use-granted) USE_GRANTED=1; shift ;;
    --fleet) FLEET_FILTER="${FLEET_FILTER} ${2:?} "; shift 2 ;;
    --hours) HOURS="${2:?}"; shift 2 ;;
    --github-repo) GITHUB_REPO="${2:?}"; shift 2 ;;
    --github-org) GITHUB_ORG="${2:?}"; shift 2 ;;
    --github-run-limit) GITHUB_RUN_LIMIT="${2:?}"; shift 2 ;;
    --label-regex) LABEL_REGEX="${2:?}"; shift 2 ;;
    -h | --help) usage ;;
    *) echo "Unknown option: $1" >&2; usage ;;
  esac
done

[[ -n "${PREFIX}" ]] || { echo "ERROR: --prefix is required (the module's prefix variable)" >&2; usage; }
[[ -n "${REGION}" ]] || { echo "ERROR: --region is required (or set AWS_REGION)" >&2; usage; }
[[ "${HOURS}" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: --hours must be a positive integer" >&2; exit 64; }
if [[ -n "${GITHUB_REPO}" && -z "${GITHUB_ORG}" ]]; then
  GITHUB_ORG="${GITHUB_REPO%%/*}"
fi

command -v aws >/dev/null || { echo "ERROR: aws CLI required" >&2; exit 1; }
command -v jq >/dev/null || { echo "ERROR: jq required" >&2; exit 1; }
if [[ "${USE_GRANTED}" -eq 1 ]]; then
  [[ -n "${PROFILE}" ]] || { echo "ERROR: --use-granted needs --profile" >&2; exit 64; }
  command -v assume >/dev/null || { echo "ERROR: 'assume' (Granted) not found on PATH" >&2; exit 1; }
  # Scripts run under bash without the interactive shell `assume` alias.
  export FORCE_NO_ALIAS=true
  export GRANTED_DISABLE_USAGE_TIPS="${GRANTED_DISABLE_USAGE_TIPS:-true}"
elif [[ -n "${PROFILE}" ]]; then
  export AWS_PROFILE="${PROFILE}"
fi

# Permission/credential failures are recorded here and reported on exit. Most callers
# substitute a placeholder (0, "unset", "not found") on failure, so without this a missing
# permission would look like a real diagnosis.
AUTH_ERRORS_LOG=$(mktemp)
AUTH_ERROR_PATTERN='AccessDenied|UnauthorizedOperation|not authorized|ExpiredToken|InvalidClientTokenId|UnrecognizedClientException|Unable to locate credentials|Token has expired'

aws_cmd() {
  local err rc=0
  err=$(mktemp)
  if [[ "${USE_GRANTED}" -eq 1 ]]; then
    assume "${PROFILE}" --exec -- aws --region "${REGION}" "$@" 2>"${err}" || rc=$?
  else
    aws --region "${REGION}" "$@" 2>"${err}" || rc=$?
  fi
  if grep -qE "${AUTH_ERROR_PATTERN}" "${err}"; then
    echo "aws $1 $2: $(grep -m1 -E "${AUTH_ERROR_PATTERN}" "${err}")" >>"${AUTH_ERRORS_LOG}"
  fi
  cat "${err}" >&2
  rm -f "${err}"
  return "${rc}"
}

cleanup() {
  local rc=$?
  if [[ -s "${AUTH_ERRORS_LOG}" ]]; then
    echo
    echo "=== *** ACCESS DENIED / CREDENTIAL ERRORS (profile: ${PROFILE:-ambient}) *** ==="
    sort -u "${AUTH_ERRORS_LOG}" | sed 's/^/  /'
    echo "  Results above that depend on these calls (0, unset, not found) are NOT real signals."
    echo "  Re-run with credentials that have the read-only permissions listed in --help."
    rc=3
  fi
  rm -f "${AUTH_ERRORS_LOG}"
  exit "${rc}"
}
trap cleanup EXIT

section() {
  echo
  echo "=== $1 ==="
}

is_nonneg_int() {
  [[ "${1:-}" =~ ^[0-9]+$ ]]
}

cw_metric_or_zero() {
  local val=${1:-0}
  case "${val}" in
    None | null | "" | N/A) echo 0 ;;
    *) awk -v v="${val}" 'BEGIN { if (v + 0 > 0) print int(v + 0.5); else print 0 }' ;;
  esac
}

fleet_selected() {
  [[ -z "${FLEET_FILTER}" || "${FLEET_FILTER}" == *" $1 "* ]]
}

END_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ)
START_TIME=$(date -u -v-"${HOURS}"H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "${HOURS} hours ago" +%Y-%m-%dT%H:%M:%SZ)
PERIOD=$((HOURS * 3600))

echo "GitHub AWS runners analysis (terraform-aws-github-runner)"
echo "  prefix:  ${PREFIX}"
echo "  region:  ${REGION}"
echo "  profile: ${PROFILE:-ambient}$([[ "${USE_GRANTED}" -eq 1 ]] && echo " (via Granted)")"
echo "  window:  last ${HOURS}h (${START_TIME} → ${END_TIME})"

# ---------------------------------------------------------------------------
# Discovery: fleets = Lambdas named PREFIX[-KEY]-scale-up
# ---------------------------------------------------------------------------
section "Discovered fleets"
FUNCTIONS_JSON=$(aws_cmd lambda list-functions \
  --query 'Functions[].{Name:FunctionName,Env:Environment.Variables}' \
  --output json 2>/dev/null || echo "[]")
FUNCTIONS_JSON=$(echo "${FUNCTIONS_JSON}" | jq -c --arg p "${PREFIX}" \
  '[.[] | select(.Name == ($p + "-webhook") or (.Name | startswith($p + "-")))]')

F_KEY=()
F_ENV=()
F_MAX=()
F_MINRUN=()
F_CONC=()
while IFS=$'\t' read -r fn env_name max; do
  [[ -z "${fn}" ]] && continue
  key="${fn#"${PREFIX}"}"
  key="${key%-scale-up}"
  key="${key#-}"
  [[ -z "${key}" ]] && key="default"
  fleet_selected "${key}" || continue
  fleet_env="${env_name:-${fn%-scale-up}}"
  minrun=$(echo "${FUNCTIONS_JSON}" | jq -r --arg n "${fleet_env}-scale-down" \
    '.[] | select(.Name == $n) | .Env.MINIMUM_RUNNING_TIME_IN_MINUTES // empty')
  conc=$(aws_cmd lambda get-function-concurrency --function-name "${fn}" \
    --query 'ReservedConcurrentExecutions' --output text 2>/dev/null || echo "")
  case "${conc}" in None | null | "") conc="unset" ;; esac
  F_KEY+=("${key}")
  F_ENV+=("${fleet_env}")
  F_MAX+=("${max:-unknown}")
  F_MINRUN+=("${minrun:-unknown}")
  F_CONC+=("${conc}")
done < <(echo "${FUNCTIONS_JSON}" | jq -r '
  .[] | select(.Name | endswith("-scale-up"))
  | [.Name, (.Env.ENVIRONMENT // ""), (.Env.RUNNERS_MAXIMUM_COUNT // "")] | @tsv')

N=${#F_KEY[@]}
if [[ "${N}" -eq 0 ]]; then
  echo "  (none)"
  echo "ERROR: no terraform-aws-github-runner resources found for prefix '${PREFIX}' in region ${REGION}" >&2
  echo "       (expected Lambdas named ${PREFIX}-scale-up or ${PREFIX}-<key>-scale-up${FLEET_FILTER:+ for fleets:${FLEET_FILTER}})." >&2
  echo "       Check --prefix/--region, or see ${MODULE_URL}" >&2
  exit 2
fi

printf "  %-28s %-36s %8s %12s %14s\n" "fleet" "environment" "max" "min_run_min" "scale_up_conc"
for ((i = 0; i < N; i++)); do
  max_disp="${F_MAX[$i]}"
  if [[ "${max_disp}" == "-1" ]]; then max_disp="unlimited"; fi
  printf "  %-28s %-36s %8s %12s %14s\n" "${F_KEY[$i]}" "${F_ENV[$i]}" "${max_disp}" "${F_MINRUN[$i]}" "${F_CONC[$i]}"
done
echo "  (max = scale-up RUNNERS_MAXIMUM_COUNT; min_run_min = scale-down MINIMUM_RUNNING_TIME_IN_MINUTES)"

# ---------------------------------------------------------------------------
# EC2
# ---------------------------------------------------------------------------
section "EC2 runners (running + pending)"
# shellcheck disable=SC2016 # backticks are JMESPath literals, not shell
INSTANCES_JSON=$(aws_cmd ec2 describe-instances \
  --filters \
  "Name=tag:ghr:Application,Values=github-action-runner" \
  "Name=instance-state-name,Values=running,pending" \
  --query 'Reservations[].Instances[].{Id:InstanceId,State:State.Name,Env:Tags[?Key==`ghr:environment`]|[0].Value,CreatedBy:Tags[?Key==`ghr:created_by`]|[0].Value,Type:InstanceType,Lifecycle:InstanceLifecycle}' \
  --output json 2>/dev/null || echo "[]")
INSTANCES_JSON=$(echo "${INSTANCES_JSON}" | jq -c --arg p "${PREFIX}" \
  '[.[] | select((.Env // "") | startswith($p))]')

TOTAL_EC2=$(echo "${INSTANCES_JSON}" | jq 'length')
echo "Total running/pending under prefix ${PREFIX}: ${TOTAL_EC2}"
if [[ "${TOTAL_EC2}" -gt 0 ]]; then
  echo "${INSTANCES_JSON}" | jq -r '
    group_by(.Env // "unknown")[]
    | "  \(.[0].Env // "unknown"): \(length) (\([.[].State] | group_by(.) | map("\(.[0])=\(length)") | join(", ")); \([.[] | (.Lifecycle // "on-demand")] | group_by(.) | map("\(.[0])=\(length)") | join(", ")))"
  '
  echo "${INSTANCES_JSON}" | jq -r '
    group_by(.CreatedBy // "unknown")[]
    | "  by created_by — \(.[0].CreatedBy // "unknown"): \(length)"
  '
fi

F_EC2=()
for ((i = 0; i < N; i++)); do
  F_EC2[i]=$(echo "${INSTANCES_JSON}" | jq --arg e "${F_ENV[$i]}" '[.[] | select(.Env == $e)] | length')
done

# ---------------------------------------------------------------------------
# SQS
# ---------------------------------------------------------------------------
section "SQS build queues and DLQs"
QUEUE_URLS=$(aws_cmd sqs list-queues --queue-name-prefix "${PREFIX}" \
  --query 'QueueUrls' --output json 2>/dev/null || echo "[]")
if [[ "${QUEUE_URLS}" == "null" ]]; then QUEUE_URLS="[]"; fi

sqs_attrs() {
  aws_cmd sqs get-queue-attributes --queue-url "$1" --attribute-names All --output json 2>/dev/null
}

F_VIS=()
F_DLQ=()
F_QISSUE=()
for ((i = 0; i < N; i++)); do
  env="${F_ENV[$i]}"
  F_VIS[i]=0
  F_DLQ[i]=0
  F_QISSUE[i]=0
  echo "Fleet: ${F_KEY[$i]}"

  build_url=$(echo "${QUEUE_URLS}" | jq -r --arg n "${env}-queued-builds" \
    '[.[] | select((split("/") | last) as $q | $q == $n or $q == ($n + ".fifo"))] | first // empty')
  if [[ -z "${build_url}" ]]; then
    echo "  build: ${env}-queued-builds — NOT FOUND"
    F_QISSUE[i]=1
  elif ! attrs=$(sqs_attrs "${build_url}"); then
    echo "  build: ${build_url##*/} — failed to read queue attributes"
    F_QISSUE[i]=1
  else
    visible=$(echo "${attrs}" | jq -r '.Attributes.ApproximateNumberOfMessages // "0"')
    inflight=$(echo "${attrs}" | jq -r '.Attributes.ApproximateNumberOfMessagesNotVisible // "0"')
    age=$(echo "${attrs}" | jq -r '.Attributes.ApproximateAgeOfOldestMessage // "n/a"')
    echo "  build: ${build_url##*/}"
    echo "    visible=${visible}  in_flight=${inflight}  oldest_age_sec=${age}"
    F_VIS[i]="${visible}"
    if is_nonneg_int "${visible}" && [[ "${visible}" -gt 0 ]]; then
      F_QISSUE[i]=1
    elif is_nonneg_int "${age}" && [[ "${age}" -gt 300 ]]; then
      F_QISSUE[i]=1
    fi
  fi

  dlq_url=$(echo "${QUEUE_URLS}" | jq -r --arg n "${env}-queued-builds" \
    '[.[] | select((split("/") | last) as $q | ($q | startswith($n)) and ($q | test("dead|dlq"; "i")))] | first // empty')
  if [[ -z "${dlq_url}" ]]; then
    echo "  dlq:   (none found — redrive_build_queue may be disabled)"
  elif ! dlq_attrs=$(sqs_attrs "${dlq_url}"); then
    echo "  dlq:   ${dlq_url##*/} — failed to read queue attributes"
    F_QISSUE[i]=1
  else
    dlq_visible=$(echo "${dlq_attrs}" | jq -r '.Attributes.ApproximateNumberOfMessages // "0"')
    dlq_age=$(echo "${dlq_attrs}" | jq -r '.Attributes.ApproximateAgeOfOldestMessage // "n/a"')
    echo "  dlq:   ${dlq_url##*/}"
    echo "    visible=${dlq_visible}  oldest_age_sec=${dlq_age}"
    if is_nonneg_int "${dlq_visible}" && [[ "${dlq_visible}" -gt 0 ]]; then
      echo "    *** ALERT: DLQ has messages — scale-up failed repeatedly for these jobs ***"
      F_DLQ[i]="${dlq_visible}"
      F_QISSUE[i]=1
    fi
  fi
  echo
done

# ---------------------------------------------------------------------------
# Capacity vs cap
# ---------------------------------------------------------------------------
section "Fleet capacity vs runners_maximum_count"
F_ATCAP=()
for ((i = 0; i < N; i++)); do
  F_ATCAP[i]=0
  max="${F_MAX[$i]}"
  note=""
  if is_nonneg_int "${max}"; then
    if [[ "${F_EC2[$i]}" -ge "${max}" ]]; then
      note=" *** AT OR OVER CAP ***"
      F_ATCAP[i]=1
    fi
  elif [[ "${max}" == "-1" ]]; then
    max="unlimited"
  fi
  echo "  ${F_KEY[$i]}: EC2=${F_EC2[$i]} / max=${max}${note}"
  if [[ "${F_ATCAP[$i]}" -eq 1 ]] && is_nonneg_int "${F_VIS[$i]}" && [[ "${F_VIS[$i]}" -gt 0 ]]; then
    echo "    build queue visible=${F_VIS[$i]} — scale-up cannot launch more; jobs wait for runners to finish or scale-down (min_run ${F_MINRUN[$i]}m)"
  fi
done
echo "  (EC2 count is a snapshot; confirm with scale-up logs: filter \"maximumRunners\" → currentRunners vs maximumRunners)"

# ---------------------------------------------------------------------------
# Lambda health
# ---------------------------------------------------------------------------
section "Lambda health (last ${HOURS}h)"
LAMBDA_ERROR_FNS=""

lambda_report() {
  local fn=$1 inv errors
  inv=$(aws_cmd cloudwatch get-metric-statistics --namespace AWS/Lambda --metric-name Invocations \
    --dimensions "Name=FunctionName,Value=${fn}" --start-time "${START_TIME}" --end-time "${END_TIME}" \
    --period "${PERIOD}" --statistics Sum --query 'sum(Datapoints[].Sum)' --output text 2>/dev/null || echo "None")
  errors=$(aws_cmd cloudwatch get-metric-statistics --namespace AWS/Lambda --metric-name Errors \
    --dimensions "Name=FunctionName,Value=${fn}" --start-time "${START_TIME}" --end-time "${END_TIME}" \
    --period "${PERIOD}" --statistics Sum --query 'sum(Datapoints[].Sum)' --output text 2>/dev/null || echo "None")
  inv=$(cw_metric_or_zero "${inv}")
  errors=$(cw_metric_or_zero "${errors}")
  printf "  %-55s inv=%-6s err=%s\n" "${fn}" "${inv}" "${errors}"
  if [[ "${errors}" != "0" ]]; then
    LAMBDA_ERROR_FNS="${LAMBDA_ERROR_FNS} ${fn}"
  fi
}

# Shared functions (webhook, dispatcher) plus per-fleet scale-up/scale-down/pool, if they exist.
while IFS= read -r fn; do
  [[ -n "${fn}" ]] && lambda_report "${fn}"
done < <(echo "${FUNCTIONS_JSON}" | jq -r --arg p "${PREFIX}" \
  '.[] | .Name | select(. == ($p + "-webhook") or . == ($p + "-dispatch-to-runner"))')
for ((i = 0; i < N; i++)); do
  for suffix in scale-up scale-down pool; do
    fn="${F_ENV[$i]}-${suffix}"
    if echo "${FUNCTIONS_JSON}" | jq -e --arg n "${fn}" 'any(.[]; .Name == $n)' >/dev/null; then
      lambda_report "${fn}"
    fi
  done
done

# ---------------------------------------------------------------------------
# GitHub queued jobs vs idle runners (optional)
# ---------------------------------------------------------------------------
GH_STATUS="skipped"   # skipped | failed | partial | ok
GH_QUEUED_COUNT=0
GH_CAPACITY_KNOWN=0
GH_DEFICIT_TOTAL=0

github_section() {
  section "GitHub queued jobs (${GITHUB_REPO:-not set})"
  if [[ -z "${GITHUB_REPO}" ]]; then
    echo "  (skipped — pass --github-repo OWNER/REPO to compare queued jobs with idle runners)"
    return 0
  fi
  if ! command -v gh >/dev/null 2>&1; then
    echo "  (skipped — gh CLI not found)"
    return 0
  fi
  if ! gh auth status >/dev/null 2>&1; then
    echo "  (skipped — gh not authenticated; run: gh auth login)"
    return 0
  fi

  local queued_runs in_progress_runs run_ids run_id jobs_json all_jobs="[]" scanned=0 failed=0
  GH_STATUS="ok"
  if ! queued_runs=$(gh run list -R "${GITHUB_REPO}" --status queued --limit "${GITHUB_RUN_LIMIT}" --json databaseId 2>/dev/null); then
    echo "  (failed — could not list queued runs for ${GITHUB_REPO})"
    GH_STATUS="failed"
    return 0
  fi
  if ! in_progress_runs=$(gh run list -R "${GITHUB_REPO}" --status in_progress --limit "${GITHUB_RUN_LIMIT}" --json databaseId 2>/dev/null); then
    echo "  (warning — could not list in_progress runs; using queued runs only)"
    in_progress_runs="[]"
    GH_STATUS="partial"
  fi
  run_ids=$(jq -n -r --argjson q "${queued_runs}" --argjson p "${in_progress_runs}" \
    '[$q[], $p[]] | map(.databaseId) | unique | .[]')

  while IFS= read -r run_id; do
    [[ -z "${run_id}" ]] && continue
    scanned=$((scanned + 1))
    if ! jobs_json=$(gh api "repos/${GITHUB_REPO}/actions/runs/${run_id}/jobs" --paginate 2>/dev/null); then
      failed=$((failed + 1))
      continue
    fi
    # Queued jobs that target self-hosted runners and match --label-regex.
    all_jobs=$(echo "${jobs_json}" | jq -c -s --argjson acc "${all_jobs}" --argjson run "${run_id}" --arg re "${LABEL_REGEX}" '
      $acc + (
        [.[].jobs[]?]
        | map(select(.status == "queued"))
        | map(.labels = ([.labels[]? | ascii_downcase] | unique))
        | map(select(
            (.labels | index("self-hosted"))
            or (.labels | length > 0 and any(.[]; test("^(ubuntu|windows|macos)-") | not))
          ))
        | map(select(any(.labels[]; test($re))))
        | map({
            run_id: $run, job_id: .id, name: .name, labels: .labels,
            queued_sec: (now - (.created_at | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) | floor)
          })
      )')
  done <<<"${run_ids}"

  if [[ "${scanned}" -gt 0 && "${failed}" -eq "${scanned}" ]]; then
    echo "  (failed — could not fetch jobs for any of ${scanned} run(s))"
    GH_STATUS="failed"
    return 0
  elif [[ "${failed}" -gt 0 ]]; then
    echo "  (warning — failed to fetch jobs for ${failed}/${scanned} run(s); counts may be understated)"
    GH_STATUS="partial"
  fi

  all_jobs=$(echo "${all_jobs}" | jq -c 'sort_by(-.queued_sec)')
  GH_QUEUED_COUNT=$(echo "${all_jobs}" | jq 'length')
  if [[ "${GH_QUEUED_COUNT}" -eq 0 ]]; then
    echo "  (none — no queued self-hosted jobs in scanned runs)"
  else
    echo "  Total queued self-hosted jobs: ${GH_QUEUED_COUNT}"
    printf "  %-12s %-12s %-10s %-40s %s\n" "run_id" "job_id" "queued_sec" "labels" "job_name"
    echo "${all_jobs}" | jq -r '.[:25][] | [(.run_id|tostring), (.job_id|tostring), (.queued_sec|tostring), (.labels|join(",")), .name] | @tsv' |
      while IFS=$'\t' read -r r j q l n; do
        printf "  %-12s %-12s %-10s %-40s %s\n" "${r}" "${j}" "${q}" "${l}" "${n}"
      done
    if [[ "${GH_QUEUED_COUNT}" -gt 25 ]]; then echo "  (showing 25 of ${GH_QUEUED_COUNT})"; fi
  fi

  # Idle/busy online runners: org-level first, then repo-level.
  local raw runners scope="org ${GITHUB_ORG}"
  if ! raw=$(gh api "orgs/${GITHUB_ORG}/actions/runners" --paginate 2>/dev/null); then
    scope="repo ${GITHUB_REPO}"
    if ! raw=$(gh api "repos/${GITHUB_REPO}/actions/runners" --paginate 2>/dev/null); then
      echo
      echo "  (warning — could not list runners for org ${GITHUB_ORG} or repo ${GITHUB_REPO}; needs admin on runners)"
      return 0
    fi
  fi
  runners=$(echo "${raw}" | jq -c -s '[.[].runners[]? | select(.status == "online")
    | {name, busy: (.busy // false), labels: [.labels[]?.name | ascii_downcase]}]')
  GH_CAPACITY_KNOWN=1

  # A job needs a runner that has ALL its labels. Group queued jobs by label set.
  local capacity
  capacity=$(jq -n -c --argjson jobs "${all_jobs}" --argjson runners "${runners}" '
    $jobs | group_by(.labels) | map(.[0].labels as $set | {
      labels: ($set | join(",")),
      queued: length,
      idle: ([$runners[] | select(.busy | not) | select(.labels as $rl | all($set[]; . as $l | any($rl[]; . == $l)))] | length),
      busy: ([$runners[] | select(.busy) | select(.labels as $rl | all($set[]; . as $l | any($rl[]; . == $l)))] | length)
    } | .deficit = ([.queued - .idle, 0] | max))')
  GH_DEFICIT_TOTAL=$(echo "${capacity}" | jq '[.[].deficit] | add // 0')

  echo
  echo "  Runner capacity (online runners, ${scope}): $(echo "${runners}" | jq 'length') online, $(echo "${runners}" | jq '[.[] | select(.busy | not)] | length') idle"
  if [[ "${GH_QUEUED_COUNT}" -gt 0 ]]; then
    printf "  %-40s %6s %5s %5s %7s\n" "job labels" "queued" "idle" "busy" "deficit"
    echo "${capacity}" | jq -r '.[] | [.labels, (.queued|tostring), (.idle|tostring), (.busy|tostring), (.deficit|tostring)] | @tsv' |
      while IFS=$'\t' read -r l q i b d; do
        note=""
        if [[ "${d}" -gt 0 ]]; then note="  *** DEFICIT ***"; fi
        if [[ "${b}" -eq 0 && "${i}" -eq 0 ]]; then note="${note}  (no online runner has all these labels — check routing/labels)"; fi
        printf "  %-40s %6s %5s %5s %7s%s\n" "${l}" "${q}" "${i}" "${b}" "${d}" "${note}"
      done
  fi
}
github_section

# ---------------------------------------------------------------------------
# Recommendations
# ---------------------------------------------------------------------------
section "Recommendations"
ANY_ISSUE=0
ANY_BACKLOG=0
for ((i = 0; i < N; i++)); do
  k="${F_KEY[$i]}"
  e="${F_ENV[$i]}"
  if [[ "${F_QISSUE[$i]}" -eq 1 ]]; then ANY_BACKLOG=1; fi
  if [[ "${F_ATCAP[$i]}" -eq 1 ]]; then
    ANY_ISSUE=1
    echo "  - [${k}] At/over runners_maximum_count (${F_MAX[$i]}): scale-up will not launch more runners."
    if [[ "${F_QISSUE[$i]}" -eq 1 ]]; then
      echo "    Backlog + cap = the typical cause of long Queued waits (routing OK, no capacity)."
    fi
    echo "    Wait for jobs/scale-down, raise runners_maximum_count, or reduce parallel jobs on this fleet."
  elif [[ "${F_QISSUE[$i]}" -eq 1 && "${F_DLQ[$i]}" -eq 0 ]]; then
    ANY_ISSUE=1
    echo "  - [${k}] Build queue backlog without hitting the cap: check /aws/lambda/${e}-scale-up for ERROR,"
    echo "    jitconfig or throttling (reserved concurrency ${F_CONC[$i]}), and EC2 capacity/spot errors."
  fi
  if [[ "${F_DLQ[$i]}" -gt 0 ]]; then
    ANY_ISSUE=1
    echo "  - [${k}] DLQ has ${F_DLQ[$i]} message(s): scale-up failed repeatedly. Fix the cause in"
    echo "    /aws/lambda/${e}-scale-up (IAM/KMS/SSM/launch template), then redrive the DLQ."
  fi
done
if [[ -n "${LAMBDA_ERROR_FNS}" ]]; then
  ANY_ISSUE=1
  echo "  - Lambda errors in window:${LAMBDA_ERROR_FNS} — inspect their CloudWatch log groups (/aws/lambda/<name>)."
fi
case "${GH_STATUS}" in
  failed) ANY_ISSUE=1; echo "  - GitHub scan failed; AWS-only signals do not prove there are no queued jobs." ;;
  partial) echo "  - GitHub scan was partial; queued counts may be understated." ;;
esac
if [[ "${GH_QUEUED_COUNT}" -gt 0 ]]; then
  ANY_ISSUE=1
  if [[ "${GH_CAPACITY_KNOWN}" -eq 0 ]]; then
    echo "  - ${GH_QUEUED_COUNT} queued job(s) but idle capacity unknown (runner list failed) — don't assume they'll be picked up."
  elif [[ "${GH_DEFICIT_TOTAL}" -gt 0 && "${ANY_BACKLOG}" -eq 0 && "${TOTAL_EC2}" -gt 0 ]]; then
    echo "  - Deficit of ${GH_DEFICIT_TOTAL} idle runner(s) with SQS clear and EC2 running — instances are likely"
    echo "    still booting/registering (cold start ~2–4 min). If it persists, check scale-up logs for jitconfig errors."
  elif [[ "${GH_DEFICIT_TOTAL}" -gt 0 && "${ANY_BACKLOG}" -eq 0 && "${TOTAL_EC2}" -eq 0 ]]; then
    echo "  - Queued jobs, no SQS backlog and no runner EC2 — the webhook probably never dispatched them."
    echo "    Check /aws/lambda/${PREFIX}-webhook for the job ID (label matcher / exactMatch mismatch, or GitHub App delivery failure)."
  elif [[ "${GH_DEFICIT_TOTAL}" -gt 0 ]]; then
    echo "  - Deficit of ${GH_DEFICIT_TOTAL} idle runner(s); see per-fleet notes above for the AWS side."
  else
    echo "  - Queued jobs are covered by idle runners — they should start shortly; if stuck >5 min, check labels/routing."
  fi
fi
if [[ "${ANY_ISSUE}" -eq 0 && "${ANY_BACKLOG}" -eq 0 ]]; then
  if [[ "${TOTAL_EC2}" -eq 0 ]]; then
    echo "  - No runners and no queue pressure — likely idle (off-hours or no pending jobs)."
  else
    echo "  - Fleets look healthy for current load."
  fi
  if [[ "${GH_STATUS}" == "skipped" ]]; then echo "    (GitHub side not checked — pass --github-repo for queued-vs-idle.)"; fi
fi

echo
echo "Log groups: /aws/lambda/${PREFIX}-webhook, /aws/lambda/<fleet environment>-scale-up"
echo "Module docs: ${MODULE_URL}"
