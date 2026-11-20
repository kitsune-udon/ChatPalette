const std = @import("std");
const domain = @import("shortcut_domain");
const win = @import("win.zig").api;

pub const Action = domain.Action;
pub const action_count = domain.action_count;
pub const default_keys = domain.default_keys;
pub const ctrl = domain.ctrl;
pub const alt = domain.alt;
pub const shift = domain.shift;
pub const windows: u8 = 8;
pub const Chord = domain.Chord;
pub const Bindings = domain.Bindings;
pub const parse = domain.parse;
pub const validate = domain.validate;

pub fn virtualKey(key: domain.Key) u8 {
    return switch (key) {
        .alphanumeric => |character| character,
        .function => |number| @intCast(win.VK_F1 + number - 1),
        .escape => win.VK_ESCAPE,
    };
}

pub fn matches(chord: Chord, vk: u8, modifiers: u8) bool {
    return virtualKey(chord.key) == vk and chord.modifiers == modifiers;
}

pub fn label(chord: ?Chord, buffer: []u8) []const u8 {
    const value = chord orelse return "未割当";
    if (value.key == .escape) return "Esc";
    var writer = std.Io.Writer.fixed(buffer);
    if (value.modifiers & ctrl != 0) writer.writeAll("Ctrl+") catch unreachable;
    if (value.modifiers & alt != 0) writer.writeAll("Alt+") catch unreachable;
    if (value.modifiers & shift != 0) writer.writeAll("Shift+") catch unreachable;
    switch (value.key) {
        .alphanumeric => |character| writer.writeByte(character) catch unreachable,
        .function => |number| writer.print("F{d}", .{number}) catch unreachable,
        .escape => unreachable,
    }
    return writer.buffered();
}

pub const Event = struct {
    action: Action,
    window: usize,
};
pub const Decision = struct {
    consume: bool = false,
    event: ?Event = null,
};
const Held = struct {
    captured: bool = false,
    event: ?Event = null,
};

/// The main key owns its release even if modifiers are released first.
pub const Tracker = struct {
    bindings: Bindings = @splat(null),
    held: [256]Held = @splat(.{}),

    pub fn replace(self: *Tracker, bindings: Bindings) void {
        self.bindings = bindings;
        for (&self.held) |*held| held.event = null;
    }

    pub fn key(self: *Tracker, vk: u8, released: bool, modifiers: u8, window: usize, browser: bool, stoppable: bool) Decision {
        const held = &self.held[vk];
        if (released) {
            const result = Decision{ .consume = held.captured, .event = held.event };
            held.* = .{};
            return result;
        }
        if (held.captured) return .{ .consume = true };
        for (self.bindings, 0..) |binding, i| {
            const chord = binding orelse continue;
            if (!matches(chord, vk, modifiers)) continue;
            const action: Action = @enumFromInt(i);
            if (action == .stop) {
                if (!stoppable) return .{};
                held.captured = true;
                return .{ .consume = true, .event = .{ .action = action, .window = window } };
            }
            if (action != .palette and !browser) return .{};
            held.* = .{ .captured = true, .event = .{ .action = action, .window = window } };
            return .{ .consume = true };
        }
        return .{};
    }
};

test "keys run in release order, repeats are swallowed, and stop fires on press" {
    var tracker = Tracker{ .bindings = try validate(default_keys) };
    const mods = ctrl | alt;
    try std.testing.expect(!tracker.key('F', false, mods, 10, false, false).consume);
    try std.testing.expect(tracker.key('F', false, mods, 20, true, false).consume);
    try std.testing.expectEqual(@as(?Event, null), tracker.key('F', false, mods, 20, true, false).event);
    try std.testing.expect(tracker.key('3', false, mods, 20, true, false).consume);
    try std.testing.expectEqual(Event{ .action = .shared1, .window = 20 }, tracker.key('3', true, mods, 20, true, false).event.?);
    try std.testing.expectEqual(Event{ .action = .chat_focus, .window = 20 }, tracker.key('F', true, 0, 30, false, false).event.?);
    try std.testing.expect(!tracker.key(0x1B, false, 0, 20, true, false).consume);
    try std.testing.expectEqual(Action.stop, tracker.key(0x1B, false, 0, 20, true, true).event.?.action);
    try std.testing.expectEqual(@as(?Event, null), tracker.key(0x1B, true, 0, 20, true, true).event);
}

test "remapping does not leak the release of a swallowed key" {
    var tracker = Tracker{ .bindings = try validate(default_keys) };
    _ = tracker.key('F', false, ctrl | alt, 20, true, false);
    tracker.replace(try validate(default_keys));
    const release = tracker.key('F', true, ctrl | alt, 20, true, false);
    try std.testing.expect(release.consume and release.event == null);
}
