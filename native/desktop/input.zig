const std = @import("std");
const win = @import("win.zig").api;
const shortcuts = @import("shortcuts.zig");
const supportedBrowser = @import("../worker/rules.zig").supportedBrowser;

const keys = @import("../worker/keyboard.zig");
const KeyboardProcedure = *const fn (c_int, win.WPARAM, win.LPARAM) callconv(.winapi) win.LRESULT;
extern "user32" fn SetWindowsHookExW(c_int, KeyboardProcedure, win.HINSTANCE, win.DWORD) callconv(.winapi) win.HHOOK;

fn down(vk: u16) bool {
    return win.GetAsyncKeyState(vk) < 0;
}

fn modifierMask() u8 {
    var mask: u8 = 0;
    if (down(win.VK_CONTROL)) mask |= shortcuts.ctrl;
    if (down(win.VK_MENU)) mask |= shortcuts.alt;
    if (down(win.VK_SHIFT)) mask |= shortcuts.shift;
    if (down(win.VK_LWIN) or down(win.VK_RWIN)) mask |= shortcuts.windows;
    return mask;
}

const Context = struct {
    window: usize,
    browser: bool,
    stoppable: bool,
    suspended: bool = false,
};

const HookAcquisition = union(enum) {
    handle: win.HHOOK,
    win32_error: win.DWORD,
};

fn acquireKeyboardHook() HookAcquisition {
    return acquireKeyboardHookFor(0);
}

fn acquireKeyboardHookFor(thread: win.DWORD) HookAcquisition {
    const handle = SetWindowsHookExW(win.WH_KEYBOARD_LL, keyboardEvent, win.GetModuleHandleW(null), thread) orelse
        return .{ .win32_error = win.GetLastError() };
    return .{ .handle = handle };
}

pub const Hook = struct {
    handle: win.HHOOK = null,
    install_error_code: ?win.DWORD = null,
    tracker: shortcuts.Tracker = .{},
    context: *const fn () Context,
    enqueue: *const fn (shortcuts.Event) void,

    pub fn install(self: *Hook, bindings: shortcuts.Bindings) !void {
        return self.installWith(bindings, acquireKeyboardHook);
    }

    fn installWith(self: *Hook, bindings: shortcuts.Bindings, comptime acquire: fn () HookAcquisition) !void {
        if (active_hook == self) return;
        if (active_hook != null) return error.KeyboardHookAlreadyInstalled;
        self.handle = switch (acquire()) {
            .handle => |hook| hook,
            .win32_error => |code| {
                self.install_error_code = code;
                return error.InstallKeyboardHook;
            },
        };
        self.install_error_code = null;
        self.tracker = .{ .bindings = bindings };
        active_hook = self;
    }

    pub fn remove(self: *Hook) void {
        if (self.handle != null) _ = win.UnhookWindowsHookEx(self.handle);
        if (active_hook == self) active_hook = null;
        self.handle = null;
    }
};

pub const ShortcutContext = Context;
var active_hook: ?*Hook = null;

fn keyboardEvent(code: c_int, message: win.WPARAM, data: win.LPARAM) callconv(.winapi) win.LRESULT {
    if (code == win.HC_ACTION) {
        if (active_hook) |hook| {
            const event: *const win.KBDLLHOOKSTRUCT = @ptrFromInt(@as(usize, @bitCast(data)));
            if (event.dwExtraInfo != keys.input_marker and event.vkCode < 256) {
                const vk: u8 = @intCast(event.vkCode);
                const released = message == win.WM_KEYUP or message == win.WM_SYSKEYUP;
                const mask = if (released) 0 else modifierMask();
                const is_chord = for (hook.tracker.bindings) |binding| {
                    if (binding) |chord| if (shortcuts.matches(chord, vk, mask)) break true;
                } else false;
                const context = if (!released and is_chord) hook.context() else Context{ .window = 0, .browser = false, .stoppable = false };
                if (!context.suspended) {
                    const result = hook.tracker.key(vk, released, mask, context.window, context.browser, context.stoppable);
                    if (result.event) |shortcut| hook.enqueue(shortcut);
                    if (result.consume) return 1;
                }
            }
        }
    }
    return win.CallNextHookEx(null, code, message, data);
}

