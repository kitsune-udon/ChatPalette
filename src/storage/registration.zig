const std = @import("std");
const model = @import("model.zig");
const sqlite = @import("sqlite.zig");

pub fn read(allocator: std.mem.Allocator, db: *sqlite.Connection) ![]const model.Registration {
    var out: std.ArrayList(model.Registration) = .empty;
    var bytes: usize = 0;
    var rows = try db.prepare(
        \\SELECT browser,json_set(payload,'$.browser',browser),json_type(payload,'$.browser') IS NULL
        \\FROM reaction_registrations ORDER BY browser
    );
    defer rows.close();
    while (try rows.next()) {
        if (try rows.int(2) != 1) return error.InvalidRegistration;
        const browser = try rows.text(0);
        const payload = try rows.text(1);
        bytes += payload.len;
        if (bytes > model.max_registrations_bytes) return error.RegistrationsTooLarge;
        const validated = try validate(allocator, payload);
        defer allocator.free(validated);
        if (!std.mem.eql(u8, browser, validated)) return error.InvalidRegistration;
        try out.append(allocator, .{
            .browser = try allocator.dupe(u8, browser),
            .payload_json = try allocator.dupe(u8, payload),
        });
    }
    return out.toOwnedSlice(allocator);
}

pub fn validateJsonTree(allocator: std.mem.Allocator, value: std.json.Value) !void {
    switch (value) {
        .object => |object| {
            const FoldedString = struct {
                pub fn hash(_: @This(), key: []const u8) u64 {
                    var hasher = std.hash.Wyhash.init(0);
                    for (key) |byte| {
                        const lowered = [1]u8{std.ascii.toLower(byte)};
                        hasher.update(&lowered);
                    }
                    return hasher.final();
                }

                pub fn eql(_: @This(), a: []const u8, b: []const u8) bool {
                    return std.ascii.eqlIgnoreCase(a, b);
                }
            };
            var keys = std.HashMap([]const u8, void, FoldedString, 80).init(allocator);
            defer keys.deinit();
            var iterator = object.iterator();
            while (iterator.next()) |member| {
                const key = member.key_ptr.*;
                if (std.mem.indexOfScalar(u8, key, 0) != null) return error.InvalidJson;
                if ((try keys.getOrPut(key)).found_existing) return error.DuplicateJsonField;
                try validateJsonTree(allocator, member.value_ptr.*);
            }
        },
        .array => |array| for (array.items) |element| {
            try validateJsonTree(allocator, element);
        },
        .string => |value_string| if (std.mem.indexOfScalar(u8, value_string, 0) != null) return error.InvalidJson,
        else => {},
    }
}

fn field(value: std.json.Value, name: []const u8) !std.json.Value {
    if (value != .object) return error.InvalidRegistration;
    return value.object.get(name) orelse error.InvalidRegistration;
}

const Token = struct {
    name: []const u8,
    id: []const u8,
    class: []const u8,
    control_type: i64,

    fn eql(a: Token, b: Token) bool {
        return a.control_type == b.control_type and std.mem.eql(u8, a.name, b.name) and
            std.mem.eql(u8, a.id, b.id) and std.mem.eql(u8, a.class, b.class);
    }
};

pub fn validate(allocator: std.mem.Allocator, payload_json: []const u8) ![]u8 {
    if (payload_json.len >= model.max_registration_bytes) return error.RegistrationTooLarge;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload_json, .{});
    defer parsed.deinit();
    try validateJsonTree(allocator, parsed.value);

    const name_field = try field(parsed.value, "browser");
    if (name_field != .string) return error.InvalidRegistration;
    const name = name_field.string;
    if (name.len == 0 or name.len > 64 or !std.ascii.isAlphabetic(name[0]))
        return error.InvalidRegistration;
    for (name[1..]) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '_' and ch != '-') return error.InvalidRegistration;
    }

    const tokens = try field(parsed.value, "tokens");
    if (tokens != .array or tokens.array.items.len != 5) return error.InvalidRegistration;
    var unique: [5]Token = undefined;
    for (tokens.array.items, 0..) |token, i| {
        const label = try field(token, "name");
        const id = try field(token, "id");
        const class = try field(token, "class");
        const control_type = try field(token, "type");
        if (label != .string or id != .string or class != .string or control_type != .integer or
            control_type.integer < 50000 or control_type.integer > 50040) return error.InvalidRegistration;
        unique[i] = .{ .name = label.string, .id = id.string, .class = class.string, .control_type = control_type.integer };
        for (unique[0..i]) |previous| if (unique[i].eql(previous)) return error.DuplicateReactionToken;
    }
    return std.ascii.allocLowerString(allocator, name);
}

pub fn save(allocator: std.mem.Allocator, db: *sqlite.Connection, payload: []const u8, expected_browser: ?[]const u8) !void {
    const browser = try validate(allocator, payload);
    defer allocator.free(browser);
    if (expected_browser) |expected| {
        if (!std.mem.eql(u8, expected, browser))
            return error.InvalidRegistration;
        const encoded_browser = try db.scalarText(allocator, "SELECT json_extract(?, '$.browser')", &.{.{ .text = payload }});
        defer allocator.free(encoded_browser);
        if (!std.mem.eql(u8, expected, encoded_browser)) return error.InvalidRegistration;
    }
    try db.run(
        \\INSERT INTO reaction_registrations VALUES(?,json_remove(?,'$.browser'))
        \\ON CONFLICT(browser) DO UPDATE SET payload=excluded.payload
        \\WHERE payload IS NOT excluded.payload
    , &.{ .{ .text = browser }, .{ .text = payload } });
    if (try db.scalarInt(
        "SELECT COALESCE(SUM(length(CAST(json_set(payload,'$.browser',browser) AS BLOB))),0) FROM reaction_registrations",
        &.{},
    ) > model.max_registrations_bytes) return error.RegistrationsTooLarge;
}
