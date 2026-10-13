# Changelog

All notable changes to WLTunnel are documented here.
Dates are ISO 8601. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.1.3] — 2026-06-26

### Added

- **`wl-tunnel`** main relay daemon: proxy Wayland wire protocol between cage (headless
  compositor) and connected apps, with per-client relay threads.
- **`wl_shm` frame capture**: intercept `wl_buffer_attach` + `wl_surface_commit` to extract
  raw pixel data from shared memory pools.
- **FNV-1a hash dedup**: skip unchanged frames per pool; reset on stream-client reconnect.
- **LZ4 compression**: vendored lz4 (BSD-2-Clause), compiled as a static C object for
  cross-compile portability (no sysroot dependency).
- **wlstream v1 encoding**: emit `POOL_DATA` + `SURFACE_COMMIT` + `SESSION_RESET` events
  over the output Unix socket using the wlstream wire format.
- **Input injection**: receive keyboard and pointer events from bsdos-core via
  `WLSTREAM_INPUT_SOCK`; synthesise virtual `wl_keyboard` / `wl_pointer` objects and
  inject into the focused surface.
- **`wl-keepalive`** helper: send synthetic Wayland round-trips to prevent compositor idle
  timeout when no frames are in flight.
- **`stream-reader`** debug tool: connect to any wlstream socket and dump frame headers to
  stdout.
- **`test-input`**, **`test-stream`**, **`test-protocol`**, **`test-reconnect`** test steps.
- **`-Dplatform=<str>`** build option: `qemu_amd64` | `qemu_aarch64` | `bpi_m64` | `pinephone`.
- **aarch64 cross-compile support**: `--sysroot` pass-through for FreeBSD sysroot; lz4
  compiled inline, no liblz4 needed.
- Multi-stream support: multiple bsdos-core consumers can connect simultaneously;
  `pool_reset_generation` synchronises pool view across relay threads.

### Origin

Extracted from [bsdOS](https://github.com/bzdOS/bsdOS) (privacy-first FreeBSD mobile OS).
In production as part of the v0.1.x QEMU sandbox since June 2026.

[0.1.3]: https://github.com/bzdOS/WLTunnel/releases/tag/v0.1.3
