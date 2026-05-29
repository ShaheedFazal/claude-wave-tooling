---
description: Coordinate a wave of work within a single session using agent teams. Reads .claude/project.json for per-project configuration. Spawns analyst, builder, reviewer, and integrator teammates that communicate directly. Loaded automatically by /wave:start-wave.
argument-hint: <wave-name> (e.g. "wave-12-prescriptions" — must match a file in the project's wave state directory)
---

# Orchestrate Wave

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

Coordinate a wave of work from analyst → builder → reviewer → integrator using Claude Code agent teams. This skill runs INSIDE a wave session (created by `/wave:start-wave`). It is the lead session for the team.

## Strict boundary: you are a coordinator, not a worker

You spawn teammates and message them. You do NOT:
- Write application code yourself (delegate to builder teammate)
- Read files in the project source tree to understand the issue (delegate to analyst teammate)
- Run `git diff` on changes to review them (delegate to reviewer teammate)
- Merge branches yourself (delegate to integrator teammate)

The test before any action: **is this coordination or work?** Coordination → do it. Work → delegate.

### Never run a process skill inline

Process skills — `/{{config.commandPrefix}}:analyst`, `/{{config.commandPrefix}}:build-*`, `/{{config.commandPrefix}}:review`, `/{{config.commandPrefix}}:integrate` — are ALWAYS invoked via `Agent(subagent_type=…)` teammate spawns. Never load one into the orchestrator's own context with the `Skill` tool and execute its steps yourself.

This rule holds on ALL paths, including:
- Initial wave kickoff (Step 3, Step 7, Step 8, Step 10)
- **Mid-wave scope amendments** (e.g. mailbox delivers a new issue; wave-status notes updated) — spawn a fresh analyst teammate for the added issue; do NOT run the analyst skill inline "because you're already here"
- Wave resumption after a pause or crash
- "Quick" fixes that feel small enough to do inline

The temptation is strongest when a scope change arrives and loading `/{{config.commandPrefix}}:analyst` in-context feels faster than a teammate spawn. It is not. Inline execution poisons the orchestrator's context with analyst-shaped work, produces no teammate log, and blurs the coordinator/worker boundary this skill exists to enforce.

Worked example (Acme Web, wave-208cde, 2026-04-14): issue #238 was added to an in-progress wave. The orchestrator loaded the analyst skill, ran `openspec new change`, and wrote `proposal.md` directly in its own tab before the human noticed and corrected it. The correct action was a single `Agent(subagent_type=…)` call.

### When the user asks for a sibling tab

If the user asks for a brainstorm, audit, or other sibling activity that belongs in its own cmux tab, you open it yourself by running the relevant tab-opening skill (e.g. `/{{config.commandPrefix}}:brainstorm <issue>`). Do NOT tell the user to switch tabs and run the command manually — that is pushing coordination work back onto them. The tab-opening skill handles `cmux new-workspace` for you; your job is to invoke it.

Worked example (same wave, same day): the user asked for planning on issue #239 mid-wave. The orchestrator first replied "open a new cmux tab and run `/web:brainstorm 239`" — bouncing the request back. The correct action was to run the brainstorm skill directly and hand the user the new tab.

## Step 1: Load wave state

1. Parse `{ARGUMENT}` as `<wave-name>`.
2. Read `{{config.stateDir}}/waves/<wave-name>.json`. If missing, STOP — the wave was never started or was cleaned up.
3. Update `lead_session_id` to your current session ID (find it via Claude's session info).
4. Update `last_activity` to now.
5. Verify `pwd` matches the wave's `worktree` path. If not, `cd` to it.
6. Check the wave's `methodology` field (defaults to `"openspec"` if missing). If `"plan-file"`, verify `review_rubric_path` exists and is readable; if not, STOP with: `"Plan-file wave missing or unreadable review_rubric_path"`. The plan-file flow modifies Steps 3, 4, 5, 6, and 8 — see the subsection below.

### Plan-file wave flow (when `methodology: "plan-file"`)

If the wave is a docs-only / shared-meta change with a pre-authored plan as its spec, the normal OpenSpec flow (analyst proposes, decision gates, design.md + tasks.md as review rubric) does not apply — the plan file IS the proposal. Modified flow:

| Step | OpenSpec (default) | Plan-file |
|------|--------------------|-----------|
| 1-2  | same               | same      |
| 3    | spawn analyst → `/opsx:propose` | **skip** — plan file is the proposal |
| 4    | Decision Gate 1 (analyst questions) | **skip** — no analyst |
| 5    | `files_claimed` from `design.md` | `files_claimed` from the plan file's "Critical files" / "Files affected" section |
| 6    | Decision Gate 2 (proposal approval) | **skip** — plan was pre-approved when the wave was started |
| 7    | builder reads `design.md` + `tasks.md` | builder reads `review_rubric_path` as its design/tasks source |
| 7a-8a | review-cycle counter contract | **IDENTICAL** (cycle count, cap, escalation) |
| 8    | `/{{config.commandPrefix}}:review` | `/{{config.commandPrefix}}:review-plan-file` (consumer must author this sibling skill) |
| 9-15 | same               | same      |

All inline references to the spec (design.md, tasks.md) in subsequent steps should be read as "the wave's rubric — the plan file at `review_rubric_path` when methodology is plan-file, or `openspec/changes/<name>/{design,tasks}.md` otherwise." Each modified step below calls this out explicitly where it matters.

## Step 2: Verify prerequisites

1. Read each issue in the wave from GitHub:
   ```bash
   gh issue view <N> --repo {{config.repo}} --comments
   ```
2. **Worktree-sanity guard.** Before running any check, confirm the worktree is a usable environment, not a bare checkout. For each dependency manifest present in the worktree — `composer.json` ⇒ expect `vendor/`, `package.json` ⇒ expect `node_modules/`:
   - **Vendored dir is a symlink:** STOP regardless of config — a symlinked `vendor/`/`node_modules/` makes Composer's absolute-path autoloader resolve to the *main checkout's* code, so the suite runs against the wrong tree (FEEDBACK 2026-05-13 / issue #175). Report and halt.
   - **Vendored dir absent AND `{{config.bootstrapCommand}}` is set:** the planner's Step 5.5a bootstrap should have installed it and did not. STOP — report `worktree missing <dir> despite bootstrapCommand being set; planner Step 5.5a did not run or failed` and surface to the human via `AskUserQuestion`. A failed bootstrap usually means the project's repo-local git hooks are dead in this worktree too, so do not paper over it.
   - **Vendored dir absent AND `{{config.bootstrapCommand}}` is NOT set:** this consumer has not adopted worktree bootstrap. Emit the warning `worktree missing <dir>; project.json has no bootstrapCommand — the baseline check below will fail on missing deps, not on code`, then continue to the baseline check. The warning makes the failure legible; adding `bootstrapCommand` is the actual fix.
   - **A real, populated directory:** proceed.
3. Run `{{config.checkCommand}}` in the worktree, with `COMPOSER_PROCESS_TIMEOUT=0` exported:
   ```bash
   COMPOSER_PROCESS_TIMEOUT=0 {{config.checkCommand}}
   ```
   Composer's default 300s `process-timeout` kills a long child process (e.g. `php artisan test`) mid-run; the kill leaves tmp residue that induces phantom failures on the re-run (FEEDBACK 2026-05-21 / #278). Exporting `0` disables it — harmless for non-Composer consumers. An honest suite can legitimately take several minutes, so allow a generous Bash-tool timeout rather than letting a short tool timeout become the new kill.
   - **Passes:** proceed.
   - **Fails AND `fixes_checks` in the wave state JSON is empty/absent:** STOP — inherited-red CI. Append a blocker to `{{config.crossTabDir}}/planner.md` and surface to the human via `AskUserQuestion`; do not spawn teammates on a broken baseline.
   - **Fails AND `fixes_checks` is non-empty:** the wave was started with explicit intent to fix failing checks (see `wave-start-wave` Step 1 / Step 4). The baseline failure is expected. If `baseline_checkcommand` is not already recorded on the wave state JSON (start-wave should have recorded it), append it now. Proceed to Step 3. Step 10 (integrator) will re-run `{{config.checkCommand}}` and halt unconditionally if it still fails at integration time — `fixes_checks` does NOT tolerate post-fix failure.
4. Confirm `openspec/changes/` is current (it was rebased from main when the worktree was created).

## Step 3: Spawn the analyst teammate (requirements pass)

**Plan-file wave:** skip this step. The rubric at `review_rubric_path` is the proposal; there are no open questions for an analyst to surface. Jump to Step 5.

**OpenSpec wave:** Use Claude Code agent teams. Spawn an analyst teammate with the prompt:

```
You are the analyst for wave <wave-name>, issues <list>.

Run the /{{config.commandPrefix}}:analyst skill with arguments: <issue-numbers>

For each issue, identify open questions or ambiguity. If anything needs human input BEFORE writing proposals, output a QUESTIONS section listing them. Otherwise say "No open questions — ready to propose."

Report back when done.
```

Wait for the teammate to finish. Read their report.

## Step 4: Decision Gate 1 — answer questions or proceed

**Plan-file wave:** skip this step. No analyst, no questions. Jump to Step 5.

**OpenSpec wave:** If the analyst found open questions:
1. Use `AskUserQuestion` to present them to the human, one at a time.
2. Once answered, send the answers to the analyst teammate via the team mailbox:
   ```
   Use the answers below to produce OpenSpec proposals for the wave. Run /opsx:propose for each issue. Commit proposals to this branch.

   Answers: <paste here>
   ```
3. Wait for the analyst to complete proposals.

If no questions:
1. Send: "Run /opsx:propose for each issue in the wave. Commit proposals to this branch."
2. Wait for completion.

## Step 5: Update files_claimed in wave state

**Plan-file wave:** read `review_rubric_path` and extract the file list from its "Critical files" / "Files affected" / "Targets" section. If the plan lists files via heading + prose, scan for path-like tokens (e.g. `path/to/file.ext`). Commit via the same `jq` update below.

**OpenSpec wave:** After proposals exist, read each `openspec/changes/<change-name>/design.md` to extract the file list (look for "Files affected" or scan the design content). Update `{{config.stateDir}}/waves/<wave-name>.json`:

```json
{
  "files_claimed": ["<path-1>", "<path-2>", ...]
}
```

This is what other sessions check via `/wave:start-wave` Step 2 to detect file conflicts.

## Step 6: Decision Gate 2 — present proposals to human

**Plan-file wave:** skip this step. The plan file was pre-approved when it was authored and referenced at `/wave:start-wave` time — re-approving each bullet would be re-litigating the spec for no gain.

**OpenSpec wave:** Format the analyst's decision summary as a table and present it via `AskUserQuestion`:

```
| Issue | Decision | Detail |
|-------|----------|--------|
| #174 | Schema field | nhsReviewDate: z.coerce.date().optional() |
| #175 | Token | --color-primary: #082432 |
```

Ask: "Approve all? Approve some? Reject and revise?"

## Step 7: Spawn the builder teammate(s)

**Plan-file wave:** builder(s) receive the `review_rubric_path` instead of an `openspec/changes/<name>/` directory. The plan file's "Critical files" section defines scope; its "Verification" / "Acceptance" section defines the PASS criteria the builder must satisfy. The builder-routing lookup below still applies — use the plan file's "Category:" declaration or the issue label as the routing key. Skip sub-item 1b (no design.md) when resolving category.

For each approved issue, determine its category and route to the correct project-specific builder skill via `{{config.builderRouting}}`:

1. Look up the issue's category from one of these sources, in order:
   a. GitHub issue labels that match keys in `{{config.builderRouting}}` — label taxonomy is project-specific (some projects use an `area:*` namespace, others use domain names like `cms`, `content-model`, etc.)
   b. The issue's OpenSpec design.md (if it declares a category) — **skip for plan-file waves**
   c. The issue body's "Category:" line, if present, OR (for plan-file waves) the plan file's "Category:" declaration
2. Look up the category key in `{{config.builderRouting}}`. The value is the project-specific builder skill name.
3. The full builder invocation is `/{{config.commandPrefix}}:<builder-skill-name>`.
4. If the issue's category is NOT a key in `{{config.builderRouting}}`, present the situation via `AskUserQuestion`: which builder should handle this issue? List the available builderRouting keys as options plus an "other / specify" option. Halt until answered — never silently route to a default builder.
5. **Existence check (MANDATORY before spawn):** verify the resolved builder skill actually exists on disk at `.claude/skills/{{config.commandPrefix}}-<builder-skill-name>/SKILL.md`. If missing, halt with:
   ```
   Builder skill missing: .claude/skills/{{config.commandPrefix}}-<builder-skill-name>/SKILL.md
   - Expected because {{config.builderRouting}}.<category> = "<builder-skill-name>"
   - Options: (a) author the missing skill in this project, (b) update builderRouting to point at an existing skill, (c) reclassify the issue's category via AskUserQuestion.
   ```
   Use `AskUserQuestion` to offer those three options. Never spawn a teammate that will fail at its first Skill-tool call — the failure mode is opaque from the orchestrator's perspective. Fixes claude-tooling#2.

If multiple issues touch DIFFERENT files, spawn multiple builder teammates in parallel. If they touch the same files, sequence them.

### Builder contract

Parallel builders share one worktree, and git's working-tree surfaces — the index, `git stash`, untracked files — are NOT partitioned per agent: a builder that runs `git add -A`/`-u` or `git stash` sweeps up or hides a sibling's in-flight work (FEEDBACK 2026-05-14 findings 69/70; #139 finding 128). The spawn prompt below carries the four rules that prevent this and three other recurring builder failure modes. The rules MUST be in the prompt — the builder Agent never reads this skill.

The durable structural fix for the shared-worktree hazard — one `git worktree` per parallel builder, each with its own index and stash — is a deferred option recorded in `FEEDBACK.md` (2026-05-14, "per-builder sub-worktrees"). Until it lands, the spawn-prompt rules are the contract.

Spawn prompt:
```
You are a builder teammate for wave <wave-name>. Implement issue #<N>.

Run /{{config.commandPrefix}}:<builder-skill-name> <N>.

CONTRACT — these four rules are binding:

1. Shared worktree. You share this worktree with other builders. Stage ONLY
   your own files, by explicit path (`git add <path> ...`) — never `git add -A`,
   `-u`, or `.`. If `git status` or `git stash` shows files outside issue #<N>'s
   scope, they are a sibling builder's WIP: leave them alone, commit only yours.

2. Commit incrementally. Commit after each logical task-group, not once at the
   end — an API/socket failure mid-wave then costs one group, not the whole
   session, and a replacement builder resumes from `git log`. Every commit must
   leave the tests green.

3. Tick tasks.md. As you finish each task in the wave's tasks.md (or the plan
   file's task list), flip its checkbox `- [ ]` -> `- [x]` in the same commit as
   the work. This is the builder's job — not the reviewer's, not a later pass.

4. Attribution discipline. Before claiming any failing test is "pre-existing" or
   "not caused by my work", do all three: (a) run
   `git log --oneline $(git merge-base origin/main HEAD)..HEAD -- <test-path>` —
   if the test is listed, this wave introduced or touched it, so it is NOT
   pre-existing; (b) re-run the test in isolation on a clean tree; (c) check the
   env — a missing or symlinked vendor dir, or a stale build, is a likelier
   cause than a genuine pre-existing failure. Only after all three may
   "pre-existing" enter your report.

When done, message the reviewer teammate to review your work. Do NOT call
/{{config.commandPrefix}}:ship yet — the integrator handles that at the end of
the wave.

Report back when done or blocked.
```

## Step 7a: Initialise per-issue review state

Before spawning any reviewer, initialise per-issue review state in the wave file for
every issue that has entered (or is about to enter) review:

```bash
WAVE={{config.stateDir}}/waves/<wave-name>.json
for N in <issue-numbers>; do
  jq --arg n "$N" '.issues_state[$n] //= {"review_cycle_count": 0, "phase": "in_review"}' "$WAVE" > /tmp/wave.json && mv /tmp/wave.json "$WAVE"
done
```

This is idempotent — re-entering review never resets a non-zero count.

## Step 8: Spawn a fresh reviewer per builder-done event

Reviewer teammates are **one-shot Agent spawns, not persistent listeners.** The Agent tool terminates the spawned process after its first response. `SendMessage` to a terminated teammate's inbox succeeds at the tool layer but never resumes execution — the message is silently queued against a dead process. Do NOT rely on a long-lived reviewer that "keeps reviewing until all builders are done".

For each builder-done event, spawn a **fresh** reviewer Agent with the specific issue number and commit range in the briefing. The review skill differs by methodology (see Step 1's plan-file subsection):

- **OpenSpec wave:** reviewer runs `/{{config.commandPrefix}}:review <issue> <branch>` — compares against `design.md` + `tasks.md`.
- **Plan-file wave:** reviewer runs `/{{config.commandPrefix}}:review-plan-file <issue> <branch> <review_rubric_path>` — compares against the plan file's "Critical files" / "Verification" sections. Consumers MUST author this sibling skill; it shares the PASS/FAIL/BLOCK contract, review-cycle-counter, and worktree-hygiene checks with the OpenSpec reviewer but swaps Step 2 (OpenSpec artifact existence) for a rubric-file existence check and Step 6 for rubric-driven comparison.

Fresh-spawn prompt (one per review request):

```
You are the reviewer teammate for wave <wave-name>. Review issue #<N> on branch <branch>. Commit range to examine: <base-sha>..<head-sha>.

1. Run the appropriate review skill (see Step 8 of the lead's skill for OpenSpec vs plan-file variant)
2. Return a single verdict: PASS, FAIL, or BLOCK
3. On FAIL: include the cycle count and the specific failure payload — the orchestrator decides whether to route back to the builder or escalate
4. On BLOCK: include enough detail for the orchestrator to escalate to the human

This is a one-shot spawn. You will terminate after this response. If the builder re-submits, the orchestrator will spawn a new reviewer with the updated commit range.
```

Worked example (Acme Web, wave-239 admin-ia, 2026-04-20): Step 8 was originally drafted assuming a persistent reviewer subscribed to SendMessage. In practice the Agent terminated after its first PASS verdict and subsequent SendMessage calls were silently queued. Fresh-spawn-per-event was adopted as the workaround and worked reliably across the rest of the wave.

## Step 8a: Cap check and escalation routing

After receiving any FAIL verdict from the reviewer, read
`issues_state[<issue-number>].review_cycle_count` in the wave state JSON (the reviewer
has just incremented it in its own Step 5a).

- **If `review_cycle_count < 2`**: message the builder directly with the reviewer's
  FAIL payload and ask them to fix and re-submit. Continue monitoring.
- **If `review_cycle_count >= 2`**: invoke the escalation procedure below for this
  issue and do NOT spawn a builder for a third cycle. Other issues in the wave
  continue their loops unaffected.

### Escalation procedure

Perform these three steps in order. If any step throws, log the error under
`issues_state[<n>].escalation_errors` and continue to the next step — do not abort the
procedure:

1. **Update wave state**:
   ```bash
   WAVE={{config.stateDir}}/waves/<wave-name>.json
   jq --arg n "<issue-number>" '.issues_state[$n].phase = "escalated"' "$WAVE" > /tmp/wave.json && mv /tmp/wave.json "$WAVE"
   ```

2. **Post consolidated GitHub issue comment**. Build a summary file from both reviewer
   verdicts and any visual-fidelity report paths, then post:
   ```bash
   cat > /tmp/escalation-<N>.md <<'EOF'
   ## Review escalated after 2 cycles

   The review loop for this issue reached the 2-cycle cap. Both reviewer verdicts
   are summarised below. Human input required to decide whether to revise scope,
   reset the cycle count, or close the issue.

   ### Cycle 1 verdict
   <paste reviewer output>

   ### Cycle 2 verdict
   <paste reviewer output>

   ### Visual-fidelity report paths (project-specific; absent if project does not use visual fidelity)
   - {{config.stateDir}}/visual-diffs/<wave>/<route>/report.json
   - {{config.stateDir}}/visual-diffs/<wave>/<route>/prod-{375,768,1280}.png
   - {{config.stateDir}}/visual-diffs/<wave>/<route>/mockup-{375,768,1280}.png
   EOF
   gh issue comment <issue-number> --repo {{config.repo}} --body-file /tmp/escalation-<N>.md
   ```

3. **Append to the planner mailbox** (the planner tab watches all wave tabs in this project and surfaces blockers):
   ```bash
   cat >> {{config.crossTabDir}}/planner.md <<'EOF'

## $(date -u +%Y-%m-%dT%H:%M:%SZ) — escalation from wave <wave-name>
Issue #<N> escalated after 2 review cycles. See issue comment for both verdicts and remediation paths.
EOF
   ```

If step 2 fails (e.g. `gh` network error), append the error to
`issues_state[<n>].escalation_errors` and still attempt step 3. Likewise for step 3.

### Scope of escalation

One issue's escalation does NOT halt sibling issues. Continue monitoring the reviewer
for all other active issues in the wave. The wave as a whole only fails if every active
issue ends up in `escalated` or `failed`.

## Step 9: Monitor the team

While teammates work:
- Use `Shift+Down` to cycle through teammate sessions and check progress
- Watch the shared task list (`Ctrl+T` to toggle visibility)
- If the same builder hits FAIL → retry → FAIL → BLOCK pattern, escalate to human

**Do NOT** start implementing tasks yourself. If teammates are stuck, message them or spawn a replacement.

### Check the cross-tab mailbox (MANDATORY before each major step)

Before Steps 3, 5, 7, 8, 9b, 10, and each Decision Gate (4, 6, 12), check:

```bash
# Check both worktree-local and main-repo mailbox (the planner writes to main-repo paths)
for MAILBOX in "{{config.crossTabDir}}/wave-<wave-name>.md" "$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null | sed 's|/.git$||')/{{config.crossTabDir}}/wave-<wave-name>.md"; do
  if [ -s "$MAILBOX" ]; then cat "$MAILBOX"; mv "$MAILBOX" "${MAILBOX}.processed.$(date +%s)"; fi
done
```

If non-empty: read contents, incorporate any decisions or scope changes, and surface external alerts to human via `AskUserQuestion`. This is how the planner sends you messages — scope changes, stale warnings, skill updates. Skipping this check means you miss cross-tab communication.

### Keep `last_activity` fresh (EVENT-TRIGGERED, not timer-based)

You cannot set timers. Update `{{config.stateDir}}/waves/<wave-name>.json` `last_activity` to the current ISO-8601 timestamp on every one of these events (whichever happens first):

- **After spawning a teammate** (Step 3, 7, 8, 10, 12)
- **After receiving an idle notification** from a teammate
- **After a teammate reports PASS, FAIL, or BLOCK**
- **After running `AskUserQuestion` and receiving the answer** (all Decision Gates)
- **After transitioning between phases** (e.g. proposal → build → review → integrate)
- **After updating `files_claimed`** in Step 5

Use a single bash line:
```bash
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ) && jq --arg ts "$TS" '.last_activity = $ts' {{config.stateDir}}/waves/<wave-name>.json > /tmp/wave.json && mv /tmp/wave.json {{config.stateDir}}/waves/<wave-name>.json
```

The planner tab (`{{config.displayName}} Planner`) reads `last_activity` to detect idle waves on its monitoring loop. If you don't update it on real events, the planner will incorrectly flag your wave as idle and may surface it to the human. Keeping this field fresh is how you signal "I'm alive" to the meta layer.

## Attribution discipline

Any claim that a failure is "inherited", "pre-existing", or "not caused by this wave" — whether about CI, prod health, a flaky test, or any other red signal — must cite a **concrete verification step**, not an inference. Inferences like "we didn't touch those files" or "smoke checks are green so it must be pre-existing" are NOT verification. Record the verification artifact (SHA, URL, or captured output) on the wave state JSON before making the claim in any human-facing message, GitHub comment, or escalation mailbox entry.

Concrete verification examples:

- **CI red, claimed inherited:** re-run `{{config.checkCommand}}` at the branch-off SHA (`git merge-base main HEAD`) in a scratch worktree. Record the SHA and failing output. This is what Step 9a enforces for the CI path — the generalisation is that the same evidentiary bar applies to any other red signal.
- **Prod health degraded, claimed pre-existing:** probe a pre-merge artifact at the exact pre-wave state. For Cloudflare Workers, every deploy has a version-preview URL (`https://<version-id>-<service>.workers.dev/...`) that stays reachable after the newer version deploys — hit the old version's health endpoint directly and record the response body.
- **Flaky test, claimed intermittent:** re-run the test at least 3× at the branch-off SHA and record the pass/fail count.

Worked example (Acme Web, post-#302, 2026-04-20 → 2026-04-21): orchestrator claimed "inherited red migration" from PR #297 in a human-facing summary without citing a probe. User pushback found the claim was in fact correct but unearned — a 30-second hit of the pre-merge version-URL's `/api/health` would have proved it on the first assertion. The rule above makes that probe mandatory before the claim is made, not after pushback.

## Step 9a: Pre-integration CI classification

Before spawning the integrator, run `{{config.checkCommand}}` at the wave branch tip. This is a distinct check from Step 2's baseline — by now the team has committed their work, so a failure here is either a fresh regression OR an inherited failure the wave did not address.

1. Run `{{config.checkCommand}}` at the current wave branch tip, with `COMPOSER_PROCESS_TIMEOUT=0` exported (as in Step 2 — Composer's 300s child-process timeout must not kill an honest long suite).
2. **Passes:** proceed to Step 10. A local `{{config.checkCommand}}` pass is not itself a merge guarantee when CI runs a different environment than local — e.g. MySQL on CI vs SQLite locally, where a driver-specific failure is invisible to the local gate (FEEDBACK 2026-05-19 / #272). The Step 10 merge contract's pending-bucket CI poll is the authoritative gate; this local pass only decides whether to spawn the integrator.
3. **Fails:** classify by re-running `{{config.checkCommand}}` at the branch-off SHA (`git merge-base main HEAD`) in a scratch worktree or via `git stash` + detached checkout:
   - **Regression:** baseline at merge-base PASSED but current tip fails. The wave introduced the failure. Halt unconditionally — append the failing output as a blocker to `{{config.crossTabDir}}/planner.md` and surface to the human via `AskUserQuestion`. Do NOT spawn the integrator.
   - **Inherited red:** baseline at merge-base ALSO failed AND none of the wave's `files_claimed` overlap the failing check's surfaced file list. The red was pre-existing; the wave did not cause it. Record evidence on the wave state JSON:
     ```json
     "inherited_red_ci": {
       "check": "<name-or-command>",
       "first_failing_sha": "<branch-off sha>",
       "wave_touches_failing_files": false,
       "classified_at": "<ISO-8601>"
     }
     ```
     Then present via `AskUserQuestion`:
       1. **Admin-merge override** — proceed to Step 10 AND auto-file a closing-hotfix issue first (see "Closing-hotfix issue" below) so the override is traceable.
       2. **Halt and escalate** — full stop, no integration; append to `{{config.crossTabDir}}/planner.md` and surface to the human via `AskUserQuestion`.
       3. **File backlog ticket and halt** — `gh issue create` a follow-up ticket for the pre-existing red, then halt.

     Default = option 3. Never auto-override.
   - **Overlap:** baseline at merge-base failed BUT the wave's `files_claimed` include the failing check's files. Treat as regression — the wave touched the failing code path but did not fix it. Halt.

### Closing-hotfix issue (when option 1 fires)

When the human chooses "admin-merge override", BEFORE Step 10 spawns the integrator:

1. File a follow-up issue on `{{config.repo}}` with `gh issue create`:
   - **Title:** `{{config.overrideHotfixTitlePrefix}}` (defaults to `"hotfix: close override for"`), followed by the failing check name and the override PR number (visible in Step 10's output once the integrator creates the PR — capture it and amend the issue body if filed before the PR exists).
   - **Labels:** `{{config.overrideHotfixLabel}}` (defaults to `"hotfix-close-override"`).
   - **Body:** include the `inherited_red_ci` JSON block above, the override PR number, and an expected closing SLA (default: `"Close within 48h by landing a hotfix wave that makes {{config.checkCommand}} green."`).
2. Record the filed issue number on the wave state JSON as `override_closes_issue: <N>`.
3. The hotfix wave that ultimately closes that issue records the override → hotfix → retro triangle in its own retro-log entry so the audit trail is traversable in both directions.

**Configuration:** the two `{{config.overrideHotfix*}}` fields are optional. If absent from `project.json`, the skill uses the hardcoded defaults shown above. Consumers that want project-specific labelling (different label convention, different title prefix, different SLA language) set the fields; everyone else inherits the defaults with no config change.

## Step 9b: Local preview gate — let the human review changes via a localhost URL

**Purpose.** The wave is about to merge into `main`, which deploys to production. Before that happens, the human needs an opportunity to open the new code in a browser and look at it. This step starts the consumer's dev server inside the worktree, hands the human one or more `http://localhost:...` URLs, and waits for explicit approval before Step 10.

**Behaviour gate.** Read `{{config.localPreview}}` from `project.json`.

- **Absent or empty array:** skip this step entirely. Proceed to Step 10. Consumers without dev-server-driven review (or with an alternative review surface) do not block on a nonexistent preview.
- **Present:** for every entry in the array, start the server, wait for it to be ready, present the URLs, and wait for the human's answer.

**One entry per server.** Each entry has these fields (full schema in `claude-tooling/schemas/project.json.schema.json`):

```json
{
  "label": "Astro public site",
  "startCommand": "npm run dev -- --port 4321",
  "url": "http://localhost:4321",
  "readyProbe": "curl -sf http://localhost:4321",
  "readyTimeoutSec": 60
}
```

- `label` — short human-readable name shown in the gate prompt.
- `startCommand` — shell command run inside the worktree (cwd = the wave's worktree). May contain `cd` segments for monorepos (e.g. `cd payload && npm run dev`).
- `url` — the URL the human will click. Must match the port the start command actually binds — frameworks that auto-fall-back when the port is busy (Astro does this) will silently move off this URL, so always pin the port explicitly via the start command.
- `readyProbe` — shell command that exits 0 once the server is ready. Use `curl -sf` so non-2xx responses are treated as "not ready yet". Do NOT rely on stdout string matching — neither Astro nor Next.js documents a stable ready-line format.
- `readyTimeoutSec` — give up if the probe hasn't passed by then. 60s is fine for Astro; Payload (Next.js + Wrangler dev) often needs 90s on a cold start.

### 9b.1 Start every preview server in the background

For each entry:

```bash
# Allocate a per-entry log + pid file so cleanup can find them later.
LOG="/tmp/wave-preview-<wave-name>-<entry-index>.log"
PID="/tmp/wave-preview-<wave-name>-<entry-index>.pid"

# Run inside the worktree (the orchestrator's cwd is already the worktree).
nohup bash -c '<entry.startCommand>' > "$LOG" 2>&1 &
echo $! > "$PID"
```

Use the `Bash` tool with `run_in_background: true` so the orchestrator session keeps moving while the dev server boots. Capture the bash session id returned by `run_in_background` — that's how this step kills the process at the end of the gate.

If `nohup` is unavailable on the host (rare — POSIX), fall back to a plain `&` backgrounded subshell. Either path must result in a writable PID file so 9b.4 can stop the server.

### 9b.2 Wait for each server to become ready

For each entry, poll the `readyProbe` every 2 seconds, capping at `readyTimeoutSec`:

```bash
DEADLINE=$(( $(date +%s) + <entry.readyTimeoutSec> ))
until <entry.readyProbe>; do
  if [ "$(date +%s)" -ge "$DEADLINE" ]; then
    echo "Preview '<entry.label>' did not become ready within <entry.readyTimeoutSec>s." >&2
    echo "Last 40 log lines:" >&2
    tail -40 "$LOG" >&2
    exit 1
  fi
  sleep 2
done
```

Run all probes in sequence (not parallel) — if the first server fails to start, don't waste time waiting on the rest.

If any probe times out:

1. Run the cleanup in 9b.4 to kill any preview processes already started.
2. Surface the failure to the human via `AskUserQuestion`:
   - **Investigate** — halt the wave, leave the worktree intact, the human inspects the log file (path included in the question text). Do NOT proceed to Step 10.
   - **Skip the preview gate this once** — proceed directly to Step 10 without preview. Record the skip on the wave state JSON: `local_preview_skipped: { reason: "ready_probe_timeout", entry: "<label>", at: "<ISO>" }`. This is the escape hatch for genuine local-env breakage; the cost is the wave merges without a preview review.
   - **Default = Investigate.** Never auto-skip.

### 9b.3 Decision gate — present URLs to the human

When all entries are ready, build the gate prompt and call `AskUserQuestion`:

```
The wave is ready to merge. Open each URL below, click around, and confirm
the changes look right before merging to main.

Wave: <wave-name>
Branch: <wave-branch>
Files changed: <count> (full list: git diff --stat main..HEAD)
Issues in this wave: <list with titles>

Preview URLs:
  • Astro public site: http://localhost:4321
  • Payload admin:     http://localhost:3000

How does it look?
  ▢ Approve — merge to main
  ▢ Halt — something looks wrong, don't merge
```

Concrete `AskUserQuestion` shape (single question, two options — never multi-select):

- Question: `"Preview ready. Approve merge to main?"`
- Options:
  1. `"Approve — merge to main"` (description: "Looks right; proceed to integrator")
  2. `"Halt — something looks wrong"` (description: "Stop here. The wave stays in its current state; nothing is merged. Re-run the orchestrator after fixes are pushed.")

Do not add a third "skip preview" option here — the human has already seen the URL; if they got this far the only meaningful choices are approve or halt. The skip option exists in 9b.2 only because the gate itself failed.

### 9b.4 Cleanup — always kill the preview processes

After the human answers (either way), and also on any failure path in 9b.1 or 9b.2, kill every preview process started in this step:

```bash
for PID_FILE in /tmp/wave-preview-<wave-name>-*.pid; do
  [ -f "$PID_FILE" ] || continue
  PID=$(cat "$PID_FILE")
  if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
    # SIGTERM first; some dev servers spawn child processes (Next.js does)
    # that ignore SIGINT. SIGKILL after 3s if still alive.
    kill -TERM "$PID" 2>/dev/null
    for _ in 1 2 3; do
      kill -0 "$PID" 2>/dev/null || break
      sleep 1
    done
    kill -KILL "$PID" 2>/dev/null || true
  fi
  rm -f "$PID_FILE"
done
```

Leftover dev servers bind ports and break the next wave's preview gate, so this cleanup is mandatory — run it in a `trap EXIT` (or its `Bash` tool equivalent) so it fires even if the orchestrator's session dies mid-gate.

### 9b.5 Routing on the answer

- **Approve** — record the approval on the wave state JSON, then proceed to Step 10:
  ```bash
  TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  jq --arg ts "$TS" '.local_preview_approved_at = $ts' \
    {{config.stateDir}}/waves/<wave-name>.json > /tmp/wave.json && \
    mv /tmp/wave.json {{config.stateDir}}/waves/<wave-name>.json
  ```
- **Halt** — record the halt and stop:
  ```bash
  TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  jq --arg ts "$TS" '.local_preview_halted_at = $ts | .phase = "halted_at_preview"' \
    {{config.stateDir}}/waves/<wave-name>.json > /tmp/wave.json && \
    mv /tmp/wave.json {{config.stateDir}}/waves/<wave-name>.json
  ```
  Do NOT spawn the integrator. Do NOT remove the worktree. Append a one-line note to `{{config.crossTabDir}}/planner.md` so a later planner sweep can re-surface the wave. The human's halt reason often surfaces a follow-up issue — the orchestrator does not file that issue automatically; the human's next message decides whether to amend, abandon, or escalate.

### 9b.6 What this step deliberately does NOT do

- **Does not** run a smoke-test script or assert anything programmatically. The human is the test.
- **Does not** deploy to a cloud preview environment. The worktree dev server is the preview surface. Cloud preview URLs (Cloudflare version-preview, Vercel previews) remain useful for verifying *production* state — Step 9b is the *pre-merge* gate.
- **Does not** isolate database state. If the consumer's dev server writes to a shared dev database (or worse, the production database), the gate will reflect that. Document this in the consumer's `project.json` or `CLAUDE.md` if relevant; do not try to solve it inside this step.
- **Does not** support concurrent waves running preview servers. Two waves in flight with overlapping ports will collide on `9b.1`. Until a wave-aware port-allocator exists, run preview gates one at a time.

### 9b.7 Worked example (acme-web)

```
Wave: wave-2026-04-29-product-detail
Branch: wave-2026-04-29-product-detail
Files changed: 7
Issues: #401 (add spec table to /products/[slug])
        #402 (homepage hero copy refresh)

Preview URLs:
  • Astro public site: http://localhost:4321
  • Payload admin:     http://localhost:3000/admin

How does it look?
  [Approve — merge to main]   [Halt — something looks wrong]
```

The human opens both URLs, clicks through `/products/example-item` and the homepage on Astro, opens `/admin → Products` on Payload to see if the new spec field appears in the editor. Two minutes of clicking, then Approve. Step 10 spawns the integrator. Cleanup in 9b.4 kills both servers.

## Step 10: Spawn the integrator teammate

When ALL builders are done and reviewer has marked them PASS:

```
You are the integrator teammate for wave <wave-name>. The wave's branches are ready to merge into main.

Run /{{config.commandPrefix}}:integrate with the branches in dependency order: <list>

After successful integration, run /{{config.commandPrefix}}:ship to push and monitor deploy.

You MUST follow the merge contract below — see "Merge contract" subsection. Never use `gh pr merge --auto`; always wait until every CI check has finished and passed (pending bucket empty, no fail/cancel bucket entries) before calling `gh pr merge`.

Report back when merged and deployed (or if a merge conflict needs human input).
```

### Merge contract (binding on every consumer's integrate skill)

This contract lives in the shared layer because every consumer that authors a `/{{config.commandPrefix}}:integrate` skill is exposed to the same failure mode. It is not optional; it is the precondition for letting the integrator teammate merge anything to `main`.

**Why this exists.** `gh pr merge --auto` only blocks merging when GitHub's branch-protection has required status checks configured. Branch protection on `main` requires GitHub Pro or higher for **private** repositories — Free-plan private repos cannot configure required checks. With no required checks, `--auto` short-circuits to an immediate merge — the API call returns "merged" before CI has even started. Three wave PRs shipped this way in Acme Web on 2026-04-22 (FEEDBACK retro finding #90); the safety net the skill assumed existed did not exist.

**The contract — every consumer integrate skill MUST implement these three steps in order:**

1. **Confirm the PR has CI checks attached** before waiting on them. A PR with zero attached checks means CI workflows are paused, mis-configured, or the branch was filtered out — merging on zero-checks IS the silent-merge failure mode. Halt and surface to the orchestrator.

   ```bash
   CHECK_COUNT=$(gh pr checks <PR-number> --repo <owner/repo> --json state | jq 'length')
   [ "$CHECK_COUNT" -gt 0 ] || { echo "FATAL: PR has zero attached checks" >&2; exit 1; }
   ```

2. **Wait for CI to pass** by polling the explicit bucket counts. Do NOT use `gh pr checks --watch --fail-fast` — it silently exits 0 on the first FINISHED check rather than the last, leaving pending checks unresolved when the merge step fires (confirmed by repeated repros — unmerged red checks would otherwise ship on the back of a falsely-green watch). The contract is "pending bucket == 0 AND fail/cancel buckets == 0", not "watch returned":

   ```bash
   until [ "$(gh pr checks <PR-number> --repo <owner/repo> --json bucket --jq '[.[] | select(.bucket=="pending")] | length')" = "0" ]; do
     sleep 30
   done
   FAILED=$(gh pr checks <PR-number> --repo <owner/repo> --json bucket --jq '[.[] | select(.bucket=="fail" or .bucket=="cancel")] | length')
   [ "$FAILED" = "0" ] || { echo "FATAL: CI failed ($FAILED check(s) in fail/cancel bucket)" >&2; exit 1; }
   ```

   The loop is a short-poll (30s) rather than `--watch` because `--watch`'s long-lived HTTP stream both drops on network blips AND has the silent-exit-0 bug above. Each `gh pr checks --json bucket` call is a stateless one-shot — no stream to lose, no premature-exit surprise. The trade-off (a few extra API calls per merge) is negligible against an unverified merge.

3. **Merge explicitly only after checks pass.** Use `--merge`, `--squash`, or `--rebase` per the consumer's preference, but NEVER `--auto`.

   ```bash
   gh pr merge <PR-number> --repo <owner/repo> --merge --delete-branch
   ```

**Known-transient `gh` failure modes (do NOT escalate to `--admin` or `--no-verify`).** An unrelated PR can land on `main` between step 2 finishing and step 3 firing. The failure looks alarming but is a benign race:

| Failure | What actually happened | Correct response |
|---|---|---|
| `gh pr merge` fails with `Base branch was modified — review and try the merge again` | An unrelated commit landed on `main` between step 2 finishing and step 3 firing | Re-read `mergeStateStatus` via `gh pr view <N> --json mergeStateStatus --jq .mergeStateStatus`; if `CLEAN` or `MERGEABLE`, re-issue the same `gh pr merge` command — the second attempt almost always wins. Do NOT pass `--admin`, `--no-verify`, or force-push |

If after one retry the merge still fails, surface to the orchestrator with the full error — that's a real conflict, not a race. The failure message reads like a merge conflict, so a less-disciplined session might pattern-match it as needing override.

**Forbidden flags.** `--auto` MUST NOT appear in any consumer integrate skill. `--admin` and `--no-verify` MUST NOT be used to paper over the transient races above. If a consumer's project gains GitHub Pro and configures branch-protection required checks, `--auto` becomes safe again — but adopting it requires an explicit shared-skill amendment with the project's protection config recorded in `project.json`. Until then, the contract above is the only correct path.

**Variant: integrator running directly to `main`.** If a consumer's integrate flow pushes directly to `main` rather than via a PR (no `gh pr merge` at all), the contract is satisfied trivially — the push itself triggers CI, and there's no merge command to gate. Add a post-push `gh run watch --exit-status` step instead.

**Worked examples.** Both `acme-web/.claude/skills/web-integrate/SKILL.md` (Step 5) and `acme-app/.claude/skills/app-integrate/SKILL.md` (Step 5) implement this contract today. New consumer projects authoring their first integrate skill should copy that shape.

### Follow-up PR contract (binding on every consumer's integrate skill)

This contract sits alongside the merge contract above and addresses a different failure mode: **the integrator skips the reviewer teammate on follow-up PRs** filed to green a red `main`. Recorded 4+ times in consumer retros before being codified per-consumer. Skipping review under pressure is never the shortest path — it just defers the bug into a future cleanup wave.

**The contract — every consumer integrate skill MUST implement these rules:**

1. **Every follow-up PR goes through the reviewer teammate.** Whenever the integrator files a PR to fix a red `main` (CI failure on merge commit, post-deploy smoke failure, prod regression), it MUST spawn the reviewer via the same `Agent(subagent_type=…)` mechanism the orchestrator uses for primary-wave review BEFORE merging. Announce the spawn in the orchestrator mailbox so the lead can see review is in flight.

2. **Fast-track carve-out — all four conditions must hold, no exceptions.** A follow-up PR may merge without a reviewer spawn ONLY if every one of these is true; if even one fails, spawn the reviewer.

   | # | Condition | How to check |
   |---|---|---|
   | 1 | PR diff is **<50 LoC** | `gh pr diff <N> \| grep -E '^[+-]' \| grep -vE '^[+-]{3}' \| wc -l` |
   | 2 | Changes are **CI/config only** — no runtime code, no schema, no migration, no business-domain file | manual judgement against `gh pr diff <N> --name-only` |
   | 3 | No schema or migration path touched (consumer-specific path list) | `gh pr diff <N> --name-only` against the consumer's schema/migration directory list |
   | 4 | Touches **only** the files surfaced by the failing CI job | cite the failing-job output paths in the PR body |

   Consumer integrate skills MUST instantiate condition #3 with their own schema/migration paths (e.g. `payload/migrations/`, `payload/src/collections/`, `database/migrations/`, `app/Filament/Resources/`). The shared contract binds the rule; the consumer skill names the files.

3. **Carve-out justification recorded.** When the carve-out applies, the commit body MUST include:

   ```
   fast-track-carveout:
     failing-check: <check-name>
     loc: <N>
     scope: ci-only
     files: <exact file list from failing check>
   ```

   This makes the carve-out auditable — every retro can scan commits for this stanza to verify the carve-out was warranted.

4. **Concurrent-review optimisation (optional but recommended).** The orchestrator may spawn the reviewer teammate CONCURRENTLY with the merge contract's CI-wait poll loop (step 2). By the time CI finishes, review has also finished — review never adds latency, so the pressure to skip review evaporates. This is the structural fix; the carve-out above is the safety valve when concurrent review isn't wired up yet.

**Worked examples.** `acme-web/.claude/skills/web-integrate/SKILL.md` Step 5c and `acme-app/.claude/skills/app-integrate/SKILL.md` Step 5a both implement this contract. New consumers should mirror that shape, with condition #3's path list adapted to their schema/migration locations.

**Why both contracts live in this skill, not the integrate skill.** The integrate skill is per-consumer and gets re-authored in every new project. Putting both contracts in the shared `wave-orchestrate` makes them precondition-of-existence — a new consumer's integrate skill that doesn't honour these contracts is broken by construction, not by oversight.

## Step 11: Update wave state to completed (UNCONDITIONAL)

**This step runs IMMEDIATELY after the integrator reports success — before any human gate, archive, or retro.** Even if the session crashes after this point, the state file reflects reality.

1. Find the PR number from the integrator's report (or via `gh pr list --repo {{config.repo}} --state merged --head <wave-branch> --json number,mergedAt --limit 1`).
2. Update `{{config.stateDir}}/waves/<wave-name>.json`:
   ```bash
   TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
   jq --arg ts "$TS" --arg pr "<PR-number>" \
     '.phase = "completed" | .last_activity = $ts | .completed_at = $ts | .merged_pr = ($pr | tonumber)' \
     {{config.stateDir}}/waves/<wave-name>.json > /tmp/wave.json && mv /tmp/wave.json {{config.stateDir}}/waves/<wave-name>.json
   ```
3. Update `{{config.waveStatusFile}}` (UNCONDITIONAL — this is the legacy single-wave aggregate state that start-wave reads):
   ```bash
   ISSUES='[<comma-separated issue numbers>]'  # e.g. '[217,218]'
   jq --argjson issues "$ISSUES" --arg wave "<wave-name>" \
     '.completedIssues = ((.completedIssues + $issues) | unique | sort)
      | .inProgressIssues = ((.inProgressIssues // []) - $issues)
      | .activeWorktrees = ((.activeWorktrees // {}) | del(.[$wave]))
      | .activePRs = ((.activePRs // []) - [<PR-number>])
      | .lastUpdated = (now | todateiso8601)' \
     {{config.waveStatusFile}} > /tmp/status.json && mv /tmp/status.json {{config.waveStatusFile}}
   ```
   Verify with `jq '.completedIssues | length, .lastUpdated' {{config.waveStatusFile}}` before moving on. If any issue number didn't land in `completedIssues`, fix it before Step 12 — a stale wave-status file causes start-wave to re-suggest closed issues.

If the integrator FAILS (merge conflict, build break), update phase to `"failed"` with an `error` field describing what went wrong.

## Step 12: Final gate — present results to human

When the integrator is done:

1. Show the merge summary, build status, deploy status.
2. Use `AskUserQuestion`: "Wave complete. Approve to archive OpenSpec changes?"
3. On approval, run `/opsx:archive` for each completed change.

## Step 14: Spawn the retro teammate (background)

```
You are the retro teammate for wave <wave-name>. For each issue in the wave, run /wave-retro <issue>. Append findings to {{config.retroLog}}. Propose any skill fixes as diffs for human review (do not auto-apply).
```

This runs in background while the wave session winds down.

## Step 15: Clean up the wave

Phase is already `"completed"` from Step 11. This step handles physical cleanup.

**MANDATORY: use `AskUserQuestion`, not prose.** Do NOT output free-text summaries like "ready to close or idle" or "switch to the new tab when you want" and then wait for the human to prompt. The AskUserQuestion tool is the cleanup prompt; it is not optional and not replaceable with a text message. If you find yourself typing "this tab is done" or "your choice", stop — that is the anti-pattern.

Worked example (wave-208cde, 2026-04-14): orchestrator reported wave-closed, told the user their new work was in workspace:69, then wrote "This tab is done — ready to close or idle" and waited. The user had to prompt "what shall i do with this tab?" before cleanup began. Correct action was a single `AskUserQuestion` the moment Step 14 returned.

1. Invoke `AskUserQuestion` with: "Wave complete. Remove the worktree and close this tab?" (options: yes / keep worktree, close tab / keep both)
2. On yes — **pre-cleanup checklist (per finding 41 from Acme Web wave-a-admin-polish):**
   - **Confirm no background subagents are still running that depend on the worktree cwd.** Use `TaskList` (or equivalent) to check. If any are alive, wait or stop them — never remove the worktree out from under them.
   - **`cd` BEFORE removing the worktree.** Detect the main checkout: `MAIN_CHECKOUT=$(git rev-parse --path-format=absolute --git-common-dir | sed 's|/.git$||')` then `cd "$MAIN_CHECKOUT"`. If you remove the worktree first, your own shell ends up in a deleted cwd and every subsequent Bash call errors with `Working directory "..." no longer exists` — including any reactive follow-up subagent the user might ask you to spawn.
   - **Warn the user:** "Worktree removal is irreversible. Any follow-up verification (admin-persona screen check, manual smoke test, etc.) must be spawned AFTER cleanup from the main checkout, not from this worktree. If you might want one, ask now."
3. Then:
   - `git worktree remove .worktrees/<wave-name>`
   - Delete `{{config.stateDir}}/waves/<wave-name>.json`
   - Close the cmux workspace

### Self-reflexivity hint (waves that modify tooling or launchers)

If this wave removed, renamed, or changed the location of a file referenced by another tool (e.g. `launch.sh` referencing a `SKILL.md` path, a CI workflow referencing a script, a cron referencing a state file), **update the referencing tool FIRST, then remove the referenced file**. Opposite order creates a window where `./launch.sh` or CI fails opaquely on the missing file before the reference-updater commit lands. The integrator should sequence commits explicitly; the orchestrator should surface the sequencing requirement in Decision Gate 2 so the human can sign off. See `shared-wave-skills` (issue #232 in Acme Web) Phase D for a worked example.

## Conflict prevention rules

1. **Two builders never touch the same file.** Sequence within the wave if needed.
2. **Schema changes merge first** (other code depends on them).
3. **Data helpers second.**
4. **Page templates third.**
5. **SEO/meta last.**

The integrator enforces this order.

## Communication channels

- **Terminal in this session** — status updates and decision gates only
- **GitHub Issues** — post decisions and findings as comments via `gh issue comment`
- **Team mailbox** — direct messages to teammates (this is how you talk to builders/reviewers)
- **Shared task list** — track wave progress, visible to all teammates

## When to escalate to human

- Reviewer marks BLOCK (architectural problem, security issue)
- Same builder fails review twice (max 1 retry, then escalate)
- Integrator hits a non-trivial merge conflict
- Any teammate sends an `AskUserQuestion` upward
- Wave runs longer than expected (>4 hours)

## Boundaries

- Do NOT use `Edit`, `Write`, or `MultiEdit` tools yourself — delegate to teammates
- Do NOT read more than 1 file in the project source tree to understand an issue — spawn an analyst instead
- Do NOT run `/{{config.commandPrefix}}:ship` yourself — the integrator handles deployment as part of Step 10
- Do NOT skip OpenSpec — every issue must go through `/opsx:propose` before building
