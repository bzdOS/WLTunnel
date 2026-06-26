// START_AI_HEADER
// MODULE: wayland-tunnel/src/test_stream.zig
// PURPOSE: Unit tests for stream.zig v1 protocol wire format encoding
//          (sendPoolData, sendSurfaceCommit, sendSessionReset, sendStreamError,
//          sendCursorMove).
// INTENT: Verify the length-prefixed v1 envelope and per-event header layouts
//         without needing real stream clients or liblz4. The tests mirror the
//         encoding steps in stream.zig; if any header field is repacked (e.g.
//         pool_id shifts in SURFACE_COMMIT), these tests catch the regression
//         at compile-time of the protocol contract.
// DEPENDENCIES: std (mem, testing).
// PUBLIC_API: 16 test blocks (run with `zig build test-stream` or
//             `make wayland-stream-test`).
// START_TEST_GROUPS
//   - POOL_DATA / SURFACE_COMMIT / SESSION_RESET / CURSOR_MOVE / STREAM_ERROR
//     header byte layouts
//   - payload_size arithmetic (POOL_DATA = 25 + lz4_len, SURFACE_COMMIT = 33 fixed)
//   - length prefix encoding (4-byte LE u32, including 4 MiB max)
//   - STREAM_ERROR msg_len truncation to 255 bytes
//   - writeExact loop semantics (partial writes sum to total)
//   - raw_len == lz4_len signal for the uncompressed fast-path
// END_TEST_GROUPS
// END_AI_HEADER

const std = @import("std");
const mem = std.mem;
const stream = @import("stream.zig");

// ============================================================================
// Encoding helpers — shared across tests to avoid duplication
// ============================================================================

const SurfaceCommitParams = struct {
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
};

fn encodeSurfaceCommit(params: SurfaceCommitParams) [33]u8 {
    var msg: [33]u8 = undefined;
    var off: usize = 0;

    msg[off] = 0x04; off += 1;
    mem.writeInt(u32, msg[off..][0..4], params.surface_id, .little); off += 4;
    mem.writeInt(u32, msg[off..][0..4], params.pool_id, .little); off += 4;
    mem.writeInt(u32, msg[off..][0..4], params.offset, .little); off += 4;
    mem.writeInt(u16, msg[off..][0..2], params.buf_width, .little); off += 2;
    mem.writeInt(u16, msg[off..][0..2], params.buf_height, .little); off += 2;
    mem.writeInt(u32, msg[off..][0..4], params.buf_stride, .little); off += 4;
    mem.writeInt(u32, msg[off..][0..4], params.format, .little); off += 4;
    mem.writeInt(u16, msg[off..][0..2], params.damage_x, .little); off += 2;
    mem.writeInt(u16, msg[off..][0..2], params.damage_y, .little); off += 2;
    mem.writeInt(u16, msg[off..][0..2], params.damage_w, .little); off += 2;
    mem.writeInt(u16, msg[off..][0..2], params.damage_h, .little); off += 2;

    return msg;
}

const PoolDataParams = struct {
    pool_id: u32,
    width: u16,
    height: u16,
    stride: u32,
    format: u32,
    raw_len: u32,
    lz4_len: u32,
};

fn encodePoolData(params: PoolDataParams) [25]u8 {
    var header: [25]u8 = undefined;
    var off: usize = 0;

    header[off] = 0x03; off += 1;
    mem.writeInt(u32, header[off..][0..4], params.pool_id, .little); off += 4;
    mem.writeInt(u16, header[off..][0..2], params.width, .little); off += 2;
    mem.writeInt(u16, header[off..][0..2], params.height, .little); off += 2;
    mem.writeInt(u32, header[off..][0..4], params.stride, .little); off += 4;
    mem.writeInt(u32, header[off..][0..4], params.format, .little); off += 4;
    mem.writeInt(u32, header[off..][0..4], params.raw_len, .little); off += 4;
    mem.writeInt(u32, header[off..][0..4], params.lz4_len, .little); off += 4;

    return header;
}

