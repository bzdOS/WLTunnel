# WLTunnel Architecture

## Overview

WLTunnel is a Wayland protocol proxy. It inserts itself between a headless Wayland
compositor (cage) and the applications running inside that session, transparently
relaying all Wayland protocol messages in both directions. On the side, it intercepts
`wl_shm` buffer uploads and `wl_surface_commit` events to extract frame data, compress
it, and forward it to bsdos-core over a separate Unix socket.

```
                      ┌─────────────────────────────────────┐
                      │              wl-tunnel               │
                      │                                      │
  app (foot) ─────────┤ relay thread                        │
  app (chrome) ───────┤ relay thread  wl_shm tracker        │──── stream frames ──► bsdos-core
  cage (compositor) ──┤────────────── upstream pipe          │
                      │                                      │
                      │               input handler ─────────│◄─── input events ──── bsdos-core
                      └─────────────────────────────────────┘
```

## Socket roles

| Socket env var | Direction | Who connects |
|---|---|---|
| `WLSTREAM_WAYLAND_SOCK` | wl-tunnel listens | cage + apps connect here |
| `WLSTREAM_COMPOSITOR_SOCK` | wl-tunnel connects outbound | real cage compositor |
| `WLSTREAM_STREAM_SOCK` | wl-tunnel listens | bsdos-core connects here |
| `WLSTREAM_INPUT_SOCK` | wl-tunnel listens | bsdos-core sends input events |

## main() accept loop

`main()` runs a single `poll(2)` loop over three server fds:

1. `wayland_server_fd` — accepts new Wayland clients (apps + cage).
   For each accepted client: spawns a relay thread with `RelayThreadArgs`.
2. `stream_server_fd` — accepts bsdos-core stream consumers.
   On each new consumer: increments `pool_reset_generation` (triggers pool cache
   flush in all relay threads), appends fd to `stream_clients[]`.
3. `input_listen_fd` — created once at startup; passed to every relay thread.
   Relay threads `accept()` input connections themselves.

`stream_clients[]` and `pool_reset_generation` are protected by a mutex
(`stream_mod.lockClients` / `unlockClients`). Only `main()` writes to them;
relay threads read under the lock when sending a frame.

## Relay thread

One relay thread per connected Wayland client. Owns:

- `RelayBuffers` — two 16 MB heap buffers: `lz4_buf` (LZ4 output) and `pixel_buf`
  (decompressed pixel scratch). Allocated once per thread, freed on disconnect.
- `WlShmTracker` — tracks all `wl_shm_pool` objects seen by this client:
  pool id → `{ fd, size, mmap_ptr }`.
- `WlRegistry` — tracks `wl_registry` bind calls to know which object ids map to
  `wl_shm`, `wl_compositor`, `wl_seat`, etc.
- `pool_hashes[32]` — FNV-1a hash per pool slot for frame dedup.
- `InputState` — tracks the current `wl_keyboard` / `wl_pointer` object ids that were
  synthesised for this client.

### Main relay loop

```
loop:
  poll(client_fd, compositor_fd, input_accept_fd, [input_conn_fd])

  client_fd readable  → read Wayland message → rewriteClientBuffer() → send to compositor
  compositor_fd readable → read Wayland message → send to client (and capture if commit)
  input_accept_fd readable → accept() new input connection
  input_conn_fd readable   → readInputEvent() → synthesise wl_keyboard/wl_pointer event
```

### rewriteClientBuffer()

Before forwarding a Wayland message from the app to the compositor, the relay scans it
for `wl_shm_pool.create_buffer` and `wl_buffer.attach` requests to build up the
`WlShmTracker` mapping. It also intercepts `wl_seat.get_pointer` and
`wl_seat.get_keyboard` to register virtual input object ids.

### wl_shm frame capture

When the compositor sends a `wl_surface.frame` event back toward the client, the relay:

1. Looks up the surface's attached buffer in `WlShmTracker` to get the `mmap_ptr`,
   width, height, stride, and format.
2. Computes FNV-1a hash of the mapped pixel data.
3. If hash matches `pool_hashes[slot]` → skip (duplicate frame).
4. Otherwise: copy pixel data to `pixel_buf`, LZ4-compress into `lz4_buf`.
5. Lock `stream_clients[]`, send a wlstream `POOL_DATA` + `SURFACE_COMMIT` frame
   to every connected consumer.

### Pool reset generation

When bsdos-core reconnects (new stream consumer accepted in `main()`),
`pool_reset_generation` is incremented. Each relay thread checks this value at the
top of its loop; if it changed, `pool_hashes` is zeroed — forcing a full re-send of
all pools to the new consumer.

### SESSION_RESET

Sent to all stream consumers when a relay thread exits (Wayland client disconnected).
Tells bsdos-core to discard its compositor state.

## Input injection

bsdos-core sends keyboard and pointer events over `WLSTREAM_INPUT_SOCK` using the
wlstream input wire format (see `INPUT_PROTOCOL.md`). The relay thread reads events
from `input_conn_fd` and synthesises Wayland protocol messages:

- Key event → `wl_keyboard.key` + `wl_keyboard.modifiers` sent to the focused surface.
- Pointer motion → `wl_pointer.motion` + `wl_pointer.frame`.
- Pointer button → `wl_pointer.button` + `wl_pointer.frame`.

The relay synthesises the `wl_keyboard` / `wl_pointer` object ids by intercepting the
app's `wl_seat.get_keyboard` / `wl_seat.get_pointer` requests.
`sendKeymap()` is called once after the first `wl_keyboard` is registered, before any
key events, to deliver the XKB keymap to the app.

## LZ4 compression

WLTunnel uses a vendored copy of lz4 (`vendor/lz4/lz4.c`, BSD-2-Clause). It is compiled
as a static C object alongside the Zig binary using `exe.addCSourceFile()`. This avoids
any dependency on `liblz4` in the sysroot, which matters for cross-compile builds
targeting aarch64 FreeBSD.

Compression happens in `relay.zig` via the `stream` module's `compressAndSend()` helper,
which calls `c.LZ4_compress_default()` directly.

## wl-keepalive

A small companion binary that connects to `WLSTREAM_COMPOSITOR_SOCK` and periodically
sends `wl_display.sync` round-trips. Prevents cage from entering an idle state when no
real app has committed a frame recently (e.g., during startup or after all surfaces are
destroyed).

## stream-reader

Debug tool: connects to any wlstream socket and prints frame headers (event type, surface
id, pool id, width, height, raw/compressed size) to stdout. Useful for verifying that
wl-tunnel is producing frames without needing bsdos-core.

```sh
WLSTREAM_STREAM_SOCK=/tmp/bsdos/streams/appTerminal/wayland-stream.sock \
    ./zig-out/bin/stream-reader
```
