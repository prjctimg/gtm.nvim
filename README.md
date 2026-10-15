# gtm.nvim

[![Version](https://img.shields.io/github/v/prjctimg/gtm.nvim)](https://github.com/prjctimg/gtm.nvim/releases)
[![License: GPLv3](https://img.shields.io/badge/license-GPLv3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)
[![Neovim](https://img.shields.io/badge/neovim-0.11+-green.svg)](https://neovim.io)

Your music, inside Neovim.

`gtm.nvim` is the small piece of [GTM](https://github.com/prjctimg/gtm) that belongs in your editor: transport controls, a statusline, and reactive theming that tints your whole editor with the colours of whatever is playing. Under a thousand lines, no dependencies, no windows.

Anything with an interface — browsing, queues, search, downloads — lives in `gtm`'s own TUI. This plugin does not reimplement it.

## Quick start

You need `gtmd` running. Grab it from the [GTM repo](https://github.com/prjctimg/gtm), start it, then:

```lua
{ "prjctimg/gtm.nvim", opts = {} }
```

That's it. Press `<Leader>gp` and something plays.

### With the good bits

```lua
{
  "prjctimg/gtm.nvim",
  opts = {
    statusline_format = "detailed",
    theme = {
      reactive = true,        -- tint the editor with the album art
      extra_groups = { "MyGroup" },  -- ...and these groups too
    },
  },
}
```

## Using it

| Command | What it does |
|---------|--------------|
| `:Gtm play` | Play / pause |
| `:Gtm next` / `:Gtm prev` | Skip tracks |
| `:Gtm stop` | Stop |
| `:Gtm volup` / `:Gtm voldown` | Volume ±5% |
| `:Gtm mute` | Mute / unmute |
| `:Gtm seek {secs}` | Jump in the track |
| `:Gtm shuffle` | Toggle shuffle |
| `:Gtm repeat {off\|one\|all}` | Set repeat mode |
| `:Gtm status` | What is playing right now |
| `:Gtm theme` | Show the active palette |
| `:Gtm theme reset` | Clear the tint |
| `:Gtm disconnect` | Drop the daemon connection |

Default keys — all under `<Leader>g`, all remappable:

| Key | Action |
|-----|--------|
| `<Leader>gp` | Play / pause |
| `<Leader>gn` / `<Leader>gN` | Next / previous |
| `<Leader>g>` / `<Leader>g<` | Volume up / down |
| `<Leader>gS` | Stop |

The Lua API mirrors the commands, so `require("gtm").next()` and friends work if you prefer to bind them yourself.

## Reactive theming

Turn on `theme.reactive` and your editor picks up the colours of the album you're listening to. Every surface gets a wash of the dominant colour and the syntax highlights shift to the palette, so scrolling from one track to the next feels like the room changed with it.

The palette is extracted **by gtmd**, not here — the plugin never decodes an image. It just receives three hex colours over the event stream and derives a full highlight ramp from them.

A few things worth knowing:

- It **keeps the tint while paused**, and only restores your theme when playback really stops — no flicker on every pause.
- **Error, warning, diff, spell and `Todo` colours never move.** They're how you spot problems, so they stay readable no matter what the artwork is doing.
- Swapping colorscheme mid-song re-tints instead of dropping the theme.
- `:Gtm theme reset` puts everything back exactly as it was.
- A track with no cover art never tints. That is the daemon's call to make, not the plugin's.

## Statusline

```lua
require("lualine").setup({
  sections = { lualine_x = { require("gtm").lualine_component() } },
})
```

Or render it yourself from `vim.o.statusline`:

```lua
vim.o.statusline = "%{%v:lua.require'gtm'.statusline()%}"
```

Two formats:

```
Artist - Title ▶ vol:80% ━━━━━━━━━━━━━━━━━━━━          -- compact
▶ Artist - Title (Album) [01:23/04:56] vol:80% [R] [S] -- detailed
```

The component hides itself while the daemon is unreachable, so a stopped `gtmd` costs no width. The clock advances locally between daemon events, so the progress bar does not stutter waiting on the network.

## How it talks to the daemon

Two Unix sockets, both handled asynchronously through `vim.uv`:

- **`gtmd.sock`** — newline-delimited JSON, request in, response out, correlated by a client-chosen `id`.
- **`gtmd.pulse`** — MessagePack frames the daemon pushes when things change.

Nothing polls for the things that matter: the plugin claims the event stream at startup, so a track change reaches you the moment it happens. A slow `get_status_lite` resync just keeps the clock honest.

```
Neovim ──► gtmd.sock   "what's playing?"     ──►  a JSON reply
        ◄── gtmd.pulse  "this track started"  ──  pushed, unprompted
```

## Requirements

- Neovim **0.11+**
- `gtmd` running ([GTM](https://github.com/prjctimg/gtm))
- For reactive theming, gtmd needs to be able to read cover art — see the [GTM docs](https://github.com/prjctimg/gtm)

No plugin dependencies, and none optional.

## Health

```vim
:checkhealth gtm
```

Reports the Neovim version, whether `gtmd` is installed, whether both sockets are live, how stale the status snapshot is, and whether the palette is flowing. If nothing is happening, start here.

## Specification

- [gtm.spec](https://github.com/prjctimg/gtm.spec) — the full specification
- [Protocol](https://github.com/prjctimg/gtm.spec/blob/main/protocol.md) — IPC reference

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Bugs and feedback welcome; PRs are restricted for now.

## Contributors

<!-- CONTRIBUTORS -->
<p align="left">
  <a href="https://github.com/iseeheaven"><img src="https://github.com/iseeheaven.png?size=80" width="50" height="50" style="border-radius:50%;margin:4px;" alt="iseeheaven"/></a> <a href="https://github.com/prjctimg"><img src="https://github.com/prjctimg.png?size=80" width="50" height="50" style="border-radius:50%;margin:4px;" alt="prjctimg"/></a>
</p>
<!-- /CONTRIBUTORS -->

## License

Copyright (C) 2026 - present prjctimg <prjctimg@outlook.com>

Released under the [GPL-3.0 license](LICENSE) — same terms as GTM. In short: you may use, study, modify and redistribute it, and any distributed work must stay under the same license.