# Contributing to WLTunnel

## Bug reports

Open an issue with:
- What happened (expected vs actual)
- Environment: FreeBSD version, Zig version, platform (`-Dplatform=`)
- Relevant env vars (`WLSTREAM_*`)
- Log output (stderr from `wl-tunnel`)

## Pull requests

1. Fork → branch → PR.
2. Keep commits atomic with clear messages.
3. All four test steps must pass (see below).
4. No new `unsafe` outside libc FFI. No `unreachable` on hot paths.
5. If adding a new module, follow the AI header convention in existing files
   (`START_AI_HEADER` / `END_AI_HEADER`, `purpose`/`input`/`output`/`sideEffects` per function).

## Building

Requires Zig 0.13+ and FreeBSD 15.1 (or a FreeBSD aarch64 sysroot for cross-compile).

```sh
# Debug build (native)
zig build

# Release build
zig build -Doptimize=ReleaseFast -Dplatform=qemu_amd64

# Cross-compile for aarch64
zig build -Doptimize=ReleaseFast \
    -Dtarget=aarch64-freebsd \
    -Dplatform=qemu_aarch64 \
    --sysroot /path/to/freebsd-aarch64-sysroot
```

## Running tests

```sh
zig build test-input      # input event framing round-trip
zig build test-stream     # wlstream v1 header encode/decode
zig build test-protocol   # v1 frame encode/decode + pool hash dedup
zig build test-reconnect  # relay EOF detection + stream readability
```

Each test step runs in isolation — no compositor or socket required.

## Protocol changes

WLTunnel emits [wlstream v1](https://github.com/bzdOS/WLStream/blob/main/spec/WAYLAND_STREAM_PROTOCOL.md)
frames. Protocol changes must go through the WLStream spec first.

## License

By contributing, you agree that your contributions are licensed under MIT.
