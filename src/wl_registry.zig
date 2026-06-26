// START_AI_HEADER
// MODULE: wayland-tunnel/src/wl_registry.zig
// PURPOSE: Track Wayland global interface bindings (wl_seat, wl_compositor, xdg_wm_base)
// INTENT: Let relay.zig know which object IDs map to which interfaces, so it can
//         intercept get_pointer/get_keyboard and inject synthetic capabilities
// DEPENDENCIES: std (Zig standard library only — no syscalls, pure data tracking)
// PUBLIC_API:
//   WlInterface — enum of supported Wayland interfaces
//   WlObject — struct holding id, interface, parent_id, active status
//   WlRegistry — struct mapping object_id → interface name and parent relationships
//   WlRegistry.init() — initialize with wl_display=1 reserved
//   WlRegistry.register(id, iface, parent_id) → bool — record a new object
//   WlRegistry.findId(iface) → ?u32 — find first ID for given interface
//   WlRegistry.findAllIds(iface, out, 64) → u32 — find all IDs for interface
//   WlRegistry.getInterface(id) → WlInterface — retrieve interface by object ID
//   WlRegistry.get(id) → ?WlObject — retrieve full record by object ID
//   WlRegistry.unregister(id) → bool — mark object as inactive
//   WlRegistry.isActive(id) → bool — check if object ID is live
//   WlRegistry.parseInterface(name) → WlInterface — string → enum (for wl_registry.global event)
//   WlRegistry.interfaceName(iface) → []const u8 — enum → string (for debug output)
//   WlRegistry.activeCount() → u32 — count live objects
//   WlRegistry.validate() → bool — check for ID dups and parent existence
//   WlRegistry.clear() → void — reset to initial state
// START_INVARIANTS
//   - register() is idempotent: same id+iface never added twice (caller must prevent)
//   - Object IDs are never reused in a Wayland session (protocol guarantee)
//   - parent_id=0 means top-level (wl_display, wl_registry, wl_compositor, wl_shm, wl_seat)
//   - parent_id≠0 means derived (wl_buffer from wl_shm_pool; wl_surface from wl_compositor)
//   - getInterface(unknown_id) returns .unknown (never panics, caller handles null via isActive)
//   - validate() checks: no ID dups among active objects, all parent_ids exist or are 0
// END_INVARIANTS
// END_AI_HEADER

const std = @import("std");

/// Перечисление поддерживаемых Wayland интерфейсов
pub const WlInterface = enum {
    unknown,
    wl_display,
    wl_registry,
    wl_compositor,
    wl_shm,
    wl_shm_pool,
    wl_buffer,
    wl_surface,
    wl_callback,
    xdg_wm_base,
    xdg_surface,
    xdg_toplevel,
    wl_seat,
    wl_keyboard,
    wl_pointer,
};

/// Максимум отслеживаемых объектов одновременно
const MAX_OBJECTS = 256;

/// Запись об одном Wayland объекте
pub const WlObject = struct {
    id: u32,
    interface: WlInterface,
    parent_id: u32, // для производных (pool→shm, buffer→pool, surface→compositor)
    active: bool,
};

