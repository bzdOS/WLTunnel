# WLTunnel

> **Wayland session streaming tunnel for bsdOS (FreeBSD).**
> Sits between a headless Wayland compositor (cage) and a stream consumer (bsdos-core).
> Proxies the Wayland wire protocol, intercepts `wl_shm` frame data, LZ4-compresses it,
> and delivers frames over a Unix socket using the [wlstream wire format](https://github.com/bzdOS/WLStream).

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Zig](https://img.shields.io/badge/Zig-0.13%2B-f7a41d.svg)](https://ziglang.org)
[![FreeBSD](https://img.shields.io/badge/FreeBSD-15.1-red.svg)](https://www.freebsd.org)

---

## Why?

Pixel streaming (VNC, SPICE, MJPEG) renders everything server-side and ships raw pixels.
Event streaming (wlstream) ships the semantic events the compositor already produces —
surface creates, SHM buffer uploads, damage regions — and lets the client re-render.

WLTunnel bridges the two worlds: it intercepts an existing Wayland session (cage + real
apps) at the protocol level, without modifying the compositor or the applications.
The compositor speaks standard Wayland; WLTunnel taps into `wl_shm` commits and
repackages frame data into the compact wlstream wire format for delivery to bsdos-core.

| Scenario | Pixel streaming | WLTunnel (event streaming) |
|---|---|---|
| Idle terminal | ~250 MB/s | **0** (no commit → no frame sent) |
| Cursor blink | ~250 MB/s | **~130 B** |
| Text typed | ~250 MB/s | **~50 KB** |
| Full redraw | ~250 MB/s | **~4 MB** (LZ4-compressed) |
| Video (1080p 60fps) | ~250 MB/s | ~250 MB/s (no win) |

## Architecture

```
cage (headless Wayland compositor, WLR_BACKENDS=headless)
  │  Wayland socket (WLSTREAM_COMPOSITOR_SOCK)
  ▼
WLTunnel  ←── apps (foot, chromium, electron) connect via WLSTREAM_WAYLAND_SOCK
  │   relay thread per client:
  │     - proxy Wayland wire protocol both ways
  │     - intercept wl_shm pool_data + surface_commit
  │     - FNV-1a hash dedup (skip unchanged frames)
  │     - LZ4-compress pixel data
  │     - encode as wlstream v1 length-prefixed frame
  │
  ├── wlstream frames → WLSTREAM_STREAM_SOCK → bsdos-core → Zenoh → viewer
  └── input events  ← WLSTREAM_INPUT_SOCK  ← bsdos-core (keyboard + pointer)

Legend:
  wl-tunnel      — main daemon (relay threads, frame capture, input injection)
  wl-keepalive   — keepalive helper (sends synthetic Wayland round-trips)
  stream-reader  — debug tool: dump raw wlstream frames from a socket
```

## Env vars

| Variable | Purpose | Default |
|---|---|---|
| `WLSTREAM_WAYLAND_SOCK` | Unix socket WLTunnel **listens** on (apps + cage connect here) | `/tmp/wayland-run/wayland-ghost-0` |
| `WLSTREAM_COMPOSITOR_SOCK` | Upstream cage compositor socket (WLTunnel connects to this) | `/tmp/wayland-run/wayland-0` |
| `WLSTREAM_STREAM_SOCK` | Output socket for wlstream frames (bsdos-core connects here) | `/tmp/wayland-run/wayland-stream.sock` |
| `WLSTREAM_INPUT_SOCK` | Input injection socket (keyboard + pointer events from bsdos-core) | `/tmp/wayland-run/input.sock` |

## Build

Requires Zig 0.13+ on FreeBSD 15.1. No external Wayland libraries needed — only libc and
a vendored copy of lz4 (BSD-2-Clause, included in `vendor/lz4/`).

```sh
# Native amd64 (QEMU dev loop)
zig build -Doptimize=ReleaseFast -Dplatform=qemu_amd64

# Cross-compile for aarch64 (the aarch64 boards)
zig build -Doptimize=ReleaseFast \
    -Dtarget=aarch64-freebsd \
    -Dplatform=qemu_aarch64 \
    --sysroot /path/to/aarch64-sysroot
```

Outputs in `zig-out/bin/`:

| Binary | Description |
|---|---|
| `wl-tunnel` | Main relay daemon |
| `wl-keepalive` | Keepalive helper |
| `stream-reader` | Debug frame reader |

### Platform values

| `-Dplatform=` | Target hardware |
|---|---|
| `qemu_amd64` | QEMU x86_64 (primary dev loop, KVM) |
| `qemu_aarch64` | QEMU aarch64 (architectural target) |
| `bpi_m64` | Banana Pi BPI-M64 (Allwinner A64) |
| `pinephone` | PinePhone (Allwinner A64 + Mali-400) |

### Tests

```sh
zig build test-input      # input framing round-trip
zig build test-stream     # wlstream header encode/decode
zig build test-protocol   # v1 frame encode/decode + pool dedup
zig build test-reconnect  # relay EOF detection + stream readability
```

## Related

- **[WLStream](https://github.com/bzdOS/WLStream)** — wire format specification and Rust crate
  that WLTunnel uses for frame encoding. Protocol reference: v1 length-prefixed binary,
  7 event types, LZ4-compressed SHM payloads.

## License

MIT. See [LICENSE](LICENSE).

## Origin

Developed as part of [bsdOS](https://github.com/bzdOS/bsdOS) — a privacy-first mobile OS
on FreeBSD. Extracted as a standalone daemon in June 2026.
