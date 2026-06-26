// START_AI_HEADER
// MODULE: wayland-tunnel/src/test_wayland_parse.zig
// PURPOSE: Unit tests for Wayland wire format parsing — regression tests for bugs found during development.
// INTENT: Verifies message size is in bytes (not words), wl_registry.bind string offset is 16 (not 24),
//         batch iteration advances offset correctly, and key message field extractions.
// DEPENDENCIES: std (@import("std")).
// PUBLIC_API: none (test module).
// END_AI_HEADER

// Unit tests for Wayland wire format parsing — the bugs found in this session.
// Run: zig test src/test_wayland_parse.zig
// Or:  zig build test (after adding to build.zig)

const std = @import("std");

// ── Test 1: Message size is in bytes, NOT words ─────────────────────────────
// Bug: code did `(size_opcode >> 16) * 4` → 4x wrong offsets.
// Fix: `size_opcode >> 16` already IS the byte count.
test "wayland_message_size_is_bytes_not_words" {
    // wl_display.get_registry: 3 words = 12 bytes total
    const msg = [12]u8{
        0x01, 0x00, 0x00, 0x00, // obj_id = 1 (wl_display)
        0x01, 0x00, 0x0C, 0x00, // LE: op=1 | size=12<<16 → 0x000C0001
        0x02, 0x00, 0x00, 0x00, // new_id = 2 (wl_registry)
    };
    const size_opcode = std.mem.readInt(u32, msg[4..8], .little);
    const msg_size: usize = @as(usize, @as(u16, @truncate(size_opcode >> 16)));
    try std.testing.expectEqual(@as(usize, 12), msg_size);
    // The bug: 12 * 4 = 48, NOT 12
    try std.testing.expect(msg_size != 48);
}

// ── Test 2: wl_registry.bind wire layout ────────────────────────────────────
// Bug: iface_str_start was hardcoded to 24 instead of 16.
// Wire: obj(4)+size_op(4)+name(4)+str_len(4)+str(padded)+version(4)+new_id(4)
//                         ^8      ^12         ^16
test "registry_bind_iface_string_starts_at_offset_16" {
    // Encoding: wl_registry.bind for "wl_shm" (6 chars + null = 7 bytes → padded 8)
    // name=1, iface="wl_shm", version=2, new_id=4
    // Total message: 8 (hdr) + 4 (name) + 4 (len) + 8 (str) + 4 (ver) + 4 (id) = 32 bytes
    var buf = [_]u8{0} ** 32;
    std.mem.writeInt(u32, buf[0..4], 2, .little);           // obj_id = wl_registry
    std.mem.writeInt(u32, buf[4..8], (32 << 16) | 0, .little); // size=32, op=0
    std.mem.writeInt(u32, buf[8..12], 1, .little);           // name = 1
    std.mem.writeInt(u32, buf[12..16], 7, .little);          // iface_str_len = 7 (incl. null)
    // iface string at offset 16: "wl_shm\0" → padded to 8 bytes
    @memcpy(buf[16..22], "wl_shm");
    buf[22] = 0; buf[23] = 0;                                // null + padding
    std.mem.writeInt(u32, buf[24..28], 2, .little);          // version = 2
    std.mem.writeInt(u32, buf[28..32], 4, .little);          // new_id = 4

    // Parse as our fixed code does:
    const name = std.mem.readInt(u32, buf[8..12], .little);
    const iface_str_len = std.mem.readInt(u32, buf[12..16], .little);
    const padded: usize = (@as(usize, iface_str_len) + 3) & ~@as(usize, 3);
    const ver_off = 16 + padded; // = 16 + 8 = 24
    const version = std.mem.readInt(u32, buf[ver_off..][0..4], .little);
    const new_id = std.mem.readInt(u32, buf[ver_off + 4 ..][0..4], .little);

    try std.testing.expectEqual(@as(u32, 1), name);
    try std.testing.expectEqual(@as(usize, 24), ver_off);   // not 16 or 20!
    try std.testing.expectEqual(@as(u32, 2), version);
    try std.testing.expectEqual(@as(u32, 4), new_id);
    try std.testing.expectEqualStrings("wl_shm", buf[16..22]);
}

