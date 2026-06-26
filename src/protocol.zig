// START_AI_HEADER
// MODULE: protocol.zig
// PURPOSE: Wayland message parsers for compositor→client and client→compositor directions; tracks shm pools, buffer attachments, surface damage, and seat ID capture for input injection.
// INTENT: keep parsing and registry updates in one place so relay.zig can stay a pure I/O loop. The deferred-caps rationale lives in the comment above processCompositorResponse; do not "simplify" it back to in-flight caps patching — it breaks ID allocation under foot.
// DEPENDENCIES: std (mem, debug), c.zig, wl_shm.WlShmTracker, wl_registry.WlRegistry.
// PUBLIC_API: processCompositorResponse(data, registry, deferred_seat_id) -> void; processClientMessage(data, fds, tracker, registry, kbd_id, ptr_id) -> void; processSingleMessage(data, fds, tracker, registry, fd_idx, kbd_id, ptr_id) -> void.
// END_AI_HEADER

pub const std = @import("std");
pub const c = @import("c").c;
const wl_shm = @import("wl_shm");
const wl_registry = @import("wl_registry");

// logEvent:start
//   purpose: thin wrapper around std.debug.print that flushes stdout immediately so logs are visible in real time under QEMU.
//   input:  comptime fmt + anytype args (matches std.debug.print signature).
//   output: void.
//   sideEffects: writes to stdout, calls fflush(NULL) on the C side.
fn logEvent(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt, args);
    _ = c.fflush(null);
}
// logEvent:end

// Record the first wl_seat that reports caps=0 for deferred caps injection.
// We do NOT patch caps in-flight anymore — injecting caps=3 immediately while foot
// is still binding globals causes ID conflicts: foot sends get_keyboard/get_pointer
// in the same buffer as bind messages, relay drops the seat requests but forwards
// the binds, cage registers those bind IDs, then foot tries to use them for surfaces.
// Instead, we defer caps=3 injection until after foot's first wl_surface.commit.

// processCompositorResponse:start
//   purpose: walk a single buffer of compositor→client Wayland messages and record the first wl_seat that reports caps=0 so input.zig can later inject a synthetic caps=3 (deferred caps injection).
//   input:  data (compositor→client raw bytes), registry (used to identify the wl_seat interface), deferred_seat_id (out: first observed seat id; 0 if none).
//   output: void; writes through deferred_seat_id exactly once per session.
//   sideEffects: logs one line per detected caps=0 seat; mutates deferred_seat_id.
pub fn processCompositorResponse(data: []u8, registry: *wl_registry.WlRegistry, deferred_seat_id: *u32) void {
    var offset: usize = 0;
    while (offset + 8 <= data.len) {
        const obj_id = std.mem.readInt(u32, data[offset..offset + 4][0..4], .little);
        const size_opcode = std.mem.readInt(u32, data[offset + 4..offset + 8][0..4], .little);
        const op_code: u16 = @truncate(size_opcode);
        const msg_size: usize = @as(usize, @as(u16, @truncate(size_opcode >> 16)));
        if (msg_size < 8) break;
        if (offset + msg_size > data.len) break;

        const iface = registry.getInterface(obj_id);
        if (iface == .wl_seat and op_code == 0 and msg_size >= 12) {
            const caps = std.mem.readInt(u32, data[offset + 8..offset + 12][0..4], .little);
            if (caps == 0 and deferred_seat_id.* == 0) {
                deferred_seat_id.* = obj_id;
                logEvent("[compositor→client] wl_seat caps=0 recorded seat_id={} (deferred injection)\n", .{obj_id});
            }
        }

        offset += msg_size;
    }
}
// processCompositorResponse:end

// processClientMessage:start
//   purpose: iterate over every framed Wayland message in a client→compositor buffer and dispatch each to processSingleMessage; advances fd_idx as SCM_RIGHTS fds are consumed.
//   input:  data (raw client buffer), fds (ancillary fds received with the buffer), tracker, registry, keyboard_id_ptr/pointer_id_ptr (out: captured seat child IDs).
//   output: void.
//   sideEffects: mutates tracker, registry, and the two ID pointers; calls logEvent once per message.
// processClientMessage:end
pub fn processClientMessage(
    data: []const u8,
    fds: []c_int,
    tracker: *wl_shm.WlShmTracker,
    registry: *wl_registry.WlRegistry,
    keyboard_id_ptr: *u32,
    pointer_id_ptr: *u32,
) void {
    var offset: usize = 0;
    var fd_idx: usize = 0;
    var msg_count: u32 = 0;
    while (offset + 8 <= data.len) {
        const obj_id = std.mem.readInt(u32, @as(*const [4]u8, @ptrCast(data[offset..offset+4].ptr)), .little);
        const size_opcode = std.mem.readInt(u32, @as(*const [4]u8, @ptrCast(data[offset+4..offset+8].ptr)), .little);
        const op_code: u16 = @truncate(size_opcode);
        const msg_bytes: usize = @as(usize, @as(u16, @truncate(size_opcode >> 16)));

        logEvent("[client] msg #{} obj_id={} opcode={} size={} bytes\n", .{msg_count, obj_id, op_code, msg_bytes});

        processSingleMessage(data[offset..], fds[fd_idx..], tracker, registry, &fd_idx, keyboard_id_ptr, pointer_id_ptr);

        if (msg_bytes < 8) break;
        offset += msg_bytes;
        msg_count += 1;
    }
}

