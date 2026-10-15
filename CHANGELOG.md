# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Copyright (c) 2026 - present
Author: prjctimg <prjctimg@outlook.com>

This is free software released under the GPL-3.0 license.

## [Unreleased]

### Removed

- **Breaking.** The feature set is reduced to playback control, statusline
  integration and reactive theming. Everything else was a reimplementation of
  the `gtm` TUI and has been removed rather than maintained:

  | Removed | Replacement |
  |---------|-------------|
  | Floating window (`:Gtm float`, `<Leader>gf`) | The `gtm` TUI |
  | Cover art rendering (`3rd/image.nvim`) | The TUI; the daemon still extracts the palette for theming |
  | Library browser (`:Gtm library`, `:Gtm playlists`, `:Gtm scan`) | The TUI |
  | YouTube search / download (`:Gtm yt`) | The TUI |
  | Equalizer control (`:Gtm eq`) | The TUI |
  | Favourites, queue and playlist commands | The TUI |

  The plugin is now ~976 lines of code, down from ~1327.

- `opts.float` (width, height, border, cover_art) and `opts.keymaps.float`.
- `opts.theme.scope` — with no float left, the tint is always global.
- `opts.theme.intensity` — it was declared in the defaults and never read by
  the theme module; the ramp's saturation is derived from the palette.
- Daemon auto-start. `gtm.nvim` used to spawn `gtmd` when no socket was found.
  A plugin silently starting a server process is not its call to make, so it now
  notifies instead. Start `gtmd` yourself.

### Added

- `:checkhealth gtm`, covering requirements, both socket connections and
  heartbeat freshness, status snapshot staleness, and whether a palette is
  actually flowing — the usual answers to "why is nothing happening".
- `LICENSE`, `CONTRIBUTING.md` and `CODE_OF_CONDUCT.md`, matching GTM's.
- `:Gtm disconnect` and `require("gtm").cycle_repeat()`, `set_volume()`,
  `statusline()`, `lualine_component()`, `reset_theme()` as Lua API.

### Changed

- The hand-rolled MessagePack decoder (`gtm/msgpack.lua`, 475 lines) and the
  separate event layer (`gtm/events.lua`) are merged into `gtm/pulse.lua`.
  Frames are still peeked by tag and unrecognised ones dropped without being
  decoded, so 60 Hz telemetry costs nothing — but the frames that *are* wanted
  are now decoded by `vim.mpack`, which ships with Neovim.
- `theme.extra_groups` now tints groups in the global scope only.

### Fixed

- **Reactive theming never actually worked.** `theme.snapshot()` called
  `vim.api.nvim_get_names()`, which is not a Neovim API, and the derived
  ramp passed `{r, g, b}` tables to `nvim_set_hl`, which requires a `0xRRGGBB`
  integer. The palette path raised on every event before it could tint
  anything. Highlight groups are now enumerated with
  `vim.fn.getcompletion("", "highlight")` and colours are converted with
  `as_int()`.
- `theme.is_enabled()` returned true for `setup({})` and only for
  `opts.reactive == false` otherwise, so the documented default (off) and the
  actual behaviour disagreed. It now reads `opts.reactive == true`.

### Fixed

- Reactive theming now recolors the **whole editor**, not just the float.
  Previously only `NormalFloat`/`FloatBorder`/`FloatTitle`/`FloatFooter`
  and the `Gtm*` groups were derived from the album palette, so the active
  colorscheme never appeared to react. `theme.scope` (default `"global"`)
  now snapshot-washes every surface group's background and re-tints the
  standard syntax/UI accent groups, and `ColorScheme` re-snapshots the new
  scheme before re-applying — so the tint is persistent across theme swaps
  instead of being lost when `Normal` itself was never touched.

- `I.setup()` is now idempotent: repeated calls (config reload, or the
  loader's default auto-setup racing a host's explicit `setup(opts)`) only
  re-apply options instead of duplicating commands, keymaps, autocmds,
  track hooks, and sockets. `setup` is safe to call from both the loader
  and a plugin manager in any order.
- The loader (`plugin/gtm.lua`) no longer marks the plugin as owned at load
  time; it re-checks `vim.g.loaded_gtm` when the `VeryLazy` event actually
  fires, so a host that takes over setup between load and `VeryLazy` is
  never clobbered by a default `setup({})`. Docs: set
  `vim.g.loaded_gtm = true` before the plugin loads to run your own setup.
- Status payload robustness: JSON `null` decodes to `vim.NIL`, a truthy
  sentinel that slips through `if x then` / `x or fallback` idioms — an idle
  daemon sending `current_track: null` crashed `statusline()` and the float
  with "attempt to index vim.NIL". Payloads are now deep-normalized
  (`vim.NIL` → `nil`) at every ingestion boundary (`_set_status`, track
  events, library lists), and track-consuming code guards on
  `type(track) == "table"`. `statusline()` returns " " while idle and the
  compact/detailed text once a track is loaded.

### Added

- Cover art rendering in the float via `3rd/image.nvim` (optional
  dependency); artwork is fetched daemon-first with `get_cover_art`,
  decoded, and cached under `stdpath("cache")/gtm/cover`.
- Reactive theming: when `opts.theme.reactive` is set, a 3-color palette
  is derived from the current album art (ffmpeg/ImageMagick 24x24 RGB
  quantization) and re-tints the float's global highlights — background
  wash at `opts.theme.intensity`, contrast-preserving text/border hues.
  The tint survives pauses, restores exactly on stop / track change /
  colorscheme swap / close, and is inspectable via `:Gtm theme status`
  and clearable via `:Gtm theme reset`.
- `theme.extra_groups` option to tint extra highlight names alongside the
  float groups.
- `theme.scope` option (`"global"` | `"float"`) to choose between
  whole-editor reactive theming and float-only tinting.

### Changed

- Events now arrive over a dedicated `gtmd.pulse` socket (MessagePack
  frames with 4-byte big-endian framing) subscribed at connect time;
  the old `get_status` polling loop is gone. A `get_status_lite` resync
  every `resync_interval` (30 s) keeps state fresh.
- The float was rewritten as a native Neovim float with a left-panel cover
  window and per-line `Gtm*` highlight records; text is indented by the
  cover size when artwork is rendered.
- `get_cover_art` responses are flattened to `data` on the command
  envelope; library/queue payloads use `tracks`, `playlists`,
  `queue`+`cursor`, `results`, `info` response keys.
- Status wire values (`status`, `repeat`) are normalized to lowercase in
  the plugin (`Paused` → `paused`, `One` → `one`).
- `cycle_repeat` maps `off|one|all` to the daemon's PascalCase `RepeatMode`
  (`Off`/`One`/`All`).
- The null-safe binary writes in the cover cache use Lua `io` (binary
  strings can't round-trip through VimL `writefile`).

### Removed

- The `handshake` command: connect now just subscribes to `gtmd.pulse` and
  takes a `get_status` snapshot (daemon protocol break, no fallback).
- `statusline_interval` option (replaced by `resync_interval`).

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
