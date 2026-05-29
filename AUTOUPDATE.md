# Autoupdate policy

**Updates to this repo are check-only. The local checkout is never mutated automatically.**

## What happens

Every `/wave-planner` invocation in a consuming project runs a read-only `git fetch --quiet origin main` against the local `~/Dev/claude-tooling` checkout during its Phase 3 (Human-surface) sweep. It then compares the local HEAD to `origin/main` and surfaces one of these:

- `Shared skills up to date.`
- `Shared skills are N commits behind — run \`git -C ~/Dev/claude-tooling pull\` to update.`
- `Drift check skipped: <reason>` (offline, auth error, remote unreachable)

The planner never runs `git pull`, `git reset`, `git checkout`, or any other mutating command against the tooling checkout.

## Why not auto-pull

Auto-pulling on every planner invocation would silently ship upstream commits into active waves. Three concrete failure modes that motivate the check-only stance:

1. **Mid-wave behaviour change.** A teammate respawn within an active wave re-reads the orchestrate skill from disk. If the skill changed under the wave's feet, the wave's behaviour becomes inconsistent within a single run — worse than a clean failure.
2. **Cross-project regression delay.** A patch good for project A may break project B in subtle ways that take days to surface. Manual pull means the regression is bounded to the project that pulled most recently — easier to attribute, easier to revert.
3. **Solo-operator cognitive load.** "Did the planner just change behaviour?" is a question that should never come up. Pulling is an explicit act with a known time and outcome.

## When to pull

When the planner reports "N commits behind", read the recent commits in this repo (`git -C ~/Dev/claude-tooling log --oneline origin/main..HEAD` or via the GitHub UI) and decide:

- **Cosmetic / docs-only changes** → safe to pull anytime, including mid-wave.
- **Behavioural changes to wave-planner, wave-orchestrate, or wave-retro** → finish the current wave first, then pull, then start the next wave on the updated skills. Test the first wave on the new version with extra attention.
- **Schema changes (`minimumSchemaVersion` bump)** → finish current waves, pull, update each consuming project's `.claude/project.json` to match the new minimum, validate, then resume.
- **Cross-project retro notices** (new entries in `FEEDBACK.md`) → review the notice in context of the consuming project before pulling, since the patch may not generalise.

## Future enhancements

- Version-pinned symlinks (each project pins which tag it consumes; the planner reports if a pin is below minimum).
- Notification of upstream changes via cross-tab mailbox so multiple consumers can coordinate on a pull.

Both deferred until a third consumer or a real collaborator joins.
