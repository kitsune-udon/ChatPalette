const std = @import("std");
const Allocator = std.mem.Allocator;

const suffixes = [_][]const u8{ "", "-journal", "-wal", "-shm" };
pub const FileMove = struct {
    source: []const u8,
    destination: []const u8,
    failed_to_restore: ?anyerror = null,
};

pub const Report = struct {
    arena: std.heap.ArenaAllocator,
    files: [suffixes.len]FileMove,
    failure_index: ?usize = null,
    failure: ?anyerror = null,

    pub fn deinit(self: *Report) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

fn moveNoReplace(from: []const u8, to: []const u8) anyerror!void {
    const win = std.os.windows;
    const from_w = try win.sliceToPrefixedFileW(null, from);
    const to_w = try win.sliceToPrefixedFileW(null, to);
    if (win.kernel32.MoveFileExW(from_w.span().ptr, to_w.span().ptr, win.MOVEFILE_WRITE_THROUGH) != 0) return;
    return switch (win.GetLastError()) {
        .SHARING_VIOLATION, .LOCK_VIOLATION => error.FileInUse,
        .ACCESS_DENIED => error.AccessDenied,
        .FILE_EXISTS, .ALREADY_EXISTS => error.PathAlreadyExists,
        .FILE_NOT_FOUND, .PATH_NOT_FOUND => error.FileNotFound,
        else => |err| win.unexpectedError(err),
    };
}

/// Application confirmation and closing the live store precede moving the DB set.
/// When a restore fails the caller reports its source, destination and error.
pub fn backupForReset(allocator: Allocator, path: []const u8) !Report {
    return backup(allocator, path, moveNoReplace);
}

fn lockFixtureFile(path: []const u8, share: u32) !std.os.windows.HANDLE {
    const win = std.os.windows;
    const path_w = try win.sliceToPrefixedFileW(null, path);
    const handle = win.kernel32.CreateFileW(path_w.span().ptr, win.GENERIC_READ, share, null, win.OPEN_EXISTING, win.FILE_ATTRIBUTE_NORMAL, null);
    if (handle == win.INVALID_HANDLE_VALUE) return win.unexpectedError(win.GetLastError());
    return handle;
}

fn expectFixtureBytes(path: []const u8, expected: []const u8) !void {
    const alloc = std.testing.allocator;
    const contents = try std.fs.cwd().readFileAlloc(alloc, path, 256);
    defer alloc.free(contents);
    try std.testing.expectEqualStrings(expected, contents);
}

test "DB reset preserves all files when the Windows lock allows reads or denies them" {
    const win = std.os.windows;
    const alloc = std.testing.allocator;
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    const parent = try directory.dir.realpathAlloc(alloc, ".");
    defer alloc.free(parent);
    const path = try std.fs.path.join(alloc, &.{ parent, "settings.db" });
    defer alloc.free(path);
    const shm_path = try std.fs.path.join(alloc, &.{ parent, "settings.db-shm" });
    defer alloc.free(shm_path);
    try directory.dir.makeDir("other");
    try directory.dir.writeFile(.{ .sub_path = "other\\settings.db", .data = "unrelated DB" });
    for (suffixes) |suffix| {
        const name = try std.fmt.allocPrint(alloc, "settings.db{s}", .{suffix});
        defer alloc.free(name);
        try directory.dir.writeFile(.{ .sub_path = name, .data = name });
    }

    for ([_]u32{ win.FILE_SHARE_READ, 0 }, [_]anyerror{ error.FileInUse, error.AccessDenied }) |share, expected| {
        var report = locked: {
            const lock = try lockFixtureFile(shm_path, share);
            defer win.CloseHandle(lock);
            break :locked try backupForReset(alloc, path);
        };
        defer report.deinit();
        try std.testing.expectEqual(@as(?usize, 3), report.failure_index);
        try std.testing.expectEqual(@as(?anyerror, expected), report.failure);
        for (report.files) |file| {
            try std.testing.expectEqual(@as(?anyerror, null), file.failed_to_restore);
            try expectFixtureBytes(file.source, std.fs.path.basename(file.source));
            try std.testing.expectError(error.FileNotFound, std.fs.cwd().statFile(file.destination));
        }
    }

    try directory.dir.rename("settings.db-shm", "held-shm");
    try directory.dir.makeDir("settings.db-shm");
    var blocked = try backupForReset(alloc, path);
    defer blocked.deinit();
    try std.testing.expectEqual(@as(?usize, 3), blocked.failure_index);
    try std.testing.expect(blocked.failure != null);
    for (blocked.files[0..3]) |file| {
        try expectFixtureBytes(file.source, std.fs.path.basename(file.source));
        try std.testing.expectError(error.FileNotFound, std.fs.cwd().statFile(file.destination));
    }
    try directory.dir.deleteDir("settings.db-shm");
    try directory.dir.rename("held-shm", "settings.db-shm");

    var completed = try backupForReset(alloc, path);
    defer completed.deinit();
    try std.testing.expectEqual(@as(?anyerror, null), completed.failure);
    for (completed.files) |file| {
        try expectFixtureBytes(file.destination, std.fs.path.basename(file.source));
        try std.testing.expectError(error.FileNotFound, std.fs.cwd().statFile(file.source));
    }
    const unrelated = try directory.dir.readFileAlloc(alloc, "other\\settings.db", 256);
    defer alloc.free(unrelated);
    try std.testing.expectEqualStrings("unrelated DB", unrelated);

    try directory.dir.writeFile(.{ .sub_path = "settings.db", .data = "new DB" });
    try std.testing.expectError(error.PathAlreadyExists, moveNoReplace(completed.files[0].destination, path));
    try expectFixtureBytes(completed.files[0].destination, "settings.db");
    try expectFixtureBytes(path, "new DB");
}

test "a partial DB backup preserves the file Windows prevents from restoring" {
    const win = std.os.windows;
    const alloc = std.testing.allocator;
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    const parent = try directory.dir.realpathAlloc(alloc, ".");
    defer alloc.free(parent);
    const path = try std.fs.path.join(alloc, &.{ parent, "settings.db" });
    defer alloc.free(path);
    for (suffixes) |suffix| {
        const name = try std.fmt.allocPrint(alloc, "settings.db{s}", .{suffix});
        defer alloc.free(name);
        try directory.dir.writeFile(.{ .sub_path = name, .data = name });
    }
    const shm_path = try std.fs.path.join(alloc, &.{ parent, "settings.db-shm" });
    defer alloc.free(shm_path);
    const probe = struct {
        threadlocal var wal_lock: ?win.HANDLE = null;
        threadlocal var lock_failure: ?anyerror = null;

        fn move(from: []const u8, to: []const u8) anyerror!void {
            try moveNoReplace(from, to);
            if (std.mem.eql(u8, std.fs.path.basename(from), "settings.db-wal")) {
                wal_lock = lockFixtureFile(to, win.FILE_SHARE_READ) catch |err| unavailable: {
                    lock_failure = err;
                    break :unavailable null;
                };
            }
        }
    };
    var report = locked: {
        const shm_lock = try lockFixtureFile(shm_path, win.FILE_SHARE_READ);
        defer win.CloseHandle(shm_lock);
        defer if (probe.wal_lock) |lock| {
            win.CloseHandle(lock);
            probe.wal_lock = null;
        };
        break :locked try backup(alloc, path, probe.move);
    };
    defer report.deinit();
    try std.testing.expectEqual(@as(?anyerror, null), probe.lock_failure);
    try std.testing.expectEqual(@as(?usize, 3), report.failure_index);
    try std.testing.expectEqual(@as(?anyerror, error.FileInUse), report.failure);
    try std.testing.expectEqual(@as(?anyerror, error.FileInUse), report.files[2].failed_to_restore);
    for (report.files, 0..) |file, i| {
        const source = if (i == 2) file.destination else file.source;
        try expectFixtureBytes(source, std.fs.path.basename(file.source));
        const absent = if (i == 2) file.source else file.destination;
        try std.testing.expectError(error.FileNotFound, std.fs.cwd().statFile(absent));
    }
}

fn backup(allocator: Allocator, path: []const u8, comptime move: fn ([]const u8, []const u8) anyerror!void) !Report {
    var report = Report{ .arena = std.heap.ArenaAllocator.init(allocator), .files = undefined };
    errdefer report.deinit();
    const owned = report.arena.allocator();
    var nonce: [16]u8 = undefined;
    std.crypto.random.bytes(&nonce);
    const base = try std.fmt.allocPrint(owned, "{s}.backup-{x}", .{ path, &nonce });
    var exists: [suffixes.len]bool = undefined;
    for (suffixes, &report.files) |suffix, *file| {
        file.* = .{
            .source = try std.fmt.allocPrint(owned, "{s}{s}", .{ path, suffix }),
            .destination = try std.fmt.allocPrint(owned, "{s}{s}", .{ base, suffix }),
        };
    }
    for (&report.files, &exists, 0..) |*file, *present, i| {
        const stat = std.fs.cwd().statFile(file.source) catch |err| {
            if (err == error.FileNotFound) {
                present.* = false;
                continue;
            }
            report.failure_index = i;
            report.failure = err;
            return report;
        };
        if (stat.kind != .file) {
            report.failure_index = i;
            report.failure = error.InvalidBackupSource;
            return report;
        }
        present.* = true;
    }
    if (!exists[0]) return error.DatabaseMissing;
    for (&report.files, exists, 0..) |*file, present, i| {
        if (!present) continue;
        move(file.source, file.destination) catch |err| {
            report.failure_index = i;
            report.failure = err;
            var j = i;
            while (j > 0) {
                j -= 1;
                if (!exists[j]) continue;
                const prior = &report.files[j];
                move(prior.destination, prior.source) catch |restore_err| {
                    prior.failed_to_restore = restore_err;
                };
            }
            return report;
        };
    }
    return report;
}
