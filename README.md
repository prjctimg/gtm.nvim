# gtm.nvim

[![Version](https://img.shields.io/github/v/release/prjctimg/gtm.nvim)](https://github.com/prjctimg/gtm.nvim/releases)
[![License: GPLv3](https://img.shields.io/badge/license-GPLv3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)
[![Neovim](https://img.shields.io/badge/neovim-0.9+-green.svg)](https://neovim.io)

Your music, inside Neovim.

`gtm.nvim` puts the [GTM](https://github.com/prjctimg/gtm) player in your editor — controls, album art, library, and equalizer, without leaving your buffer. It also tints your whole editor with the colours of whatever is currently playing.

## Quick start

You need `gtmd` running. Grab it from the [GTM repo](https://github.com/prjctimg/gtm), then:

```lua
{
  "prjctimg/gtm.nvim",
  opts = {
    statusline_format = "compact",
  },
}
```

That's it. `:Gtm float` opens the player.

### With the good bits

```lua
{
  "prjctimg/gtm.nvim",
  dependencies = { "3rd/image.nvim" }, -- album art in the float
  opts = {
    statusline_format = "compact",
    float = {
      width = 0.8,
      height = 0.8,
      border = "rounded",
      cover_art = true,
    },
    theme = {
      reactive = true,  -- tint the editor with the album art
      intensity = 0.2,  -- how strongly (0 .. 0.5)
      scope = "global", -- "global" (whole editor) or "float"
    },
  },
}
```

## Using it

Everything lives under one command and one set of keys.

| Command | What it does |
|---------|--------------|
| `:Gtm float` | Open / close the player |
| `:Gtm play` | Play / pause |
| `:Gtm next` / `:Gtm prev` | Skip tracks |
| `:Gtm stop` | Stop |
| `:Gtm volup` / `:Gtm voldown` | Volume ±5% |
| `:Gtm mute` | Mute / unmute |
| `:Gtm seek {secs}` | Jump in the track |
| `:Gtm shuffle` | Toggle shuffle |
| `:Gtm repeat {off\|one\|all}` | Set repeat mode |
| `:Gtm eq {preset}` | Set an equalizer preset |
| `:Gtm status` | What is playing right now |
| `:Gtm library` | Browse your library |
| `:Gtm playlists` | Your playlists |
| `:Gtm scan {path}` | Add a folder to the library |
| `:Gtm yt {query}` | Search YouTube |
| `:Gtm theme {status\|reset}` | Show the palette / clear the tint |
| `:Gtm disconnect` | Drop the daemon connection |

Default keys — all under `<Leader>g`, and all remappable:

| Key | Action |
|-----|--------|
| `<Leader>gp` | Play / pause |
| `<Leader>gn` / `<Leader>gN` | Next / previous |
| `<Leader>g>` / `<Leader>g<` | Volume up / down |
| `<Leader>gf` | Toggle the float |
| `<Leader>gS` | Stop |

## Reactive theming

Turn on `theme.reactive` and your editor picks up the colours of the album you're
listening to. Every surface gets a wash of the dominant colour and the syntax
highlights shift to the palette, so scrolling from one track to the next feels
like the room changed with it.

A few things worth knowing:

- It **keeps the tint while paused**, and only restores your theme when playback
  really stops — no flicker on every pause.
- **Error, warning, diff, spell and `Todo` colours never move.** They're how you
  spot problems, so they stay readable no matter what the artwork is doing.
- Swapping colorscheme mid-song re-tints instead of dropping the theme.
- `:Gtm theme reset` puts everything back exactly as it was.

The background strength is up to you — `intensity = 0.2` is a hint, `0` leaves
the editor alone.

## Statusline

It ships a component for lualine, and `compact` / `detailed` formats:

```
Artist - Title ▶ vol:80% ━━━━━━━━━━━━━━━━━━━━          -- compact
▶ Artist / Title (Album) [01:23/04:56] vol:80% 🔁 🔀   -- detailed
```

```lua
require("lualine").setup({
  sections = { lualine_x = { require("gtm").lualine_component() } },
})
```

## How it talks to the daemon

Two Unix sockets, both handled asynchronously through `vim.uv`:

- **`gtmd.sock`** — newline-delimited JSON, request in, response out.
- **`gtmd.pulse`** — MessagePack frames pushed by the daemon when things change.

Nothing polls for the things that matter: the plugin subscribes to the event
stream at startup, so a track change reaches you the moment it happens. A small
`get_status_lite` resync every 30 seconds just keeps the clock honest.

```
Neovim ──► gtmd.sock   "what's playing?"     ──►  a JSON reply
        ◄── gtmd.pulse  "this track started"  ──  pushed, unprompted
```

## Requirements

- Neovim 0.9+
- `gtmd` running ([GTM](https://github.com/prjctimg/gtm))
- `yt-dlp` — only for YouTube search and downloads
- [3rd/image.nvim](https://github.com/3rd/image.nvim) — optional, for album art
- `ffmpeg` or ImageMagick — only if you want reactive theming

## Notes

- Album art comes from the daemon, cached under `stdpath("cache")/gtm/cover` so
  the same track is only fetched once.
- Without `image.nvim` the float still works, just with a `♪` where the art
  would be.

## Specification

- [gtm.spec](https://github.com/prjctimg/gtm.spec) — the full specification
- [Protocol](https://github.com/prjctimg/gtm.spec/blob/main/protocol.md) — IPC reference
- [Configuration](https://github.com/prjctimg/gtm.spec/blob/main/man/gtm-config.1.md) — daemon config

## Contributors

<!-- CONTRIBUTORS -->
<p align="left">
  <a href="https://github.com/iseeheaven"><img src="https://github.com/iseeheaven.png?size=80" width="50" height="50" style="border-radius:50%;margin:4px;" alt="iseeheaven"/></a> <a href="https://github.com/prjctimg"><img src="https://github.com/prjctimg.png?size=80" width="50" height="50" style="border-radius:50%;margin:4px;" alt="prjctimg"/></a>
</p>
<!-- /CONTRIBUTORS -->

## License

[GPLv3](https://www.gnu.org/licenses/gpl-3.0) — same as GTM.