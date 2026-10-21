# gtm.nvim

[![Version](https://img.shields.io/github/v/prjctimg/gtm.nvim)](https://github.com/prjctimg/gtm.nvim/releases)
[![License: GPLv3](https://img.shields.io/badge/license-GPLv3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)
[![Neovim](https://img.shields.io/badge/neovim-0.11+-green.svg)](https://neovim.io)

Your music, inside Neovim.

`gtm.nvim` is the small piece of [GTM](https://github.com/prjctimg/gtm) that belongs in your editor: transport controls, a statusline, native pickers over the queue and library, and reactive theming that tints your whole editor with the colours of whatever is playing. Small, dependency-free, and no custom windows.

Browsing is `vim.ui.select` over the daemon's own IPC, so your existing selector — fzf-lua, Telescope, snacks, or the stock list — supplies the UI and its search. Cover art, downloads and full library editing stay in `gtm`'s own TUI.

## Quick start

You need `gtmd` running. Grab it from the [GTM repo](https://github.com/prjctimg/gtm), start it, then:

```lua
{ "prjctimg/gtm.nvim", opts = {} }
```

That's it. The statusline shows a play/pause icon and a source marker, and the editor tints itself with whatever is playing.

There are **no default keymaps**. Pick the ones you want:

```lua
{
  "prjctimg/gtm.nvim",
  opts = {
    keymaps = {
      play_pause = "<leader>gp",
      next = "<leader>gn",
      prev = "<leader>gN",
      volume_up = "<leader>g>",
      volume_down = "<leader>g<",
      stop = "<leader>gS",
      queue = "<leader>gq",
      spotify = "<leader>gs",
      radio = "<leader>gr",
      search = "<leader>g/",
    },
  },
}
```

## Statusline

The statusline is a list of items you turn on. By default only the source marker and the state icon are shown; everything else is opt-in, so nothing is squeezed in without asking.

```lua
{
  "prjctimg/gtm.nvim",
  opts = {
    statusline = {
      source = true,    -- ♫ Spotify ◉ radio ☁ podcast ❋ chart ▤
      state = true,     -- ▶ ⏸ ⏹
      artist = true,
      title = true,
      album = false,
      progress = true,  -- ━━━─ 20 columns
      time = false,     -- [01:23/04:56]
      volume = false,   -- vol:80%
      repeat = false,   -- [R]
      shuffle = false,  -- [S]
    },
  },
}
```

Items render in the order above. An item with nothing to show is skipped, so the empty state is just `⏹` rather than a row of zeroes.

### Source icons

`statusline.source` shows a marker for where the audio came from, using [Nerd Font](https://www.nerdfonts.com/) codepoints from Material Design Icons:

| Source | Glyph | Codepoint |
|---|---|---|
| spotify | `md-spotify` | U+F04C7 |
| radio | `md-radio` | U+F0439 |
| podcast | `md-podcast` | U+F0994 |
| local | `md-folder_music` | U+F1359 |
| chart | `md-chart_line` | U+F012A |

A source your `gtmd` doesn't name renders nothing rather than guessing.

**No Nerd Font?** Those are private-use codepoints and will show as empty boxes. Paste the plain-Unicode set instead — it needs no patched font:

```lua
icons = { spotify = "◉", radio = "☁", podcast = "❋", local = "♫", chart = "▤" },
```

You can override just the ones you like; the rest keep their defaults.

lualine:

```lua
require("lualine").setup({
  sections = { lualine_x = { require("gtm").lualine_component() } },
})
```

or any `statusline`:

```lua
vim.o.statusline = "%{%v:lua.require'gtm'.statusline()%}"
```

The component hides itself while the daemon is unreachable. The clock advances locally between daemon events, so the progress bar does not stutter waiting on the socket.

## Browsing

Every picker is a `vim.ui.select` menu. The plugin draws no window and keeps no list of its own: your selector supplies the UI and its search — fzf-lua, Telescope, snacks, or the stock number list. Selecting a track plays it; there is nothing to open or close.

| Command | What it browses |
|---------|-----------------|
| `:Gtm queue` | The current queue; selecting a row plays it |
| `:Gtm queue remove` | The queue, removing the selected row |
| `:Gtm queue clear` | Clears the queue after a confirmation |
| `:Gtm spotify {query}` | Spotify web search; only real tracks are listed |
| `:Gtm spotify` | Prompts for the query first |
| `:Gtm spotify-playlists` | Synced Spotify playlists → tracks |
| `:Gtm radio` | Top Radio Browser stations |
| `:Gtm radio {query}` | Radio Browser station search |
| `:Gtm radio tags` | Tag → stations |
| `:Gtm radio countries` | Country → stations |
| `:Gtm search [query]` | The local library index |
| `:Gtm playlists` | Local playlists → tracks |
| `:Gtm favourites` | Favourites |

Queue playback handles local paths, `spotify:` URIs and `radio://` streams alike. Queue edits are separate subcommands, so selecting a row only plays it.

The stock `vim.ui.select` fallback is a numbered `inputlist`: it works, but search needs a selector plugin. Cover art is not rendered in a menu; a Spotify result carries its image URL to the daemon so the queued row still gets art.

The Lua API mirrors these: `queue(action)`, `spotify(query)`, `spotify_playlists()`, `radio(arg)`, `search(query)`, `playlists()` and `favourites()`. The opt-in keymap names are `queue`, `spotify`, `spotify_playlists`, `radio`, `search`, `playlists` and `favourites`.

## Reactive theming

On by default. Your editor takes on the colours of the album you're listening to: every surface gets a wash of the dominant colour and the syntax highlights shift to the palette, so scrolling from one track to the next feels like the room changed with it.

**The daemon does the colour work, not the plugin.** gtmd reads the cover art, extracts a palette, resolves it into a full set of roles — surfaces, foregrounds, accents, selection, syntax, semantics — and pushes them over the pulse socket. The plugin maps roles onto highlight groups. The only colour it computes itself is the background wash, because the daemon cannot know which colorscheme you run. That is what keeps gtm.nvim, the gtm TUI, and any future editor plugin in agreement: one derivation, one answer.

A few things worth knowing:

- **Backgrounds are your colorscheme, washed with the album.** Each background keeps its own colour and steps `theme.intensity` (default `0.34`) of the way toward the album accent, so the editor is *your* theme warmed by the record — never a fixed dark grey substituted for it.
- It **keeps the tint while paused**, and only restores your theme when playback really stops — no flicker on every pause.
- **Error, warning, diff, spell and `Todo` colours never move.** They're how you spot problems, so they stay readable no matter what the artwork is doing.
- Swapping colorscheme mid-song re-picks light or dark and re-tints, instead of dropping the theme.
- **Track changes re-tint live, with no restart.** If the pulse stream drops — `gtmd` restarting, say — it reconnects on its own, and the tint is re-asserted on the periodic resync, so the editor never keeps colours from a track that already ended.
- `:Gtm theme reset` puts everything back exactly as it was.
- A track with no cover art never tints. That is the daemon's call to make, not the plugin's.
- Turn it off with `theme = { reactive = false }`, or set `theme = { intensity = 0 }` to keep your backgrounds untouched while the accents and syntax still follow the album.

It needs a gtmd that sends role sets. Against an older daemon the editor stays
untinted — deliberately, since a second derivation is how two clients end up
rendering the same track differently.

The plugin derives no roles. If your gtmd predates role sets, `:checkhealth gtm` says so and the editor simply stays untinted rather than guessing colours the TUI would render differently.

## Commands

| Command | What it does |
|---------|--------------|
| `:Gtm play` | Play / pause |
| `:Gtm next` / `:Gtm prev` | Skip tracks |
| `:Gtm stop` | Stop |
| `:Gtm volup` / `:Gtm voldown` | Volume ±5% |
| `:Gtm mute` | Mute / unmute |
| `:Gtm seek {secs}` | Jump in the track |
| `:Gtm shuffle` | Toggle shuffle |
| `:Gtm repeat` | Cycle repeat: off → one → all |
| `:Gtm repeat {off\|one\|all}` | Set repeat mode |
| `:Gtm status` | What is playing right now |
| `:Gtm theme` | Show the active palette |
| `:Gtm theme reset` | Clear the tint |
| `:Gtm queue [remove\|clear]` | Browse the queue; optionally remove the selected row or clear it |
| `:Gtm spotify [query]` | Search Spotify (tracks only) |
| `:Gtm spotify-playlists` | Browse synced Spotify playlists |
| `:Gtm radio [query\|tags\|countries]` | Top stations, search, or drill down by tag/country |
| `:Gtm search [query]` | Search the local library |
| `:Gtm playlists` | Browse local playlists |
| `:Gtm favourites` | Browse favourites |

The Lua API mirrors the commands, so `require("gtm").next()` and friends work if you'd rather bind them yourself.

Every message the plugin shows carries the same marker — `[gtm] 📻️ ` — so it is recognisable in a busy message list.

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
- Optional: a `vim.ui.select` provider (fzf-lua, Telescope, snacks) for searchable pickers

No required plugin dependencies. Without a selector plugin the pickers fall back to the stock numbered list.

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
