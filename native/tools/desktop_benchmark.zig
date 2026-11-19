const std = @import("std");
const storage = @import("../storage/store.zig");
const palette = @import("../desktop/palette.zig");
const management = @import("../desktop/management.zig");
const windows = @import("../desktop/win.zig");
const samples = @import("samples.zig");
const files = @import("files.zig");
const win = windows.api;

fn repaint(hwnd: win.HWND) !void {
    if (win.RedrawWindow(hwnd, null, null, win.RDW_INVALIDATE | win.RDW_ALLCHILDREN | win.RDW_UPDATENOW) == 0) {
        return error.CouldNotRepaintBenchmarkWindow;
    }
}

fn arrange(hwnd: win.HWND) !void {
    // Measure synchronous paint without moving the foreground or sending keyboard input.
    _ = win.ShowWindow(hwnd, win.SW_SHOWNOACTIVATE);
    if (win.IsWindowVisible(hwnd) == 0) return error.BenchmarkWindowNotVisible;
    try repaint(hwnd);
}

const Operation = enum { management_first, management_update, palette_list, palette_search };

fn measure(
    alloc: std.mem.Allocator,
    panel: *palette.Palette,
    manager: *management.Management,
    connection: *storage.Store,
    snapshot: *storage.Snapshot,
    history: *storage.LibraryHistory,
    operation: Operation,
    repeats: usize,
) !samples.Sample {
    const count = snapshot.data.shared_items.len;
    const count_expected: usize = if (operation == .palette_search) blk: {
        var num: usize = 0;
        for (snapshot.data.shared_items) |item| {
            if (std.mem.indexOf(u8, item.text, "body 9") != null) num += 1;
        }
        break :blk @min(num, 500);
    } else @min(count, 500);
    const readings = try alloc.alloc(f64, repeats);
    var timer = try std.time.Timer.start();
    for (0..repeats + 1) |iteration| {
        var elapsed: f64 = undefined;
        switch (operation) {
            .management_first => {
                manager.close();
                timer.reset();
                try manager.open(panel.window, connection, snapshot, history);
                try arrange(manager.window);
                elapsed = samples.milliseconds(&timer);
            },
            .management_update => {
                timer.reset();
                manager.refresh();
                elapsed = samples.milliseconds(&timer);
                try repaint(manager.window);
            },
            .palette_list, .palette_search => {
                windows.setText(panel.search, if (operation == .palette_search) "body 9" else "");
                timer.reset();
                panel.refreshItems();
                elapsed = samples.milliseconds(&timer);
                try repaint(panel.window);
            },
        }
        switch (operation) {
            .management_first, .management_update => {
                const items = win.SendMessageW(manager.list, win.LVM_GETITEMCOUNT, 0, 0);
                if (items < 0 or count != @as(usize, @intCast(items))) return error.WrongManagementCount;
            },
            .palette_list, .palette_search => {
                if (panel.count != count_expected) return error.WrongPaletteCount;
                const actual = win.SendMessageW(panel.list, win.LB_GETCOUNT, 0, 0);
                if (actual < 0 or count_expected != @as(usize, @intCast(actual))) return error.WrongPaletteCount;
            },
        }
        if (iteration != 0) readings[iteration - 1] = elapsed;
    }
    return samples.summarize(alloc, count, @tagName(operation), readings);
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len < 3) return error.ExpectedOutputDirectoryAndRepeats;
    const repeats = try std.fmt.parseUnsigned(usize, args[2], 10);
    if (repeats < 1 or repeats > 100) return error.InvalidBenchmarkRepeats;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const counts = try samples.parseCounts(alloc, args[3..]);
    try std.fs.cwd().makeDir(args[1]);
    var output = try std.fs.cwd().openDir(args[1], .{ .no_follow = true });
    defer output.close();
    const path = try std.fs.cwd().realpathAlloc(alloc, args[1]);
    const db_path = try std.fs.path.join(alloc, &.{ path, "settings.db" });
    var connection = try storage.Store.open(allocator, db_path);
    defer connection.close();

    var timer = try std.time.Timer.start();
    var panel: palette.Palette = .{};
    try panel.open(null);
    defer panel.close();
    try arrange(panel.window);
    const initial = samples.milliseconds(&timer);
    const operations = [_]Operation{ .management_first, .management_update, .palette_list, .palette_search };
    const result = try alloc.alloc(samples.Sample, 1 + counts.len * operations.len);
    const cold = try alloc.dupe(f64, &.{initial});
    result[0] = try samples.summarize(alloc, 0, "palette_create_and_show", cold);

    for (counts, 0..) |count, index| {
        var fixture = std.heap.ArenaAllocator.init(allocator);
        defer fixture.deinit();
        try connection.save(try samples.synthetic(storage, fixture.allocator(), count));
        var snapshot = try connection.load(allocator);
        defer snapshot.deinit();
        defer panel.refresh(.{});
        panel.refresh(snapshot.data);
        var history = storage.LibraryHistory.init(allocator);
        defer history.deinit();
        var manager: management.Management = .{};
        defer manager.close();
        for (operations, result[1 + index * operations.len ..][0..operations.len]) |operation, *entry| {
            entry.* = try measure(alloc, &panel, &manager, &connection, &snapshot, &history, operation, repeats);
        }
    }
    const report = try std.json.Stringify.valueAlloc(alloc, .{
        .mode = "desktop-controls",
        .repeats = repeats,
        .warmups = 1,
        .measurements = result,
    }, .{ .whitespace = .indent_2 });
    try files.writeNew(output, "measurements.json", report);
}
