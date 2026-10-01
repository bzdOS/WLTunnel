// START_AI_HEADER
// MODULE: wl_keepalive.zig
// PURPOSE: minimal Wayland client that stays connected to a compositor so cage/Firefox-style apps have a live seat when no real client is around.
// INTENT: cage as a headless process has no clients to keep it alive; wl_keepalive connects once and sleeps forever in 60-second nanosleep loops, so cage's lifetime = wl_keepalive's lifetime. Read WAYLAND_DISPLAY + XDG_RUNTIME_DIR from env so the same binary works in tests and the real runtime dir.
// DEPENDENCIES: std (heap GPA, getenv, fmt), libc via @cImport (socket/connect/close/nanosleep).
// PUBLIC_API: main() !void — binary entry point.
//
// @deprecated (2026-07-03, #146):
//   stream_manager.rs now spawns cage with `-s` (shell mode) + a named FIFO for stdin,
//   which keeps cage alive without any Wayland client shim.  wl-keepalive is no longer
//   spawned from StreamManager.  This binary remains for:
//     (a) infra/scripts/bsdos-pipeline (legacy sh supervisor, also deprecated)
//     (b) infra/scripts/_ssh.sh cage_start (manual/debug only)
//   Both callers are annotated with @deprecated.  Remove wl-keepalive entirely once
//   bsdos-pipeline is retired and cage_start is updated to cage -s + FIFO.
// END_AI_HEADER

// wl_keepalive: минимальный Wayland клиент для cage keepalive.
// Подключается к compositor, создаёт невидимый surface, спит бесконечно.
// Использование: wl_keepalive (читает WAYLAND_DISPLAY и XDG_RUNTIME_DIR из env)

const std = @import("std");
const c = @cImport({
    @cInclude("sys/socket.h");
    @cInclude("sys/un.h");
    @cInclude("unistd.h");
    @cInclude("stdlib.h");
    @cInclude("string.h");
    @cInclude("time.h");
});

// main:start
//   purpose: connect to the Wayland socket derived from XDG_RUNTIME_DIR + WAYLAND_DISPLAY (or "/tmp/wayland-run/wayland-0") and run an infinite 60-second nanosleep loop.
//   input:  env (XDG_RUNTIME_DIR, WAYLAND_DISPLAY).
//   output: returns (exit 0) once orphaned — the cage parent died and we were reparented to init (getppid()==1); returns error.SocketFailed if socket(AF_UNIX) fails; connect failure is logged and ignored (cage may not be up yet).
//   sideEffects: opens an AF_UNIX SOCK_STREAM connection to the Wayland socket; loops on nanosleep(5s) checking getppid(), exiting when the cage parent dies (prevents orphaned keepalive accumulation).
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Получить путь к Wayland сокету
    const xdg_runtime = std.posix.getenv("XDG_RUNTIME_DIR") orelse "/tmp/wayland-run";
    const wayland_display = std.posix.getenv("WAYLAND_DISPLAY") orelse "wayland-0";

    var sock_path: [108]u8 = undefined;
    const path = try std.fmt.bufPrint(&sock_path, "{s}/{s}", .{ xdg_runtime, wayland_display });

    std.debug.print("[wl-keepalive] Attempting to connect to {s}/{s}\n", .{ xdg_runtime, wayland_display });

    // Подключиться к compositor
    const fd = c.socket(c.AF_UNIX, c.SOCK_STREAM, 0);
    if (fd < 0) {
        std.debug.print("[wl-keepalive] socket() failed\n", .{});
        return error.SocketFailed;
    }
    defer _ = c.close(fd);

    var addr: c.sockaddr_un = undefined;
    @memset(std.mem.asBytes(&addr), 0);
    addr.sun_family = c.AF_UNIX;
    @memcpy(addr.sun_path[0..path.len], path);

    if (c.connect(fd, @ptrCast(&addr), @sizeOf(c.sockaddr_un)) < 0) {
        std.debug.print("[wl-keepalive] connect to {s} failed (will continue anyway)\n", .{path});
    } else {
        std.debug.print("[wl-keepalive] connected to compositor\n", .{});
    }

    _ = allocator; // keepalive uses only a stack buffer + libc; no heap needed

    // Живём, пока жив cage (наш родитель). Если cage умирает, ядро репарентит нас
    // на init → getppid()==1. Тогда мы больше не нужны и выходим: без этой проверки
    // осиротевшие keepalive копятся тысячами и съедают RAM+swap (корень утечки 2026-07-03).
    std.debug.print("[wl-keepalive] running (exits when cage/parent dies)\n", .{});
    while (true) {
        // Короткий сон + проверка родителя: сирота обнаруживается и завершается ≤5с.
        var ts: c.struct_timespec = undefined;
        ts.tv_sec = 5;
        ts.tv_nsec = 0;
        _ = c.nanosleep(&ts, null);
        if (c.getppid() == 1) {
            std.debug.print("[wl-keepalive] parent (cage) gone — exiting to avoid orphan leak\n", .{});
            return;
        }
    }
}
// main:end
