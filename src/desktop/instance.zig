const std = @import("std");
const windows = @import("win.zig");
const win = windows.api;

pub const class_name = windows.wide("ChatPalette.Host");
pub const recall = win.WM_APP + 5;
pub const present = win.WM_APP + 6;
pub const Request = enum(usize) { quiet, reveal };
const session_name = windows.wide("Local\\ChatPalette.Desktop");

pub const Instance = struct {
    directory: win.HANDLE,
    session: win.HANDLE,
    window_name: [77:0]u16,

    pub fn acquire(directory: []const u8, request: ?Request) !?Instance {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(directory, &digest, .{});
        const hex = std.fmt.bytesToHex(digest, .lower);
        var name: [77:0]u16 = @splat(0);
        const prefix = windows.wide("ChatPalette.");
        @memcpy(name[0..prefix.len], prefix);
        for (hex, name[prefix.len .. prefix.len + hex.len]) |ch, *unit| unit.* = ch;
        const local = try tryLock(&name) orelse {
            try requestExisting(&name, request orelse return error.InstanceAlreadyRunning);
            return null;
        };
        errdefer unlock(local);
        const session = try tryLock(session_name) orelse return error.OtherInstanceAlreadyRunning;
        return .{ .directory = local, .session = session, .window_name = name };
    }

    pub fn release(self: Instance) void {
        unlock(self.session);
        unlock(self.directory);
    }
};

fn tryLock(name: [:0]const u16) !?win.HANDLE {
    const mutex = win.CreateMutexW(null, 0, name) orelse return error.CreateInstanceMutex;
    switch (win.WaitForSingleObject(mutex, 0)) {
        win.WAIT_OBJECT_0, win.WAIT_ABANDONED => return mutex,
        else => |state| {
            _ = win.CloseHandle(mutex);
            if (state == win.WAIT_TIMEOUT) return null;
            return error.WaitForInstanceMutex;
        },
    }
}

fn unlock(mutex: win.HANDLE) void {
    _ = win.ReleaseMutex(mutex);
    _ = win.CloseHandle(mutex);
}

fn requestExisting(name: [:0]const u16, request: Request) !void {
    const started = win.GetTickCount64();
    while (win.GetTickCount64() - started < 3000) {
        if (win.FindWindowW(class_name, name)) |window| {
            if (request == .reveal) {
                var pid: win.DWORD = 0;
                if (win.GetWindowThreadProcessId(window, &pid) != 0) _ = win.AllowSetForegroundWindow(pid);
            }
            var response: win.DWORD_PTR = 0;
            if (win.SendMessageTimeoutW(window, recall, @intFromEnum(request), 0, win.SMTO_ABORTIFHUNG | win.SMTO_BLOCK, 300, &response) != 0 and response == 1)
                return;
        }
        std.Thread.sleep(25 * std.time.ns_per_ms);
    }
    return error.InstanceNotResponding;
}
