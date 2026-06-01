---
name: openspec-sync-specs
description: Sync delta specs from an OpenSpec change into the main specs under openspec/specs/. Supplementary companion to openspec-archive-change — the archive skill delegates to this one for its step-4 sync. Invoke with a change name; reads openspec/changes/<name>/specs/ and updates the matching main spec, preserving the delta's full relative path (works for both flat `openspec/specs/<capability>/spec.md` and nested `openspec/specs/<panel>/<capability>/spec.md` layouts).
license: MIT
compatibility: Requires openspec project layout (openspec/changes/ and openspec/specs/).
metadata:
  author: shaheed
  version: "1.0"
---

Sync the delta specs from a single OpenSpec change into the main specs library so the main library stays current after a change is archived (or about to be).

**Input**: A change name. Required — do not guess. If not provided, ask via AskUserQuestion listing changes that still have a `specs/` directory (either under `openspec/changes/<name>/` or the most recent archive).

## When to use

- Invoked by `openspec-archive-change` step 4 (its "Sync now (recommended)" path)
- Invoked directly via `/openspec-sync-specs <change>` if the archive skill's sync prompt was skipped
- Invoked ad-hoc when a change was archived without syncing and main specs drifted

This skill **does not** modify any change directory, delete any file, or run `git commit`. It only updates main specs.

## Steps

1. **Locate the delta specs**

   Check in this order:
   1. `openspec/changes/<name>/specs/` (change still active)
   2. Newest match of `openspec/changes/archive/*<name>*/specs/` (already archived)

   If neither exists, stop and report: "No delta specs found for '<name>' — nothing to sync."

2. **Enumerate delta files**

   Recursively find **every** `spec.md` under the delta `specs/` directory (not just direct children). For each, map it to the main spec by preserving its **full relative path** from `specs/` down:

   | Delta path (under the change) | Main spec path |
   |---|---|
   | `specs/auth/spec.md` (flat) | `openspec/specs/auth/spec.md` |
   | `specs/repeat-flow/cycle-tracker/spec.md` (nested) | `openspec/specs/repeat-flow/cycle-tracker/spec.md` |

   The relative path is the mapping — do **not** flatten it to the last segment. This is what makes the skill layout-agnostic: a flat layout is just the depth-1 case of a nested one.

   > **Why this skill, not `openspec archive`'s built-in sync:** the upstream `openspec` CLI only supports a flat one-level layout — it does a shallow read and writes nested deltas to the wrong (flattened) path (see Fission-AI/OpenSpec [#796](https://github.com/Fission-AI/OpenSpec/issues/796), still open). A consumer with panel-nested specs (e.g. a multi-panel app whose specs mirror its `app/{Panel}/` structure) therefore runs `openspec archive --skip-specs` — or moves the change dir by hand — and lets **this** skill do the path-preserving sync. Where the nesting is a deliberate mirror of the app's architecture, the fix lives here, not in flattening the library.

   Build a list of (delta_path, main_path) pairs.

3. **Classify each delta**

   For each pair, compare delta with main spec using `diff` (or read both files):

   | State | Meaning |
   |---|---|
   | `CREATE` | main spec does not exist — delta introduces a new capability |
   | `ADD` | delta adds new sections/lines to main spec |
   | `MODIFY` | delta replaces existing sections in main spec |
   | `REMOVE` | delta marks sections for deletion (look for `## REMOVED:` or `<!-- remove -->` markers) |
   | `RENAME` | delta uses `<!-- renamed-from: old-path -->` header |
   | `NO-OP` | delta and main are identical (already synced) |

   See `references/delta-merge-rules.md` for the merge semantics in detail.

4. **Show combined summary**

   Before any writes, print a table:

   ```
   ## Proposed Sync: <change-name>

   | Main Spec | Action |
   |---|---|
   | openspec/specs/foo/spec.md | ADD (2 sections) |
   | openspec/specs/bar/spec.md | CREATE |
   | openspec/specs/baz/spec.md | NO-OP |
   ```

   Stop here if all rows are NO-OP and report "Already in sync — nothing to do."

5. **Confirm per spec** (or per-change)

   Use **AskUserQuestion** to choose:
   - "Apply all" — run every action in the table
   - "Review one by one" — prompt per non-NO-OP row with the diff preview
   - "Cancel"

6. **Apply the sync**

   For each chosen row:
   - `CREATE`: write the delta content to the new main spec path (mkdir -p parent)
   - `ADD`: insert new sections at the end of main spec (or at a `<!-- insert-here -->` marker if present)
   - `MODIFY`: replace matched section (use the section heading as the anchor) with the delta version
   - `REMOVE`: delete the section matching the removal marker
   - `RENAME`: move old main spec to new path, then apply ADD/MODIFY/REMOVE to it

   Use the Edit tool for in-place changes and Write only for `CREATE`.

7. **Report**

   Print a final summary:

   ```
   ## Sync Complete

   **Change:** <name>
   **Updated:** <N> spec files
   **Created:** <M> new spec files
   **Skipped (NO-OP):** <K>

   Next step: `git add openspec/specs && git commit -m "sync delta specs from <name>"`
   ```

   Do not run git. The user owns commits.

## Guardrails

- Never delete a change directory or delta file — read-only on `openspec/changes/`
- Never apply a MODIFY/REMOVE without showing the before/after diff first
- Never assume path mapping when the delta path contains segments that don't exist in main specs — prompt
- Never edit a spec outside `openspec/specs/`
- If the change name is ambiguous (multiple archives match), list them and prompt via AskUserQuestion
- If a merge conflict is detected (main spec changed in a way incompatible with delta), stop that row, report, and offer to skip it

## Out of scope

- Writing new specs from scratch (use `openspec-propose`)
- Bidirectional sync (main → delta)
- Git commits or pushes
- Archiving the change (that's `openspec-archive-change`'s job)
