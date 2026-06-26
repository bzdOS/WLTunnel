// START_AI_HEADER
// MODULE: wayland-tunnel/src/main.zig
// PURPOSE: Main relay entry point: accept Wayland (Firefox/cage) and stream (bsdos-core) clients, spawn relay threads per client
// INTENT: Central orchestration point for wayland-tunnel architecture — bridges desktop compositors to remote agents via stream protocol
// DEPENDENCIES: stream.zig (MAX_STREAM_CLIENTS, pool_reset_generation, stream_clients), socket.zig (createWaylandSocket, createStreamSocket), relay.zig (RelayThreadArgs, relayThreadFn), c.zig (C bindings)
// PUBLIC_API:
//   main() → entry point: initializes sockets, runs main poll loop forever, spawns relay threads on each Wayland accept, tracks stream client disconnects
// START_INVARIANTS
//   - ЕДИНСТВЕННАЯ точка accept() для Wayland-клиентов (relay threads не трогают server_fd)
//   - pool_reset_generation инкрементируется ТОЛЬКО здесь при добавлении stream-клиента (synchronizes pool view for relays)
//   - stream_clients[] и pool_reset_generation защищены stream_mod.lockClients/unlockClients
//   - stream-клиенты отслеживаются через poll, disconnect обнаруживается recv(...MSG_PEEK) == 0 или EAGAIN после POLLIN|POLLHUP
//   - input_listen_fd создаётся ОДИН РАЗ здесь при старте; relay threads получают его через args, не владеют им, не закрывают
// END_INVARIANTS
// END_AI_HEADER

const std = @import("std");
const c = @import("c").c;
const stream_mod = @import("stream");
const socket_mod = @import("socket");
const relay = @import("relay");

const INPUT_SOCK_DEFAULT = "/tmp/wayland-run/input.sock";

const WAYLAND_SOCK = "/tmp/wayland-run/wayland-ghost-0";
const STREAM_SOCK = "/tmp/wayland-run/wayland-stream.sock";
const REAL_COMPOSITOR = "/tmp/wayland-run/wayland-0";

