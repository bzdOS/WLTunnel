// START_AI_HEADER
// MODULE: wayland-tunnel/src/test-client.zig
// PURPOSE: Wayland test client that connects to wayland-ghost-0, creates a surface with SHM pool, and commits a cyan frame.
// INTENT: Integration test to verify the tunnel captures and forwards SHM buffer content correctly.
// DEPENDENCIES: std, @cImport(sys/socket.h, sys/un.h, sys/mman.h, fcntl.h, unistd.h, string.h, stdlib.h, time.h).
// PUBLIC_API: main.
// END_AI_HEADER

// Simple Wayland test client that connects to wayland-ghost-0
// Creates a surface, allocates shared memory, and commits pixel data

const std = @import("std");
const c = @cImport({
    @cInclude("sys/socket.h");
    @cInclude("sys/un.h");
    @cInclude("sys/mman.h");
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
    @cInclude("string.h");
    @cInclude("stdlib.h");
    @cInclude("time.h");
});

const WAYLAND_SOCKET = "/var/run/wayland-ghost-0";
const WIDTH = 256;
const HEIGHT = 256;
const STRIDE = WIDTH * 4;
const PIXEL_SIZE = STRIDE * HEIGHT;

// Minimal Wayland object IDs (client-assigned)
const ID_DISPLAY = 1;
const ID_REGISTRY = 2;
const ID_COMPOSITOR = 3;
const ID_SHM = 4;
const ID_SURFACE = 5;
const ID_SHM_POOL = 6;
const ID_BUFFER = 7;

// Helper: write u32 little-endian
// writeU32LE:start
//   purpose: Write a u32 value as little-endian 4 bytes at an offset in a buffer.
//   input:  buf: destination byte slice, offset: start position, val: u32 value to encode.
//   output: none (writes in-place).
//   sideEffects: None (pure mutation of buf at [offset..offset+4]).
fn writeU32LE(buf: []u8, offset: usize, val: u32) void {
    buf[offset] = @intCast(val & 0xFF);
    buf[offset + 1] = @intCast((val >> 8) & 0xFF);
    buf[offset + 2] = @intCast((val >> 16) & 0xFF);
    buf[offset + 3] = @intCast((val >> 24) & 0xFF);
}
// writeU32LE:end

// Helper: write u16 little-endian
// writeU16LE:start
//   purpose: Write a u16 value as little-endian 2 bytes at an offset in a buffer.
//   input:  buf: destination byte slice, offset: start position, val: u16 value to encode.
//   output: none (writes in-place).
//   sideEffects: None (pure mutation of buf at [offset..offset+2]).
fn writeU16LE(buf: []u8, offset: usize, val: u16) void {
    buf[offset] = @intCast(val & 0xFF);
    buf[offset + 1] = @intCast((val >> 8) & 0xFF);
}
// writeU16LE:end

// Helper: write string (4-byte aligned length prefix + data + null terminator)
// writeString:start
//   purpose: Write a Wayland string (4-byte little-endian length prefix + null-terminated data + 4-byte align padding).
//   input:  buf: destination byte slice, offset: start position, str: string content (null terminator appended automatically).
//   output: number of bytes written (4 + padded_len, where padded_len = ((str.len+1 + 3) / 4) * 4).
//   sideEffects: None (pure mutation of buf at [offset..]).
fn writeString(buf: []u8, offset: usize, str: []const u8) usize {
    const len = str.len + 1; // +1 for null terminator
    writeU32LE(buf, offset, @intCast(len));
    @memcpy(buf[offset + 4 .. offset + 4 + str.len], str);
    buf[offset + 4 + str.len] = 0;
    // Align to 4 bytes
    const padded_len = ((len + 3) / 4) * 4;
    return 4 + padded_len;
}
// writeString:end

// Send Wayland message: obj_id, op_code, and arguments
// Returns number of bytes sent
// sendMessage:start
//   purpose: Send a Wayland message (object ID + op code + args) over a Unix socket.
//   input:  fd: Unix socket fd, obj_id: Wayland object identifier, op_code: operation code,
//           args: serialized message arguments (4-byte aligned).
//   output: number of bytes sent, or error.WriteFailed on write error.
//   sideEffects: Writes to Wayland Unix socket via c.write(); prints debug to stderr.
fn sendMessage(
    fd: c_int,
    obj_id: u32,
    op_code: u16,
    args: []const u8,
) !usize {
    const total_words = (8 + args.len + 3) / 4;
    const total_bytes = total_words * 4;
    var msg: [1024]u8 = undefined;

    writeU32LE(&msg, 0, obj_id);
    writeU16LE(&msg, 4, op_code);
    writeU16LE(&msg, 6, @intCast(total_words));
    @memcpy(msg[8 .. 8 + args.len], args);

    const n = c.write(fd, &msg, total_bytes);
    if (n < 0) {
        return error.WriteFailed;
    }

    return @intCast(n);
}
// sendMessage:end

