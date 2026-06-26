// START_AI_HEADER
// MODULE: wayland-tunnel/src/stream.zig
// PURPOSE: Deliver v1 stream protocol frames from relay threads to bsdos-core clients
// INTENT: Decouple frame production (relay threads, one per Wayland client) from frame
//         delivery (bsdos-core socket). Relay threads call sendPoolData/sendSurfaceCommit
//         without knowing how many stream clients are connected.
// DEPENDENCIES: c.zig (write, setsockopt, fcntl, close), lz4 (LZ4_compress_default)
// PUBLIC_API:
//   sendPoolData(lz4_buf, pool_id, w, h, stride, fmt, pixels) — EV_POOL_DATA=0x03 to all clients
//   sendSurfaceCommit(surface_id, pool_id, ...) — EV_SURFACE_COMMIT=0x04 to all clients
//   sendSessionReset(reason, msg) — EV_SESSION_RESET=0xFE to all clients
//   sendStreamError(code, msg) — EV_ERROR=0xFF to all clients
//   sendCursorMove(x, y) — EV_CURSOR_MOVE=0x05 to all clients
//   writeExact(fd, data) — blocking write loop used by all senders
//   configureStreamFd(fd) — set blocking + SO_NOSIGPIPE on new stream client fd
//   lockClients() / unlockClients() — expose mutex for main.zig accept path
//   stream_clients[MAX_STREAM_CLIENTS] — registered bsdos-core fds (-1 = empty slot)
//   pool_reset_generation — atomic u32, incremented by main() on new client; relay threads
//                           watch this to force POOL_DATA resend after new client connects
// START_INVARIANTS
//   - stream_clients[] is only written under stream_clients_mutex
//   - pool_reset_generation is incremented ONLY by main.zig (single writer); relay threads
//     are read-only observers — this avoids ABA on the generation counter
//   - A disconnected client slot is set to -1 immediately on first write error;
//     subsequent senders skip it via the `if (fd < 0) continue` guard
//   - writeExact() retries on EINTR but returns false on any other error;
//     callers must close fd and set slot to -1 on false return
//   - LZ4 compression is skipped if WLSTREAM_NO_LZ4 env is set or if compressed >= raw size
// END_INVARIANTS
// END_AI_HEADER

pub const std = @import("std");
pub const c = @import("c").c;

pub const MAX_STREAM_CLIENTS = 4;

var stream_clients_mutex: std.Thread.Mutex = .{};
pub var stream_clients: [MAX_STREAM_CLIENTS]i32 = [_]i32{-1} ** MAX_STREAM_CLIENTS;

// pool_reset_generation: relay threads load this each frame; if changed, they reset
// their per-thread pool_hashes.sent[] so the next frame forces a fresh POOL_DATA send.
// Incremented by main.zig when a new stream client is accepted.
pub var pool_reset_generation: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

// lockClients:start
//   purpose: Acquire stream_clients_mutex for atomic multi-step access from main.zig
//   sideEffects: blocks until mutex available
pub fn lockClients() void {
    stream_clients_mutex.lock();
}
// lockClients:end

// unlockClients:start
//   purpose: Release stream_clients_mutex
//   sideEffects: wakes any blocked lockClients() caller
pub fn unlockClients() void {
    stream_clients_mutex.unlock();
}
// unlockClients:end

// writeExact:start
//   purpose: Write all bytes of data to fd, looping on short writes and retrying on EINTR
//   input: fd: blocking socket fd; data: byte slice to send
//   output: true if all bytes written, false on error (EPIPE, EBADF, etc.)
//   sideEffects: write() syscalls; logs on error with fd and byte offset
//   rationale: Wayland stream clients expect atomic protocol messages; partial writes
//              would corrupt the length-prefixed framing
pub fn writeExact(fd: i32, data: []const u8) bool {
    var written: usize = 0;
    const chunk_size = 1024 * 256;
    while (written < data.len) {
        const to_write = @min(chunk_size, data.len - written);
        const n = c.write(fd, data.ptr + written, to_write);
        if (n < 0) {
            const err = std.posix.errno(n);
            std.debug.print("[writeExact] write(fd={}) err={} offset={}\n", .{ fd, @intFromEnum(err), written });
            if (err == .INTR) continue;
            return false;
        }
        if (n == 0) return false;
        written += @intCast(n);
    }
    return true;
}
// writeExact:end

