// START_AI_HEADER
// MODULE: wayland-tunnel/src/input.zig
// PURPOSE: Inject keyboard and pointer events directly into a Wayland client's socket
// INTENT: Simulate a real wl_seat for Firefox/foot without a physical seat in cage headless.
//         Events arrive from bsdos-core (via input.sock) and are re-encoded as Wayland
//         protocol messages sent directly on client_fd.
// DEPENDENCIES: c.zig (sendmsg, mkstemp, write, unlink, close), stream.zig (logEvent pattern)
// PUBLIC_API:
//   sendKeymap(client_fd, kb_id) — send wl_keyboard.keymap (opcode 0) with XKB_V1 fd via SCM_RIGHTS
//   handleInputEvent(client_fd, data, state) — dispatch keyboard/pointer event bytes from input.sock
//   InputFrameBuffer — accumulator for partial input socket reads
//   InputState — per-relay-thread state: ids, flags, focused_surface_id
// START_INVARIANTS
//   - sendKeymap() MUST be called exactly once after kb_id is captured, before any key events
//   - focused_surface_id MUST be non-zero before sending wl_pointer.enter or wl_keyboard.enter;
//     passing surface=0 is a Wayland protocol error that crashes libwayland clients (Firefox)
//   - CMSG layout on FreeBSD 64-bit: sizeof(cmsghdr)=12, CMSG_ALIGN=8 → CMSG_HDR_ALIGNED=16,
//     CMSG_SPACE(sizeof(int))=24, CMSG_LEN(sizeof(int))=20; fd is at byte offset 16
//     (NOT offset 12 — that was the original bug)
//   - wl_keyboard.enter opcode = 1 (NOT 0 — opcode 0 is keymap; was another bug source)
//   - Input event format from bsdos-core socket:
//       keyboard: [type=0x00][keycode:u32 LE][action:u8][mods:u8][pad:1] = 7 bytes
//       pointer:  [type=0x01][x:f32 LE][y:f32 LE][buttons:u32 LE][scroll_x:f32][scroll_y:f32] = 18 bytes
// END_INVARIANTS
// END_AI_HEADER

pub const std = @import("std");
pub const c = @import("c").c;
pub const stream_mod = @import("stream");

// logEvent:start
//   purpose: flush-on-write debug
//   sideEffects: stderr + fflush
fn logEvent(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt, args);
    _ = c.fflush(null);
}
// logEvent:end

pub const KEYBOARD_EVENT_LEN: usize = 7;
pub const POINTER_EVENT_LEN: usize = 18;
pub const MAX_INPUT_EVENT_LEN: usize = POINTER_EVENT_LEN;

// inputEventLen:start
//   purpose: return expected byte length for event type
//   output: 7 for keyboard, 18 for pointer, null for unknown
//   sideEffects: none
fn inputEventLen(event_type: u8) ?usize {
    return switch (event_type) {
        0 => KEYBOARD_EVENT_LEN,
        1 => POINTER_EVENT_LEN,
        else => null,
    };
}
// inputEventLen:end

pub const InputFrameBuffer = struct {
    buf: [MAX_INPUT_EVENT_LEN * 4]u8,
    len: usize,

    // InputFrameBuffer.init:start
    //   purpose: zero-initialize frame accumulator
    //   sideEffects: none
    pub fn init() InputFrameBuffer {
        return .{
            .buf = [_]u8{0} ** (MAX_INPUT_EVENT_LEN * 4),
            .len = 0,
        };
    }
    // InputFrameBuffer.init:end

    // InputFrameBuffer.bufferedLen:start
    //   purpose: return count of buffered bytes
    //   sideEffects: none
    pub fn bufferedLen(self: *const InputFrameBuffer) usize {
        return self.len;
    }
    // InputFrameBuffer.bufferedLen:end

    // InputFrameBuffer.pushBytes:start
    //   purpose: append bytes to buffer, drain complete frames
    //   sideEffects: calls handleInputEvent per complete frame, logs on overflow
    pub fn pushBytes(
        self: *InputFrameBuffer,
        client_fd: c_int,
        bytes: []const u8,
        state: *InputState,
    ) void {
        for (bytes) |byte| {
            if (self.len == self.buf.len) {
                std.debug.print("[tunnel] Input frame buffer overflow; dropping {} buffered bytes\n", .{self.len});
                self.len = 0;
            }
            self.buf[self.len] = byte;
            self.len += 1;
            self.drain(client_fd, state);
        }
    }
    // InputFrameBuffer.pushBytes:end

    // InputFrameBuffer.drain:start
    //   purpose: dispatch all complete frames from buffer front
    //   sideEffects: calls handleInputEvent, calls dropPrefix
    fn drain(self: *InputFrameBuffer, client_fd: c_int, state: *InputState) void {
        while (self.len > 0) {
            const frame_len = inputEventLen(self.buf[0]) orelse {
                std.debug.print("[tunnel] Input frame unknown type=0x{x:02}; dropping one byte\n", .{self.buf[0]});
                self.dropPrefix(1);
                continue;
            };

            if (self.len < frame_len) return;

            handleInputEvent(client_fd, self.buf[0..frame_len], state);
            self.dropPrefix(frame_len);
        }
    }
    // InputFrameBuffer.drain:end

    // InputFrameBuffer.dropPrefix:start
    //   purpose: remove count bytes from front of buffer via memmove
    //   sideEffects: modifies buf[] in-place
    fn dropPrefix(self: *InputFrameBuffer, count: usize) void {
        if (count >= self.len) {
            self.len = 0;
            return;
        }
        const remaining = self.len - count;
        std.mem.copyForwards(u8, self.buf[0..remaining], self.buf[count..self.len]);
        self.len = remaining;
    }
    // InputFrameBuffer.dropPrefix:end
};

