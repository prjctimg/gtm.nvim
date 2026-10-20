# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Copyright (c) 2026 - present
Author: prjctimg <prjctimg@outlook.com>

This is free software released under the GPL-3.0 license.

## [Unreleased]

### Added

- Reactive themes can now be **resolved by the daemon**. A gtmd new enough to
  send them broadcasts a `reactive_theme` pulse event: a complete role→colour
  set (`bg0`, `fg`, `accent`, …) for both light and dark, plus a token-set
  version. The plugin maps those roles onto highlight groups — its only colour
  calculation is the background wash — so this plugin, the `gtm` TUI and any
  future editor plugin all render the same colours from the same track.

  The editor's own background selects the polarity, so changing colorscheme
  mid-track re-picks light or dark and re-tints instead of losing the palette.
  A role set missing any required role is ignored outright: a half-applied ramp
  is worse than no ramp. `:checkhealth gtm` reports which source is live.

  This is the client half of `REACTIVE_TOKENS.md` in the
  [gtm repo](https://github.com/prjctimg/gtm). There is no local role
  derivation: against a gtmd that predates role sets the editor stays untinted.

- `theme.intensity` (default `0.25`) tunes the background wash: each background
  steps that fraction of the way toward the album accent, so the tint lands on
  *your* colorscheme's surfaces instead of a fixed dark grey. `0` leaves
  backgrounds alone while accents and syntax still follow the album.

- `:checkhealth gtm`, covering requirements, both socket connections and
  heartbeat freshness, status snapshot staleness, and whether a palette is
  actually flowing — the usual answers to "why is nothing happening".
- `LICENSE`, `CONTRIBUTING.md` and `CODE_OF_CONDUCT.md`, matching GTM's.
- `:Gtm disconnect` and `require("gtm").cycle_repeat()`, `set_volume()`,
  `statusline()` and `lualine_component()` as Lua API.
- `scripts/checkrefs.lua`, which resolves every cross-module call in `init.lua`
  and `health.lua` against the modules as loaded. A renamed helper that one
  caller missed now fails at push rather than at a user's keyboard.
- `:Gtm repeat` with no argument cycles the repeat mode.

### Changed

- **Breaking.** `statusline_format = "compact" | "detailed"` is replaced by a
  per-item table. The default now renders only the source marker and the state
  icon; artist, title, album, progress, time, volume, repeat and shuffle are
  opt-in, so nothing is squeezed into the statusline without asking. Items with
  no data are skipped, which makes the empty state a bare `⏹`. A 0.1.x
  `statusline_format` is still accepted and mapped onto the new table.
- **Breaking.** No keymaps are set by default. The six previous defaults are
  commented out in `plugin_spec.lua` and listed as suggestions in the README.
- Reactive theming now defaults to on. `:Gtm theme reset` still turns it off.
- `statusline.source` renders a playback-source marker, and `statusline.icons`
  makes the marker set configurable. Defaults are Nerd Font codepoints from
  Material Design Icons — `md-spotify` U+F04C7, `md-radio` U+F0439,
  `md-podcast` U+F0994, `md-folder_music` U+F1359, `md-chart_line` U+F012A — with
  a plain-Unicode set documented in the README and help for terminals with no
  patched font. A source gtmd does not name renders nothing rather than guessing.
  It stays empty until gtmd reports a source at all — see `PLAYBACK_SOURCE.md`
  in the gtm repo.
- Bare `:Gtm repeat` cycles off → one → all instead of forcing `all`. An
  explicit mode still sets it directly.

### Removed

- **Breaking.** The local palette derivation in `theme.lua` (79 lines of
  `hsv_to_rgb`/`rgb_to_hsv`/`mix`/`adjust`), along with the `reactive_palette`
  subscription that fed it. gtmd owns the colours outright: a client maps roles
  onto groups and computes nothing but the background wash, which is what keeps
  this plugin, the TUI and future clients rendering the same track identically.

  A gtmd that predates `reactive_theme` now leaves the editor untinted rather
  than deriving its own ramp. That is deliberate — a second derivation is the
  problem, not the solution — but it does mean theming requires the role-set
  daemon.
- `theme.source()`, `theme.roles()`'s `"local"` mode, and the `"derived
  locally"` branch in `:checkhealth gtm`.


- **Breaking.** The feature set is reduced to playback control, statusline
  integration and reactive theming. Everything else reimplemented the `gtm` TUI
  and has been removed rather than maintained:

  | Removed | Replacement |
  |---------|-------------|
  | Floating window (`:Gtm float`, `<Leader>gf`) | The `gtm` TUI |
  | Cover art rendering (`3rd/image.nvim`) | The TUI; the daemon still extracts the palette for theming |
  | Library browser (`:Gtm library`, `:Gtm playlists`, `:Gtm scan`) | The TUI |
  | YouTube search / download (`:Gtm yt`) | The TUI |
  | Equalizer control (`:Gtm eq`) | The TUI |
  | Favourites, queue and playlist commands | The TUI |

  The plugin is ~940 lines of code, down from ~1330.

- `opts.float` (width, height, border, cover_art) and `opts.keymaps.float`.
- `opts.theme.scope` — with no float left, the tint is always global.
- Daemon auto-start. `gtm.nvim` used to spawn `gtmd` when no socket was found.
  A plugin silently starting a server process is not its call to make, so it now
  notifies instead. Start `gtmd` yourself.
- `:Gtm disconnect`. `:checkhealth gtm` reports connection state and reconnection
  is automatic (it no longer gives up), so a command to drop the socket by hand
  was a debug hatch rather than a feature.
- `duration_changed` handling. It patched `status.duration`, which nothing read
  — every duration read goes through the extrapolated clock in `gtm.ipc`.
- `radio_title_changed` handling. Internet radio therefore shows the title that
  arrived with `playback_started` and does not update to the stream's real
  title.

### Fixed

- **A track change did not re-tint until Neovim restarted.** The heartbeat and
  playback events travel on the pulse socket, and that subscriber had no
  reconnection of its own: a stream that died silently — a `gtmd` restart, a
  connect that lost a race with the listener — left both the tint and the
  statusline frozen for the rest of the session while the command socket still
  looked healthy. The subscriber now replaces a dead handle instead of keeping
  it, redials with backoff after EOF or a failed connect, and a watchdog
  reconnects when the heartbeat has been quiet for a minute. The command socket
  no longer gives up after thirty attempts, and the periodic resync tick
  re-claims the pulse socket and re-asserts the tint, so a dropped stream or a
  silently shadowed highlight does not stay wrong.
- **A colorscheme change re-based the tint on the previous scheme's colours.**
  `on_colorscheme` put the tint down by writing the whole old snapshot back —
  including over groups the new scheme had just redefined — and then recorded
  that as the baseline, so a later `:Gtm theme reset` restored colours from the
  scheme the user had left. It now lifts only groups whose current value is
  still the tint it wrote, re-snapshots the scheme that actually loaded, and
  re-applies. It runs deferred through `vim.schedule`, so its handler wins the
  `ColorScheme` ordering, and `:set background=light|dark` is handled the same
  way.
- **Syntax highlighting was not being applied.** `theme.fg_role()` resolved a
  group to a syntax role with `name:gsub("^@", ""):gsub("[%w_]+$", "")`, which
  strips a single-segment name to `""` and leaves a trailing dot on a dotted
  one, so the lookup never matched: every syntax group (`String`, `Keyword`,
  `Function`, `@string`, `@keyword`, …) collapsed to `fg`. On top of that,
  `set_roles` copied only the eleven roles in `NEED`, so the daemon's twelve
  syntax roles were decoded and then discarded. The mapping now resolves exact
  Vim groups and a tree-sitter capture's first segment (`@function.builtin` →
  `function`), and every role the daemon sends is kept. `Comment` takes the
  daemon's `comment` role instead of `fg_dim`.
