const std = @import("std");
const shortcuts = @import("shortcut_domain");

pub const max_profiles = 10_000;
pub const max_items = 100_000;
pub const max_file_bytes = 128 * 1024 * 1024;
pub const max_text_bytes = 32 * 1024 * 1024;
pub const max_registration_bytes = 8_192;
pub const max_registrations_bytes = 24_000;
pub const shared_id = "@shared";

pub const Action = shortcuts.Action;
pub const action_count = shortcuts.action_count;
pub const default_shortcut_keys = shortcuts.default_keys;

pub const Item = struct {
    id: []const u8,
    name: []const u8,
    text: []const u8,
    slot: u8 = 0,
};

pub const Profile = struct {
    id: []const u8,
    name: []const u8,
    channel: []const u8 = "",
    items: []const Item = &.{},
};

pub const Preferences = struct {
    pub const reaction_counts = [_]u32{ 1, 10, 100, 1_000, 10_000 };
    pub const reaction_intervals = [_]u32{ 0, 25, 50, 100, 150, 200, 250, 500, 1000 };

    input_profile_id: []const u8 = "",
    auto_mode: bool = true,
    reaction_kind: u8 = 1,
    reaction_count: u32 = 1,
    reaction_interval_ms: u32 = 200,
    shortcut_keys: shortcuts.Keys = default_shortcut_keys,
};

pub const Registration = struct {
    browser: []const u8,
    /// A JSON object including its browser, as required by JSON2 and the worker.
    payload_json: []const u8,
};

pub const Data = struct {
    preferences: Preferences = .{},
    profiles: []const Profile = &.{},
    shared_items: []const Item = &.{},
    registrations: []const Registration = &.{},

    pub fn findProfile(self: Data, id: []const u8) ?*const Profile {
        for (self.profiles) |*profile| {
            if (std.mem.eql(u8, profile.id, id)) return profile;
        }
        return null;
    }

    pub fn itemsFor(self: Data, profile_id: []const u8) ![]const Item {
        if (profile_id.len == 0) return self.shared_items;
        if (self.findProfile(profile_id)) |profile| return profile.items;
        return error.ProfileMissing;
    }

    pub fn eql(a: Data, b: Data) bool {
        const stringEqual = std.mem.eql;
        const x = a.preferences;
        const y = b.preferences;
        if (x.auto_mode != y.auto_mode or
            x.reaction_kind != y.reaction_kind or x.reaction_count != y.reaction_count or
            x.reaction_interval_ms != y.reaction_interval_ms) return false;
        for (x.shortcut_keys, y.shortcut_keys) |left, right| {
            if (!stringEqual(u8, left, right)) return false;
        }
        if (!libraryEql(a, b) or a.registrations.len != b.registrations.len) return false;
        for (a.registrations, b.registrations) |left, right| {
            if (!stringEqual(u8, left.browser, right.browser) or
                !stringEqual(u8, left.payload_json, right.payload_json)) return false;
        }
        return true;
    }

    pub fn libraryEql(a: Data, b: Data) bool {
        const stringEqual = std.mem.eql;
        if (!stringEqual(u8, a.preferences.input_profile_id, b.preferences.input_profile_id) or
            !itemListsEqual(a.shared_items, b.shared_items) or a.profiles.len != b.profiles.len) return false;
        for (a.profiles, b.profiles) |left, right| {
            if (!stringEqual(u8, left.id, right.id) or !stringEqual(u8, left.name, right.name) or
                !stringEqual(u8, left.channel, right.channel) or !itemListsEqual(left.items, right.items)) return false;
        }
        return true;
    }
};

fn itemListsEqual(a: []const Item, b: []const Item) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!std.mem.eql(u8, x.id, y.id) or !std.mem.eql(u8, x.name, y.name) or
            !std.mem.eql(u8, x.text, y.text) or x.slot != y.slot) return false;
    }
    return true;
}

pub const LibraryRevision = struct {
    data_version: i64,
    writes: i64,
    schema: i64,
    temp_schema: i64,
};

pub const LibraryOrigin = struct {
    connection: u128,
    revision: LibraryRevision,
    text_bytes: usize,
};

/// All slices are owned by the arena unless supplied in a short-lived draft.
pub const Snapshot = struct {
    arena: std.heap.ArenaAllocator,
    data: Data = .{},
    // Set only for a library read or written in a validated DB transaction.
    library_origin: ?LibraryOrigin = null,
    retained: ?*LibraryArena = null,

    const LibraryArena = struct {
        arena: std.heap.ArenaAllocator,
        references: usize = 1,

        fn release(self: *LibraryArena) void {
            self.references -= 1;
            if (self.references != 0) return;
            const allocator = self.arena.child_allocator;
            self.arena.deinit();
            allocator.destroy(self);
        }
    };

    pub const LibraryLease = struct {
        owner: *LibraryArena,
        profiles: []const Profile,
        shared_items: []const Item,

        pub fn read(self: LibraryLease) Data {
            return .{ .profiles = self.profiles, .shared_items = self.shared_items };
        }

        pub fn release(self: LibraryLease) void {
            self.owner.release();
        }
    };

    pub fn init(allocator: std.mem.Allocator) Snapshot {
        return .{ .arena = std.heap.ArenaAllocator.init(allocator) };
    }

    pub fn deinit(self: *Snapshot) void {
        self.arena.deinit();
        if (self.retained) |owner| owner.release();
        self.* = undefined;
    }

    // Keep the published library alive through a queued operation without copying its items.
    pub fn retainLibrary(self: *Snapshot) !LibraryLease {
        const owner = self.retained orelse first: {
            const allocator = self.arena.child_allocator;
            const retained = try allocator.create(LibraryArena);
            retained.* = .{ .arena = self.arena };
            self.arena = std.heap.ArenaAllocator.init(allocator);
            self.retained = retained;
            break :first retained;
        };
        owner.references += 1;
        return .{ .owner = owner, .profiles = self.data.profiles, .shared_items = self.data.shared_items };
    }

    pub fn clone(allocator: std.mem.Allocator, data: Data) !Snapshot {
        var result = Snapshot.init(allocator);
        errdefer result.deinit();
        const owned = result.arena.allocator();
        result.data.preferences = data.preferences;
        result.data.preferences.input_profile_id = try owned.dupe(u8, data.preferences.input_profile_id);
        for (&result.data.preferences.shortcut_keys) |*key| key.* = try owned.dupe(u8, key.*);
        const profiles = try owned.alloc(Profile, data.profiles.len);
        for (profiles, data.profiles) |*dst, src| dst.* = .{
            .id = try owned.dupe(u8, src.id),
            .name = try owned.dupe(u8, src.name),
            .channel = try owned.dupe(u8, src.channel),
            .items = try copyItems(owned, src.items),
        };
        result.data.profiles = profiles;
        result.data.shared_items = try copyItems(owned, data.shared_items);
        const registrations = try owned.alloc(Registration, data.registrations.len);
        for (registrations, data.registrations) |*dst, src| dst.* = .{
            .browser = try owned.dupe(u8, src.browser),
            .payload_json = try owned.dupe(u8, src.payload_json),
        };
        result.data.registrations = registrations;
        return result;
    }
};