// Send Wayland message with file descriptor
// sendMessageWithFd:start
//   purpose: Send a Wayland message with a file descriptor via Unix ancillary data (SCM_RIGHTS).
//   input:  fd: Unix socket fd, obj_id/op_code/args: message fields, send_fd: file descriptor to transfer.
//   output: number of bytes sent, or error.SendmsgFailed on c.sendmsg() failure.
//   sideEffects: Writes to Wayland Unix socket via c.sendmsg() with SCM_RIGHTS ancillary data.
fn sendMessageWithFd(
    fd: c_int,
    obj_id: u32,
    op_code: u16,
    args: []const u8,
    send_fd: c_int,
) !usize {
    const total_words = (8 + args.len + 3) / 4;
    const total_bytes = total_words * 4;
    var msg: [1024]u8 = undefined;

    writeU32LE(&msg, 0, obj_id);
    writeU16LE(&msg, 4, op_code);
    writeU16LE(&msg, 6, @intCast(total_words));
    @memcpy(msg[8 .. 8 + args.len], args);

    // Setup iovec
    var iov: c.iovec = .{
        .iov_base = &msg,
        .iov_len = total_bytes,
    };

    // Setup ancillary data for file descriptor
    var cmsg_buf: [64]u8 = undefined;
    var cmsg: *c.cmsghdr = @alignCast(@ptrCast(&cmsg_buf));
    cmsg.cmsg_len = @intCast(c.CMSG_LEN(@sizeOf(c_int)));
    cmsg.cmsg_level = c.SOL_SOCKET;
    cmsg.cmsg_type = c.SCM_RIGHTS;
    const cmsg_data = @as([*]c_int, @alignCast(@ptrCast(c.CMSG_DATA(cmsg))));
    cmsg_data[0] = send_fd;

    // Setup msghdr
    var msg_hdr: c.msghdr = .{
        .msg_name = null,
        .msg_namelen = 0,
        .msg_iov = &iov,
        .msg_iovlen = 1,
        .msg_control = &cmsg_buf,
        .msg_controllen = @intCast(c.CMSG_SPACE(@sizeOf(c_int))),
        .msg_flags = 0,
    };

    const n = c.sendmsg(fd, &msg_hdr, 0);
    if (n < 0) {
        return error.SendmsgFailed;
    }

    return @intCast(n);
}
// sendMessageWithFd:end

