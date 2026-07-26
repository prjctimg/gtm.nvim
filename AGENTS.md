# gtm.nvim - Agent Notes

## Build & Test

No formal build or test suite. Plugin loads directly into Neovim.

## Coding Guidelines

- Use non-deprecated Neovim APIs (v0.11.0+)
- Use module filename first letter instead of default `M` variable
- Use non-blocking constructs for indefinitely running tasks
- Follow conventional commit guidelines

## Architecture

- Communicates with GTM daemon via Unix socket IPC (`vim.uv`)
- Floating window launcher, statusline integration, library browser
- Equalizer control, YouTube search/download, global keymaps

## Loop Engineering

This repo uses loop engineering patterns. See:
- `.opencode/STATE.md` — current loop memory
- `.opencode/LOOP.md` — active loops and cadence
- `.opencode/loop-budget.md` — token caps
- `.opencode/loop-constraints.md` — binding agent rules
- `.opencode/loop-run-log.md` — run history
- `.opencode/gate.yaml` — path denylist + auto-merge allowlist
- `.opencode/skills/` — triage and verifier skills

Start a loop: `opencode run "Run loop-triage. Update .opencode/STATE.md."`
Verify changes: `opencode run "Verify diff in worktree" --agent verifier`
