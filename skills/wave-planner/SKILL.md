---
description: Portfolio + launcher + live-wave sweep in one skill. Reads .claude/project.json for per-project configuration. On-demand, invoked from any shell in a consumer project. Reconciles wave-status.json (sole writer), surveys active waves, surfaces new feedback + drift + mailbox, suggests the next wave, and launches it end-to-end (branch + worktree + cmux tab + orchestrator boot). No persistent tab, no /loop.
argument-hint: (no args — or "<wave-name> <issue-numbers> [fixes:<checks>]" to skip suggest-and-launch a specific wave directly)
---

# Planner

## Configuration

This skill reads project-specific values from `.claude/project.json` at the current working directory.

**Before doing anything else:**

1. Locate `.claude/project.json` (relative to cwd). If missing, STOP and report:
   `".claude/project.json not found — shared wave skills require per-project configuration. See claude-tooling/README.md."`
2. Treat every `{{config.<key>}}` token in this skill body as that value from `project.json`. Nested keys use dot notation (e.g. `{{config.repo}}`).
3. If any `{{config.<key>}}` referencing a **required** key (per the JSON schema) cannot be resolved, STOP and report the missing path by name. Tokens referencing **optional** keys (e.g. `{{config.prodHealthProbe}}` and its sub-fields) evaluate to "not configured" when absent — behaviour guarded on those tokens is skipped rather than halted.
4. If `schemaVersion` in `project.json` is below the schema's `minimumSchemaVersion`, STOP with: `"project.json schemaVersion N is below minimum M required by claude-tooling. See claude-tooling/MIGRATIONS.md."`

This preamble is identical across all `wave-*` skills.

## Role

The planner is the **one front door per project**. Every invocation runs the same six phases, regardless of whether you want to launch a new wave, check on in-flight ones, or just see what needs attention:

```
/wave-planner     (per-project, on-demand, any shell — no persistent tab)
       ↓ launches directly via cmux new-workspace
/wave-orchestrate (per-wave, auto-loaded inside the spawned tab)
       ↓ post-merge
/wave-retro       (per-project, on-demand)
```

There is no separate `start-wave` skill — the launch mechanics are Phase 5 of this skill. There is no separate `toolsmith` skill — shared-skill maintenance happens in `~/Dev/claude-tooling` directly, guided by `CONTRIBUTING.md`.

## Invocation model

**On-demand. Not persistent. No `/loop`.** Invoke from any Claude Code session whose cwd is under a consumer project. Every invocation runs Phases 1–3 unconditionally, then presents a gate (Phase 4) that lets you exit cleanly if nothing needs launching.

Parallel waves still live in cmux tabs via `/wave-orchestrate`. The planner is stateless between invocations — every run reads fresh state, reports current reality, and exits when there's no more decision to make.

### Argument modes

| Args | Behaviour |
|---|---|
| No args | Full Phase 1→4 flow. Phase 4 presents a suggestion via `AskUserQuestion`; on accept, Phase 5 launches. |
| `<wave-name> <issue-numbers> [fixes:<checks>]` | Skip Phase 4's suggest step and go straight to Phase 5 with the provided args. Phases 1–3 still run first (sweep + heal + surface) so you see current state before launching. |

The explicit-args path replaces what was `/wave:start-wave <name> <issues>` in the five-skill era. Use it when you've already picked the wave (e.g. from the backlog) and just want to launch.

## Scope: own repo only

Every `cmux` call this skill makes is filtered to workspaces whose cwd is under this project's main checkout or its `.worktrees/` subtree. The planner never reads tabs from other projects. `cmux list-workspaces --json` returns `{window_ref, workspaces: [...]}` where each workspace exposes `ref` (e.g. `"workspace:4"`), `current_directory`, and `index`. Filter on `.workspaces[] | .current_directory`:

```bash
MAIN_CHECKOUT=$(git rev-parse --path-format=absolute --show-toplevel)
cmux list-workspaces --json | jq --arg prefix "$MAIN_CHECKOUT" \
  '[.workspaces[] | select((.current_directory | ascii_downcase) | startswith($prefix | ascii_downcase))]'
```

The `ascii_downcase` on both sides is for macOS — the filesystem is case-insensitive, but `cmux` records the cwd as the user typed it (often `~/dev/...`) while `git rev-parse --show-toplevel` returns the canonical case (often `~/Dev/...`). Without the downcase normalisation, `startswith()` returns false and the filter silently produces an empty list — the same failure mode this filter was rewritten to fix. On Linux the downcase is a harmless no-op against case-sensitive paths.

**Sanity-check the filter.** If the filtered result is empty AND your cwd is inside `$MAIN_CHECKOUT` (the planner was invoked from this project), the filter is misbehaving — likely a schema drift in `cmux list-workspaces --json`. Warn and continue rather than silently proceeding as if no own-repo workspaces exist: an empty result is supposed to mean "no waves running", but a broken filter would also produce an empty result and quietly turn every own-repo guard into a no-op (FEEDBACK 2026-05-26 / planner session — the previous `.[] | .cwd` filter silently produced this exact failure mode for weeks).

## What the planner owns

- `{{config.waveStatusFile}}` — **sole writer**. Phase 2 reconciliation is the only place this file is written.
- Backlog pruning and priority evaluation
- Live-wave sweep: per-wave JSON vs GitHub PR vs cmux workspace cross-reference
- Launch mechanics: args validation, conflict check, atomic claim, verify-main, worktree, state-dir symlink, cmux tab spawn, orchestrator boot prompt
- Drift check against `~/Dev/claude-tooling` and surfacing of `FEEDBACK.md` delta
- Amendment-vs-new-wave routing on production regressions

## What the planner does NOT own

