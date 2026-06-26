// START_AI_HEADER
// MODULE: wayland-tunnel/src/relay.zig
// PURPOSE: Proxy Wayland protocol between a client (Firefox/foot) and cage compositor,
//          capturing frames and injecting synthetic input events
// INTENT: One relay thread per Wayland client. Intercepts get_pointer/get_keyboard to
//         synthesise virtual input objects; captures SHM commits for the stream;
//         injects keyboard/pointer events received from bsdos-core input.sock.
// DEPENDENCIES: stream.zig, socket.zig, protocol.zig, input.zig, wl_shm.zig, wl_registry.zig
// PUBLIC_API:
//   relayThreadFn(args_ptr) — thread entry: allocate buffers, run main relay loop
//   RelayBuffers — heap scratch: lz4_buf (16MB+) + pixel_buf (16MB+)
//   RelayThreadArgs — spawn params: client_fd, compositor_path, allocator
// START_INVARIANTS
//   - Each relay thread owns RelayBuffers, WlShmTracker, WlRegistry, InputState.
//     Only stream.stream_clients[] is shared (stream_clients_mutex).
//   - pool_hashes[32] per thread: FNV-1a dedup, reset when pool_reset_generation changes.
//   - rewriteClientBuffer() MUST run before sendKeymap()/caps injection.
//   - focused_surface_id updated from frame.surface_id; pointer/keyboard enter deferred until non-zero.
// END_INVARIANTS
// END_AI_HEADER

pub const std = @import("std");
pub const c = @import("c").c;
const stream_mod = @import("stream");
const socket_mod = @import("socket");
const protocol = @import("protocol");
const input = @import("input");
const wl_shm = @import("wl_shm");
const wl_registry = @import("wl_registry");

// logEvent:start
//   purpose: flush-on-write debug print
//   sideEffects: stderr write + fflush
fn logEvent(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt, args);
    _ = c.fflush(null);
}
// logEvent:end

pub const RelayBuffers = struct {
    lz4_buf: []u8,
    pixel_buf: []u8,
    allocator: std.mem.Allocator,

    // RelayBuffers.init:start
    //   purpose: allocate lz4_buf and pixel_buf (~32MB total)
    //   input: allocator
    //   output: RelayBuffers or error
    //   sideEffects: two heap allocations
    pub fn init(allocator: std.mem.Allocator) !RelayBuffers {
        const lz4 = try allocator.alloc(u8, 16 * 1024 * 1024 + 65536);
        errdefer allocator.free(lz4);
        const px = try allocator.alloc(u8, 16 * 1024 * 1024 + 64);
        return .{ .lz4_buf = lz4, .pixel_buf = px, .allocator = allocator };
    }
    // RelayBuffers.init:end

    // RelayBuffers.deinit:start
    //   purpose: free lz4_buf and pixel_buf
    //   sideEffects: two allocator.free()
    pub fn deinit(self: *RelayBuffers) void {
        self.allocator.free(self.lz4_buf);
        self.allocator.free(self.pixel_buf);
    }
    // RelayBuffers.deinit:end
};

pub const RelayThreadArgs = struct {
    client_fd: c_int,
    compositor_path: [128]u8,
    compositor_path_len: usize,
    /// Persistent input.sock listening fd, created once in main() at startup.
    /// Owned by main; relay thread must NOT close it.
    input_listen_fd: c_int,
    allocator: std.mem.Allocator,
};

// fnv1aHash:start
//   purpose: FNV-1a hash of byte slice for frame dedup
//   input: data []const u8
//   output: u64
//   sideEffects: none
fn fnv1aHash(data: []const u8) u64 {
    var hash: u64 = 14695981039346656037;
    for (data) |byte| {
        hash ^= @as(u64, byte);
        hash *%= 1099511628211;
    }
    return hash;
}
// fnv1aHash:end

