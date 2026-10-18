# Contributing

Thanks for considering contributing to `gtm.nvim`. This is a friendly, hobby
project: feedback and bug reports are welcome. The project is still young, so PRs
are restricted for now — they will be unlocked after the first major (`v1`).

The companion project, [gtm](https://github.com/prjctimg/gtm), is the daemon and
TUI this plugin talks to. If you are looking for the player itself, start there.

## Scope

`gtm.nvim` is deliberately three things:

- **Playback control** — `:Gtm` and optional keymaps over the daemon's transport
  commands. There are no default keymaps; the README lists suggestions.
- **Statusline integration** — one item list, a render function and a lualine
  component. Only the source marker and the state icon are on by default.
- **Reactive theming** — the editor tinted from the album palette gtmd extracts,
  on by default.

It is under a thousand lines of code. Anything with an interface — browsing,
queues, search, downloads — belongs in the `gtm` TUI, not here. **Please open an
issue before writing a PR that adds a window, picker or list.** A feature that
belongs upstream should be fixed upstream.

## Getting set up

There is nothing to build. The plugin loads straight into Neovim.

You need `gtmd` running — see [gtm's install instructions](https://github.com/prjctimg/gtm).
`gtm.nvim` does not start the daemon for you.

```lua
{ "prjctimg/gtm.nvim", opts = {} }
```

Check the wiring end to end:

```vim
:checkhealth gtm
```

That reports the Neovim version, whether `gtmd` is on `$PATH`, both socket
connections, heartbeat freshness and whether a palette is arriving. If something
is wrong, it is almost always in there.

## Tests

Two headless scripts, both exiting non-zero on failure.

```bash
nvim --headless -l scripts/checkrefs.lua
nvim --headless -l scripts/smoke.lua
```

`checkrefs.lua` resolves every cross-module call in `init.lua` and `health.lua`
against the modules as loaded, so a renamed helper that one caller missed fails
at push instead of at a user's keyboard.

`smoke.lua` stands up a fake `gtmd` — a JSON command socket and a MessagePack
pulse socket — and drives the plugin through the whole path: connect, prime,
position extrapolation, pulse decoding, tint apply and restore, every `:Gtm`
subcommand, and health.

Neither needs a daemon. Run both after any change to the IPC, theme or command
paths.

## Linting

```bash
luacheck lua plugin
```

`.luacheckrc` pins `lua51`, allows the `vim` global and caps lines at 120
columns. Keep it clean; a warning is a change to make, not to silence.

## Manual test checklist

The smoke test covers the machinery, but not the feel. Before opening a PR,
walk this list against a real running `gtmd`:

- [ ] the statusline shows only the state icon and source marker by default
- [ ] enabling `artist`, `title`, `progress`, `time`, `volume`, `repeat` and
      `shuffle` each adds exactly its item; disabling one removes it
- [ ] the empty state is a bare `⏹` with everything else enabled
- [ ] a keymap you configure fires; none are bound until you ask for one
- [ ] play/pause, next, prev and stop all take effect
- [ ] volume keys move the reported volume by 5% and the daemon agrees
- [ ] `mute`, `shuffle` and `repeat {off|one|all}` work and are reflected in
      `:Gtm status`; bare `:Gtm repeat` cycles off -> one -> all
- [ ] `:Gtm seek 30` jumps, and the statusline position follows
- [ ] the progress bar advances smoothly while playing (the clock is
      extrapolated locally, so it must not tick in jumps)
- [ ] reactive theming tints the editor on a track with cover art (on by default)
- [ ] `Error`, `Warning`, `Diff` and `Spell` groups keep their colorscheme
      colours while the tint is up
- [ ] pausing keeps the tint; stopping or ending the track restores it exactly
- [ ] `:colorscheme` mid-track re-tints rather than dropping the palette
- [ ] `:Gtm theme reset` restores every group
- [ ] restarting `gtmd` reconnects on its own without a Neovim restart
- [ ] `:q` exits cleanly with no errors

## Code conventions

- Target Neovim 0.11+; do not use deprecated APIs.
- Name a module's table after its first letter — `ipc.lua` uses `I`, not `M`.
- Anything that runs indefinitely must be non-blocking: `vim.uv` timers and
  pipes, never sleeps or blocking calls.
- Public API and documented options are comments, not just code. Explain *why*
  when it is not obvious from the code.

## Project structure

```
lua/gtm/
├── init.lua         Public API, :Gtm, keymaps, setup, statusline rendering
├── ipc.lua          gtmd.sock — newline JSON, request/response by id,
│                    reconnect with backoff, the status snapshot
├── pulse.lua        gtmd.pulse — length-prefixed MessagePack; peeks the tag,
│                    drops telemetry, decodes the rest with vim.mpack
├── theme.lua        Palette to highlight ramp; snapshots every group so the
│                    tint can be restored exactly
├── health.lua       :checkhealth gtm
└── plugin_spec.lua  lazy.nvim spec
plugin/gtm.lua      Auto-setup loader for non-plugin-manager installs
scripts/smoke.lua    Headless fake-daemon integration test
scripts/checkrefs.lua  Cross-module reference check
```

The pulse stream is the source of truth for state changes. Position is
extrapolated locally between events; the `get_status_lite` resync exists only to
heal drift the plugin was never told about.

## Before you open a PR

```bash
nvim --headless -l scripts/checkrefs.lua
nvim --headless -l scripts/smoke.lua
luacheck lua plugin
```

Then run the manual checklist. Conventional commits:

```
feat: add a seek-relative keymap
fix: keep the tint when the daemon drops the pulse socket
docs: document the socket path override
```