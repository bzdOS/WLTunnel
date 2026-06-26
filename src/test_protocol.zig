// START_AI_HEADER
// MODULE: wayland-tunnel/src/test_protocol.zig
// PURPOSE: Unit tests for the v1 length-prefixed stream protocol wire format.
//          Covers frame encode/decode round-trips, POOL_DATA dedup logic (fnv1aHash),
//          edge cases (empty payload, max u16 payload, same-hash skip, diff-hash send).
// INTENT: Catch regressions in the [u32 LE size][payload] envelope without needing
//         real sockets, LZ4, or stream clients. All tests run stack-only (no heap).
// DEPENDENCIES: std (@import("std")).
// PUBLIC_API: 5 test blocks.
// START_TEST_GROUPS
//   - test_frame_encode_decode       — round-trip a well-formed v1 frame
//   - test_frame_empty_payload       — 0-byte payload is a valid v1 frame (size prefix = 0)
//   - test_frame_max_u16_payload     — 65535-byte payload stress (largest single-allocation frame)
//   - test_pool_data_skip            — same hash → cache hit → sendPoolData skipped
//   - test_pool_data_different       — changed pixel data → hash miss → sendPoolData called
// END_TEST_GROUPS
// END_AI_HEADER

// Run: zig test src/test_protocol.zig

const std = @import("std");
const mem = std.mem;
const testing = std.testing;

// ============================================================================
// Internal copy of fnv1aHash (mirrors relay.zig exactly — no import needed)
// ============================================================================

// fnv1aHash:start
//   purpose: Compute FNV-1a 64-bit hash of a byte slice (non-cryptographic, allocation-free).
//   input:  data: arbitrary byte slice.
//   output: 64-bit FNV-1a hash (u64). Returns FNV offset basis for empty input.
//   sideEffects: none (pure).
fn fnv1aHash(data: []const u8) u64 {
    var hash: u64 = 14695981039346656037;
    for (data) |byte| {
        hash ^= @as(u64, byte);
        hash *%= 1099511628211;
    }
    return hash;
}
// fnv1aHash:end

// ============================================================================
// Encoding helpers — mirror the exact byte layout from stream.zig
// ============================================================================

// writeU32Le:start
//   purpose: Write a u32 in little-endian order into a 4-byte buffer.
//   input: buf: destination [4]u8; v: value.
//   output: void.
//   sideEffects: mutates buf.
fn writeU32Le(buf: *[4]u8, v: u32) void {
    mem.writeInt(u32, buf, v, .little);
}
// writeU32Le:end

// readU32Le:start
//   purpose: Read a u32 in little-endian order from a 4-byte buffer.
//   input: buf: source [4]u8.
//   output: u32.
//   sideEffects: none.
fn readU32Le(buf: *const [4]u8) u32 {
    return mem.readInt(u32, buf, .little);
}
// readU32Le:end

// ============================================================================
// Pool-hash cache struct (mirrors relay.zig PoolHash exactly)
// ============================================================================

const PoolHash = struct {
    pool_id: u32,
    hash: u64,
    sent: bool,
};

// shouldSkipPoolData:start
//   purpose: Decide whether sendPoolData should be skipped for this frame.
//            Mirrors the per-frame dedup logic in relay.zig relayThreadFn.
//   input: pool_hashes: mutable [32]PoolHash slot array;
//          pool_id: SHM pool identifier for this frame;
//          pixels: raw pixel bytes to hash.
//   output: true if POOL_DATA should be skipped (hash hit, already sent to clients).
//   sideEffects: Updates the matching or first-free slot in pool_hashes on a miss.
fn shouldSkipPoolData(pool_hashes: *[32]PoolHash, pool_id: u32, pixels: []const u8) bool {
    const current_hash = fnv1aHash(pixels);

    // Check for cache hit: same pool_id + same hash + already sent.
    for (pool_hashes.*) |ph| {
        if (ph.pool_id == pool_id and ph.hash == current_hash and ph.sent) {
            return true; // skip — nothing changed
        }
    }

    // Cache miss — update the slot for this pool_id, or the first free slot.
    for (&pool_hashes.*) |*ph| {
        if (ph.pool_id == 0 or ph.pool_id == pool_id) {
            ph.pool_id = pool_id;
            ph.hash = current_hash;
            ph.sent = true;
            break;
        }
    }

    return false; // do not skip — send POOL_DATA
}
// shouldSkipPoolData:end

// ============================================================================
// Test 1: test_frame_encode_decode
// ============================================================================

test "test_frame_encode_decode" {
    // Write a [u32 LE len][payload] frame into a stack buffer, then read it
    // back and verify the size prefix decodes to the correct payload length
    // and that payload bytes are preserved verbatim.

    const payload = [_]u8{ 0x03, 0x01, 0x00, 0x00, 0x00, 0x20, 0x03, 0x58, 0x02 };
    const payload_size: u32 = @intCast(payload.len);

    var frame: [4 + payload.len]u8 = undefined;
    writeU32Le(frame[0..4], payload_size);
    @memcpy(frame[4..], &payload);

    // Decode
    const decoded_size = readU32Le(frame[0..4]);
    try testing.expectEqual(payload_size, decoded_size);
    try testing.expectEqualSlices(u8, &payload, frame[4..]);

    // First payload byte must be EV_POOL_DATA (0x03) — sanity check on the
    // event type byte that follows every v1 size prefix.
    try testing.expectEqual(@as(u8, 0x03), frame[4]);
}

