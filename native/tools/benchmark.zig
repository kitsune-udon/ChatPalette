const std = @import("std");
const store = @import("storage");
const files = @import("files.zig");
const process = @import("process.zig");
const samples = @import("samples.zig");
const Sample = samples.Sample;

const measurement_file = "measurements.json";

const Operation = enum {
    edit,
    swap,
    undo,
    reverse,
    validate,
    load,
};

fn measure(
    alloc: std.mem.Allocator,
    db: *store.Store,
    baseline: store.Data,
    operation: Operation,
    repeats: usize,
) !Sample {
    const original = baseline.shared_items;
    const edited = try alloc.dupe(store.Item, original);
    defer alloc.free(edited);
    const middle = original.len / 2;
    var target = baseline;
    switch (operation) {
        .edit => edited[middle].text = "edited",
        .swap, .undo => if (original.len > 1) {
            const other = middle - 1;
            std.mem.swap(store.Item, &edited[middle], &edited[other]);
        },
        .reverse => std.mem.reverse(store.Item, edited),
        .validate, .load => {},
    }
    if (operation != .undo) target.shared_items = edited;
    if (operation == .validate) try db.saveLibrary(baseline);
    const sample_values = try alloc.alloc(f64, repeats);
    var timer = try std.time.Timer.start();
    for (0..repeats + 1) |iteration| {
        // Restore the precondition outside the timed interval.
        if (operation == .undo) {
            var changed = baseline;
            changed.shared_items = edited;
            try db.saveLibrary(changed);
        } else if (operation != .load and operation != .validate) {
            try db.saveLibrary(baseline);
        }
        var elapsed: f64 = undefined;
        var snapshot: store.Snapshot = undefined;
        switch (operation) {
            .load => {
                timer.reset();
                snapshot = try db.load(std.heap.page_allocator);
                elapsed = samples.milliseconds(&timer);
            },
            .validate => {
                timer.reset();
                try store.validate(alloc, target);
                elapsed = samples.milliseconds(&timer);
                snapshot = try db.load(std.heap.page_allocator);
            },
            else => {
                timer.reset();
                try db.saveLibrary(target);
                elapsed = samples.milliseconds(&timer);
                snapshot = try db.load(std.heap.page_allocator);
            },
        }
        defer snapshot.deinit();
        if (!target.eql(snapshot.data)) {
            const actual = snapshot.data;
            std.debug.print("合成計測の照合失敗　{d}件 {s} {d}回目　読戻し件数 {d}\n", .{
                original.len, @tagName(operation), iteration + 1, actual.shared_items.len,
            });
            for (target.shared_items[0..@min(target.shared_items.len, actual.shared_items.len)], actual.shared_items[0..@min(target.shared_items.len, actual.shared_items.len)], 0..) |want, observed, row| {
                if (!std.mem.eql(u8, want.id, observed.id) or !std.mem.eql(u8, want.name, observed.name) or
                    !std.mem.eql(u8, want.text, observed.text) or want.slot != observed.slot)
                {
                    std.debug.print("合成データの先頭不一致 行 {d}　弾幕ID {s} / {s}\n", .{ row + 1, want.id, observed.id });
                    break;
                }
            }
            return error.MeasurementChangedData;
        }
        if (iteration != 0) sample_values[iteration - 1] = elapsed;
    }
    return samples.summarize(alloc, original.len, @tagName(operation), sample_values);
}

fn dataBench(
    alloc: std.mem.Allocator,
    output: []const u8,
    repeats: usize,
    counts: []const usize,
    load_only: bool,
) ![]const Sample {
    const operations: []const Operation = if (load_only) &.{.load} else &.{ .edit, .swap, .undo, .reverse, .validate };
    const result = try alloc.alloc(Sample, counts.len * operations.len);
    for (counts, 0..) |count, index| {
        var fixture = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer fixture.deinit();
        const scratch = fixture.allocator();
        const path = try std.fs.path.join(scratch, &.{ output, try std.fmt.allocPrint(scratch, "synthetic-{d}.db", .{count}) });
        var db = try store.Store.open(std.heap.page_allocator, path);
        defer db.close();
        const data = try samples.synthetic(store, scratch, count);
        try db.save(data);
        for (operations, result[index * operations.len ..][0..operations.len]) |operation, *slot| {
            slot.* = try measure(alloc, &db, data, operation, repeats);
        }
    }
    return result;
}