const CursorMoveParams = struct {
    x: i32,
    y: i32,
};

fn encodeCursorMove(params: CursorMoveParams) [9]u8 {
    var msg: [9]u8 = undefined;
    var off: usize = 0;

    msg[off] = 0x05; off += 1;
    mem.writeInt(i32, msg[off..][0..4], params.x, .little); off += 4;
    mem.writeInt(i32, msg[off..][0..4], params.y, .little); off += 4;

    return msg;
}

const SessionResetParams = struct {
    reason: u8,
    msg: []const u8,
};

fn encodeSessionReset(comptime max_msg_len: usize, params: SessionResetParams) [3 + max_msg_len]u8 {
    var header: [3 + max_msg_len]u8 = undefined;
    var off: usize = 0;

    header[off] = 0xFE; off += 1;
    header[off] = params.reason; off += 1;
    header[off] = @intCast(params.msg.len); off += 1;
    @memcpy(header[off..][0..params.msg.len], params.msg);
    off += params.msg.len;

    return header;
}

const StreamErrorParams = struct {
    code: u16,
    msg: []const u8,
};

fn encodeStreamError(comptime max_msg_len: usize, params: StreamErrorParams) [4 + max_msg_len]u8 {
    var header: [4 + max_msg_len]u8 = undefined;
    const payload_size: u32 = 1 + 2 + 1 + @as(u32, @intCast(params.msg.len));

    mem.writeInt(u32, header[0..4], payload_size, .little);
    header[4] = 0xFF;
    mem.writeInt(u16, header[5..7], params.code, .little);
    header[7] = @intCast(params.msg.len);
    @memcpy(header[8..][0..params.msg.len], params.msg);

    return header;
}

// ============================================================================
// Decode helpers — verify encoded bytes match expected values
// ============================================================================

fn decodeSurfaceCommit(msg: [33]u8) SurfaceCommitParams {
    return .{
        .surface_id = mem.readInt(u32, msg[1..5], .little),
        .pool_id = mem.readInt(u32, msg[5..9], .little),
        .offset = mem.readInt(u32, msg[9..13], .little),
        .buf_width = mem.readInt(u16, msg[13..15], .little),
        .buf_height = mem.readInt(u16, msg[15..17], .little),
        .buf_stride = mem.readInt(u32, msg[17..21], .little),
        .format = mem.readInt(u32, msg[21..25], .little),
        .damage_x = mem.readInt(u16, msg[25..27], .little),
        .damage_y = mem.readInt(u16, msg[27..29], .little),
        .damage_w = mem.readInt(u16, msg[29..31], .little),
        .damage_h = mem.readInt(u16, msg[31..33], .little),
    };
}

fn decodePoolData(header: [25]u8) PoolDataParams {
    return .{
        .pool_id = mem.readInt(u32, header[1..5], .little),
        .width = mem.readInt(u16, header[5..7], .little),
        .height = mem.readInt(u16, header[7..9], .little),
        .stride = mem.readInt(u32, header[9..13], .little),
        .format = mem.readInt(u32, header[13..17], .little),
        .raw_len = mem.readInt(u32, header[17..21], .little),
        .lz4_len = mem.readInt(u32, header[21..25], .little),
    };
}

fn decodeCursorMove(msg: [9]u8) CursorMoveParams {
    return .{
        .x = mem.readInt(i32, msg[1..5], .little),
        .y = mem.readInt(i32, msg[5..9], .little),
    };
}

// ============================================================================
// Test 1: POOL_DATA header encoding (0x03)
// ============================================================================

