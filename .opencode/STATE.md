# Loop State — gtm.nvim

Last run: 2026-09-28 (PROMPT completion — cover art + reactive theming)

## High Priority (loop is acting or waiting on human)

- None open. Both PROMPT tasks are implemented, smoke-tested against a
  wire-faithful fake daemon (18 main + 5 event-path checks, all PASS) and
  committed as `b2fa8b0` (10 files, within gate).
- Awaiting the nightly `gtmd` install (user) — then re-run the embedded-art
  end-to-end against a real-mode daemon (t3 recipe in earlier runs).

## Watch List

- `gtmd` binary is absent (`/home/prjctimg/.local/bin/gtmd` deleted while
  nightly install pending) — live-daemon probes are on hold until the user
  installs it. Fake-daemon harness remains at `/tmp/opencode/fake_gtmd.py`.
- Cover-art end-to-end with embedded APIC art needs a real-mode daemon
  (`cover.rs` skips library cover-path/sidecar lookups in test mode).
- Pulse wire verified live earlier (StructTuple frames, heartbeat /
  playback_started / repeat_mode_changed PascalCase). Status normalization
  (`Paused`→`paused`, `One`→`one`) covered by fake-daemon smoke.
- Luacheck now clean (0/0) via `.luacheckrc` (W122 vim.bo idiom, W214
  `_opts` convention ignored). New modules stylua-clean; init.lua kept in
  repo's non-stylua style deliberately.

## Recent Noise (ignored this run)

- `pkill -f` self-match foot-guns when restarting the fake daemon (use
  `pkill -f '[f]ake_gtmd'` as a standalone command, never inline with the
  restart, or the shell kills itself).
- Neovim v0.12.5 quirks encountered: `vim.fn.delete(path, "f")` raises
  E15 (use 1-arg `delete(path)`); binary Lua strings crossing into VimL
  become Blobs (write via Lua `io.open`, and use `delete(dir,"rf")` for dirs).

---
Run log: 2026-09-28 — PROMPT tasks done: daemon-first cover art (image.nvim),
reactive theming (3-color palette, keep-while-paused, exact restore),
gtmd.pulse event subscription, envelope/flattening/casing protocol changes,
handshake removed, docs + .luacheckrc; committed b2fa8b0.