const std = @import("std");
const browser = @import("browser.zig");
const files = @import("files.zig");
const process = @import("process.zig");
const sandbox = @import("sandbox.zig");
const test_runner = @import("test_runner.zig");

const app_name = "ChatPalette.exe";
const fixture_name = "chatpalette-browser-fixture.exe";
const browser_name = "brave.exe";
const selection_name = "browser-inputs.json";
const observations_name = "browser-observations.json";
const fixture_deadline_ms = 180_000;
const guest_deadline_ms = 240_000;
// Sandbox logon tasks can take the foreground after the browser is ready.
const guest_startup_ms = 35_000;

const Pins = struct {
    application: files.HexDigest,
    fixture: files.HexDigest,
    brave: files.HexDigest,
    chrome_dll: files.HexDigest,
};

const Report = struct {
    passed: bool = false,
    failure: ?[]const u8 = null,
    cleanup_failure: ?[]const u8 = null,
    fixture: ?process.Result = null,
    browser_version: ?[]const u8 = null,
    pins: ?Pins = null,
    desktop_wait_ms: ?u64 = null,
};

pub fn host(allocator: std.mem.Allocator, app: []const u8, fixture: []const u8, brave: []const u8, output: []const u8, prepare_only: bool) !void {
    if (!std.ascii.eqlIgnoreCase(std.fs.path.basename(app), app_name) or
        !std.ascii.eqlIgnoreCase(std.fs.path.basename(fixture), fixture_name) or
        !std.ascii.eqlIgnoreCase(std.fs.path.basename(brave), browser_name)) return error.UnexpectedSandboxBrowserExecutable;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const session = try sandbox.Host.openOwned(alloc, prepare_only);
    defer session.close();
    const cwd = std.fs.cwd();
    const resolved_brave = try cwd.realpathAlloc(alloc, brave);
    const version = try browser.executableVersion(alloc, resolved_brave);
    const runtime = try std.fs.path.join(alloc, &.{ std.fs.path.dirname(resolved_brave).?, version });
    var source = try cwd.openDir(runtime, .{ .no_follow = true, .iterate = true });
    defer source.close();
    const absolute_output = try std.fs.path.resolve(alloc, &.{ try std.process.getCwdAlloc(alloc), output });
    const parent = try cwd.realpathAlloc(alloc, std.fs.path.dirname(absolute_output) orelse return error.InvalidSandboxBrowserOutput);
    const destination = try std.fs.path.join(alloc, &.{ parent, std.fs.path.basename(absolute_output) });
    const relative_output = try std.fs.path.relative(alloc, runtime, destination);
    if (!std.fs.path.isAbsolute(relative_output)) {
        var components = try std.fs.path.componentIterator(relative_output);
        const first = components.next() orelse return error.SandboxBrowserOutputInsideRuntime;
        if (!std.mem.eql(u8, first.name, "..")) return error.SandboxBrowserOutputInsideRuntime;
    }

    const layout = try sandbox.Layout.create(alloc, destination);
    var input = try cwd.openDir(layout.input, .{ .no_follow = true });
    defer input.close();
    try cwd.copyFile(app, input, app_name, .{});
    try cwd.copyFile(fixture, input, fixture_name, .{});
    try cwd.copyFile(try std.fs.selfExePathAlloc(alloc), input, sandbox.tool_name, .{});
    try cwd.copyFile(resolved_brave, input, browser_name, .{});
    const staged_version = try browser.executableVersion(alloc, try std.fs.path.join(alloc, &.{ layout.input, browser_name }));
    if (!std.mem.eql(u8, staged_version, version)) return error.SandboxInputChanged;

    try copyRuntime(source, input, version);
    const expected = try readPins(alloc, input, version);
    try files.writeNew(input, selection_name, try std.json.Stringify.valueAlloc(alloc, expected, .{ .whitespace = .indent_2 }));
    try layout.configure(alloc, .browser);
    if (try session.run(Report, alloc, layout, guest_deadline_ms)) |report| {
        if (!report.passed or report.fixture == null or !guestImagesMatch(report, version, expected))
            return error.SandboxBrowserFailed;
        var results = try cwd.openDir(layout.evidence, .{ .no_follow = true });
        defer results.close();
        try test_runner.validateBrowserReport(alloc, try results.readFileAlloc(alloc, observations_name, 4 * 1024 * 1024), expected.application);
    }
}

fn copyRuntime(source: std.fs.Dir, destination: std.fs.Dir, version: []const u8) !void {
    try destination.makeDir(version);
    var output = try destination.openDir(version, .{ .no_follow = true });
    defer output.close();
    try copyTree(source, output, true);
}

