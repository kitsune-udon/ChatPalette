const std = @import("std");
const windows = @import("win.zig");
const win = windows.api;

pub const class_name = windows.wide("ChatPalette.Host");
pub const take_over = win.WM_APP + 1;

pub const Instance = struct {
    handle: win.HANDLE,
    window_name: [77:0]u16,

    pub fn acquire(directory: []const u8) !Instance {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(directory, &digest, .{});
        const hex = std.fmt.bytesToHex(digest, .lower);
        var name: [77:0]u16 = @splat(0);
        const prefix = windows.wide("ChatPalette.");
        @memcpy(name[0..prefix.len], prefix);
        for (hex, name[prefix.len .. prefix.len + hex.len]) |ch, *unit| unit.* = ch;
        win.SetLastError(0);
        const mutex = win.CreateMutexW(null, 1, &name) orelse return error.CreateInstanceMutex;
        errdefer _ = win.CloseHandle(mutex);
        if (win.GetLastError() == win.ERROR_ALREADY_EXISTS) {
            const started = win.GetTickCount64();
            while (true) {
                const previous = win.FindWindowW(class_name, &name);
                if (previous != null) _ = win.PostMessageW(previous, take_over, 0, 0);
                const state = win.WaitForSingleObject(mutex, 50);
                if (state == win.WAIT_OBJECT_0 or state == win.WAIT_ABANDONED) break;
                if (state != win.WAIT_TIMEOUT or win.GetTickCount64() - started >= 8000)
                    return error.PreviousInstanceDidNotExit;
            }
        }
        return .{ .handle = mutex, .window_name = name };
    }

    pub fn release(self: Instance) void {
        _ = win.ReleaseMutex(self.handle);
        _ = win.CloseHandle(self.handle);
    }
};