pub fn processSingleMessage(
    data: []const u8,
    fds: []c_int,
    tracker: *wl_shm.WlShmTracker,
    registry: *wl_registry.WlRegistry,
    fd_idx: *usize,
    keyboard_id_ptr: *u32,
    pointer_id_ptr: *u32,
) void {
    if (data.len < 8) return;

    const obj_id = std.mem.readInt(u32, data[0..4], .little);
    const size_opcode = std.mem.readInt(u32, data[4..8], .little);
    const op_code: u16 = @truncate(size_opcode);
    const iface = registry.getInterface(obj_id);
    const rem_fds = fds;

    if (iface == .wl_display and op_code == 1) {
        if (data.len >= 12) {
            const new_id = std.mem.readInt(u32, @as(*const [4]u8, @ptrCast(data[8..12].ptr)), .little);
            const reg_success = registry.register(new_id, .wl_registry, obj_id);
            logEvent("[wl_display] get_registry new_id={} (registered={})\n", .{ new_id, reg_success });
        }
    }

    if (iface == .wl_compositor and op_code == 0) {
        if (data.len >= 12) {
            const new_id = std.mem.readInt(u32, data[8..12], .little);
            _ = registry.register(new_id, .wl_surface, obj_id);
            logEvent("[wl_compositor] create_surface new_id={}\n", .{new_id});
        }
    }

    if (iface == .wl_shm and op_code == 0 and rem_fds.len > 0) {
        if (data.len >= 16) {
            const new_pool_id = std.mem.readInt(u32, data[8..12], .little);
            const size = std.mem.readInt(u32, data[12..16], .little);
            tracker.addPool(new_pool_id, rem_fds[0], size) catch |e| {
                std.debug.print("[wl_shm] addPool error: {} (size={})\n", .{e, size});
            };
            _ = registry.register(new_pool_id, .wl_shm_pool, obj_id);
            fd_idx.* += 1;
            logEvent("[wl_shm] create_pool pool_id={} size={} fd={}\n", .{ new_pool_id, size, rem_fds[0] });
        }
    }

    if (iface == .wl_shm_pool and op_code == 0) {
        if (data.len >= 32) {
            const buf_id = std.mem.readInt(u32, data[8..12], .little);
            const offset = std.mem.readInt(u32, data[12..16], .little);
            const width = std.mem.readInt(u32, data[16..20], .little);
            const height = std.mem.readInt(u32, data[20..24], .little);
            const stride = std.mem.readInt(u32, data[24..28], .little);
            const format = std.mem.readInt(u32, data[28..32], .little);

            tracker.addBuffer(buf_id, obj_id, offset, width, height, stride, format) catch |e| {
                std.debug.print("[wl_shm_pool] addBuffer error: {}\n", .{e});
            };
            _ = registry.register(buf_id, .wl_buffer, obj_id);

            std.debug.print("[wl_shm_pool] create_buffer buf_id={} offset={} {}x{} stride={} format={}\n", .{
                buf_id, offset, width, height, stride, format,
            });
        }
    }

    if (iface == .wl_shm_pool and op_code == 1) {
        tracker.releasePool(obj_id) catch |e| {
            std.debug.print("[wl_shm_pool] releasePool error: {}\n", .{e});
        };
        _ = registry.unregister(obj_id);
        logEvent("[wl_shm_pool] destroy pool_id={}\n", .{obj_id});
    }

    if (iface == .wl_shm_pool and op_code == 2) {
        if (data.len >= 12) {
            const new_size = std.mem.readInt(u32, data[8..12], .little);
            tracker.resizePool(obj_id, new_size) catch |e| {
                std.debug.print("[wl_shm_pool] resizePool error: {}\n", .{e});
            };
            logEvent("[wl_shm_pool] resize pool_id={} new_size={}\n", .{obj_id, new_size});
        }
    }

    if (iface == .wl_buffer and op_code == 0) {
        tracker.releaseBuffer(obj_id) catch |e| {
            std.debug.print("[wl_buffer] releaseBuffer error: {}\n", .{e});
        };
        _ = registry.unregister(obj_id);
        logEvent("[wl_buffer] destroy buf_id={}\n", .{obj_id});
    }

    if (iface == .wl_registry and op_code == 0) {
        if (data.len >= 20) {
            const name = std.mem.readInt(u32, data[8..12], .little);
            const iface_str_len = std.mem.readInt(u32, data[12..16], .little);
            const iface_str_start: usize = 16;
            const padded_len: usize = (@as(usize, iface_str_len) + 3) & ~@as(usize, 3);
            const version_offset = iface_str_start + padded_len;
            if (data.len < version_offset + 8) return;

            const version = std.mem.readInt(u32, data[version_offset..][0..4], .little);
            const new_id = std.mem.readInt(u32, data[version_offset + 4 ..][0..4], .little);

            var iface_name_bytes: [128]u8 = undefined;
            var iface_name_len: usize = 0;
            if (iface_str_len > 1 and iface_str_len <= 128) {
                iface_name_len = iface_str_len - 1;
                if (iface_str_start + iface_name_len <= data.len) {
                    @memcpy(iface_name_bytes[0..iface_name_len], data[iface_str_start..][0..iface_name_len]);
                }
            }

            const parsed_iface = wl_registry.WlRegistry.parseInterface(iface_name_bytes[0..iface_name_len]);
            _ = registry.register(new_id, parsed_iface, obj_id);

            logEvent("[registry] bind name={} version={} new_id={} iface={s}\n", .{
                name, version, new_id,
                wl_registry.WlRegistry.interfaceName(parsed_iface),
            });
        }
    }

    if (iface == .wl_surface and op_code == 1) {
        if (data.len >= 12) {
            const buf_id = std.mem.readInt(u32, data[8..12], .little);
            tracker.attachBuffer(obj_id, buf_id) catch |e| {
                std.debug.print("[wl_surface] attachBuffer error: {}\n", .{e});
            };
            logEvent("[wl_surface] attach surface_id={} buf_id={}\n", .{ obj_id, buf_id });
        }
    }

    if (iface == .wl_surface and op_code == 4) {
        if (data.len >= 24) {
            const dmg_x = std.mem.readInt(i32, data[8..12], .little);
            const dmg_y = std.mem.readInt(i32, data[12..16], .little);
            const dmg_w = std.mem.readInt(i32, data[16..20], .little);
            const dmg_h = std.mem.readInt(i32, data[20..24], .little);
            tracker.markDamage(dmg_x, dmg_y, dmg_w, dmg_h);
            logEvent("[wl_surface] damage surface_id={} x={} y={} w={} h={}\n", .{ obj_id, dmg_x, dmg_y, dmg_w, dmg_h });
        }
    }

    if (iface == .wl_surface and op_code == 9) {
        if (data.len >= 24) {
            const dmg_x = std.mem.readInt(i32, data[8..12], .little);
            const dmg_y = std.mem.readInt(i32, data[12..16], .little);
            const dmg_w = std.mem.readInt(i32, data[16..20], .little);
            const dmg_h = std.mem.readInt(i32, data[20..24], .little);
            tracker.markDamage(dmg_x, dmg_y, dmg_w, dmg_h);
            logEvent("[wl_surface] damage_buffer surface_id={} x={} y={} w={} h={}\n", .{ obj_id, dmg_x, dmg_y, dmg_w, dmg_h });
        }
    }

    if (iface == .wl_surface and op_code == 6) {
        tracker.markCommit(obj_id);
        logEvent("[wl_surface] commit surface_id={}\n", .{obj_id});
    }

    if (iface == .wl_seat) {
        logEvent("[wl_seat] client msg obj_id={} op_code={} len={}\n", .{ obj_id, op_code, data.len });
    }

    if (iface == .wl_seat and op_code == 1) {
        if (data.len >= 12) {
            const kb_id = std.mem.readInt(u32, data[8..12], .little);
            keyboard_id_ptr.* = kb_id;
            _ = registry.register(kb_id, .wl_keyboard, obj_id);
            logEvent("[wl_seat] get_keyboard kb_id={}\n", .{kb_id});
        }
    }

    if (iface == .wl_seat and op_code == 0) {
        if (data.len >= 12) {
            const ptr_id = std.mem.readInt(u32, data[8..12], .little);
            pointer_id_ptr.* = ptr_id;
            _ = registry.register(ptr_id, .wl_pointer, obj_id);
            logEvent("[wl_seat] get_pointer ptr_id={}\n", .{ptr_id});
        }
    }

    return;
}
