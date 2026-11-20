const std = @import("std");
const model = @import("model.zig");
const Allocator = std.mem.Allocator;
const Item = model.Item;
const Profile = model.Profile;
const Snapshot = model.Snapshot;
const equal = std.mem.eql;

pub const ItemValues = struct { name: []const u8, text: []const u8, slot: u8 = 0 };
pub const TextEdit = struct { scope: []const u8, index: usize };
pub const ItemCommand = union(enum) {
    add: ItemValues,
    edit: struct { id: []const u8, values: ItemValues },
    delete: []const u8,
    duplicate: []const u8,
    up: []const u8,
    down: []const u8,
    move: struct { id: []const u8, destination: []const u8 },
};

pub const ProfileCommand = union(enum) {
    add: struct { name: []const u8, channel: []const u8 = "" },
    rename: struct { id: []const u8, name: []const u8 },
    bind: struct { id: []const u8, channel: []const u8 },
    unbind: []const u8,
    delete: []const u8,
};

const PositionedItem = struct { index: usize, item: Item };
const ItemPatch = struct {
    scope: []const u8,
    remove: []const u8 = "",
    restore: [2]?PositionedItem = .{ null, null },

    fn owned(self: ItemPatch, allocator: Allocator) !ItemPatch {
        var patch = self;
        patch.scope = try allocator.dupe(u8, self.scope);
        patch.remove = try allocator.dupe(u8, self.remove);
        for (&patch.restore) |*entry| {
            if (entry.*) |*previous| previous.item = try ownedItem(allocator, previous.item);
        }
        return patch;
    }
};

const Assignment = struct {
    scope: []const u8,
    ids: [2][]const u8,
};

const UndoChange = union(enum) {
    items: struct { first: ItemPatch, second: ?ItemPatch = null, text_only: bool = false },
    assign: Assignment,
    remove_profile: []const u8,
    insert_profile: struct { index: usize, profile: Profile },
    edit_profile: Profile,

    fn textEdit(self: UndoChange) ?TextEdit {
        if (self != .items or !self.items.text_only) return null;
        return .{ .scope = self.items.first.scope, .index = self.items.first.restore[0].?.index };
    }
};

const Entry = struct {
    arena: std.heap.ArenaAllocator,
    change: UndoChange,
    description: UndoDescription,
};

pub const UndoDescription = struct {
    target: ?[]const u8,
    operation: union(enum) {
        item: std.meta.Tag(ItemCommand),
        profile: std.meta.Tag(ProfileCommand),
        assignment,
    },
};

