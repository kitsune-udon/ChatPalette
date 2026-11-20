const std = @import("std");

pub const Sample = struct {
    items: usize,
    operation: []const u8,
    median_ms: f64,
    max_ms: f64,
    samples_ms: []const f64,
};

pub fn summarize(alloc: std.mem.Allocator, items: usize, operation: []const u8, samples: []const f64) !Sample {
    const sorted = try alloc.dupe(f64, samples);
    defer alloc.free(sorted);
    std.mem.sort(f64, sorted, {}, std.sort.asc(f64));
    const middle = sorted.len / 2;
    const median = if (sorted.len % 2 == 0) (sorted[middle - 1] + sorted[middle]) / 2 else sorted[middle];
    return .{ .items = items, .operation = operation, .median_ms = median, .max_ms = sorted[sorted.len - 1], .samples_ms = samples };
}

pub fn milliseconds(timer: *std.time.Timer) f64 {
    return @as(f64, @floatFromInt(timer.read())) / std.time.ns_per_ms;
}

pub fn parseCounts(alloc: std.mem.Allocator, args: []const []const u8) ![]const usize {
    if (args.len == 0) return &.{ 1_000, 10_000, 100_000 };
    const counts = try alloc.alloc(usize, args.len);
    errdefer alloc.free(counts);
    for (args, counts, 0..) |argument, *count, index| {
        count.* = try std.fmt.parseUnsigned(usize, argument, 10);
        if (count.* < 1 or count.* > 100_000 or std.mem.indexOfScalar(usize, counts[0..index], count.*) != null) {
            return error.InvalidBenchmarkCount;
        }
    }
    return counts;
}

pub fn synthetic(comptime Store: type, alloc: std.mem.Allocator, count: usize) !Store.Data {
    const items = try alloc.alloc(Store.Item, count);
    for (items, 1..) |*item, i| {
        item.* = .{
            .id = try std.fmt.allocPrint(alloc, "bench-{d}", .{i}),
            .name = try std.fmt.allocPrint(alloc, "item {d}", .{i}),
            .text = try std.fmt.allocPrint(alloc, "synthetic body {d}", .{i}),
        };
    }
    return .{ .shared_items = items, .preferences = .{ .auto_mode = false } };
}
