# gtm.nvim - Agent Notes

## Scope

Three features, deliberately: **playback control**, **statusline integration**,
and **reactive theming**. Anything else belongs to gtmd or its TUI — do not
reimplement a window, picker or library view here. The whole plugin is under
1k lines of code; keep it that way.

## Build & Test

No formal build. Plugin loads directly into Neovim.

```bash
nvim --headless -l scripts/checkrefs.lua   # cross-module calls resolve
nvim --headless -l scripts/smoke.lua       # fake-daemon integration test
nvim --headless -c 'checkhealth gtm' -c qa
luacheck lua plugin                        # optional, if installed
```

`scripts/checkrefs.lua` resolves every `ipc.`/`pulse.`/`theme.` call in
`init.lua` and `health.lua` against the modules as loaded. A renamed helper that
one caller missed is a push-time failure instead of a user-time error.

`scripts/smoke.lua` stands up a fake gtmd (JSON command socket + MessagePack
pulse socket) and asserts on the whole path: connect, prime, position
extrapolation, pulse decoding, tint apply/restore, every `:Gtm` subcommand, and
health. Run it after any change to the IPC, theme or command paths.

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
| `lua/gtm/pulse.lua` | `gtmd.pulse` — length-prefixed MessagePack; peeks the tag, drops telemetry, decodes the rest with `vim.mpack`; owns its reconnection (backoff + heartbeat watchdog) |
| `lua/gtm/theme.lua` | Applies resolved colour roles; snapshots every group and restores on stop; re-derives after a colorscheme change |
| `lua/gtm/health.lua` | `:checkhealth gtm` |

The pulse stream is the source of truth for state changes. Position is
extrapolated locally between events; the `get_status_lite` resync is only a
floor under drift the plugin never heard about.

The two sockets heal independently: the command socket retries forever, and the
pulse socket redials on EOF or a silent heartbeat. A resync tick re-claims the
pulse socket and re-asserts the tint, so a stream that dies quietly cannot leave
the editor stuck on a previous track.

## Conventions worth keeping

The statusline is a list of items in `defaults.statusline`, rendered in table
order. Two items are on by default — `source` and `state` — and the rest are
opt-in, so nothing appears without being asked for. An item with no data is
skipped, which is what makes the empty state a bare `⏹`. Adding an item means
adding a key to the defaults, the spec and the docs; there is no second format.

There are no default keymaps. `CMDS` carries `key`/`desc` per entry so an opted-in
mapping is one line, and the README lists the suggestions.

`statusline.source` renders nothing until gtmd reports a playback source — see
`PLAYBACK_SOURCE.md` in the gtm repo, alongside `REACTIVE_TOKENS.md` for the
`reactive_theme` role sets.

## Colour ownership

gtmd resolves the reactive colours, not the plugin: `REACTIVE_TOKENS.md` in the
[gtm](https://github.com/prjctimg/gtm) repo defines a `reactive_theme` event
carrying a resolved role→colour set for both polarities, so this plugin, the TUI
and future clients agree.

**`theme.lua` derives no role.** It picks a polarity and maps roles onto
highlight groups. There must be no second ramp again — two derivations is
exactly how two clients end up rendering the same track differently. A daemon
without role sets tints nothing, which is correct.

The one colour calculation the client owns is the **background wash**: each
background is stepped `theme.intensity` of the way toward the daemon's `accent`
role. The daemon cannot produce this, because it does not know which colorscheme
the editor runs — a background that is *your* theme warmed by the album has to
be blended against a colour only the client has. It is a surface policy, not a
role derivation: no role the daemon named is recomputed, and every non-background
role (syntax, accents, selection, search, lines, cursor) is applied verbatim.

A role set missing any role in `NEED` is ignored outright: a half-applied ramp
is worse than no ramp. Every other role is applied when present and skipped when
absent, so a client built against a newer set degrades instead of failing.