pub const History = struct {
    allocator: Allocator,
    entries: [30]Entry = undefined,
    start: usize = 0,
    length: usize = 0,

    pub fn init(allocator: Allocator) History {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *History) void {
        self.clear();
    }

    pub fn clear(self: *History) void {
        for (0..self.length) |i| self.entries[(self.start + i) % self.entries.len].arena.deinit();
        self.start = 0;
        self.length = 0;
    }

    pub fn latest(self: *const History) ?UndoDescription {
        if (self.length == 0) return null;
        return self.entries[(self.start + self.length - 1) % self.entries.len].description;
    }

    fn publish(self: *History, store: anytype, snapshot: *Snapshot, draft: model.Data, undo_change: UndoChange, description: UndoDescription) !void {
        var entry: Entry = .{ .arena = std.heap.ArenaAllocator.init(self.allocator), .change = undefined, .description = description };
        errdefer entry.arena.deinit();
        const own = entry.arena.allocator();
        if (description.target) |target| entry.description.target = try own.dupe(u8, target);
        entry.change = switch (undo_change) {
            .items => |steps| .{ .items = .{
                .first = try steps.first.owned(own),
                .second = if (steps.second) |second| try second.owned(own) else null,
                .text_only = steps.text_only,
            } },
            .assign => |assignment| .{ .assign = .{
                .scope = try own.dupe(u8, assignment.scope),
                .ids = .{ try own.dupe(u8, assignment.ids[0]), try own.dupe(u8, assignment.ids[1]) },
            } },
            .remove_profile => |id| .{ .remove_profile = try own.dupe(u8, id) },
            .insert_profile => |previous| .{ .insert_profile = .{
                .index = previous.index,
                .profile = try ownedProfile(own, previous.profile),
            } },
            .edit_profile => |previous| .{ .edit_profile = try ownedProfile(own, previous) },
        };
        try persist(self.allocator, store, snapshot, draft, entry.change.textEdit());
        if (self.length == self.entries.len) {
            self.entries[self.start].arena.deinit();
            self.entries[self.start] = entry;
            self.start = (self.start + 1) % self.entries.len;
        } else {
            self.entries[(self.start + self.length) % self.entries.len] = entry;
            self.length += 1;
        }
    }

    /// Returns the resulting item ID, owned by the published snapshot. A removal
    /// or a boundary move may leave no selected item and returns null.
    pub fn item(self: *History, store: anytype, snapshot: *Snapshot, scope: []const u8, command: ItemCommand) !?[]const u8 {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const temp = arena.allocator();
        var draft = try draftData(temp, snapshot.data);
        var items = try itemDraft(temp, draft, scope);
        var inverse = ItemPatch{ .scope = scope };
        var second: ?ItemPatch = null;
        const id_before: []const u8 = switch (command) {
            .add => "",
            .edit => |change| change.id,
            .delete, .duplicate, .up, .down => |id| id,
            .move => |move| move.id,
        };
        const index = if (command == .add) items.items.len else itemIndex(items.items, id_before) orelse return error.ItemMissing;
        const old = if (command == .add) null else items.items[index];
        var selection: []const u8 = id_before;
        var selection_scope = scope;
        switch (command) {
            .add, .edit => {
                const values = if (command == .add) command.add else command.edit.values;
                if (values.slot > 2) return error.InvalidSlot;
                const name = std.mem.trim(u8, values.name, " \t");
                if (old) |previous| {
                    if (equal(u8, previous.name, name) and equal(u8, previous.text, values.text) and previous.slot == values.slot)
                        return previous.id;
                    inverse.restore[0] = .{ .index = index, .item = previous };
                }
                selection = if (old) |previous| previous.id else try newId(temp);
                if (old == null) inverse.remove = selection;
                const updated = Item{ .id = selection, .name = name, .text = values.text, .slot = values.slot };
                if (old != null) items.items[index] = updated else try items.append(temp, updated);
                if (values.slot != 0) {
                    for (items.items, 0..) |*candidate, i| {
                        if (i != index and candidate.slot == values.slot) {
                            inverse.restore[1] = .{ .index = i, .item = candidate.* };
                            candidate.slot = 0;
                            break;
                        }
                    }
                }
            },
            .delete => {
                inverse.restore[0] = .{ .index = index, .item = items.orderedRemove(index) };
                selection = if (items.items.len == 0) "" else items.items[@min(index, items.items.len - 1)].id;
            },
            .duplicate => {
                selection = try newId(temp);
                const original = old.?;
                const label = try std.fmt.allocPrint(temp, "{s}（コピー）", .{original.name});
                try items.insert(temp, index + 1, .{ .id = selection, .name = label, .text = original.text });
                inverse.remove = selection;
            },
            .up, .down => {
                if ((command == .up and index == 0) or (command == .down and index + 1 == items.items.len))
                    return null;
                inverse.restore[0] = .{ .index = index, .item = old.? };
                const other = if (command == .up) index - 1 else index + 1;
                std.mem.swap(Item, &items.items[index], &items.items[other]);
            },
            .move => |move| {
                if (equal(u8, scope, move.destination)) return error.SameProfile;
                var target = try itemDraft(temp, draft, move.destination);
                var moved = items.orderedRemove(index);
                inverse.restore[0] = .{ .index = index, .item = moved };
                moved.slot = 0;
                try target.append(temp, moved);
                try setItems(&draft, move.destination, target.items);
                second = .{ .scope = move.destination, .remove = moved.id };
                selection_scope = move.destination;
            },
        }
        try setItems(&draft, scope, items.items);
        // Allocate a copy of the selection before publishing, which frees old slices.
        const selected = try temp.dupe(u8, selection);
        const selected_scope = try temp.dupe(u8, selection_scope);
        const text_only = command == .edit and old.?.slot == command.edit.values.slot and inverse.restore[1] == null;
        try self.publish(store, snapshot, draft, .{ .items = .{ .first = inverse, .second = second, .text_only = text_only } }, .{
            .target = if (snapshot.data.findProfile(scope)) |profile_value| profile_value.name else null,
            .operation = .{ .item = std.meta.activeTag(command) },
        });
        if (selected.len == 0) return null;
        const published = try snapshot.data.itemsFor(selected_scope);
        return published[itemIndex(published, selected) orelse return error.ItemMissing].id;
    }

    /// Returns the affected profile ID if it is still available.
    pub fn profile(self: *History, store: anytype, snapshot: *Snapshot, command: ProfileCommand) !?[]const u8 {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const temp = arena.allocator();
        var draft = try draftData(temp, snapshot.data);
        var profiles = std.ArrayList(Profile).fromOwnedSlice(@constCast(draft.profiles));
        const id: []const u8 = switch (command) {
            .add => try newId(temp),
            .rename => |rename| rename.id,
            .bind => |bind| bind.id,
            .unbind, .delete => |target| target,
        };
        const index = if (command == .add) profiles.items.len else profileIndex(draft.profiles, id) orelse return error.ProfileMissing;
        const labelled = try temp.dupe(u8, id);
        const inverse: UndoChange = switch (command) {
            .add => |add| blk: {
                try profiles.append(temp, .{ .id = id, .name = std.mem.trim(u8, add.name, " \t"), .channel = add.channel });
                break :blk .{ .remove_profile = id };
            },
            .delete => .{ .insert_profile = .{ .index = index, .profile = profiles.orderedRemove(index) } },
            .rename, .bind, .unbind => blk: {
                const profile_value = &profiles.items[index];
                var before = profile_value.*;
                before.items = &.{};
                switch (command) {
                    .rename => |rename| profile_value.name = std.mem.trim(u8, rename.name, " \t"),
                    .bind => |bind| {
                        if (bind.channel.len == 0) return error.MissingChannel;
                        profile_value.channel = bind.channel;
                    },
                    .unbind => profile_value.channel = "",
                    else => unreachable,
                }
                if (equal(u8, before.name, profile_value.name) and equal(u8, before.channel, profile_value.channel)) {
                    return snapshot.data.profiles[index].id;
                }
                break :blk .{ .edit_profile = before };
            },
        };
        draft.profiles = profiles.items;
        try self.publish(store, snapshot, draft, inverse, .{
            .target = if (command == .delete) inverse.insert_profile.profile.name else profiles.items[index].name,
            .operation = .{ .profile = std.meta.activeTag(command) },
        });
        return if (snapshot.data.findProfile(labelled)) |profile_value| profile_value.id else null;
    }

    pub fn assign(self: *History, store: anytype, snapshot: *Snapshot, scope: []const u8, first: []const u8, second: []const u8) !bool {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const temp = arena.allocator();
        var draft = try draftData(temp, snapshot.data);
        const previous = try applyAssignment(temp, &draft, .{ .scope = scope, .ids = .{ first, second } });
        if (equal(u8, first, previous[0]) and equal(u8, second, previous[1])) return false;
        try self.publish(store, snapshot, draft, .{ .assign = .{ .scope = scope, .ids = previous } }, .{
            .target = if (snapshot.data.findProfile(scope)) |profile_value| profile_value.name else null,
            .operation = .assignment,
        });
        return true;
    }

    pub fn undo(self: *History, store: anytype, snapshot: *Snapshot) !bool {
        if (self.length == 0) return false;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const temp = arena.allocator();
        var draft = try draftData(temp, snapshot.data);
        const entry = &self.entries[(self.start + self.length - 1) % self.entries.len];
        var profiles = std.ArrayList(Profile).fromOwnedSlice(@constCast(draft.profiles));
        switch (entry.change) {
            .items => |steps| {
                try applyItemPatch(temp, &draft, steps.first);
                if (steps.second) |second| try applyItemPatch(temp, &draft, second);
            },
            .assign => |assignment| _ = try applyAssignment(temp, &draft, assignment),
            .remove_profile => |id| {
                _ = profiles.orderedRemove(profileIndex(profiles.items, id) orelse return error.ProfileMissing);
                draft.profiles = profiles.items;
            },
            .insert_profile => |prior| {
                try profiles.insert(temp, prior.index, prior.profile);
                draft.profiles = profiles.items;
            },
            .edit_profile => |profile_value| {
                const index = profileIndex(profiles.items, profile_value.id) orelse return error.ProfileMissing;
                profiles.items[index].name = profile_value.name;
                profiles.items[index].channel = profile_value.channel;
            },
        }
        try persist(self.allocator, store, snapshot, draft, entry.change.textEdit());
        entry.arena.deinit();
        self.length -= 1;
        return true;
    }
};

