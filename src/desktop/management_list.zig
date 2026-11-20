const std = @import("std");
const Item = @import("../storage/model.zig").Item;

// Win32 asks for virtual item values independently of model commits. The
// published scope owns its strings even after the model releases its arena.
pub const PublishedList = struct {
    arena: std.heap.ArenaAllocator,
    references: usize = 1,
    scope_id: []const u8,
    rows: []const Item,
    slot_labels: [2][]const u8,

    pub fn capture(memory: std.mem.Allocator, scope_id: []const u8, rows: []const Item, labels: [2][]const u8) !*PublishedList {
        var arena = std.heap.ArenaAllocator.init(memory);
        errdefer arena.deinit();
        const owned = arena.allocator();
        const result = try owned.create(PublishedList);
        const copies = try owned.alloc(Item, rows.len);
        var bytes = scope_id.len + labels[0].len + labels[1].len;
        for (rows) |row| bytes += row.id.len + row.name.len + row.text.len;
        var strings = try owned.alloc(u8, bytes);
        const scope = copyString(&strings, scope_id);
        const owned_labels = [2][]const u8{ copyString(&strings, labels[0]), copyString(&strings, labels[1]) };
        for (rows, copies) |row, *copy| {
            copy.* = .{
                .id = copyString(&strings, row.id),
                .name = copyString(&strings, row.name),
                .text = copyString(&strings, row.text),
                .slot = row.slot,
            };
        }
        result.* = .{ .arena = arena, .scope_id = scope, .rows = copies, .slot_labels = owned_labels };
        return result;
    }

    fn copyString(remaining: *[]u8, source: []const u8) []const u8 {
        const value = remaining.*[0..source.len];
        @memcpy(value, source);
        remaining.* = remaining.*[source.len..];
        return value;
    }

    pub fn matches(self: *const PublishedList, scope_id: []const u8, rows: []const Item, labels: [2][]const u8) bool {
        const equal = std.mem.eql;
        if (self.rows.len != rows.len or !equal(u8, self.scope_id, scope_id) or
            !equal(u8, self.slot_labels[0], labels[0]) or !equal(u8, self.slot_labels[1], labels[1])) return false;
        for (self.rows, rows) |old, new| {
            if (old.slot != new.slot or !equal(u8, old.id, new.id) or
                !equal(u8, old.name, new.name) or !equal(u8, old.text, new.text)) return false;
        }
        return true;
    }

    pub fn retain(self: *PublishedList) *PublishedList {
        self.references += 1;
        return self;
    }

    pub fn release(self: *PublishedList) void {
        self.references -= 1;
        if (self.references != 0) return;
        const arena = self.arena;
        arena.deinit();
    }

    pub fn slotLabel(self: *const PublishedList, slot: u8) []const u8 {
        return if (slot > 0 and slot <= self.slot_labels.len) self.slot_labels[slot - 1] else "";
    }
};
