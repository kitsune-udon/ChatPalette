const std = @import("std");
const files = @import("files.zig");
const release = @import("release.zig");
const process = @import("process.zig");
const sandbox = @import("sandbox.zig");
const sandbox_browser = @import("sandbox_browser.zig");
const sandbox_package = @import("sandbox_package.zig");
const benchmark = @import("benchmark.zig");
const browser = @import("browser.zig");
const source_check = @import("source_check.zig");
const comparator = @import("compare.zig");
const freeze = @import("freeze.zig");
const test_runner = @import("test_runner.zig");

pub fn main() void {
    command(std.heap.page_allocator) catch |err| {
        std.debug.print("chatpalette-tools {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
}

fn print(comptime format: []const u8, args: anytype) !void {
    var buffer: [4096]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&buffer);
    try stdout.interface.print(format, args);
    try stdout.interface.flush();
}

fn command(allocator: std.mem.Allocator) !void {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len == 1) return error.CommandRequired;
    const action = args[1];
    if (std.mem.eql(u8, action, "sha256") and args.len == 3) {
        const digest = try files.readDigest(std.fs.cwd(), args[2]);
        return print("{s}\n", .{files.hex(digest)});
    }
    if (std.mem.eql(u8, action, "release") and args.len == 6) {
        try release.makeCandidate(allocator, args[2], args[3], args[4], args[5]);
        return print("{s}\n", .{args[5]});
    }
    if (std.mem.eql(u8, action, "freeze") and (args.len == 5 or args.len == 6)) {
        const prepare_only = args.len == 6;
        if (prepare_only and !std.mem.eql(u8, args[5], "--prepare-only")) return error.InvalidArguments;
        const result = try freeze.run(allocator, args[2], args[3], args[4], prepare_only);
        defer allocator.free(result);
        return print("{s}\n", .{result});
    }
    if (std.mem.eql(u8, action, "verify") and args.len == 4) {
        const digest = try release.verifyCandidate(allocator, args[2], args[3]);
        return print("{s}\n", .{files.hex(digest)});
    }
    if (std.mem.eql(u8, action, "extract") and args.len == 5) {
        const digest = try release.extractCandidate(allocator, args[2], args[3], args[4]);
        return print("{s}\n", .{files.hex(digest)});
    }
    if (std.mem.eql(u8, action, "source-check") and args.len == 3) {
        try source_check.run(allocator, args[2]);
        return print("PASS\n", .{});
    }
    if (std.mem.eql(u8, action, "test-list")) {
        const result = try test_runner.list(allocator, args[2..]);
        defer allocator.free(result);
        return print("{s}", .{result});
    }
    if (std.mem.eql(u8, action, "test-run") and args.len >= 5) {
        const passed = test_runner.run(allocator, args[2], args[3], args[4], args[5..]) catch |err| {
            if (err == error.DesktopSessionRequired)
                std.debug.print("Use --session desktop for the current interactive desktop, or sandbox-browser for the isolated Brave fixture.\n", .{});
            return err;
        };
        try print("{s}\n", .{args[4]});
        if (!passed) return error.NativeTestRunFailed;
        return;
    }
    if (std.mem.eql(u8, action, "compare") and (args.len == 7 or args.len == 9)) {
        const with_expectation = args.len == 9;
        if (with_expectation and !std.mem.eql(u8, args[7], "--expect")) return error.InvalidArguments;
        const passed = try comparator.run(allocator, args[2], args[3], args[4], args[5], args[6], if (with_expectation) args[8] else null);
        try print("{s}\n", .{args[6]});
        if (!passed) return error.ImplementationsDisagreed;
        return;
    }
    if (std.mem.eql(u8, action, "run") and args.len >= 5) {
        const timeout = try std.fmt.parseInt(u32, args[3], 10);
        try std.fs.cwd().makeDir(args[2]);
        var output = try std.fs.cwd().openDir(args[2], .{});
        defer output.close();
        const work_dir = try std.process.getCwdAlloc(allocator);
        defer allocator.free(work_dir);
        const executable = try std.fs.cwd().realpathAlloc(allocator, args[4]);
        defer allocator.free(executable);
        const locked = try files.openImmutable(allocator, executable);
        defer locked.close();
        const before = try files.fileDigest(locked);
        const argv = try allocator.alloc([]const u8, args.len - 4);
        defer allocator.free(argv);
        argv[0] = executable;
        @memcpy(argv[1..], args[5..]);
        const result = process.run(allocator, argv, work_dir, output, timeout) catch |err| {
            try process.saveResult(allocator, args[2], .{ .@"error" = @errorName(err) });
            return err;
        };
        try locked.seekTo(0);
        const after = try files.fileDigest(locked);
        const unchanged = std.mem.eql(u8, &before, &after);
        try process.saveResult(allocator, args[2], .{
            .exit_code = result.exit_code,
            .timed_out = result.timed_out,
            .stderr_bytes = result.stderr_bytes,
            .elapsed_ms = result.elapsed_ms,
            .executable_sha256 = files.hex(before),
            .unchanged = unchanged,
        });
        if (!unchanged) return error.ExecutableChangedDuringTest;
        if (!result.passed()) return error.TestFailed;
        return print("{s}\n", .{args[2]});
    }
    if (std.mem.eql(u8, action, "sandbox") and args.len >= 4) {
        var index: usize = 4;
        const prepare_only = index < args.len and std.mem.eql(u8, args[index], "--prepare-only");
        if (prepare_only) index += 1;
        if (index < args.len and !std.mem.eql(u8, args[index], "--")) return error.InvalidArguments;
        const arguments: []const []const u8 = if (index == args.len) &.{"--smoke"} else args[index + 1 ..];
        try sandbox.host(allocator, args[2], args[3], prepare_only, arguments);
        return print("{s}\n", .{args[3]});
    }
    if (std.mem.eql(u8, action, "sandbox-guest") and args.len == 4) {
        return sandbox.guest(allocator, args[2], args[3]);
    }
    if (std.mem.eql(u8, action, "sandbox-watch") and args.len == 4) {
        return sandbox.watch(allocator, args[2], try std.fmt.parseInt(u32, args[3], 10));
    }
    if (std.mem.eql(u8, action, "sandbox-browser") and (args.len == 6 or args.len == 7)) {
        const prepare_only = args.len == 7;
        if (prepare_only and !std.mem.eql(u8, args[6], "--prepare-only")) return error.InvalidArguments;
        try sandbox_browser.host(allocator, args[2], args[3], args[4], args[5], prepare_only);
        return print("{s}\n", .{args[5]});
    }
    if (std.mem.eql(u8, action, "sandbox-browser-guest") and args.len == 4) {
        return sandbox_browser.guest(allocator, args[2], args[3]);
    }
    if (std.mem.eql(u8, action, "sandbox-package") and (args.len == 6 or args.len == 7)) {
        const prepare_only = args.len == 7;
        if (prepare_only and !std.mem.eql(u8, args[6], "--prepare-only")) return error.InvalidArguments;
        try sandbox_package.host(allocator, args[2], args[3], args[4], args[5], prepare_only);
        return print("{s}\n", .{args[5]});
    }
    if (std.mem.eql(u8, action, "sandbox-package-guest") and args.len == 7) {
        return sandbox_package.guest(allocator, args[2], args[3], args[4], args[5], args[6]);
    }
    if (std.mem.eql(u8, action, "benchmark") and args.len >= 5) {
        try benchmark.run(allocator, args[2], args[3], args[4], args[5..]);
        return print("{s}\n", .{args[3]});
    }
    if (std.mem.eql(u8, action, "browser") and args.len >= 3) {
        if (std.mem.eql(u8, args[2], "list") and args.len == 3) {
            const result = try browser.list(allocator);
            defer allocator.free(result);
            return print("{s}\n", .{result});
        }
        if (std.mem.eql(u8, args[2], "inspect") and (args.len == 6 or args.len == 7)) {
            const exercise = args.len == 7;
            if (exercise and !std.mem.eql(u8, args[6], "--exercise")) return error.InvalidArguments;
            const passed = try browser.inspect(allocator, args[3], args[4], args[5], exercise);
            try print("{s}\n", .{args[5]});
            if (!passed) return error.BrowserChecksIncomplete;
            return;
        }
    }
    if (std.mem.eql(u8, action, "--help") and args.len == 2) {
        return print(
            \\chatpalette-tools sha256 <path>
            \\chatpalette-tools release <app-exe> <app-exe-sha256> <project-root> <new-output-dir> (rehearsal)
            \\chatpalette-tools freeze <project-root> <zig.exe> <new-output-dir> [--prepare-only]
            \\chatpalette-tools verify <zip> <SHA256SUMS>
            \\chatpalette-tools extract <zip> <SHA256SUMS> <new-output-dir>
            \\chatpalette-tools source-check <project-root>
            \\chatpalette-tools test-list [--name <native-test>]... [--session <headless|desktop>]
            \\chatpalette-tools test-run <project-root> <build-bin-dir> <new-results-dir> [--name <native-test>]... [--session <headless|desktop>]
            \\chatpalette-tools compare <verified-0.8.0.zip> <native-exe> <decimal-HWND> <repeats-per-order> <new-output-dir> [--expect <json>]
            \\chatpalette-tools run <new-output-dir> <timeout-ms> <exe> [args...]
            \\chatpalette-tools sandbox <exe> <new-output-dir> [--prepare-only] [-- args...]
            \\chatpalette-tools sandbox-watch <results-dir> <timeout-ms>
            \\chatpalette-tools sandbox-browser <ChatPalette.exe> <chatpalette-browser-fixture.exe> <brave.exe> <new-output-dir> [--prepare-only]
            \\chatpalette-tools sandbox-package <candidate.zip> <archive-sha256> <clean-install-test.exe> <new-output-dir> [--prepare-only]
            \\chatpalette-tools sandbox-package-guest <input-dir> <result-dir> <archive-sha256> <harness-sha256> <controller-sha256>
            \\chatpalette-tools benchmark <storage|load> <new-output-dir> <repeats> [counts...]
            \\chatpalette-tools benchmark startup <new-output-dir> <repeats> <exe>
            \\chatpalette-tools browser list
            \\chatpalette-tools browser inspect <decimal-HWND> <auto|watch|popout> <new-report> [--exercise]
            \\
        , .{});
    }
    return error.InvalidArguments;
}

test {
    _ = release;
    _ = sandbox;
    _ = sandbox_package;
    _ = browser;
    _ = @import("zip.zig");
    _ = source_check;
    _ = comparator;
    _ = freeze;
    _ = test_runner;
}
