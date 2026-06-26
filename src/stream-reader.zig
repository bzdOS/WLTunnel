// START_AI_HEADER
// MODULE: stream-reader.zig
// PURPOSE: standalone diagnostic that connects to the wayland-tunnel stream socket and prints one human-readable line per v1 stream event.
// INTENT: catch tunnel→core protocol mismatches on the VM (without involving the Mac client) — distinguishes LZ4 vs raw POOL_DATA, validates the 4-byte length prefix, flags truncated frames.
// DEPENDENCIES: std (env, fmt, heap), libc via @cImport (socket/connect/read/close).
// PUBLIC_API: main() !void, readExact(fd, buf) bool — internal helper for full-buffer reads.
// END_AI_HEADER

// stream-reader: v1 protocol verifier for wayland-stream.sock
// Connects to WLSTREAM_STREAM_SOCK (default /tmp/wayland-run/wayland-stream.sock),
// parses length-prefixed events, prints per-event diagnostics.
// Run on VM to verify tunnel output before involving Mac client.

const std = @import("std");
const c = @cImport({
    @cInclude("sys/socket.h");
    @cInclude("sys/un.h");
    @cInclude("unistd.h");
    @cInclude("string.h");
});

const DEFAULT_SOCK = "/tmp/wayland-run/wayland-stream.sock";

const EV_POOL_DATA: u8 = 0x03;
const EV_SURFACE_COMMIT: u8 = 0x04;
const EV_CURSOR_MOVE: u8 = 0x05;
const EV_SESSION_RESET: u8 = 0xFE;
const EV_ERROR: u8 = 0xFF;