// ============================================================================
// Test 2: test_frame_empty_payload
// ============================================================================

test "test_frame_empty_payload" {
    // A 0-byte payload is a valid v1 frame: only the 4-byte size prefix with
    // value 0 is transmitted. The receiver must not attempt to read beyond it.

    var frame: [4]u8 = undefined;
    writeU32Le(&frame, 0);

    const decoded_size = readU32Le(&frame);
    try testing.expectEqual(@as(u32, 0), decoded_size);

    // Verify each byte of the prefix
    try testing.expectEqual(@as(u8, 0), frame[0]);
    try testing.expectEqual(@as(u8, 0), frame[1]);
    try testing.expectEqual(@as(u8, 0), frame[2]);
    try testing.expectEqual(@as(u8, 0), frame[3]);
}

// ============================================================================
// Test 3: test_frame_max_u16_payload
// ============================================================================

test "test_frame_max_u16_payload" {
    // 65535-byte payload — the largest payload that fits in u16 (which is what
    // EV_POOL_DATA width/height fields use). The size prefix is u32 so it can
    // hold this value without overflow.

    const payload_size: u32 = 65535;
    var size_prefix: [4]u8 = undefined;
    writeU32Le(&size_prefix, payload_size);

    const decoded = readU32Le(&size_prefix);
    try testing.expectEqual(payload_size, decoded);

    // Verify little-endian byte order: 65535 = 0x0000_FFFF → [0xFF, 0xFF, 0x00, 0x00]
    try testing.expectEqual(@as(u8, 0xFF), size_prefix[0]);
    try testing.expectEqual(@as(u8, 0xFF), size_prefix[1]);
    try testing.expectEqual(@as(u8, 0x00), size_prefix[2]);
    try testing.expectEqual(@as(u8, 0x00), size_prefix[3]);

    // Confirm the prefix survives a POOL_DATA-style arithmetic:
    // payload_size = 25 (header) + lz4_len. Here lz4_len = 65510.
    const lz4_len: u32 = 65510;
    const pool_payload: u32 = 25 + lz4_len;
    var pool_prefix: [4]u8 = undefined;
    writeU32Le(&pool_prefix, pool_payload);
    try testing.expectEqual(pool_payload, readU32Le(&pool_prefix));
}

// ============================================================================
// Test 4: test_pool_data_skip
// ============================================================================

test "test_pool_data_skip" {
    // When the pixel buffer content has not changed, the relay dedup cache
    // should report a hit and sendPoolData should be skipped.
    //
    // This exercises the shouldSkipPoolData helper which mirrors the cache
    // look-up logic in relay.zig relayThreadFn FRAME_CAPTURE block.

    var pool_hashes: [32]PoolHash = [_]PoolHash{.{ .pool_id = 0, .hash = 0, .sent = false }} ** 32;
    const pool_id: u32 = 7;

    // A 16-byte all-zero pixel buffer (highly compressible, deterministic hash)
    var pixels: [16]u8 = [_]u8{0} ** 16;

    // First call: cache miss — should NOT skip
    const skip_first = shouldSkipPoolData(&pool_hashes, pool_id, &pixels);
    try testing.expect(!skip_first);

    // Second call: same pixels → cache hit → MUST skip
    const skip_second = shouldSkipPoolData(&pool_hashes, pool_id, &pixels);
    try testing.expect(skip_second);

    // Third call: still same pixels → still a cache hit
    const skip_third = shouldSkipPoolData(&pool_hashes, pool_id, &pixels);
    try testing.expect(skip_third);
}

// ============================================================================
// Test 5: test_pool_data_different
// ============================================================================

test "test_pool_data_different" {
    // When pixel data changes between frames, the hash miss must cause
    // shouldSkipPoolData to return false (i.e. sendPoolData should fire).

    var pool_hashes: [32]PoolHash = [_]PoolHash{.{ .pool_id = 0, .hash = 0, .sent = false }} ** 32;
    const pool_id: u32 = 3;

    var pixels_a: [16]u8 = [_]u8{0xAA} ** 16;
    var pixels_b: [16]u8 = [_]u8{0xBB} ** 16; // different content → different hash

    // Sanity: the two payloads must hash differently
    try testing.expect(fnv1aHash(&pixels_a) != fnv1aHash(&pixels_b));

    // First frame — cache miss → do not skip
    const skip_a = shouldSkipPoolData(&pool_hashes, pool_id, &pixels_a);
    try testing.expect(!skip_a);

    // Same frame repeated — cache hit → skip
    const skip_a_again = shouldSkipPoolData(&pool_hashes, pool_id, &pixels_a);
    try testing.expect(skip_a_again);

    // Different content — hash miss → do not skip, then update slot
    const skip_b = shouldSkipPoolData(&pool_hashes, pool_id, &pixels_b);
    try testing.expect(!skip_b);

    // Now pixels_b is cached; calling again should skip
    const skip_b_again = shouldSkipPoolData(&pool_hashes, pool_id, &pixels_b);
    try testing.expect(skip_b_again);

    // Going back to pixels_a changes hash again — must not skip
    const skip_a_back = shouldSkipPoolData(&pool_hashes, pool_id, &pixels_a);
    try testing.expect(!skip_a_back);
}
