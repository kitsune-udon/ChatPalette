const std = @import("std");
const win = @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cDefine("NONAMELESSUNION", "1");
    @cDefine("NO_STRICT", "1");
    @cInclude("windows.h");
});

pub const input_marker: usize = 0x43485049;
const modifiers = [_]u16{ win.VK_LSHIFT, win.VK_RSHIFT, win.VK_LMENU, win.VK_RMENU, win.VK_LCONTROL, win.VK_RCONTROL };
const cancel_prefix = std.unicode.utf8ToUtf16LeStringLiteral("Local\\ChatPalette-input-");
const payload_prefix = std.unicode.utf8ToUtf16LeStringLiteral("Local\\ChatPalette-text-");
// DB5 permits 16 Mi UTF-16 units. A BMP character can take three UTF-8 bytes per unit.
const max_payload_bytes = 48 * 1024 * 1024;

fn objectName(comptime prefix: [:0]const u16, token: []const u8) ![prefix.len + 32:0]u16 {
    if (token.len != 32) return error.InvalidInputCancelToken;
    var name: [prefix.len + 32:0]u16 = undefined;
    @memcpy(name[0..prefix.len], prefix);
    for (token, name[prefix.len..]) |byte, *wide| {
        if (!std.ascii.isHex(byte) or std.ascii.isUpper(byte)) return error.InvalidInputCancelToken;
        wide.* = byte;
    }
    name[name.len] = 0;
    return name;
}

pub const Cancellation = struct {
    handle: win.HANDLE,
    token: [32]u8,

    pub fn create() !Cancellation {
        var random: [16]u8 = undefined;
        std.crypto.random.bytes(&random);
        const token = std.fmt.bytesToHex(random, .lower);
        const name = try objectName(cancel_prefix, &token);
        win.SetLastError(0);
        const handle = win.CreateEventW(null, win.TRUE, win.FALSE, &name) orelse return error.CreateInputCancellation;
        errdefer _ = win.CloseHandle(handle);
        if (win.GetLastError() == win.ERROR_ALREADY_EXISTS) return error.CreateInputCancellation;
        return .{ .handle = handle, .token = token };
    }

    pub fn cancel(self: Cancellation) void {
        _ = win.SetEvent(self.handle);
    }

    pub fn close(self: Cancellation) void {
        _ = win.CloseHandle(self.handle);
    }
};

pub const Authorization = struct {
    cancellation: win.HANDLE,
    pipe: win.HANDLE,

    pub fn open(token: []const u8, pipe: win.HANDLE) !Authorization {
        if (pipe == null) return error.InputCancelled;
        const name = try objectName(cancel_prefix, token);
        const cancellation = win.OpenEventW(win.SYNCHRONIZE, win.FALSE, &name) orelse return error.InputCancelled;
        return .{ .cancellation = cancellation, .pipe = pipe };
    }

    pub fn close(self: Authorization) void {
        _ = win.CloseHandle(self.cancellation);
    }

    pub fn live(self: Authorization) bool {
        return win.PeekNamedPipe(self.pipe, null, 0, null, null, null) != 0 and
            win.WaitForSingleObject(self.cancellation, 0) == win.WAIT_TIMEOUT;
    }
};

pub const Payload = struct {
    handle: win.HANDLE,

    pub fn create(token: []const u8, text: []const u8) !Payload {
        const size = try payloadSize(text.len);
        const name = try objectName(payload_prefix, token);
        win.SetLastError(0);
        const invalid = std.os.windows.INVALID_HANDLE_VALUE;
        const handle = win.CreateFileMappingW(invalid, null, win.PAGE_READWRITE, 0, size, &name) orelse return error.CreateInputPayload;
        errdefer _ = win.CloseHandle(handle);
        if (win.GetLastError() == win.ERROR_ALREADY_EXISTS) return error.CreateInputPayload;
        const address = win.MapViewOfFile(handle, win.FILE_MAP_WRITE, 0, 0, size) orelse return error.MapInputPayload;
        defer _ = win.UnmapViewOfFile(address);
        const bytes: [*]u8 = @ptrCast(address);
        @memcpy(bytes[0..text.len], text);
        return .{ .handle = handle };
    }

    pub fn close(self: Payload) void {
        _ = win.CloseHandle(self.handle);
    }
};

