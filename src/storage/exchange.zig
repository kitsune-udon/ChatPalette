const std = @import("std");
const model = @import("model.zig");
const registration = @import("registration.zig");
const sqlite = @import("sqlite.zig");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

pub fn readFile(allocator: Allocator, path: []const u8) !model.Snapshot {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const size = try file.getEndPos();
    if (size == 0 or size > model.max_file_bytes) return error.InvalidJsonSize;
    const bytes = try file.readToEndAlloc(allocator, model.max_file_bytes);
    defer allocator.free(bytes);
    const json = if (std.mem.startsWith(u8, bytes, "\xef\xbb\xbf")) bytes[3..] else bytes;
    if (!std.unicode.utf8ValidateSlice(json)) return error.InvalidJsonEncoding;

    // The same SQLite JSON grammar is used for preserved registration objects.
    var db = try sqlite.Connection.open(allocator, ":memory:", .create);
    defer db.close();
    if (try db.scalarInt("SELECT json_valid(?)", &.{.{ .text = json }}) != 1) return error.InvalidJson;

    var snapshot = model.Snapshot.init(allocator);
    errdefer snapshot.deinit();
    const owned = snapshot.arena.allocator();
    const document = try std.json.parseFromSliceLeaky(Value, owned, json, .{
        .allocate = .alloc_always,
        .parse_numbers = false,
    });
    try registration.validateJsonTree(allocator, document);
    try expectShape(document, .{ "format", "version", "profiles", "sharedItems", "preferences", "reactionRegistrations" });
    if (!std.mem.eql(u8, try string(document, "format"), "ChatPalette") or try integer(u32, document, "version") != 2)
        return error.UnsupportedJsonVersion;
    snapshot.data.preferences = try readPreferences(try field(document, "preferences"));
    var count: usize = 0;
    snapshot.data.shared_items = try readItems(owned, try array(document, "sharedItems"), &count);
    const profile_values = try array(document, "profiles");
    if (profile_values.len > model.max_profiles) return error.TooManyProfiles;
    const profiles = try owned.alloc(model.Profile, profile_values.len);
    for (profiles, profile_values) |*profile, value| {
        try expectShape(value, .{ "id", "name", "channel", "items" });
        profile.* = .{
            .id = try string(value, "id"),
            .name = try string(value, "name"),
            .channel = try string(value, "channel"),
            .items = try readItems(owned, try array(value, "items"), &count),
        };
    }
    snapshot.data.profiles = profiles;
    snapshot.data.registrations = try readRegistrations(owned, &db, json, (try array(document, "reactionRegistrations")).len);
    try model.validate(allocator, snapshot.data);
    return snapshot;
}

fn field(object: Value, name: []const u8) !Value {
    if (object != .object) return error.InvalidJsonShape;
    return object.object.get(name) orelse error.InvalidJsonShape;
}

fn expectShape(object: Value, comptime names: anytype) !void {
    if (object != .object or object.object.count() != names.len) return error.InvalidJsonShape;
    inline for (names) |name| {
        if (!object.object.contains(name)) return error.InvalidJsonShape;
    }
}

fn string(object: Value, name: []const u8) ![]const u8 {
    const value = try field(object, name);
    if (value != .string) return error.InvalidJsonShape;
    return value.string;
}

fn integer(comptime T: type, object: Value, name: []const u8) !T {
    const value = try field(object, name);
    if (value != .number_string) return error.InvalidJsonShape;
    for (value.number_string, 0..) |char, i| {
        if (!std.ascii.isDigit(char) and !(i == 0 and char == '-'))
            return error.InvalidJsonShape;
    }
    const parsed = std.fmt.parseInt(i64, value.number_string, 10) catch return error.InvalidJsonShape;
    return std.math.cast(T, parsed) orelse error.InvalidJsonShape;
}

fn array(object: Value, name: []const u8) ![]const Value {
    const value = try field(object, name);
    if (value != .array) return error.InvalidJsonShape;
    return value.array.items;
}

