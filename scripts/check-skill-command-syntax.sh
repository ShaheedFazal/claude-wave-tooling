#!/usr/bin/env bash
# Guard against the recurring `/wave:planner` vs `/wave-planner` naming bug.
# Active wave skill commands MUST use the hyphen form (matches the actual
# skill directory names under skills/wave-*/). The colon form is reserved for
# deprecated historical references (`/wave:start-wave`, `/wave:toolsmith`) and
# for historical observation records in FEEDBACK.md.
#
# Exits non-zero if any active-command colon form appears in skill bodies or
# user-facing docs.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

FORBIDDEN_PATTERN='/wave:(planner|orchestrate|retro)'
INCLUDE_GLOBS=(
  'skills/wave-*/SKILL.md'
  'README.md'
  'CONTRIBUTING.md'
  'AUTOUPDATE.md'
)

HITS=0
for glob in "${INCLUDE_GLOBS[@]}"; do
  while IFS= read -r path; do
    if grep -nE "$FORBIDDEN_PATTERN" "$path" 2>/dev/null; then
      HITS=$((HITS + 1))
    fi
  done < <(ls $glob 2>/dev/null || true)
done

if [ "$HITS" -gt 0 ]; then
  echo
  echo "ERROR: active wave skill commands MUST use the hyphen form."
  echo "Found $HITS file(s) above with /wave:planner | /wave:orchestrate | /wave:retro."
  echo "Replace with /wave-planner, /wave-orchestrate, /wave-retro respectively."
  echo "(Historical references like /wave:start-wave or /wave:toolsmith are NOT checked here)."
  exit 1
fi

echo "OK: no forbidden colon-form skill commands found in active files."