pub fn browser(window: win.HWND) ?[]const u8 {
    var pid: win.DWORD = 0;
    _ = win.GetWindowThreadProcessId(window, &pid);
    if (pid == 0) return null;
    const process = win.OpenProcess(win.PROCESS_QUERY_LIMITED_INFORMATION, 0, pid) orelse return null;
    defer _ = win.CloseHandle(process);
    var path: [32768]u16 = undefined;
    var size: win.DWORD = path.len;
    if (win.QueryFullProcessImageNameW(process, 0, &path, &size) == 0) return null;
    const start = if (std.mem.lastIndexOfScalar(u16, path[0..size], '\\')) |index| index + 1 else 0;
    var name: [16]u8 = undefined;
    if (size - start > name.len) return null;
    for (path[start..size], 0..) |code, i| {
        if (code > 0x7F) return null;
        name[i] = std.ascii.toLower(@intCast(code));
    }
    if (size - start < 4 or !std.mem.endsWith(u8, name[0 .. size - start], ".exe")) return null;
    return supportedBrowser(name[0 .. size - start - 4]);
}

pub fn insert(allocator: std.mem.Allocator, target: win.HWND, value: []const u8) !void {
    try keys.insert(allocator, @ptrCast(target), value);
}

pub fn clear(allocator: std.mem.Allocator, target: win.HWND) !void {
    try keys.clear(allocator, @ptrCast(target));
}

test "shared keyboard hook publishes bindings only after acquisition and retries once per owner" {
    const Fixture = struct {
        fn context() Context {
            return .{ .window = 0, .browser = false, .stoppable = false };
        }
        fn enqueue(_: shortcuts.Event) void {}
        fn denied() HookAcquisition {
            if (active_hook != null) @panic("the hook was published before acquisition");
            return .{ .win32_error = win.ERROR_ACCESS_DENIED };
        }
        fn rejectedByWindows() HookAcquisition {
            const result = acquireKeyboardHookFor(win.GetCurrentThreadId());
            if (result == .handle) {
                _ = win.UnhookWindowsHookEx(result.handle);
                @panic("Windows unexpectedly installed a thread-local low-level keyboard hook");
            }
            return result;
        }
        fn acquired() HookAcquisition {
            if (active_hook != null) @panic("the hook was published before acquisition");
            return .{ .handle = @ptrFromInt(1) };
        }
        fn noSecondAcquire() HookAcquisition {
            @panic("a previously installed hook must remain the only OS registration");
        }
    };
    const testing = std.testing;
    try testing.expect(active_hook == null);
    defer active_hook = null;
    var hook: Hook = .{ .context = Fixture.context, .enqueue = Fixture.enqueue };
    const before = try shortcuts.validate(shortcuts.default_keys);
    hook.tracker.replace(before);
    var updated = shortcuts.default_keys;
    updated[@intFromEnum(shortcuts.Action.palette)] = "^+q";
    updated[@intFromEnum(shortcuts.Action.shared1)] = "";
    const after = try shortcuts.validate(updated);

    try testing.expectError(error.InstallKeyboardHook, hook.installWith(after, Fixture.rejectedByWindows));
    try testing.expect(hook.handle == null and active_hook == null);
    try testing.expect((hook.install_error_code orelse 0) != 0);
    try testing.expectEqualDeep(before, hook.tracker.bindings);

    try testing.expectError(error.InstallKeyboardHook, hook.installWith(after, Fixture.denied));
    try testing.expectEqual(@as(?win.DWORD, win.ERROR_ACCESS_DENIED), hook.install_error_code);
    try testing.expect(hook.handle == null and active_hook == null);
    try testing.expectEqualDeep(before, hook.tracker.bindings);

    try hook.installWith(after, Fixture.acquired);
    try testing.expect(hook.handle != null and active_hook == &hook and hook.install_error_code == null);
    try testing.expectEqualDeep(after, hook.tracker.bindings);
    const owned = hook.handle;
    try hook.installWith(before, Fixture.noSecondAcquire);
    try testing.expectEqual(owned, hook.handle);
    try testing.expectEqualDeep(after, hook.tracker.bindings);
    var another: Hook = .{ .context = Fixture.context, .enqueue = Fixture.enqueue };
    try testing.expectError(error.KeyboardHookAlreadyInstalled, another.installWith(before, Fixture.noSecondAcquire));
    try testing.expect(another.handle == null and active_hook == &hook);
}