// configureStreamFd:start
//   purpose: Put new stream client fd into blocking mode and suppress SIGPIPE
//   input: fd: freshly accepted stream socket fd
//   sideEffects: fcntl(F_SETFL, ~O_NONBLOCK), setsockopt(SO_NOSIGPIPE=0x0800)
//   rationale: main.zig sets the server socket non-blocking for poll(); accepted fds
//              inherit that flag. writeExact() needs blocking semantics.
pub fn configureStreamFd(fd: i32) void {
    const fl = c.fcntl(fd, c.F_GETFL, @as(c_int, 0));
    _ = c.fcntl(fd, c.F_SETFL, fl & ~c.O_NONBLOCK);
    var nosigpipe: c_int = 1;
    _ = c.setsockopt(fd, c.SOL_SOCKET, 0x0800, &nosigpipe, @sizeOf(c_int));
}
// configureStreamFd:end

// tryCompressLz4:start
//   purpose: Attempt LZ4 compression on pixel data, returning compressed data if beneficial
//   input: lz4_buf: scratch buffer for LZ4 output; pixels: raw pixel data
//   output: struct { data: []const u8, lz4_len: u32, was_compressed: bool }
//   sideEffects: calls LZ4_compress_default if WLSTREAM_NO_LZ4 not set and pixels fit in lz4_buf
//   rationale: extracted from sendPoolData for testability; compression is skipped if
//              WLSTREAM_NO_LZ4 is set, pixels empty, or pixels > lz4_buf.len
pub const CompressResult = struct {
    data: []const u8,
    lz4_len: u32,
    was_compressed: bool,
};

pub fn tryCompressLz4(lz4_buf: []u8, pixels: []const u8) CompressResult {
    const raw_len: u32 = @intCast(pixels.len);

    const no_lz4 = std.posix.getenv("WLSTREAM_NO_LZ4") != null;
    if (pixels.len > 0 and !no_lz4 and pixels.len <= lz4_buf.len) {
        const max_compressed = @as(usize, @intCast(c.LZ4_compressBound(@intCast(pixels.len))));
        const result = c.LZ4_compress_default(
            @ptrCast(pixels.ptr),
            @ptrCast(lz4_buf.ptr),
            @intCast(pixels.len),
            @intCast(@min(max_compressed, lz4_buf.len)),
        );
        if (result > 0 and @as(usize, @intCast(result)) < pixels.len) {
            const lz4_len: u32 = @intCast(result);
            const ratio: f64 = @as(f64, @floatFromInt(lz4_len)) * 100.0 / @as(f64, @floatFromInt(raw_len));
            std.debug.print("[tunnel] LZ4 {} → {} bytes ({d:.0}%)\n", .{ raw_len, lz4_len, ratio });
            return .{
                .data = lz4_buf[0..@intCast(result)],
                .lz4_len = lz4_len,
                .was_compressed = true,
            };
        }
    }

    return .{
        .data = pixels,
        .lz4_len = raw_len,
        .was_compressed = false,
    };
}
// tryCompressLz4:end

// sendPoolData:start
//   purpose: Encode and send EV_POOL_DATA (0x03) frame to all registered stream clients
//   input: lz4_buf: scratch buffer for LZ4 output (caller-owned, reused across calls);
//          pool_id: SHM pool identifier; w/h/stride/format: pixel geometry;
//          pixels: raw BGRA pixel data (may be LZ4-compressed before sending)
//   output: void (disconnected clients are removed from stream_clients[] in-place)
//   sideEffects: LZ4_compress_default() on pixels if WLSTREAM_NO_LZ4 not set;
//                writeExact() to each stream_clients[] fd;
//                closes fd and sets slot to -1 on write error;
//                logs compression ratio and per-client send stats
//   rationale: bsdos-core caches POOL_DATA by pool_id; it needs this before any
//              SURFACE_COMMIT referencing the same pool_id can be rendered
pub fn sendPoolData(
    lz4_buf: []u8,
    pool_id: u32,
    width: u16,
    height: u16,
    stride: u32,
    format: u32,
    pixels: []const u8,
) void {
    const EVENT_POOL_DATA: u8 = 0x03; // per WLStream spec §POOL_DATA
    const raw_len: u32 = @intCast(pixels.len);

    const compress_result = tryCompressLz4(lz4_buf, pixels);
    const lz4_len = compress_result.lz4_len;
    const data_to_send = compress_result.data;

    const payload_header_size: u32 = 1 + 4 + 2 + 2 + 4 + 4 + 4 + 4;
    const payload_size: u32 = payload_header_size + lz4_len;

    var header: [25]u8 = undefined;
    var off: usize = 0;
    header[off] = EVENT_POOL_DATA; off += 1;
    std.mem.writeInt(u32, header[off..][0..4], pool_id, .little); off += 4;
    std.mem.writeInt(u16, header[off..][0..2], width, .little); off += 2;
    std.mem.writeInt(u16, header[off..][0..2], height, .little); off += 2;
    std.mem.writeInt(u32, header[off..][0..4], stride, .little); off += 4;
    std.mem.writeInt(u32, header[off..][0..4], format, .little); off += 4;
    std.mem.writeInt(u32, header[off..][0..4], raw_len, .little); off += 4;
    std.mem.writeInt(u32, header[off..][0..4], lz4_len, .little); off += 4;

    stream_clients_mutex.lock();
    defer stream_clients_mutex.unlock();

    for (stream_clients, 0..) |fd, i| {
        if (fd < 0) continue;

        var size_prefix: [4]u8 = undefined;
        std.mem.writeInt(u32, &size_prefix, payload_size, .little);

        if (!writeExact(fd, &size_prefix)) {
            _ = c.close(fd);
            stream_clients[i] = -1;
            std.debug.print("[tunnel] Stream client {d} disconnected (POOL_DATA size prefix write error)\n", .{i});
            continue;
        }

        if (!writeExact(fd, &header)) {
            _ = c.close(fd);
            stream_clients[i] = -1;
            std.debug.print("[tunnel] Stream client {d} disconnected (POOL_DATA header write error)\n", .{i});
            continue;
        }

        if (data_to_send.len > 0) {
            if (!writeExact(fd, data_to_send)) {
                _ = c.close(fd);
                stream_clients[i] = -1;
                std.debug.print("[tunnel] Stream client {d} disconnected (POOL_DATA pixels write error)\n", .{i});
                continue;
            }
        }

        std.debug.print("[tunnel] Sent POOL_DATA to client {d}: pool_id={} {}x{} stride={} raw={} lz4={} bytes\n", .{i, pool_id, width, height, stride, raw_len, lz4_len});
    }
}
// sendPoolData:end

