# gtm.nvim

Neovim plugin for the [GTM](https://github.com/skchr/gtm-rs) terminal music player.

Provides floating window launcher, statusline integration, library browser,
equalizer control, YouTube search/download, and global keymaps
for controlling the GTM daemon directly from Neovim via Unix socket IPC.

## Requirements

- Neovim 0.9+
- [GTM](https://github.com/skchr/gtm-rs) daemon (`gtmd`) running
- `yt-dlp` (optional, for YouTube features)
- No external dependencies for core features (uses `vim.uv` / libuv for socket I/O)

### Cover Art (optional)

- [3rd/image.nvim](https://github.com/3rd/image.nvim) for image rendering
- A supported backend: Kitty (recommended), ueberzugpp, or Sixel
- [ImageMagick](https://imagemagick.org/) for image processing
- `ffmpeg` for embedded thumbnail extraction (fallback)

## Install

### lazy.nvim

```lua
{
  "prjctimg/gtm.nvim",
  opts = {
    statusline_format = "compact",  -- "compact" or "detailed"
    float = {
      width = 0.8,
      height = 0.8,
      border = "rounded",
      cover_art = true,             -- requires image.nvim
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

### Manual

```lua
require("gtm").setup({
  statusline_format = "compact",
  float = { width = 0.8, height = 0.8, border = "rounded" },
})
```

### Cover Art

Cover art is rendered in the floating pane using [image.nvim](https://github.com/3rd/image.nvim).
This is an **optional** feature. To enable it:

```lua
{
  "prjctimg/gtm.nvim",
  dependencies = {
    { "3rd/image.nvim", opts = { processor = "magick_cli" } },
  },
  opts = {
    float = {
      cover_art = true,
    },
  },
}
```

Cover art is resolved in this order:
1. `cover_art` field from GTM daemon IPC response
2. Common filenames next to the audio file (`cover.jpg`, `folder.jpg`, etc.)
3. Embedded thumbnail extracted via `ffmpeg` (cached in `~/.cache/gtm/covers/`)

To disable cover art: `float = { cover_art = false }`.

## Commands

### Playback

| Command | Description |
|---------|-------------|
| `:Gtm float` / `:Gtm toggle` | Toggle GTM floating window |
| `:Gtm play` | Toggle play/pause |
| `:Gtm next` | Next track |
| `:Gtm prev` | Previous track |
| `:Gtm stop` | Stop playback |
| `:Gtm volup` | Volume up 5% |
| `:Gtm voldown` | Volume down 5% |
| `:Gtm shuffle` | Toggle shuffle |
| `:Gtm repeat {mode}` | Set repeat: off, one, all |
| `:Gtm mute` | Toggle mute |
| `:Gtm seek {secs}` | Seek to position in seconds |
| `:Gtm status` | Show current track info |
| `:Gtm disconnect` | Disconnect from daemon |

### Library

| Command | Description |
|---------|-------------|
| `:Gtm library` | Open track list with vim motions |
| `:Gtm playlists` | Open playlist list |
| `:Gtm scan {path}` | Scan directory and add to library |

Library buffer keymaps: `j`/`k` navigate, `gg`/`G` jump, `<CR>` play,
`d` delete, `a` add to queue, `F` toggle favourite, `t` playlists,
`/` filter, `q`/`<Esc>` close.

### Equalizer

| Command | Description |
|---------|-------------|
| `:Gtm eq on` | Enable EQ |
| `:Gtm eq off` | Disable EQ |
| `:Gtm eq {preset}` | Set preset: flat, pop, rock, jazz, classical, bass, vocal, electronic, hip_hop, latin, acoustic, podcast, dance, headphones, speaker |

### YouTube

| Command | Description |
|---------|-------------|
| `:Gtm yt` | Search YouTube (prompts for query) |
| `:Gtm yt {query}` | Search YouTube for query |
| `:Gtm yt download` | Download track (prompts for URL) |
| `:Gtm yt download {url}` | Download from URL or search query |

Results appear in a floating picker. Press `<CR>` to download.
Audio is saved as MP3 to `~/.local/share/gtm/audio/` and the library
is automatically rescanned.

## Statusline

### lualine.nvim

```lua
require("lualine").setup({
  sections = {
    lualine_x = {
      require("gtm").lualine_component(),
    },
  },
})
```

### Manual

```lua
-- In your statusline config:
vim.o.statusline = "%{v:lua.require'gtm'.statusline()}"
```

### Formats

**Compact** (default):
```
Artist - Title ▶ vol:80% ━━━━━━━━━━━━━━━━━━━━
```

**Detailed**:
```
▶ Artist / Title (Album) [01:23/04:56] vol:80% 🔁 🔀
```

## Architecture

```
Neovim                          GTM Daemon
──────                          ──────────
gtm (single init.lua) ── Unix socket ──► gtmd
  │  JSON line requests              │
  │  ◄── JSON responses              │
  │  ◄── bincode events (skipped)    │
  │                                  │
  ├── IPC (connect, send, read)      │
  ├── Float (termopen)               │
  ├── Statusline (poll + interpolate)│
  ├── Library (track/playlist UI)    │
  ├── Equalizer (preset control)     │
  ├── YouTube (search + download)    │
  └── Commands (keymaps)             │
```

The plugin connects directly to the daemon's Unix socket using libuv
(`vim.uv`), sending JSON line-delimited requests and parsing responses.
Bincode event frames on the same socket are detected and skipped.
No CLI wrapper needed.

## License

GPLv3 — same as GTM.
