# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Copyright (c) 2025 - present
Author: prjctimg <prjctimg@outlook.com>

This is free software released under the GPL-3.0 license.

## [Unreleased]

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