// sendSurfaceCommit:start
//   purpose: Encode and send EV_SURFACE_COMMIT (0x04) to all stream clients
//   input: surface_id, pool_id, offset, buf geometry, damage rect
//   output: void (same error handling as sendPoolData)
//   sideEffects: writeExact() to each client; closes fd on error
//   rationale: viewer uses SURFACE_COMMIT to know WHICH region of a previously-sent
//              POOL_DATA to blit; pool_id links the two events
pub fn sendSurfaceCommit(
    surface_id: u32,
    pool_id: u32,
    offset: u32,
    buf_width: u16,
    buf_height: u16,
    buf_stride: u32,
    format: u32,
    damage_x: u16,
    damage_y: u16,
    damage_w: u16,
    damage_h: u16,
) void {
    const EVENT_SURFACE_COMMIT: u8 = 0x04; // per WLStream spec §SURFACE_COMMIT
    const payload_size: u32 = 1 + 4 + 4 + 4 + 2 + 2 + 4 + 4 + 2 + 2 + 2 + 2;

    var msg: [33]u8 = undefined;
    var off: usize = 0;
    msg[off] = EVENT_SURFACE_COMMIT; off += 1;
    std.mem.writeInt(u32, msg[off..][0..4], surface_id, .little); off += 4;
    std.mem.writeInt(u32, msg[off..][0..4], pool_id, .little); off += 4;
    std.mem.writeInt(u32, msg[off..][0..4], offset, .little); off += 4;
    std.mem.writeInt(u16, msg[off..][0..2], buf_width, .little); off += 2;
    std.mem.writeInt(u16, msg[off..][0..2], buf_height, .little); off += 2;
    std.mem.writeInt(u32, msg[off..][0..4], buf_stride, .little); off += 4;
    std.mem.writeInt(u32, msg[off..][0..4], format, .little); off += 4;
    std.mem.writeInt(u16, msg[off..][0..2], damage_x, .little); off += 2;
    std.mem.writeInt(u16, msg[off..][0..2], damage_y, .little); off += 2;
    std.mem.writeInt(u16, msg[off..][0..2], damage_w, .little); off += 2;
    std.mem.writeInt(u16, msg[off..][0..2], damage_h, .little); off += 2;

    stream_clients_mutex.lock();
    defer stream_clients_mutex.unlock();

    for (stream_clients, 0..) |fd, i| {
        if (fd < 0) continue;

        var size_prefix: [4]u8 = undefined;
        std.mem.writeInt(u32, &size_prefix, payload_size, .little);

        if (!writeExact(fd, &size_prefix)) {
            _ = c.close(fd);
            stream_clients[i] = -1;
            std.debug.print("[tunnel] Stream client {d} disconnected (SURFACE_COMMIT size prefix write error)\n", .{i});
            continue;
        }

        if (!writeExact(fd, &msg)) {
            _ = c.close(fd);
            stream_clients[i] = -1;
            std.debug.print("[tunnel] Stream client {d} disconnected (SURFACE_COMMIT write error)\n", .{i});
            continue;
        }

        std.debug.print("[tunnel] Sent SURFACE_COMMIT to client {d}: surface_id={} pool_id={}\n", .{i, surface_id, pool_id});
    }
}
// sendSurfaceCommit:end

