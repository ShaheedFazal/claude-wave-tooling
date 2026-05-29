# Spec-drift guard (T2.5)

A CI check that protects the OpenSpec **living spec library** from silent drift.

## What it does

When a pull request changes behaviour-bearing application code but touches
**nothing** under `openspec/`, the living spec and the code have drifted apart —
the spec no longer describes what the code does. The guard fails that PR.

It does **not** care *how* the spec was updated — a direct edit to
`openspec/specs/.../spec.md` (right for a small change) and a full
`openspec/changes/<name>/` entry (right for a larger one) both satisfy it. It
only insists that *something* under `openspec/` moved alongside the code.

It is deliberately advisory: the check turns the PR red and explains the gap,
but nothing hard-blocks merge. If a change genuinely needs no spec update, a
maintainer merges past it as a conscious decision — the guard surfaces the
question, the human answers it (the model recommended in
[OpenSpec discussion #169](https://github.com/Fission-AI/OpenSpec/discussions/169)).

For **wave** PRs the guard is effectively blocking anyway: the integrator's
merge contract waits on `gh pr checks --watch --fail-fast`, so a red spec-drift
check halts the integrator until it is resolved.

## How it works

`claude-tooling/.github/workflows/spec-drift.yml` is a reusable workflow. On a
consumer PR it:

1. Reads `applicationCodePaths` from the consumer's `.claude/project.json`.
   Absent → the guard is a no-op (the consumer has not opted in).
2. Diffs `origin/<base>...HEAD`.
3. If any changed file matches `applicationCodePaths` **and** no changed file is
   under `openspec/` → fail with an explanatory message. Otherwise pass.

## Consumer adoption — three steps

### 1. Declare `applicationCodePaths` in `.claude/project.json`

A list of git pathspecs naming behaviour-bearing code. Keep it to code whose
behaviour a spec should describe — not assets, not config noise.

```jsonc
// acme-app (Laravel)
"applicationCodePaths": ["app", "database/migrations", "routes"]

// acme-web (Astro + Payload)
"applicationCodePaths": ["src", "payload/src", "payload/migrations"]
```

### 2. Add the caller workflow

Create `.github/workflows/spec-drift.yml` in the consumer repo:

```yaml
name: spec-drift
on:
  pull_request:
jobs:
  spec-drift:
    uses: ShaheedFazal/claude-wave-tooling/.github/workflows/spec-drift.yml@main
```

### 3. One-time: allow the consumer repo to call the workflow

Because all repos are **private**, claude-tooling must explicitly permit the
consumer repos to reference its reusable workflow:

> claude-tooling → **Settings → Actions → General → Access** →
> "Accessible from repositories owned by **ShaheedFazal**".

Without this, the consumer's caller workflow fails to resolve the `uses:`
reference. This is a GitHub settings change — it cannot be scripted.

## Notes

- Adding `applicationCodePaths` is a backwards-compatible optional schema field
  (no `minimumSchemaVersion` bump — see `CONTRIBUTING.md` §4).
- Tune `applicationCodePaths` over time: too broad and the guard nags on
  no-spec-needed changes; too narrow and real drift slips through. Start with
  the primary source directory and widen only if drift is observed.
