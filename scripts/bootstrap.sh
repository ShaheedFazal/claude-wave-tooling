#!/usr/bin/env bash
# bootstrap.sh — one-command setup for a new laptop or a fresh project.
#
# Idempotent. Safe to re-run.
#
# Responsibilities:
#   1. Symlink ~/.claude/skills/{wave-planner,wave-orchestrate,wave-retro,
#      openspec-sync-specs} to the checkout of this repo. (The three wave
#      skills — wave-toolsmith and wave-start-wave were absorbed into
#      wave-planner in v0.2.0 — plus openspec-sync-specs, the nesting-aware
#      spec sync the wave archive gate depends on.)
#   2. Verify required tools are installed (gh, cmux, openspec, node, a
#      JSON-schema validator — ajv-cli or python3+jsonschema).
#   3. If run from a project directory containing .claude/project.json,
#      validate it against the schema in strict mode.
#   4. On re-run, remove stale wave-toolsmith and wave-start-wave symlinks
#      left behind by pre-v0.2.0 installs.
#
# Exits non-zero on any missing required dependency (unless --skip-checks).

set -euo pipefail

TOOLING_HOME="${CLAUDE_TOOLING_HOME:-$HOME/Dev/claude-tooling}"
SKILLS_DIR="$HOME/.claude/skills"
SKIP_CHECKS=false

for arg in "$@"; do
  case "$arg" in
    --skip-checks)
      SKIP_CHECKS=true
      ;;
    -h|--help)
      sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "Unknown argument: $arg" >&2
      exit 64
      ;;
  esac
done

echo "=== claude-tooling bootstrap ==="
echo "Tooling checkout: $TOOLING_HOME"
echo

# --- 1. Symlink shared meta skills --------------------------------------

if [ ! -d "$TOOLING_HOME/skills" ]; then
  echo "ERROR: $TOOLING_HOME/skills does not exist. Clone the repo first:" >&2
  echo "  git clone https://github.com/ShaheedFazal/claude-wave-tooling $TOOLING_HOME" >&2
  exit 1
fi

mkdir -p "$SKILLS_DIR"

for skill in wave-planner wave-orchestrate wave-retro openspec-sync-specs; do
  SRC="$TOOLING_HOME/skills/$skill"
  DST="$SKILLS_DIR/$skill"

  if [ ! -d "$SRC" ]; then
    echo "ERROR: expected shared skill missing: $SRC" >&2
    exit 2
  fi

  if [ -L "$DST" ]; then
    # Already a symlink; update if target differs
    EXISTING_TARGET=$(readlink "$DST")
    if [ "$EXISTING_TARGET" = "$SRC" ]; then
      echo "  [ok] $skill -> $SRC"
    else
      ln -sfn "$SRC" "$DST"
      echo "  [updated] $skill -> $SRC (was: $EXISTING_TARGET)"
    fi
  elif [ -e "$DST" ]; then
    echo "ERROR: $DST exists and is not a symlink. Remove or rename it before running bootstrap." >&2
    exit 3
  else
    ln -s "$SRC" "$DST"
    echo "  [created] $skill -> $SRC"
  fi
done

