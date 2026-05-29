# Feedback pool

Append-only pool of observations from consumer-project retros. Shared-meta findings land here so the next maintainer session in `claude-tooling` has a single place to look.

**How this file is used**

- Consumer retros (`/wave:retro` running in a consumer repo) append short observations here when a finding is scoped `shared-meta`. They do not propose diffs; they describe what was seen.
- Each consumer's `/wave:planner` Phase 3 surfaces "N new feedback entries since <timestamp>" via a sentinel (`{{config.stateDir}}/.feedback-seen`). No explicit mark-read action.
- When you, the maintainer, sit down to evolve shared skills, scan new entries and decide which to act on. Acting on an entry is a normal edit → commit → push cycle; no ceremony required here.

**Format — one observation per entry, newest-first**

```markdown
## YYYY-MM-DDTHH:MM:SSZ — <project-name> / <wave-name-or-issue>

- **Saw:** <1-2 sentence description of what happened>
- **Context:** <pointer to consumer retro log entry or wave branch>
- **Hypothesis (optional):** <one line — "might suggest X for shared skills"; leave out if unclear>
```

Short. Prose, not diffs. If you find yourself writing more than 8 lines, you're probably proposing a fix — that work belongs in an actual commit against `claude-tooling/skills/wave-*/`, not here.

**Not in scope for this file**

- Applied patches / PR references — those live in git history.
- Read/unread state — every entry stays here until you decide to delete it (typically never).
- Project-skill findings — those stay in the consumer's retro log.
- Config findings — those live in the consumer's retro log too; schema changes travel via MIGRATIONS.md.

---