pub const PayloadView = struct {
    text: []const u8,

    pub fn open(token: []const u8, length: usize) !PayloadView {
        const size = try payloadSize(length);
        const name = try objectName(payload_prefix, token);
        const handle = win.OpenFileMappingW(win.FILE_MAP_READ, win.FALSE, &name) orelse return error.OpenInputPayload;
        defer _ = win.CloseHandle(handle);
        const address = win.MapViewOfFile(handle, win.FILE_MAP_READ, 0, 0, size) orelse return error.MapInputPayload;
        const bytes: [*]const u8 = @ptrCast(address);
        return .{ .text = bytes[0..length] };
    }

    pub fn close(self: PayloadView) void {
        _ = win.UnmapViewOfFile(self.text.ptr);
    }
};

fn payloadSize(length: usize) !u32 {
    if (length > max_payload_bytes) return error.InvalidInputPayloadSize;
    return @intCast(@max(1, length));
}

fn down(vk: u16) bool {
    return win.GetAsyncKeyState(vk) < 0;
}

fn key(vk: u16, scan: u16, flags: win.DWORD) win.INPUT {
    var result = std.mem.zeroes(win.INPUT);
    result.type = win.INPUT_KEYBOARD;
    result.u.ki = .{ .wVk = vk, .wScan = scan, .dwFlags = flags, .time = 0, .dwExtraInfo = input_marker };
    return result;
}

fn virtualKey(vk: u16, released: bool) win.INPUT {
    const extended: win.DWORD = switch (vk) {
        win.VK_RMENU, win.VK_RCONTROL => win.KEYEVENTF_EXTENDEDKEY,
        else => 0,
    };
    return key(vk, 0, extended | if (released) @as(win.DWORD, win.KEYEVENTF_KEYUP) else 0);
}

pub const Effect = union(enum) { enter, clear, insert: []const u8 };

fn pendingKeyRelease(events: []const win.INPUT, sent: usize) ?win.INPUT {
    if (sent == 0 or sent >= events.len) return null;
    // Effects emit adjacent down/up pairs. Modifier restoration is handled separately.
    const pressed = events[sent - 1].u.ki;
    const remaining = events[sent].u.ki;
    if (std.mem.indexOfScalar(u16, &modifiers, pressed.wVk) != null) return null;
    if (pressed.dwFlags & win.KEYEVENTF_KEYUP != 0 or
        remaining.dwFlags != (pressed.dwFlags | win.KEYEVENTF_KEYUP) or
        pressed.wVk != remaining.wVk or pressed.wScan != remaining.wScan) return null;
    return events[sent];
}

