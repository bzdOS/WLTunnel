// START_AI_HEADER
// MODULE: wayland-tunnel/src/socket.zig
// PURPOSE: Low-level Unix socket primitives for Wayland proxy and stream server
// INTENT: Isolate all socket/fd syscalls so relay.zig and main.zig stay protocol-level
// DEPENDENCIES: c.zig (libc: socket, bind, listen, connect, recvmsg, sendmsg)
// PUBLIC_API:
//   createStreamSocket(path) — SOCK_STREAM server socket for bsdos-core
//   createWaylandSocket(path) — SOCK_STREAM server socket for Wayland clients
//   connectToCompositor(path) — connect to cage's wayland-0 socket
//   recvWithFds(fd, buf, fds_buf, fd_count) — recvmsg with SCM_RIGHTS fd extraction
//   sendWithFds(fd, buf, fds) — sendmsg with SCM_RIGHTS fd passing
// END_AI_HEADER

pub const std = @import("std");
pub const c = @import("c").c;

// MAX_FDS_PER_MSG: max SCM_RIGHTS fds per recvmsg call (Wayland pools pass 1 fd per message)
pub const MAX_FDS_PER_MSG = 8;

// aarch64 correctness: derive the cmsg control-buffer size from @sizeOf(c.cmsghdr)
// and @sizeOf(c_long) instead of a hardcoded 16. FreeBSD's CMSG_SPACE rounds BOTH
// the header and the data area up to sizeof(long); the literal 16 only happened to
// match because struct cmsghdr (12B) aligns to 16 on LP64 and 8 fds is already
// 8-aligned. Computing it mirrors input.zig's CMSG_* constants and stays correct
// for any MAX_FDS_PER_MSG on both amd64 and aarch64 FreeBSD.
const CMSG_ALIGN_SZ: usize = @sizeOf(c_long);
fn cmsgAlign(n: usize) usize {
    return (n + CMSG_ALIGN_SZ - 1) & ~(CMSG_ALIGN_SZ - 1);
}
pub const CMSG_SPACE_FDS = cmsgAlign(@sizeOf(c.cmsghdr)) + cmsgAlign(MAX_FDS_PER_MSG * @sizeOf(c_int));

// chmodSocket:start
//   purpose: set filesystem permissions on a Unix domain socket file
//   input: path (socket filesystem path), mode (octal permissions like 0o777)
//   output: void (returns silently on error)
//   sideEffects: calls chmod syscall on socket file at path
pub fn chmodSocket(path: []const u8, mode: c_ushort) void {
    var buf: [256:0]u8 = undefined;
    if (path.len >= buf.len) return;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    _ = c.chmod(&buf, mode);
}
// chmodSocket:end

// createStreamSocket:start
//   purpose: create and bind a listening Unix domain socket for bsdos-core to connect to
//   input: socket_path (filesystem path where socket will be created)
//   output: file descriptor (i32) on success, error set on failure
//   sideEffects: deletes existing socket file, creates and binds Unix socket at path, calls listen(backlog=4), sets socket buffer sizes to 16MB, changes file permissions to 0o777
pub fn createStreamSocket(socket_path: []const u8) !i32 {
    std.fs.deleteFileAbsolute(socket_path) catch |err| {
        if (err != error.FileNotFound) return err;
    };

    const server_fd = c.socket(c.AF_UNIX, c.SOCK_STREAM, 0);
    if (server_fd < 0) return error.SocketCreationFailed;
    errdefer _ = c.close(server_fd);

    var addr: c.sockaddr_un = undefined;
    addr.sun_family = c.AF_UNIX;
    if (socket_path.len >= addr.sun_path.len) return error.PathTooLong;
    _ = c.memset(&addr.sun_path, 0, addr.sun_path.len);
    @memcpy(addr.sun_path[0..socket_path.len], socket_path);

    if (c.bind(server_fd, @ptrCast(&addr), @sizeOf(c.sockaddr_un)) < 0) return error.BindFailed;
    if (c.listen(server_fd, 4) < 0) return error.ListenFailed;

    chmodSocket(socket_path, 0o777);

    var sndbuf_size: c_int = 16 * 1024 * 1024;
    var rcvbuf_size: c_int = 16 * 1024 * 1024;
    _ = c.setsockopt(server_fd, c.SOL_SOCKET, c.SO_SNDBUF, @ptrCast(&sndbuf_size), @sizeOf(c_int));
    _ = c.setsockopt(server_fd, c.SOL_SOCKET, c.SO_RCVBUF, @ptrCast(&rcvbuf_size), @sizeOf(c_int));

    return server_fd;
}
// createStreamSocket:end