- **The reactive background was a fixed near-black, not your colorscheme.**
  `bg0` from the daemon is `mix(#0d0d12, primary, 0.06)` — a grey the TUI owns.
  Applying it to `Normal` replaced the editor's own background with something
  darker and barely tinted, which read as "too darkened" and stopped feeling
  reactive. Every background is now a wash of the daemon's `accent` over the
  colour the group already had (`theme.intensity`, default `0.25`), so the
  editor keeps its theme's elevation and gains the album's hue.
- **Reactive theming stopped applying.** gtmd batches `reactive_palette` and
  `reactive_theme` into one pulse frame, palette first. `pulse._frame` peeked
  only the frame's leading tag, and the palette is deliberately unhandled, so
  the entire frame — theme included — was dropped before it was decoded.
  Single-event frames keep the cheap peek; a batch is now decoded in full, which
  is what a batched `reactive_theme` needs. The smoke suite missed it because it
  wrote the two events as separate frames; it now also sends the batch gtmd
  actually sends.
- Quitting nvim while a command-socket connect was still in flight closed the uv
  pipe twice, printing a libuv `handle is already closing` error from inside the
  callback. The late callback now closes only a handle it still owns, and no
  longer clears or reschedules a retry for a socket the user already tore down.

- `restore()` was clearing the stored role sets, so a colorscheme change could
  not re-pick a polarity. `restore()` now keeps them and a new `clear()` — which
  is what `:Gtm theme reset` and playback-stopped call — drops them, so a reset
  is not resurrected by the next `:colorscheme`.

