# AGENTS.md

## Agent skills

### Issue tracker

Issues and specs live as GitHub issues. See `docs/agents/issue-tracker.md`.

### Triage labels

Five canonical labels: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context layout: a root `GLOSSARY.md` plus `docs/adr/`. See `docs/agents/domain.md`.

## Ground rules

### The Main Flow

`/grill-with-docs` → `/to-spec` → `/to-tickets` → `/implement` → `/code-review` → `/retro`. The user invokes each step; the agent never pre-empts.

- `/grill-with-docs` — conversation only, except `GLOSSARY.md` (term resolved) and `docs/adr/` (decision is hard to reverse, surprising without context, a real trade-off).
- `/to-spec`, `/to-tickets`, `/retro` — issue-tracker only.
- `/implement`, `/code-review` — code and doc changes scoped to one ticket.

### Popup questionsff

When asking the user a structured question (multiple bounded options, single-choice, yes/no), invoke the `question` tool for popup-style choice. Fall back to plain text only when the popup UI is unreliable. Each question is single-select unless the user explicitly asks for multi-select.

### Commits

The user decides when code is committed. The agent never runs `git commit`, `git push`, `git add`, or any other state-changing git command without explicit user invocation. Even after `/implement` or `/code-review` produces changes, those changes sit in the working tree until the user says `commit` (or similar). Read-only inspection (`git log`, `git status`, `git diff`) is fine.
