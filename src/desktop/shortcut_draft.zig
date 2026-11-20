const std = @import("std");
const storage = @import("../storage/store.zig");
const bindings = @import("shortcuts.zig");
const allocator = std.heap.page_allocator;

pub const ShortcutDraft = struct {
    keys: [storage.action_count][]const u8,

    pub fn copy(keys: [storage.action_count][]const u8) !ShortcutDraft {
        var result: ShortcutDraft = undefined;
        for (keys, &result.keys, 0..) |key, *value, i| {
            value.* = allocator.dupe(u8, key) catch |failure| {
                for (result.keys[0..i]) |owned| allocator.free(owned);
                return failure;
            };
        }
        return result;
    }

    pub fn deinit(self: ShortcutDraft) void {
        for (self.keys) |value| allocator.free(value);
    }

    pub fn preserveEquivalent(self: *ShortcutDraft, baseline: ShortcutDraft) !void {
        for (&self.keys, baseline.keys) |*value, previous| {
            if (std.mem.eql(u8, value.*, previous) or !sameKey(previous, value.*)) continue;
            const unchanged = try allocator.dupe(u8, previous);
            allocator.free(value.*);
            value.* = unchanged;
        }
    }
};

pub fn sameKey(old: []const u8, new: []const u8) bool {
    if (std.mem.eql(u8, old, new)) return true;
    const previous = bindings.parse(old) catch return false;
    const current = bindings.parse(new) catch return false;
    return std.meta.eql(previous, current);
}

pub fn sameKeys(before: [storage.action_count][]const u8, after: [storage.action_count][]const u8) bool {
    for (before, after) |old, new| if (!sameKey(old, new)) return false;
    return true;
}

test "the key editor honors semantic changes, including invalid unsaved drafts" {
    var draft = storage.default_shortcut_keys;
    draft[0] = "!^Q";
    try std.testing.expect(sameKeys(storage.default_shortcut_keys, draft));
    draft[0] = "q";
    try std.testing.expect(!sameKeys(storage.default_shortcut_keys, draft));
    draft[0] = "^+q";
    try std.testing.expect(!sameKeys(storage.default_shortcut_keys, draft));
}

test "saving a mixed key draft retains the spelling of every unchanged chord" {
    var prior = storage.default_shortcut_keys;
    prior[@intFromEnum(storage.Action.chat_focus)] = "!^F";
    prior[@intFromEnum(storage.Action.stop)] = "eSC";
    const saved = try ShortcutDraft.copy(prior);
    defer saved.deinit();
    var staged = storage.default_shortcut_keys;
    staged[@intFromEnum(storage.Action.profile1)] = "";
    var draft = try ShortcutDraft.copy(staged);
    defer draft.deinit();
    try std.testing.expect(!sameKeys(saved.keys, draft.keys));
    try draft.preserveEquivalent(saved);
    try std.testing.expectEqualStrings("!^F", draft.keys[@intFromEnum(storage.Action.chat_focus)]);
    try std.testing.expectEqualStrings("eSC", draft.keys[@intFromEnum(storage.Action.stop)]);
    try std.testing.expectEqualStrings("", draft.keys[@intFromEnum(storage.Action.profile1)]);
}