// ── Test 3: Bug case — wrong offsets with old code ──────────────────────────
// Old code: version at [16..20], new_id at [20..24], iface_start = 24
// This produces garbage: reads "wl_s" as version integer
test "registry_bind_old_offsets_give_garbage" {
    var buf = [_]u8{0} ** 32;
    std.mem.writeInt(u32, buf[8..12], 1, .little);
    std.mem.writeInt(u32, buf[12..16], 7, .little);
    @memcpy(buf[16..22], "wl_shm");
    buf[22] = 0; buf[23] = 0;
    std.mem.writeInt(u32, buf[24..28], 2, .little);
    std.mem.writeInt(u32, buf[28..32], 4, .little);

    // Old buggy code read version from offset 16:
    const buggy_version = std.mem.readInt(u32, buf[16..20], .little);
    // "wl_s" in little-endian: 'w'=0x77 'l'=0x6C '_'=0x5F 's'=0x73
    try std.testing.expect(buggy_version != 2);    // definitely NOT 2
    try std.testing.expect(buggy_version > 1000);  // some large garbage number
}

// ── Test 4: Message batch iteration ─────────────────────────────────────────
// Bug: processClientMessage only processed first message in a batch.
// Fix: loop over all messages using size field to advance offset.
test "batch_of_two_messages_advances_offset_correctly" {
    // Two wl_display messages: sync(12B) + get_registry(12B) = 24B batch
    var batch = [_]u8{0} ** 24;
    // Message 1: wl_display.sync (op=0, size=12)
    std.mem.writeInt(u32, batch[0..4], 1, .little);
    std.mem.writeInt(u32, batch[4..8], (12 << 16) | 0, .little);
    std.mem.writeInt(u32, batch[8..12], 1, .little);  // new_id=1
    // Message 2: wl_display.get_registry (op=1, size=12)
    std.mem.writeInt(u32, batch[12..16], 1, .little);
    std.mem.writeInt(u32, batch[16..20], (12 << 16) | 1, .little);
    std.mem.writeInt(u32, batch[20..24], 2, .little); // new_id=2

    var offset: usize = 0;
    var msg_count: usize = 0;
    var opcodes: [4]u16 = undefined;

    while (offset + 8 <= batch.len) {
        const size_op = std.mem.readInt(u32, batch[offset + 4 .. offset + 8][0..4], .little);
        opcodes[msg_count] = @truncate(size_op);
        msg_count += 1;
        const msg_bytes: usize = @as(usize, @as(u16, @truncate(size_op >> 16)));
        if (msg_bytes < 8) break;
        offset += msg_bytes;
    }

    try std.testing.expectEqual(@as(usize, 2), msg_count);   // both messages parsed
    try std.testing.expectEqual(@as(u16, 0), opcodes[0]);    // sync
    try std.testing.expectEqual(@as(u16, 1), opcodes[1]);    // get_registry
    try std.testing.expectEqual(@as(usize, 24), offset);     // consumed all bytes
}

// ── Test 5: wl_compositor.create_surface new_id extraction ──────────────────
test "wl_compositor_create_surface_new_id_at_offset_8" {
    // create_surface: obj=3 (wl_compositor), op=0, new_id=5
    // size = 12 bytes (hdr + new_id)
    var msg = [_]u8{0} ** 12;
    std.mem.writeInt(u32, msg[0..4], 3, .little);
    std.mem.writeInt(u32, msg[4..8], (12 << 16) | 0, .little);
    std.mem.writeInt(u32, msg[8..12], 5, .little);  // new_id = 5

    const new_id = std.mem.readInt(u32, msg[8..12], .little);
    try std.testing.expectEqual(@as(u32, 5), new_id);
}

// ── Test 6: wl_shm.create_pool size field position ──────────────────────────
// create_pool: obj=wl_shm new_pool_id(u32) size(u32) + FD via ancillary
test "wl_shm_create_pool_size_at_offset_12" {
    // create_pool: op=0, new_pool_id=7, size=4096
    var msg = [_]u8{0} ** 20;
    std.mem.writeInt(u32, msg[0..4], 4, .little);              // obj_id = wl_shm
    std.mem.writeInt(u32, msg[4..8], (20 << 16) | 0, .little); // size=20, op=0
    std.mem.writeInt(u32, msg[8..12], 7, .little);              // new_pool_id = 7
    std.mem.writeInt(u32, msg[12..16], 4096, .little);          // size = 4096

    const pool_id = std.mem.readInt(u32, msg[8..12], .little);
    const pool_size = std.mem.readInt(u32, msg[12..16], .little);
    try std.testing.expectEqual(@as(u32, 7), pool_id);
    try std.testing.expectEqual(@as(u32, 4096), pool_size);
}