// sendPointerButton:start
//   purpose: inject wl_pointer.button event to client
//   input: pointer_id, button (BTN_LEFT=0x110 etc.), state (0=release 1=press)
//   sideEffects: writeExact to client_fd
pub fn sendPointerButton(client_fd: c_int, pointer_id: u32, button: u32, state: u32) void {
    const POINTER_BUTTON_OPCODE: u16 = 3;
    const msg_size: u16 = 24;
    var btn_event: [24]u8 = undefined;

    std.mem.writeInt(u32, btn_event[0..4], pointer_id, .little);
    std.mem.writeInt(u32, btn_event[4..8], (@as(u32, msg_size) << 16) | POINTER_BUTTON_OPCODE, .little);
    std.mem.writeInt(u32, btn_event[8..12], 0, .little);
    std.mem.writeInt(u32, btn_event[12..16], 0, .little);
    std.mem.writeInt(u32, btn_event[16..20], button, .little);
    std.mem.writeInt(u32, btn_event[20..24], state, .little);

    if (stream_mod.writeExact(client_fd, &btn_event)) {
        std.debug.print("[tunnel] Injected pointer button: btn={} state={}\n", .{ button, state });
    } else {
        std.debug.print("[tunnel] Failed to inject pointer button\n", .{});
    }
}
// sendPointerButton:end

test "InputFrameBuffer handles partial keyboard frame" {
    var state = InputState.init();
    var framer = InputFrameBuffer.init();
    const frame = [_]u8{ 0x00, 30, 0, 0, 0, 1, 0 };

    framer.pushBytes(-1, frame[0..3], &state);
    try std.testing.expectEqual(@as(usize, 3), framer.bufferedLen());

    framer.pushBytes(-1, frame[3..], &state);
    try std.testing.expectEqual(@as(usize, 0), framer.bufferedLen());
}

test "InputFrameBuffer drains coalesced pointer frames" {
    var state = InputState.init();
    var framer = InputFrameBuffer.init();
    const one = [_]u8{
        0x01,
        0, 0, 0xc8, 0x42,
        0, 0, 0x48, 0x42,
        0x00,
        0, 0, 0, 0,
        0, 0, 0, 0,
    };
    var two: [POINTER_EVENT_LEN * 2]u8 = undefined;
    @memcpy(two[0..POINTER_EVENT_LEN], &one);
    @memcpy(two[POINTER_EVENT_LEN..], &one);

    framer.pushBytes(-1, &two, &state);
    try std.testing.expectEqual(@as(usize, 0), framer.bufferedLen());
}

test "InputFrameBuffer tracks pointer button release frames" {
    var state = InputState.init();
    state.pointer_id = 1;
    var framer = InputFrameBuffer.init();
    var down = [_]u8{
        0x01,
        0, 0, 0xc8, 0x42,
        0, 0, 0x48, 0x42,
        0x01,
        0, 0, 0, 0,
        0, 0, 0, 0,
    };
    var up = down;
    up[9] = 0x00;

    framer.pushBytes(-1, &down, &state);
    try std.testing.expectEqual(@as(u8, 0x01), state.pointer_buttons);

    framer.pushBytes(-1, &up, &state);
    try std.testing.expectEqual(@as(u8, 0x00), state.pointer_buttons);
}