fn startupBench(
    alloc: std.mem.Allocator,
    output: []const u8,
    repeats: usize,
    exe: []const u8,
) ![]const Sample {
    const bytes = try std.fs.cwd().readFileAlloc(alloc, exe, 256 * 1024 * 1024);
    const hash = files.digest(bytes);
    const home = try std.fs.path.join(alloc, &.{ output, "runtime" });
    try std.fs.cwd().makeDir(home);
    var runtime = try std.fs.cwd().openDir(home, .{ .no_follow = true });
    defer runtime.close();
    try files.writeNew(runtime, "ChatPalette.exe", bytes);
    const app = try std.fs.path.join(alloc, &.{ home, "ChatPalette.exe" });
    const warmup_path = try std.fs.path.join(alloc, &.{ output, "warmup" });
    try std.fs.cwd().makeDir(warmup_path);
    var warmup = try std.fs.cwd().openDir(warmup_path, .{ .no_follow = true });
    defer warmup.close();
    if (!(try process.run(alloc, &.{ app, "--smoke" }, home, warmup, 120_000)).passed()) return error.BenchmarkTestFailed;
    const database = "data/settings.db";
    const data_sha = try files.readDigest(runtime, database);
    const measurements = try alloc.alloc(f64, repeats);
    for (measurements, 1..) |*value, i| {
        const path = try std.fs.path.join(alloc, &.{ output, try std.fmt.allocPrint(alloc, "trial-{d}", .{i}) });
        try std.fs.cwd().makeDir(path);
        var trial = try std.fs.cwd().openDir(path, .{ .no_follow = true });
        defer trial.close();
        const result = try process.run(alloc, &.{ app, "--smoke" }, home, trial, 120_000);
        if (!result.passed()) return error.BenchmarkTestFailed;
        if (!std.mem.eql(u8, &hash, &(try files.readDigest(runtime, "ChatPalette.exe")))) return error.ExecutableChangedDuringTest;
        if (!std.mem.eql(u8, &data_sha, &(try files.readDigest(runtime, database)))) return error.BenchmarkChangedDatabase;
        value.* = @floatFromInt(result.elapsed_ms);
    }
    const summary = try alloc.alloc(Sample, 1);
    summary[0] = try samples.summarize(alloc, 0, "process_start_to_smoke_exit", measurements);
    return summary;
}

pub fn run(allocator: std.mem.Allocator, mode: []const u8, output: []const u8, raw_repeats: []const u8, data: []const []const u8) !void {
    const repeats = try std.fmt.parseUnsigned(usize, raw_repeats, 10);
    if (repeats < 1 or repeats > 100) return error.InvalidBenchmarkRepeats;
    const startup = std.mem.eql(u8, mode, "startup");
    const load_only = std.mem.eql(u8, mode, "load");
    if (startup) {
        if (data.len != 1) return error.InvalidArguments;
    } else if (!load_only and !std.mem.eql(u8, mode, "storage")) {
        return error.InvalidArguments;
    }
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const counts: []const usize = if (startup) &.{} else try samples.parseCounts(alloc, data);
    try std.fs.cwd().makeDir(output);
    const absolute = try std.fs.cwd().realpathAlloc(alloc, output);
    const summary = if (startup)
        try startupBench(alloc, absolute, repeats, data[0])
    else
        try dataBench(alloc, absolute, repeats, counts, load_only);
    const report = try std.json.Stringify.valueAlloc(alloc, .{
        .mode = mode,
        .repeats = repeats,
        .warmups = @as(u8, 1),
        .measurements = summary,
    }, .{ .whitespace = .indent_2 });
    var directory = try std.fs.cwd().openDir(absolute, .{ .no_follow = true });
    defer directory.close();
    try files.writeNew(directory, measurement_file, report);
}
