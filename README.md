# gtm.nvim

[![Version](https://img.shields.io/github/v/release/prjctimg/gtm.nvim)](https://github.com/prjctimg/gtm.nvim/releases)
[![License: GPLv3](https://img.shields.io/badge/license-GPLv3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)
[![Neovim](https://img.shields.io/badge/neovim-0.9+-green.svg)](https://neovim.io)

Neovim plugin for the GTM terminal music player. Controls playback, library, and equalizer directly from Neovim.

## Requirements

- Neovim 0.9+
- [GTM daemon](https://github.com/prjctimg/gtm-rs) (`gtmd`) running
- `yt-dlp` (optional, for YouTube search/download)

## Install

```lua
-- lazy.nvim
{
  "prjctimg/gtm.nvim",
  opts = {
    statusline_format = "compact",
    float = {
      width = 0.8,
      height = 0.8,
      border = "rounded",
      cover_art = false,
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
| `:Gtm library` | Open library browser |
| `:Gtm playlists` | Open playlist list |
| `:Gtm scan {path}` | Scan directory into library |
| `:Gtm eq {preset}` | Set equalizer preset |
| `:Gtm yt {query}` | Search YouTube |

See `:help gtm.nvim` for full keymaps and library buffer bindings.

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

The plugin connects to the daemon's Unix socket via `vim.uv`, exchanging JSON line-delimited requests/responses. MessagePack binary event frames are detected and skipped. No CLI wrapper needed.

```
Neovim (init.lua) ── Unix socket ──► gtmd
  │  JSON line requests              │
  │  ◄── JSON responses              │
  │  ◄── MessagePack events (skipped)│
  │                                  │
  ├── IPC / Float / Statusline       │
  ├── Library / Equalizer / YouTube  │
  └── Commands & keymaps             │
```

## Specification

- [gtm.spec](https://github.com/prjctimg/gtm.spec) — full specification
- [Protocol](https://github.com/prjctimg/gtm.spec/blob/main/protocol.md) — IPC protocol reference
- [Configuration](https://github.com/prjctimg/gtm.spec/blob/main/man/gtm-config.1.md) — daemon configuration

## License

[GPLv3](https://www.gnu.org/licenses/gpl-3.0) — same as GTM.
