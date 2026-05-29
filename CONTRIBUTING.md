# Contributing to claude-tooling

This file replaces `skills/wave-toolsmith/SKILL.md`. Under the three-skill model (planner + orchestrate + retro), there is no persistent per-project toolsmith tab and no toolsmith skill — shared-skill evolution is a normal source-control workflow that happens **here, in this repo**, not from a consumer's `.claude/` tab.

If you're making a quick change to a shared skill: edit, commit, push, move on. Most edits don't need any ceremony beyond this.

Everything below is guidance for the cases that benefit from structure.

## 1. When to edit vs spawn a wave

The shape of the work decides — not the content.

| Edit directly (do it here, as a normal commit) | Spawn a wave (branch + PR + CI + review + merge) |
|---|---|
| One-line SKILL.md clarification | Multi-file orchestration-layer refactor |
| Typo or grammar fix | Extraction, reorganisation, or renaming across skills |
| Applying an approved retro observation | Schema bump with migration doc |
| Updating `FEEDBACK.md` / `MIGRATIONS.md` / `README.md` | CI or workflow change that ships via PR |
| Fixing a bug found by dry-run before anything landed | Anything that touches consumers' behaviour in a non-trivial way |

**The "is this a wave?" test:** if the work produces a PR that goes through CI and review, it's a wave. Spawn it via `/wave-planner` (in a consumer repo that can see `claude-tooling` as its source for shared skills, or directly with a dedicated Claude session here). Don't inline multi-file refactors as a single commit because it feels faster — the wave discipline exists so that orchestration-layer changes are reviewable.

Prior violation (retro finding 22 on `acme-web`): the original `shared-wave-skills` extraction was implemented as a 4-phase, multi-PR project inside a single consumer's toolsmith tab. The content was shared-skills domain but the shape was wave-shaped. Doing it again today: spawn a wave.

## 2. How to evolve a shared skill

1. `cd ~/Dev/claude-tooling && git pull`
2. Edit `skills/wave-<name>/SKILL.md` (or another file in this repo).
3. Commit with a descriptive message that references the retro or issue motivating the change. Conventional-commit prefix preferred: `feat(wave):`, `fix(wave):`, `docs:`, etc.
4. `git push`.
5. Each consumer's next `/wave-planner` invocation runs a drift check and surfaces "N commits behind — pull `~/Dev/claude-tooling` to update" on Phase 3. The consumer pulls when they want; updates are never auto-applied.

**Tag when consumer-visible behaviour changes.** Tags mark checkpoints that consumers can roll back to. Not every commit deserves a tag. Examples of tag-worthy changes: skill API changes, required-config additions, significant behavioural shifts.

## 3. Drift check and the feedback pool

### Drift check (read-only)

The `/wave-planner` skill in consumer repos runs this during its Phase 3 (Human-surface) sweep:

```bash
git -C ~/Dev/claude-tooling fetch --quiet origin main 2>/dev/null && {
  LOCAL=$(git -C ~/Dev/claude-tooling rev-parse HEAD)
  REMOTE=$(git -C ~/Dev/claude-tooling rev-parse origin/main)
  if [ "$LOCAL" = "$REMOTE" ]; then
    echo "Shared skills up to date."
  else
    BEHIND=$(git -C ~/Dev/claude-tooling rev-list --count HEAD..origin/main)
    echo "Shared skills are $BEHIND commits behind — run \`git -C ~/Dev/claude-tooling pull\` to update."
  fi
}
```

Never auto-pull. See `AUTOUPDATE.md` for the rationale (summary: a shared skills change that quietly lands mid-wave can poison a running orchestrator; explicit pull by the human is the gate).

### Feedback pool (`FEEDBACK.md`)

`FEEDBACK.md` at repo root is where consumer retros append short observations. The format and rules live in that file's header. Key points for maintainers:

- New entries are informational, not patches. Act on them when you're evolving shared skills; leave them alone otherwise.
- Consumer `/wave-planner` Phase 3 surfaces "N new entries since last check" via a small sentinel (`{{config.stateDir}}/.feedback-seen`). No mark-read dance — entries stay in the file indefinitely.

## 4. Schema changes

Bump `schemaVersion` and `minimumSchemaVersion` in `schemas/project.json.schema.json` when:

- A required key is added, removed, or renamed.
- The meaning of an existing key changes in a way consumers must react to.

Backwards-compatible additions (new optional keys, new enum values that consumers don't have to handle) stay in the same major version.

Every bump requires:

1. An entry in `MIGRATIONS.md` explaining what changed and what each consumer must do.
2. The consumer-side change, if any, coordinated in a parallel PR. Halt the shared-tooling merge until consumers have staged their updates.

Consumers that fail to bump their `schemaVersion` see an actionable halt message from the `wave-*` skill preamble; the preamble is the enforcement point.

## 5. Commit discipline

Three hard rules. CI and human review reject violations.

1. **No project-identity branches in shared skills.** Never write `if commandPrefix == "web" then X else Y` or prose equivalents in a shared skill. Project-specific behaviour lives in `.claude/project.json` as data; shared skills consume that data without knowing which consumer they're running in.
2. **No prose fallbacks.** Avoid phrases like "default to X", "otherwise use Y", "fall back to Z" in behaviour-affecting prose unless they reference a config key with a documented default. Prose fallbacks bypass the no-branching grep and are the most likely source of cross-project drift.
3. **Required-key changes bump `minimumSchemaVersion`.** See Section 4.

## 6. Testing discipline

Shared-skill changes are hard to test because they run inside other Claude sessions. Two practices:

- **Dry-run via a subagent.** Before committing a non-trivial skill edit, spawn a subagent (`Agent(subagent_type=general-purpose)`) with a minimal scenario and the edited skill body, and verify the subagent follows the revised steps. This catches step-number collisions, broken cross-references, and ambiguous instructions that no validator can.
- **Validate `project.json` samples.** `scripts/validate-config.sh` checks a config against the schema in strict mode. Run it against both consumer configs (`acme-web/.claude/project.json` and `acme-app/.claude/project.json`) after any schema or required-key change.

For planner-specific changes: run the sweep against a known-stale wave state file (e.g. a JSON where `phase: "in-progress"` but the branch is merged) and verify the auto-heal output matches expectations.

## 7. What lives where

| Area | Location |
|---|---|
| Shared skills | `skills/wave-*/SKILL.md` |
| Consumer-project.json schema | `schemas/project.json.schema.json` |
| Bootstrap + validation scripts | `scripts/*.sh` |
| Design records | `docs/*.md` |
| Active feedback pool | `FEEDBACK.md` |
| Schema migration notes | `MIGRATIONS.md` |
| Consumers' symlinks to shared skills | `~/.claude/skills/wave-*` (set up by `scripts/bootstrap.sh`) |

## 8. Three-layer delivery (reference)

For context when reviewing shared-skill changes:

```
/wave-planner          — picks + launches + sweeps waves (per-project, on-demand)
       ↓
/wave-orchestrate      — coordinates analyst → builder → reviewer → integrator (per-wave)
       ↓
/wave-retro            — post-merge analysis, writes observations to FEEDBACK.md for
                         shared-meta scope (per-wave, on-demand)
```

No `wave-toolsmith`, no `wave-start-wave`. Planner absorbs the launch mechanics. This file is the maintainer-side replacement for the old toolsmith skill's "evolve shared skills" content.
