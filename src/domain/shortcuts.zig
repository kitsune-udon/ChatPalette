const std = @import("std");

// These tags and their order are shared by DB5 and JSON2.
pub const Action = enum(u8) {
    palette,
    profile1,
    profile2,
    shared1,
    shared2,
    chat_focus,
    chat_clear,
    reactions_show,
    reaction,
    chat_send,
    stop,

    fn required(self: Action) bool {
        return self == .palette or self == .reaction or self == .stop;
    }
};

pub const action_count = std.meta.fields(Action).len;
pub const Keys = [action_count][]const u8;
pub const default_keys: Keys = .{
    "^!q", "^!1", "^!2", "^!3", "^!4", "^!f", "^!w", "^!r", "^!t", "^!e", "Esc",
};

pub const ctrl: u8 = 1;
pub const alt: u8 = 2;
pub const shift: u8 = 4;

pub const Key = union(enum) {
    alphanumeric: u8,
    function: u8,
    escape,
};

pub const Chord = struct {
    key: Key,
    modifiers: u8,

    pub fn eql(a: Chord, b: Chord) bool {
        return a.modifiers == b.modifiers and std.meta.eql(a.key, b.key);
    }
};

pub const Bindings = [action_count]?Chord;

pub fn parse(text: []const u8) error{InvalidShortcut}!?Chord {
    if (text.len == 0) return null;
    if (std.ascii.eqlIgnoreCase(text, "Esc")) return .{ .key = .escape, .modifiers = 0 };
    var modifiers: u8 = 0;
    var suffix = text;
    while (suffix.len > 0) : (suffix = suffix[1..]) {
        const mask = switch (suffix[0]) {
            '^' => ctrl,
            '!' => alt,
            '+' => shift,
            else => break,
        };
        if (modifiers & mask != 0) return error.InvalidShortcut;
        modifiers |= mask;
    }
    if (modifiers & ctrl == 0 or modifiers & (alt | shift) == 0) return error.InvalidShortcut;
    if (suffix.len == 1 and std.ascii.isAlphanumeric(suffix[0]))
        return .{ .key = .{ .alphanumeric = std.ascii.toUpper(suffix[0]) }, .modifiers = modifiers };

    if (suffix.len < 2 or suffix.len > 3 or std.ascii.toUpper(suffix[0]) != 'F' or suffix[1] == '0')
        return error.InvalidShortcut;
    for (suffix[1..]) |digit| if (!std.ascii.isDigit(digit)) return error.InvalidShortcut;
    const number = std.fmt.parseInt(u8, suffix[1..], 10) catch return error.InvalidShortcut;
    if (number == 0 or number > 12) return error.InvalidShortcut;
    return .{ .key = .{ .function = number }, .modifiers = modifiers };
}

pub fn validate(keys: Keys) error{ InvalidShortcut, RequiredShortcut, DuplicateShortcut }!Bindings {
    var bindings: Bindings = @splat(null);
    for (std.enums.values(Action), keys, 0..) |action, text, i| {
        const chord = try parse(text) orelse {
            if (action.required()) return error.RequiredShortcut;
            continue;
        };
        if (chord.key == .escape and action != .stop) return error.InvalidShortcut;
        for (bindings[0..i]) |earlier| {
            if (earlier) |previous| if (previous.eql(chord)) return error.DuplicateShortcut;
        }
        bindings[i] = chord;
    }
    return bindings;
}

test "DB5 and JSON2 shortcut tags and defaults retain all eleven actions" {
    const expected = .{
        .{ "palette", "^!q" },    .{ "profile1", "^!1" },       .{ "profile2", "^!2" },
        .{ "shared1", "^!3" },    .{ "shared2", "^!4" },        .{ "chat_focus", "^!f" },
        .{ "chat_clear", "^!w" }, .{ "reactions_show", "^!r" }, .{ "reaction", "^!t" },
        .{ "chat_send", "^!e" },  .{ "stop", "Esc" },
    };
    const bindings = try validate(default_keys);
    try std.testing.expectEqual(expected.len, action_count);
    inline for (expected, 0..) |entry, i| {
        try std.testing.expectEqualStrings(entry[0], @tagName(@as(Action, @enumFromInt(i))));
        try std.testing.expectEqualStrings(entry[1], default_keys[i]);
        try std.testing.expect(bindings[i] != null);
    }
}

test "shortcut identity ignores case and modifier order without changing saved text" {
    const first = (try parse("!^+F12")).?;
    const second = (try parse("+^!f12")).?;
    try std.testing.expect(first.eql(second));
    try std.testing.expectEqual(@as(u8, 12), first.key.function);
    var keys = default_keys;
    keys[@intFromEnum(Action.chat_focus)] = "!^+F12";
    keys[@intFromEnum(Action.chat_clear)] = "+^!f12";
    try std.testing.expectError(error.DuplicateShortcut, validate(keys));
    try std.testing.expectEqualStrings("!^+F12", keys[@intFromEnum(Action.chat_focus)]);
    for ([_][]const u8{ "^q", "!F1", "^!!a", "^+F01", "^+F13", "^+F1x", "^+é", "^+ " }) |bad| {
        try std.testing.expectError(error.InvalidShortcut, parse(bad));
    }
}

test "absent bindings are permitted for optional actions and Escape is reserved for stop" {
    var keys = default_keys;
    keys[@intFromEnum(Action.profile1)] = "";
    keys[@intFromEnum(Action.stop)] = "eSC";
    const bindings = try validate(keys);
    try std.testing.expect(bindings[@intFromEnum(Action.profile1)] == null);
    try std.testing.expect(bindings[@intFromEnum(Action.stop)].?.key == .escape);
    keys[@intFromEnum(Action.profile1)] = "Esc";
    try std.testing.expectError(error.InvalidShortcut, validate(keys));
    for ([_]Action{ .palette, .reaction, .stop }) |action| {
        keys = default_keys;
        keys[@intFromEnum(action)] = "";
        try std.testing.expectError(error.RequiredShortcut, validate(keys));
    }
    keys[@intFromEnum(Action.stop)] = "^+F1";
    try std.testing.expectEqual(@as(u8, 1), (try validate(keys))[@intFromEnum(Action.stop)].?.key.function);
}
