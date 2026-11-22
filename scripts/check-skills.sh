#!/usr/bin/env bash
# check-skills.sh: validate every skills/<name>/SKILL.md against AGENTS.md.
#
# Usage: scripts/check-skills.sh [--help] [REPO_ROOT]
#
# Checks, per skill directory:
#   - SKILL.md exists and starts with a frontmatter block (--- ... ---)
#   - frontmatter has exactly the keys `name` and `description`
#   - `name` equals the directory name and is lowercase-hyphenated
#   - `description` is non-empty and under 1024 characters
#   - SKILL.md is at most 500 lines
#   - README.md links to skills/<name>/SKILL.md (inventory row)
#
# Required tools: bash (3.2+), awk, grep, wc. Read-only.
# Exit codes: 0 all checks pass, 1 one or more checks failed,
#             64 usage error (bad argument or no skills/ directory).

set -euo pipefail

usage() { sed -n '2,/^$/s/^# \{0,1\}//p' "$0"; }

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
if [ ! -d "$ROOT/skills" ]; then
  echo "error: no skills/ directory under '$ROOT'" >&2
  exit 64
fi

MAX_DESC=1024
MAX_LINES=500
failures=0
count=0

fail() {
  echo "FAIL $1: $2"
  failures=$((failures + 1))
}

for dir in "$ROOT"/skills/*/; do
  dir="${dir%/}"
  skill="$(basename "$dir")"
  file="$dir/SKILL.md"
  count=$((count + 1))

  if [ ! -f "$file" ]; then
    fail "$skill" "missing SKILL.md"
    continue
  fi

  if [ "$(head -n 1 "$file")" != "---" ]; then
    fail "$skill" "SKILL.md must start with a '---' frontmatter line"
    continue
  fi

  # Frontmatter = lines between the first two '---' lines.
  fm="$(awk 'NR==1{next} /^---[[:space:]]*$/{exit} {print}' "$file")"
  if [ "$(grep -c '^---' "$file")" -lt 2 ]; then
    fail "$skill" "frontmatter is not closed with '---'"
    continue
  fi

  keys="$(printf '%s\n' "$fm" | grep -E '^[A-Za-z0-9_-]+:' | sed 's/:.*//' | sort | tr '\n' ' ')"
  if [ "$keys" != "description name " ]; then
    fail "$skill" "frontmatter keys must be exactly 'name' and 'description' (found: ${keys:-none})"
  fi

  name="$(printf '%s\n' "$fm" | sed -n 's/^name:[[:space:]]*//p' | head -n 1)"
  if [ "$name" != "$skill" ]; then
    fail "$skill" "name '$name' does not match directory '$skill'"
  fi
  if ! printf '%s' "$name" | grep -Eq '^[a-z0-9]+(-[a-z0-9]+)*$'; then
    fail "$skill" "name '$name' must be lowercase and hyphen-separated"
  fi

  desc="$(printf '%s\n' "$fm" | sed -n 's/^description:[[:space:]]*//p' | head -n 1)"
  desc_len="$(printf '%s' "$desc" | wc -c | tr -d ' ')"
  if [ "$desc_len" -eq 0 ]; then
    fail "$skill" "description is empty"
  elif printf '%s' "$desc" | grep -Eq '^[>|][-+]?$'; then
    fail "$skill" "description uses a multi-line YAML block (> or |); keep it on one line"
  elif [ "$desc_len" -ge "$MAX_DESC" ]; then
    fail "$skill" "description is $desc_len chars (must be under $MAX_DESC)"
  fi

  lines="$(wc -l < "$file" | tr -d ' ')"
  if [ "$lines" -gt "$MAX_LINES" ]; then
    fail "$skill" "SKILL.md is $lines lines (max $MAX_LINES; move detail to references/)"
  fi

  if ! grep -Fq "(skills/$skill/SKILL.md)" "$ROOT/README.md"; then
    fail "$skill" "README.md has no inventory link to skills/$skill/SKILL.md"
  fi
done

if [ "$count" -eq 0 ]; then
  echo "error: no skill directories found under $ROOT/skills" >&2
  exit 64
fi

if [ "$failures" -gt 0 ]; then
  echo "$failures check(s) failed across $count skill(s)."
  exit 1
fi
echo "OK: $count skill(s) passed."
