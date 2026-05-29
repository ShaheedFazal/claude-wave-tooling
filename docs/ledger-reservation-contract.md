# Decision-ledger reservation contract

**Audience.** Per-consumer brainstorm and analyst skills (`/<prefix>:brainstorm`, `/<prefix>:analyst`) that allocate monotonic decision IDs (`D-NNN`) into a project-local decisions ledger.

**Status.** Binding contract for every consumer that uses a `D-NNN`-style ledger. Existing implementations: `acme-web/.claude/skills/web-brainstorm/SKILL.md` and `acme-app/.claude/skills/app-brainstorm/SKILL.md`. New consumers MUST follow this protocol when authoring their first brainstorm skill.

## Why this exists

Recorded in [`FEEDBACK.md`](../FEEDBACK.md) on 2026-04-22 and 2026-04-24 — three waves on the Acme Web project collided on the same `D-NNN` slots in a four-hour window because each brainstorm independently read `Last ID allocated: D-NNN` and picked `D-NNN+1`. The renumber-resolver commit then collided with a third concurrent wave. The renumber ceremony cost was substantial: detail-file renames, frontmatter rewrites, OpenSpec artifact updates, issue-body edits, test-assertion updates, GitHub-comment fixes — all to undo a structurally-inevitable collision in a monotonic-ID scheme without a central authority.

The fix below is per-decision **reserve → write → release** with a committed footer entry on `main`. It costs two extra commits per decision; it is dramatically cheaper than the renumber ceremony.

## The protocol

Every brainstorm/analyst that allocates a new `D-NNN` MUST follow this cycle, **once per decision** (do not batch the reservation):

### Step 1 — Pre-claim scan

Compute `next_free` from BOTH the ledger footer's `**Last ID allocated:**` and any `**Reserved:**` entries. Reservations are pending claims from other in-flight brainstorms; treating them like merged decisions is the entire point.

```bash
# Pseudocode — adapt to consumer's ledger path
LAST=$(grep -E '^\*\*Last ID allocated:\*\*' docs/<ledger>.md | grep -oE 'D-[0-9]+' | sort -u | tail -1)
RESERVED=$(grep -E '^\*\*Reserved:\*\*' docs/<ledger>.md | grep -oE 'D-[0-9]+' | sort -u)
NEXT_FREE = max(LAST, max(RESERVED)) + 1   # zero-pad to 3 digits
```

If the ledger has no `**Last ID allocated:**` footer (first decision in a fresh ledger), start at `D-001` and author the footer in this same close-out.

**Belt-and-braces scan across active worktrees and unmerged commits:**

```bash
# Surface any D-NNN that's been written to a detail file or branch but
# never reserved on main — these are protocol violations to clean up.
git log --all --source -- 'docs/decisions/D-*.md' | grep -oE 'D-[0-9]+' | sort -u
find ../*/docs/decisions/ -name 'D-*.md' 2>/dev/null | grep -oE 'D-[0-9]+' | sort -u
```

Any ID surfaced here that is NOT in the ledger or reservation list means a brainstorm filed a detail file without reserving first — reclaim by bumping `next_free` past that ID.

### Step 2 — Reserve the ID on `main`

Append a `**Reserved:**` line to the ledger footer (immediately below `**Last ID allocated:**`) and commit directly to `main`:

```markdown
**Last ID allocated:** D-129
**Reserved:** D-130 (brainstorm #316, pending close-out)
**Reserved:** D-131 (brainstorm #316, pending close-out)
**Reserved:** D-132 (brainstorm #323, pending close-out)
```

```bash
git add docs/<ledger>.md
git commit -m "chore(ledger): reserve D-NNN for brainstorm #<N>"
git push origin main
```

This commit MUST land on `main` before any detail file is written. Concurrent brainstorms reading the ledger after this commit see the reservation and skip past it. The pre-push race (two brainstorms pushing the same reservation simultaneously) is resolved by `git push` itself rejecting the second push as non-fast-forward; that brainstorm pulls, re-runs the pre-claim scan, and picks a higher number.

### Step 3 — Write the detail file and ledger row

After the reservation commits successfully, create the detail file at `docs/decisions/D-NNN-<slug>.md` and append the ledger row in the same wave branch where the brainstorm is being closed out.

### Step 4 — Release the reservation at close-out

When the brainstorm's PR (or close-out commit) lands the actual decision row on `main`, **remove the corresponding `**Reserved:**` line** in the same commit. The footer should at all times reflect "what's pending" minus "what's now allocated".

```markdown
**Last ID allocated:** D-132
**Reserved:** D-141 (brainstorm #323, pending close-out)
```

If a brainstorm is abandoned, the cleanup is also "remove the reservation line" — but this is a separate commit, not lazy. Stale reservations cost subsequent brainstorms ID-space; treat them as litter.

## The collision-resolver clause

When two reservations DO collide despite this protocol (e.g. a brainstorm opened a worktree before the protocol was added; or the protocol was honoured but a third wave was launched between the pre-claim scan and the reservation push), the renumber-resolver MUST itself run the protocol:

1. Reserve the new IDs on `main` BEFORE renaming any files
2. Then perform the rename in a single subsequent commit
3. Release the old reservations as part of the renumbering commit

The 2026-04-24 incident in Acme Web happened because the resolver chose `D-141..D-143` without scanning active worktrees — `wave-306-308-migration-hardening` had already reserved those slots locally, and the resolver became the second collision. The contract above prevents this: a resolver that runs the protocol cannot pick a colliding number.

## What this contract does NOT solve

- **Ledger schema validation.** This contract handles ID allocation; it does not validate that ledger row formats stay consistent. Each consumer's ledger has its own column conventions, supersedes-link discipline, and area-tag vocabulary — those are per-consumer concerns documented in the ledger header.
- **Cross-project reservation.** Each consumer ledger has its own ID space; `D-100` in Acme Web is unrelated to `D-100` in Acme App. The contract is per-ledger, not global.
- **Retroactive cleanup.** If two waves have already shipped colliding decisions on `main`, this contract is silent — the renumber-resolver clause above only governs how to *resolve* such collisions; it does not detect them. A periodic ledger audit (e.g. the consumer's retro skill) is the right place for that.

## Pointer for consumer authors

When authoring `<prefix>:brainstorm` (or `<prefix>:analyst` if it allocates D-IDs), include a paragraph that:

1. References this contract by path
2. Names the consumer's specific ledger path (e.g. `docs/decisions.md`, `docs/decisions.md`)
3. Inlines the protocol's reserve → write → release cycle as concrete bash so the agent doesn't have to context-switch to read this file mid-brainstorm

The two existing implementations cited at the top of this document follow this pattern.