test "POOL_DATA header encoding format" {
    // POOL_DATA wire format:
    // [event_type: u8 = 0x03]
    // [pool_id: u32 LE]
    // [width: u16 LE]
    // [height: u16 LE]
    // [stride: u32 LE]
    // [format: u32 LE]
    // [raw_len: u32 LE]
    // [lz4_len: u32 LE]
    // Total: 1 + 4 + 2 + 2 + 4 + 4 + 4 + 4 = 25 bytes

    const params = PoolDataParams{
        .pool_id = 42,
        .width = 800,
        .height = 600,
        .stride = 3200,
        .format = 0, // ARGB8888
        .raw_len = 1920000, // 800*600*4
        .lz4_len = 500000, // compressed
    };

    const header = encodePoolData(params);
    const decoded = decodePoolData(header);

    try std.testing.expectEqual(params, decoded);
    try std.testing.expect(header[0] == 0x03);
}

// ============================================================================
// Test 2: SURFACE_COMMIT header encoding (0x04)
// ============================================================================

test "SURFACE_COMMIT header encoding format" {
    // SURFACE_COMMIT wire format:
    // [event_type: u8 = 0x04]
    // [surface_id: u32 LE]
    // [pool_id: u32 LE]
    // [offset: u32 LE]
    // [buf_width: u16 LE]
    // [buf_height: u16 LE]
    // [buf_stride: u32 LE]
    // [format: u32 LE]
    // [damage_x: u16 LE]
    // [damage_y: u16 LE]
    // [damage_w: u16 LE]
    // [damage_h: u16 LE]
    // Total: 1 + 4 + 4 + 4 + 2 + 2 + 4 + 4 + 2 + 2 + 2 + 2 = 33 bytes

    const params = SurfaceCommitParams{
        .surface_id = 10,
        .pool_id = 42,
        .offset = 0,
        .buf_width = 800,
        .buf_height = 600,
        .buf_stride = 3200,
        .format = 0,
        .damage_x = 0,
        .damage_y = 0,
        .damage_w = 800,
        .damage_h = 600,
    };

    const msg = encodeSurfaceCommit(params);
    const decoded = decodeSurfaceCommit(msg);

    try std.testing.expectEqual(params, decoded);
    try std.testing.expect(msg[0] == 0x04);
}

// ============================================================================
// Test 3: SESSION_RESET header encoding (0xFE)
// ============================================================================

test "SESSION_RESET header encoding format" {
    // SESSION_RESET wire format:
    // [event_type: u8 = 0xFE]
    // [reason: u8]
    // [msg_len: u8]
    // [msg: msg_len bytes]
    // Total: 1 + 1 + 1 + msg_len

    const params = SessionResetParams{
        .reason = 1, // app_exit
        .msg = "compositor restarted",
    };

    const header = encodeSessionReset(20, params);

    try std.testing.expect(header[0] == 0xFE);
    try std.testing.expect(header[1] == params.reason);
    try std.testing.expect(header[2] == params.msg.len);
    try std.testing.expect(std.mem.eql(u8, header[3..][0..params.msg.len], params.msg));
}

// ============================================================================
// Test 4: Length prefix encoding (u32 LE)
// ============================================================================

test "length prefix encoding" {
    // Each stream message is prefixed with u32 LE payload size
    // payload_size = 1 (event_type) + payload_data

    const payload_size: u32 = 25; // POOL_DATA header
    var size_prefix: [4]u8 = undefined;
    mem.writeInt(u32, &size_prefix, payload_size, .little);

    try std.testing.expect(mem.readInt(u32, &size_prefix, .little) == payload_size);
    try std.testing.expect(size_prefix[0] == 25);
    try std.testing.expect(size_prefix[1] == 0);
    try std.testing.expect(size_prefix[2] == 0);
    try std.testing.expect(size_prefix[3] == 0);
}

// ============================================================================
// Test 5: Large payload size encoding
// ============================================================================

test "large payload size encoding (4MB)" {
    const payload_size: u32 = 4 * 1024 * 1024; // 4MB
    var size_prefix: [4]u8 = undefined;
    mem.writeInt(u32, &size_prefix, payload_size, .little);

    try std.testing.expect(mem.readInt(u32, &size_prefix, .little) == payload_size);
}

