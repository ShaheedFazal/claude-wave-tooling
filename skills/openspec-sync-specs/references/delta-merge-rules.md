# Delta Merge Rules

How a delta spec under `openspec/changes/<name>/specs/<capability>/spec.md` is merged into the corresponding main spec at `openspec/specs/<capability>/spec.md`.

## 1. Identity & path mapping

A delta's capability path is the canonical identifier of the main spec it targets.

| Delta path | Main path |
|---|---|
| `specs/shared/architecture/spec.md` | `openspec/specs/shared/architecture/spec.md` |
| `specs/repeat-flow/imports/spec.md` | `openspec/specs/repeat-flow/imports/spec.md` |
| `specs/admin/users/spec.md` | `openspec/specs/admin/users/spec.md` |

Nothing else in the delta filename carries meaning. The directory structure is the contract.

## 2. Action classification

Classification is determined by content markers in the delta, not by any filename convention.

### CREATE
- Main spec file does not exist at the mapped path.
- Action: write the delta verbatim to the main path.

### ADD (additive-only delta)
- Main spec exists.
- Delta contains sections that do **not** appear (by heading) in the main spec.
- Delta contains **no** removal markers and no text that conflicts with existing sections.
- Action: append new sections at end of main spec, preserving order as they appear in the delta.

### MODIFY
- Delta contains sections whose headings **match** sections in the main spec.
- The body text differs.
- Action: for each matching heading, replace the section body in the main spec with the delta's version.

### REMOVE
- Delta contains a marker section indicating removal. Supported markers (case-insensitive heading):
  - `## REMOVED: <section name>`
  - `<!-- remove: <section name> -->`
- Action: delete the named section from the main spec. A single delta may combine REMOVE with ADD/MODIFY — process REMOVE first.

### RENAME
- Delta top matter contains: `<!-- renamed-from: specs/<old-capability>/spec.md -->`
- Action: move the old main spec to the new path *before* applying other actions, so ADD/MODIFY/REMOVE operate on the renamed file.

### NO-OP
- Delta and main spec are byte-identical.
- Action: none. Report as skipped.

## 3. Section boundaries

Sections are delimited by Markdown heading levels:

- Heading of depth N opens a section.
- Section body = all lines until the next heading of depth ≤ N or end of file.

When matching sections across delta ↔ main, compare normalised headings (trim whitespace, collapse internal spaces, case-insensitive). Do not match by heading text containing transient values (dates, PR numbers).

## 4. Conflict handling

A conflict is any of the following:

- Delta heading matches **multiple** headings in main spec (ambiguous).
- Main spec has been edited in a way that makes the delta's MODIFY no longer applicable (e.g. the referenced section was already removed).
- REMOVE targets a heading that does not exist in main spec.

On conflict: stop that row, print the conflict, offer user choice via AskUserQuestion:
- **Skip** — leave this spec alone
- **Force replace** — treat the whole delta as MODIFY for the file
- **Open diff** — print full diff for user judgement

Never silently resolve a conflict.

## 5. Ordering (multi-spec deltas)

When a single change contains deltas for multiple specs, apply in this order:

1. All RENAMEs first (so subsequent actions operate on new paths)
2. CREATEs (independent of other specs)
3. ADDs
4. MODIFYs
5. REMOVEs last (so any ADD/MODIFY doesn't reference a section we're about to delete)

Within a single spec file, apply in the order the actions appear in the delta.

## 6. Idempotency

Running sync twice in a row must be safe:

- Second run of an already-synced change = all rows NO-OP.
- Partial runs: spec-level granularity. If the user picks "Review one by one" and cancels after spec 2 of 5, a re-run should see specs 1–2 as NO-OP and re-offer 3–5.

## 7. Non-goals

- **No semantic merging.** If the delta contradicts main spec in a way that needs human judgement, surface the conflict; do not try to pick a side.
- **No cross-change reconciliation.** This skill handles one change at a time. Competing deltas across changes are a planning problem, not a sync problem.
- **No formatting.** Preserve the delta's exact text when inserting/replacing. Do not rewrap lines, reformat tables, or tidy whitespace. If the main spec uses different formatting, that's a style issue to handle outside this skill.