// createWaylandSocket:start
//   purpose: create and bind a listening Unix domain socket for Wayland clients to connect to
//   input: socket_path (filesystem path where socket will be created)
//   output: file descriptor (i32) on success, error set on failure
//   sideEffects: deletes existing socket file, creates and binds Unix socket at path, calls listen(backlog=128), changes file permissions to 0o777
pub fn createWaylandSocket(socket_path: []const u8) !i32 {
    std.fs.deleteFileAbsolute(socket_path) catch |err| {
        if (err != error.FileNotFound) return err;
    };

    const server_fd = c.socket(c.AF_UNIX, c.SOCK_STREAM, 0);
    if (server_fd < 0) return error.SocketCreationFailed;
    errdefer _ = c.close(server_fd);

    var addr: c.sockaddr_un = undefined;
    addr.sun_family = c.AF_UNIX;
    if (socket_path.len >= addr.sun_path.len) return error.PathTooLong;
    _ = c.memset(&addr.sun_path, 0, addr.sun_path.len);
    @memcpy(addr.sun_path[0..socket_path.len], socket_path);

    if (c.bind(server_fd, @ptrCast(&addr), @sizeOf(c.sockaddr_un)) < 0) return error.BindFailed;
    if (c.listen(server_fd, 128) < 0) return error.ListenFailed;

    chmodSocket(socket_path, 0o777);
    return server_fd;
}
// createWaylandSocket:end

// connectToCompositor:start
//   purpose: establish client connection to Wayland compositor (cage's wayland-0 socket)
//   input: compositor_path (filesystem path to Wayland compositor socket)
//   output: connected file descriptor (c_int) on success, error set on failure
//   sideEffects: creates Unix socket, calls connect syscall, logs debug message on failure
pub fn connectToCompositor(compositor_path: []const u8) !c_int {
    const fd = c.socket(c.AF_UNIX, c.SOCK_STREAM, 0);
    if (fd < 0) return error.SocketCreationFailed;
    errdefer _ = c.close(fd);

    var addr: c.sockaddr_un = undefined;
    addr.sun_family = c.AF_UNIX;
    if (compositor_path.len >= addr.sun_path.len) return error.PathTooLong;
    _ = c.memset(&addr.sun_path, 0, addr.sun_path.len);
    @memcpy(addr.sun_path[0..compositor_path.len], compositor_path);

    const rc = c.connect(fd, @ptrCast(&addr), @sizeOf(c.sockaddr_un));
    if (rc < 0) {
        const sys_errno = std.posix.errno(rc);
        std.debug.print("[tunnel] connect({s}) failed errno={}\n", .{ compositor_path, @intFromEnum(sys_errno) });
        return error.ConnectFailed;
    }
    return fd;
}
// connectToCompositor:end

