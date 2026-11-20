const std = @import("std");
const storage = @import("../storage/model.zig");
const win = @import("win.zig").api;
const allocator = std.heap.page_allocator;

pub const max_rows = 500;
pub const Row = struct { item: storage.Item, profile_id: []const u8 };

extern "kernel32" fn FindStringOrdinal(win.DWORD, [*]const u16, c_int, [*]const u16, c_int, win.BOOL) callconv(.winapi) c_int;

pub const ItemRows = struct {
    rows: [max_rows]Row = undefined,
    count: usize = 0,

    pub fn collect(self: *ItemRows, items: []const storage.Item, profile_id: []const u8, query: []const u8) bool {
        for (items) |item| {
            if (!matchesQuery(query, item)) continue;
            if (self.count == self.rows.len) return true;
            self.rows[self.count] = .{ .item = item, .profile_id = profile_id };
            self.count += 1;
        }
        return false;
    }
};

fn matchesQuery(query: []const u8, item: storage.Item) bool {
    if (query.len == 0) return true;
    var fallback = std.heap.stackFallback(2048, allocator);
    const scratch = fallback.get();
    const joined = std.fmt.allocPrint(scratch, "{s} {s}", .{ item.name, item.text }) catch return false;
    defer scratch.free(joined);
    if (std.ascii.indexOfIgnoreCase(joined, query) != null) return true;
    if (asciiOnly(joined) and asciiOnly(query)) return false;
    const source = std.unicode.utf8ToUtf16LeAlloc(scratch, joined) catch return false;
    defer scratch.free(source);
    const target = std.unicode.utf8ToUtf16LeAlloc(scratch, query) catch return false;
    defer scratch.free(target);
    return FindStringOrdinal(win.FIND_FROMSTART, source.ptr, @intCast(source.len), target.ptr, @intCast(target.len), 1) >= 0;
}

fn asciiOnly(value: []const u8) bool {
    for (value) |ch| if (!std.ascii.isAscii(ch)) return false;
    return true;
}

test "palette matches across name and text and folds Unicode case" {
    const item = storage.Item{ .id = "1", .name = "Ä弾幕", .text = "日本語 😀", .slot = 0 };
    try std.testing.expect(matchesQuery("ä弾幕 日", item));
    try std.testing.expect(matchesQuery("日本語", item));
    try std.testing.expect(!matchesQuery("別", item));
}