// relayThreadFn:start
//   purpose: thread entry — init buffers, run relay loop, cleanup
//   sideEffects: heap alloc, closes client_fd on exit, destroys args_ptr
pub fn relayThreadFn(args_ptr: *RelayThreadArgs) void {
    const client_fd = args_ptr.client_fd;
    const input_listen_fd = args_ptr.input_listen_fd;
    const allocator = args_ptr.allocator;
    const compositor_path = args_ptr.compositor_path[0..args_ptr.compositor_path_len];
    defer allocator.destroy(args_ptr);

    var buffers = RelayBuffers.init(allocator) catch |e| {
        std.debug.print("[relay-thread] Failed to allocate buffers: {}\n", .{e});
        _ = c.close(client_fd);
        return;
    };
    defer buffers.deinit();

    handleWaylandClientWithRelay(
        client_fd,
        compositor_path,
        input_listen_fd,
        &buffers,
    ) catch |e| {
        std.debug.print("[relay-thread] Relay error: {}\n", .{e});
    };
}
// relayThreadFn:end

// bindListenInputSock:start
//   purpose: bind and listen on per-stream input.sock so stream_input_handler can connect
//   output: fd >= 0 on success, -1 on failure
//   sideEffects: unlink stale socket, socket() + bind() + listen() syscalls
pub fn bindListenInputSock(sock_path: []const u8) c_int {
    const fd = c.socket(c.AF_UNIX, c.SOCK_STREAM, 0);
    if (fd < 0) return -1;
    var iaddr: c.sockaddr_un = undefined;
    iaddr.sun_family = c.AF_UNIX;
    _ = c.memset(&iaddr.sun_path, 0, iaddr.sun_path.len);
    @memcpy(iaddr.sun_path[0..sock_path.len], sock_path);
    // Remove stale socket
    _ = c.unlink(iaddr.sun_path[0..].ptr);
    if (c.bind(fd, @ptrCast(&iaddr), @sizeOf(c.sockaddr_un)) < 0) {
        _ = c.close(fd);
        return -1;
    }
    if (c.listen(fd, 4) < 0) {
        _ = c.close(fd);
        return -1;
    }
    std.debug.print("[tunnel] Input sock listening: {s}\n", .{sock_path});
    return fd;
}
// bindListenInputSock:end

const VIRTUAL_KB_OFFSET: u32 = 0x10000;
const VIRTUAL_PTR_OFFSET: u32 = 0x20000;

// dumpBuffer:start
//   purpose: print Wayland message structure for debugging
//   sideEffects: logEvent calls
fn dumpBuffer(label: []const u8, buf: []const u8) void {
    logEvent("[dump] {s} ({} bytes):\n", .{ label, buf.len });
    var i: usize = 0;
    while (i + 8 <= buf.len) {
        const obj_id = std.mem.readInt(u32, buf[i..][0..4], .little);
        const size_op = std.mem.readInt(u32, buf[i + 4..][0..4], .little);
        const sz: usize = @as(usize, @as(u16, @truncate(size_op >> 16)));
        const op: u16 = @truncate(size_op);
        if (sz < 8 or i + sz > buf.len) break;
        var arg0: u32 = 0;
        if (sz >= 12) arg0 = std.mem.readInt(u32, buf[i + 8..][0..4], .little);
        logEvent("[dump]   off={d:4} obj={d:5} op={d:3} sz={d:3} arg0={d}\n",
            .{ i, obj_id, op, sz, arg0 });
        i += sz;
    }
}
// dumpBuffer:end

