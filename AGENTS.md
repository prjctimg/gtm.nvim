# gtm.nvim - Agent Notes

## Scope

Three features, deliberately: **playback control**, **statusline integration**,
and **reactive theming**. Anything else belongs to gtmd or its TUI — do not
reimplement a window, picker or library view here. The whole plugin is under
1k lines of code; keep it that way.

## Build & Test

No formal build. Plugin loads directly into Neovim.

```bash
nvim --headless -l scripts/smoke.lua   # fake-daemon integration test
nvim --headless -c 'checkhealth gtm' -c qa
luacheck lua plugin                    # optional, if installed
```

`scripts/smoke.lua` stands up a fake gtmd (JSON command socket + MessagePack
pulse socket) and asserts on the whole path: connect, prime, position
extrapolation, pulse decoding, tint apply/restore, commands and health. Run it
after any change to the IPC or theme paths.

## Coding Guidelines

- Use non-deprecated Neovim APIs (v0.11.0+)
- Use module filename first letter instead of default `M` variable
- Use non-blocking constructs for indefinitely running tasks
- Follow conventional commit guidelines

## Architecture

Two Unix sockets to gtmd, both non-blocking via `vim.uv`:

| Module | Role |
|--------|------|
| `lua/gtm/init.lua` | Public API, `:Gtm`, keymaps, setup, statusline rendering |
| `lua/gtm/ipc.lua` | `gtmd.sock` — newline JSON, request/response by `id`, reconnect with backoff, status snapshot |
| `lua/gtm/pulse.lua` | `gtmd.pulse` — length-prefixed MessagePack; peeks the tag, drops telemetry, decodes the rest with `vim.mpack` |
| `lua/gtm/theme.lua` | Palette → highlight ramp; snapshots every group and restores on stop |
| `lua/gtm/health.lua` | `:checkhealth gtm` |

The pulse stream is the source of truth for state changes. Position is
extrapolated locally between events; the `get_status_lite` resync is only a
floor under drift the plugin never heard about.