// recvWithFds:start
//   purpose: receive message from socket and extract passed file descriptors via SCM_RIGHTS
//   input: fd (socket to receive from), buf (buffer for message data), received_fds (array to store received fds), fd_count (pointer to store count of received fds)
//   output: number of bytes received (usize), error set on failure or if connection closed
//   sideEffects: calls recvmsg syscall, populates received_fds array and fd_count with extracted file descriptors, retries on EINTR
pub fn recvWithFds(
    fd: c_int,
    buf: []u8,
    received_fds: *[MAX_FDS_PER_MSG]c_int,
    fd_count: *usize,
) !usize {
    fd_count.* = 0;
    for (received_fds) |*f| f.* = -1;

    var iov: c.iovec = .{ .iov_base = buf.ptr, .iov_len = buf.len };
    var cmsg_buf: [CMSG_SPACE_FDS]u8 = undefined;
    var msg: c.msghdr = .{
        .msg_name = null,
        .msg_namelen = 0,
        .msg_iov = &iov,
        .msg_iovlen = 1,
        .msg_control = &cmsg_buf,
        .msg_controllen = CMSG_SPACE_FDS,
        .msg_flags = 0,
    };

    const n = while (true) {
        const r = c.recvmsg(fd, &msg, 0);
        if (r < 0) {
            const err = std.posix.errno(r);
            if (err == .INTR) continue;
            return error.RecvFailed;
        }
        break r;
    };
    if (n == 0) return error.ConnectionClosed;

    var cmsg: ?*c.cmsghdr = c.CMSG_FIRSTHDR(&msg);
    while (cmsg != null) : (cmsg = c.CMSG_NXTHDR(&msg, cmsg)) {
        const cmsg_ptr = cmsg.?;
        if (cmsg_ptr.cmsg_level == c.SOL_SOCKET and cmsg_ptr.cmsg_type == c.SCM_RIGHTS) {
            const cmsg_len = cmsg_ptr.cmsg_len;
            const cmsg_data_offset: usize = std.mem.alignForward(usize, @sizeOf(c.cmsghdr), @sizeOf(c_long));
            if (cmsg_len > cmsg_data_offset) {
                const payload_len = cmsg_len - cmsg_data_offset;
                const n_fds = payload_len / @sizeOf(c_int);
                const data_ptr = @as([*]u8, @ptrCast(cmsg_ptr)) + cmsg_data_offset;
                const fds = @as([*]c_int, @ptrCast(@alignCast(data_ptr)));
                var i: usize = 0;
                while (i < n_fds and fd_count.* < MAX_FDS_PER_MSG) : (i += 1) {
                    received_fds[fd_count.*] = fds[i];
                    fd_count.* += 1;
                }
            }
        }
    }

    return @intCast(n);
}
// recvWithFds:end

// sendWithFds:start
//   purpose: send message with file descriptors via SCM_RIGHTS ancillary data
//   input: fd (socket to send to), data (message bytes to send), fds (file descriptors to pass)
//   output: void on success, error set on failure
//   sideEffects: calls sendmsg syscall, passes ownership of file descriptors to receiving process
pub fn sendWithFds(fd: c_int, data: []const u8, fds: []c_int) !void {
    const stream = @import("stream");

    if (fds.len == 0) {
        if (!stream.writeExact(fd, data)) return error.WriteFailed;
        return;
    }

    var iov: c.iovec = .{
        .iov_base = @constCast(data.ptr),
        .iov_len = data.len,
    };

    var cmsg_buf: [CMSG_SPACE_FDS]u8 = undefined;
    @memset(cmsg_buf[0..], 0);

    var msg: c.msghdr = .{
        .msg_name = null,
        .msg_namelen = 0,
        .msg_iov = &iov,
        .msg_iovlen = 1,
        .msg_control = &cmsg_buf,
        .msg_controllen = CMSG_SPACE_FDS,
        .msg_flags = 0,
    };

    const cmsg: ?*c.cmsghdr = c.CMSG_FIRSTHDR(&msg);
    if (cmsg == null) return error.CmsgSetupFailed;

    const cmsg_val = cmsg.?;
    cmsg_val.cmsg_level = c.SOL_SOCKET;
    cmsg_val.cmsg_type = c.SCM_RIGHTS;
    const cmsg_data_offset: usize = std.mem.alignForward(usize, @sizeOf(c.cmsghdr), @sizeOf(c_long));
    const fd_payload_size = fds.len * @sizeOf(c_int);
    cmsg_val.cmsg_len = @as(c.socklen_t, @intCast(cmsg_data_offset + fd_payload_size));

    const cmsg_data_ptr = @as([*]u8, @ptrCast(cmsg_val)) + cmsg_data_offset;
    const fds_ptr = @as([*]c_int, @ptrCast(@alignCast(cmsg_data_ptr)));
    for (fds, 0..) |fd_val, i| {
        fds_ptr[i] = fd_val;
    }

    msg.msg_controllen = cmsg_val.cmsg_len;

    const n = c.sendmsg(fd, &msg, 0);
    if (n < 0) {
        const send_errno = std.posix.errno(n);
        std.debug.print("[sendWithFds] sendmsg(fd={}) failed errno={} ({})\n", .{ fd, @intFromEnum(send_errno), send_errno });
        return error.SendmsgFailed;
    }
    if (n != data.len) return error.PartialSend;
}
// sendWithFds:end