// rewriteClientBuffer:start
//   purpose: intercept get_pointer/get_keyboard, replace with create_region+destroy gap-fill, pass other messages through
//   input: src Wayland bytes, dst output buffer, fds, tracker, registry, id capture pointers
//   output: bytes written to dst
//   sideEffects: registers ptr_id/kb_id in registry, calls processSingleMessageForTracking
fn rewriteClientBuffer(
    src: []const u8,
    dst: []u8,
    fds: []c_int,
    tracker: *wl_shm.WlShmTracker,
    registry: *wl_registry.WlRegistry,
    keyboard_id_ptr: *u32,
    pointer_id_ptr: *u32,
) usize {
    var src_off: usize = 0;
    var dst_len: usize = 0;
    var fd_idx: usize = 0;

    while (src_off + 8 <= src.len) {
        const obj_id = std.mem.readInt(u32, src[src_off..][0..4], .little);
        const size_opcode = std.mem.readInt(u32, src[src_off + 4..][0..4], .little);
        const msg_size: usize = @as(usize, @as(u16, @truncate(size_opcode >> 16)));
        const op_code: u16 = @truncate(size_opcode);
        if (msg_size < 8) break;
        if (src_off + msg_size > src.len) break;

        const iface = registry.getInterface(obj_id);

        if (iface == .wl_seat and op_code == 0 and msg_size >= 12) {
            // get_pointer: capture ID, then fill the ID slot in cage with a dummy
            // create_region+destroy so cage's wl_map has no gaps.  Gaps cause
            // libwayland server to reject the next new_id with "not a valid new
            // object id" because wl_map_reserve_new sees a never-zero slot at the
            // skipped index after array growth.
            const ptr_id = std.mem.readInt(u32, src[src_off + 8..][0..4], .little);
            pointer_id_ptr.* = ptr_id;
            _ = registry.register(ptr_id, .wl_pointer, obj_id);
            if (registry.findId(.wl_compositor)) |cid| {
                if (dst_len + 20 <= dst.len) {
                    // create_region(ptr_id)
                    std.mem.writeInt(u32, dst[dst_len..][0..4], cid, .little);
                    std.mem.writeInt(u32, dst[dst_len+4..][0..4], (@as(u32,12)<<16)|1, .little);
                    std.mem.writeInt(u32, dst[dst_len+8..][0..4], ptr_id, .little);
                    dst_len += 12;
                    // wl_region.destroy(ptr_id)
                    std.mem.writeInt(u32, dst[dst_len..][0..4], ptr_id, .little);
                    std.mem.writeInt(u32, dst[dst_len+4..][0..4], (@as(u32,8)<<16)|0, .little);
                    dst_len += 8;
                }
            }
            logEvent("[rewrite] get_pointer→fill; ptr_id={}\n", .{ptr_id});
        } else if (iface == .wl_seat and op_code == 1 and msg_size >= 12) {
            // get_keyboard: same gap-fill strategy.
            const kb_id = std.mem.readInt(u32, src[src_off + 8..][0..4], .little);
            keyboard_id_ptr.* = kb_id;
            _ = registry.register(kb_id, .wl_keyboard, obj_id);
            if (registry.findId(.wl_compositor)) |cid| {
                if (dst_len + 20 <= dst.len) {
                    std.mem.writeInt(u32, dst[dst_len..][0..4], cid, .little);
                    std.mem.writeInt(u32, dst[dst_len+4..][0..4], (@as(u32,12)<<16)|1, .little);
                    std.mem.writeInt(u32, dst[dst_len+8..][0..4], kb_id, .little);
                    dst_len += 12;
                    std.mem.writeInt(u32, dst[dst_len..][0..4], kb_id, .little);
                    std.mem.writeInt(u32, dst[dst_len+4..][0..4], (@as(u32,8)<<16)|0, .little);
                    dst_len += 8;
                }
            }
            logEvent("[rewrite] get_keyboard→fill; kb_id={}\n", .{kb_id});
        } else if (iface == .wl_pointer or iface == .wl_keyboard) {
            // Messages from virtual input objects (set_cursor, release, etc.) —
            // cage doesn't know about these IDs; drop to avoid protocol errors.
            logEvent("[rewrite] drop virtual input obj={} op={}\n", .{obj_id, op_code});
        } else {
            if (dst_len + msg_size <= dst.len) {
                @memcpy(dst[dst_len..][0..msg_size], src[src_off..][0..msg_size]);
                dst_len += msg_size;
            }
            processSingleMessageForTracking(src[src_off..], fds[fd_idx..], tracker, registry, &fd_idx);
        }

        src_off += msg_size;
    }
    return dst_len;
}
// rewriteClientBuffer:end