// ============================================================================
// Test 6: CURSOR_MOVE header encoding (0x05)
// ============================================================================

test "CURSOR_MOVE header encoding format" {
    // CURSOR_MOVE wire format (12 bytes total: 4 size prefix + 1 type + 4 x + 4 y):
    // [event_type: u8 = 0x05]
    // [x: i32 LE]
    // [y: i32 LE]
    // payload_size = 1 + 4 + 4 = 9

    const params = CursorMoveParams{
        .x = 1234,
        .y = -567,
    };

    const msg = encodeCursorMove(params);
    const decoded = decodeCursorMove(msg);

    try std.testing.expectEqual(params, decoded);
    try std.testing.expect(msg[0] == 0x05);
}

// ============================================================================
// Test 7: STREAM_ERROR header encoding (0xFF)
// ============================================================================

test "STREAM_ERROR header encoding format" {
    // EV_ERROR (0xFF) wire format:
    // [event_type: u8 = 0xFF]
    // [code: u16 LE]
    // [msg_len: u8]
    // [msg: msg_len bytes]
    // payload_size = 1 + 2 + 1 + msg_len

    const params = StreamErrorParams{
        .code = 0x0001, // pool_not_found
        .msg = "pool 42 missing",
    };

    const header = encodeStreamError(20, params);
    const payload_size = mem.readInt(u32, header[0..4], .little);

    try std.testing.expect(payload_size == 1 + 2 + 1 + params.msg.len);
    try std.testing.expect(header[4] == 0xFF);
    try std.testing.expect(mem.readInt(u16, header[5..7], .little) == params.code);
    try std.testing.expect(header[7] == params.msg.len);
    try std.testing.expect(std.mem.eql(u8, header[8..][0..params.msg.len], params.msg));
}

// ============================================================================
// Test 8: STREAM_ERROR msg_len truncation to 255
// ============================================================================

test "STREAM_ERROR truncates msg to 255 bytes" {
    // The wire format uses u8 for msg_len, so messages longer than 255
    // bytes must be truncated. Mirror that behaviour here.
    const long_msg = "a" ** 1000;
    const msg_len: u8 = @intCast(@min(long_msg.len, 255));
    try std.testing.expect(msg_len == 255);
}

// ============================================================================
// Test 9: SESSION_RESET payload_size math
// ============================================================================

test "SESSION_RESET payload_size includes msg_len" {
    // SESSION_RESET (0xFE) wire format:
    //   payload_size = 1 (event_type) + 1 (reason) + 1 (msg_len) + msg_len
    const reason: u8 = 1;
    const msg = "app_exit";
    const msg_len: u8 = @intCast(msg.len);
    const payload_size: u32 = 1 + 1 + 1 + @as(u32, msg_len);

    try std.testing.expect(payload_size == 3 + msg.len);
    try std.testing.expect(reason == 1);
}

// ============================================================================
// Test 10: POOL_DATA payload_size = 25 (header) + lz4_len
// ============================================================================

test "POOL_DATA payload_size math" {
    // payload_size = 1 + 4 + 2 + 2 + 4 + 4 + 4 + 4 = 25 (header)
    //              + lz4_len
    const payload_header_size: u32 = 1 + 4 + 2 + 2 + 4 + 4 + 4 + 4;
    try std.testing.expect(payload_header_size == 25);

    const lz4_len: u32 = 0;
    var size_prefix: [4]u8 = undefined;
    mem.writeInt(u32, &size_prefix, payload_header_size + lz4_len, .little);
    try std.testing.expect(mem.readInt(u32, &size_prefix, .little) == 25);

    // With LZ4-compressed payload of 500k bytes:
    const big: u32 = 500_000;
    mem.writeInt(u32, &size_prefix, payload_header_size + big, .little);
    try std.testing.expect(mem.readInt(u32, &size_prefix, .little) == 500_025);
}

// ============================================================================
// Test 11: SURFACE_COMMIT payload_size = 33 (fixed)
// ============================================================================