fn copyItems(allocator: std.mem.Allocator, items: []const Item) ![]Item {
    const copy = try allocator.alloc(Item, items.len);
    for (copy, items) |*dst, src| dst.* = .{
        .id = try allocator.dupe(u8, src.id),
        .name = try allocator.dupe(u8, src.name),
        .text = try allocator.dupe(u8, src.text),
        .slot = src.slot,
    };
    return copy;
}

pub fn validatePreferences(prefs: Preferences) !shortcuts.Bindings {
    if (prefs.reaction_kind < 1 or prefs.reaction_kind > 6 or
        std.mem.indexOfScalar(u32, &Preferences.reaction_counts, prefs.reaction_count) == null or
        std.mem.indexOfScalar(u32, &Preferences.reaction_intervals, prefs.reaction_interval_ms) == null)
        return error.InvalidPreferences;
    if (prefs.input_profile_id.len != 0 and !validIdentity(prefs.input_profile_id)) return error.InvalidProfileId;
    return shortcuts.validate(prefs.shortcut_keys);
}

fn textBytes(value: []const u8, required: bool) !usize {
    if (std.mem.indexOfAny(u8, value, "\x00\r\n") != null or
        (required and std.mem.trim(u8, value, " \t").len == 0))
        return error.InvalidText;
    const units = try std.unicode.calcUtf16LeLen(value);
    if (units > 16 * 1024 * 1024) return error.TextTooLong;
    return units * 2;
}

fn validIdentity(value: []const u8) bool {
    return value.len != 0 and std.mem.indexOfScalar(u8, value, 0) == null and std.unicode.utf8ValidateSlice(value);
}

pub fn isReservedScope(id: []const u8) bool {
    return std.ascii.eqlIgnoreCase(shared_id, id);
}

pub fn validate(allocator: std.mem.Allocator, data: Data) !void {
    _ = try validatedTextBytes(allocator, data);
}

pub fn validatedTextBytes(allocator: std.mem.Allocator, data: Data) !usize {
    _ = try validatePreferences(data.preferences);
    if (data.profiles.len > max_profiles) return error.TooManyProfiles;
    var profiles = std.StringHashMap(void).init(allocator);
    defer profiles.deinit();
    var channels = std.StringHashMap(void).init(allocator);
    defer channels.deinit();
    var items = std.StringHashMap(void).init(allocator);
    defer items.deinit();
    var count: usize = 0;
    var bytes = try validateItems(&items, data.shared_items, &count);
    for (data.profiles) |profile| {
        if (!validIdentity(profile.id) or isReservedScope(profile.id) or (try profiles.getOrPut(profile.id)).found_existing)
            return error.InvalidProfileId;
        bytes += try textBytes(profile.name, true);
        bytes += try textBytes(profile.channel, false);
        if (profile.channel.len != 0 and (try channels.getOrPut(profile.channel)).found_existing)
            return error.DuplicateChannel;
        bytes += try validateItems(&items, profile.items, &count);
        if (bytes > max_text_bytes) return error.TotalTextTooLong;
    }
    if (bytes > max_text_bytes) return error.TotalTextTooLong;
    const active = data.preferences.input_profile_id;
    if (active.len != 0 and !profiles.contains(active)) return error.ProfileMissing;
    return bytes;
}

pub fn itemTextBytes(name: []const u8, body: []const u8) !usize {
    return (try textBytes(name, true)) + (try textBytes(body, true));
}

fn validateItems(known: *std.StringHashMap(void), items: []const Item, count: *usize) !usize {
    if (items.len > max_items - count.*) return error.TooManyItems;
    count.* += items.len;
    var bytes: usize = 0;
    var slots: u3 = 0;
    for (items) |item| {
        if (!validIdentity(item.id) or (try known.getOrPut(item.id)).found_existing)
            return error.InvalidItemId;
        if (item.slot > 2) return error.InvalidSlot;
        if (item.slot != 0) {
            const bit = @as(u3, 1) << @as(u2, @intCast(item.slot));
            if (slots & bit != 0) return error.DuplicateSlot;
            slots |= bit;
        }
        bytes += try itemTextBytes(item.name, item.text);
        if (bytes > max_text_bytes) return error.TotalTextTooLong;
    }
    return bytes;
}