// processSingleMessageForTracking:start
//   purpose: update WlShmTracker and WlRegistry from one Wayland message
//   sideEffects: tracker.addPool/addBuffer/attachBuffer/markCommit, registry.register/unregister
fn processSingleMessageForTracking(
    data: []const u8,
    fds: []c_int,
    tracker: *wl_shm.WlShmTracker,
    registry: *wl_registry.WlRegistry,
    fd_idx: *usize,
) void {
    if (data.len < 8) return;
    const obj_id = std.mem.readInt(u32, data[0..4], .little);
    const size_opcode = std.mem.readInt(u32, data[4..8], .little);
    const op_code: u16 = @truncate(size_opcode);
    const iface = registry.getInterface(obj_id);

    if (iface == .wl_display and op_code == 1 and data.len >= 12) {
        const new_id = std.mem.readInt(u32, data[8..12], .little);
        _ = registry.register(new_id, .wl_registry, obj_id);
    }
    if (iface == .wl_compositor and op_code == 0 and data.len >= 12) {
        const new_id = std.mem.readInt(u32, data[8..12], .little);
        _ = registry.register(new_id, .wl_surface, obj_id);
        logEvent("[track] create_surface new_id={}\n", .{new_id});
    }
    if (iface == .wl_shm and op_code == 0 and fds.len > 0 and data.len >= 16) {
        const pool_id = std.mem.readInt(u32, data[8..12], .little);
        const size = std.mem.readInt(u32, data[12..16], .little);
        tracker.addPool(pool_id, fds[0], size) catch {};
        _ = registry.register(pool_id, .wl_shm_pool, obj_id);
        fd_idx.* += 1;
        logEvent("[track] create_pool pool_id={} size={}\n", .{ pool_id, size });
    }
    if (iface == .wl_shm_pool and op_code == 0 and data.len >= 32) {
        const buf_id = std.mem.readInt(u32, data[8..12], .little);
        const offset = std.mem.readInt(u32, data[12..16], .little);
        const width = std.mem.readInt(u32, data[16..20], .little);
        const height = std.mem.readInt(u32, data[20..24], .little);
        const stride = std.mem.readInt(u32, data[24..28], .little);
        const format = std.mem.readInt(u32, data[28..32], .little);
        tracker.addBuffer(buf_id, obj_id, offset, width, height, stride, format) catch {};
        _ = registry.register(buf_id, .wl_buffer, obj_id);
        logEvent("[track] create_buffer buf_id={} {}x{}\n", .{ buf_id, width, height });
    }
    if (iface == .wl_shm_pool and op_code == 2 and data.len >= 12) {
        const new_size = std.mem.readInt(u32, data[8..12], .little);
        tracker.resizePool(obj_id, new_size) catch {};
    }
    if (iface == .wl_shm_pool and op_code == 1) {
        tracker.releasePool(obj_id) catch {};
        _ = registry.unregister(obj_id);
    }
    if (iface == .wl_buffer and op_code == 0) {
        tracker.releaseBuffer(obj_id) catch {};
        _ = registry.unregister(obj_id);
    }
    if (iface == .wl_registry and op_code == 0 and data.len >= 20) {
        const iface_str_len = std.mem.readInt(u32, data[12..16], .little);
        const padded_len: usize = (@as(usize, iface_str_len) + 3) & ~@as(usize, 3);
        const version_offset: usize = 16 + padded_len;
        if (data.len >= version_offset + 8) {
            const new_id = std.mem.readInt(u32, data[version_offset + 4..][0..4], .little);
            var name_bytes: [128]u8 = undefined;
            var name_len: usize = 0;
            if (iface_str_len > 1 and iface_str_len <= 128) {
                name_len = iface_str_len - 1;
                if (16 + name_len <= data.len) {
                    @memcpy(name_bytes[0..name_len], data[16..][0..name_len]);
                }
            }
            const parsed_iface = wl_registry.WlRegistry.parseInterface(name_bytes[0..name_len]);
            _ = registry.register(new_id, parsed_iface, obj_id);
            logEvent("[track] bind new_id={} iface={s}\n", .{ new_id, wl_registry.WlRegistry.interfaceName(parsed_iface) });
        }
    }
    if (iface == .wl_surface and op_code == 1 and data.len >= 12) {
        const buf_id = std.mem.readInt(u32, data[8..12], .little);
        tracker.attachBuffer(obj_id, buf_id) catch {};
    }
    if (iface == .wl_surface and op_code == 6) {
        tracker.markCommit(obj_id);
    }
}
// processSingleMessageForTracking:end