// sendSessionReset:start
//   purpose: Send EV_SESSION_RESET (0xFE) to notify clients that stream state is invalid
//   input: reason: u8 code (1=client_disconnected); msg: human-readable description
//   sideEffects: writeExact() to all clients; closes fd on write error
//   rationale: viewer resets its pool cache on SESSION_RESET and waits for next POOL_DATA
pub fn sendSessionReset(reason: u8, msg: []const u8) void {
    const EVENT_SESSION_RESET: u8 = 0xFE; // per WLStream spec §SESSION_RESET
    const msg_len: u8 = @intCast(@min(msg.len, 255));
    const payload_size: u32 = 1 + 1 + 1 + @as(u32, msg_len);

    var header: [4 + 1 + 1 + 1]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], payload_size, .little);
    header[4] = EVENT_SESSION_RESET;
    header[5] = reason;
    header[6] = msg_len;

    stream_clients_mutex.lock();
    defer stream_clients_mutex.unlock();

    for (stream_clients, 0..) |fd, i| {
        if (fd < 0) continue;
        if (!writeExact(fd, &header)) {
            _ = c.close(fd);
            stream_clients[i] = -1;
            continue;
        }
        if (msg_len > 0) {
            _ = writeExact(fd, msg[0..msg_len]);
        }
    }
    std.debug.print("[tunnel] Sent SESSION_RESET reason={} msg={s}\n", .{ reason, msg[0..msg_len] });
}
// sendSessionReset:end

// sendStreamError:start
//   purpose: Send EV_ERROR (0xFF) with a protocol error code to all stream clients
//   input: code: error code (0x0001=pool_not_found); msg: description
//   sideEffects: writeExact() to all clients; closes fd on error
pub fn sendStreamError(code: u16, msg: []const u8) void {
    const EVENT_ERROR: u8 = 0xFF; // per WLStream spec §ERROR
    const msg_len: u8 = @intCast(@min(msg.len, 255));
    const payload_size: u32 = 1 + 2 + 1 + @as(u32, msg_len);

    var header: [4 + 1 + 2 + 1]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], payload_size, .little);
    header[4] = EVENT_ERROR;
    std.mem.writeInt(u16, header[5..7], code, .little);
    header[7] = msg_len;

    stream_clients_mutex.lock();
    defer stream_clients_mutex.unlock();

    for (stream_clients, 0..) |fd, i| {
        if (fd < 0) continue;
        if (!writeExact(fd, &header)) {
            _ = c.close(fd);
            stream_clients[i] = -1;
            continue;
        }
        if (msg_len > 0) {
            _ = writeExact(fd, msg[0..msg_len]);
        }
    }
    std.debug.print("[tunnel] Sent ERROR code=0x{x:04} msg={s}\n", .{ code, msg[0..msg_len] });
}
// sendStreamError:end

// sendCursorMove:start
//   purpose: Send EV_CURSOR_MOVE (0x05) cursor position update to all stream clients
//   input: x, y: cursor position in compositor pixel space
//   sideEffects: writeExact() to all clients; closes fd on error
pub fn sendCursorMove(x: i32, y: i32) void {
    const EVENT_CURSOR_MOVE: u8 = 0x05; // per WLStream spec §CURSOR_MOVE
    const payload_size: u32 = 1 + 4 + 4;

    var msg: [4 + 1 + 4 + 4]u8 = undefined;
    var off: usize = 0;
    std.mem.writeInt(u32, msg[off..][0..4], payload_size, .little); off += 4;
    msg[off] = EVENT_CURSOR_MOVE; off += 1;
    std.mem.writeInt(i32, msg[off..][0..4], x, .little); off += 4;
    std.mem.writeInt(i32, msg[off..][0..4], y, .little); off += 4;

    stream_clients_mutex.lock();
    defer stream_clients_mutex.unlock();

    for (stream_clients, 0..) |fd, i| {
        if (fd < 0) continue;
        if (!writeExact(fd, &msg)) {
            _ = c.close(fd);
            stream_clients[i] = -1;
        }
    }
    std.debug.print("[tunnel] Sent CURSOR_MOVE x={} y={}\n", .{ x, y });
}
// sendCursorMove:end
