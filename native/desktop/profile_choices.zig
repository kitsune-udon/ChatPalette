const std = @import("std");
const storage = @import("../storage/store.zig");

const ProfileChoices = @This();

arena: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(std.heap.page_allocator),
ids: []const []const u8 = &.{},
names: []const []const u8 = &.{},

pub fn clear(self: *ProfileChoices) void {
    _ = self.arena.reset(.free_all);
    self.ids = &.{};
    self.names = &.{};
}

/// Publish only after all displayed labels, including the first empty choice, exist.
pub fn publish(self: *ProfileChoices, profiles: []const storage.Profile) !void {
    if (self.sameNames(profiles)) {
        for (profiles, self.ids[1..]) |profile, id| {
            if (!std.mem.eql(u8, profile.id, id)) break;
        } else return;
    }
    self.clear();
    errdefer self.clear();
    const memory = self.arena.allocator();
    const ids = try memory.alloc([]const u8, profiles.len + 1);
    const names = try memory.alloc([]const u8, profiles.len);
    ids[0] = "";
    for (profiles, ids[1..], names) |profile, *id, *name| {
        id.* = try memory.dupe(u8, profile.id);
        name.* = try memory.dupe(u8, profile.name);
    }
    self.ids = ids;
    self.names = names;
}

pub fn sameNames(self: *const ProfileChoices, profiles: []const storage.Profile) bool {
    if (self.ids.len == 0 or self.names.len != profiles.len) return false;
    for (profiles, self.names) |profile, name| {
        if (!std.mem.eql(u8, profile.name, name)) return false;
    }
    return true;
}

pub fn resolve(self: *const ProfileChoices, data: storage.Data, index: usize) ?[]const u8 {
    if (index >= self.ids.len) return null;
    const id = self.ids[index];
    return if (id.len == 0 or data.findProfile(id) != null) id else null;
}

test "a displayed choice retains its exact ID across reorder and deletion" {
    var choices: ProfileChoices = .{};
    defer choices.clear();
    const first: storage.Profile = .{ .id = "scope-A", .name = "First" };
    const second: storage.Profile = .{ .id = "scope-a", .name = "Second" };
    try choices.publish(&.{ first, second });

    const reordered: storage.Data = .{ .profiles = &.{ second, first } };
    try std.testing.expectEqualStrings("scope-A", choices.resolve(reordered, 1).?);
    try std.testing.expectEqualStrings("scope-a", choices.resolve(reordered, 2).?);
    try std.testing.expectEqualStrings("", choices.resolve(reordered, 0).?);

    const after_delete: storage.Data = .{ .profiles = &.{second} };
    try std.testing.expect(choices.resolve(after_delete, 1) == null);
    try std.testing.expect(choices.resolve(after_delete, std.math.maxInt(usize)) == null);
    choices.clear();
    try std.testing.expect(choices.resolve(after_delete, 0) == null);
}