// main:start
//   purpose: initialize tunnel sockets, run infinite poll loop, accept Wayland clients and relay-spawn, track stream client health
//   input: environment variables WLSTREAM_WAYLAND_SOCK, WLSTREAM_STREAM_SOCK, WLSTREAM_COMPOSITOR_SOCK, WLSTREAM_INPUT_SOCK (default to constants)
//   output: never returns (infinite loop until fatal error)
//   sideEffects: creates two server sockets (UNIX), spawns relay threads per Wayland accept, closes stream client fds on disconnect, ignores SIGPIPE
pub fn main() !void {
    // START_SIGPIPE_IGNORE
    {
        var sa = std.mem.zeroes(std.posix.Sigaction);
        sa.handler = .{ .handler = @ptrFromInt(1) };
        std.posix.sigaction(std.posix.SIG.PIPE, &sa, null);
    }
    // END_SIGPIPE_IGNORE

    // START_SOCKET_PATH_INIT
    var wayland_sock_buf: [128]u8 = undefined;
    var stream_sock_buf: [128]u8 = undefined;
    var compositor_buf: [128]u8 = undefined;

    const wayland_sock: []const u8 = if (std.posix.getenv("WLSTREAM_WAYLAND_SOCK")) |s| blk: {
        @memcpy(wayland_sock_buf[0..s.len], s);
        break :blk wayland_sock_buf[0..s.len];
    } else WAYLAND_SOCK;

    const stream_sock: []const u8 = if (std.posix.getenv("WLSTREAM_STREAM_SOCK")) |s| blk: {
        @memcpy(stream_sock_buf[0..s.len], s);
        break :blk stream_sock_buf[0..s.len];
    } else STREAM_SOCK;

    const compositor_sock: []const u8 = if (std.posix.getenv("WLSTREAM_COMPOSITOR_SOCK")) |s| blk: {
        @memcpy(compositor_buf[0..s.len], s);
        break :blk compositor_buf[0..s.len];
    } else REAL_COMPOSITOR;
    // END_SOCKET_PATH_INIT

    // START_ALLOCATOR_INIT
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    // END_ALLOCATOR_INIT

    // START_WAYLAND_SOCKET_CREATE
    const server_fd = socket_mod.createWaylandSocket(wayland_sock) catch |err| {
        std.debug.print("ERROR: Failed to create Wayland socket: {}\n", .{err});
        return err;
    };
    defer _ = c.close(server_fd);

    std.debug.print("DEBUG: Listening on {s}\n", .{wayland_sock});
    // END_WAYLAND_SOCKET_CREATE

    // START_STREAM_SOCKET_CREATE
    const stream_server_fd = socket_mod.createStreamSocket(stream_sock) catch |err| {
        std.debug.print("ERROR: Failed to create stream socket: {}\n", .{err});
        return err;
    };
    defer _ = c.close(stream_server_fd);

    std.debug.print("[tunnel] Listening: Wayland={s}  Stream={s}\n", .{ wayland_sock, stream_sock });
    std.debug.print("[tunnel] Compositor: {s}\n", .{compositor_sock});
    // END_STREAM_SOCKET_CREATE

    // START_INPUT_SOCK_CREATE
    // Create input.sock once at startup so stream_input_handler can connect at any time,
    // not just while a Wayland client (Chrome) is connected to the relay.
    var input_sock_buf: [128]u8 = undefined;
    const input_sock: []const u8 = if (std.posix.getenv("WLSTREAM_INPUT_SOCK")) |s| blk: {
        @memcpy(input_sock_buf[0..s.len], s);
        break :blk input_sock_buf[0..s.len];
    } else INPUT_SOCK_DEFAULT;
    const input_listen_fd: c_int = relay.bindListenInputSock(input_sock);
    defer { if (input_listen_fd >= 0) _ = c.close(input_listen_fd); }
    if (input_listen_fd >= 0) {
        std.debug.print("[tunnel] Input sock listening: {s}\n", .{input_sock});
    } else {
        std.debug.print("[tunnel] WARNING: failed to bind input sock {s}\n", .{input_sock});
    }
    // END_INPUT_SOCK_CREATE

    // START_SOCKET_NONBLOCK
    {
        const flags = c.fcntl(server_fd, c.F_GETFL, @as(c_int, 0));
        _ = c.fcntl(server_fd, c.F_SETFL, flags | c.O_NONBLOCK);
    }
    {
        const flags = c.fcntl(stream_server_fd, c.F_GETFL, @as(c_int, 0));
        _ = c.fcntl(stream_server_fd, c.F_SETFL, flags | c.O_NONBLOCK);
    }
    // END_SOCKET_NONBLOCK

    // START_POLLFD_INIT
    var main_poll: [2 + stream_mod.MAX_STREAM_CLIENTS]c.pollfd = undefined;
    main_poll[0] = .{ .fd = server_fd,        .events = c.POLLIN, .revents = 0 };
    main_poll[1] = .{ .fd = stream_server_fd, .events = c.POLLIN, .revents = 0 };
    for (0..stream_mod.MAX_STREAM_CLIENTS) |i| {
        main_poll[2 + i] = .{ .fd = -1, .events = c.POLLIN | c.POLLHUP, .revents = 0 };
    }
    // END_POLLFD_INIT

    // START_MAIN_LOOP
    while (true) {
        // START_STREAM_CLIENT_POLL_UPDATE
        {
            stream_mod.lockClients();
            defer stream_mod.unlockClients();
            for (stream_mod.stream_clients, 0..) |fd, i| {
                main_poll[2 + i].fd = fd;
            }
        }
        // END_STREAM_CLIENT_POLL_UPDATE

        _ = c.poll(&main_poll, 2 + stream_mod.MAX_STREAM_CLIENTS, -1);

        // START_STREAM_CLIENT_DISCONNECT
        {
            stream_mod.lockClients();
            defer stream_mod.unlockClients();
            for (&stream_mod.stream_clients, 0..) |*slot, i| {
                const pfd = main_poll[2 + i];
                if (pfd.fd < 0) continue;
                if (pfd.revents & (c.POLLIN | c.POLLHUP | c.POLLERR) != 0) {
                    var buf: [1]u8 = undefined;
                    const n = c.recv(pfd.fd, &buf, 1, c.MSG_PEEK | c.MSG_DONTWAIT);
                    const recv_errno = std.posix.errno(n);
                    if (n == 0 or (n < 0 and recv_errno != .AGAIN)) {
                        std.debug.print("[tunnel] Stream client slot {d} (fd={}) disconnected, freeing\n", .{ i, pfd.fd });
                        _ = c.close(pfd.fd);
                        slot.* = -1;
                        main_poll[2 + i].fd = -1;
                    }
                }
            }
        }
        // END_STREAM_CLIENT_DISCONNECT

        // START_WAYLAND_ACCEPT
        if (main_poll[0].revents & c.POLLIN != 0) {
            const new_client_fd = c.accept(server_fd, null, null);
            if (new_client_fd >= 0) {
                std.debug.print("[tunnel] Client accepted (fd={}), spawning relay thread\n", .{new_client_fd});

                const args = allocator.create(relay.RelayThreadArgs) catch |e| {
                    std.debug.print("[tunnel] Failed to allocate RelayThreadArgs: {}\n", .{e});
                    _ = c.close(new_client_fd);
                    continue;
                };

                args.* = .{
                    .client_fd = new_client_fd,
                    .compositor_path = undefined,
                    .compositor_path_len = compositor_sock.len,
                    .input_listen_fd = input_listen_fd,
                    .allocator = allocator,
                };
                @memcpy(args.compositor_path[0..compositor_sock.len], compositor_sock);

                const thread = std.Thread.spawn(.{}, relay.relayThreadFn, .{args}) catch |e| {
                    std.debug.print("[tunnel] Failed to spawn relay thread: {}\n", .{e});
                    _ = c.close(new_client_fd);
                    allocator.destroy(args);
                    continue;
                };
                thread.detach();
            }
        }
        // END_WAYLAND_ACCEPT

        // START_STREAM_ACCEPT
        if (main_poll[1].revents & c.POLLIN != 0) {
            var raw_fd = c.accept(stream_server_fd, null, null);
            if (raw_fd >= 0 and raw_fd <= 2) {
                const safe = c.fcntl(raw_fd, c.F_DUPFD, @as(c_int, 3));
                _ = c.close(raw_fd);
                raw_fd = safe;
            }
            if (raw_fd >= 0) {
                stream_mod.configureStreamFd(raw_fd);
                stream_mod.lockClients();
                defer stream_mod.unlockClients();
                var placed = false;
                for (&stream_mod.stream_clients, 0..) |*slot, i| {
                    if (slot.* < 0) {
                        slot.* = raw_fd;
                        const gen = stream_mod.pool_reset_generation.load(.acquire) + 1;
                        stream_mod.pool_reset_generation.store(gen, .release);
                        std.debug.print("[tunnel] Stream client connected (fd={}) at slot {d}, pool_reset_gen={}\n", .{ raw_fd, i, gen });
                        placed = true;
                        break;
                    }
                }
                if (!placed) {
                    std.debug.print("[tunnel] Stream client limit reached, dropping fd={}\n", .{raw_fd});
                    _ = c.close(raw_fd);
                }
            } else {
                std.debug.print("[tunnel] Stream accept returned {} (EAGAIN expected if relay thread raced)\n", .{raw_fd});
            }
        }
        // END_STREAM_ACCEPT
    }
    // END_MAIN_LOOP
}
// main:end
