# Loop Constraints — gtm.nvim

> The `loop-triage` and `loop-verifier` skills read this file at the start of every run.
> Constraints here are **binding** — the agent MUST follow them.

## Push & Merge
- Never auto-merge to main without human approval
- Always create a draft PR first

## Paths
- Never edit `.git/` or hidden config files
- Never auto-edit `plugin/` directory — flag for human review

## Code
- Use non-deprecated Neovim APIs (v0.11.0+)
- Use module filename first letter instead of default `M` variable
- Use non-blocking constructs for indefinitely running tasks
- Follow conventional commit guidelines

## Communication
- Always tell the user what you're about to do before doing it
- Never close an issue or PR without approval

## Budget
- If token spend hits 80% of daily cap, switch to report-only
- If loop-pause-all is active, exit immediately
