// START_AI_HEADER
// MODULE: c.zig
// PURPOSE: single @cImport aggregation point for libc + lz4 headers used across the wayland-tunnel.
// INTENT: keep every Zig source in this crate pulling C symbols through one const; avoids the per-file @cImport cost and prevents header drift between modules.
// DEPENDENCIES: C headers — sys/socket, sys/un, sys/uio, sys/mman, sys/stat, poll, unistd, string, fcntl, stdlib, errno, lz4.
// PUBLIC_API: c (comptime namespace of libc + lz4 symbols).
// END_AI_HEADER

// _FORTIFY_SOURCE=0 is passed as a real -D flag from build.zig's c_mod.addCMacro (NOT via
// @cDefine here — @cDefine("_FORTIFY_SOURCE", "0") would emit a C STRING literal define,
// breaking ssp.h's `#if _FORTIFY_SOURCE > 0` numeric comparison). See build.zig for why.
pub const c = @cImport({
    @cInclude("stddef.h");
    @cInclude("stdio.h");
    @cInclude("sys/socket.h");
    @cInclude("sys/un.h");
    @cInclude("sys/uio.h");
    @cInclude("sys/mman.h");
    @cInclude("sys/stat.h");
    @cInclude("poll.h");
    @cInclude("unistd.h");
    @cInclude("string.h");
    @cInclude("fcntl.h");
    @cInclude("stdlib.h");
    @cInclude("errno.h");
    @cInclude("lz4.h");
});
