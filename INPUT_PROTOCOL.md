# bsdOS Input Protocol

## Socket Location
- **Path:** `/tmp/wayland-run/input.sock`
- **Direction:** bsdos-core → wayland-tunnel
- **Mode:** 0o666 (world-readable, world-writable)

## Wire Format
Each message consists of:
```
[type: u8][payload: N bytes]
```

The transport is a Unix `SOCK_STREAM`, so read boundaries are not message
boundaries. `wayland-tunnel` must frame events by length:

- keyboard frame: 7 bytes total
- pointer frame: 18 bytes total

Partial frames stay buffered. Coalesced frames are drained one by one.

### Type 0: Keyboard Event
```
[type: 0x00]
[key_code: u32 LE]
[action: u8]
[modifiers: u8]
```

**action values:**
- `0x00` = key released (up)
- `0x01` = key pressed (down)
- `0x02` = key repeat

**modifiers bitfield:**
- Bit 0: Shift
- Bit 1: Control (Ctrl)
- Bit 2: Alt
- Bit 3: Super (Command)
- Bit 4: Caps Lock
- Bit 5: Num Lock

### Type 1: Pointer Event
```
[type: 0x01]
[x: f32 LE]           // absolute surface coordinate, pixels
[y: f32 LE]
[buttons: u8]         // bitmask: bit 0=left, 1=right, 2=middle
[scroll_x: f32 LE]    // accumulated scroll delta
[scroll_y: f32 LE]
```

## Zenoh Keys (Input Source)

**Keyboard events from Mac viewer:**
```
bsdos/input/keyboard → [key_code: u32 LE][action: u8][modifiers: u8]
```

**Pointer events from Mac viewer:**
```
bsdos/input/pointer → [x: f32 LE][y: f32 LE][buttons: u8][scroll_x: f32 LE][scroll_y: f32 LE]
```

`x`/`y` are absolute surface coordinates after the Mac-side Y-axis flip, not
relative deltas. `buttons` uses bit 0=left, bit 1=right, bit 2=middle.

## Client Behavior

1. wayland-tunnel connects to `/tmp/wayland-run/input.sock`
2. Reads bytes from the stream socket and frames messages by fixed event length
3. Routes to Wayland interfaces:
   - type=0 → `wl_keyboard.key` (Wayland protocol)
   - type=1 → `wl_pointer` motion + buttons (Wayland protocol)

## Retry Logic

- bsdos-core retries every 1s on any bridge error
- Socket accept errors logged but do not kill bridge
- Client disconnections silently handled (retained in Vec, dropped on write fail)

## Test

```sh
make wayland-input-test
```

This covers partial keyboard frames, coalesced pointer frames, and pointer
button release tracking.