/// Реестр объектов Wayland
pub const WlRegistry = struct {
    objects: [MAX_OBJECTS]WlObject = [_]WlObject{
        .{
            .id = 0,
            .interface = .unknown,
            .parent_id = 0,
            .active = false,
        }
    } ** MAX_OBJECTS,
    count: u32 = 0,

    // init:start
    //   purpose: Initialize registry with wl_display=1 reserved
    //   input: none
    //   output: WlRegistry with count=1 and objects[0] = {id:1, interface:wl_display, parent_id:0, active:true}
    //   sideEffects: none
    /// Инициализировать реестр (wl_display=1 зарезервирован)
    pub fn init() WlRegistry {
        var self = WlRegistry{};
        _ = self.register(1, .wl_display, 0);
        return self;
    }
    // init:end

    // register:start
    //   purpose: Register a new Wayland object with given id, interface, and optional parent
    //   input: self (mutable), id (u32), iface (WlInterface), parent_id (u32, 0 for top-level)
    //   output: bool — true if registered, false if capacity full or id already exists
    //   sideEffects: increments self.count, modifies self.objects array to set one .active=true
    /// Зарегистрировать новый объект
    /// Возвращает true если успешно, false если нет места
    pub fn register(
        self: *WlRegistry,
        id: u32,
        iface: WlInterface,
        parent_id: u32,
    ) bool {
        if (self.count >= MAX_OBJECTS) return false;

        // Проверить, что ID не занят
        for (self.objects[0..self.count]) |obj| {
            if (obj.active and obj.id == id) return false;
        }

        // Найти первый свободный слот
        for (&self.objects) |*obj| {
            if (!obj.active) {
                obj.* = .{
                    .id = id,
                    .interface = iface,
                    .parent_id = parent_id,
                    .active = true,
                };
                self.count += 1;
                return true;
            }
        }

        return false;
    }
    // register:end

    // findId:start
    //   purpose: Search for first object ID matching given interface
    //   input: self (const), iface (WlInterface)
    //   output: ?u32 — first active object id for iface, or null if not found
    //   sideEffects: none
    /// Найти ID по интерфейсу (первый активный объект)
    pub fn findId(self: *const WlRegistry, iface: WlInterface) ?u32 {
        for (self.objects) |obj| {
            if (obj.active and obj.interface == iface) {
                return obj.id;
            }
        }
        return null;
    }
    // findId:end

    // findAllIds:start
    //   purpose: Collect all object IDs for a given interface into fixed output buffer
    //   input: self (const), iface (WlInterface), out (*[64]u32 pre-allocated output buffer)
    //   output: u32 — count of IDs written to out (0 to 64)
    //   sideEffects: none (caller-provided buffer)
    /// Найти все IDs объектов данного интерфейса (выходной буфер фиксированный)
    pub fn findAllIds(
        self: *const WlRegistry,
        iface: WlInterface,
        out: *[64]u32,
    ) u32 {
        var count: u32 = 0;
        for (self.objects) |obj| {
            if (obj.active and obj.interface == iface) {
                if (count >= 64) break;
                out[count] = obj.id;
                count += 1;
            }
        }
        return count;
    }
    // findAllIds:end

    // getInterface:start
    //   purpose: Retrieve interface type for object ID
    //   input: self (const), id (u32)
    //   output: WlInterface — .unknown if id not found, otherwise matched interface
    //   sideEffects: none
    /// Получить интерфейс по ID
    pub fn getInterface(self: *const WlRegistry, id: u32) WlInterface {
        for (self.objects) |obj| {
            if (obj.active and obj.id == id) {
                return obj.interface;
            }
        }
        return .unknown;
    }
    // getInterface:end

    // get:start
    //   purpose: Retrieve complete WlObject record for given ID
    //   input: self (const), id (u32)
    //   output: ?WlObject — full record if active and found, null otherwise
    //   sideEffects: none
    /// Получить полную запись по ID
    pub fn get(self: *const WlRegistry, id: u32) ?WlObject {
        for (self.objects) |obj| {
            if (obj.active and obj.id == id) {
                return obj;
            }
        }
        return null;
    }
    // get:end

    // unregister:start
    //   purpose: Mark object as inactive (simulate wl_registry.global_remove event)
    //   input: self (mutable), id (u32)
    //   output: bool — true if found and deactivated, false if id not found
    //   sideEffects: sets obj.active=false, decrements self.count
    /// Деактивировать объект (при удалении)
    pub fn unregister(self: *WlRegistry, id: u32) bool {
        for (&self.objects) |*obj| {
            if (obj.active and obj.id == id) {
                obj.active = false;
                if (self.count > 0) self.count -= 1;
                return true;
            }
        }
        return false;
    }
    // unregister:end

    // isActive:start
    //   purpose: Check if object ID exists and is currently active
    //   input: self (const), id (u32)
    //   output: bool — true if active, false otherwise
    //   sideEffects: none
    /// Проверить, активен ли объект
    pub fn isActive(self: *const WlRegistry, id: u32) bool {
        for (self.objects) |obj| {
            if (obj.id == id) return obj.active;
        }
        return false;
    }
    // isActive:end

    // parseInterface:start
    //   purpose: Parse Wayland interface name string to enum (for wl_registry.global event handler)
    //   input: name ([]const u8 — e.g., "wl_compositor", "wl_seat", "xdg_wm_base")
    //   output: WlInterface — matched enum value or .unknown if no match
    //   sideEffects: none
    /// Разобрать строку интерфейса в enum
    pub fn parseInterface(name: []const u8) WlInterface {
        return if (std.mem.eql(u8, name, "wl_display"))
            .wl_display
        else if (std.mem.eql(u8, name, "wl_registry"))
            .wl_registry
        else if (std.mem.eql(u8, name, "wl_compositor"))
            .wl_compositor
        else if (std.mem.eql(u8, name, "wl_shm"))
            .wl_shm
        else if (std.mem.eql(u8, name, "wl_shm_pool"))
            .wl_shm_pool
        else if (std.mem.eql(u8, name, "wl_buffer"))
            .wl_buffer
        else if (std.mem.eql(u8, name, "wl_surface"))
            .wl_surface
        else if (std.mem.eql(u8, name, "wl_callback"))
            .wl_callback
        else if (std.mem.eql(u8, name, "xdg_wm_base"))
            .xdg_wm_base
        else if (std.mem.eql(u8, name, "xdg_surface"))
            .xdg_surface
        else if (std.mem.eql(u8, name, "xdg_toplevel"))
            .xdg_toplevel
        else if (std.mem.eql(u8, name, "wl_seat"))
            .wl_seat
        else if (std.mem.eql(u8, name, "wl_keyboard"))
            .wl_keyboard
        else if (std.mem.eql(u8, name, "wl_pointer"))
            .wl_pointer
        else
            .unknown;
    }
    // parseInterface:end

    // interfaceName:start
    //   purpose: Convert WlInterface enum to human-readable string (for debug output)
    //   input: iface (WlInterface)
    //   output: []const u8 — string literal name (e.g., "wl_compositor", "unknown")
    //   sideEffects: none
    /// Получить строку имени интерфейса (для отладки)
    pub fn interfaceName(iface: WlInterface) []const u8 {
        return switch (iface) {
            .unknown => "unknown",
            .wl_display => "wl_display",
            .wl_registry => "wl_registry",
            .wl_compositor => "wl_compositor",
            .wl_shm => "wl_shm",
            .wl_shm_pool => "wl_shm_pool",
            .wl_buffer => "wl_buffer",
            .wl_surface => "wl_surface",
            .wl_callback => "wl_callback",
            .xdg_wm_base => "xdg_wm_base",
            .xdg_surface => "xdg_surface",
            .xdg_toplevel => "xdg_toplevel",
            .wl_seat => "wl_seat",
            .wl_keyboard => "wl_keyboard",
            .wl_pointer => "wl_pointer",
        };
    }
    // interfaceName:end

    // activeCount:start
    //   purpose: Count all currently active (non-deleted) objects in registry
    //   input: self (const)
    //   output: u32 — number of active objects (should match self.count)
    //   sideEffects: none
    /// Вернуть количество активных объектов
    pub fn activeCount(self: *const WlRegistry) u32 {
        var cnt: u32 = 0;
        for (self.objects) |obj| {
            if (obj.active) cnt += 1;
        }
        return cnt;
    }
    // activeCount:end

    // validate:start
    //   purpose: Perform integrity checks: no duplicate active IDs, all parent_ids exist or are 0
    //   input: self (const)
    //   output: bool — true if valid, false if duplicates or broken parent links
    //   sideEffects: none (uses stack-allocated seen array)
    /// Проверить целостность реестра (отладка)
    pub fn validate(self: *const WlRegistry) bool {
        var seen: [MAX_OBJECTS]u32 = undefined;
        var seen_count: u32 = 0;

        // Убедиться, что нет дублей ID
        for (self.objects) |obj| {
            if (!obj.active) continue;

            for (seen[0..seen_count]) |id| {
                if (id == obj.id) return false;
            }
            seen[seen_count] = obj.id;
            seen_count += 1;
        }

        // Все родители должны быть активны (кроме parent_id=0)
        for (self.objects) |obj| {
            if (!obj.active or obj.parent_id == 0) continue;

            var found = false;
            for (self.objects) |parent| {
                if (parent.active and parent.id == obj.parent_id) {
                    found = true;
                    break;
                }
            }
            if (!found) return false;
        }

        return true;
    }
    // validate:end

    // clear:start
    //   purpose: Reset registry to initial state (all objects inactive except wl_display=1)
    //   input: self (mutable)
    //   output: void
    //   sideEffects: clears all objects, re-registers wl_display at id=1, resets count
    /// Очистить реестр (сбросить на начальное состояние)
    pub fn clear(self: *WlRegistry) void {
        for (&self.objects) |*obj| {
            obj.* = .{
                .id = 0,
                .interface = .unknown,
                .parent_id = 0,
                .active = false,
            };
        }
        self.count = 0;
        // Re-register wl_display
        _ = self.register(1, .wl_display, 0);
    }
    // clear:end
};

