// START_AI_HEADER
// MODULE: wayland-tunnel/src/test_hash_cache.zig
// PURPOSE: Unit tests for FNV-1a hash caching used to skip duplicate POOL_DATA frames.
// INTENT: Tests hash consistency, collision behavior, and the pool_hash_cache slot allocation/reuse logic.
// DEPENDENCIES: std (@import("std")).
// PUBLIC_API: fnv1aHash (test helper).
// END_AI_HEADER

// Unit tests for FNV-1a hash caching in wayland-tunnel
// Tests the hash computation and cache logic for POOL_DATA skipping
// Run: zig test src/test_hash_cache.zig

const std = @import("std");

/// FNV-1a hash для сравнения буферов (быстрый, без аллокаций)
// fnv1aHash:start
//   purpose: Compute FNV-1a 64-bit hash of a byte slice (non-cryptographic, allocation-free).
//   input:  data: arbitrary byte slice.
//   output: 64-bit FNV-1a hash (u64). FNV offset basis for empty data.
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

test "fnv1a_same_data_same_hash" {
    const data1 = "Hello, World!";
    const data2 = "Hello, World!";
    const hash1 = fnv1aHash(data1);
    const hash2 = fnv1aHash(data2);
    try std.testing.expectEqual(hash1, hash2);
}

test "fnv1a_different_data_different_hash" {
    const data1 = "Hello, World!";
    const data2 = "Hello, World?";
    const hash1 = fnv1aHash(data1);
    const hash2 = fnv1aHash(data2);
    try std.testing.expect(hash1 != hash2);
}

test "fnv1a_empty_data_consistent" {
    const empty: []const u8 = "";
    const hash1 = fnv1aHash(empty);
    const hash2 = fnv1aHash(empty);
    try std.testing.expectEqual(hash1, hash2);
    // Should be FNV offset basis (initial value)
    try std.testing.expectEqual(hash1, 14695981039346656037);
}

test "fnv1a_large_buffer" {
    var buffer: [1024]u8 = undefined;
    @memset(buffer[0..], 0);
    const hash1 = fnv1aHash(buffer[0..]);
    try std.testing.expect(hash1 != 14695981039346656037); // Not empty hash
}

test "fnv1a_single_byte_change" {
    var buffer1: [16]u8 = undefined;
    var buffer2: [16]u8 = undefined;
    @memset(buffer1[0..], 0x42);
    @memset(buffer2[0..], 0x42);
    buffer2[8] = 0x43; // Change one byte

    const hash1 = fnv1aHash(buffer1[0..]);
    const hash2 = fnv1aHash(buffer2[0..]);
    try std.testing.expect(hash1 != hash2);
}

test "pool_hash_cache_structure" {
    const PoolHash = struct { pool_id: u32, hash: u64, sent: bool };
    var pool_hashes: [8]PoolHash = [_]PoolHash{.{ .pool_id = 0, .hash = 0, .sent = false }} ** 8;

    // Verify initialization
    for (pool_hashes) |ph| {
        try std.testing.expectEqual(ph.pool_id, 0);
        try std.testing.expectEqual(ph.hash, 0);
        try std.testing.expectEqual(ph.sent, false);
    }

    // Simulate cache update
    pool_hashes[0].pool_id = 10;
    pool_hashes[0].hash = 0x123456789abcdef0;
    pool_hashes[0].sent = true;

    try std.testing.expectEqual(pool_hashes[0].pool_id, 10);
    try std.testing.expectEqual(pool_hashes[0].hash, 0x123456789abcdef0);
    try std.testing.expectEqual(pool_hashes[0].sent, true);
}

test "pool_hash_cache_lookup" {
    const PoolHash = struct { pool_id: u32, hash: u64, sent: bool };
    var pool_hashes: [8]PoolHash = [_]PoolHash{.{ .pool_id = 0, .hash = 0, .sent = false }} ** 8;

    const pool_id = 5;
    const hash_value: u64 = 0xdeadbeefdeadbeef;

    // Store in cache
    pool_hashes[0].pool_id = pool_id;
    pool_hashes[0].hash = hash_value;
    pool_hashes[0].sent = true;

    // Lookup
    var found = false;
    for (&pool_hashes) |*ph| {
        if (ph.pool_id == pool_id and ph.hash == hash_value and ph.sent) {
            found = true;
            break;
        }
    }

    try std.testing.expect(found);
}

test "pool_hash_cache_miss_different_hash" {
    const PoolHash = struct { pool_id: u32, hash: u64, sent: bool };
    var pool_hashes: [8]PoolHash = [_]PoolHash{.{ .pool_id = 0, .hash = 0, .sent = false }} ** 8;

    const pool_id = 5;
    const stored_hash: u64 = 0x1111111111111111;
    const query_hash: u64 = 0x2222222222222222;

    // Store in cache
    pool_hashes[0].pool_id = pool_id;
    pool_hashes[0].hash = stored_hash;
    pool_hashes[0].sent = true;

    // Lookup with different hash
    var found = false;
    for (&pool_hashes) |*ph| {
        if (ph.pool_id == pool_id and ph.hash == query_hash and ph.sent) {
            found = true;
            break;
        }
    }

    try std.testing.expect(!found);
}

test "pool_hash_cache_slot_reuse" {
    const PoolHash = struct { pool_id: u32, hash: u64, sent: bool };
    var pool_hashes: [8]PoolHash = [_]PoolHash{.{ .pool_id = 0, .hash = 0, .sent = false }} ** 8;

    // Fill first pool
    pool_hashes[0].pool_id = 10;
    pool_hashes[0].hash = 0x1111;
    pool_hashes[0].sent = true;

    // Find free slot for second pool
    var slot_found: ?usize = null;
    for (&pool_hashes, 0..) |*ph, i| {
        if (ph.pool_id == 0) {
            slot_found = i;
            break;
        }
    }

    try std.testing.expect(slot_found != null);
    try std.testing.expectEqual(slot_found, 1);

    // Write second pool to slot 1
    pool_hashes[slot_found.?].pool_id = 20;
    pool_hashes[slot_found.?].hash = 0x2222;
    pool_hashes[slot_found.?].sent = true;

    try std.testing.expectEqual(pool_hashes[0].pool_id, 10);
    try std.testing.expectEqual(pool_hashes[1].pool_id, 20);
}
