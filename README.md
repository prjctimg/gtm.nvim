# gtm.nvim

[![Version](https://img.shields.io/github/v/release/prjctimg/gtm.nvim)](https://github.com/prjctimg/gtm.nvim/releases)
[![License: GPLv3](https://img.shields.io/badge/license-GPLv3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)
[![Neovim](https://img.shields.io/badge/neovim-0.9+-green.svg)](https://neovim.io)

Neovim plugin for the GTM terminal music player. Controls playback, library, and equalizer directly from Neovim.

## Requirements

- Neovim 0.9+
- [GTM daemon](https://github.com/prjctimg/gtm-rs) (`gtmd`) running
- `yt-dlp` (optional, for YouTube search/download)
- [3rd/image.nvim](https://github.com/3rd/image.nvim) (optional, for cover art rendering in the float)

## Install

```lua
-- lazy.nvim
{
  "prjctimg/gtm.nvim",
  dependencies = {
    -- optional: artwork in the float window
    { "3rd/image.nvim", optional = true },
  },
  opts = {
    statusline_format = "compact",
    float = {
      width = 0.8,
      height = 0.8,
      border = "rounded",
      cover_art = true, -- requires 3rd/image.nvim
    },
    -- tint the whole editor (surfaces + accents) from the album art
    theme = {
      reactive = true, -- default false
      intensity = 0.2, -- 0..0.5 background wash strength
      scope = "global", -- "global" (whole editor) | "float"
    },
    keymaps = {
      play_pause = "<leader>gp",
      next = "<leader>gn",
      prev = "<leader>gN",
      volume_up = "<leader>g>",
      volume_down = "<leader>g<",
      float = "<leader>gf",
      stop = "<leader>gS",
    },
  },
}
```

## Commands

| Command | Description |
|---------|-------------|
| `:Gtm float` | Toggle floating window |
| `:Gtm play` | Toggle play/pause |
| `:Gtm next` / `:Gtm prev` | Next / previous track |
| `:Gtm stop` | Stop playback |
| `:Gtm volup` / `:Gtm voldown` | Volume ±5% |
| `:Gtm shuffle` | Toggle shuffle |
| `:Gtm repeat {off\|one\|all}` | Set repeat mode |
| `:Gtm seek {secs}` | Seek to position |
| `:Gtm status` | Show current track |
| `:Gtm theme {status\|reset}` | Show reactive palette hexes / clear the tint |
| `:Gtm library` | Open library browser |
| `:Gtm playlists` | Open playlist list |
| `:Gtm scan {path}` | Scan directory into library |
| `:Gtm eq {preset}` | Set equalizer preset |
| `:Gtm yt {query}` | Search YouTube |

See `:help gtm.nvim` for full keymaps and library buffer bindings.

## Cover art

Cover art is resolved daemon-first: the plugin asks `gtmd` via
`get_cover_art`, decodes the base64 payload, and caches it under
`stdpath("cache")/gtm/cover` keyed by track hash — a flat directory that is
never scanned. When artwork can't be rendered (no `image.nvim`), the float
falls back to a `♪` placeholder.

## Reactive theming

When `opts.theme.reactive = true`, the plugin derives a 3-color palette from
the current album art (downscaled to 24×24 raw RGB via ffmpeg or
ImageMagick) and re-tints the editor:

- every surface group's background takes an ambient wash of the dominant
  color at `opts.theme.intensity` (clamped 0..0.5), so the whole scheme —
  not just the float — reacts to the artwork;
- the standard syntax/UI accent groups (`Title`, `Function`, `Keyword`,
  `Type`, `String`, ...) take the palette's primary/secondary/tertiary
  colors through a contrast-preserving adjust;
- dim foreground colors are re-tuned for readability against the tint.

Semantic colors are deliberately left untouched: error, warning, diff,
diagnostic, spell and `Todo` groups keep their meaning. The float's own
groups additionally receive an explicit derivation (background wash +
per-line accents).

Set `opts.theme.scope = "float"` to limit the tint to the float's groups.
`opts.theme.extra_groups` accepts additional highlight names to tint.

The tint stays applied while playback is paused and is restored exactly
(per-group `nvim_get_hl` snapshots of the groups actually touched) on stop,
track change, colorscheme swap (`ColorScheme` rebundle), or plugin close.
`:Gtm theme status` prints the active palette hexes; `:Gtm theme reset`
clears the tint.

## Statusline

```lua
-- lualine.nvim
require("lualine").setup({
  sections = {
    lualine_x = {
      require("gtm").lualine_component(),
    },
  },
})
```

**Compact:** `Artist - Title ▶ vol:80% ━━━━━━━━━━━━━━━━━━━━`
**Detailed:** `▶ Artist / Title (Album) [01:23/04:56] vol:80% 🔁 🔀`

## Architecture

The plugin talks to the daemon over two Unix sockets using `vim.uv`:

- a command socket (`gtmd.sock`) for JSON line-delimited request/response
  pairs, and
- a pulse socket (`gtmd.pulse`) for MessagePack event frames — the plugin
  subscribes at startup, so no polling is needed. A lightweight
  `get_status_lite` resync every 30 s keeps drift out.

```
Neovim (init.lua) ── Unix socket ──► gtmd
  │  JSON requests (gtmd.sock)      │
  │  ◄── JSON responses             │
  │  MessagePack events (gtmd.pulse)│
  │  ◄── heartbeat / state frames   │
  │                                 │
  ├── IPC / Float / Statusline      │
  ├── Cover art + reactive theme    │
  ├── Library / Equalizer / YouTube │
  └── Commands & keymaps            │
```

## Specification

- [gtm.spec](https://github.com/prjctimg/gtm.spec) — full specification
- [Protocol](https://github.com/prjctimg/gtm.spec/blob/main/protocol.md) — IPC protocol reference
- [Configuration](https://github.com/prjctimg/gtm.spec/blob/main/man/gtm-config.1.md) — daemon configuration

## Contributors

<!-- CONTRIBUTORS -->
<p align="left">
  <a href="https://github.com/iseeheaven"><img src="https://github.com/iseeheaven.png?size=80" width="50" height="50" style="border-radius:50%;margin:4px;" alt="iseeheaven"/></a> <a href="https://github.com/prjctimg"><img src="https://github.com/prjctimg.png?size=80" width="50" height="50" style="border-radius:50%;margin:4px;" alt="prjctimg"/></a>
</p>
<!-- /CONTRIBUTORS -->

## License

[GPLv3](https://www.gnu.org/licenses/gpl-3.0) — same as GTM.
