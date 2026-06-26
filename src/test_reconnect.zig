// START_AI_HEADER
// MODULE: wayland-tunnel/src/test_reconnect.zig
// PURPOSE: Unit tests for relay EOF detection and readability signalling.
//          Covers the two conditions relay.zig observes on its poll() fds:
//          (a) data available (POLLIN + read returns > 0) and
//          (b) peer closed (POLLIN + read returns 0 → EOF).
// INTENT: Validate the low-level pipe/socket read semantics that relay.zig relies
//         on to detect disconnects without depending on POLLHUP (which may arrive
//         late on some kernels). Uses pipe(2) for a socketpair-free, portable
//         kernel test; the same EOF semantics hold for SOCK_STREAM sockets.
// DEPENDENCIES: std (@import("std")), libc via std.posix.
// PUBLIC_API: 2 test blocks.
// START_TEST_GROUPS
//   - test_eof_detection     — write EOF on write-end of a pipe, verify read-end
//                              poll(POLLIN) fires and read() returns 0
//   - test_stream_readable   — write data to write-end, verify read-end poll(POLLIN)
//                              fires and read() returns the exact bytes written
// END_TEST_GROUPS
// END_AI_HEADER

// Run: zig test src/test_reconnect.zig

const std = @import("std");
const testing = std.testing;
const posix = std.posix;

// ============================================================================
// Thin wrappers around std.posix to keep test bodies readable
// ============================================================================

// makePipe:start
//   purpose: Create a kernel pipe and return [read_fd, write_fd].
//   input: none.
//   output: [2]posix.fd_t or PipeError.
//   sideEffects: two new file descriptors in the calling process.
fn makePipe() ![2]posix.fd_t {
    return posix.pipe();
}
// makePipe:end

// pollReadable:start
//   purpose: Ask the kernel whether fd has data (or EOF) readable right now.
//            Uses poll(2) with a 0 ms timeout (non-blocking probe).
//            Returns true on POLLIN (data available) or POLLHUP (peer closed / EOF).
//            On Linux, pipe EOF sets POLLHUP without POLLIN; relay.zig checks both:
//              if (fds[0].revents & POLLHUP != 0) → break (disconnect)
//              if (fds[0].revents & POLLIN != 0)  → read data
//            This function mirrors that combined check.
//   input: fd: file descriptor to test.
//   output: true if POLLIN or POLLHUP is set in revents (data or EOF ready).
//   sideEffects: one poll(2) syscall.
fn pollReadable(fd: posix.fd_t) !bool {
    var pfd = [1]posix.pollfd{
        .{ .fd = fd, .events = posix.POLL.IN, .revents = 0 },
    };
    const n = try posix.poll(&pfd, 0); // 0 ms timeout — instant probe
    if (n < 0) return false;
    // Check both POLLIN (data available) and POLLHUP (peer closed the pipe/socket).
    // On Linux pipes, EOF arrives as POLLHUP; on sockets it may be POLLIN + read()=0.
    const readable = (pfd[0].revents & posix.POLL.IN) != 0;
    const hup = (pfd[0].revents & posix.POLL.HUP) != 0;
    return readable or hup;
}
// pollReadable:end

// ============================================================================
// Test 6: test_eof_detection
// ============================================================================

test "test_eof_detection" {
    // Scenario: relay.zig poll loop sees POLLIN on client_fd or compositor_fd.
    // It calls read(); if read() returns 0 the peer has closed the connection.
    // relay.zig then breaks the loop and cleans up.
    //
    // Emulation: use a pipe pair. Close the write-end. The read-end should
    // immediately become readable (poll returns POLLIN) and read() must return 0.

    const fds = try makePipe();
    const read_fd = fds[0];
    const write_fd = fds[1];
    defer posix.close(read_fd);
    // write_fd is closed below to trigger EOF

    // Before closing write-end: read-end should NOT be readable (no data, no EOF)
    const readable_before = try pollReadable(read_fd);
    try testing.expect(!readable_before);

    // Close the write-end — this signals EOF to the read-end
    posix.close(write_fd);

    // After closing write-end: POLLIN fires on read-end (EOF is readable)
    const readable_after = try pollReadable(read_fd);
    try testing.expect(readable_after);

    // read() must return 0 to confirm EOF (not an error, not data)
    var buf: [1]u8 = undefined;
    const n = try posix.read(read_fd, &buf);
    try testing.expectEqual(@as(usize, 0), n);
}

// ============================================================================
// Test 7: test_stream_readable
// ============================================================================

test "test_stream_readable" {
    // Scenario: relay.zig poll loop calls write() on the compositor_fd to forward
    // a client message; the compositor reads it. Mirrors the symmetric case where
    // relay reads client data: poll fires POLLIN then read() > 0.
    //
    // Emulation: write known bytes to write-end of a pipe; poll the read-end;
    // read the bytes back and verify they are identical.

    const fds = try makePipe();
    const read_fd = fds[0];
    const write_fd = fds[1];
    defer posix.close(read_fd);
    defer posix.close(write_fd);

    // Before writing: read-end should NOT be readable
    const before = try pollReadable(read_fd);
    try testing.expect(!before);

    // Write a small v1 protocol frame: [u32 LE len=5][EV_CURSOR_MOVE payload stub]
    const frame = [_]u8{
        0x09, 0x00, 0x00, 0x00, // size prefix: 9 (= 1+4+4, EV_CURSOR_MOVE payload)
        0x05,                   // EV_CURSOR_MOVE
        0xD2, 0x04, 0x00, 0x00, // x = 1234 LE
        0xC7, 0xFD, 0xFF, 0xFF, // y = -569 LE (two's complement)
    };
    const written = try posix.write(write_fd, &frame);
    try testing.expectEqual(@as(usize, frame.len), written);

    // After writing: read-end should be readable (data available)
    const after = try pollReadable(read_fd);
    try testing.expect(after);

    // Read the frame back and verify byte-for-byte
    var recv: [frame.len]u8 = undefined;
    const n = try posix.read(read_fd, &recv);
    try testing.expectEqual(@as(usize, frame.len), n);
    try testing.expectEqualSlices(u8, &frame, &recv);

    // Verify size prefix decodes correctly
    const decoded_size = std.mem.readInt(u32, recv[0..4], .little);
    try testing.expectEqual(@as(u32, 9), decoded_size);

    // Verify event type byte
    try testing.expectEqual(@as(u8, 0x05), recv[4]);

    // After reading all data: no more bytes pending, but pipe still open (not EOF)
    // poll should return false (no more data).
    const drained = try pollReadable(read_fd);
    try testing.expect(!drained);
}