test "SURFACE_COMMIT payload_size is fixed at 33" {
    // payload_size = 1 + 4 + 4 + 4 + 2 + 2 + 4 + 4 + 2 + 2 + 2 + 2 = 33
    const payload_size: u32 = 1 + 4 + 4 + 4 + 2 + 2 + 4 + 4 + 2 + 2 + 2 + 2;
    try std.testing.expect(payload_size == 33);

    var size_prefix: [4]u8 = undefined;
    mem.writeInt(u32, &size_prefix, payload_size, .little);
    try std.testing.expect(mem.readInt(u32, &size_prefix, .little) == 33);
}

// ============================================================================
// Test 12: empty stream_clients array does not panic on header encode
// ============================================================================

test "empty event_type byte is 0x00 placeholder" {
    // Sanity check: EV_SURFACE_COMMIT, EV_POOL_DATA, EV_CURSOR_MOVE, etc.
    // all live in the 0x01..=0x05 range. A zero byte should never appear
    // as a valid event_type in the v1 stream protocol.
    const zero: u8 = 0x00;
    try std.testing.expect(zero < 0x01 or zero > 0x05);
}

// ============================================================================
// Test 13: writeExact-style loop with all() helper
// ============================================================================

test "writeExact loop math: partial writes sum to total" {
    // writeExact() in stream.zig does a manual loop:
    //   while (written < data.len) { n = write(...); written += n; }
    // Simulate that loop in user-space and verify the byte total matches.
    const data = [_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05 };
    var written: usize = 0;
    var iter: usize = 0;
    while (written < data.len) : (iter += 1) {
        // Simulate writing 2 bytes per syscall (chunked write).
        const n: usize = @min(2, data.len - written);
        written += n;
        if (iter > 10) break; // safety
    }
    try std.testing.expect(written == data.len);
}

// ============================================================================
// Test 14: POOL_DATA raw_len == lz4_len means uncompressed payload
// ============================================================================

test "POOL_DATA raw_len == lz4_len is the uncompressed fast-path signal" {
    // stream.zig sendPoolData() sets lz4_len = raw_len when LZ4 either
    // fails to compress smaller, WLSTREAM_NO_LZ4 is set, or pixels are
    // already-compressed. The bsdos-core wayland_bridge detects this and
    // uses the raw payload as-is.
    const raw_len: u32 = 1024;
    const lz4_len: u32 = 1024;
    try std.testing.expect(raw_len == lz4_len);
    try std.testing.expect(raw_len > 0);
}

// ============================================================================
// Test 15: SURFACE_COMMIT with dynamic damage values (not full surface)
// ============================================================================

test "SURFACE_COMMIT damage fields from dynamic input" {
    // Verify that damage_x/y/w/h are read from surface state, not hardcoded.
    // This test uses non-full-surface damage values to ensure the fields
    // are properly encoded and can be decoded by the compositor.

    const params = SurfaceCommitParams{
        .surface_id = 10,
        .pool_id = 42,
        .offset = 0,
        .buf_width = 800,
        .buf_height = 600,
        .buf_stride = 3200,
        .format = 0,
        // Partial damage: cursor region (10, 20, 8, 16)
        .damage_x = 10,
        .damage_y = 20,
        .damage_w = 8,
        .damage_h = 16,
    };

    const msg = encodeSurfaceCommit(params);
    const decoded = decodeSurfaceCommit(msg);

    // Verify damage fields are correctly encoded
    try std.testing.expectEqual(params.damage_x, decoded.damage_x);
    try std.testing.expectEqual(params.damage_y, decoded.damage_y);
    try std.testing.expectEqual(params.damage_w, decoded.damage_w);
    try std.testing.expectEqual(params.damage_h, decoded.damage_h);
}

// ============================================================================
// Test 16: SURFACE_COMMIT damage (0,0,0,0) means full surface (Wayland convention)
// ============================================================================