// sendPointerAxis:start
//   purpose: inject wl_pointer.axis + axis_stop events for scroll
//   sideEffects: writeExact to client_fd (up to 4 messages for x+y axes)
pub fn sendPointerAxis(client_fd: c_int, pointer_id: u32, scroll_x: f32, scroll_y: f32) void {
    const POINTER_AXIS_OPCODE: u16 = 8;
    const POINTER_AXIS_STOP_OPCODE: u16 = 9;
    const axis_msg_size: u16 = 20;
    const axis_stop_size: u16 = 16;

    if (scroll_y != 0) {
        var axis_event: [20]u8 = undefined;
        std.mem.writeInt(u32, axis_event[0..4], pointer_id, .little);
        std.mem.writeInt(u32, axis_event[4..8], (@as(u32, axis_msg_size) << 16) | POINTER_AXIS_OPCODE, .little);
        std.mem.writeInt(u32, axis_event[8..12], 0, .little);
        std.mem.writeInt(u32, axis_event[12..16], 0, .little);
        const axis_value: i32 = @intFromFloat(scroll_y * 256.0);
        std.mem.writeInt(i32, axis_event[16..20], axis_value, .little);

        if (stream_mod.writeExact(client_fd, &axis_event)) {
            std.debug.print("[tunnel] Injected pointer axis_y={d:.1}\n", .{scroll_y});
        }

        var axis_stop: [16]u8 = undefined;
        std.mem.writeInt(u32, axis_stop[0..4], pointer_id, .little);
        std.mem.writeInt(u32, axis_stop[4..8], (@as(u32, axis_stop_size) << 16) | POINTER_AXIS_STOP_OPCODE, .little);
        std.mem.writeInt(u32, axis_stop[8..12], 0, .little);
        std.mem.writeInt(u32, axis_stop[12..16], 0, .little);
        _ = stream_mod.writeExact(client_fd, &axis_stop);
    }

    if (scroll_x != 0) {
        var axis_event: [20]u8 = undefined;
        std.mem.writeInt(u32, axis_event[0..4], pointer_id, .little);
        std.mem.writeInt(u32, axis_event[4..8], (@as(u32, axis_msg_size) << 16) | POINTER_AXIS_OPCODE, .little);
        std.mem.writeInt(u32, axis_event[8..12], 0, .little);
        std.mem.writeInt(u32, axis_event[12..16], 1, .little);
        const axis_value: i32 = @intFromFloat(scroll_x * 256.0);
        std.mem.writeInt(i32, axis_event[16..20], axis_value, .little);

        if (stream_mod.writeExact(client_fd, &axis_event)) {
            std.debug.print("[tunnel] Injected pointer axis_x={d:.1}\n", .{scroll_x});
        }

        var axis_stop: [16]u8 = undefined;
        std.mem.writeInt(u32, axis_stop[0..4], pointer_id, .little);
        std.mem.writeInt(u32, axis_stop[4..8], (@as(u32, axis_stop_size) << 16) | POINTER_AXIS_STOP_OPCODE, .little);
        std.mem.writeInt(u32, axis_stop[8..12], 0, .little);
        std.mem.writeInt(u32, axis_stop[12..16], 1, .little);
        _ = stream_mod.writeExact(client_fd, &axis_stop);
    }
}
// sendPointerAxis:end

pub const InputState = struct {
    keyboard_id: u32,
    pointer_id: u32,
    keymap_sent: bool,
    keyboard_enter_sent: bool,
    pointer_enter_sent: bool,
    focused_surface_id: u32,
    cursor_x: f32,
    cursor_y: f32,
    pointer_buttons: u8,

    // InputState.init:start
    //   purpose: zero-initialize per-relay-thread input state
    //   sideEffects: none
    pub fn init() InputState {
        return .{
            .keyboard_id = 0,
            .pointer_id = 0,
            .keymap_sent = false,
            .keyboard_enter_sent = false,
            .pointer_enter_sent = false,
            .focused_surface_id = 0,
            .cursor_x = 0.0,
            .cursor_y = 0.0,
            .pointer_buttons = 0,
        };
    }
    // InputState.init:end
};

