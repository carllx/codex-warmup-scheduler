# Agent Guidelines

## Agent skills

### Issue tracker

Issues and specs live in GitHub Issues (`carllx/codex-warmup-scheduler`). See `docs/agents/issue-tracker.md`.

### Domain docs

Single-context repository layout. See `docs/agents/domain.md`.

## Agent navigability

- **LOC as a review signal**: Line count is a review signal, not a rigid mechanical metric.
- **Preferred file size**: Keep authored files under ~400 LOC whenever feasible.
- **500 LOC warning**: When a file exceeds 500 LOC, inspect for natural architectural seams.
- **700 LOC hard ceiling**: Files exceeding 700 LOC must not continue growing without explicit documentation explaining why retaining a single deep module is cleaner.
- **No shallow decomposition**: Do not mechanically fragment code into shallow pass-through modules just to satisfy LOC targets.
- **Architecture over metric**: Prioritize deep modules, small interfaces, locality, and testability.
- **Exclusions**: Generated schemas, test fixtures, and vendored/generated artifacts are exempt from these guidelines.