pub const Batch = struct {
    data: std.ArrayList(win.INPUT) = .empty,
    allocator: std.mem.Allocator,

    pub fn prepare(allocator: std.mem.Allocator, effect: Effect) !Batch {
        var batch: Batch = .{ .allocator = allocator };
        errdefer batch.deinit();
        // Reserve space on either side of the effects for the modifiers observed at send time.
        try batch.data.resize(allocator, modifiers.len);
        switch (effect) {
            .enter => {
                try batch.push(virtualKey(win.VK_RETURN, false));
                try batch.push(virtualKey(win.VK_RETURN, true));
            },
            .clear => {
                try batch.push(virtualKey(win.VK_LCONTROL, false));
                try batch.push(virtualKey('A', false));
                try batch.push(virtualKey('A', true));
                try batch.push(virtualKey(win.VK_LCONTROL, true));
                try batch.push(virtualKey(win.VK_BACK, false));
                try batch.push(virtualKey(win.VK_BACK, true));
            },
            .insert => |text| {
                if (std.mem.indexOfAny(u8, text, "\x00\x08\x09\x0A\x0D") != null) return error.TextContainsEditingKey;
                const units = try std.unicode.utf8ToUtf16LeAlloc(allocator, text);
                defer allocator.free(units);
                if (units.len > 16 * 1024 * 1024) return error.InvalidInputPayloadSize;
                try batch.data.ensureUnusedCapacity(allocator, 2 + units.len * 2 + modifiers.len);
                try batch.appendText(units);
            },
        }
        try batch.data.ensureUnusedCapacity(allocator, modifiers.len);
        return batch;
    }

    pub fn deinit(self: *Batch) void {
        self.data.deinit(self.allocator);
    }

    fn push(self: *Batch, event: win.INPUT) !void {
        try self.data.append(self.allocator, event);
    }

    fn appendText(self: *Batch, units: []const u16) !void {
        try self.push(virtualKey(win.VK_IME_OFF, false));
        try self.push(virtualKey(win.VK_IME_OFF, true));
        for (units) |unit| {
            try self.push(key(0, unit, win.KEYEVENTF_UNICODE));
            try self.push(key(0, unit, win.KEYEVENTF_UNICODE | win.KEYEVENTF_KEYUP));
        }
    }

    fn withModifiers(self: *Batch, physical: [modifiers.len]bool) []win.INPUT {
        var start = modifiers.len;
        for (physical) |held| start -= @intFromBool(held);
        var release_index = start;
        for (modifiers, physical) |vk, held| {
            if (!held) continue;
            self.data.items[release_index] = virtualKey(vk, true);
            release_index += 1;
        }
        var i = modifiers.len;
        while (i > 0) {
            i -= 1;
            if (physical[i]) self.data.appendAssumeCapacity(virtualKey(modifiers[i], false));
        }
        return self.data.items[start..];
    }

    pub fn send(self: *Batch, target: win.HWND, authorization: ?Authorization) !void {
        var physical: [modifiers.len]bool = undefined;
        for (modifiers, &physical) |vk, *was_down| was_down.* = down(vk);
        const events = self.withModifiers(physical);
        if (target == null or win.GetForegroundWindow() != target) return error.ForegroundChanged;
        if (authorization) |permit| if (!permit.live()) return error.InputCancelled;
        if (win.GetForegroundWindow() != target) return error.ForegroundChanged;
        const sent = win.SendInput(@intCast(events.len), events.ptr, @sizeOf(win.INPUT));
        if (sent == events.len) return;
        // Release a key already pressed by the partial batch and restore the modifiers without replaying an effect.
        var recovery: [modifiers.len + 1]win.INPUT = undefined;
        var n: usize = 0;
        if (pendingKeyRelease(events, sent)) |release_event| {
            recovery[n] = release_event;
            n += 1;
        }
        for (modifiers, physical) |vk, was_down| {
            if (was_down == down(vk)) continue;
            recovery[n] = virtualKey(vk, !was_down);
            n += 1;
        }
        if (n != 0) _ = win.SendInput(@intCast(n), &recovery, @sizeOf(win.INPUT));
        return error.InputOutcomeUnknown;
    }
};

pub fn insert(allocator: std.mem.Allocator, target: win.HWND, value: []const u8) !void {
    var batch = try Batch.prepare(allocator, .{ .insert = value });
    defer batch.deinit();
    try batch.send(target, null);
}

pub fn enter(allocator: std.mem.Allocator, target: win.HWND, authorization: Authorization) !void {
    var batch = try Batch.prepare(allocator, .enter);
    defer batch.deinit();
    try batch.send(target, authorization);
}

pub fn clear(allocator: std.mem.Allocator, target: win.HWND) !void {
    var batch = try Batch.prepare(allocator, .clear);
    defer batch.deinit();
    try batch.send(target, null);
}

test "literal input queues IME off, UTF-16 units, and restoration of held modifiers" {
    const allocator = std.testing.allocator;
    var batch = try Batch.prepare(allocator, .{ .insert = "あ👏" });
    defer batch.deinit();
    const events = batch.withModifiers(.{ false, false, false, true, true, false });

    const k = win.KEYEVENTF_KEYUP;
    const u = win.KEYEVENTF_UNICODE;
    const e = win.KEYEVENTF_EXTENDEDKEY;
    const expected = [_]struct { vk: u16, scan: u16, flags: win.DWORD }{
        .{ .vk = win.VK_RMENU, .scan = 0, .flags = e | k },
        .{ .vk = win.VK_LCONTROL, .scan = 0, .flags = k },
        .{ .vk = win.VK_IME_OFF, .scan = 0, .flags = 0 },
        .{ .vk = win.VK_IME_OFF, .scan = 0, .flags = k },
        .{ .vk = 0, .scan = 0x3042, .flags = u },
        .{ .vk = 0, .scan = 0x3042, .flags = u | k },
        .{ .vk = 0, .scan = 0xd83d, .flags = u },
        .{ .vk = 0, .scan = 0xd83d, .flags = u | k },
        .{ .vk = 0, .scan = 0xdc4f, .flags = u },
        .{ .vk = 0, .scan = 0xdc4f, .flags = u | k },
        .{ .vk = win.VK_LCONTROL, .scan = 0, .flags = 0 },
        .{ .vk = win.VK_RMENU, .scan = 0, .flags = e },
    };
    try std.testing.expectEqual(expected.len, events.len);
    for (expected, events) |want, actual| {
        try std.testing.expectEqual(@as(win.DWORD, win.INPUT_KEYBOARD), actual.type);
        const key_event = actual.u.ki;
        try std.testing.expectEqual(want.vk, key_event.wVk);
        try std.testing.expectEqual(want.scan, key_event.wScan);
        try std.testing.expectEqual(want.flags, key_event.dwFlags);
        try std.testing.expectEqual(input_marker, key_event.dwExtraInfo);
    }
}

