#!/usr/bin/env bash
# validate-config.sh — strict validator for .claude/project.json
#
# Usage: validate-config.sh <path-to-project.json>
# Returns 0 on valid, non-zero on any schema violation, missing required key,
# unknown key (additionalProperties: false), or schemaVersion < minimumSchemaVersion.

set -euo pipefail

CONFIG_PATH="${1:-}"
SCHEMA_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/schemas/project.json.schema.json"

if [[ -z "$CONFIG_PATH" ]]; then
  echo "Usage: $0 <path-to-project.json>" >&2
  exit 64
fi

if [[ ! -f "$CONFIG_PATH" ]]; then
  echo "ERROR: config file not found: $CONFIG_PATH" >&2
  exit 1
fi

if [[ ! -f "$SCHEMA_PATH" ]]; then
  echo "ERROR: schema not found at $SCHEMA_PATH" >&2
  exit 2
fi

# Pick a validator. Prefer ajv (faster, better strict-mode messages); fall back to python jsonschema.
if command -v npx &>/dev/null && npx --no-install ajv --version &>/dev/null 2>&1; then
  VALIDATOR="ajv"
elif command -v python3 &>/dev/null && python3 -c "import jsonschema" &>/dev/null; then
  VALIDATOR="python"
else
  echo "ERROR: no validator available. Install one of:" >&2
  echo "  npm install -g ajv-cli ajv-formats" >&2
  echo "  pip install jsonschema" >&2
  exit 3
fi

# Schema-version gate: project.json's schemaVersion must be >= schema's minimumSchemaVersion.
PROJECT_VERSION="$(python3 -c "import json,sys; print(json.load(open('$CONFIG_PATH')).get('schemaVersion', 0))")"
MIN_VERSION="$(python3 -c "import json,sys; print(json.load(open('$SCHEMA_PATH')).get('minimumSchemaVersion', 1))")"

if [[ "$PROJECT_VERSION" -lt "$MIN_VERSION" ]]; then
  echo "ERROR: project.json schemaVersion=$PROJECT_VERSION is below minimum $MIN_VERSION required by claude-tooling." >&2
  echo "       See claude-tooling/MIGRATIONS.md for the upgrade path." >&2
  exit 4
fi

# Run the schema validator in strict mode.
case "$VALIDATOR" in
  ajv)
    npx --no-install ajv validate \
      --strict=true \
      --strict-types=true \
      --strict-tuples=true \
      --strict-required=true \
      --all-errors \
      -s "$SCHEMA_PATH" \
      -d "$CONFIG_PATH"
    ;;
  python)
    python3 - "$SCHEMA_PATH" "$CONFIG_PATH" <<'PYEOF'
import json, sys
from jsonschema import Draft7Validator

schema = json.load(open(sys.argv[1]))
config = json.load(open(sys.argv[2]))

validator = Draft7Validator(schema)
errors = sorted(validator.iter_errors(config), key=lambda e: list(e.path))

if errors:
    for e in errors:
        path = "/".join(str(p) for p in e.path) or "(root)"
        print(f"FAIL [{path}]: {e.message}", file=sys.stderr)
    sys.exit(1)

print(f"OK: {sys.argv[2]} valid against {sys.argv[1]}")
PYEOF
    ;;
esac