- **Reactive theming never actually worked.** `theme.snapshot()` called
  `vim.api.nvim_get_names()`, which is not a Neovim API, and the derived ramp
  passed `{r, g, b}` tables to `nvim_set_hl`, which requires a `0xRRGGBB`
  integer. The palette path raised on every event before it could tint
  anything. Highlight groups are now enumerated with
  `vim.fn.getcompletion("", "highlight")` and colours are converted to
  integers.
- `:colorscheme` no longer breaks the tint's restore. `on_colorscheme`
  re-snapshotted while the tint was still applied, recording the tint as the
  colorscheme's own baseline, so a later `:Gtm theme reset` was a no-op. It now
  puts the tint down before re-snapshotting.
- `theme.is_enabled()` returned true for `setup({})` and only for
  `opts.reactive == false` otherwise, so the documented default (off) and the
  actual behaviour disagreed. It now reads `opts.reactive == true`.
- Reactive theming recolors the **whole editor**, not just the float.
  Previously only `NormalFloat`/`FloatBorder`/`FloatTitle`/`FloatFooter` and
  the `Gtm*` groups were derived from the album palette, so the active
  colorscheme never appeared to react.
- `setup()` is idempotent: repeated calls (config reload, or the loader's
  default auto-setup racing a host's explicit `setup(opts)`) only re-apply
  options instead of duplicating commands, keymaps, autocmds, track hooks and
  sockets, in any order.
- The loader (`plugin/gtm.lua`) re-checks `vim.g.loaded_gtm` when the
  `VeryLazy` event actually fires, so a host that takes over setup between load
  and `VeryLazy` is never clobbered by a default `setup({})`.
- Status payloads deep-normalize JSON `null` (`vim.NIL`, a truthy sentinel) to
  real `nil` at every ingestion boundary, so an idle daemon sending
  `current_track: null` no longer crashes the statusline.
- `:Gtm theme` read the palette through a helper that no longer existed, so it
  always reported "no palette from the daemon yet" even with a tint applied.
  Every `:Gtm` subcommand now has a smoke check.

## [0.1.0] - 2025-01-01

### Added

- Floating window launcher with playback controls and cover art.
- Statusline integration via lualine component and manual statusline function.
- Library browser with vim motions for navigating tracks and playlists.
- Equalizer preset control with named presets (flat, pop, rock, jazz, etc.).
- YouTube search and download powered by yt-dlp.
- Global keymaps for play/pause, next, prev, volume up/down, stop, and float toggle.
- Unix socket IPC directly to GTM daemon using libuv (`vim.uv`), no CLI wrapper needed.
- Binary frame detection and skipping on the IPC socket.
- Cover art resolution from daemon metadata, local file detection, and ffmpeg extraction with caching.
- `:Gtm` user command with tab completion for all subcommands.
- Queue management: add, remove, move, list, and clear tracks.
- Favourites support: toggle, add, and remove favourites per track.
- Playlist management: create, delete, add/remove tracks from playlists.
- Library scanning and directory import via `:Gtm scan`.
- Shuffle, repeat, mute, and seek controls.
- Volume control with 5% increments.
- Compact and detailed statusline render formats.
- Configurable options via `setup()` for statusline format, float dimensions, border style, and keymaps.