test "input rejects editing characters and targets without foreground ownership before sending" {
    const allocator = std.testing.allocator;
    for ([_][]const u8{ "a\x08b", "a\tb", "a\nb", "a\rb" }) |value|
        try std.testing.expectError(error.TextContainsEditingKey, insert(allocator, null, value));
    try std.testing.expectError(error.ForegroundChanged, insert(allocator, null, "text"));
    try std.testing.expectError(error.ForegroundChanged, enter(allocator, null, .{ .cancellation = null, .pipe = null }));
    try std.testing.expectError(error.ForegroundChanged, clear(allocator, null));
}

test "input permission expires on cancellation and cannot select an arbitrary named event" {
    const owner = try Cancellation.create();
    defer owner.close();
    const name = try objectName(cancel_prefix, &owner.token);
    const reader = win.OpenEventW(win.SYNCHRONIZE, win.FALSE, &name) orelse return error.OpenInputCancellation;
    defer _ = win.CloseHandle(reader);
    try std.testing.expectEqual(@as(win.DWORD, win.WAIT_TIMEOUT), win.WaitForSingleObject(reader, 0));
    owner.cancel();
    try std.testing.expectEqual(@as(win.DWORD, win.WAIT_OBJECT_0), win.WaitForSingleObject(reader, 0));
    try std.testing.expectError(error.InvalidInputCancelToken, objectName(cancel_prefix, "Global\\some-other-event"));
}

test "scoped read-only input payload roundtrips text larger than a pipe frame" {
    const cancellation = try Cancellation.create();
    defer cancellation.close();
    const body = "あ👏" ** 5_000;
    const payload = try Payload.create(&cancellation.token, body);
    defer payload.close();
    const view = try PayloadView.open(&cancellation.token, body.len);
    defer view.close();
    try std.testing.expectEqualStrings(body, view.text);
    try std.testing.expectError(error.InvalidInputPayloadSize, PayloadView.open(&cancellation.token, max_payload_bytes + 1));
}

test "partial keyboard batches release an unmatched effect key without replaying it" {
    const allocator = std.testing.allocator;
    var enter_batch = try Batch.prepare(allocator, .enter);
    defer enter_batch.deinit();
    const enter_events = enter_batch.withModifiers(@splat(false));
    try std.testing.expect(pendingKeyRelease(enter_events, 0) == null);
    try std.testing.expect(pendingKeyRelease(enter_events, enter_events.len) == null);
    try std.testing.expectEqual(@as(u16, win.VK_RETURN), pendingKeyRelease(enter_events, 1).?.u.ki.wVk);
    try std.testing.expectEqual(@as(win.DWORD, win.KEYEVENTF_KEYUP), pendingKeyRelease(enter_events, 1).?.u.ki.dwFlags);

    var clear_batch = try Batch.prepare(allocator, .clear);
    defer clear_batch.deinit();
    const clear_events = clear_batch.withModifiers(@splat(false));
    try std.testing.expect(pendingKeyRelease(clear_events, 1) == null);
    try std.testing.expectEqual(@as(u16, 'A'), pendingKeyRelease(clear_events, 2).?.u.ki.wVk);
    try std.testing.expect(pendingKeyRelease(clear_events, 3) == null);
    try std.testing.expectEqual(@as(u16, win.VK_BACK), pendingKeyRelease(clear_events, 5).?.u.ki.wVk);
}