fn persist(allocator: Allocator, store: anytype, snapshot: *Snapshot, source: model.Data, text_edit: ?TextEdit) !void {
    var draft = source;
    if (draft.preferences.input_profile_id.len != 0 and draft.findProfile(draft.preferences.input_profile_id) == null)
        draft.preferences.input_profile_id = "";
    var owned = try Snapshot.clone(allocator, draft);
    errdefer owned.deinit();
    const store_type = @TypeOf(store);
    const Implementation = if (@typeInfo(store_type) == .pointer) @typeInfo(store_type).pointer.child else store_type;
    if (comptime @hasDecl(Implementation, "saveLibraryFromSnapshot")) {
        try store.saveLibraryFromSnapshot(snapshot, &owned, text_edit);
    } else {
        try store.saveLibrary(owned.data);
    }
    snapshot.deinit();
    snapshot.* = owned;
}

fn draftData(temp: Allocator, source: model.Data) !model.Data {
    var draft = source;
    draft.profiles = try temp.dupe(Profile, source.profiles);
    return draft;
}

fn itemDraft(temp: Allocator, source: model.Data, scope: []const u8) !std.ArrayList(Item) {
    return std.ArrayList(Item).fromOwnedSlice(try temp.dupe(Item, try source.itemsFor(scope)));
}

