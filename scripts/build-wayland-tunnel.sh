#!/bin/sh
set -eu
. "$(dirname "$0")/_agent.sh"

echo "Building wayland-tunnel in FreeBSD VM (via 9p/p9fs)..."

# Sources are already at /mnt/bsdos/wayland-tunnel/ via 9p mount.
# Build in-place under /tmp/wayland-tunnel-build to avoid polluting the
# host-shared 9p mount with zig-cache (which has FreeBSD-specific binaries).

echo "Preparing build directory in guest..."
agent_exec "su -m root -c 'mkdir -p /tmp/wayland-tunnel-build && chown freebsd /tmp/wayland-tunnel-build'"

echo "Syncing sources from 9p mount to build directory..."
agent_exec "cp -r /mnt/bsdos/wayland-tunnel/src /tmp/wayland-tunnel-build/ && cp -r /mnt/bsdos/wayland-tunnel/vendor /tmp/wayland-tunnel-build/ && cp /mnt/bsdos/wayland-tunnel/build.zig /tmp/wayland-tunnel-build/"

echo "Cleaning previous build artifacts..."
agent_exec "rm -rf /tmp/wayland-tunnel-build/.zig-cache /tmp/wayland-tunnel-build/zig-out 2>/dev/null; true"

echo "Running zig build in FreeBSD VM (native build)..."
AGENT_EXEC_TIMEOUT=300 agent_exec "cd /tmp/wayland-tunnel-build && zig build -Doptimize=ReleaseSafe 2>&1"

echo "Verifying binary was created..."
agent_exec "test -f /tmp/wayland-tunnel-build/zig-out/bin/wayland-tunnel" || {
    echo "ERROR: Binary not found after build"
    exit 1
}

echo "Installing to /usr/local/bin/wayland-tunnel..."
agent_exec "su -m root -c 'install -m 755 /tmp/wayland-tunnel-build/zig-out/bin/wayland-tunnel /usr/local/bin/wayland-tunnel'"

echo "Installing wl-keepalive to /usr/local/bin/wl-keepalive..."
if agent_exec "test -f /tmp/wayland-tunnel-build/zig-out/bin/wl-keepalive" 2>/dev/null; then
    agent_exec "su -m root -c 'install -m 755 /tmp/wayland-tunnel-build/zig-out/bin/wl-keepalive /usr/local/bin/wl-keepalive'"
    echo "✓ wl-keepalive installed successfully"
else
    echo "⚠ WARNING: wl-keepalive binary not found, skipping install"
fi

echo "Installing stream-reader to /usr/local/bin/stream-reader..."
if agent_exec "test -f /tmp/wayland-tunnel-build/zig-out/bin/stream-reader" 2>/dev/null; then
    agent_exec "su -m root -c 'install -m 755 /tmp/wayland-tunnel-build/zig-out/bin/stream-reader /usr/local/bin/stream-reader'"
    echo "✓ stream-reader installed successfully"
else
    echo "⚠ WARNING: stream-reader binary not found, skipping install"
fi

echo "✓ wayland-tunnel built and installed successfully (FreeBSD native)"
