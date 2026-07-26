# LOOP.md — gtm.nvim

Neovim plugin for the GTM daemon. Communicates via Unix socket IPC.

## Active Loops

### Issue Triage (L1 — report only)
- Cadence: 1d weekdays
- Skill: `loop-triage`
- State: STATE.md
- Phase: Report-only initially. L2 assisted fixes after trust established.
- Handoff: Design decisions, API changes, breaking Neovim compatibility.

### PR Review (L2 — assisted)
- Cadence: on PR creation
- Skill: `loop-triage` + `loop-verifier`
- State: STATE.md
- Phase: Assisted — verifier checks Lua syntax + Neovim API compatibility.
- Handoff: Anything touching plugin/ or lua/gtm/init.lua.

## Worktrees

- Use isolated worktrees for any L2 code changes.

## Budget & Observability

- Token caps: `loop-budget.md`
- Run history: `loop-run-log.md`
- Kill switch: `loop-pause-all` label in STATE.md

## Safety

- Never auto-merge changes to `plugin/` directory.
- All Lua changes must pass luacheck before merge.