// main:start
//   purpose: Connect to wayland-ghost-0, create SHM pool, create surface, commit cyan (ARGB=0xFF00FFFF) frame.
//   input:  none (Wayland socket path is hardcoded to /var/run/wayland-ghost-0).
//   output: void on success, error.* on any failure (socket/connect/mmap/sendmsg).
//   sideEffects: Connects to AF_UNIX socket; creates temp file (mkstemp) for SHM; mmaps file;
//                sends 7 Wayland messages (get_registry, bind compositor, bind shm, create_pool, create_buffer,
//                create_surface, attach, commit); sleeps 1 second; cleans up temp file and mmap.
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create socket and connect to wayland-ghost-0
    const sock = c.socket(c.AF_UNIX, c.SOCK_STREAM, 0);
    if (sock < 0) {
        std.debug.print("ERROR: socket() failed\n", .{});
        return error.SocketFailed;
    }
    defer _ = c.close(sock);

    var addr: c.sockaddr_un = undefined;
    addr.sun_family = c.AF_UNIX;
    @memset(&addr.sun_path, 0);
    const path = WAYLAND_SOCKET;
    @memcpy(addr.sun_path[0..path.len], path);

    if (c.connect(sock, @ptrCast(&addr), @sizeOf(c.sockaddr_un)) < 0) {
        std.debug.print("ERROR: connect() failed\n", .{});
        return error.ConnectFailed;
    }

    std.debug.print("Connected to {s}\n", .{WAYLAND_SOCKET});

    // Step 1: Get registry (op_code=1 on wl_display)
    // wl_display.get_registry(new_id:u32)
    var args: [4]u8 = undefined;
    writeU32LE(&args, 0, ID_REGISTRY);
    _ = try sendMessage(sock, ID_DISPLAY, 1, &args);
    std.debug.print("[client] get_registry new_id={}\n", .{ID_REGISTRY});

    // Step 2: Bind wl_compositor (op_code=0 on wl_registry)
    // wl_registry.bind(name:u32, interface:str, version:u32, new_id:u32)
    var bind_args: [256]u8 = undefined;
    writeU32LE(&bind_args, 0, 0); // name = 0 (compositor global)
    var offset = writeString(&bind_args, 4, "wl_compositor");
    writeU32LE(&bind_args, 4 + offset, 5); // version = 5
    writeU32LE(&bind_args, 4 + offset + 4, ID_COMPOSITOR);
    const bind_len = 4 + offset + 8;
    _ = try sendMessage(sock, ID_REGISTRY, 0, bind_args[0..bind_len]);
    std.debug.print("[client] bind wl_compositor new_id={}\n", .{ID_COMPOSITOR});

    // Step 3: Bind wl_shm (op_code=0 on wl_registry)
    var bind_shm_args: [256]u8 = undefined;
    writeU32LE(&bind_shm_args, 0, 1); // name = 1 (shm global)
    offset = writeString(&bind_shm_args, 4, "wl_shm");
    writeU32LE(&bind_shm_args, 4 + offset, 2); // version = 2
    writeU32LE(&bind_shm_args, 4 + offset + 4, ID_SHM);
    const bind_shm_len = 4 + offset + 8;
    _ = try sendMessage(sock, ID_REGISTRY, 0, bind_shm_args[0..bind_shm_len]);
    std.debug.print("[client] bind wl_shm new_id={}\n", .{ID_SHM});

    // Step 4: Create shared memory pool
    // Create a temporary file for shared memory
    const tmpfile = try allocator.dupeZ(u8, "/tmp/wayland-test-shm.XXXXXX");
    defer allocator.free(tmpfile);

    const shm_fd = c.mkstemp(@ptrCast(@constCast(tmpfile.ptr)));
    if (shm_fd < 0) {
        std.debug.print("ERROR: mkstemp() failed\n", .{});
        return error.MkstempFailed;
    }
    defer {
        _ = c.unlink(@ptrCast(tmpfile.ptr));
    }

    // Resize file to PIXEL_SIZE
    if (c.ftruncate(shm_fd, PIXEL_SIZE) < 0) {
        std.debug.print("ERROR: ftruncate() failed\n", .{});
        _ = c.close(shm_fd);
        return error.FtruncateFailed;
    }

    // mmap the file
    const shm_ptr = c.mmap(null, PIXEL_SIZE, c.PROT_READ | c.PROT_WRITE, c.MAP_SHARED, shm_fd, 0);
    if (shm_ptr == c.MAP_FAILED) {
        std.debug.print("ERROR: mmap() failed\n", .{});
        _ = c.close(shm_fd);
        return error.MmapFailed;
    }
    defer _ = c.munmap(shm_ptr, PIXEL_SIZE);

    // Fill with solid color (cyan: ARGB = 0xFF00FFFF)
    var shm_bytes = @as([*]u8, @ptrCast(shm_ptr))[0..PIXEL_SIZE];
    for (0..PIXEL_SIZE / 4) |i| {
        const offset_i = i * 4;
        shm_bytes[offset_i] = 0xFF; // A
        shm_bytes[offset_i + 1] = 0xFF; // R
        shm_bytes[offset_i + 2] = 0xFF; // G
        shm_bytes[offset_i + 3] = 0x00; // B
    }

    // wl_shm.create_pool(new_id:u32, size:u32) + fd
    var pool_args: [8]u8 = undefined;
    writeU32LE(&pool_args, 0, ID_SHM_POOL);
    writeU32LE(&pool_args, 4, PIXEL_SIZE);
    _ = try sendMessageWithFd(sock, ID_SHM, 0, &pool_args, shm_fd);
    std.debug.print("[client] create_pool new_id={} size={} fd={}\n", .{ ID_SHM_POOL, PIXEL_SIZE, shm_fd });

    // Step 5: Create buffer from pool
    // wl_shm_pool.create_buffer(new_id:u32, offset:u32, width:u32, height:u32, stride:u32, format:u32)
    var buf_args: [24]u8 = undefined;
    writeU32LE(&buf_args, 0, ID_BUFFER);
    writeU32LE(&buf_args, 4, 0); // offset
    writeU32LE(&buf_args, 8, WIDTH);
    writeU32LE(&buf_args, 12, HEIGHT);
    writeU32LE(&buf_args, 16, STRIDE);
    writeU32LE(&buf_args, 20, 1); // format = WL_SHM_FORMAT_ARGB8888
    _ = try sendMessage(sock, ID_SHM_POOL, 0, &buf_args);
    std.debug.print("[client] create_buffer new_id={} {}x{} stride={}\n", .{ ID_BUFFER, WIDTH, HEIGHT, STRIDE });

    // Step 6: Create surface
    // wl_compositor.create_surface(new_id:u32)
    var surf_args: [4]u8 = undefined;
    writeU32LE(&surf_args, 0, ID_SURFACE);
    _ = try sendMessage(sock, ID_COMPOSITOR, 0, &surf_args);
    std.debug.print("[client] create_surface new_id={}\n", .{ID_SURFACE});

    // Step 7: Attach buffer to surface
    // wl_surface.attach(buffer:u32, x:i32, y:i32)
    var attach_args: [12]u8 = undefined;
    writeU32LE(&attach_args, 0, ID_BUFFER);
    writeU32LE(&attach_args, 4, 0); // x = 0
    writeU32LE(&attach_args, 8, 0); // y = 0
    _ = try sendMessage(sock, ID_SURFACE, 1, &attach_args);
    std.debug.print("[client] attach buffer_id={}\n", .{ID_BUFFER});

    // Step 8: Commit surface
    // wl_surface.commit() - no arguments
    _ = try sendMessage(sock, ID_SURFACE, 6, &[_]u8{});
    std.debug.print("[client] commit surface_id={} - pixels should be captured!\n", .{ID_SURFACE});

    // Wait a bit for the tunnel to process
    var ts: c.timespec = .{ .tv_sec = 1, .tv_nsec = 0 };
    _ = c.nanosleep(&ts, null);

    std.debug.print("[client] Test complete. Check tunnel logs for frame_ready.\n", .{});
}
// main:end
