---
description: Post-merge retrospective analysis of completed issues. Reads .claude/project.json for per-project configuration. Classifies findings by scope. Appends project-specific findings to the local retro log; appends shared-meta observations (prose only, no diffs) to claude-tooling/FEEDBACK.md.
argument-hint: <issue-number> (e.g. "174")
---

# Retrospective

## Configuration

This skill reads project-specific values from `.claude/project.json` at the current working directory.

**Before doing anything else:**

1. Locate `.claude/project.json` (relative to cwd). If missing, STOP and report:
   `".claude/project.json not found — shared wave skills require per-project configuration. See claude-tooling/README.md."`
2. Treat every `{{config.<key>}}` token in this skill body as that value from `project.json`. Nested keys use dot notation (e.g. `{{config.repo}}`).
3. If any `{{config.<key>}}` referencing a **required** key (per the JSON schema) cannot be resolved, STOP and report the missing path by name. Tokens referencing **optional** keys (e.g. `{{config.prodHealthProbe}}` and its sub-fields) evaluate to "not configured" when absent — behaviour guarded on those tokens is skipped rather than halted.
4. If `schemaVersion` in `project.json` is below the schema's `minimumSchemaVersion`, STOP with: `"project.json schemaVersion N is below minimum M required by claude-tooling. See claude-tooling/MIGRATIONS.md."`

This preamble is identical across all `wave-*` skills.

## Purpose

Post-issue analysis. Runs after merge, before archive. Reads structured data (worker logs, git history, review verdicts) — not terminal output. Records observations; does not prescribe diffs. Shared-meta patterns propagate to other consumers via the feedback pool in `~/Dev/claude-tooling/FEEDBACK.md`.

## Step 1: Collect inputs

For issue `{ARGUMENT}`, read cheap high-signal artifacts first. Fall through to transcript parsing only if those are thin or inconsistent.

### Primary inputs

1. `git log --oneline main --grep="#{ARGUMENT}"` — merge commits, commit messages, bodies.
2. `git log --oneline <wave-branch>` or `git log --oneline issue-{ARGUMENT}-*` — feature-branch commits (proxy for retries, phase progression, architectural pivots).
3. `{{config.retroLog}}` — prior retro entries (check for recurring patterns; finding numbers for cross-reference).
4. `{{config.decisionLedger}}` — any `D-NNN` entries associated with this issue.
5. **OpenSpec artifacts** from `openspec/changes/archive/*-<issue-slug>/` or the active `openspec/changes/<name>/`:
   - `HANDOFF.md` if present — inter-phase context and dry-run findings
   - `proposal.md`, `design.md`, `tasks.md` — what was planned, decisions made
6. **PR description and review comments** (`gh pr view <N> --repo {{config.repo}}`).

### Fallback inputs (only if primary is thin)

7. **Claude Code session transcripts** — `{{config.sessionTranscriptsDir}}/*.jsonl`. Filter by wave branch or worktree path:
   ```bash
   grep -l '"gitBranch":"<wave-branch-name>"' {{config.sessionTranscriptsDir}}/*.jsonl
   ```
   Authoritative audit trail when intermediate artifacts are thin. Use `jq` to extract specific patterns — do NOT read a whole file into context.
8. **Review verdicts** from session transcripts (search for `PASS`/`FAIL`/`BLOCK` in assistant messages from the reviewer teammate). Skip if verdicts are already visible in commit messages or PR comments.

Well-documented changes rarely need transcript parsing.

## Step 2: Analysis checklist

### A. Worker quality
- Did the builder FAIL review? Which rubric sections?
- Is this the same failure as a prior issue? Check `{{config.retroLog}}`.
- Did the builder miss instructions that ARE in its skill? → Note but don't propose a skill change (model issue, not prompt issue).
- Did the builder miss instructions that are NOT in its skill? → Propose adding them via an observation.

### B. Orchestrator discipline
- Did the orchestrator use `Edit`/`Write`/`MultiEdit` directly? (grep the log)
- Did the orchestrator read more than 1 file in the project source tree?
- Did the orchestrator skip OpenSpec?
- Did the orchestrator read `git diff` directly instead of delegating?

### C. Process efficiency
- How long did the issue take (first spawn → merge)?
- How many review cycles?
- Merge conflicts? Which files?
- Model escalation required?

### D. Data integrity
- Did schema changes use constrained types (enums, validated strings)?
- Any free-text fields where dropdowns should have been used?
- Did CMS-facing schema include `.describe()` for non-obvious fields?

## Step 3: Classify each finding's scope