/// Тесты (запуск: zig build-exe wl_registry.zig && ./wl_registry)
pub fn main() !void {
    var reg = WlRegistry.init();

    // Тест 1: регистрация объектов
    _ = reg.register(2, .wl_registry, 1);
    _ = reg.register(3, .wl_compositor, 1);
    _ = reg.register(4, .wl_shm, 1);

    std.debug.print("Registered 4 objects\n", .{});

    // Тест 2: поиск по интерфейсу
    if (reg.findId(.wl_shm)) |id| {
        std.debug.print("wl_shm found at ID: {}\n", .{id});
    }

    // Тест 3: получение интерфейса по ID
    const iface = reg.getInterface(4);
    std.debug.print("ID 4 is: {s}\n", .{WlRegistry.interfaceName(iface)});

    // Тест 4: парсинг строки
    const parsed = WlRegistry.parseInterface("wl_buffer");
    std.debug.print("Parsed wl_buffer: {s}\n", .{WlRegistry.interfaceName(parsed)});

    // Тест 5: регистрация производной (buffer из pool)
    _ = reg.register(5, .wl_shm_pool, 4);
    _ = reg.register(6, .wl_buffer, 5);
    std.debug.print("Registered pool and buffer\n", .{});

    // Тест 6: проверка целостности
    const valid = reg.validate();
    std.debug.print("Registry valid: {}\n", .{valid});

    // Тест 7: количество активных
    std.debug.print("Active objects: {}\n", .{reg.activeCount()});

    // Тест 8: удаление объекта
    const unregistered = reg.unregister(5);
    std.debug.print("Unregistered ID 5: {}\n", .{unregistered});
    std.debug.print("Active objects after delete: {}\n", .{reg.activeCount()});
}