fn setItems(data: *model.Data, scope: []const u8, items: []const Item) !void {
    if (scope.len == 0) data.shared_items = items else {
        const index = profileIndex(data.profiles, scope) orelse return error.ProfileMissing;
        @constCast(data.profiles)[index].items = items;
    }
}

fn applyItemPatch(temp: Allocator, data: *model.Data, patch: ItemPatch) !void {
    var items = try itemDraft(temp, data.*, patch.scope);
    if (patch.remove.len != 0) {
        const index = itemIndex(items.items, patch.remove) orelse return error.ItemMissing;
        _ = items.orderedRemove(index);
    }
    var restore = patch.restore;
    if (restore[0] == null or (restore[1] != null and restore[1].?.index < restore[0].?.index))
        std.mem.swap(?PositionedItem, &restore[0], &restore[1]);
    for (restore) |entry| {
        if (entry) |previous| {
            if (itemIndex(items.items, previous.item.id)) |index| _ = items.orderedRemove(index);
        }
    }
    for (restore) |entry| {
        if (entry) |previous| try items.insert(temp, previous.index, previous.item);
    }
    try setItems(data, patch.scope, items.items);
}

fn applyAssignment(temp: Allocator, data: *model.Data, assignment: Assignment) ![2][]const u8 {
    const first, const second = assignment.ids;
    if (first.len != 0 and equal(u8, first, second)) return error.DuplicateSlot;
    const items = try itemDraft(temp, data.*, assignment.scope);
    var before: [2][]const u8 = .{ "", "" };
    var matched: usize = 0;
    for (items.items) |*candidate| {
        if (candidate.slot != 0) before[candidate.slot - 1] = candidate.id;
        candidate.slot = if (equal(u8, candidate.id, first)) 1 else if (equal(u8, candidate.id, second)) 2 else 0;
        if (candidate.slot != 0) matched += 1;
    }
    if (matched != @as(usize, @intFromBool(first.len != 0)) + @as(usize, @intFromBool(second.len != 0)))
        return error.ItemMissing;
    try setItems(data, assignment.scope, items.items);
    return before;
}

fn itemIndex(items: []const Item, id: []const u8) ?usize {
    for (items, 0..) |entry, index| if (equal(u8, entry.id, id)) return index;
    return null;
}

fn profileIndex(profiles: []const Profile, id: []const u8) ?usize {
    for (profiles, 0..) |entry, index| if (equal(u8, entry.id, id)) return index;
    return null;
}

fn ownedItem(allocator: Allocator, previous: Item) !Item {
    return .{
        .id = try allocator.dupe(u8, previous.id),
        .name = try allocator.dupe(u8, previous.name),
        .text = try allocator.dupe(u8, previous.text),
        .slot = previous.slot,
    };
}

fn ownedProfile(allocator: Allocator, previous: Profile) !Profile {
    const copied = try allocator.alloc(Item, previous.items.len);
    for (copied, previous.items) |*dest, source| dest.* = try ownedItem(allocator, source);
    return .{
        .id = try allocator.dupe(u8, previous.id),
        .name = try allocator.dupe(u8, previous.name),
        .channel = try allocator.dupe(u8, previous.channel),
        .items = copied,
    };
}

fn newId(allocator: Allocator) ![]u8 {
    var nonce: [16]u8 = undefined;
    std.crypto.random.bytes(&nonce);
    nonce[6] = (nonce[6] & 0x0f) | 0x40;
    nonce[8] = (nonce[8] & 0x3f) | 0x80;
    const hex = std.fmt.bytesToHex(nonce, .upper);
    return std.fmt.allocPrint(allocator, "{{{s}-{s}-{s}-{s}-{s}}}", .{ hex[0..8], hex[8..12], hex[12..16], hex[16..20], hex[20..32] });
}
