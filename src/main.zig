const std = @import("std");
const desktop = @import("desktop/main.zig");
const worker = @import("worker/main.zig");

const Entry = union(enum) {
    desktop: desktop.Startup,
    worker: []const u8,
};

fn parse(args: []const []const u8) !Entry {
    if (args.len == 0) return .{ .desktop = .normal };
    if (args.len == 1) {
        if (std.mem.eql(u8, args[0], "--smoke")) return .{ .desktop = .smoke };
        if (std.mem.eql(u8, args[0], "--quiet")) return .{ .desktop = .quiet };
    }
    if (args.len == 2 and std.mem.eql(u8, args[0], "-PipeName"))
        return .{ .worker = args[1] };
    return error.InvalidStartupArguments;
}

pub fn main() void {
    const allocator = std.heap.page_allocator;
    const args = std.process.argsAlloc(allocator) catch |err| return fatal(err);
    defer std.process.argsFree(allocator, args);
    const entry = parse(args[1..]) catch {
        std.debug.print("起動引数が不正です。引数なし、--smoke、--quiet のいずれかで起動してください。\n", .{});
        std.process.exit(1);
    };
    switch (entry) {
        .desktop => |mode| desktop.run(mode) catch |err| fatal(err),
        .worker => |name| worker.run(name) catch |err| fatal(err),
    }
}

fn fatal(err: anyerror) void {
    std.debug.print("ChatPalette: {s}\n", .{@errorName(err)});
    std.process.exit(1);
}

test "the executable chooses its role before initializing a desktop instance" {
    try std.testing.expectEqual(desktop.Startup.normal, (try parse(&.{})).desktop);
    try std.testing.expectEqual(desktop.Startup.quiet, (try parse(&.{"--quiet"})).desktop);
    try std.testing.expectEqual(desktop.Startup.smoke, (try parse(&.{"--smoke"})).desktop);
    try std.testing.expectEqualStrings("test-worker", (try parse(&.{ "-PipeName", "test-worker" })).worker);
    try std.testing.expectError(error.InvalidStartupArguments, parse(&.{"--check"}));
    try std.testing.expectError(error.InvalidStartupArguments, parse(&.{ "--quiet", "--smoke" }));
}

test {
    _ = @import("desktop/shortcuts.zig");
    _ = @import("desktop/operations.zig");
    _ = @import("desktop/worker_client.zig");
    _ = @import("storage/store.zig");
    _ = worker;
}
