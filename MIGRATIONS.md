# claude-tooling project.json migrations

Most entries describe a change to the schema's `minimumSchemaVersion` and what consumers must do before pulling. A few — tagged **(install)** — cover bootstrap or skill-layout changes that need a one-time action on existing machines rather than a `project.json` edit.

The shared wave skills halt with an actionable error if a project's `.claude/project.json` is below the current `minimumSchemaVersion`. The fix is always to update `.claude/project.json` in each consuming repo, then commit it on whatever branch makes sense for that consumer.

---

## v1 → v2 (2026-04-16): tab-naming requires `displayName`

**Why:** The toolsmith and planner each spawn their own cmux tab per project. With only `projectName` (a slug like `acme-web`), tab strips became hard to read when several projects were active. `displayName` is a short human-readable label distinct from the slug.

**What changed:**

- `displayName` is now a required string in `project.json` (max 32 chars).
- `minimumSchemaVersion` bumped from `1` to `2`.
- The `wave-start-wave`, `wave-planner`, and `wave-toolsmith` skills now substitute `{{config.displayName}}` into cmux tab names.

**Consumer migration steps:**

1. Edit `.claude/project.json` in each consuming repo:
   - Bump `"schemaVersion": 1` → `"schemaVersion": 2`.
   - Add a `"displayName"` field. Keep it short (≤32 chars) and recognisable on a tab strip. Examples: `"Acme Web"`, `"Acme App"`.
2. Commit the change on whatever branch the project uses. No coordination with claude-tooling needed beyond pulling this version.
3. Optional but recommended: if the project ships a launcher script (e.g. `launch.sh`) whose `--name` argument hardcodes the toolsmith tab name, update it to match the new `displayName` for consistency. Launcher scripts do not parse `project.json` today.
4. Re-run `~/Dev/claude-tooling/scripts/bootstrap.sh` to validate the updated config.

---

## v2 → v3 (2026-04-21): optional `prodHealthProbe`

**Why:** Planner ran blind to production health. On 2026-04-20 two waves (`wave-2026-04-20-payload-safety` and `wave-2026-04-20-rebuild-triggers`) shipped four PRs on top of a silently degraded Payload worker whose migration had failed 18 hours earlier. Neither wave introduced the regression; neither detected it. Phase 1 sweep + Phase 5 verify-main only read local state and CI results, never prod. See `claude-tooling#16` and `FEEDBACK.md` entry `2026-04-21T17:15:00Z`.

The fix: let `.claude/project.json` declare a prod health endpoint and a jq assertion. When configured, the planner probes on every invocation, surfaces degraded prod as a Phase 3 BLOCKER, routes Phase 4 toward amendment waves, and refuses to launch non-`fix-` waves at Phase 5.2 while prod is still degraded.

**What changed:**

- Optional `prodHealthProbe` object added to `project.json` schema with two required sub-fields: `url` (string, uri format) and `healthyJqExpr` (jq expression evaluated against the body via `jq -e`).
- `minimumSchemaVersion` bumped from `2` to `3`. Note: the new field itself is optional, so the bump exists to force every consumer to explicitly acknowledge the new capability (by setting `schemaVersion: 3`), not because absence of the probe breaks anything. See `CONTRIBUTING.md` §4 — this bump is a deliberate departure from the "additive optional field keeps the major version" rule; the rationale is coordinated adoption of a prod-safety signal.
- `wave-planner/SKILL.md` Phase 1 runs the probe (silent at Phase 1, surfaces at Phase 3). Phase 3 has a new top-of-list BLOCKER item for degraded prod. Phase 4 amendment-routing becomes mandatory when the probe is failing. Phase 5.2 re-probes before atomic claim and blocks non-`fix-` wave names on a failing re-probe.
- All three `wave-*` skill preambles updated: optional config keys now evaluate to "not configured" rather than halting the skill.

**Consumer migration steps:**

1. Edit `.claude/project.json` in each consuming repo:
   - **Mandatory:** bump `"schemaVersion": 2` → `"schemaVersion": 3`.
   - **Optional but recommended** for any project with a live prod endpoint: add a `prodHealthProbe` block. Example:
     ```json
     "prodHealthProbe": {
       "url": "https://api.example.com/api/health",
       "healthyJqExpr": ".status == \"healthy\""
     }
     ```
     Keep the jq expression tight. Assertions that match too loosely (e.g. `. != null`) defeat the purpose.
2. Commit the change on whatever branch the project uses.
3. Re-run `~/Dev/claude-tooling/scripts/validate-config.sh .claude/project.json` to confirm the schema accepts it.
4. Projects **without** a live prod endpoint (e.g. `acme-app` as of 2026-04-21) still need step 1 (the version bump) but can omit `prodHealthProbe` entirely. The planner behaves as it did pre-v3 when the probe is absent.

---

## (install) 2026-06-04: `openspec-sync-specs` becomes a bundled, symlinked skill

**Type:** bootstrap/install migration — **no `project.json` schema change**, no `minimumSchemaVersion` bump. Affects only the `~/.claude/skills/` layout, and only on a machine that already had a hand-installed copy of this skill.

**Why:** `openspec-sync-specs` — the nesting-aware spec sync that the wave archive gate (`wave-orchestrate` Step 9c) depends on — used to be a loose, hand-maintained directory under `~/.claude/skills/`. It lived in no repo, so it was neither backed up nor distributed. It is now versioned here under `skills/openspec-sync-specs/` and symlinked by `bootstrap.sh` alongside the wave skills.

**What changed:**

- `skills/openspec-sync-specs/` is now tracked in this repo (source of truth).
- `bootstrap.sh` now iterates `wave-planner wave-orchestrate wave-retro openspec-sync-specs` and symlinks each into `~/.claude/skills/`.

**Consumer migration steps (only if bootstrap errors):**

Fresh installs, and machines that never had the loose copy, need **no action** — `bootstrap.sh` just creates the symlink. But on a machine where `~/.claude/skills/openspec-sync-specs` already exists as a **real directory** (a pre-existing hand-installed copy), bootstrap halts — by design, it refuses to clobber a directory it didn't create:

> `ERROR: …/openspec-sync-specs exists and is not a symlink. Remove or rename it before running bootstrap.`

Fix:

1. If your loose copy has local edits worth keeping, diff it against the repo copy and port them in first: `diff -r ~/.claude/skills/openspec-sync-specs ~/Dev/claude-tooling/skills/openspec-sync-specs`. Commit any ported changes.
2. Remove the loose copy: `rm -rf ~/.claude/skills/openspec-sync-specs`.
3. Re-run `~/Dev/claude-tooling/scripts/bootstrap.sh` — it recreates the path as a symlink into the checkout (`[created] openspec-sync-specs -> …`).