// main:start
//   purpose: connect to WLSTREAM_STREAM_SOCK (or DEFAULT_SOCK), read length-prefixed v1 events in a loop, and print per-type diagnostics plus a final summary.
//   input:  env WLSTREAM_STREAM_SOCK; DEFAULT_SOCK = "/tmp/wayland-run/wayland-stream.sock".
//   output: never returns normally (loops on EOF or protocol error, then prints summary and exits).
//   sideEffects: opens one AF_UNIX SOCK_STREAM connection; allocates an 8 MiB read buffer; writes to stderr via std.debug.print.
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const sock_path = if (std.posix.getenv("WLSTREAM_STREAM_SOCK")) |s| s else DEFAULT_SOCK;

    const sock = c.socket(c.AF_UNIX, c.SOCK_STREAM, 0);
    if (sock < 0) return error.SocketFailed;
    defer _ = c.close(sock);

    var addr: c.sockaddr_un = undefined;
    addr.sun_family = c.AF_UNIX;
    @memset(&addr.sun_path, 0);
    if (sock_path.len >= addr.sun_path.len) return error.PathTooLong;
    @memcpy(addr.sun_path[0..sock_path.len], sock_path);

    if (c.connect(sock, @ptrCast(&addr), @sizeOf(c.sockaddr_un)) < 0) {
        std.debug.print("ERROR: connect({s}) failed\n", .{sock_path});
        return error.ConnectFailed;
    }
    std.debug.print("[stream-reader] Connected to {s}\n", .{sock_path});

    // Heap-allocate read buffer (up to 8MB for pixel frames)
    const BUF_SIZE = 8 * 1024 * 1024;
    const buf = try alloc.alloc(u8, BUF_SIZE);
    defer alloc.free(buf);

    var event_count: u64 = 0;
    var pool_events: u64 = 0;
    var commit_events: u64 = 0;
    var lz4_ok: u64 = 0;
    var lz4_raw: u64 = 0;

    while (true) {
        // Read 4-byte length prefix
        var len_buf: [4]u8 = undefined;
        if (!readExact(sock, &len_buf)) {
            std.debug.print("[stream-reader] EOF reading length prefix after {} events\n", .{event_count});
            break;
        }
        const payload_size = std.mem.readInt(u32, &len_buf, .little);

        if (payload_size == 0 or payload_size > BUF_SIZE) {
            std.debug.print("[stream-reader] INVALID payload_size={} — protocol error\n", .{payload_size});
            break;
        }

        if (!readExact(sock, buf[0..payload_size])) {
            std.debug.print("[stream-reader] EOF reading payload ({} bytes) after {} events\n", .{ payload_size, event_count });
            break;
        }

        event_count += 1;
        const ev = buf[0];

        switch (ev) {
            EV_POOL_DATA => {
                pool_events += 1;
                if (payload_size < 25) {
                    std.debug.print("[#{}] POOL_DATA: TRUNCATED (payload={})\n", .{ event_count, payload_size });
                    continue;
                }
                const pool_id  = std.mem.readInt(u32, buf[1..5],  .little);
                const width    = std.mem.readInt(u16, buf[5..7],  .little);
                const height   = std.mem.readInt(u16, buf[7..9],  .little);
                const stride   = std.mem.readInt(u32, buf[9..13], .little);
                const format   = std.mem.readInt(u32, buf[13..17],.little);
                const raw_len  = std.mem.readInt(u32, buf[17..21],.little);
                const lz4_len  = std.mem.readInt(u32, buf[21..25],.little);
                const data_len = payload_size - 25;

                const compressed = lz4_len < raw_len;
                if (compressed) { lz4_ok += 1; } else { lz4_raw += 1; }

                const ratio: f64 = if (raw_len > 0)
                    @as(f64, @floatFromInt(lz4_len)) * 100.0 / @as(f64, @floatFromInt(raw_len))
                else 0.0;

                std.debug.print("[#{}] POOL_DATA pool={} {}x{} stride={} fmt=0x{x} raw={} lz4={} ({d:.0}%) data_in_buf={} {s}\n", .{
                    event_count, pool_id, width, height, stride, format,
                    raw_len, lz4_len, ratio, data_len,
                    if (compressed) "LZ4" else "RAW",
                });

                if (data_len != lz4_len) {
                    std.debug.print("  WARN: data_in_buf({}) != lz4_len({}) — framing mismatch!\n", .{ data_len, lz4_len });
                }
            },

            EV_SURFACE_COMMIT => {
                commit_events += 1;
                if (payload_size < 33) {
                    std.debug.print("[#{}] SURFACE_COMMIT: TRUNCATED (payload={})\n", .{ event_count, payload_size });
                    continue;
                }
                const surface_id  = std.mem.readInt(u32, buf[1..5],  .little);
                const pool_id     = std.mem.readInt(u32, buf[5..9],  .little);
                const offset      = std.mem.readInt(u32, buf[9..13], .little);
                const buf_width   = std.mem.readInt(u16, buf[13..15],.little);
                const buf_height  = std.mem.readInt(u16, buf[15..17],.little);
                const buf_stride  = std.mem.readInt(u32, buf[17..21],.little);
                const format      = std.mem.readInt(u32, buf[21..25],.little);
                const dmg_x       = std.mem.readInt(u16, buf[25..27],.little);
                const dmg_y       = std.mem.readInt(u16, buf[27..29],.little);
                const dmg_w       = std.mem.readInt(u16, buf[29..31],.little);
                const dmg_h       = std.mem.readInt(u16, buf[31..33],.little);
                std.debug.print("[#{}] SURFACE_COMMIT surface={} pool={} offset={} {}x{} stride={} fmt=0x{x} dmg=[{},{},{},{}]\n", .{
                    event_count, surface_id, pool_id, offset,
                    buf_width, buf_height, buf_stride, format,
                    dmg_x, dmg_y, dmg_w, dmg_h,
                });
            },

            EV_CURSOR_MOVE => {
                if (payload_size < 9) { continue; }
                const x = std.mem.readInt(i32, buf[1..5], .little);
                const y = std.mem.readInt(i32, buf[5..9], .little);
                std.debug.print("[#{}] CURSOR_MOVE x={} y={}\n", .{ event_count, x, y });
            },

            EV_SESSION_RESET => {
                const reason = if (payload_size > 1) buf[1] else 0;
                std.debug.print("[#{}] SESSION_RESET reason={}\n", .{ event_count, reason });
            },

            EV_ERROR => {
                const code = if (payload_size >= 3) std.mem.readInt(u16, buf[1..3], .little) else 0;
                std.debug.print("[#{}] ERROR code=0x{x:04}\n", .{ event_count, code });
            },

            else => {
                std.debug.print("[#{}] UNKNOWN event=0x{x:02} payload={}\n", .{ event_count, ev, payload_size });
            },
        }
    }

    std.debug.print("\n--- Summary ---\n", .{});
    std.debug.print("Total events : {}\n", .{event_count});
    std.debug.print("POOL_DATA    : {} ({} LZ4, {} raw)\n", .{ pool_events, lz4_ok, lz4_raw });
    std.debug.print("SURFACE_COMMIT: {}\n", .{commit_events});
    if (lz4_raw > 0) {
        std.debug.print("WARN: {} uncompressed POOL_DATA events — metal-viewer must NOT call lz4_flex::decompress on these\n", .{lz4_raw});
    }
}
// main:end

// readExact:start
//   purpose: read exactly buf.len bytes from fd (handles short reads), return false on EOF or error.
//   input:  fd (open socket), buf (destination slice).
//   output: true on success, false if read() returns <=0 before the buffer is full.
//   sideEffects: blocks reading from fd.
fn readExact(fd: c_int, buf: []u8) bool {
    var done: usize = 0;
    while (done < buf.len) {
        const n = c.read(fd, buf[done..].ptr, buf.len - done);
        if (n <= 0) return false;
        done += @intCast(n);
    }
    return true;
}
// readExact:end