- In-wave coordination — `/wave-orchestrate` handles that
- Post-merge analysis — `/wave-retro` handles that
- Shared-skill edits — that's a normal git workflow in `~/Dev/claude-tooling` (see CONTRIBUTING.md)
- Application code, OpenSpec proposals, code review — all in-wave concerns
- Reading or interacting with tabs in other projects
- **Decision-ledger ID allocation** — `D-NNN` IDs in `{{config.decisionLedger}}` are allocated by the consumer's brainstorm/analyst skills, not the planner. Those skills MUST follow the reserve → write → release protocol in [`claude-tooling/docs/ledger-reservation-contract.md`](../../docs/ledger-reservation-contract.md) to prevent parallel-brainstorm collisions (FEEDBACK 2026-04-22 / 2026-04-24 — three waves collided on the same `D-NNN` slots in a four-hour window before the protocol was authored).

## The six phases

Each invocation runs these in order. Phases 1–3 are silent if there's nothing to report.

| Phase | Purpose | Reads | Writes | Human input? |
|---|---|---|---|---|
| 1. Read-only sweep | Enumerate active waves; cross-reference each with GitHub PRs and cmux workspace state; probe prod health if configured | `{{config.stateDir}}/waves/*.json`, `cmux list-workspaces`, `cmux read-screen --lines 30`, `gh pr list`, `gh issue list`, `{{config.prodHealthProbe.url}}` (if set) | None | None |
| 2. Auto-heal | Reconcile state with reality | (outputs of Phase 1) | `{{config.waveStatusFile}}`, per-wave JSON `phase: "completed"` + `merged_pr` where applicable | None — heals silently, reports delta |
| 3. Human-surface | Flag attention-worthy signals before planning (prod-health BLOCKER first when configured + failing) | `{{config.crossTabDir}}/planner.md`, `~/Dev/claude-tooling/FEEDBACK.md` + seen-sentinel, drift check, Phase 1 probe result | Archive processed mailbox messages; update seen-sentinel | Report-only |
| 4. Plan + present | Build suggestion (or accept explicit args); present via `AskUserQuestion` — amendment routing mandatory when prod degraded | Open issues, active wave claims, retro log, Phase 1 probe result | None yet | Gate 1 |
| 5. Launch | Conflict + prod-health re-check, atomic claim, verify-main + checkCommand, create worktree, seed state symlink, cmux new-workspace with orchestrator prompt, update state | Same as five-skill-era start-wave + probe re-read | Per-wave JSON, cmux workspace, worktree | Gate 2 (file conflict, broken main, or degraded prod on non-`fix-` wave) |
| 6. Session handoff | Record session-local context for the next invocation | This session's actions | `{{config.crossTabDir}}/planner.md` (gated — nothing written on an idle session) | None |

### Phase 1 — read-only sweep

For each file in `{{config.stateDir}}/waves/*.json`:

1. Read the JSON. Extract `name`, `issues[]`, `phase`, `cmux_workspace_id`, `worktree`, `last_activity`, `files_claimed[]`, `merged_pr`.
2. **Cmux cross-reference** (own-repo filter). `WORKSPACE_ID` is the value stored in the wave JSON's `cmux_workspace_id` field — it MUST be the full ref string `"workspace:N"` (see Phase 5.8). Filter on `.ref` (not `.id`) and `.current_directory` (not `.cwd`):
   ```bash
   cmux list-workspaces --json | jq --arg id "$WORKSPACE_ID" --arg prefix "$MAIN_CHECKOUT" \
     '[.workspaces[] | select(.ref == $id) | select((.current_directory | ascii_downcase) | startswith($prefix | ascii_downcase))]'
   ```
   Empty result means the workspace is gone or outside this project. If present, run:
   ```bash
   cmux read-screen --workspace "$WORKSPACE_ID" --lines 30
   ```
   Capture the screen output for Phase 2 idle detection. If `WORKSPACE_ID` is a bare number (e.g. `"4"`) rather than the ref form, `read-screen` will fail with `Error: Workspace index not found` and stall detection will be silently dead for that wave (FEEDBACK 2026-05-26) — fail loud and surface the wave JSON for repair instead of treating the error as "no signal".
3. **GitHub cross-reference:**
   ```bash
   gh pr list --repo {{config.repo}} --state merged --head <wave-branch> --json number,mergedAt --limit 1
   ```

