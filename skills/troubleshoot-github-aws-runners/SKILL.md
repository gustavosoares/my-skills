---
name: troubleshoot-github-aws-runners
description: Troubleshoot self-hosted GitHub Actions runners deployed on AWS with the terraform-aws-github-runner module (github-aws-runners/terraform-aws-github-runner, single or multi-runner) when jobs sit in Queued, get cancelled waiting for a runner, or scale-up seems stuck. Asks for the module prefix, region and AWS profile, runs the bundled read-only analyze-github-aws-runners.sh, checks webhook and scale-up CloudWatch logs, and maps symptoms to fleet caps, label routing, DLQ/scale-up failures and JIT registration. Use when the user mentions github-aws-runners, terraform-aws-github-runner, philips-labs runners, self-hosted runner queue waits, runners_maximum_count, or jobs stuck waiting for a self-hosted runner. Not for actions-runner-controller (ARC) or GitHub-hosted runners.
---

# Troubleshooting GitHub AWS runners

Diagnose why GitHub Actions jobs on self-hosted, ephemeral EC2 runners are not
being picked up.

## Prerequisites

This skill only applies to runners deployed with
[**terraform-aws-github-runner**](https://github.com/github-aws-runners/terraform-aws-github-runner)
(formerly `philips-labs/terraform-aws-github-runner`), using either the root
module or `modules/multi-runner`. It relies on the module's naming and tagging:

- Lambdas named `<prefix>-webhook` and `<prefix>[-<key>]-scale-up` / `-scale-down` / `-pool`
- SQS build queues `<prefix>[-<key>]-queued-builds` (plus the DLQ when `redrive_build_queue` is enabled)
- EC2 tags `ghr:Application=github-action-runner`, `ghr:environment`, `ghr:created_by`
- Scale-up env var `RUNNERS_MAXIMUM_COUNT` (from `runners_maximum_count`)

Local tools: `aws` and `jq`. Optional: an authenticated `gh` for the GitHub side, and
[Granted](https://granted.dev) if the user assumes roles with it.

## When to use

- Job stuck in **Queued** or waiting a long time before **Set up job**
- Workflow cancelled after waiting for a runner
- Suspected label routing problem (`runs-on` labels vs runner matchers)
- Fleet at cap, scale-up errors, DLQ messages, orphaned EC2 instances

## When NOT to use

- Runners from other solutions (actions-runner-controller/ARC on Kubernetes, a
  hand-built EC2 runner, GitHub-hosted or larger runners): names and signals won't match
- The job **ran** and failed in a step — that's a CI failure, not a capacity problem
- Changing runner configuration — that's a Terraform change in the user's repo

## Inputs to gather (ask if missing)

| Input | Why |
| ----- | --- |
| **Module `prefix`** and **AWS region** | The script discovers fleets from `<prefix>-*-scale-up` Lambdas |
| **AWS profile** (and whether they use Granted) | Read-only access to the runners account |
| **GitHub job or run URL** | Job ID, labels, queue start/end, runner name |
| **`runs-on` labels** | Must match a fleet's label matcher |
| **Approximate wait duration** | Cold boot (~2–4 min) vs cap/routing (10+ min) |
| **Did other jobs in the same run start?** | Same labels + earlier jobs started = capacity, not routing |
| **Recent Terraform apply to the runners** | Matcher/pool/cap changes may not be live yet (or just went live) |

## Workflow

```
- [ ] 0. Choose AWS profile (ask the user)
- [ ] 1. Locate + run analyze script (always first)
- [ ] 2. Pull GitHub job/run details (gh api)
- [ ] 3. Verify the webhook routed the job to the right fleet queue
- [ ] 4. Inspect scale-up logs for that fleet
- [ ] 5. Classify root cause (decision tree)
- [ ] 6. Report findings + recommended fix
```

### Step 0: Choose AWS profile

**Ask the user which AWS profile to use before running any AWS command** — don't
pick one silently. Read-only access is enough. If they use Granted, pass
`--use-granted` so the script wraps calls in `assume <profile> --exec --`.

If the profile uses SSO, ask the user to log in from their own terminal first
(e.g. `aws sso login --profile <profile>` or `assume <profile>`). A command run
on an expired session can block on a browser prompt nobody sees, so the skill
looks hung.

**Permissions used (all read-only):** `lambda:ListFunctions`,
`lambda:GetFunctionConcurrency`, `sqs:ListQueues`, `sqs:GetQueueAttributes`,
`ec2:DescribeInstances`, `cloudwatch:GetMetricStatistics`, and
`logs:FilterLogEvents` for Steps 3–4. On any denial the script prints an
`ACCESS DENIED / CREDENTIAL ERRORS` section and exits `3`. Tell the user which
call failed, ask before switching to a more privileged profile, and mention the
gap in the final report.

### Step 1: Run the analyze script

The script ships with this skill (`scripts/analyze-github-aws-runners.sh`). Your
working directory is the user's project, not the skill folder, so **resolve an
absolute path first** — use the first that exists:

1. `<skill base directory>/scripts/analyze-github-aws-runners.sh` — the directory reported when this skill loaded
2. Standard install locations:

   ```bash
   for d in ~/.claude/skills ~/.agents/skills ~/.cursor/skills; do
     f="$d/troubleshoot-github-aws-runners/scripts/analyze-github-aws-runners.sh"
     [[ -x "$f" ]] && { echo "$f"; break; }
   done
   ```

3. None found → tell the user the script is missing and suggest reinstalling:
   `npx skills add gustavosoares/my-skills --skill troubleshoot-github-aws-runners`

Then run it:

```bash
"$SCRIPT" --prefix "$PREFIX" --region "$REGION" --profile "$PROFILE" --hours 2 \
  --github-repo OWNER/REPO        # optional: compare queued jobs with idle runners
# add --use-granted for Granted users; --fleet KEY to focus on one fleet
```

Set `--hours` to cover the incident window. Run `--help` for all options.

**Check the exit code first:**

| Exit | Meaning |
| ---- | ------- |
| `0` | Report complete |
| `2` | No module resources for that prefix/region — confirm `prefix` (the module's `prefix` variable) and region |
| `3` | Some AWS calls denied — values from those calls (`0`, `unset`, `NOT FOUND`) are placeholders, not findings. Follow Step 0's denial flow |
| `64` | Bad arguments |

**Read these sections:**

- **Discovered fleets** — each fleet's environment, `max` (`RUNNERS_MAXIMUM_COUNT`; `-1` = unlimited), scale-down minimum running time, and scale-up reserved concurrency
- **EC2 runners** — running/pending per fleet, spot vs on-demand, `pool-lambda` vs `scale-up-lambda`
- **SQS build queues and DLQs** — `visible > 0` or `oldest_age_sec > 300` = backlog; DLQ messages = repeated scale-up failures
- **Fleet capacity** — `*** AT OR OVER CAP ***` plus backlog means jobs wait for runners to finish. Confirm with the scale-up `maximumRunners` log line (Step 4) before reporting a cap issue
- **Lambda health** — invocations/errors per webhook, scale-up, scale-down, pool function
- **GitHub queued jobs** (with `--github-repo`) — queued self-hosted jobs grouped by label set vs **idle** online runners that have all those labels. `*** DEFICIT ***` when queued > idle; "no online runner has all these labels" hints at routing

### Step 2: GitHub job details

```bash
gh api repos/OWNER/REPO/actions/jobs/<JOB_ID> \
  --jq '{name,labels,status,conclusion,runner_name,created_at,started_at,completed_at}'

gh run view <RUN_ID> -R OWNER/REPO --json jobs,status,conclusion
```

- **`runner_name` empty + long `created_at` → `started_at` gap** = never picked up
- **Earlier jobs in the run started, later ones queued** = a later wave hit capacity

### Step 3: Webhook routing

Log group: `/aws/lambda/<prefix>-webhook` (newer module versions with EventBridge
also have `<prefix>-dispatch-to-runner`). Filter by **workflow job ID** (not run ID):

```bash
aws logs filter-log-events --region "$REGION" --profile "$PROFILE" \
  --log-group-name "/aws/lambda/$PREFIX-webhook" \
  --start-time <ms> --end-time <ms> \
  --filter-pattern "<JOB_ID>"
```

Confirm:

- The `queued` event arrived within seconds of the GitHub queue time (not minutes later)
- The dispatch line names the expected fleet queue, e.g. `<prefix>-<key>-queued-builds`

**Mapping labels to a fleet:** each fleet's `matcherConfig` (`labelMatchers`,
`exactMatch`) in the user's multi-runner config decides which queue a job goes
to. With `exactMatch = true` the job's labels must match the fleet's labels
exactly. One missing or extra label (`self-hosted`, an arch label) sends the job
nowhere. Ask the user for their runner config if the dispatch line is missing
or names the wrong queue.

### Step 4: Scale-up logs

Log group: `/aws/lambda/<fleet environment>-scale-up` (the environment column from
the script, e.g. `gha-prod-linux-x64-scale-up`):

```bash
aws logs filter-log-events --region "$REGION" --profile "$PROFILE" \
  --log-group-name "/aws/lambda/<ENV>-scale-up" \
  --start-time <ms> --end-time <ms> \
  --filter-pattern "<PATTERN>"

# Useful <PATTERN> values:
#   "maximumRunners"   at-cap decisions (currentRunners vs maximumRunners)
#   "ERROR"            failures (IAM, KMS, SSM, launch template, EC2 capacity)
#   "jitconfig"        JIT runner registration problems
```

| Log | Meaning |
| --- | ------- |
| `currentRunners: N, maximumRunners: M` with N ≥ M | At cap: no new EC2 until runners terminate |
| `Created instance(s)` but job still queued | Boot/registration in progress (~2–4 min) or JIT failed |
| `401` / error on `generate-jitconfig` | EC2 exists but never registered with GitHub |
| `InsufficientInstanceCapacity` / spot errors | No EC2 capacity for the instance types; widen `instance_types` or allow on-demand failover |
| No scale-up logs for the job | Webhook never dispatched, or dispatched to another fleet's queue |

The EC2 console shows an instance as **Initializing** before it's an idle runner,
so "EC2 running" ≠ "runner available".

### Step 5: Decision tree

```
Job Queued
├─ No webhook "queued" event for the job ID within ~1 min
│  └─ GitHub delivery delay / failure → GitHub App → Advanced → Recent deliveries
├─ Webhook ignored the job or dispatched to the WRONG queue
│  └─ Label matcher mismatch (exactMatch, missing labels) → fix runs-on or matcherConfig, apply
├─ Webhook OK, scale-up logs currentRunners >= maximumRunners
│  └─ Fleet at cap → wait, raise runners_maximum_count, add pool, or reduce parallel jobs
├─ Webhook OK, scale-up launches EC2, job waits 2–4 min then starts
│  └─ Cold start (normal) → a warm pool (pool_config) reduces this
├─ EC2 running, runner_name still empty after 5+ min
│  └─ JIT/registration failure or bad AMI/user-data → scale-up ERROR logs, instance console output
├─ Scale-up errors / throttling with backlog below cap
│  └─ IAM/KMS/SSM/EC2 capacity issue, or low reserved concurrency on scale-up
└─ DLQ depth > 0
   └─ Repeated scale-up failures → fix the cause, then redrive the DLQ
```

### Step 6: Report template

```markdown
## Runner incident summary

**Job:** <name> (<job URL>)
**Labels:** <runs-on>
**Wait:** queued <start> → <picked up or cancelled> (<duration>)
**Fleet:** <fleet key / environment>
**AWS profile used:** <profile> (note any access denials)

### Findings
- Analyze script: <cap / backlog / DLQ / lambda errors / deficit>
- Webhook: <queue name, dispatch latency>
- Scale-up: <currentRunners vs max, errors>

### Root cause
<one sentence>

### Recommended action
<immediate step + any Terraform tuning>
```

## Where caps and tuning live

These are module variables in the user's Terraform (per fleet in multi-runner).
The script reads the live values where the module exposes them, so trust the
script and the logs over values remembered from earlier sessions:

| Variable | Effect |
| -------- | ------ |
| `runners_maximum_count` | Fleet cap (scale-up env `RUNNERS_MAXIMUM_COUNT`) |
| `minimum_running_time_in_minutes` | Idle runners aren't terminated before this |
| `pool_config` / `pool_runner_owner` | Warm pool size and schedule (cuts cold starts) |
| `scale_up_reserved_concurrent_executions` | Scale-up Lambda concurrency; too low throttles bursts |
| `instance_types`, `instance_target_capacity_type` | Spot vs on-demand and fallback types |
| `redrive_build_queue` | Enables the build-queue DLQ |
| `enable_job_queued_check` | Skip launching for jobs no longer queued |

## Deeper investigation

When the script and steps above are inconclusive:

1. **Metrics dashboard**: the module can publish runner metrics; graph pool size vs scale-up launches over time
2. **GitHub runners page** (org or repo settings → Actions → Runners): idle vs busy with the job's labels
3. **Concurrent workflow runs**: other PRs or matrix jobs consuming the same fleet
4. **Branch vs applied Terraform**: workflow labels may predate a fleet/label change
5. **CloudWatch Logs Insights**: `currentRunners` over time on the scale-up log group
6. **EC2 console**: `ghr:created_by` (`pool-lambda` vs `scale-up-lambda`), lifecycle, console output for boot failures
7. **Spot interruption**: a job that failed mid-run on spot is expected; don't use spot labels for jobs that can't be retried

## References

- Module: [terraform-aws-github-runner](https://github.com/github-aws-runners/terraform-aws-github-runner) and its [docs](https://github-aws-runners.github.io/terraform-aws-github-runner/)
- Analyze script: [`scripts/analyze-github-aws-runners.sh`](scripts/analyze-github-aws-runners.sh)
