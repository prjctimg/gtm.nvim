# gtm.nvim - Agent Notes

## Scope

Four features, deliberately: **playback control**, **statusline integration**,
**native pickers over the queue and library**, and **reactive theming**. The
pickers are `vim.ui.select` menus over existing daemon commands — do not add a
custom window, list, cover renderer or editor here. Anything that needs its own
interface belongs to gtmd or its TUI. Keep the runtime small; delegate to the
daemon and to `vim.ui.select` instead of growing a second UI.

## Build & Test

No formal build. Plugin loads directly into Neovim.

```bash
nvim --headless -l scripts/checkrefs.lua   # cross-module calls resolve
nvim --headless -l scripts/smoke.lua       # fake-daemon integration test
nvim --headless -c 'checkhealth gtm' -c qa
luacheck lua plugin scripts                 # optional, if installed
```

`scripts/checkrefs.lua` loads `gtm` and resolves every `ipc.`/`pulse.`/`theme.`
call in `init.lua` and `health.lua` against the internal tables as they actually
load. A renamed helper that one caller missed is a push-time failure instead of
a user-time error.

`scripts/smoke.lua` stands up a fake gtmd (JSON command socket + MessagePack
pulse socket) and asserts on the whole path: connect, prime, position
extrapolation, pulse decoding, tint apply/restore, every non-picker `:Gtm`
subcommand, every picker (queue, Spotify, radio, library), and health. Run it
after any change to the IPC, theme, picker or command paths.

## Coding Guidelines

- Use non-deprecated Neovim APIs (v0.11.0+)
- Use the module's letter for its table (`I` in `init.lua`), not the default `M`
- Use non-blocking constructs for indefinitely running tasks
- Follow conventional commit guidelines

## Architecture

Two Unix sockets to gtmd, both non-blocking via `vim.uv`.

Everything lives in `lua/gtm/init.lua`; `lua/gtm/health.lua` is only a
`:checkhealth` discovery shim. Inside `init.lua`:

| Section | Role |
|---------|------|
| Shared | The helpers more than one section needs: the notification marker, the timer teardown, the empty-string guard, the timestamp format |
| IPC | `gtmd.sock` — newline JSON, request/response by `id`, reconnect with backoff, status snapshot |
| Theme | Applies resolved colour roles; snapshots every group and restores on stop; re-derives after a colorscheme change |
| Pulse | `gtmd.pulse` — length-prefixed MessagePack; peeks the tag, drops telemetry, decodes the rest with `vim.mpack`; owns its reconnection (backoff + heartbeat watchdog) |
| Pickers | `vim.ui.select` pickers over the queue, Spotify, radio and the local library; labels and IPC only |
| Health | The `:checkhealth gtm` checks |
| Public API | `I.opts`, `:Gtm`, keymaps, setup, statusline rendering |

The internal tables are reached as `I._ipc`, `I._pulse` and `I._theme` (the
health shim and the smoke test use these; they are not public API).

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
adding a key to the defaults, the renderer and the docs; there is no second
format.

There are no default keymaps. `CMDS` carries `key`/`desc` per entry so an opted-in
mapping is one line, and the README lists the suggestions.

Every message the plugin shows goes through the shared `notify` helper and
carries the same marker: `[gtm] 📻️ `. It is a constant, not an option, and not
the source icon the statusline uses — a notification is not a statusline. A new
message goes through that helper, not through `vim.notify` directly.

Browsing is `vim.ui.select` only. The selector plugin supplies search and
filtering; the picker section of `init.lua` supplies labels and the IPC calls.
Keep destructive queue actions behind explicit subcommands (`queue remove`,
`queue clear`) so selecting a row only plays it.

`statusline.source` renders nothing until gtmd reports a playback source — see
`PLAYBACK_SOURCE.md` in the gtm repo, alongside `REACTIVE_TOKENS.md` for the
`reactive_theme` role sets.

## Colour ownership

gtmd resolves the reactive colours, not the plugin: `REACTIVE_TOKENS.md` in the
[gtm](https://github.com/prjctimg/gtm) repo defines a `reactive_theme` event
carrying a resolved role→colour set for both polarities, so this plugin, the TUI
and future clients agree.

**The theme section derives no role.** It picks a polarity and maps roles onto
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