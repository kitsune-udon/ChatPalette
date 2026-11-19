const std = @import("std");
const files = @import("tools/files.zig");
const process = @import("tools/process.zig");
const zip = @import("tools/zip.zig");
const scenario = @import("clean_install_scenario.zig");

const allocator = std.heap.page_allocator;
const executable = "ChatPalette.exe";
const max_archive = 256 * 1024 * 1024;
const deadline_ms = 75000;

const Report = struct {
    passed: bool = false,
    archive_sha256: ?files.HexDigest = null,
    expected_archive_sha256: files.HexDigest,
    executable_sha256: ?files.HexDigest = null,
    version: ?[]const u8 = null,
    scenario_process: ?process.Result = null,
    failure: ?[]const u8 = null,
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const args = try std.process.argsAlloc(scratch);
    if ((args.len == 6 or args.len == 7) and std.mem.eql(u8, args[1], "--inside-job"))
        return scenario.run(scratch, args[2], args[3], args[4], args[5], try checkClipboard(args[6..]));
    if (args.len != 4 and args.len != 5) {
        std.debug.print("chatpalette-clean-install-test <候補ZIP> <ZIPのSHA-256> <新規の結果フォルダー> [--sandbox-clipboard]\n", .{});
        std.process.exit(2);
    }
    const clipboard = try checkClipboard(args[4..]);
    var expected: files.Digest = undefined;
    if (args[2].len != 64) return error.InvalidArchiveDigest;
    _ = std.fmt.hexToBytes(&expected, args[2]) catch return error.InvalidArchiveDigest;
    const cwd = std.fs.cwd();
    const archive = try cwd.realpathAlloc(scratch, args[1]);
    try cwd.makeDir(args[3]);
    const output = try cwd.realpathAlloc(scratch, args[3]);
    var dir = try cwd.openDir(output, .{});
    defer dir.close();

    var report: Report = .{ .expected_archive_sha256 = files.hex(expected) };
    verify(scratch, archive, output, dir, clipboard, &report) catch |failure| {
        report.failure = @errorName(failure);
    };
    report.passed = report.failure == null;
    try process.saveResult(allocator, output, report);
    if (report.failure) |failure| {
        std.debug.print("クリーン展開試験に失敗しました。{s}\n", .{failure});
        std.process.exit(1);
    }
    std.debug.print("クリーン展開試験に合格しました。\n", .{});
}

fn checkClipboard(flags: []const []const u8) !bool {
    if (flags.len == 0) return false;
    if (flags.len == 1 and std.mem.eql(u8, flags[0], "--sandbox-clipboard")) return true;
    return error.InvalidCleanInstallOptions;
}

fn verify(scratch: std.mem.Allocator, input: []const u8, output: []const u8, dir: std.fs.Dir, clipboard: bool, report: *Report) !void {
    const archive = try files.openImmutable(scratch, input);
    defer archive.close();
    if (try archive.getEndPos() > max_archive) return error.ArchiveTooLarge;
    report.archive_sha256 = files.hex(try files.fileDigest(archive));
    if (!std.mem.eql(u8, &report.archive_sha256.?, &report.expected_archive_sha256)) return error.ArchiveDigestMismatch;

    var installed = try createDirectory(dir, "installation");
    defer installed.close();
    try archive.seekTo(0);
    var buffer: [64 * 1024]u8 = undefined;
    var reader = archive.reader(&buffer);
    try std.zip.extract(installed, &reader, .{});
    const manifest = try installed.readFileAlloc(scratch, zip.manifest_name, 4 * 1024 * 1024);
    _ = try zip.verify(scratch, archive, manifest);
    try zip.verifyTree(scratch, installed, manifest);
    try ensureInitialLayout(installed);
    report.executable_sha256 = files.hex(try files.readDigest(installed, executable));
    const version_raw = try installed.readFileAlloc(scratch, "VERSION", 256);
    const version = std.mem.trim(u8, version_raw, "\r\n\t ");
    if (version.len == 0) return error.MissingReleaseVersion;
    report.version = version;

    const installed_path = try std.fs.path.join(scratch, &.{ output, "installation" });
    const scenario_path = try std.fs.path.join(scratch, &.{ output, "scenario" });
    var logs = try createDirectory(dir, "scenario");
    defer logs.close();
    const self = try std.fs.selfExePathAlloc(scratch);
    // The scenario process keeps the Job Object alive through the application's restart.
    const args = [_][]const u8{ self, "--inside-job", installed_path, scenario_path, &report.executable_sha256.?, version, "--sandbox-clipboard" };
    const command: []const []const u8 = if (clipboard) &args else args[0 .. args.len - 1];
    const result = try process.run(allocator, command, installed_path, logs, deadline_ms);
    report.scenario_process = result;
    if (!result.passed()) return error.CleanInstallScenarioFailed;
    const evidence = try logs.readFileAlloc(scratch, "result.json", 4 * 1024 * 1024);
    const completion = try std.json.parseFromSliceLeaky(struct { passed: bool }, scratch, evidence, .{ .ignore_unknown_fields = true });
    if (!completion.passed) return error.CleanInstallObservationFailed;
    const final_exe = files.hex(try files.readDigest(installed, executable));
    if (!std.mem.eql(u8, &report.executable_sha256.?, &final_exe)) return error.InstalledExecutableChanged;
}

fn createDirectory(parent: std.fs.Dir, name: []const u8) !std.fs.Dir {
    try parent.makeDir(name);
    return parent.openDir(name, .{ .iterate = true, .no_follow = true });
}

fn ensureInitialLayout(dir: std.fs.Dir) !void {
    dir.access("data", .{}) catch |failure| {
        if (failure == error.FileNotFound) return;
        return failure;
    };
    return error.PackageContainsUserData;
}
