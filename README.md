# claude-tooling

Shared wave-orchestration skills used across multiple consumer projects.

## What this repo holds

- `skills/wave-planner/` — one front door per project: sweeps active waves, reconciles `wave-status.json` (sole writer), surfaces drift + feedback, suggests the next wave, launches it end-to-end (branch + worktree + cmux tab + orchestrator boot)
- `skills/wave-orchestrate/` — runs inside a wave: coordinates analyst → builder → reviewer → integrator via Claude Code agent teams
- `skills/wave-retro/` — post-merge analysis: scope-classified findings; shared-meta observations go to `FEEDBACK.md`
- `schemas/project.json.schema.json` — JSON Schema for per-project `.claude/project.json`
- `scripts/validate-config.sh` — strict validator wrapping the schema
- `scripts/bootstrap.sh` — one-command setup for a new laptop or project
- `docs/` — design records (decision-ledger reservation contract, spec-drift guard)
- `FEEDBACK.md` — append-only pool of observations from consumer retros
- `CONTRIBUTING.md` — maintainer-side guidance for evolving shared skills
- `MIGRATIONS.md` — schema-version migration notes

## Why this exists

The three wave-* skills are project-agnostic. Duplicating them per-project guarantees drift — fixes proposed in retros land in one repo but not the other, and the two copies silently diverge within weeks. Centralising them here, with per-project values supplied by a small `.claude/project.json`, removes the drift surface.

Framework-specific patterns (`build-frontend`, `analyst`, `review`, `comply`, etc.) are per-project and stay in each consumer's `.claude/skills/<prefix>-*/`.

## Install (existing project adopting these skills)

```bash
git clone https://github.com/ShaheedFazal/claude-wave-tooling ~/Dev/claude-tooling
cd ~/Dev/claude-tooling
./scripts/bootstrap.sh    # symlinks ~/.claude/skills/wave-{planner,orchestrate,retro} + verifies dependencies
```

Then in the consuming project repo:

```bash
# Author .claude/project.json with project-specific values; see schemas/project.json.schema.json
~/Dev/claude-tooling/scripts/validate-config.sh .claude/project.json    # must pass strict
```

## Command reference

All wave-orchestration is invoked under the `/wave-*` prefix:

| Command | Purpose |
|---------|---------|
| `/wave-planner` | One front door. Invoke from any shell in a consumer project. Runs five phases: read-only sweep of active waves, auto-heal stale state, surface drift + feedback + mailbox, plan + present the next wave (or accept explicit args), launch end-to-end. |
| `/wave-orchestrate` | (Auto-loaded inside a spawned wave tab) coordinates the wave |
| `/wave-retro` | Post-merge retrospective for a closed issue |

**Three-skill topology:**

```
/wave-planner          — per-project, on-demand, any shell
       ↓ (Phase 5 spawns the wave tab directly)
/wave-orchestrate      — per-wave, auto-loaded
       ↓ (post-merge, separate invocation)
/wave-retro            — per-project, on-demand
```

No persistent tabs at rest. No `/loop`. Parallel waves still live in independent cmux tabs — each wave gets its own worktree, its own JSON claim, its own orchestrator session.

Project-specific commands (e.g. `/web:build-frontend`, `/app:build-resource`) keep their per-project prefix and live in each consumer's `.claude/skills/`.

## Configuration: `.claude/project.json`

Every consumer MUST commit a `.claude/project.json` at its root. The schema enforces required keys (repo slug, command prefix, state directory, check command, builder routing, etc.) and rejects unknown keys (`additionalProperties: false`).

A `schemaVersion` integer in the file is matched against `minimumSchemaVersion` in the schema. Shared skills halt with an actionable upgrade message if the project's schemaVersion is below the minimum.

See `schemas/project.json.schema.json` for the canonical shape and `MIGRATIONS.md` for version-to-version migration steps.

## Version policy

- **Tags** mark consumer-tested releases (`v0.1.0-five-skills`, `v0.2.0-three-skills`, ...).
- **`main`** is what symlinks resolve to by default — usually safe but may be in transition between tags.
- **Schema versions** are major-only and bump only when an existing key changes meaning or new keys become required. Backwards-compatible additions land within the same major.
- **Migrations** between schema versions are documented in `MIGRATIONS.md`.

## Updating

Updates are check-only — nothing is auto-pulled. The planner's Phase 3 runs a read-only `git fetch` and reports "N commits behind" if the local checkout is stale. Updating is an explicit `git -C ~/Dev/claude-tooling pull` you run when you want to. See `AUTOUPDATE.md` for the rationale.

## Contributing

See `CONTRIBUTING.md` for the full guide. Summary:

1. **One-line tweaks** (typos, clarifications, applying an approved observation) — edit directly in this repo, commit, push. No ceremony.
2. **Multi-file refactors** — spawn a wave. The shape of the work decides, not the content.
3. **No project-identity branches in shared skills.** No `if commandPrefix == "web" then X`. Project-specific behaviour goes in `.claude/project.json` as data, not as conditionals in the shared skill body.
4. **No prose fallbacks.** Phrases like "default to X", "otherwise use Y", "fall back to Z" in behaviour-affecting prose are rejected unless they reference a config key with a documented default.
5. **Required-key changes bump `minimumSchemaVersion`.** Document the migration in `MIGRATIONS.md`.

Consumer retros append short observations to `FEEDBACK.md` (prose, not diffs). The next maintainer session here decides what to act on.

## Status

v0.2.0-three-skills. The skills are in active use across multiple private consumer projects (`acme-web`, `acme-app` are the placeholder names used in examples throughout this repo). The consumer projects themselves are not public.
