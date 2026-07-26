# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Copyright (c) 2025 - present
Author: prjctimg <prjctimg@outlook.com>

This is free software released under the GPL-3.0 license.

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