// CMSG layout constants for SCM_RIGHTS (1 fd) on 64-bit FreeBSD.
// CMSG_ALIGN uses sizeof(long)=8; cmsghdr is 12 bytes → padded to 16.
const CMSG_ALIGN_SZ: usize = @sizeOf(c_long);
const CMSG_HDR_ALIGNED: usize = (@sizeOf(c.cmsghdr) + CMSG_ALIGN_SZ - 1) & ~(CMSG_ALIGN_SZ - 1);
const CMSG_DATA_ALIGNED: usize = (@sizeOf(c_int) + CMSG_ALIGN_SZ - 1) & ~(CMSG_ALIGN_SZ - 1);
const CMSG_SPACE_1FD: usize = CMSG_HDR_ALIGNED + CMSG_DATA_ALIGNED; // = 24
const CMSG_LEN_1FD: usize = CMSG_HDR_ALIGNED + @sizeOf(c_int);      // = 20

// sendKeymap:start
//   purpose: send wl_keyboard.keymap(XKB_V1) with keymap fd via SCM_RIGHTS
//   sideEffects: mkstemp+unlink+write (creates anonymous temp file), sendmsg with SCM_RIGHTS fd, close km_fd
/// Send wl_keyboard.keymap(XKB_V1) to client_fd immediately after kb_id is captured.
/// Creates an anonymous temp file with a minimal US-QWERTY keymap, forwards the fd
/// via SCM_RIGHTS so the client can mmap it.
pub fn sendKeymap(client_fd: c_int, kb_id: u32) bool {
    const keymap_str =
        "xkb_keymap {\n" ++
        "  xkb_keycodes  { include \"evdev+aliases(qwerty)\" };\n" ++
        "  xkb_types     { include \"complete\" };\n" ++
        "  xkb_compat    { include \"complete\" };\n" ++
        "  xkb_symbols   { include \"pc+us+inet(evdev)\" };\n" ++
        "  xkb_geometry  { include \"pc(pc104)\" };\n" ++
        "};\n\x00"; // null terminator required by libxkbcommon
    const keymap_size: u32 = keymap_str.len;

    // mkstemp needs a mutable null-terminated template
    const tmpname = "/tmp/.bsdos-km-XXXXXX";
    var tpl: [tmpname.len + 1]u8 = undefined;
    @memcpy(tpl[0..tmpname.len], tmpname);
    tpl[tmpname.len] = 0;

    const km_fd = c.mkstemp(@as([*c]u8, @ptrCast(&tpl)));
    if (km_fd < 0) {
        std.debug.print("[tunnel] sendKeymap: mkstemp failed\n", .{});
        return false;
    }
    _ = c.unlink(@as([*c]const u8, @ptrCast(&tpl))); // anonymous after unlink

    const written = c.write(km_fd, @as(?*const anyopaque, @ptrCast(keymap_str.ptr)), @as(usize, keymap_size));
    if (written < 0 or @as(usize, @intCast(written)) < keymap_size) {
        _ = c.close(km_fd);
        std.debug.print("[tunnel] sendKeymap: write failed\n", .{});
        return false;
    }

    // wl_keyboard.keymap(format=XKB_V1=1, fd, size)
    var msg: [16]u8 = undefined;
    std.mem.writeInt(u32, msg[0..4], kb_id, .little);
    std.mem.writeInt(u32, msg[4..8], (@as(u32, 16) << 16) | 0, .little);
    std.mem.writeInt(u32, msg[8..12], 1, .little); // XKB_V1
    std.mem.writeInt(u32, msg[12..16], keymap_size, .little);

    var iov = c.iovec{
        .iov_base = @ptrCast(&msg),
        .iov_len = msg.len,
    };
    var cmsg_buf: [CMSG_SPACE_1FD]u8 align(@alignOf(c_long)) = [_]u8{0} ** CMSG_SPACE_1FD;
    var mhdr = std.mem.zeroes(c.msghdr);
    mhdr.msg_iov = &iov;
    mhdr.msg_iovlen = 1;
    mhdr.msg_control = @ptrCast(&cmsg_buf);
    mhdr.msg_controllen = CMSG_SPACE_1FD;

    const cmsg: *c.cmsghdr = @ptrCast(@alignCast(&cmsg_buf));
    cmsg.cmsg_len = @intCast(CMSG_LEN_1FD);
    cmsg.cmsg_level = c.SOL_SOCKET;
    cmsg.cmsg_type = c.SCM_RIGHTS;
    const fdp: *c_int = @ptrCast(@alignCast(cmsg_buf[CMSG_HDR_ALIGNED..].ptr));
    fdp.* = km_fd;

    const ret = c.sendmsg(client_fd, &mhdr, 0);
    _ = c.close(km_fd);

    if (ret < 0) {
        std.debug.print("[tunnel] sendKeymap: sendmsg failed\n", .{});
        return false;
    }
    std.debug.print("[tunnel] Sent wl_keyboard.keymap kb_id={} size={}\n", .{kb_id, keymap_size});
    return true;
}
// sendKeymap:end

