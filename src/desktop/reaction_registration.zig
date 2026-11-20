const std = @import("std");
const win = @import("win.zig").api;
const transport = @import("worker_client.zig");
const operations = @import("operations.zig");
const diagnostic = @import("diagnostics.zig");
const storage = @import("../storage/store.zig");

pub const Preparation = struct {
    mode: transport.Mode,
    target: usize,
    video: operations.VideoId,
    page: operations.PageToken,
    generation: u64,
    due: u64,
    committed: bool = false,
    browser: diagnostic.Browser = .unselected,
    started_at: ?u64 = null,

    pub fn saveCaptured(self: *Preparation, db: *storage.Store, payload: []const u8) !void {
        try db.saveRegistration(payload);
        self.committed = true;
    }

    pub fn retries(mode: transport.Mode, state: []const u8) bool {
        return mode == .reaction_capture and
            (std.mem.eql(u8, state, "unsupported") or std.mem.eql(u8, state, "wrong_window"));
    }
};

pub fn captureFields(point: win.POINT, x: *[11]u8, y: *[11]u8) [2]transport.Field {
    return .{
        .{ .name = "X", .value = std.fmt.bufPrint(x, "{d}", .{point.x}) catch unreachable },
        .{ .name = "Y", .value = std.fmt.bufPrint(y, "{d}", .{point.y}) catch unreachable },
    };
}

test "registration sends signed physical coordinates and only retries registration misses" {
    var x: [11]u8 = undefined;
    var y: [11]u8 = undefined;
    const fields = captureFields(.{ .x = -2147483648, .y = 1200 }, &x, &y);
    try std.testing.expectEqualStrings("X", fields[0].name);
    try std.testing.expectEqualStrings("-2147483648", fields[0].value);
    try std.testing.expectEqualStrings("Y", fields[1].name);
    try std.testing.expectEqualStrings("1200", fields[1].value);
    try std.testing.expect(Preparation.retries(.reaction_capture, "unsupported"));
    try std.testing.expect(Preparation.retries(.reaction_capture, "wrong_window"));
    try std.testing.expect(!Preparation.retries(.reaction_capture, "changed"));
    try std.testing.expect(!Preparation.retries(.reaction_capture, "captured"));
    try std.testing.expect(!Preparation.retries(.reaction_check, "unsupported"));
    try std.testing.expect(!Preparation.retries(.reaction_check, "wrong_window"));
}