fn readPreferences(object: Value) !model.Preferences {
    try expectShape(object, .{ "inputProfileId", "autoMode", "reactionKind", "reactionCount", "reactionIntervalMs", "shortcutKeys" });
    const auto_mode = try integer(u8, object, "autoMode");
    if (auto_mode > 1) return error.InvalidPreferences;
    const key_values = try field(object, "shortcutKeys");
    if (key_values != .object or key_values.object.count() != model.action_count)
        return error.InvalidShortcut;
    var keys: [model.action_count][]const u8 = undefined;
    for (std.enums.values(model.Action), &keys) |action, *key|
        key.* = try string(key_values, @tagName(action));
    return .{
        .input_profile_id = try string(object, "inputProfileId"),
        .auto_mode = auto_mode == 1,
        .reaction_kind = try integer(u8, object, "reactionKind"),
        .reaction_count = try integer(u32, object, "reactionCount"),
        .reaction_interval_ms = try integer(u32, object, "reactionIntervalMs"),
        .shortcut_keys = keys,
    };
}

fn readItems(allocator: Allocator, values: []const Value, total: *usize) ![]const model.Item {
    if (values.len > model.max_items - total.*) return error.TooManyItems;
    total.* += values.len;
    const items = try allocator.alloc(model.Item, values.len);
    for (items, values) |*item, value| {
        try expectShape(value, .{ "id", "name", "text", "slot" });
        item.* = .{
            .id = try string(value, "id"),
            .name = try string(value, "name"),
            .text = try string(value, "text"),
            .slot = try integer(u8, value, "slot"),
        };
    }
    return items;
}

fn readRegistrations(allocator: Allocator, db: *sqlite.Connection, json: []const u8, count: usize) ![]const model.Registration {
    const registrations = try allocator.alloc(model.Registration, count);
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();
    var rows = try db.prepare(
        \\SELECT type,value,json_extract(value,'$.browser') FROM json_each(?,'$.reactionRegistrations')
    );
    defer rows.close();
    try rows.bind(&.{.{ .text = json }});
    var size: usize = 0;
    for (registrations) |*result| {
        if (!try rows.next() or !std.mem.eql(u8, try rows.text(0), "object"))
            return error.InvalidRegistration;
        const payload = try rows.text(1);
        size += payload.len;
        if (size > model.max_registrations_bytes) return error.RegistrationsTooLarge;
        const browser = try registration.validate(allocator, payload);
        if (!std.mem.eql(u8, browser, try rows.text(2)))
            return error.InvalidRegistration;
        if ((try seen.getOrPut(browser)).found_existing) return error.DuplicateRegistration;
        result.* = .{ .browser = browser, .payload_json = try allocator.dupe(u8, payload) };
    }
    if (try rows.next()) return error.InvalidRegistration;
    return registrations;
}

pub fn write(allocator: Allocator, data: model.Data) ![]u8 {
    var writer = std.Io.Writer.Allocating.init(allocator);
    defer writer.deinit();
    var output: std.json.Stringify = .{ .writer = &writer.writer };
    try output.beginObject();
    try output.objectField("format");
    try output.write("ChatPalette");
    try output.objectField("version");
    try output.write(@as(u8, 2));
    try output.objectField("profiles");
    try output.beginArray();
    for (data.profiles) |profile| {
        try output.write(.{ .id = profile.id, .name = profile.name, .channel = profile.channel, .items = profile.items });
        if (writer.written().len > model.max_file_bytes) return error.InvalidJsonSize;
    }
    try output.endArray();
    try output.objectField("sharedItems");
    try output.write(data.shared_items);
    try output.objectField("preferences");
    try output.beginObject();
    const prefs = data.preferences;
    try output.objectField("inputProfileId");
    try output.write(prefs.input_profile_id);
    try output.objectField("autoMode");
    try output.write(@as(u8, @intFromBool(prefs.auto_mode)));
    try output.objectField("reactionKind");
    try output.write(prefs.reaction_kind);
    try output.objectField("reactionCount");
    try output.write(prefs.reaction_count);
    try output.objectField("reactionIntervalMs");
    try output.write(prefs.reaction_interval_ms);
    try output.objectField("shortcutKeys");
    try output.beginObject();
    for (std.enums.values(model.Action), prefs.shortcut_keys) |action, key| {
        try output.objectField(@tagName(action));
        try output.write(key);
    }
    try output.endObject();
    try output.endObject();
    try output.objectField("reactionRegistrations");
    try output.beginArray();
    for (data.registrations) |registration_value| {
        try output.beginWriteRaw();
        try output.writer.writeAll(registration_value.payload_json);
        output.endWriteRaw();
    }
    try output.endArray();
    try output.endObject();
    try output.writer.writeByte('\n');
    if (writer.written().len > model.max_file_bytes) return error.InvalidJsonSize;
    return writer.toOwnedSlice();
}