pub fn handleInputEvent(
    client_fd: c_int,
    input_buf: []const u8,
    state: *InputState,
) void {
    const n = input_buf.len;
    if (n == 0) return;

    const event_type = input_buf[0];

    if (event_type == 0 and n >= 7) {
        const key_code = std.mem.readInt(u32, input_buf[1..5], .little);
        const action = input_buf[5];
        std.debug.print("[tunnel] Input key: code={} action={}\n", .{ key_code, action });

        if (state.keyboard_id > 0) {
            if (!state.keyboard_enter_sent) {
                // Keymap already sent at kb_id capture time via sendKeymap().
                // Send enter to establish focus on the surface.
                const KEYBOARD_ENTER_OPCODE: u16 = 1;
                const enter_msg_size: u16 = 20;
                var kb_enter: [20]u8 = undefined;
                std.mem.writeInt(u32, kb_enter[0..4], state.keyboard_id, .little);
                std.mem.writeInt(u32, kb_enter[4..8], (@as(u32, enter_msg_size) << 16) | KEYBOARD_ENTER_OPCODE, .little);
                std.mem.writeInt(u32, kb_enter[8..12], 0, .little); // serial
                std.mem.writeInt(u32, kb_enter[12..16], state.focused_surface_id, .little); // surface
                std.mem.writeInt(u32, kb_enter[16..20], 0, .little); // keys wl_array size=0

                if (stream_mod.writeExact(client_fd, &kb_enter)) {
                    state.keyboard_enter_sent = true;
                    std.debug.print("[tunnel] Sent wl_keyboard.enter surface={}\n", .{state.focused_surface_id});
                }

                // wl_keyboard.modifiers — initialize modifier state to 0
                const KEYBOARD_MODIFIERS_OPCODE: u16 = 4;
                const mods_msg_size: u16 = 28;
                var kb_mods: [28]u8 = undefined;
                std.mem.writeInt(u32, kb_mods[0..4], state.keyboard_id, .little);
                std.mem.writeInt(u32, kb_mods[4..8], (@as(u32, mods_msg_size) << 16) | KEYBOARD_MODIFIERS_OPCODE, .little);
                std.mem.writeInt(u32, kb_mods[8..12], 0, .little);  // serial
                std.mem.writeInt(u32, kb_mods[12..16], 0, .little); // mods_depressed
                std.mem.writeInt(u32, kb_mods[16..20], 0, .little); // mods_latched
                std.mem.writeInt(u32, kb_mods[20..24], 0, .little); // mods_locked
                std.mem.writeInt(u32, kb_mods[24..28], 0, .little); // group
                _ = stream_mod.writeExact(client_fd, &kb_mods);
            }

            const KEYBOARD_KEY_OPCODE: u16 = 3;
            const msg_size: u16 = 24;
            var kb_event: [24]u8 = undefined;
            std.mem.writeInt(u32, kb_event[0..4], state.keyboard_id, .little);
            std.mem.writeInt(u32, kb_event[4..8], (@as(u32, msg_size) << 16) | KEYBOARD_KEY_OPCODE, .little);
            std.mem.writeInt(u32, kb_event[8..12], 0, .little);
            std.mem.writeInt(u32, kb_event[12..16], 0, .little);
            std.mem.writeInt(u32, kb_event[16..20], key_code, .little);
            std.mem.writeInt(u32, kb_event[20..24], @as(u32, action), .little);

            if (!stream_mod.writeExact(client_fd, &kb_event)) {
                std.debug.print("[tunnel] Failed to inject key event\n", .{});
            } else {
                std.debug.print("[tunnel] Injected key: code={} state={}\n", .{ key_code, action });
            }
        } else {
            std.debug.print("[tunnel] Cannot inject key: keyboard_id not bound yet\n", .{});
        }
    } else if (event_type == 1 and n >= 18) {
        const x_bits = std.mem.readInt(u32, input_buf[1..5], .little);
        const y_bits = std.mem.readInt(u32, input_buf[5..9], .little);
        const buttons = input_buf[9];
        const scroll_x_bits = std.mem.readInt(u32, input_buf[10..14], .little);
        const scroll_y_bits = std.mem.readInt(u32, input_buf[14..18], .little);

        const x: f32 = @bitCast(x_bits);
        const y: f32 = @bitCast(y_bits);
        const scroll_x: f32 = @bitCast(scroll_x_bits);
        const scroll_y: f32 = @bitCast(scroll_y_bits);

        state.cursor_x = x;
        state.cursor_y = y;

        std.debug.print("[tunnel] Input pointer: x={d:.1} y={d:.1} buttons=0x{x:02} scroll_x={d:.1} scroll_y={d:.1}\n", .{ x, y, buttons, scroll_x, scroll_y });

        if (state.pointer_id > 0) {
            if (!state.pointer_enter_sent) {
                // Guard: surface=0 is invalid and crashes Firefox. Wait until
                // focused_surface_id is known (set from frame.surface_id in relay).
                if (state.focused_surface_id == 0) {
                    std.debug.print("[tunnel] Cannot inject pointer enter: focused_surface_id not yet known\n", .{});
                } else {
                    const POINTER_ENTER_OPCODE: u16 = 0;
                    const enter_msg_size: u16 = 24;
                    var ptr_enter: [24]u8 = undefined;

                    std.mem.writeInt(u32, ptr_enter[0..4], state.pointer_id, .little);
                    std.mem.writeInt(u32, ptr_enter[4..8], (@as(u32, enter_msg_size) << 16) | POINTER_ENTER_OPCODE, .little);
                    std.mem.writeInt(u32, ptr_enter[8..12], 0, .little); // serial
                    std.mem.writeInt(u32, ptr_enter[12..16], state.focused_surface_id, .little);
                    const fx_enter: i32 = @intFromFloat(x * 256.0);
                    const fy_enter: i32 = @intFromFloat(y * 256.0);
                    std.mem.writeInt(i32, ptr_enter[16..20], fx_enter, .little);
                    std.mem.writeInt(i32, ptr_enter[20..24], fy_enter, .little);

                    if (stream_mod.writeExact(client_fd, &ptr_enter)) {
                        state.pointer_enter_sent = true;
                        std.debug.print("[tunnel] Sent wl_pointer.enter surface={}\n", .{state.focused_surface_id});
                    }
                }
            }

            const POINTER_MOTION_OPCODE: u16 = 2;
            const motion_msg_size: u16 = 24;
            var motion_msg: [24]u8 = undefined;

            std.mem.writeInt(u32, motion_msg[0..4], state.pointer_id, .little);
            std.mem.writeInt(u32, motion_msg[4..8], (@as(u32, motion_msg_size) << 16) | POINTER_MOTION_OPCODE, .little);
            std.mem.writeInt(u32, motion_msg[8..12], 0, .little);
            std.mem.writeInt(u32, motion_msg[12..16], 0, .little);
            const fx: i32 = @intFromFloat(x * 256.0);
            const fy: i32 = @intFromFloat(y * 256.0);
            std.mem.writeInt(i32, motion_msg[16..20], fx, .little);
            std.mem.writeInt(i32, motion_msg[20..24], fy, .little);

            if (!stream_mod.writeExact(client_fd, &motion_msg)) {
                std.debug.print("[tunnel] Failed to inject pointer motion\n", .{});
            } else {
                std.debug.print("[tunnel] Injected pointer motion: x={d:.1} y={d:.1}\n", .{x, y});
            }

            const changed_buttons = state.pointer_buttons ^ buttons;
            if (changed_buttons != 0) {
                const BTN_LEFT: u32 = 0x110;
                const BTN_RIGHT: u32 = 0x111;
                const BTN_MIDDLE: u32 = 0x112;

                if (changed_buttons & 0x01 != 0) {
                    sendPointerButton(client_fd, state.pointer_id, BTN_LEFT, if (buttons & 0x01 != 0) 1 else 0);
                }
                if (changed_buttons & 0x02 != 0) {
                    sendPointerButton(client_fd, state.pointer_id, BTN_RIGHT, if (buttons & 0x02 != 0) 1 else 0);
                }
                if (changed_buttons & 0x04 != 0) {
                    sendPointerButton(client_fd, state.pointer_id, BTN_MIDDLE, if (buttons & 0x04 != 0) 1 else 0);
                }
            }
            state.pointer_buttons = buttons;

            if (scroll_x != 0 or scroll_y != 0) {
                sendPointerAxis(client_fd, state.pointer_id, scroll_x, scroll_y);
            }
        } else {
            std.debug.print("[tunnel] Cannot inject pointer: pointer_id not bound yet\n", .{});
        }
    }
}