fn copyTree(source: std.fs.Dir, destination: std.fs.Dir, root: bool) !void {
    var iterator = source.iterate();
    while (try iterator.next()) |entry| {
        if (root and (std.ascii.eqlIgnoreCase(entry.name, "Installer") or std.ascii.eqlIgnoreCase(entry.name, "BraveVpnWireguardService"))) continue;
        switch (entry.kind) {
            .file => try source.copyFile(entry.name, destination, entry.name, .{}),
            .directory => {
                var nested = try source.openDir(entry.name, .{ .no_follow = true, .iterate = true });
                defer nested.close();
                try destination.makeDir(entry.name);
                var local = try destination.openDir(entry.name, .{ .no_follow = true });
                defer local.close();
                try copyTree(nested, local, false);
            },
            else => return error.UnexpectedBrowserBundleEntry,
        }
    }
}

fn readPins(alloc: std.mem.Allocator, dir: std.fs.Dir, version: []const u8) !Pins {
    return .{
        .application = files.hex(try files.readDigest(dir, app_name)),
        .fixture = files.hex(try files.readDigest(dir, fixture_name)),
        .brave = files.hex(try files.readDigest(dir, browser_name)),
        .chrome_dll = files.hex(try files.readDigest(dir, try std.fs.path.join(alloc, &.{ version, "chrome.dll" }))),
    };
}

fn guestImagesMatch(report: Report, version: []const u8, expected: Pins) bool {
    return std.mem.eql(u8, report.browser_version orelse return false, version) and
        std.meta.eql(report.pins orelse return false, expected);
}

pub fn guest(allocator: std.mem.Allocator, input: []const u8, output: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var evidence = try std.fs.cwd().openDir(output, .{ .no_follow = true });
    defer evidence.close();
    try files.writeNew(evidence, "sandbox-browser.started", "");
    var report: Report = .{};
    runFixture(alloc, input, evidence, &report) catch |failure| {
        report.failure = @errorName(failure);
    };
    report.passed = report.failure == null and report.cleanup_failure == null;
    try process.saveResult(alloc, output, report);
    if (!report.passed) return error.SandboxBrowserFailed;
}

fn runFixture(alloc: std.mem.Allocator, input_path: []const u8, evidence: std.fs.Dir, report: *Report) !void {
    var startup = try std.time.Timer.start();
    const cwd = std.fs.cwd();
    var input = try cwd.openDir(input_path, .{ .no_follow = true });
    defer input.close();
    const selection = try input.readFileAlloc(alloc, selection_name, 4096);
    const expected = try std.json.parseFromSliceLeaky(Pins, alloc, selection, .{});
    const work_path = try files.newDirectory(alloc, try std.process.getEnvVarOwned(alloc, "TEMP"), "ChatPaletteBrowser-");
    var work = try cwd.openDir(work_path, .{ .no_follow = true });
    defer work.close();
    for ([_][]const u8{ app_name, fixture_name, browser_name }) |name| try input.copyFile(name, work, name, .{});
    const brave = try std.fs.path.join(alloc, &.{ work_path, browser_name });
    const version = try browser.executableVersion(alloc, brave);
    var source = try input.openDir(version, .{ .no_follow = true, .iterate = true });
    defer source.close();
    try copyRuntime(source, work, version);
    report.browser_version = version;
    report.pins = try readPins(alloc, work, version);
    if (!std.meta.eql(report.pins.?, expected)) return error.SandboxInputChanged;

    const startup_remaining = guest_startup_ms * std.time.ns_per_ms -| startup.read();
    if (startup_remaining != 0) std.Thread.sleep(startup_remaining);
    report.desktop_wait_ms = startup_remaining / std.time.ns_per_ms;

    const raw = try std.fs.path.join(alloc, &.{ work_path, "fixture" });
    const observed = process.observe(alloc, &.{
        try std.fs.path.join(alloc, &.{ work_path, fixture_name }),
        try std.fs.path.join(alloc, &.{ work_path, app_name }),
        raw,
        brave,
    }, work_path, evidence, fixture_deadline_ms);
    report.fixture = observed.result;
    if (observed.cleanup_failure) |failure| report.cleanup_failure = @errorName(failure);
    const path = try std.fs.path.join(alloc, &.{ raw, "result.json" });
    const text = cwd.readFileAlloc(alloc, path, 4 * 1024 * 1024) catch |failure| switch (failure) {
        error.FileNotFound => null,
        else => return failure,
    };
    if (text) |data| try files.writeNew(evidence, observations_name, data);
    if (observed.failure) |failure| return failure;
    const result = observed.result orelse return error.BrowserFixtureDidNotStart;
    if (result.exit_code != 0 or result.timed_out) return error.BrowserFixtureFailed;
    try test_runner.validateBrowserReport(alloc, text orelse return error.BrowserFixtureEvidenceMissing, expected.application);
    if (result.stderr_bytes != 0) return error.UnexpectedTestStderr;
}
