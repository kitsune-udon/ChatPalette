const std = @import("std");
const files = @import("files.zig");
const process = @import("process.zig");

pub const steps = [_]struct { name: []const u8, image: []const u8, details: ?[]const u8, timeout_ms: u32 }{
    .{ .name = "unit-app", .image = "chatpalette-app-tests.exe", .details = null, .timeout_ms = 180_000 },
    .{ .name = "startup", .image = "chatpalette-startup-test.exe", .details = "startup-result", .timeout_ms = 180_000 },
    .{ .name = "worker-lifecycle", .image = "chatpalette-worker-lifecycle-test.exe", .details = "worker-result", .timeout_ms = 60_000 },
};
pub const timeout_ms = steps[0].timeout_ms + steps[1].timeout_ms + steps[2].timeout_ms;

pub const Pins = struct {
    harness_sha256: files.HexDigest,
    runners_sha256: [steps.len]files.HexDigest,
};

pub const Inputs = struct {
    paths: [steps.len][]const u8,
    pins: Pins,
};

pub fn verify(dir: std.fs.Dir, name: []const u8, expected: files.HexDigest) !void {
    const actual = files.hex(try files.readDigest(dir, name));
    if (!std.mem.eql(u8, &actual, &expected)) return error.SandboxFreezeInputChanged;
}

pub fn stage(input: std.fs.Dir, sources: Inputs) !void {
    for (steps, sources.paths, sources.pins.runners_sha256) |step, path, sha| {
        try std.fs.cwd().copyFile(path, input, step.image, .{});
        try verify(input, step.image, sha);
    }
}

// The startup harness launches executable copies beside its synthetic databases. Run it on
// the guest filesystem, then retain its complete output including individual trial logs.
fn preserveDetails(alloc: std.mem.Allocator, work: std.fs.Dir, output: std.fs.Dir, name: []const u8) !void {
    var source = try work.openDir(name, .{ .iterate = true, .no_follow = true });
    defer source.close();
    try output.makeDir(name);
    var dest = try output.openDir(name, .{ .no_follow = true });
    defer dest.close();
    var tree = try source.walk(alloc);
    defer tree.deinit();
    while (try tree.next()) |entry| switch (entry.kind) {
        .file => try source.copyFile(entry.path, dest, entry.path, .{}),
        .directory => try dest.makeDir(entry.path),
        else => return error.UnexpectedFreezeEvidenceEntry,
    };
}

pub fn run(
    alloc: std.mem.Allocator,
    input: std.fs.Dir,
    work: std.fs.Dir,
    work_path: []const u8,
    output: std.fs.Dir,
    output_path: []const u8,
    app: []const u8,
    expected: Pins,
) !void {
    try verify(std.fs.cwd(), try std.fs.selfExePathAlloc(alloc), expected.harness_sha256);
    var paths: [steps.len][]const u8 = undefined;
    var locks: [steps.len]?std.fs.File = @splat(null);
    defer for (locks) |lock| {
        if (lock) |file| file.close();
    };
    for (steps, expected.runners_sha256, &paths, &locks) |step, sha, *path, *lock| {
        try input.copyFile(step.image, work, step.image, .{});
        path.* = try std.fs.path.join(alloc, &.{ work_path, step.image });
        lock.* = try files.openImmutable(alloc, path.*);
        try verify(work, step.image, sha);
    }

    for (steps, paths, expected.runners_sha256) |step, path, sha| {
        try output.makeDir(step.name);
        var logs = try output.openDir(step.name, .{ .no_follow = true });
        defer logs.close();
        const logs_path = try std.fs.path.join(alloc, &.{ output_path, step.name });
        const argv: []const []const u8 = if (step.details) |dir|
            &.{ path, app, try std.fs.path.join(alloc, &.{ work_path, dir }) }
        else
            &.{path};
        const observation = process.observe(alloc, argv, work_path, logs, step.timeout_ms);
        if (observation.result) |result| try process.saveResult(alloc, logs_path, result);
        const copy_failure: ?anyerror = if (step.details) |name| retained: {
            preserveDetails(alloc, work, output, name) catch |err| break :retained err;
            break :retained null;
        } else null;
        if (observation.failure != null or observation.cleanup_failure != null or copy_failure != null) {
            const detail = try std.json.Stringify.valueAlloc(alloc, .{
                .failure = if (observation.failure) |err| @errorName(err) else null,
                .cleanup_failure = if (observation.cleanup_failure) |err| @errorName(err) else null,
                .copy_failure = if (copy_failure) |err| @errorName(err) else null,
            }, .{});
            try files.writeNew(logs, "failure.json", detail);
        }
        if (observation.failure) |failure| return failure;
        if (observation.cleanup_failure) |failure| return failure;
        const result = observation.result orelse return error.FreezeTestResultMissing;
        if (result.timed_out or result.exit_code != 0) return error.FreezeTestCommandFailed;
        // Zig's native unit runner writes its test names and summary to stderr.
        if (step.details != null and result.stderr_bytes != 0) return error.UnexpectedTestStderr;
        if (copy_failure) |failure| return failure;
        try verify(work, step.image, sha);
    }
}