- `scope: shared-meta` — applies to files under `~/Dev/claude-tooling/` (shared skills, schema, scripts). Propagates to other consumers via `FEEDBACK.md`.
- `scope: project-skill` — applies to files under `.claude/skills/{{config.commandPrefix}}-*/`. Local to this project.
- `scope: config` — applies to `.claude/project.json` or the schema. Data change, not behaviour.

Classification determines where the observation lands (Step 4).

## Step 4: Write the retro entry (always)

Append to `{{config.retroLog}}`:

```markdown
## Issue #<N> — <title> (<date>) [scope: <shared-meta|project-skill|config>]
- Worker: <role> | Verdict: <PASS/FAIL x N/BLOCK> | Cycles: <N>
- Findings: <1–3 bullet points>
- Pattern: <new | recurring (see issue #X)>
```

Scope tag is mandatory. Keep it short — the retro log is a log, not an essay.

### Finding numbering — avoid concurrent-edit collisions

`{{config.retroLog}}` is a single append-only file, which makes it a collision surface when a long-running feature branch pre-seeds findings while main-direct retro entries are also landing. Two branches picking "the next free number" produce duplicate IDs.

**Rule for pre-seeded findings on a feature branch:**
- Do NOT allocate a global integer on the feature branch.
- Use a branch-local ID: `#{issue}-a`, `#{issue}-b`, … where `{issue}` is the wave's primary issue number.
- Example heading: `### Finding #238-a (builder, wave-208cde) — <title>`

**Rule for the retro author at merge time** (this skill, post-merge):
- Renumber any `#{issue}-<letter>` headings into the next free global integers, taking the current max from main's `{{config.retroLog}}`.
- Preserve cross-references within the wave: if pre-seeded finding `#238-b` said "this demotes #238-a", rewrite to the new global numbers after renumbering.

## Step 5: If any finding is scope: shared-meta — append to FEEDBACK.md

For each shared-meta finding, append a short observation to `~/Dev/claude-tooling/FEEDBACK.md`. **Prose only. No diffs.** The next `claude-tooling` maintainer session decides whether to act.

```bash
TOOLING_HOME="${CLAUDE_TOOLING_HOME:-$HOME/Dev/claude-tooling}"
cat >> "$TOOLING_HOME/FEEDBACK.md" <<EOF

## $(date -u +%Y-%m-%dT%H:%M:%SZ) — {{config.projectName}} / issue #<N>

- **Saw:** <1–2 sentence description of what happened during the wave>
- **Context:** {{config.retroLog}} (issue #<N>), <wave branch or PR link>
- **Hypothesis (optional):** <one line — leave out if unclear>
EOF
```

`$CLAUDE_TOOLING_HOME` honours non-default installs; the default matches `scripts/bootstrap.sh`.

Format rules:
- Keep each entry under ~8 lines. Longer than that means you're proposing a patch — and patches belong in actual commits against `claude-tooling/skills/wave-*/`, not in the pool.
- No prescribed fields beyond "Saw" and "Context". Hypothesis is optional.
- No status tracking. Once written, entries stay in `FEEDBACK.md` indefinitely.

For `scope: project-skill` and `scope: config` findings: no cross-repo action. Retro log entry is the whole record.

## Step 6: Apply (if the finding warrants it and scope is local)

For findings that are clearly actionable AND local (project-skill or config):

1. Edit the target file in the consumer repo.
2. Commit to main with a message that references the issue and finding: `fix({{config.commandPrefix}}): <description> (issue #<N>, finding #<M>)`.
3. Push.

For findings scoped `shared-meta`: do NOT edit shared skill files from this skill. The observation in `FEEDBACK.md` is the handoff; acting on it is a separate commit in `~/Dev/claude-tooling`.

**NEVER apply changes automatically.** Every application — local or shared — is a deliberate commit by the human or by a separate session working in the right repo.

## When to escalate vs note

- **Same failure 2+ times across different issues** → write a shared-meta observation with hypothesis.
- **First occurrence** → note it, don't propose anything yet.
- **Orchestrator discipline violation** → always write a shared-meta observation (these compound).
- **Data integrity gap** → always write a project-skill observation proposing schema constraints.
- **Model failure where instruction WAS in the skill** → note it; don't propose a skill change.

## Rules

- READ ONLY for analysis — WRITE only to `{{config.retroLog}}` and (for shared-meta findings) `~/Dev/claude-tooling/FEEDBACK.md`.
- Observations, not diffs. If a diff is obvious, commit it separately.
- Distinguish model failures from prompt failures.
- Track patterns across issues, not just within one.
- Always classify scope before writing the entry.