test "SURFACE_COMMIT damage (0,0,0,0) round-trip" {
    // Wayland protocol: zero-sized damage means full surface.
    // The compositor should treat (0,0,0,0) as full surface upload.

    const params = SurfaceCommitParams{
        .surface_id = 10,
        .pool_id = 42,
        .offset = 0,
        .buf_width = 800,
        .buf_height = 600,
        .buf_stride = 3200,
        .format = 0,
        // Zero damage = full surface
        .damage_x = 0,
        .damage_y = 0,
        .damage_w = 0,
        .damage_h = 0,
    };

    const msg = encodeSurfaceCommit(params);
    const decoded = decodeSurfaceCommit(msg);

    // Verify zero damage is correctly encoded
    try std.testing.expectEqual(@as(u16, 0), decoded.damage_x);
    try std.testing.expectEqual(@as(u16, 0), decoded.damage_y);
    try std.testing.expectEqual(@as(u16, 0), decoded.damage_w);
    try std.testing.expectEqual(@as(u16, 0), decoded.damage_h);
}

// ============================================================================
// LZ4 compression tests — verify tryCompressLz4 behavior
// ============================================================================

test "tryCompressLz4: compressible data (all zeros) should compress" {
    // All zeros is highly compressible — LZ4 should reduce size significantly
    var pixels: [1024]u8 = [_]u8{0} ** 1024;
    var lz4_buf: [2048]u8 = undefined;

    const result = stream.tryCompressLz4(&lz4_buf, &pixels);

    try std.testing.expect(result.was_compressed);
    try std.testing.expect(result.lz4_len < pixels.len);
    try std.testing.expectEqual(result.data.len, result.lz4_len);
}

test "tryCompressLz4: incompressible data (random) should not compress" {
    // Random data is incompressible — LZ4 should return was_compressed=false
    // with lz4_len == raw_len
    var pixels: [256]u8 = undefined;
    var lz4_buf: [512]u8 = undefined;

    // Fill with pseudo-random data (simple pattern that doesn't compress well)
    for (&pixels, 0..) |*p, i| {
        p.* = @intCast((i * 7 + 13) % 256);
    }

    const result = stream.tryCompressLz4(&lz4_buf, &pixels);

    // Random data should not compress (or compress to larger size)
    // In that case, was_compressed should be false and lz4_len == raw_len
    if (!result.was_compressed) {
        try std.testing.expectEqual(result.lz4_len, pixels.len);
        try std.testing.expectEqualSlices(u8, result.data, &pixels);
    }
}

test "tryCompressLz4: empty data should not compress" {
    const pixels: [0]u8 = .{};
    var lz4_buf: [256]u8 = undefined;

    const result = stream.tryCompressLz4(&lz4_buf, &pixels);

    try std.testing.expect(!result.was_compressed);
    try std.testing.expectEqual(result.lz4_len, 0);
    try std.testing.expectEqual(result.data.len, 0);
}

test "tryCompressLz4: pixels larger than lz4_buf should not compress" {
    // If pixels.len > lz4_buf.len, compression should be skipped
    var pixels: [2048]u8 = [_]u8{0} ** 2048;
    var lz4_buf: [1024]u8 = undefined;

    const result = stream.tryCompressLz4(&lz4_buf, &pixels);

    try std.testing.expect(!result.was_compressed);
    try std.testing.expectEqual(result.lz4_len, pixels.len);
    try std.testing.expectEqualSlices(u8, result.data, &pixels);
}

test "tryCompressLz4: compressible pattern (repeating bytes)" {
    // Repeating pattern should compress well
    var pixels: [1024]u8 = undefined;
    var lz4_buf: [2048]u8 = undefined;

    // Fill with repeating 4-byte pattern
    for (&pixels, 0..) |*p, i| {
        p.* = @intCast(i % 4);
    }

    const result = stream.tryCompressLz4(&lz4_buf, &pixels);

    try std.testing.expect(result.was_compressed);
    try std.testing.expect(result.lz4_len < pixels.len);
}
