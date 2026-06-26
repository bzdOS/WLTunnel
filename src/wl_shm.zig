// START_AI_HEADER
// MODULE: wayland-tunnel/src/wl_shm.zig
// PURPOSE: Track Wayland SHM pools and buffers for framebuffer pixel access
// INTENT: Give relay.zig a stable view of pool_id→mmap and buffer_id→geometry
//         so frame pixels can be read without parsing raw Wayland protocol bytes
// DEPENDENCIES: c.zig (mmap, fstat, close)
// PUBLIC_API:
//   WlShmTracker — struct tracking pools[], buffers[], surfaces[]
//   WlShmTracker.addPool(pool_id, fd, size) — register mmap'd shared memory region
//   WlShmTracker.resizePool(pool_id, new_size) — munmap + remap larger region
//   WlShmTracker.addBuffer(buf_id, pool_id, offset, w/h/stride/format) — track buffer metadata
//   WlShmTracker.attachBuffer(surface_id, buffer_id) — bind buffer to surface
//   WlShmTracker.getLatestFrame() — return latest committed surface geometry + mmap slice
//   WlShmTracker.getAttachedBuffer(surface_id) — return buffer_id attached to surface
//   WlShmTracker.getCommitPixels(surface_id) — zero-copy pixel pointer
//   WlShmTracker.markCommit(surface_id) — record pending surface commit
//   WlShmTracker.markDamage(x, y, w, h) — track dirty region for pending commit
//   WlShmTracker.releasePool(pool_id) — unref pool (deferred if buffers still live)
//   WlShmTracker.releaseBuffer(buffer_id) — release buffer slot, finalize deferred pools
//   WlShmTracker.releaseSurface(surface_id) — release surface slot
//   WlShmTracker.deinit() — cleanup all mmap/fd at shutdown
// START_INVARIANTS
//   - pool fds are mmap-ed on creation; mmap pointer valid until pool is destroyed
//   - buffer geometry (w/h/stride/format) set at wl_buffer creation, immutable after
//   - getLatestFrame() returns null if no commit received yet
//   - pool.backing updated via fstat on each getLatestFrame (foot may ftruncate late)
//   - pool.pending_release defers munmap+close until all buffers from pool destroyed
// END_INVARIANTS
// END_AI_HEADER

const std = @import("std");
const c = @cImport({
    @cInclude("sys/mman.h");
    @cInclude("sys/stat.h");
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
    @cInclude("string.h");
});

/// Wayland shared memory format codes (wl_shm.format)
pub const PixelFormat = enum(u32) {
    argb8888 = 0,
    xrgb8888 = 1,
    rgb888 = 2,
    rgb565 = 3,
    _,
};

/// SHM pool state — mmap'd shared buffer
pub const ShmPool = struct {
    pool_id: u32,
    fd: c_int,
    ptr: ?[*]const u8,
    size: usize,    // bytes mmap'd (= declared size from create_pool) — used for munmap
    backing: usize, // bytes actually backed by the shm file at mmap time (from fstat)
                    // foot may declare future size before ftruncating; only `backing`
                    // bytes are safe to read — checked in getLatestFrame
    active: bool,
    // pending_release: client called wl_shm_pool.destroy but buffers still reference us.
    // We defer munmap+close until all buffers from this pool are released.
    pending_release: bool,
};

/// Wayland buffer — describes a rect within a pool
pub const WlBuffer = struct {
    buffer_id: u32,
    pool_id: u32,
    offset: u32,
    width: u32,
    height: u32,
    stride: u32,
    format: PixelFormat,
    active: bool,
};

/// Surface attachment state — which buffer is active
pub const SurfaceState = struct {
    surface_id: u32,
    attached_buffer: ?u32, // buffer_id or null
    active: bool,
};

// Limits sized for real workloads: foot creates many pools/buffers during resize.
// Slots are reused on destroy — these are the high-watermark array sizes.
const MAX_POOLS    = 32;
const MAX_BUFFERS  = 64;
const MAX_SURFACES = 16;

/// Captured frame data (zero-copy: pixels is a slice of mmap'd pool)
pub const FrameCapture = struct {
    surface_id: u32,
    width: u16,
    height: u16,
    stride: u16,
    format: u32,
    pixels: []const u8,
    // Damage rect (dirty region for this frame)
    damage_x: i32,
    damage_y: i32,
    damage_w: i32,  // -1 = full surface (no damage msg received)
    damage_h: i32,
};