# Clean up stale symlinks left behind by pre-v0.2.0 installs (the three-skill
# collapse removed wave-toolsmith and wave-start-wave). Only touch symlinks
# that point into this checkout — never unlink a user-authored directory.
#
# Defensive: require both TOOLING_HOME and the symlink target to be non-empty
# before pattern-matching, so a corrupted environment can never reduce the
# case glob to "/*" and match any absolute path.
for stale in toolsmith start-wave; do
  DST="$SKILLS_DIR/wave-$stale"
  if [ -L "$DST" ]; then
    EXISTING_TARGET=$(readlink "$DST")
    if [ -n "$TOOLING_HOME" ] && [ -n "$EXISTING_TARGET" ]; then
      case "$EXISTING_TARGET" in
        "$TOOLING_HOME"/*)
          rm "$DST"
          echo "  [removed] wave-$stale (stale symlink from pre-v0.2.0)"
          ;;
        *)
          echo "  [skipped] wave-$stale — points outside $TOOLING_HOME, leaving alone"
          ;;
      esac
    else
      echo "  [skipped] wave-$stale — empty TOOLING_HOME or readlink result, refusing to touch" >&2
    fi
  fi
done

echo

# --- 2. Dependency checks -----------------------------------------------

if [ "$SKIP_CHECKS" = true ]; then
  echo "Skipping dependency checks (--skip-checks)."
else
  echo "=== Dependency checks ==="
  MISSING=0

  check_cmd() {
    local cmd="$1"
    local install_hint="$2"
    if command -v "$cmd" >/dev/null 2>&1; then
      echo "  [ok] $cmd ($($cmd --version 2>&1 | head -1))"
    else
      echo "  [MISSING] $cmd — install: $install_hint" >&2
      MISSING=$((MISSING + 1))
    fi
  }

  check_cmd gh "brew install gh (then \`gh auth login\`)"
  check_cmd cmux "see https://github.com/... (cmux is an Anthropic-internal distribution)"
  check_cmd openspec "brew install openspec (or see https://openspec.dev) — required: the wave archive gate and openspec-sync-specs depend on it"
  check_cmd node "brew install node"
  check_cmd python3 "brew install python"

  # Validator: prefer ajv, fallback to python-jsonschema
  if command -v npx >/dev/null 2>&1 && npx --no-install ajv --version >/dev/null 2>&1; then
    echo "  [ok] ajv-cli (available via npx)"
  elif python3 -c "import jsonschema" >/dev/null 2>&1; then
    echo "  [ok] python-jsonschema ($(python3 -c 'import jsonschema; print(jsonschema.__version__)' 2>/dev/null))"
  else
    echo "  [MISSING] no JSON-schema validator — install one:" >&2
    echo "           npm install -g ajv-cli ajv-formats" >&2
    echo "           OR" >&2
    echo "           pip3 install --user --break-system-packages jsonschema" >&2
    MISSING=$((MISSING + 1))
  fi

  if [ "$MISSING" -gt 0 ]; then
    echo >&2
    echo "ERROR: $MISSING required dependency/dependencies missing. Install them and re-run." >&2
    exit 4
  fi
  echo
fi

# --- 3. Validate project config if present ------------------------------

if [ -f ".claude/project.json" ]; then
  echo "=== Validating .claude/project.json (strict) ==="
  if "$TOOLING_HOME/scripts/validate-config.sh" ".claude/project.json"; then
    echo
  else
    echo >&2
    echo "ERROR: project.json failed strict validation. Fix the errors above and re-run." >&2
    exit 5
  fi

  # --- 3b. Bootstrap state directory structure on pristine consumer -------
  # Prevents shared-skill startup from emitting raw `jq` errors when
  # {{config.waveStatusFile}} or {{config.stateDir}}/waves/ don't exist yet.
  # Fixes claude-tooling#1.
  echo "=== Bootstrapping state directory (pristine-project safety) ==="
  STATE_DIR=$(python3 -c "import json; print(json.load(open('.claude/project.json'))['stateDir'])")
  CROSS_TAB_DIR=$(python3 -c "import json; print(json.load(open('.claude/project.json'))['crossTabDir'])")
  WAVE_STATUS_FILE=$(python3 -c "import json; print(json.load(open('.claude/project.json'))['waveStatusFile'])")
  RETRO_LOG=$(python3 -c "import json; print(json.load(open('.claude/project.json'))['retroLog'])")

  CREATED_ANY=false

  if [ ! -d "$STATE_DIR" ]; then
    mkdir -p "$STATE_DIR/waves"
    echo "  [created] $STATE_DIR/waves/"
    CREATED_ANY=true
  elif [ ! -d "$STATE_DIR/waves" ]; then
    mkdir -p "$STATE_DIR/waves"
    echo "  [created] $STATE_DIR/waves/"
    CREATED_ANY=true
  else
    echo "  [ok] $STATE_DIR/waves/"
  fi

  if [ ! -d "$CROSS_TAB_DIR" ]; then
    mkdir -p "$CROSS_TAB_DIR"
    echo "  [created] $CROSS_TAB_DIR/"
    CREATED_ANY=true
  else
    echo "  [ok] $CROSS_TAB_DIR/"
  fi

  if [ ! -f "$WAVE_STATUS_FILE" ]; then
    mkdir -p "$(dirname "$WAVE_STATUS_FILE")"
    cat > "$WAVE_STATUS_FILE" <<WSJSON
{
  "completedIssues": [],
  "inProgressIssues": [],
  "activeWorktrees": {},
  "activePRs": [],
  "lastUpdated": "1970-01-01T00:00:00Z",
  "remainingIssues": {
    "p0Blocking": [],
    "p1PreLaunch": [],
    "p2PostLaunch": []
  }
}
WSJSON
    echo "  [created] $WAVE_STATUS_FILE (epoch placeholder)"
    CREATED_ANY=true
  else
    echo "  [ok] $WAVE_STATUS_FILE"
  fi

  if [ ! -f "$RETRO_LOG" ]; then
    mkdir -p "$(dirname "$RETRO_LOG")"
    cat > "$RETRO_LOG" <<EOF
# Retrospective Log

Rolling log of post-issue retrospectives. Each entry is appended by the
\`wave-retro\` skill after an issue completes (post-merge, pre-archive).
EOF
    echo "  [created] $RETRO_LOG"
    CREATED_ANY=true
  else
    echo "  [ok] $RETRO_LOG"
  fi

  # Seed the FEEDBACK.md seen-sentinel so the planner's first Phase 3 run in
  # this project doesn't surface "FEEDBACK.md changed" against an empty
  # baseline. Point at the current byte-count; subsequent planner runs diff
  # from here. Harmless if FEEDBACK.md grows before the first planner run.
  FEEDBACK_FILE="$TOOLING_HOME/FEEDBACK.md"
  FEEDBACK_SENTINEL="$STATE_DIR/.feedback-seen"
  if [ -f "$FEEDBACK_FILE" ] && [ ! -f "$FEEDBACK_SENTINEL" ]; then
    wc -c < "$FEEDBACK_FILE" | tr -d ' ' > "$FEEDBACK_SENTINEL"
    echo "  [created] $FEEDBACK_SENTINEL (seeded from $FEEDBACK_FILE byte-count)"
    CREATED_ANY=true
  elif [ -f "$FEEDBACK_SENTINEL" ]; then
    echo "  [ok] $FEEDBACK_SENTINEL"
  fi

  if [ "$CREATED_ANY" = true ]; then
    echo
    echo "  NOTE: Commit the newly-created state files to your project's git history."
    echo "        (Or add them to .gitignore if you prefer state to be local-only —"
    echo "         but that means waves created on one laptop aren't visible on another.)"
  fi
  echo
else
  echo "No .claude/project.json at cwd — skipping project validation + state-dir bootstrap."
  echo "(If this IS a project that should adopt wave skills, author .claude/project.json"
  echo " per the schema at $TOOLING_HOME/schemas/project.json.schema.json)"
  echo
fi

echo "=== bootstrap complete ==="
echo "Invoke /wave:planner from any Claude Code session whose cwd is under a project"
echo "that has .claude/project.json. Planner is the one front door: it sweeps active"
echo "waves, surfaces feedback and drift, suggests the next wave, and launches it."
echo "Shared-skill maintenance happens in ~/Dev/claude-tooling directly; see"
echo "CONTRIBUTING.md there for how to evolve the shared skills."