// handleWaylandClientWithRelay:start
//   purpose: main relay loop — proxy client↔compositor, capture frames, inject input
//   input: input_listen_fd — persistent listening fd from main(); relay does NOT own it, must not close it
//   sideEffects: closes compositor_fd; writes to stream_clients[] via stream_mod; reads/writes client_fd and compositor_fd
fn handleWaylandClientWithRelay(
    client_fd: c_int,
    compositor_path: []const u8,
    input_listen_fd: c_int,
    buffers: *RelayBuffers,
) !void {
    defer _ = c.close(client_fd);
    std.debug.print("[tunnel] Client relay started (fd={})\n", .{client_fd});

    // START_RELAY_INIT
    std.debug.print("[tunnel] Connecting to compositor at {s}...\n", .{compositor_path});
    const compositor_fd = socket_mod.connectToCompositor(compositor_path) catch |e| {
        std.debug.print("[tunnel] Cannot connect to compositor: {} (path: {s})\n", .{e, compositor_path});
        return;
    };
    defer _ = c.close(compositor_fd);

    std.debug.print("[tunnel] Relay started client↔compositor (client_fd={} compositor_fd={})\n", .{client_fd, compositor_fd});

    var tracker = wl_shm.WlShmTracker{};
    defer tracker.deinit();

    var registry = wl_registry.WlRegistry.init();

    // Deferred caps injection: after foot's first wl_surface.commit we send a synthetic
    // wl_seat.capabilities(3) so get_keyboard/get_pointer arrive in a clean batch with
    // no simultaneous bind/create messages → no cage object-ID conflicts.
    var deferred_caps_seat_id: u32 = 0;
    var caps_injected: bool = false;

    var input_state = input.InputState.init();
    var input_frames = input.InputFrameBuffer.init();

    const PoolHash = struct { pool_id: u32, hash: u64, sent: bool };
    var pool_hashes: [32]PoolHash = [_]PoolHash{.{ .pool_id = 0, .hash = 0, .sent = false }} ** 32;
    var last_pool_reset_gen: u32 = stream_mod.pool_reset_generation.load(.acquire);

    const MAX_WAYLAND_MESSAGE = 4096;
    var client_buf: [MAX_WAYLAND_MESSAGE]u8 = undefined;
    var compositor_buf: [MAX_WAYLAND_MESSAGE]u8 = undefined;

    // input_listen_fd: persistent listening socket from main() — lives for the full
    // wayland-tunnel lifetime so stream_input_handler can (re)connect at any time,
    // even between Chrome sessions.
    var input_fd: c_int = -1; // accepted client connection from stream_input_handler

    // START_LAST_FRAME_CACHE
    //   purpose: cache metadata of last sent frame so we can resend it to
    //            newly connected stream clients without waiting for Firefox
    //            to commit a new frame (late-join fix).
    //   lifetime: updated on every successful frame send in FRAME_CAPTURE block
    //   consumedBy: the late-join-resend block in the poll loop
    const LastFrameInfo = struct {
        surface_id: u32,
        pool_id: u32,
        buf_offset: u32,
        width: u16,
        height: u16,
        stride: u32,
        format: u32,
        pixel_len: usize,
    };
    var last_frame_info: ?LastFrameInfo = null;
    // END_LAST_FRAME_CACHE

    // input_listen_fd is owned by main() — do NOT close it here.
    // Only close the accepted per-session connection (input_fd).
    defer { if (input_fd >= 0) _ = c.close(input_fd); }

    // poll[2]: listen for accept when no client; read when client connected
    var fds: [3]c.pollfd = .{
        .{ .fd = client_fd,        .events = c.POLLIN, .revents = 0 },
        .{ .fd = compositor_fd,    .events = c.POLLIN, .revents = 0 },
        .{ .fd = input_listen_fd,  .events = @as(c_short, if (input_listen_fd >= 0) c.POLLIN else 0), .revents = 0 },
    };
    // END_RELAY_INIT

    // START_RELAY_POLL_LOOP
    while (true) {
        const poll_timeout: c_int = 500;
        const ready = c.poll(&fds, 3, poll_timeout);
        if (ready < 0) {
            std.debug.print("[tunnel] Poll error\n", .{});
            break;
        }

        // START_LATE_JOIN_RESEND
        //   purpose: when a new stream client connects (pool_reset_generation increments),
        //            resend the last known frame from pixel_buf cache so the client gets
        //            immediate content instead of waiting for Firefox's next commit.
        //   trigger: pool_reset_generation change (set by stream.zig on new client accept)
        //   precondition: last_frame_info != null (at least one frame captured before)
        //   pixelSource: buffers.pixel_buf (still holds last frame's raw pixel data)
        const pool_reset_gen = stream_mod.pool_reset_generation.load(.acquire);
        if (pool_reset_gen != last_pool_reset_gen) {
            last_pool_reset_gen = pool_reset_gen;
            for (&pool_hashes) |*ph| { ph.sent = false; }

            if (last_frame_info) |lf| {
                const pixels = buffers.pixel_buf[0..lf.pixel_len];
                stream_mod.sendPoolData(
                    buffers.lz4_buf,
                    lf.pool_id,
                    lf.width,
                    lf.height,
                    lf.stride,
                    lf.format,
                    pixels,
                );
                stream_mod.sendSurfaceCommit(
                    lf.surface_id,
                    lf.pool_id,
                    lf.buf_offset,
                    lf.width,
                    lf.height,
                    lf.stride,
                    lf.format,
                    0,
                    0,
                    @intCast(@min(lf.width, 65535)),
                    @intCast(@min(lf.height, 65535)),
                );
                logEvent("[relay] Late-join: resent last frame to new stream client (gen={})\n", .{pool_reset_gen});
            }
        }
                // END_LATE_JOIN_RESEND


        // START_RELAY_INPUT_FD
        if (fds[2].revents & c.POLLIN != 0) {
            if (input_fd < 0) {
                // Accept stream_input_handler connection
                const accepted = c.accept(input_listen_fd, null, null);
                if (accepted >= 0) {
                    input_fd = accepted;
                    fds[2].fd = input_fd;
                    std.debug.print("[tunnel] Input client connected\n", .{});
                }
            } else {
                var input_buf: [64]u8 = undefined;
                const n = c.read(input_fd, &input_buf, input_buf.len);
                if (n > 0) {
                    input_frames.pushBytes(client_fd, input_buf[0..@intCast(n)], &input_state);
                } else if (n <= 0) {
                    std.debug.print("[tunnel] Input client disconnected\n", .{});
                    _ = c.close(input_fd);
                    input_fd = -1;
                    fds[2].fd = input_listen_fd; // back to waiting for accept
                }
            }
        }
        // END_RELAY_INPUT_FD

        // START_RELAY_POLLHUP
        if (fds[0].revents & c.POLLHUP != 0 or fds[1].revents & c.POLLHUP != 0) {
            std.debug.print("[tunnel] Connection closed (POLLHUP client={} compositor={})\n",
                .{ fds[0].revents & c.POLLHUP, fds[1].revents & c.POLLHUP });
            stream_mod.sendSessionReset(1, "client_disconnected");
            break;
        }
        // END_RELAY_POLLHUP

        // START_RELAY_CLIENT_MSG
        if (fds[0].revents & c.POLLIN != 0) {
            var fds_buf: [socket_mod.MAX_FDS_PER_MSG]c_int = [_]c_int{-1} ** socket_mod.MAX_FDS_PER_MSG;
            var fd_count: usize = 0;

            const n = socket_mod.recvWithFds(client_fd, &client_buf, &fds_buf, &fd_count) catch |e| {
                std.debug.print("[tunnel] Client recv error: {}\n", .{e});
                break;
            };
            if (n == 0) {
                std.debug.print("[tunnel] Client disconnected\n", .{});
                break;
            }

            logEvent("[recv] {} bytes from client (fd={})\n", .{ n, client_fd });

            var rewritten_buf: [MAX_WAYLAND_MESSAGE]u8 = undefined;
            const rewritten_len = rewriteClientBuffer(
                client_buf[0..n],
                &rewritten_buf,
                fds_buf[0..fd_count],
                &tracker,
                &registry,
                &input_state.keyboard_id,
                &input_state.pointer_id,
            );

            if (rewritten_len == 0) continue;

            if (fd_count > 0) {
                socket_mod.sendWithFds(compositor_fd, rewritten_buf[0..rewritten_len], fds_buf[0..fd_count]) catch |e| {
                    std.debug.print("[tunnel] Compositor send error (with fds): {} client_fd={} compositor_fd={}\n", .{e, client_fd, compositor_fd});
                    break;
                };
            } else {
                if (!stream_mod.writeExact(compositor_fd, rewritten_buf[0..rewritten_len])) {
                    std.debug.print("[tunnel] Compositor write failed (no fds)\n", .{});
                    break;
                }
            }

            // Send wl_keyboard.keymap immediately after kb_id is first captured.
            // This must happen after we've forwarded the rewritten buffer to cage so
            // the client's get_keyboard has been "acknowledged" (as a dummy region).
            if (input_state.keyboard_id != 0 and !input_state.keymap_sent) {
                if (input.sendKeymap(client_fd, input_state.keyboard_id)) {
                    input_state.keymap_sent = true;
                }
            }

            // Inject deferred wl_seat.capabilities(3) on first commit.
            // tracker.has_pending_commit is set by processSingleMessageForTracking when
            // wl_surface.commit is seen; check it before getLatestFrame() consumes it.
            if (!caps_injected and deferred_caps_seat_id != 0 and tracker.has_pending_commit) {
                var caps_msg: [12]u8 = undefined;
                std.mem.writeInt(u32, caps_msg[0..4], deferred_caps_seat_id, .little);
                std.mem.writeInt(u32, caps_msg[4..8], (@as(u32, 12) << 16) | 0, .little);
                std.mem.writeInt(u32, caps_msg[8..12], 3, .little);
                if (stream_mod.writeExact(client_fd, &caps_msg)) {
                    caps_injected = true;
                    logEvent("[relay] Injected wl_seat.capabilities(3) for seat_id={} after first commit\n", .{deferred_caps_seat_id});
                } else {
                    std.debug.print("[relay] Failed to send deferred caps=3 to client\n", .{});
                }
            }

            // START_FRAME_CAPTURE
            const maybe_frame = tracker.getLatestFrame();
            if (maybe_frame) |frame| {
                // Track the rendering surface so enter events have a valid surface ID.
                input_state.focused_surface_id = frame.surface_id;

                const buf_id = tracker.getAttachedBuffer(frame.surface_id) orelse {
                    std.debug.print("[tunnel] No attached buffer for surface {}\n", .{frame.surface_id});
                    continue;
                };

                var pool_id: u32 = 0;
                var buf_offset: u32 = 0;
                var found = false;
                for (tracker.buffers[0..tracker.buffer_hwm]) |buf| {
                    if (buf.buffer_id == buf_id and buf.active) {
                        pool_id = buf.pool_id;
                        buf_offset = buf.offset;
                        found = true;
                        break;
                    }
                }

                if (!found) {
                    std.debug.print("[tunnel] Buffer {} not found in tracker\n", .{buf_id});
                    stream_mod.sendStreamError(0x0001, "pool_not_found");
                    continue;
                }

                const pixels_mmap = frame.pixels;
                std.debug.print("[tunnel] Got frame: surface_id={} pool_id={} {}x{} stride={} sending {} bytes ptr=0x{x}\n", .{
                    frame.surface_id, pool_id, frame.width, frame.height, frame.stride, pixels_mmap.len,
                    @intFromPtr(pixels_mmap.ptr)});

                if (pixels_mmap.len > buffers.pixel_buf.len - 64) {
                    std.debug.print("[tunnel] Frame too large for safe_buf ({} > {}), skipping\n",
                        .{pixels_mmap.len, buffers.pixel_buf.len - 64});
                    continue;
                }
                @memcpy(buffers.pixel_buf[0..pixels_mmap.len], pixels_mmap);
                @memset(buffers.pixel_buf[pixels_mmap.len..pixels_mmap.len + 64], 0);
                const pixels_to_send = buffers.pixel_buf[0..pixels_mmap.len];

                const current_hash = fnv1aHash(pixels_to_send);

                // START_HASH_DEDUP
                // Pool reset gen check moved to the late-join-resend block above.

                var need_pool_data = true;
                for (&pool_hashes) |*ph| {
                    if (ph.pool_id == pool_id and ph.hash == current_hash and ph.sent) {
                        need_pool_data = false;
                        break;
                    }
                }

                if (need_pool_data) {
                    stream_mod.sendPoolData(
                        buffers.lz4_buf,
                        pool_id,
                        frame.width,
                        frame.height,
                        @intCast(frame.stride),
                        frame.format,
                        pixels_to_send,
                    );
                    for (&pool_hashes) |*ph| {
                        if (ph.pool_id == 0 or ph.pool_id == pool_id) {
                            ph.pool_id = pool_id;
                            ph.hash = current_hash;
                            ph.sent = true;
                            break;
                        }
                    }
                } else {}
                // END_HASH_DEDUP

                const dmg_x: u16 = if (frame.damage_w > 0) @intCast(@min(@max(0, frame.damage_x), 0xFFFF)) else 0;
                const dmg_y: u16 = if (frame.damage_w > 0) @intCast(@min(@max(0, frame.damage_y), 0xFFFF)) else 0;
                const frame_width_u16: u16 = @intCast(@min(frame.width, 65535));
                const frame_height_u16: u16 = @intCast(@min(frame.height, 65535));
                const dmg_w: u16 = if (frame.damage_w > 0) @intCast(@min(@max(0, frame.damage_w), 65535)) else frame_width_u16;
                const dmg_h: u16 = if (frame.damage_w > 0) @intCast(@min(@max(0, frame.damage_h), 65535)) else frame_height_u16;

                stream_mod.sendSurfaceCommit(
                    frame.surface_id,
                    pool_id,
                    buf_offset,
                    frame.width,
                    frame.height,
                    @intCast(frame.stride),
                    frame.format,
                    dmg_x,
                    dmg_y,
                    dmg_w,
                    dmg_h,
                );

                // START_CACHE_LAST_FRAME
                //   purpose: store frame metadata for late-join resend
                //   consumedBy: the late-join-resend block in the poll loop
                last_frame_info = .{
                    .surface_id = frame.surface_id,
                    .pool_id = pool_id,
                    .buf_offset = buf_offset,
                    .width = frame.width,
                    .height = frame.height,
                    .stride = @intCast(frame.stride),
                    .format = frame.format,
                    .pixel_len = pixels_mmap.len,
                };
                // END_CACHE_LAST_FRAME
            }
            // END_FRAME_CAPTURE
        }
        // END_RELAY_CLIENT_MSG

        // START_RELAY_COMPOSITOR_MSG
        if (fds[1].revents & c.POLLIN != 0) {
            var comp_fds_buf: [socket_mod.MAX_FDS_PER_MSG]c_int = [_]c_int{-1} ** socket_mod.MAX_FDS_PER_MSG;
            var comp_fd_count: usize = 0;

            const n = socket_mod.recvWithFds(compositor_fd, &compositor_buf, &comp_fds_buf, &comp_fd_count) catch |e| {
                std.debug.print("[tunnel] Compositor recv error: {}\n", .{e});
                break;
            };
            if (n == 0) {
                std.debug.print("[tunnel] Compositor closed connection\n", .{});
                break;
            }

            protocol.processCompositorResponse(compositor_buf[0..n], &registry, &deferred_caps_seat_id);

            var comp_offset: usize = 0;
            while (comp_offset + 8 <= n) {
                const comp_obj = std.mem.readInt(u32, compositor_buf[comp_offset..][0..4], .little);
                const comp_size_op = std.mem.readInt(u32, compositor_buf[comp_offset + 4..][0..4], .little);
                const comp_op: u16 = @truncate(comp_size_op);
                const comp_size: usize = @as(usize, @as(u16, @truncate(comp_size_op >> 16)));

                const pointer_interface = registry.getInterface(comp_obj);
                if (pointer_interface == .wl_pointer and comp_op == 2 and comp_size >= 24) {
                    if (comp_offset + 24 <= n) {
                        const fx = std.mem.readInt(i32, compositor_buf[comp_offset + 16..][0..4], .little);
                        const fy = std.mem.readInt(i32, compositor_buf[comp_offset + 20..][0..4], .little);
                        const x: i32 = @divTrunc(fx, 256);
                        const y: i32 = @divTrunc(fy, 256);
                        stream_mod.sendCursorMove(x, y);
                    }
                }

                if (comp_size < 8) break;
                comp_offset += comp_size;
            }

            if (comp_fd_count > 0) {
                socket_mod.sendWithFds(client_fd, compositor_buf[0..n], comp_fds_buf[0..comp_fd_count]) catch |e| {
                    std.debug.print("[tunnel] Client FD send error: {}\n", .{e});
                    break;
                };
                for (comp_fds_buf[0..comp_fd_count]) |fd| {
                    if (fd >= 0) _ = c.close(fd);
                }
            } else {
                if (!stream_mod.writeExact(client_fd, compositor_buf[0..n])) {
                    std.debug.print("[tunnel] Client write failed\n", .{});
                    break;
                }
            }
        }
        // END_RELAY_COMPOSITOR_MSG
    }
    // END_RELAY_POLL_LOOP
}
// handleWaylandClientWithRelay:end