/// Buffer dimensions structure for pixel frame transmission
pub const BufferDims = struct {
    width: u16,
    height: u16,
    stride: u16,
    format: u32,
};

/// Wayland SHM tracker — minimal, zero-copy pixel extraction
pub const WlShmTracker = struct {
    pools: [MAX_POOLS]ShmPool = [_]ShmPool{std.mem.zeroes(ShmPool)} ** MAX_POOLS,
    buffers: [MAX_BUFFERS]WlBuffer = [_]WlBuffer{std.mem.zeroes(WlBuffer)} ** MAX_BUFFERS,
    surfaces: [MAX_SURFACES]SurfaceState = [_]SurfaceState{std.mem.zeroes(SurfaceState)} ** MAX_SURFACES,

    // High-watermark: highest index+1 ever used. Slots below may be inactive (reusable).
    pool_hwm: usize = 0,
    buffer_hwm: usize = 0,
    surface_hwm: usize = 0,

    // Last committed surface — set by processClientMessage on wl_surface.commit
    pending_commit_surface: u32 = 0,
    has_pending_commit: bool = false,

    // Damage tracking for pending commit
    // -1 = full surface (no damage msg received), >= 0 = specific dirty rect
    pending_damage_x: i32 = 0,
    pending_damage_y: i32 = 0,
    pending_damage_w: i32 = -1,
    pending_damage_h: i32 = -1,

    // --- Slot allocation helpers (reuse inactive slots before extending hwm) ---

    // allocPoolSlot:start
    //   purpose: find inactive pool slot or allocate new one within MAX_POOLS limit
    //   input: none
    //   output: pointer to ShmPool slot, or null if no slots available
    //   sideEffects: none (updates pool_hwm only on new slot allocation)
    fn allocPoolSlot(self: *WlShmTracker) ?*ShmPool {
        for (self.pools[0..self.pool_hwm]) |*slot| {
            if (!slot.active) return slot;
        }
        if (self.pool_hwm >= MAX_POOLS) return null;
        const slot = &self.pools[self.pool_hwm];
        self.pool_hwm += 1;
        return slot;
    }
    // allocPoolSlot:end

    // allocBufferSlot:start
    //   purpose: find inactive buffer slot or allocate new one within MAX_BUFFERS limit
    //   input: none
    //   output: pointer to WlBuffer slot, or null if no slots available
    //   sideEffects: none (updates buffer_hwm only on new slot allocation)
    fn allocBufferSlot(self: *WlShmTracker) ?*WlBuffer {
        for (self.buffers[0..self.buffer_hwm]) |*slot| {
            if (!slot.active) return slot;
        }
        if (self.buffer_hwm >= MAX_BUFFERS) return null;
        const slot = &self.buffers[self.buffer_hwm];
        self.buffer_hwm += 1;
        return slot;
    }
    // allocBufferSlot:end

    // allocSurfaceSlot:start
    //   purpose: find inactive surface slot or allocate new one within MAX_SURFACES limit
    //   input: none
    //   output: pointer to SurfaceState slot, or null if no slots available
    //   sideEffects: none (updates surface_hwm only on new slot allocation)
    fn allocSurfaceSlot(self: *WlShmTracker) ?*SurfaceState {
        for (self.surfaces[0..self.surface_hwm]) |*slot| {
            if (!slot.active) return slot;
        }
        if (self.surface_hwm >= MAX_SURFACES) return null;
        const slot = &self.surfaces[self.surface_hwm];
        self.surface_hwm += 1;
        return slot;
    }
    // allocSurfaceSlot:end

    /// Add a new shared memory pool (wl_shm.create_pool)
    /// Maps the fd at mmap offset 0 with PROT_READ, MAP_SHARED.
    /// `size` is the declared size from the protocol; actual file backing may be smaller
    /// (foot can send create_pool before calling ftruncate). We mmap the full declared
    /// range (so munmap covers it all) but record the actual fstat size as `backing` —
    /// getLatestFrame refuses to access beyond `backing` to avoid SIGBUS.
    // addPool:start
    //   purpose: register a new shared memory pool via mmap
    //   input: pool_id (Wayland object id), fd (shared memory file descriptor), size (declared region size in bytes)
    //   output: error.MmapFailed if mmap fails, error.TooManyPools if at MAX_POOLS
    //   sideEffects: mmap (creates mapping), fstat (queries actual file backing size), debug prints
    pub fn addPool(self: *WlShmTracker, pool_id: u32, fd: c_int, size: usize) !void {
        if (fd < 0) {
            std.debug.print("[wl_shm] addPool: invalid fd={} for pool_id={} size={}\n", .{fd, pool_id, size});
            return error.MmapFailed;
        }
        const slot = self.allocPoolSlot() orelse return error.TooManyPools;

        const ptr = c.mmap(null, size, c.PROT_READ, c.MAP_SHARED, fd, 0);
        if (ptr == c.MAP_FAILED) {
            std.debug.print("[wl_shm] mmap failed: pool_id={} fd={} size={}\n",
                .{pool_id, fd, size});
            return error.MmapFailed;
        }

        // fstat to find actual file size — may be smaller than declared `size`.
        var st: c.struct_stat = std.mem.zeroes(c.struct_stat);
        const backing: usize = if (c.fstat(fd, &st) == 0 and st.st_size > 0)
            @as(usize, @intCast(st.st_size))
        else
            size; // fstat failed or empty — assume declared (best effort)
        if (backing < size) {
            std.debug.print("[wl_shm] addPool: pool_id={} declared={} backing={} (partial — foot ftruncates later)\n",
                .{pool_id, size, backing});
        }

        slot.* = ShmPool{
            .pool_id = pool_id,
            .fd = fd,
            .ptr = @ptrCast(ptr),
            .size = size,       // full mmap size — used by releasePool/munmap
            .backing = backing, // safe-to-read bytes at mmap time
            .active = true,
            .pending_release = false,
        };
        std.debug.print("[wl_shm] addPool OK: pool_id={} fd={} size={} backing={} ptr=0x{x}\n",
            .{pool_id, fd, size, backing, @intFromPtr(ptr)});
    }
    // addPool:end

    /// Resize an existing pool (wl_shm_pool.resize opcode=2)
    /// munmaps the old region and mmaps the new larger one on the same fd.
    // resizePool:start
    //   purpose: grow pool mapping to new_size (e.g., on terminal resize)
    //   input: pool_id (existing pool), new_size (larger size in bytes)
    //   output: error.PoolNotFound, error.MmapFailed
    //   sideEffects: munmap (old mapping), mmap (new mapping)
    pub fn resizePool(self: *WlShmTracker, pool_id: u32, new_size: usize) !void {
        for (self.pools[0..self.pool_hwm]) |*pool| {
            if (pool.pool_id == pool_id and pool.active) {
                if (pool.ptr) |ptr| {
                    _ = c.munmap(@constCast(@ptrCast(ptr)), pool.size);
                    pool.ptr = null; // mark unmapped before re-mapping to avoid SIGBUS on error
                }
                const new_ptr = c.mmap(null, new_size, c.PROT_READ, c.MAP_SHARED, pool.fd, 0);
                if (new_ptr == c.MAP_FAILED) {
                    std.debug.print("[wl_shm] resizePool mmap failed: pool_id={} fd={} new_size={}\n",
                        .{pool_id, pool.fd, new_size});
                    pool.active = false; // can't access pixels anymore
                    return error.MmapFailed;
                }
                std.debug.print("[wl_shm] resizePool OK: pool_id={} fd={} size={}->{} ptr=0x{x}\n",
                    .{pool_id, pool.fd, pool.size, new_size, @intFromPtr(new_ptr)});
                pool.ptr = @ptrCast(new_ptr);
                pool.size = new_size;
                // After resize, foot has already called ftruncate(fd, new_size) per protocol.
                pool.backing = new_size;
                return;
            }
        }
        return error.PoolNotFound;
    }
    // resizePool:end

    /// Add a new buffer description (wl_shm_pool.create_buffer)
    /// Does NOT allocate — just tracks the metadata
    // addBuffer:start
    //   purpose: register buffer metadata within existing pool
    //   input: buf_id, pool_id, offset (bytes within pool), width/height/stride (geometry), format (PixelFormat code)
    //   output: error.PoolNotFound, error.TooManyBuffers
    //   sideEffects: none (metadata only, no I/O)
    pub fn addBuffer(
        self: *WlShmTracker,
        buf_id: u32,
        pool_id: u32,
        offset: u32,
        width: u32,
        height: u32,
        stride: u32,
        format: u32,
    ) !void {
        // Validate pool exists
        var pool_found = false;
        for (self.pools[0..self.pool_hwm]) |pool| {
            if (pool.pool_id == pool_id and pool.active) {
                pool_found = true;
                break;
            }
        }
        if (!pool_found) return error.PoolNotFound;

        const slot = self.allocBufferSlot() orelse return error.TooManyBuffers;
        slot.* = WlBuffer{
            .buffer_id = buf_id,
            .pool_id = pool_id,
            .offset = offset,
            .width = width,
            .height = height,
            .stride = stride,
            .format = @enumFromInt(format),
            .active = true,
        };
    }
    // addBuffer:end

    /// Attach a buffer to a surface (wl_surface.attach)
    /// Creates surface record if it doesn't exist
    // attachBuffer:start
    //   purpose: associate buffer with surface (pending next commit)
    //   input: surface_id (Wayland surface object id), buffer_id (active buffer)
    //   output: error.BufferNotFound, error.TooManySurfaces
    //   sideEffects: none (metadata only)
    pub fn attachBuffer(self: *WlShmTracker, surface_id: u32, buffer_id: u32) !void {
        // Check if buffer exists
        var buffer_found = false;
        for (self.buffers[0..self.buffer_hwm]) |buf| {
            if (buf.buffer_id == buffer_id and buf.active) {
                buffer_found = true;
                break;
            }
        }
        if (!buffer_found) return error.BufferNotFound;

        // Find existing surface
        for (self.surfaces[0..self.surface_hwm]) |*surf| {
            if (surf.surface_id == surface_id and surf.active) {
                surf.attached_buffer = buffer_id;
                return;
            }
        }

        // New surface
        const slot = self.allocSurfaceSlot() orelse return error.TooManySurfaces;
        slot.* = SurfaceState{
            .surface_id = surface_id,
            .attached_buffer = buffer_id,
            .active = true,
        };
    }
    // attachBuffer:end

    /// Get attached buffer ID for a surface
    // getAttachedBuffer:start
    //   purpose: query current buffer attached to surface
    //   input: surface_id
    //   output: buffer_id or null
    //   sideEffects: none (read-only)
    pub fn getAttachedBuffer(self: *const WlShmTracker, surface_id: u32) ?u32 {
        for (self.surfaces[0..self.surface_hwm]) |surf| {
            if (surf.surface_id == surface_id and surf.active) {
                return surf.attached_buffer;
            }
        }
        return null;
    }
    // getAttachedBuffer:end

    /// Get pixel data on surface commit (wl_surface.commit)
    /// Returns a zero-copy slice of the mmap'd buffer, or error if validation fails
    // getCommitPixels:start
    //   purpose: get raw pixel pointer for committed surface buffer (zero-copy)
    //   input: surface_id
    //   output: pointer into mmap'd region, or error if surface/buffer/pool invalid or bounds check fails
    //   sideEffects: none (read-only access to mmap)
    pub fn getCommitPixels(self: *const WlShmTracker, surface_id: u32) ![*]const u8 {
        // Find surface and get attached buffer_id
        const buffer_id = blk: {
            for (self.surfaces[0..self.surface_hwm]) |surf| {
                if (surf.surface_id == surface_id and surf.active) {
                    break :blk surf.attached_buffer orelse return error.NoAttachedBuffer;
                }
            }
            return error.SurfaceNotFound;
        };

        // Find buffer
        const buf = blk: {
            for (self.buffers[0..self.buffer_hwm]) |b| {
                if (b.buffer_id == buffer_id and b.active) break :blk b;
            }
            return error.BufferNotFound;
        };

        // Find pool
        const pool = blk: {
            for (self.pools[0..self.pool_hwm]) |p| {
                if (p.pool_id == buf.pool_id and p.active) break :blk p;
            }
            return error.PoolNotFound;
        };

        const ptr = pool.ptr orelse return error.PoolNotMapped;

        // Validate bounds against actual backing (not declared size)
        const pixel_bytes = buf.stride * buf.height;
        if (buf.offset + pixel_bytes > pool.backing) {
            return error.BufferOutOfBounds;
        }

        return ptr + buf.offset;
    }
    // getCommitPixels:end

    /// Get buffer dimensions for a surface
    // getSurfaceDimensions:start
    //   purpose: query width and height of buffer attached to surface
    //   input: surface_id
    //   output: [2]u32 containing {width, height}, or error if surface/buffer not found
    //   sideEffects: none (read-only)
    pub fn getSurfaceDimensions(self: *const WlShmTracker, surface_id: u32) ![2]u32 {
        const buffer_id = blk: {
            for (self.surfaces[0..self.surface_hwm]) |surf| {
                if (surf.surface_id == surface_id and surf.active) {
                    break :blk surf.attached_buffer orelse return error.NoAttachedBuffer;
                }
            }
            return error.SurfaceNotFound;
        };

        for (self.buffers[0..self.buffer_hwm]) |buf| {
            if (buf.buffer_id == buffer_id and buf.active) {
                return .{ buf.width, buf.height };
            }
        }
        return error.BufferNotFound;
    }
    // getSurfaceDimensions:end

    /// Get buffer stride (bytes per row)
    // getBufferStride:start
    //   purpose: query stride of buffer (scanline width in bytes)
    //   input: buffer_id
    //   output: stride in bytes, or error if buffer not found
    //   sideEffects: none (read-only)
    pub fn getBufferStride(self: *const WlShmTracker, buffer_id: u32) !u32 {
        for (self.buffers[0..self.buffer_hwm]) |buf| {
            if (buf.buffer_id == buffer_id and buf.active) {
                return buf.stride;
            }
        }
        return error.BufferNotFound;
    }
    // getBufferStride:end

    /// Get pixel format
    // getPixelFormat:start
    //   purpose: query PixelFormat enum of buffer (ARGB8888, XRGB8888, etc.)
    //   input: buffer_id
    //   output: PixelFormat, or error if buffer not found
    //   sideEffects: none (read-only)
    pub fn getPixelFormat(self: *const WlShmTracker, buffer_id: u32) !PixelFormat {
        for (self.buffers[0..self.buffer_hwm]) |buf| {
            if (buf.buffer_id == buffer_id and buf.active) {
                return buf.format;
            }
        }
        return error.BufferNotFound;
    }
    // getPixelFormat:end

    /// Release a pool (wl_shm_pool.destroy). Per Wayland protocol, pool destruction does NOT
    /// invalidate existing buffers — the shared memory backing remains valid until all
    /// wl_buffer objects are also destroyed. We defer munmap+close until no active buffers
    /// reference this pool (Chrome's pattern: create_pool → create_buffer → destroy_pool → attach → commit).
    // releasePool:start
    //   purpose: unref shared memory pool (may defer if buffers still active)
    //   input: pool_id
    //   output: error.PoolNotFound
    //   sideEffects: if no active buffers: munmap (unmaps region), close (closes fd); if buffers exist: none (sets pending_release flag)
    pub fn releasePool(self: *WlShmTracker, pool_id: u32) !void {
        for (self.pools[0..self.pool_hwm]) |*pool| {
            if (pool.pool_id == pool_id and pool.active) {
                // Check if any active buffers still reference this pool
                var refs: usize = 0;
                for (self.buffers[0..self.buffer_hwm]) |buf| {
                    if (buf.pool_id == pool_id and buf.active) refs += 1;
                }
                if (refs > 0) {
                    // Defer release: buffers still live — mark pending, keep mmap+fd alive
                    pool.pending_release = true;
                    std.debug.print("[wl_shm] releasePool: pool_id={} deferred ({} active buffers)\n", .{pool_id, refs});
                    return;
                }
                // No active buffers — release now
                if (pool.ptr) |ptr| {
                    const result = c.munmap(@constCast(@ptrCast(ptr)), pool.size);
                    if (result != 0) return error.MunmapFailed;
                }
                if (c.close(pool.fd) != 0) return error.CloseFailed;
                pool.active = false;
                pool.pending_release = false;
                return;
            }
        }
        return error.PoolNotFound;
    }
    // releasePool:end

    /// Release a buffer. Slot becomes available for reuse.
    /// If the buffer's pool had a deferred release pending, finalize it now if no other buffers remain.
    // releaseBuffer:start
    //   purpose: unref buffer and finalize deferred pool releases if applicable
    //   input: buffer_id
    //   output: error.BufferNotFound
    //   sideEffects: marks buffer slot inactive; if pool.pending_release and no remaining buffers: munmap, close
    pub fn releaseBuffer(self: *WlShmTracker, buffer_id: u32) !void {
        var released_pool_id: u32 = 0;
        for (self.buffers[0..self.buffer_hwm]) |*buf| {
            if (buf.buffer_id == buffer_id and buf.active) {
                released_pool_id = buf.pool_id;
                buf.active = false;
                break;
            }
        }
        if (released_pool_id == 0) return error.BufferNotFound;

        // Check if the pool had a deferred release and no more buffers reference it
        for (self.pools[0..self.pool_hwm]) |*pool| {
            if (pool.pool_id == released_pool_id and pool.active and pool.pending_release) {
                var refs: usize = 0;
                for (self.buffers[0..self.buffer_hwm]) |buf| {
                    if (buf.pool_id == released_pool_id and buf.active) refs += 1;
                }
                if (refs == 0) {
                    std.debug.print("[wl_shm] releaseBuffer: finalizing deferred pool_id={}\n", .{released_pool_id});
                    if (pool.ptr) |ptr| {
                        _ = c.munmap(@constCast(@ptrCast(ptr)), pool.size);
                    }
                    _ = c.close(pool.fd);
                    pool.active = false;
                    pool.pending_release = false;
                }
            }
        }
        return;
    }
    // releaseBuffer:end

    /// Release a surface. Slot becomes available for reuse.
    // releaseSurface:start
    //   purpose: unref surface and reclaim slot for reuse
    //   input: surface_id
    //   output: error.SurfaceNotFound
    //   sideEffects: marks surface slot inactive
    pub fn releaseSurface(self: *WlShmTracker, surface_id: u32) !void {
        for (self.surfaces[0..self.surface_hwm]) |*surf| {
            if (surf.surface_id == surface_id and surf.active) {
                surf.active = false;
                return;
            }
        }
        return error.SurfaceNotFound;
    }
    // releaseSurface:end

    /// Cleanup all resources (called at shutdown)
    // deinit:start
    //   purpose: cleanup all mmap'd regions and close fds (call on tracker shutdown)
    //   input: none
    //   output: none
    //   sideEffects: munmap (all active pools), close (all active pool fds), resets hwm counters
    pub fn deinit(self: *WlShmTracker) void {
        for (self.pools[0..self.pool_hwm]) |*pool| {
            if (pool.active and pool.ptr != null) {
                _ = c.munmap(@constCast(@ptrCast(pool.ptr.?)), pool.size);
                _ = c.close(pool.fd);
                pool.active = false;
            }
        }
        self.pool_hwm = 0;
        self.buffer_hwm = 0;
        self.surface_hwm = 0;
    }
    // deinit:end

    /// Debug: count active pools
    // activePoolCount:start
    //   purpose: count active pool slots (debug telemetry)
    //   input: none
    //   output: count of active pools
    //   sideEffects: none (read-only)
    pub fn activePoolCount(self: *const WlShmTracker) usize {
        var count: usize = 0;
        for (self.pools[0..self.pool_hwm]) |pool| {
            if (pool.active) count += 1;
        }
        return count;
    }
    // activePoolCount:end

    /// Debug: count active buffers
    // activeBufferCount:start
    //   purpose: count active buffer slots (debug telemetry)
    //   input: none
    //   output: count of active buffers
    //   sideEffects: none (read-only)
    pub fn activeBufferCount(self: *const WlShmTracker) usize {
        var count: usize = 0;
        for (self.buffers[0..self.buffer_hwm]) |buf| {
            if (buf.active) count += 1;
        }
        return count;
    }
    // activeBufferCount:end

    /// Debug: count active surfaces
    // activeSurfaceCount:start
    //   purpose: count active surface slots (debug telemetry)
    //   input: none
    //   output: count of active surfaces
    //   sideEffects: none (read-only)
    pub fn activeSurfaceCount(self: *const WlShmTracker) usize {
        var count: usize = 0;
        for (self.surfaces[0..self.surface_hwm]) |surf| {
            if (surf.active) count += 1;
        }
        return count;
    }
    // activeSurfaceCount:end

    /// Record damage for pending commit (from wl_surface.damage or damage_buffer)
    /// If called multiple times before commit, computes union of all damage rects
    // markDamage:start
    //   purpose: record or expand dirty region for pending surface commit
    //   input: x, y, w, h (damage rectangle in buffer coordinates, or w=-1 for full surface)
    //   output: none
    //   sideEffects: updates pending_damage_{x,y,w,h} fields (union if called multiple times)
    pub fn markDamage(self: *WlShmTracker, x: i32, y: i32, w: i32, h: i32) void {
        if (self.pending_damage_w < 0) {
            self.pending_damage_x = x;
            self.pending_damage_y = y;
            self.pending_damage_w = w;
            self.pending_damage_h = h;
        } else {
            const x2 = @max(self.pending_damage_x + self.pending_damage_w, x + w);
            const y2 = @max(self.pending_damage_y + self.pending_damage_h, y + h);
            self.pending_damage_x = @min(self.pending_damage_x, x);
            self.pending_damage_y = @min(self.pending_damage_y, y);
            self.pending_damage_w = x2 - self.pending_damage_x;
            self.pending_damage_h = y2 - self.pending_damage_y;
        }
    }
    // markDamage:end

    /// Consume and reset pending damage (called by getLatestFrame)
    // consumeDamage:start
    //   purpose: snapshot and clear pending damage state
    //   input: none
    //   output: struct { x, y, w, h: i32 } with current damage rect
    //   sideEffects: resets pending_damage_{x,y,w,h} to initial state (w=-1)
    fn consumeDamage(self: *WlShmTracker) struct { x: i32, y: i32, w: i32, h: i32 } {
        const x = self.pending_damage_x;
        const y = self.pending_damage_y;
        const w = self.pending_damage_w;
        const h = self.pending_damage_h;
        self.pending_damage_x = 0;
        self.pending_damage_y = 0;
        self.pending_damage_w = -1;
        self.pending_damage_h = -1;
        return .{ .x = x, .y = y, .w = w, .h = h };
    }
    // consumeDamage:end

    /// Record a surface commit (called from processClientMessage on wl_surface.commit)
    // markCommit:start
    //   purpose: flag surface as having pending commit (frame ready for capture)
    //   input: surface_id
    //   output: none
    //   sideEffects: sets pending_commit_surface and has_pending_commit flag
    pub fn markCommit(self: *WlShmTracker, surface_id: u32) void {
        self.pending_commit_surface = surface_id;
        self.has_pending_commit = true;
    }
    // markCommit:end

    /// Consume the latest committed frame (zero-copy, returns slice of mmap'd pool).
    /// Returns null if no commit has occurred since last call.
    // getLatestFrame:start
    //   purpose: extract latest committed surface frame with pixel data and damage info
    //   input: none
    //   output: FrameCapture struct (zero-copy slice of mmap'd pool), or null if no commit pending
    //   sideEffects: fstat (refreshes pool.backing to detect foot's late ftruncate), consumeDamage (clears damage state)
    pub fn getLatestFrame(self: *WlShmTracker) ?FrameCapture {
        // START_GET_LATEST_FRAME_VALIDATE_COMMIT
        if (!self.has_pending_commit) {
            std.debug.print("[getLatestFrame] no pending commit\n", .{});
            return null;
        }
        self.has_pending_commit = false;
        const sid = self.pending_commit_surface;
        std.debug.print("[getLatestFrame] processing surface_id={}\n", .{sid});
        // END_GET_LATEST_FRAME_VALIDATE_COMMIT

        // START_GET_LATEST_FRAME_RESOLVE_BUFFER
        const buffer_id = blk: {
            for (self.surfaces[0..self.surface_hwm]) |surf| {
                if (surf.surface_id == sid and surf.active) {
                    if (surf.attached_buffer) |bid| {
                        std.debug.print("[getLatestFrame] found buffer_id={}\n", .{bid});
                        break :blk bid;
                    } else {
                        std.debug.print("[getLatestFrame] no attached buffer for surface\n", .{});
                        return null;
                    }
                }
            }
            std.debug.print("[getLatestFrame] surface not found in list\n", .{});
            return null;
        };
        // END_GET_LATEST_FRAME_RESOLVE_BUFFER

        // START_GET_LATEST_FRAME_RESOLVE_BUFFER_METADATA
        const buf = blk: {
            for (self.buffers[0..self.buffer_hwm]) |b| {
                if (b.buffer_id == buffer_id and b.active) {
                    std.debug.print("[getLatestFrame] found buffer pool_id={} stride={} w={} h={}\n", .{b.pool_id, b.stride, b.width, b.height});
                    break :blk b;
                }
            }
            std.debug.print("[getLatestFrame] buffer not found or not active\n", .{});
            return null;
        };
        // END_GET_LATEST_FRAME_RESOLVE_BUFFER_METADATA

        // START_GET_LATEST_FRAME_RESOLVE_POOL
        const pool_ptr: *ShmPool = blk: {
            for (self.pools[0..self.pool_hwm]) |*p| {
                if (p.pool_id == buf.pool_id and p.active) {
                    break :blk p;
                }
            }
            std.debug.print("[getLatestFrame] pool not found or not active\n", .{});
            return null;
        };
        // END_GET_LATEST_FRAME_RESOLVE_POOL

        // START_GET_LATEST_FRAME_UPDATE_BACKING
        // Refresh backing via fstat — foot calls ftruncate AFTER create_pool, so backing
        // at addPool time may be smaller than by commit time. One syscall per frame is fine.
        var st: c.struct_stat = std.mem.zeroes(c.struct_stat);
        const fstat_ret = c.fstat(pool_ptr.fd, &st);
        std.debug.print("[getLatestFrame] fstat pool_id={} fd={} ret={} st_size={}\n",
            .{pool_ptr.pool_id, pool_ptr.fd, fstat_ret, st.st_size});
        if (fstat_ret == 0) {
            const current_size: usize = @intCast(@max(0, st.st_size));
            if (current_size > pool_ptr.backing) {
                std.debug.print("[getLatestFrame] pool_id={} backing grown {} → {}\n",
                    .{pool_ptr.pool_id, pool_ptr.backing, current_size});
                pool_ptr.backing = @min(pool_ptr.size, current_size);
            }
        }
        std.debug.print("[getLatestFrame] found pool ptr={} size={} backing={}\n",
            .{@intFromPtr(pool_ptr.ptr), pool_ptr.size, pool_ptr.backing});
        // END_GET_LATEST_FRAME_UPDATE_BACKING

        // START_GET_LATEST_FRAME_BOUNDS_CHECK
        const ptr = pool_ptr.ptr orelse {
            std.debug.print("[getLatestFrame] pool ptr is null\n", .{});
            return null;
        };
        const pixel_bytes: usize = @as(usize, buf.stride) * @as(usize, buf.height);
        // Check against pool.backing (fstat-refreshed actual size).
        if (buf.offset + pixel_bytes > pool_ptr.backing) {
            std.debug.print("[getLatestFrame] pixel data exceeds pool backing: offset={} + bytes={} > backing={} (declared={})\n",
                .{buf.offset, pixel_bytes, pool_ptr.backing, pool_ptr.size});
            return null;
        }
        // END_GET_LATEST_FRAME_BOUNDS_CHECK

        // START_GET_LATEST_FRAME_CONSTRUCT_RESULT
        const dmg = self.consumeDamage();
        return FrameCapture{
            .surface_id = sid,
            .width  = @intCast(@min(buf.width,  std.math.maxInt(u16))),
            .height = @intCast(@min(buf.height, std.math.maxInt(u16))),
            .stride = @intCast(@min(buf.stride, std.math.maxInt(u16))),
            .format = @intFromEnum(buf.format),
            .pixels = (ptr + buf.offset)[0..pixel_bytes],
            .damage_x = dmg.x,
            .damage_y = dmg.y,
            .damage_w = dmg.w,
            .damage_h = dmg.h,
        };
        // END_GET_LATEST_FRAME_CONSTRUCT_RESULT
    }
    // getLatestFrame:end

    /// Get buffer dimensions for a surface for pixel frame transmission
    // getBufferDimensions:start
    //   purpose: fetch buffer dimensions in BufferDims struct for frame transmission
    //   input: surface_id
    //   output: BufferDims with width/height/stride/format, or error if surface/buffer not found
    //   sideEffects: none (read-only)
    pub fn getBufferDimensions(self: *const WlShmTracker, surface_id: u32) !BufferDims {
        const buffer_id = blk: {
            for (self.surfaces[0..self.surface_hwm]) |surf| {
                if (surf.surface_id == surface_id and surf.active) {
                    break :blk surf.attached_buffer orelse return error.NoAttachedBuffer;
                }
            }
            return error.SurfaceNotFound;
        };

        for (self.buffers[0..self.buffer_hwm]) |buf| {
            if (buf.buffer_id == buffer_id and buf.active) {
                return BufferDims{
                    .width = @intCast(buf.width),
                    .height = @intCast(buf.height),
                    .stride = @intCast(buf.stride),
                    .format = @intFromEnum(buf.format),
                };
            }
        }
        return error.BufferNotFound;
    }
    // getBufferDimensions:end
};

/// Errors that can occur during SHM tracking
pub const WlShmError = error{
    TooManyPools,
    TooManyBuffers,
    TooManySurfaces,
    MmapFailed,
    MunmapFailed,
    CloseFailed,
    PoolNotFound,
    BufferNotFound,
    SurfaceNotFound,
    PoolNotMapped,
    NoAttachedBuffer,
    BufferOutOfBounds,
};