4. **Prod health probe (if configured).** Read the probe config from `.claude/project.json` via `jq -r` into shell variables so no template-substituted value is re-interpreted by the shell (the jq expression commonly contains quotes and would break literal substitution):
   ```bash
   PROBE_URL=$(jq -r '.prodHealthProbe.url // empty' .claude/project.json)
   PROBE_EXPR=$(jq -r '.prodHealthProbe.healthyJqExpr // empty' .claude/project.json)
   if [ -n "$PROBE_URL" ] && [ -n "$PROBE_EXPR" ]; then
     # Initialize all recorded fields so classification doesn't read stale or unset values on partial paths
     PROBE_BODY=""
     PROBE_CURL_ERR=""
     PROBE_JQ_EXIT=""
     PROBE_JQ_ERR=""
     PROBE_BODY=$(curl -fsS --max-time 10 "$PROBE_URL" 2>/tmp/probe.err)
     PROBE_CURL_EXIT=$?
     PROBE_CURL_ERR=$(cat /tmp/probe.err 2>/dev/null)
     if [ $PROBE_CURL_EXIT -eq 0 ]; then
       # Separate assertion-false (exit 1, empty stderr) from parse/compile errors (non-zero exit, non-empty stderr)
       printf '%s' "$PROBE_BODY" | jq -e "$PROBE_EXPR" >/dev/null 2>/tmp/jq.err
       PROBE_JQ_EXIT=$?
       PROBE_JQ_ERR=$(cat /tmp/jq.err 2>/dev/null)
     fi
     PROBE_BODY_DISPLAY=$(printf '%s' "$PROBE_BODY" | head -c 2048)
     PROBE_BODY_BYTES=$(printf '%s' "$PROBE_BODY" | wc -c)
   fi
   ```
   Capture `{probed: true, url, curl_exit, curl_err, jq_exit, jq_err, body_display, body_bytes}` for Phases 3 and 5. Classification:
   - **Passing:** `curl_exit == 0 AND jq_exit == 0` (expression returned truthy).
   - **Failing — network/HTTP:** `curl_exit != 0` (DNS, TLS, timeout, non-2xx — body absent or partial).
   - **Failing — parse/compile:** `curl_exit == 0 AND jq_exit != 0 AND jq_err non-empty` (body isn't JSON, or the expression is malformed — almost always a consumer-config issue, not actual prod degradation).
   - **Failing — degraded:** `curl_exit == 0 AND jq_exit != 0 AND jq_err empty` (expression ran cleanly but returned false/null — prod is genuinely unhealthy).

   If `{{config.prodHealthProbe}}` is absent, record `{probed: false}` — downstream phases behave as they did pre-v3.

Also collect the `lastUpdated` timestamp from `{{config.waveStatusFile}}` and the set of recently-closed issues from GitHub since then:

```bash
SINCE=$(jq -r '.lastUpdated // "2026-01-01T00:00:00Z"' {{config.waveStatusFile}})
gh issue list --repo {{config.repo}} --state closed \
  --search "closed:>=${SINCE%T*}" --limit 200 --json number \
  | jq '[.[].number]'
```

Phase 1 emits nothing; it just gathers facts for Phase 2.

### Phase 2 — auto-heal

Using Phase 1's data:

1. **Per-wave self-heal:** for each wave where the PR is merged but `phase` is not in the terminal-phase set `{"completed", "rolled_back", "abandoned"}`:
   ```bash
   TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
   jq --arg ts "$TS" --arg pr "<merged-PR-number>" \
     '.phase = "completed" | .merged_pr = ($pr | tonumber) | .completed_at = $ts | .last_activity = $ts' \
     {{config.stateDir}}/waves/<name>.json > /tmp/wave.json && mv /tmp/wave.json {{config.stateDir}}/waves/<name>.json
   ```
   Report: "Wave <name> completed but state was stale — auto-fixed."

2. **`wave-status.json` reconciliation** (sole-writer responsibility):
   ```bash
   CLOSED='[<numbers from Phase 1 gh issue list>]'
   jq --argjson closed "$CLOSED" \
     '.completedIssues = ((.completedIssues + $closed) | unique | sort)
      | .remainingIssues.p0Blocking = (.remainingIssues.p0Blocking - $closed)
      | .remainingIssues.p1PreLaunch = (.remainingIssues.p1PreLaunch - $closed)
      | .remainingIssues.p2PostLaunch = (.remainingIssues.p2PostLaunch - $closed)
      | .lastUpdated = (now | todateiso8601)' \
     {{config.waveStatusFile}} > /tmp/status.json && mv /tmp/status.json {{config.waveStatusFile}}
   ```
   Report which issues were added and, best-effort from git log / PR titles, which wave closed them.

If `{{config.waveStatusFile}}` does not exist or is missing the `remainingIssues` field, halt with: `"{{config.waveStatusFile}} missing or incomplete — cannot plan without priority data. Author the file or invoke /wave-planner with explicit <name> <issues> args to skip planning."`

### Phase 3 — human-surface

Emit signals worth the human's attention before spending their time on Phase 4.

1. **Prod health (if probe configured).** If Phase 1 recorded `probed: true` AND the probe is failing, surface as the first item in the Phase 3 output using the mode-specific template below. When the probe passes or is not configured, this item is silent.

   **Mode A — network/HTTP failure** (`curl_exit != 0`):
   ```
   **BLOCKER: prod health probe could not reach the endpoint.**
   URL: <url>
   curl: exit=<curl_exit>  error: <curl_err or "-">
   (No body to evaluate. Treat as degraded-unknown; could be a network blip or a genuine outage.)
   ```

   **Mode B — parse/compile error** (`curl_exit == 0 AND jq_exit != 0 AND jq_err non-empty`):
   ```
   **BLOCKER: prod health probe body or expression failed to parse.**
   URL: <url>
   Expression: <healthyJqExpr>
   jq stderr: <first line of jq_err>
   Response body (first 2KB of <body_bytes>B): <body_display>
   (Usually a consumer config issue — fix the jq expression or the endpoint shape, not prod.)
   ```

   **Mode C — genuinely degraded** (`curl_exit == 0 AND jq_exit != 0 AND jq_err empty`):
   ```
   **BLOCKER: prod is degraded.**
   URL: <url>
   Expression: <healthyJqExpr>  (evaluated to false/null)
   Response body (first 2KB of <body_bytes>B):
   <body_display>
   ```

   All three modes route Phase 4 toward amendment waves. Prod being broken — or being provably un-observable — changes which wave (if any) should launch, so this BLOCKER must be visible before Phase 4 builds suggestions.

2. **Planner mailbox:**
   ```bash
   if [ -s {{config.crossTabDir}}/planner.md ]; then
     cat {{config.crossTabDir}}/planner.md
     mv {{config.crossTabDir}}/planner.md {{config.crossTabDir}}/planner.md.processed.$(date +%s)
   fi
   ```
   Surface contents. Common senders: wave orchestrators reporting escalations, retro skills noting a finding that affects portfolio priority.

3. **FEEDBACK.md delta:**
   ```bash
   TOOLING_HOME="${CLAUDE_TOOLING_HOME:-$HOME/Dev/claude-tooling}"
   SENTINEL="{{config.stateDir}}/.feedback-seen"
   FEEDBACK="$TOOLING_HOME/FEEDBACK.md"
   [ -f "$SENTINEL" ] && LAST_SEEN=$(cat "$SENTINEL") || LAST_SEEN=0
   CURRENT=$(wc -c < "$FEEDBACK" 2>/dev/null || echo 0)
   if [ "$CURRENT" != "$LAST_SEEN" ]; then
     echo "FEEDBACK.md changed since last check. Review $FEEDBACK if relevant to this session."
     echo "$CURRENT" > "$SENTINEL"
   fi
   ```
   Byte-count sentinel is intentionally crude — it catches appends without parsing markdown. Reviewing the file is a human action, not an automated diff surface. `$CLAUDE_TOOLING_HOME` honours non-default installs; the default matches `scripts/bootstrap.sh`.

4. **Drift check:**
   ```bash
   TOOLING_HOME="${CLAUDE_TOOLING_HOME:-$HOME/Dev/claude-tooling}"
   git -C "$TOOLING_HOME" fetch --quiet origin main 2>/dev/null && {
     LOCAL=$(git -C "$TOOLING_HOME" rev-parse HEAD)
     REMOTE=$(git -C "$TOOLING_HOME" rev-parse origin/main)
     if [ "$LOCAL" != "$REMOTE" ]; then
       BEHIND=$(git -C "$TOOLING_HOME" rev-list --count HEAD..origin/main)
       echo "Shared skills are $BEHIND commits behind — run \`git -C \"$TOOLING_HOME\" pull\` to update."
     fi
   } || echo "Drift check skipped: git fetch failed (offline or auth error)."
   ```
   Never auto-pull. See `~/Dev/claude-tooling/AUTOUPDATE.md`.

5. **Stall signals from Phase 1:**

   | Signal | Threshold | Surface as |
   |---|---|---|
   | Workspace missing AND phase not in terminal set AND `last_activity` older than 2h | > 2h | `AskUserQuestion`: "Wave <name> appears dead. Mark abandoned?" |
   | Workspace alive AND screen unchanged since last invocation (compare to `last_seen_screen` in state file, if present) | > 30 min since last planner invocation | Report only: "Wave <name> looks idle (no screen change). Check in?" |
   | Workspace alive AND screen changing | (healthy) | Silent |
   | Phase `paused` or `blocked` with `paused_reason` / `blocked_by` | (dormant) | One-line context, no prompt |
   | Wave phase flipped to terminal set but workspace still open | — | `AskUserQuestion`: "Wave <name> finished (phase: <x>). Close its workspace?" |

### Phase 4 — plan + present

**If explicit args were provided**, skip the suggestion machinery and jump to Phase 5 with those args.

**Otherwise**, build a suggestion:

**Read sources:**

1. **Open issues:**
   ```bash
   gh issue list --repo {{config.repo}} --state open --limit 100 --json number,title,labels,body
   ```
2. **Active waves** to exclude already-claimed issues: the Phase 1 data already has these.
3. **Completed issues** from `{{config.waveStatusFile}}.completedIssues[]` — don't suggest these.
4. **Priority hints** from `{{config.waveStatusFile}}.remainingIssues` — `p0Blocking` first, then `p1PreLaunch`, defer `p2PostLaunch` unless the human explicitly asks for it.
5. **Recent retro findings** from `{{config.retroLog}}` — flag patterns to avoid (e.g. "schema migrations are currently risky, defer").

**Build candidate set:**
- Remove issues claimed by an active wave.
- Remove issues in `completedIssues[]`.
- Remove issues with unsatisfied dependencies (read body/labels).
- Sort by priority: p0Blocking > p1PreLaunch > p2PostLaunch.

**Right-sizing — is this even wave-worthy?** Before grouping, check any candidate that is *already a written OpenSpec change* (an `openspec/changes/<name>/` directory with a `proposal.md` exists). If such a change touches ≤3 files, adds no migration, and adds no new resource/page/policy, the full wave machinery (analyst → builder → reviewer → integrator + a worktree + a cmux tab) is heavier than the work warrants. For that candidate, the Phase 4 `AskUserQuestion` offers a lightweight route as **option 1** and the wave as option 2:

| Route | For |
|---|---|
| Direct spec edit on a feature branch | bug fixes, typos, minor improvements |
| `/opsx:apply` on a feature branch | a ≤3-file change that already has a written proposal |
| Full wave | multi-issue, complex, or new-capability work |

All three routes still update the living spec — only the scaffolding scales. The wave path stays available so a founder who wants the agent-team review surface can pick it. This inverts the previous default, where the planner proposed a full wave even for a 2-file change with a ready proposal (FEEDBACK 2026-05-15 / PR #200).

**Group into a coherent wave (3–6 issues is the sweet spot for agent teams):**
- **Solo wave (1 issue):** a single high-priority blocker, or a large/complex issue that warrants its own session.
- **Small wave (2–3 issues):** issues that share scope (one feature area).
- **Standard wave (4–6 issues):** independent issues that don't share files, ranked by priority.
- **Avoid:** issues that touch the same files unless they MUST be batched.

For each candidate: number, title, priority tier, estimated complexity, likely files touched, any external prerequisites.

**Amendment-vs-new-wave routing.** When a production regression is traced to a recently merged PR, decide:
- **Amendment** (fast path): narrow fix (< 50 LoC, no schema change, no new OpenSpec scope) → single-issue wave named `fix-<regression-issue-N>`.
- **New wave** (full path): design change, schema migration, or multi-area → normal wave.

Record the routing call in the suggestion's rationale.

**Prod-health override.** If the Phase 1 probe is failing (see Phase 3 BLOCKER), route `AskUserQuestion` by the failure mode — don't assume every failing probe means "prod is degraded":

- **Mode A (network/HTTP) or Mode C (degraded):** amendment routing becomes mandatory regardless of backlog priority.
  - **Regression-issue match, confident:** exactly one open issue where the label set contains `bug` or `regression` **and** the body contains the probe URL or (for Mode C) a string fragment from the response body (e.g. `migration_error`, a status string, a specific error message). Top option is "Launch amendment wave `fix-<N>` to restore prod."
  - **Regression-issue match, uncertain:** 2+ candidates matching either criterion, or 1 candidate matching only the label. Present the top 3 candidates as separate `AskUserQuestion` options ("Launch `fix-<N1>`", "Launch `fix-<N2>`", ...) so the human picks rather than the planner guessing.
  - **No regression issue exists yet:** top option is "File a regression issue first, then launch amendment wave." The planner does not launch an amendment wave with no claim target.
  - For Mode A specifically, also offer "Retry probe now" as one of the options. If selected, re-run the Phase 1 probe block against the same URL, re-classify, and re-enter Phase 3 with the fresh result (which may now pass, pushing Phase 4 back to normal backlog routing). Do not re-run the whole sweep — the retry is a targeted re-probe only.
- **Mode B (parse/compile error):** don't force amendment routing — this is almost always a consumer-config bug (typo in `healthyJqExpr`, probe URL pointing at the wrong endpoint, endpoint shape changed). Top option is "Fix `.claude/project.json` probe config and re-invoke planner." Amendment-wave options appear below only as a fallback in case the human confirms prod really is degraded and the jq error is a red herring.

In all cases, do NOT surface new-feature waves as the default choice while the probe is failing. The check-in option ("Just report — don't launch") remains available for humans who want to exit and fix things via a separate path.

**Suggest a wave name** (kebab-case from the dominant theme):
- Single issue: `issue-<N>-<short-slug>`
- Themed batch: `wave-YYYY-MM-DD-<theme>`
- Mixed: `wave-YYYY-MM-DD-batch`

**Present via `AskUserQuestion`**, with these options:

1. **Accept the suggested wave** — go to Phase 5 with the suggestion's args.
2. **Modify** — keep some, drop some, add some, re-suggest.
3. **Show alternatives** — different grouping.
4. **Just report — don't launch** — exit cleanly. Useful as a check-in usage pattern.
5. **I'll specify manually** — exit. Human re-invokes `/wave-planner <name> <issues>` directly.

The question text must include: suggested wave name, issue list with titles, rationale, and any risks (unsatisfied dependencies, external prerequisites, file conflicts with active waves).

### Phase 5 — launch

Runs only when Phase 4 returned an accepted suggestion OR when explicit args were provided. Encapsulates everything the five-skill-era `start-wave` did, as steps within this phase.

#### 5.1 Validate args

Parse `<wave-name> <issue-numbers> [fixes:<check-names>]`:

1. Wave-name: lowercase, alphanumeric + hyphens, max 50 chars (becomes a git branch name).
2. Issue-numbers: comma-separated integers, at least one.
3. Optional `fixes:<names>`: split remainder on `,` into the `fixes_checks` array (e.g. `phpstan,tests,pint`). Absent → empty array.

If parsing fails, STOP with the expected format.

**About `fixes_checks`:** declaring this list tells the orchestrator "this wave is a hotfix intended to make these checks green — a red baseline is EXPECTED." Without it, `{{config.checkCommand}}` failing in Step 5.4 is treated as a halt condition. The end-of-wave integrator gate still requires checks to pass unconditionally — `fixes_checks` only tolerates the baseline at start-up.

#### 5.2 Re-check conflicts and prod health (BLOCKING)

Phase 1 read state at invocation time; a new wave may have started in parallel since, and prod health may have changed. Re-check now, before atomic claim:

1. List active waves: `ls {{config.stateDir}}/waves/*.json 2>/dev/null`.
2. For each: extract `issues[]`, `files_claimed[]`, `last_activity`, `worktree`.
3. **Detect stale:** if `last_activity` older than 2h OR worktree directory missing, mark stale and offer to delete its state file.
4. **Issue conflict (HARD BLOCK):** for each issue in this new wave, check against every active wave's `issues[]`. If overlap:
   ```
   Issue #N is already claimed by active wave <name> (worktree <path>, started <started>). Coordinate with that session or wait for it to finish.
   ```
   STOP.
5. **File conflict (WARN):** if this wave has OpenSpec design.md files, cross-check their file lists against `files_claimed[]` in active waves. On overlap, `AskUserQuestion`: "This wave will touch <files> also claimed by wave <other-name>. Proceed anyway?" STOP on no.
6. **Prod-health re-probe (if configured).** If `prodHealthProbe` is present in `.claude/project.json`, re-run the Phase 1 probe now (the Phase 1 reading may be stale by the time launch is confirmed). Use the same `jq -r`-into-variable pattern as Phase 1 to avoid shell-quoting issues with the expression:
   ```bash
   PROBE_URL=$(jq -r '.prodHealthProbe.url // empty' .claude/project.json)
   PROBE_EXPR=$(jq -r '.prodHealthProbe.healthyJqExpr // empty' .claude/project.json)
   if [ -n "$PROBE_URL" ] && [ -n "$PROBE_EXPR" ]; then
     PROBE_BODY=""
     JQ_EXIT=""
     JQ_ERR=""
     PROBE_BODY=$(curl -fsS --max-time 10 "$PROBE_URL" 2>/tmp/probe.err)
     CURL_EXIT=$?
     if [ $CURL_EXIT -eq 0 ]; then
       printf '%s' "$PROBE_BODY" | jq -e "$PROBE_EXPR" >/dev/null 2>/tmp/jq.err
       JQ_EXIT=$?
       JQ_ERR=$(cat /tmp/jq.err 2>/dev/null)
     fi
     PROBE_BODY_DISPLAY=$(printf '%s' "$PROBE_BODY" | head -c 2048)
   fi
   ```
   Classification matches Phase 1. Gate behaviour varies by mode:
   - **Mode A (network/HTTP) or Mode C (degraded), wave name does NOT start with `fix-`:** STOP with:
     ```
     Prod health probe is failing (URL: <url>, mode: network|degraded, body: <body_display>). Either launch an amendment wave (name starting `fix-`) or fix prod via a separate hotfix, then retry. If Mode A and you believe this is a transient network blip, re-invoke /wave-planner — a successful re-probe will clear the block.
     ```
   - **Mode A or Mode C, wave name starts with `fix-`:** proceed. Amendment waves are allowed through because their purpose is to restore prod.
   - **Mode B (parse/compile error):** do NOT hard-STOP — Mode B is a consumer-config bug (busted `healthyJqExpr` or wrong endpoint shape), not a prod signal. Emit a warning and continue:
     ```
     WARNING: prod health probe returned a parse/compile error (URL: <url>, expr: <healthyJqExpr>, jq stderr: <jq_err first line>). This is almost certainly a config bug in .claude/project.json, not actual prod degradation — fixing it is recommended but not blocking. Proceeding with launch.
     ```
   - **Passing probe or no configured probe:** no-op.

   Note that `fix-` is a semantic convention humans opt into — the skill trusts the wave name rather than validating that the work is genuinely restorative, so this gate relies on human discipline, not enforcement. A user can always rename a wave `fix-*` to bypass the block; the gate's job is to make that bypass deliberate, not to prevent it.

7. **Brief freshness re-check (per issue, BLOCKING).** The GitHub board the planner read while drafting the brief in Phase 4 goes stale between draft and launch — an issue can be implemented, merged, or closed in that window, and a launched wave then carries dead work (FEEDBACK 2026-05-18 / #206, 2026-05-21 / #278). Fetch first so `origin/main` is current (Phase 5.4's pull runs only later), then for each issue in this wave:
   ```bash
   git fetch origin main --quiet
   gh issue view <N> --repo {{config.repo}} --json state,stateReason
   git log origin/main --grep="#<N>" --oneline | head -1
   ```
   - **Issue is CLOSED, or a merge commit on `origin/main` already references it:** the work is done. Drop the issue from the wave's `issues[]` and report the drop to the human.
   - **Issue is OPEN with no referencing merge commit:** keep it.

   If dropping leaves the wave with zero issues, STOP — report "all briefed issues already shipped; nothing to launch" and exit without an atomic claim. "Issue is OPEN" alone is not "work is undone" — but a closed or already-merged issue padding the wave is phantom scope.

#### 5.3 Atomic claim

Write the wave state file at `{{config.stateDir}}/waves/<wave-name>.json`:

```json
{
  "name": "<wave-name>",
  "issues": [<issue-numbers>],
  "fixes_checks": [<from Step 5.1>],
  "worktree": ".worktrees/<wave-name>",
  "methodology": "openspec",
  "review_rubric_path": null,
  "lead_session_id": "<filled-by-orchestrator>",
  "phase": "starting",
  "files_claimed": [],
  "started": "<ISO-8601>",
  "last_activity": "<ISO-8601>"
}
```

**Plan-file waves** (docs-only / shared-meta / no-OpenSpec): set `"methodology": "plan-file"` and `"review_rubric_path": "<absolute or project-relative path>"`. The orchestrator branches accordingly (see `wave-orchestrate` Step 1).

Use noclobber to guarantee atomicity:

```bash
set -o noclobber
cat > "{{config.stateDir}}/waves/<wave-name>.json" <<EOF
<json body>
EOF
```

If the file already exists, the claim failed (race with another planner). Retry once, then STOP.

#### 5.4 Verify main is current and clean

1. `git checkout main && git pull origin main`
2. `git status` — must be clean. If dirty, STOP and report.
3. Run `{{config.checkCommand}}`.
   - **Passes:** proceed.
   - **Fails AND `fixes_checks` is empty:** STOP — cannot start a wave on broken main. Either declare `fixes:<checks>` or fix main first via a separate hotfix.
   - **Fails AND `fixes_checks` is non-empty:** log the expected-red baseline on the wave state JSON:
     ```json
     "baseline_checkcommand": {
       "status": "failed",
       "tail": "<last 40 lines of output>",
       "captured_at": "<ISO-8601>"
     }
     ```
     Then proceed. The orchestrator's Step 9a pre-integration CI classification is the real safety net.

#### 5.5 Create the worktree

```bash
git fetch origin main
git worktree add .worktrees/<wave-name> -b <wave-name> origin/main
git -C .worktrees/<wave-name> config commit.gpgsign false
```

Branch from `origin/main`, not the local `main` ref. `git worktree add` branches from whatever ref you name; a local `main` that has fallen behind the remote produces a stale base, and the wave then fails review for a non-code reason (FEEDBACK 2026-05-19 / issue #271). Step 5.4 already pulled `main`, so this is belt-and-braces — but it makes the base unambiguous regardless of how 5.4 ran.

Commit signing is disabled because headless workers can't unlock 1Password. If worktree creation fails (branch exists, directory exists), STOP and report. Do NOT auto-cleanup — that's destructive.

#### 5.5a Bootstrap the worktree (dependencies + repo-local git config)

`git worktree add` checks out only **tracked** files. Gitignored vendored directories (`vendor/`, `node_modules/`) and repo-local git config (`core.hooksPath` and friends) do NOT carry into a fresh worktree. Without this step the orchestrator's Step 2 baseline check fails on missing dependencies — surfacing as an opaque Vite/Filament "file not in manifest" error rather than an honest "deps not installed" — and project pre-commit hooks silently never fire. This is the single most-repeated failure in the feedback pool.

1. **Install dependencies.** If `{{config.bootstrapCommand}}` is set, run it inside the worktree:
   ```bash
   ( cd ".worktrees/<wave-name>" && {{config.bootstrapCommand}} )
   ```
   The command must be idempotent (safe to re-run). Typical value for a Laravel + Vite consumer: `composer install --no-interaction && npm install && npm run build`. If the command exits non-zero, STOP and report — do not launch a wave onto a half-installed worktree. If the field is absent, skip this sub-step (a consumer with no vendored dependencies needs no bootstrap).
2. **Never symlink `vendor/` or `node_modules/` from the main checkout.** Composer's generated autoloader bakes an absolute `$baseDir` into `vendor/composer/autoload_*.php`; a symlink makes every autoloaded class resolve to the *main checkout's* copy, so the wave's own edits are invisible and the suite passes against the wrong code (FEEDBACK 2026-05-13 / issue #175). Always install into the worktree.
3. **Re-assert repo-local git config the project relies on.** A worktree does not inherit `core.hooksPath` (or filters/attributes) from the primary clone, so a project's pre-commit guards are dead in the worktree until reasserted (FEEDBACK 2026-05-19 / issue #260). If the consumer wires hooks via repo-local config, the `bootstrapCommand` should re-run the project's setup step (e.g. `composer setup`) so the config is live; verify the consumer's `bootstrapCommand` covers this.
4. **Verify before proceeding.** Confirm no vendored directory is a symlink:
   ```bash
   for d in vendor node_modules; do
     P=".worktrees/<wave-name>/$d"
     [ -L "$P" ] && { echo "Step 5.5a failed: $d is a symlink — corrupts autoload, see issue #175"; exit 1; }
   done
   ```
   If the check fails, STOP and report rather than launching a wave onto a broken environment.

#### 5.6 Seed worktree-local state

`git worktree add` only checks out tracked files, so `.gitignore`d paths are absent. The wave's coordination state lives in `{{config.stateDir}}/` (wave JSON claim, cross-tab mailbox, retro log, wave-status) and is by-design gitignored. Without a symlink, the orchestrator starts in a worktree with an empty state dir and drifts from the main checkout.

```bash
rm -rf ".worktrees/<wave-name>/{{config.stateDir}}"
ln -sf "../../{{config.stateDir}}" ".worktrees/<wave-name>/{{config.stateDir}}"

test -f ".worktrees/<wave-name>/{{config.stateDir}}/waves/<wave-name>.json" || { echo "Step 5.6 failed: wave JSON not visible through symlink"; exit 1; }
```

Symlinks (not copies) because the orchestrator's writes — `phase`, `last_activity`, `files_claimed`, `cmux_workspace_id` — must be visible to any later planner invocation reading from the main checkout.

If the test fails, STOP. Recovery: `git worktree remove .worktrees/<wave-name> --force` and delete the state file, then investigate whether `{{config.stateDir}}` is unexpectedly tracked in git.

##### 5.6a Symlink dotenv files (so dev servers can start in the worktree)

The orchestrator's Step 9b (local preview gate) starts the consumer's dev server inside the worktree so the human can review changes via a localhost URL before merge. Dev servers usually need `.env` (database URLs, API keys, port overrides) — and `.env` is gitignored, so `git worktree add` does not check it out.

The list of dotenv paths to mirror is **per-consumer**, declared via the optional `{{config.dotenvPaths}}` array in `project.json`. Repo-root `.env` is mirrored unconditionally regardless of config (universal default). Additional paths (monorepo subprojects like `apps/api/.env`, `payload/.env`, etc.) come from config.

```bash
# Universal default: every project that has a root .env gets it mirrored.
DOTENV_PATHS=( ".env" )

# Append any additional paths declared in project.json (.dotenvPaths array).
# Falls back to empty array when the field is absent — no error.
EXTRA_PATHS=$(jq -r '(.dotenvPaths // []) | .[]' .claude/project.json 2>/dev/null || true)
while IFS= read -r p; do
  [ -n "$p" ] && DOTENV_PATHS+=( "$p" )
done <<< "$EXTRA_PATHS"

for ENVPATH in "${DOTENV_PATHS[@]}"; do
  SRC="$PWD/$ENVPATH"                                   # main checkout (cwd)
  DST=".worktrees/<wave-name>/$ENVPATH"

  if [ -f "$SRC" ]; then
    mkdir -p "$(dirname "$DST")"
    ln -sf "$SRC" "$DST"
    echo "  [linked] $ENVPATH -> $SRC"
  else
    echo "  [skipped] $ENVPATH (not present in main checkout)"
  fi
done
```

Symlinks (not copies) so secrets rotated in the main checkout's `.env` are picked up automatically — copies would silently go stale.

If a consumer's dev servers need env files at additional paths, add them to `dotenvPaths` in that consumer's `project.json` rather than editing this skill. Source: FEEDBACK 2026-04-27 — multiple waves have re-discovered this gap.

#### 5.7 Open the wave session in a new cmux tab

1. Build the task prompt:

   ```
   You are running wave <wave-name>. Coordinate the implementation of issues <issue-numbers> from start to finish within this session.

   Wave state file: {{config.stateDir}}/waves/<wave-name>.json
   Working directory: .worktrees/<wave-name> (this is your cwd)
   Branch: <wave-name>

   Run /wave-orchestrate <wave-name> to begin.
   ```

2. Write it to a temp file to avoid shell quoting issues:
   ```bash
   TASK_FILE=$(mktemp)
   cat > "$TASK_FILE" <<'EOF'
   <task prompt>
   EOF
   ```

3. Spawn the workspace (tab name prefixed with `{{config.displayName}}` so multi-project tab strips stay readable) and capture the canonical ref from its `OK workspace:N` reply in one shot:
   ```bash
   NW_OUT=$(cmux new-workspace \
     --cwd "$PWD/.worktrees/<wave-name>" \
     --name "{{config.displayName}} Wave <wave-name>" \
     --command "bash -c 'cat $TASK_FILE | claude --dangerously-skip-permissions'")
   # NW_OUT looks like "OK workspace:8" — extract the full ref, not the bare number.
   WORKSPACE_REF=$(printf '%s\n' "$NW_OUT" | awk '/workspace:/ {for (i=1;i<=NF;i++) if ($i ~ /^workspace:/) {print $i; exit}}')
   if [ -z "$WORKSPACE_REF" ]; then
     echo "Failed to parse workspace ref from cmux new-workspace output: $NW_OUT" >&2
     exit 1
   fi
   ```

4. `WORKSPACE_REF` (e.g. `workspace:8`) is what gets stored in step 5.8 — **always the full ref, never the bare number**. `cmux read-screen --workspace` and Phase 1's `.ref` filter both require the ref form; a bare number silently breaks stall detection (FEEDBACK 2026-05-26).

#### 5.8 Update wave state and report

1. Update `{{config.stateDir}}/waves/<wave-name>.json`. Pass `WORKSPACE_REF` from step 5.7 (e.g. `workspace:8`) — do not strip the prefix:
   ```bash
   TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
   jq --arg ts "$TS" --arg id "$WORKSPACE_REF" \
     '.phase = "in-progress" | .last_activity = $ts | .cmux_workspace_id = $id' \
     {{config.stateDir}}/waves/<wave-name>.json > /tmp/wave.json && mv /tmp/wave.json {{config.stateDir}}/waves/<wave-name>.json
   ```

2. Report to the human:
   ```
   Wave launched: <wave-name>
   Issues: <list with titles>
   Worktree: .worktrees/<wave-name>
   cmux workspace: <WORKSPACE_REF>

   The wave is running independently. Re-invoke /wave-planner whenever you want a status check or to launch another.
   ```

Exit. No `/loop`, no persistent monitoring — the next `/wave-planner` invocation runs the full sweep again.

### Phase 5 recovery

If a step in Phase 5 fails partway through, each later step has side-effects that need undoing. Match the last-succeeded step to the action:

| Last step completed | What exists | Cleanup action |
|---|---|---|
| 5.3 (atomic claim) but 5.5 failed | Wave JSON written, no branch, no worktree | Delete `{{config.stateDir}}/waves/<wave-name>.json` to release the claim |
| 5.5 (worktree) but 5.6 (state symlink) failed | Worktree + branch exist, state symlink broken or missing | `git worktree remove .worktrees/<wave-name> --force` then delete the wave JSON |
| 5.6 (state symlink) but 5.7 (cmux new-workspace) failed | Worktree + branch + symlink exist, no cmux tab | `git worktree remove .worktrees/<wave-name> --force` then delete the wave JSON |
| 5.7 (cmux tab) but 5.8 (state update) failed | Worktree + tab running but state JSON missing `phase: "in-progress"` and `cmux_workspace_id` | Manually update the wave JSON: `jq '.phase="in-progress" | .cmux_workspace_id="workspace:<N>"' ...` — store the full ref form, not the bare number; do NOT remove the worktree, the wave is already running |

Never auto-cleanup on failure — each recovery is a deliberate human step. Reason: a failed 5.5 (worktree) can leave a half-created branch that a later wave might need to inspect; aggressive cleanup would destroy forensic evidence.

### Phase 6 — session handoff

Runs at the end of every invocation — after Phase 5 if a wave launched, after Phase 4 if not, after Phase 3 on a report-only run. Its job is to make sure the *next* planner invocation inherits this session's context instead of re-deriving everything from GitHub + wave JSONs and losing what was only ever session-local: which PRs await human review, which issue the human verbally tagged "do tomorrow", what the suggested next wave was and why.

**Gate — skip Phase 6 entirely unless the session did something worth recording.** Write a handoff only if the session launched a wave, filed an issue, opened a PR, surfaced a stall/BLOCKER, or the human verbally prioritised something. A pure clean sweep (no waves, no backlog candidates, nothing flagged) writes nothing — a noise entry just trains the next session to ignore the file.

**When the gate passes,** append a dated block to `{{config.crossTabDir}}/planner.md`:

```markdown
## <ISO-8601 timestamp> — planner session handoff

- **Launched this session:** <wave names + issue numbers, or "none">
- **PRs awaiting human review:** <PR numbers + one line each, or "none">
- **Issues filed / verbally prioritised:** <numbers + any verbal "do tomorrow" tags, or "none">
- **Suggested next wave + why:** <one line, or "none">
- **Reconciliation hints for the next Phase 2:** <anything the next sweep should know, e.g. "wave-X JSON phase is stale — branch already merged">
```

Phase 3 of the *next* invocation already reads and archives `{{config.crossTabDir}}/planner.md`, so the loop closes with no new machinery — Phase 6 only defines the *write* side that was previously left to the human to remember to ask for (FEEDBACK 2026-05-15 / planner session).

## Graceful exits

- No active waves, no backlog candidates → "Nothing active. Backlog empty of planner-eligible issues. Exit."
- Active waves healthy, no backlog candidates → "<N> waves healthy: <names>. Nothing new to launch. Exit."
- Check-in usage → human selects "Just report — don't launch" at Phase 4, exit without launching.

## Cross-tab communication

- **Mailbox write:** the planner may write to `{{config.crossTabDir}}/wave-<name>.md` to send mid-wave guidance (e.g. scope change). Keep it rare — the orchestrator checks its mailbox on every loop tick and acts on what it finds.
- **Mailbox read:** Phase 3 reads `{{config.crossTabDir}}/planner.md`.
- **`cmux notify`** — reserved for urgent human-attention signals. Prefer mailbox writes.

## Boundaries

- NEVER write `{{config.waveStatusFile}}` outside Phase 2's reconciliation flow.
- NEVER read or interact with cmux workspaces outside this project (own-repo filter is mandatory).
- NEVER edit shared skill files from a consumer tab — open `~/Dev/claude-tooling` and edit there (see `CONTRIBUTING.md`).
- NEVER comment on GitHub issues — that's wave-session work.
- NEVER start a `/loop` — the planner is on-demand only.
- Do not auto-suggest `p2PostLaunch` issues unless the human explicitly asks.
- Do not suggest issues with unsatisfied dependencies — defer with a note on what blocks them.

## Key context

- Invocation: `/wave-planner` from any project-aware session. No persistent tab; every run is stateless.
- Dependencies: `gh`, `jq`, `cmux`, `{{config.stateDir}}/waves/`, `{{config.waveStatusFile}}`, `{{config.retroLog}}`, `~/Dev/claude-tooling/FEEDBACK.md`
- Related skills: `/wave-orchestrate` (launched by Phase 5), `/wave-retro` (post-merge, separate invocation)

## Rules

- ALWAYS run Phases 1–3 before accepting explicit args — the sweep + surface is part of every invocation, not just the planning path.
- ALWAYS present suggestions via `AskUserQuestion`. Never silently launch.
- ALWAYS filter cmux operations to this project's cwd.
- NEVER skip dependency/conflict checks because you "know" the backlog.
- Keep each phase's steps in order — Phase 5's atomic claim depends on Phase 1's sweep data being fresh.
