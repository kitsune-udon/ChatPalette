const std = @import("std");
const files = @import("files.zig");
const process = @import("process.zig");
const log_tail = @import("sandbox_log.zig");
const audio = @import("sandbox_audio.zig");
pub const freeze_suite = @import("sandbox_freeze.zig");

const input_guest = "C:\\ChatPaletteInput";
const output_guest = "C:\\ChatPaletteEvidence";
pub const tool_name = "ChatPaletteTools.exe";
const test_name = "ChatPaletteTest.exe";
pub const selection_name = "selection.json";
const timeout_ms = 120_000;
const max_executable_bytes = 256 * 1024 * 1024;
const win = std.os.windows;
extern "kernel32" fn GetProcessId(win.HANDLE) callconv(.winapi) u32;
extern "kernel32" fn CreateMutexW(?*win.SECURITY_ATTRIBUTES, win.BOOL, win.LPCWSTR) callconv(.winapi) ?win.HANDLE;
extern "kernel32" fn ReleaseMutex(win.HANDLE) callconv(.winapi) win.BOOL;
extern "kernel32" fn Process32FirstW(win.HANDLE, *ProcessEntry) callconv(.winapi) win.BOOL;
extern "kernel32" fn Process32NextW(win.HANDLE, *ProcessEntry) callconv(.winapi) win.BOOL;

const ProcessEntry = extern struct {
    size: u32,
    usage: u32,
    process_id: u32,
    default_heap: usize,
    module_id: u32,
    threads: u32,
    parent_id: u32,
    base_priority: i32,
    flags: u32,
    executable: [260]u16,
};

fn acquireHostMutex() !win.HANDLE {
    const name = std.unicode.utf8ToUtf16LeStringLiteral("Local\\ChatPaletteSandboxRunner");
    const handle = CreateMutexW(null, win.TRUE, name) orelse return error.SandboxMutexUnavailable;
    if (win.GetLastError() == .ALREADY_EXISTS) {
        win.CloseHandle(handle);
        return error.SandboxRunnerAlreadyActive;
    }
    return handle;
}

fn runningSandboxPid() !?u32 {
    const snapshot = win.kernel32.CreateToolhelp32Snapshot(0x00000002, 0); // TH32CS_SNAPPROCESS
    if (snapshot == win.INVALID_HANDLE_VALUE) return error.CouldNotEnumerateSandboxSessions;
    defer win.CloseHandle(snapshot);
    var entry = std.mem.zeroes(ProcessEntry);
    entry.size = @sizeOf(ProcessEntry);
    var available = Process32FirstW(snapshot, &entry);
    while (available != 0) : (available = Process32NextW(snapshot, &entry)) {
        const length = std.mem.indexOfScalar(u16, &entry.executable, 0) orelse entry.executable.len;
        if (sandboxProcess(entry.executable[0..length]) != null) return entry.process_id;
    }
    if (win.GetLastError() != .NO_MORE_FILES) return error.CouldNotEnumerateSandboxSessions;
    return null;
}

fn canStartSandbox() !void {
    if (try runningSandboxPid()) |pid| {
        std.debug.print("Windows Sandbox セッション使用中 PID {d}。セッションの終了後に再試行してください。\n", .{pid});
        return error.SandboxSessionAlreadyActive;
    }
}

const SessionEntry = struct { Id: []const u8 };

fn readSessionList(alloc: std.mem.Allocator, json: []const u8) ![]const SessionEntry {
    const listing = std.json.parseFromSliceLeaky(struct { WindowsSandboxEnvironments: []const SessionEntry }, alloc, json, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        std.debug.print("Windows Sandbox のセッション一覧を解釈できません。{s}\n", .{@errorName(err)});
        return error.InvalidSandboxSessionList;
    };
    return listing.WindowsSandboxEnvironments;
}

fn requireEmptySessionList(sessions: []const SessionEntry) !void {
    if (sessions.len != 0) {
        std.debug.print("Windows Sandbox セッション使用中です。`wsb list` で確認し、試験の前に使用中のセッションを終了してください。\n", .{});
        return error.SandboxSessionAlreadyActive;
    }
}

const SandboxCli = struct {
    alias: []const u8,
    layout: Layout,

    fn executable(alloc: std.mem.Allocator) !?[]const u8 {
        const local = std.process.getEnvVarOwned(alloc, "LOCALAPPDATA") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => return null,
            else => return err,
        };
        const alias = try std.fs.path.join(alloc, &.{ local, "Microsoft", "WindowsApps", "wsb.exe" });
        _ = win.GetFileAttributes(alias) catch |err| switch (err) {
            error.FileNotFound => return null, // Older Windows Sandbox versions have only the process check.
            else => return err,
        };
        return alias;
    }

    fn find(alloc: std.mem.Allocator, layout: Layout) !?SandboxCli {
        return .{ .alias = (try executable(alloc)) orelse return null, .layout = layout };
    }

    fn evidence(self: SandboxCli, alloc: std.mem.Allocator, step: []const u8) !std.fs.Dir {
        const path = try std.fs.path.join(alloc, &.{ self.layout.root, step });
        try std.fs.cwd().makeDir(path);
        return std.fs.cwd().openDir(path, .{ .no_follow = true });
    }

    fn list(self: SandboxCli, alloc: std.mem.Allocator, step: []const u8) ![]const SessionEntry {
        var logs = try self.evidence(alloc, step);
        defer logs.close();
        const result = try process.runAppExecutionAlias(alloc, &.{ self.alias, "list", "--raw" }, self.layout.root, logs, 10_000);
        if (!result.passed()) return error.SandboxSessionListFailed;
        return readSessionList(alloc, try logs.readFileAlloc(alloc, "stdout.txt", 64 * 1024));
    }

    fn start(self: SandboxCli, alloc: std.mem.Allocator, id: []const u8) !void {
        const xml = try std.fs.cwd().readFileAlloc(alloc, self.layout.configuration, 64 * 1024);
        var logs = try self.evidence(alloc, "session-start");
        defer logs.close();
        const request = try std.json.Stringify.valueAlloc(alloc, SessionEntry{ .Id = id }, .{});
        try files.writeNew(logs, "request.json", request);
        const result = try process.runSandboxStart(alloc, &.{ self.alias, "start", "--id", id, "--config", xml, "--raw" }, self.layout.root, logs, 60_000);
        if (!result.passed()) return error.SandboxSessionStartFailed;
        const json = try logs.readFileAlloc(alloc, "stdout.txt", 64 * 1024);
        try confirmStartedSession(alloc, id, json);
    }

    fn cleanup(self: SandboxCli, alloc: std.mem.Allocator, id: []const u8, connector: ?process.SandboxConnector) !Cleanup {
        const sessions = try self.list(alloc, "session-before-cleanup");
        const active = sessionPresent(sessions, id);
        if (active) {
            var logs = try self.evidence(alloc, "session-stop");
            defer logs.close();
            const result = try process.runAppExecutionAlias(alloc, &.{ self.alias, "stop", "--id", id, "--raw" }, self.layout.root, logs, 10_000);
            if (!result.passed()) return error.SandboxSessionStopFailed;
        }
        // A client on the way up can miss the service's stop notification. Drain its owned job as well.
        if (connector) |child| try child.stop();
        const remaining = try self.list(alloc, "session-after-cleanup");
        if (sessionPresent(remaining, id)) return error.SandboxSessionStillPresent;
        if (remaining.len == 0) try waitForSandboxExit();
        return .{ .status = if (active) .stopped else .already_closed, .session_id = id };
    }
};

fn newSessionId(alloc: std.mem.Allocator) ![]const u8 {
    var bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&bytes);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    const text = std.fmt.bytesToHex(bytes, .lower);
    return std.fmt.allocPrint(alloc, "{s}-{s}-{s}-{s}-{s}", .{ text[0..8], text[8..12], text[12..16], text[16..20], text[20..] });
}

fn confirmStartedSession(alloc: std.mem.Allocator, requested: []const u8, json: []const u8) !void {
    const reported = std.json.parseFromSliceLeaky(SessionEntry, alloc, json, .{ .ignore_unknown_fields = true }) catch
        return error.InvalidSandboxSessionStartReply;
    if (!std.ascii.eqlIgnoreCase(reported.Id, requested)) return error.SandboxSessionOwnershipUnverified;
}

fn sessionPresent(sessions: []const SessionEntry, id: []const u8) bool {
    for (sessions) |session| if (std.ascii.eqlIgnoreCase(session.Id, id)) return true;
    return false;
}

fn waitForSandboxExit() !void {
    var timer = try std.time.Timer.start();
    while (try runningSandboxPid() != null) {
        if (timer.read() >= 15 * std.time.ns_per_s) return error.SandboxSessionStillPresent;
        std.Thread.sleep(100 * std.time.ns_per_ms);
    }
}

const Cleanup = struct {
    status: enum { stopped, already_closed, manual_cli_unavailable, failed },
    session_id: ?[]const u8 = null,
    failure: ?[]const u8 = null,
};

pub const LifecycleEvidence = struct {
    request: []const u8,
    start: []const u8,
    preflight: []const u8,
    before_cleanup: []const u8,
    after_cleanup: []const u8,
};

pub fn validateCleanupEvidence(alloc: std.mem.Allocator, expected_id: []const u8, cleanup_json: []const u8, source: LifecycleEvidence) !void {
    const cleanup = try std.json.parseFromSliceLeaky(struct {
        status: @FieldType(Cleanup, "status"),
        session_id: ?[]const u8,
        failure: ?[]const u8,
        guest_passed: bool,
        host_failure: ?[]const u8 = null,
    }, alloc, cleanup_json, .{});
    if (!cleanup.guest_passed or cleanup.failure != null or cleanup.host_failure != null) return error.InvalidSandboxCleanupEvidence;
    if (expected_id.len == 0 or !std.ascii.eqlIgnoreCase(expected_id, cleanup.session_id orelse "") or
        (cleanup.status != .stopped and cleanup.status != .already_closed)) return error.InvalidSandboxCleanupEvidence;
    try confirmStartedSession(alloc, expected_id, source.request);
    try confirmStartedSession(alloc, expected_id, source.start);
    const preflight = try readSessionList(alloc, source.preflight);
    const before = try readSessionList(alloc, source.before_cleanup);
    const after = try readSessionList(alloc, source.after_cleanup);
    if (preflight.len != 0 or sessionPresent(after, expected_id) or
        sessionPresent(before, expected_id) != (cleanup.status == .stopped)) return error.InvalidSandboxCleanupEvidence;
}

const SandboxProcess = enum { launcher, client, vm };

fn sandboxProcess(executable: []const u16) ?SandboxProcess {
    // The server also runs when the session list is empty.
    inline for (.{
        .{ "WindowsSandbox.exe", SandboxProcess.launcher },
        .{ "WindowsSandboxRemoteSession.exe", SandboxProcess.client },
        .{ "WindowsSandboxClient.exe", SandboxProcess.client },
        .{ "vmmemWindowsSandbox", SandboxProcess.vm },
        .{ "vmmemWindowsSandbox.exe", SandboxProcess.vm },
    }) |entry| {
        if (win.eqlIgnoreCaseWTF16(executable, std.unicode.utf8ToUtf16LeStringLiteral(entry[0]))) return entry[1];
    }
    return null;
}

const Selection = struct {
    executable_sha256: []const u8,
    args: []const []const u8,
    freeze: ?freeze_suite.Pins = null,
};

const GuestReport = struct {
    passed: bool,
    result: ?process.Result = null,
    input_matches: bool = false,
    executable_sha256: ?[]const u8 = null,
    failure: ?[]const u8 = null,
};

fn appendXml(out: *std.Io.Writer, value: []const u8) !void {
    for (value) |ch| {
        switch (ch) {
            '&' => try out.writeAll("&amp;"),
            '<' => try out.writeAll("&lt;"),
            '>' => try out.writeAll("&gt;"),
            '"' => try out.writeAll("&quot;"),
            '\'' => try out.writeAll("&apos;"),
            else => try out.writeByte(ch),
        }
    }
}

fn mappedFolder(out: *std.Io.Writer, host_path: []const u8, guest_path: []const u8, read_only: bool) !void {
    try out.writeAll("    <MappedFolder><HostFolder>");
    try appendXml(out, host_path);
    try out.print("</HostFolder><SandboxFolder>{s}</SandboxFolder><ReadOnly>{s}</ReadOnly></MappedFolder>\n", .{
        guest_path,
        if (read_only) "true" else "false",
    });
}

pub const PackagePins = struct {
    archive: files.Digest,
    harness: files.Digest,
    controller: files.Digest,
};

pub const Mode = union(enum) {
    smoke,
    package: PackagePins,
    browser,

    fn guestCommand(self: Mode) []const u8 {
        return switch (self) {
            .smoke => "sandbox-guest",
            .package => "sandbox-package-guest",
            .browser => "sandbox-browser-guest",
        };
    }
};

fn config(allocator: std.mem.Allocator, input: []const u8, output: []const u8, mode: Mode) ![]u8 {
    var builder = std.Io.Writer.Allocating.init(allocator);
    errdefer builder.deinit();
    const out = &builder.writer;
    try out.writeAll(
        \\<Configuration>
        \\  <Networking>Disable</Networking>
        \\  <ClipboardRedirection>Disable</ClipboardRedirection>
        \\  <AudioInput>Disable</AudioInput>
        \\  <VideoInput>Disable</VideoInput>
        \\  <PrinterRedirection>Disable</PrinterRedirection>
        \\  <MappedFolders>
        \\
    );
    try mappedFolder(out, input, input_guest, true);
    try mappedFolder(out, output, output_guest, false);
    try out.print("  </MappedFolders>\n  <LogonCommand><Command>{s}\\{s} {s} {s} {s}", .{
        input_guest, tool_name, mode.guestCommand(), input_guest, output_guest,
    });
    if (mode == .package) {
        const pins = mode.package;
        try out.print(" {s} {s} {s}", .{ files.hex(pins.archive), files.hex(pins.harness), files.hex(pins.controller) });
    }
    try out.writeAll("</Command></LogonCommand>\n</Configuration>\n");
    return builder.toOwnedSlice();
}

fn readSelection(alloc: std.mem.Allocator, input: std.fs.Dir) !Selection {
    const text = try input.readFileAlloc(alloc, selection_name, 64 * 1024);
    return std.json.parseFromSliceLeaky(Selection, alloc, text, .{
        .max_value_len = 32767,
    });
}

pub fn silenceGuest(alloc: std.mem.Allocator, input_path: []const u8, output_path: []const u8, evidence: std.fs.Dir) !void {
    if (!std.mem.eql(u8, input_path, input_guest) or !std.mem.eql(u8, output_path, output_guest))
        return error.SandboxAudioGuestRequired;
    const muted_outputs = try audio.muteGuest();
    const report = try std.json.Stringify.valueAlloc(alloc, .{ .muted_outputs = muted_outputs }, .{});
    defer alloc.free(report);
    try files.writeNew(evidence, "audio.json", report);
}

pub fn host(
    allocator: std.mem.Allocator,
    app: []const u8,
    output: []const u8,
    prepare_only: bool,
    test_args: []const []const u8,
) !void {
    const harness = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(harness);
    try hostWithHarness(allocator, app, harness, output, prepare_only, test_args, .allow_manual);
}

pub const SessionControl = enum { allow_manual, require_owned };

pub fn hostWithHarness(
    allocator: std.mem.Allocator,
    app: []const u8,
    harness: []const u8,
    output: []const u8,
    prepare_only: bool,
    test_args: []const []const u8,
    control: SessionControl,
) !void {
    return hostSelection(allocator, app, harness, output, prepare_only, test_args, control, null);
}

pub fn hostFreeze(
    allocator: std.mem.Allocator,
    app: []const u8,
    harness: []const u8,
    output: []const u8,
    prepare_only: bool,
    suite: freeze_suite.Inputs,
) !void {
    return hostSelection(allocator, app, harness, output, prepare_only, &.{"--smoke"}, .require_owned, suite);
}

fn hostSelection(
    allocator: std.mem.Allocator,
    app: []const u8,
    harness: []const u8,
    output: []const u8,
    prepare_only: bool,
    test_args: []const []const u8,
    control: SessionControl,
    suite: ?freeze_suite.Inputs,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const host_session = switch (control) {
        .allow_manual => try Host.open(alloc, prepare_only),
        .require_owned => try Host.openOwned(alloc, prepare_only),
    };
    defer host_session.close();
    const layout = try Layout.create(alloc, output);
    var input = try std.fs.cwd().openDir(layout.input, .{ .no_follow = true });
    defer input.close();

    const tool_bytes = try std.fs.cwd().readFileAlloc(alloc, harness, max_executable_bytes);
    try files.writeNew(input, tool_name, tool_bytes);
    const test_bytes = try std.fs.cwd().readFileAlloc(alloc, app, max_executable_bytes);
    const app_hash = files.hex(files.digest(test_bytes));
    try files.writeNew(input, test_name, test_bytes);
    if (suite) |sources| {
        try freeze_suite.verify(input, tool_name, sources.pins.harness_sha256);
        try freeze_suite.stage(input, sources);
    }
    const selection = try std.json.Stringify.valueAlloc(alloc, Selection{
        .executable_sha256 = &app_hash,
        .args = test_args,
        .freeze = if (suite) |sources| sources.pins else null,
    }, .{ .whitespace = .indent_2, .emit_null_optional_fields = false });
    try files.writeNew(input, selection_name, selection);

    try layout.configure(alloc, .smoke);
    const deadline = timeout_ms + if (suite != null) freeze_suite.timeout_ms else @as(u32, 0);
    if (try host_session.run(GuestReport, alloc, layout, deadline)) |report| try requireGuestSuccess(report, &app_hash);
    if (suite) |sources| {
        try freeze_suite.verify(input, selection_name, files.hex(files.digest(selection)));
        for (freeze_suite.steps, sources.pins.runners_sha256) |step, sha| try freeze_suite.verify(input, step.image, sha);
    }
}

pub const Layout = struct {
    root: []const u8,
    input: []const u8,
    evidence: []const u8,
    configuration: []const u8,

    pub fn create(alloc: std.mem.Allocator, output: []const u8) !Layout {
        try std.fs.cwd().makeDir(output);
        const absolute = try std.fs.cwd().realpathAlloc(alloc, output);
        const input_path = try std.fs.path.join(alloc, &.{ absolute, "input" });
        const evidence = try std.fs.path.join(alloc, &.{ absolute, "results" });
        try std.fs.cwd().makeDir(input_path);
        try std.fs.cwd().makeDir(evidence);
        return .{
            .root = absolute,
            .input = input_path,
            .evidence = evidence,
            .configuration = try std.fs.path.join(alloc, &.{ absolute, "tests.wsb" }),
        };
    }

    pub fn configure(self: Layout, alloc: std.mem.Allocator, mode: Mode) !void {
        try files.writeNew(std.fs.cwd(), self.configuration, try config(alloc, self.input, self.evidence, mode));
    }
};

pub const Host = struct {
    launcher: ?[]const u8 = null,
    mutex: ?win.HANDLE = null,
    require_owned_session: bool = false,

    pub fn open(alloc: std.mem.Allocator, prepare_only: bool) !Host {
        if (prepare_only) return .{};
        const windows = try std.process.getEnvVarOwned(alloc, "SystemRoot");
        const launcher = try std.fs.path.join(alloc, &.{ windows, "System32", "WindowsSandbox.exe" });
        const self: Host = .{ .launcher = launcher, .mutex = try acquireHostMutex() };
        errdefer self.close();
        std.fs.cwd().access(launcher, .{}) catch return error.WindowsSandboxUnavailable;
        return self;
    }

    pub fn openOwned(alloc: std.mem.Allocator, prepare_only: bool) !Host {
        var self = try open(alloc, prepare_only);
        errdefer self.close();
        if (!prepare_only and (try SandboxCli.executable(alloc)) == null) return error.SandboxSessionControllerRequired;
        self.require_owned_session = true;
        return self;
    }

    pub fn close(self: Host) void {
        if (self.mutex) |host_lock| {
            _ = ReleaseMutex(host_lock);
            win.CloseHandle(host_lock);
        }
    }

    pub fn run(self: Host, comptime Report: type, alloc: std.mem.Allocator, layout: Layout, guest_timeout_ms: u32) !?Report {
        const launcher = self.launcher orelse return null;
        const cli = try SandboxCli.find(alloc, layout);
        if (cli == null and self.require_owned_session) return error.SandboxSessionControllerRequired;
        if (cli) |control| try requireEmptySessionList(try control.list(alloc, "session-preflight"));
        try canStartSandbox();
        const session_id = if (cli != null) try newSessionId(alloc) else null;
        // The connector continues to run while the guest is visible. Wait for the mapped result before stopping it.
        const argv: []const []const u8 = if (cli) |control|
            &.{ control.alias, "connect", "--id", session_id.?, "--raw" }
        else
            &.{ launcher, layout.configuration };
        var connector: ?process.SandboxConnector = null;
        defer if (connector) |child| child.close();
        const observation: anyerror!Report = watch_guest: {
            if (cli) |control| control.start(alloc, session_id.?) catch |err| break :watch_guest err;
            break :watch_guest connectAndObserve(Report, alloc, layout, argv, session_id, &connector, guest_timeout_ms);
        };
        var host_failure: ?anyerror = null;
        const report: ?Report = observation catch |err| no_report: {
            host_failure = err;
            break :no_report null;
        };
        var cleanup_failure: ?anyerror = null;
        const cleanup: Cleanup = if (cli) |control|
            control.cleanup(alloc, session_id.?, connector) catch |err| failed: {
                cleanup_failure = err;
                std.debug.print("Windows Sandbox の自動終了を確認できません。{s}。結果フォルダー {s}\n", .{ @errorName(err), layout.root });
                break :failed .{ .status = .failed, .session_id = session_id, .failure = @errorName(err) };
            }
        else
            .{ .status = .manual_cli_unavailable };
        const guest_passed = if (report) |value| value.passed else false;
        writeCleanupReceipt(alloc, layout.root, cleanup, guest_passed, host_failure) catch |err| {
            std.debug.print("Windows Sandbox の終了記録を書き込めません。{s}。結果フォルダー {s}\n", .{ @errorName(err), layout.root });
            if (host_failure == null and guest_passed) return cleanup_failure orelse err;
        };
        if (host_failure) |err| return err;
        // Preserve a failed guest report for the caller; cleanup failures have an independent receipt and diagnostic.
        if (guest_passed) {
            if (cleanup_failure) |err| return err;
        }
        return report;
    }
};

fn connectAndObserve(
    comptime Report: type,
    alloc: std.mem.Allocator,
    layout: Layout,
    argv: []const []const u8,
    session_id: ?[]const u8,
    connector: *?process.SandboxConnector,
    guest_timeout_ms: u32,
) !Report {
    const handle = if (session_id != null) owned: {
        connector.* = try process.SandboxConnector.start(alloc, argv);
        break :owned connector.*.?.handle;
    } else legacy: {
        var child = std.process.Child.init(argv, alloc);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
        try child.spawn();
        win.CloseHandle(child.thread_handle);
        std.debug.print("wsb.exe がないため試験用の Windows Sandbox を手動で終了してください。\n", .{});
        break :legacy child.id;
    };
    defer if (session_id == null) win.CloseHandle(handle);
    const launcher_info = try std.json.Stringify.valueAlloc(alloc, .{
        .pid = GetProcessId(handle),
        .config = layout.configuration,
        .session_id = session_id,
    }, .{ .whitespace = .indent_2 });
    const launcher_info_path = try std.fs.path.join(alloc, &.{ layout.root, "launcher.json" });
    try files.writeNew(std.fs.cwd(), launcher_info_path, launcher_info);
    return waitForGuest(Report, alloc, layout.evidence, handle, 180_000 + guest_timeout_ms);
}

fn writeCleanupReceipt(alloc: std.mem.Allocator, root: []const u8, cleanup: Cleanup, guest_passed: bool, host_failure: ?anyerror) !void {
    const path = try std.fs.path.join(alloc, &.{ root, "session-cleanup.json" });
    const receipt = try std.json.Stringify.valueAlloc(alloc, .{
        .status = cleanup.status,
        .session_id = cleanup.session_id,
        .failure = cleanup.failure,
        .guest_passed = guest_passed,
        .host_failure = if (host_failure) |err| @errorName(err) else null,
    }, .{ .whitespace = .indent_2 });
    try files.writeNew(std.fs.cwd(), path, receipt);
}

/// Observe an existing result directory without starting or stopping a Windows Sandbox session.
pub fn watch(allocator: std.mem.Allocator, evidence: []const u8, deadline_ms: u32) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    try requireGuestSuccess(try waitForGuest(GuestReport, arena.allocator(), evidence, null, deadline_ms), null);
}

fn requireGuestSuccess(report: GuestReport, expected_sha: ?[]const u8) !void {
    if (!report.passed or !report.input_matches or report.failure != null or report.result == null or !report.result.?.passed()) {
        return error.SandboxTestsFailed;
    }
    const sha = report.executable_sha256 orelse return error.SandboxInputChanged;
    if (sha.len != 64) return error.SandboxInputChanged;
    for (sha) |byte| if (!std.ascii.isHex(byte)) return error.SandboxInputChanged;
    if (expected_sha) |expected| {
        if (!std.mem.eql(u8, sha, expected)) return error.SandboxInputChanged;
    }
}

fn waitForGuest(comptime Report: type, alloc: std.mem.Allocator, evidence: []const u8, launcher: ?win.HANDLE, deadline_ms: u32) !Report {
    if (deadline_ms == 0 or deadline_ms == win.INFINITE) return error.InvalidSandboxWait;
    var results = try std.fs.cwd().openDir(evidence, .{ .no_follow = true });
    defer results.close();
    var stdout_buffer: [4096]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;
    var stdout = std.fs.File.stdout().writerStreaming(&stdout_buffer);
    var stderr = std.fs.File.stderr().writerStreaming(&stderr_buffer);
    var stdout_tail: log_tail.Tail = .{};
    var stderr_tail: log_tail.Tail = .{};
    var timer = try std.time.Timer.start();
    const deadline = @as(u64, deadline_ms) * std.time.ns_per_ms;
    while (true) {
        const data: ?[]const u8 = results.readFileAlloc(alloc, "result.json", 256 * 1024) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        try stdout_tail.update(results, "stdout.txt", &stdout.interface, data != null);
        try stderr_tail.update(results, "stderr.txt", &stderr.interface, data != null);
        if (data) |report| return std.json.parseFromSliceLeaky(Report, alloc, report, .{});
        if (launcher) |handle| {
            var launcher_exit: u32 = undefined;
            if (win.kernel32.GetExitCodeProcess(handle, &launcher_exit) == 0) {
                return error.SandboxLauncherStatusUnavailable;
            }
            if (launcher_exit != 259 and launcher_exit != 0) {
                std.debug.print("Windows Sandbox 起動結果 0x{x}\n", .{launcher_exit});
                return error.SandboxLaunchFailed;
            }
        }
        const elapsed = timer.read();
        if (elapsed >= deadline) {
            std.debug.print("Windows Sandbox の完了を確認できませんでした。結果フォルダー {s}\n", .{evidence});
            return error.SandboxGuestDidNotReport;
        }
        std.Thread.sleep(@min(100 * std.time.ns_per_ms, deadline - elapsed));
    }
}

fn guestRun(alloc: std.mem.Allocator, input_path: []const u8, output_path: []const u8) !GuestReport {
    var input = try std.fs.cwd().openDir(input_path, .{ .no_follow = true });
    defer input.close();
    var output = try std.fs.cwd().openDir(output_path, .{ .no_follow = true });
    defer output.close();
    const selection = try readSelection(alloc, input);
    var expected: files.Digest = undefined;
    if (selection.executable_sha256.len != 64) return error.InvalidExecutableDigest;
    _ = try std.fmt.hexToBytes(&expected, selection.executable_sha256);
    const test_bytes = try input.readFileAlloc(alloc, test_name, max_executable_bytes);
    const observed = files.digest(test_bytes);
    if (!std.mem.eql(u8, &expected, &observed)) return error.SandboxInputChanged;
    try silenceGuest(alloc, input_path, output_path, output);

    const tmp = try std.process.getEnvVarOwned(alloc, "TEMP");
    const work_path = try files.newDirectory(alloc, tmp, "ChatPaletteTest-");
    var work = try std.fs.cwd().openDir(work_path, .{ .no_follow = true });
    defer work.close();
    try files.writeNew(work, test_name, test_bytes);
    const test_path = try std.fs.path.join(alloc, &.{ work_path, test_name });
    const freeze_app = if (selection.freeze != null) try files.openImmutable(alloc, test_path) else null;
    defer if (freeze_app) |locked| locked.close();
    if (selection.freeze) |pins| {
        if (selection.args.len != 1 or !std.mem.eql(u8, selection.args[0], "--smoke")) return error.InvalidFreezeSmokeArguments;
        try freeze_suite.verify(work, test_name, files.hex(expected));
        try freeze_suite.run(alloc, input, work, work_path, output, output_path, test_path, pins);
    }
    const argv = try alloc.alloc([]const u8, selection.args.len + 1);
    argv[0] = test_path;
    @memcpy(argv[1..], selection.args);
    const result = try process.run(alloc, argv, work_path, output, timeout_ms);
    const final = try files.readDigest(work, test_name);
    const input_matches = std.mem.eql(u8, &observed, &final);
    return .{
        .passed = result.passed() and input_matches,
        .result = result,
        .input_matches = input_matches,
        .executable_sha256 = selection.executable_sha256,
    };
}

pub fn guest(allocator: std.mem.Allocator, input: []const u8, output: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var evidence = try std.fs.cwd().openDir(output, .{ .no_follow = true });
    defer evidence.close();
    // Only the guest that claimed this directory may create logs or publish a result.
    try files.writeNew(evidence, "sandbox-guest.started", "");
    const report = guestRun(alloc, input, output) catch |err| GuestReport{
        .passed = false,
        .failure = @errorName(err),
    };
    try process.saveResult(alloc, output, report);
    if (!report.passed) return error.SandboxTestsFailed;
}

test "Sandbox configuration quotes host path XML and invokes the Zig guest" {
    const xml = try config(std.testing.allocator, "C:\\x & y\\input", "C:\\a\\logs", .smoke);
    defer std.testing.allocator.free(xml);
    try std.testing.expect(std.mem.indexOf(u8, xml, "C:\\x &amp; y\\input") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "ChatPaletteTools.exe sandbox-guest") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "powershell") == null);

    const browser_xml = try config(std.testing.allocator, "C:\\sandbox\\input", "C:\\sandbox\\logs", .browser);
    defer std.testing.allocator.free(browser_xml);
    try std.testing.expect(std.mem.indexOf(u8, browser_xml, "<Networking>Disable</Networking>") != null);
    try std.testing.expect(std.mem.indexOf(u8, browser_xml, "ChatPaletteTools.exe sandbox-browser-guest") != null);
}

test "Sandbox preflight detects an existing VM after the client closes" {
    try std.testing.expectEqual(SandboxProcess.vm, sandboxProcess(std.unicode.utf8ToUtf16LeStringLiteral("vmmemWindowsSandbox")));
    try std.testing.expectEqual(SandboxProcess.client, sandboxProcess(std.unicode.utf8ToUtf16LeStringLiteral("windowssandboxremotesession.exe")));
    try std.testing.expect(sandboxProcess(std.unicode.utf8ToUtf16LeStringLiteral("WindowsSandboxServer.exe")) == null);
    try std.testing.expect(sandboxProcess(std.unicode.utf8ToUtf16LeStringLiteral("vmmemWSL")) == null);
}

test "Sandbox preflight checks the CLI list even when the session has no client" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    try requireEmptySessionList(try readSessionList(alloc, "{\"WindowsSandboxEnvironments\":[]}"));
    try std.testing.expectError(error.SandboxSessionAlreadyActive, requireEmptySessionList(try readSessionList(alloc, "{\"WindowsSandboxEnvironments\":[{\"Id\":\"b6f4e20a-5b3c-40ea-9b33-5fa68f169706\"}]}")));
    try std.testing.expectError(error.InvalidSandboxSessionList, readSessionList(alloc, "{}"));
}

test "Sandbox start requires the ID that was assigned before launch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const id = try newSessionId(alloc);
    try std.testing.expectEqual(@as(usize, 36), id.len);
    try std.testing.expectEqual(@as(u8, '4'), id[14]);
    const reply = try std.json.Stringify.valueAlloc(alloc, SessionEntry{ .Id = id }, .{});
    try confirmStartedSession(alloc, id, reply);
    try std.testing.expectError(error.InvalidSandboxSessionStartReply, confirmStartedSession(alloc, id, "{}"));
    try std.testing.expectError(error.SandboxSessionOwnershipUnverified, confirmStartedSession(alloc, id, "{\"Id\":\"b6f4e20a-5b3c-40ea-9b33-5fa68f169706\"}"));
}

test "Sandbox cleanup finds only the assigned ID among the listed sessions" {
    const owned = "b6f4e20a-5b3c-40ea-9b33-5fa68f169706";
    const other: SessionEntry = .{ .Id = "7312362a-bb59-4581-9b7b-9a48e2520cf7" };
    try std.testing.expect(!sessionPresent(&.{other}, owned));
    try std.testing.expect(sessionPresent(&.{ other, .{ .Id = "B6f4e20a-5b3c-40ea-9b33-5fa68f169706" } }, owned));
}

test "Sandbox freeze evidence ties the assigned ID to its start and disappearance" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const id = "b6f4e20a-5b3c-40ea-9b33-5fa68f169706";
    const reply = "{\"Id\":\"" ++ id ++ "\"}";
    const present = "{\"WindowsSandboxEnvironments\":[" ++ reply ++ "]}";
    const empty = "{\"WindowsSandboxEnvironments\":[]}";
    const cleanup = "{\"status\":\"stopped\",\"session_id\":\"" ++ id ++ "\",\"failure\":null,\"guest_passed\":true}";
    var stage: LifecycleEvidence = .{ .request = reply, .start = reply, .preflight = empty, .before_cleanup = present, .after_cleanup = empty };
    try validateCleanupEvidence(alloc, id, cleanup, stage);
    const manual_cleanup = "{\"status\":\"manual_cli_unavailable\",\"session_id\":null,\"failure\":null,\"guest_passed\":true}";
    try std.testing.expectError(error.InvalidSandboxCleanupEvidence, validateCleanupEvidence(alloc, id, manual_cleanup, stage));
    try std.testing.expectError(error.InvalidSandboxCleanupEvidence, validateCleanupEvidence(alloc, "", cleanup, stage));
    const host_error = cleanup[0 .. cleanup.len - 1] ++ ",\"host_failure\":\"UnexpectedEndOfInput\"}";
    try std.testing.expectError(error.InvalidSandboxCleanupEvidence, validateCleanupEvidence(alloc, id, host_error, stage));
    stage.after_cleanup = present;
    try std.testing.expectError(error.InvalidSandboxCleanupEvidence, validateCleanupEvidence(alloc, id, cleanup, stage));
    stage.after_cleanup = empty;
    stage.before_cleanup = empty;
    try std.testing.expectError(error.InvalidSandboxCleanupEvidence, validateCleanupEvidence(alloc, id, cleanup, stage));
    stage.start = "{\"Id\":\"7312362a-bb59-4581-9b7b-9a48e2520cf7\"}";
    try std.testing.expectError(error.SandboxSessionOwnershipUnverified, validateCleanupEvidence(alloc, id, cleanup, stage));
}

test "Sandbox prepares the selected harness and rejects modified guest input" {
    const alloc = std.testing.allocator;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try temporary.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);
    const app = try std.fs.path.join(alloc, &.{ root, "SyntheticApp.exe" });
    defer alloc.free(app);
    const harness = try std.fs.path.join(alloc, &.{ root, "SyntheticHarness.exe" });
    defer alloc.free(harness);
    const output = try std.fs.path.join(alloc, &.{ root, "prepared" });
    defer alloc.free(output);
    try files.writeNew(temporary.dir, "SyntheticApp.exe", "app fixture");
    try files.writeNew(temporary.dir, "SyntheticHarness.exe", "harness fixture");
    try hostWithHarness(alloc, app, harness, output, true, &.{ "--smoke", "with space" }, .require_owned);
    try std.testing.expectEqual(files.digest("app fixture"), try files.readDigest(temporary.dir, "prepared/input/ChatPaletteTest.exe"));
    try std.testing.expectEqual(files.digest("harness fixture"), try files.readDigest(temporary.dir, "prepared/input/ChatPaletteTools.exe"));
    try std.testing.expectError(error.FileNotFound, temporary.dir.access("prepared/results/result.json", .{}));
    try std.testing.expectError(error.PathAlreadyExists, hostWithHarness(alloc, app, harness, output, true, &.{"--smoke"}, .allow_manual));

    const input = try std.fs.path.join(alloc, &.{ output, "input" });
    defer alloc.free(input);
    const results = try std.fs.path.join(alloc, &.{ output, "results" });
    defer alloc.free(results);
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var staged = try std.fs.cwd().openDir(input, .{});
    defer staged.close();
    const selection = try readSelection(arena.allocator(), staged);
    try std.testing.expectEqualStrings("with space", selection.args[1]);
    try std.testing.expect(selection.freeze == null);
    try std.testing.expectError(error.SandboxAudioGuestRequired, guestRun(arena.allocator(), input, results));
    try std.testing.expectError(error.FileNotFound, temporary.dir.access("prepared/results/audio.json", .{}));
    try std.testing.expectError(error.FileNotFound, temporary.dir.access("prepared/results/stdout.txt", .{}));
    const modified = try staged.createFile(test_name, .{ .truncate = true });
    try modified.writeAll("mutated app fixture");
    modified.close();
    try std.testing.expectError(error.SandboxInputChanged, guestRun(arena.allocator(), input, results));

    const probe = try std.fs.path.join(alloc, &.{ root, "competing" });
    defer alloc.free(probe);
    try temporary.dir.makeDir("competing");
    try files.writeNew(temporary.dir, "competing/sandbox-guest.started", "");
    try std.testing.expectError(error.PathAlreadyExists, guest(alloc, input, probe));
    try std.testing.expectError(error.FileNotFound, temporary.dir.access("competing/result.json", .{}));
    try std.testing.expectError(error.FileNotFound, temporary.dir.access("competing/stdout.txt", .{}));

    try std.testing.expectError(error.SandboxTestsFailed, guest(alloc, input, results));
    const saved = try files.readDigest(temporary.dir, "prepared/results/result.json");
    try std.testing.expectError(error.PathAlreadyExists, guest(alloc, input, results));
    try std.testing.expectEqual(saved, try files.readDigest(temporary.dir, "prepared/results/result.json"));
}

test "freeze prepares pinned desktop runners without launching a guest or writing test results" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realpathAlloc(alloc, ".");
    const app = try std.fs.path.join(alloc, &.{ root, "product" });
    const harness = try std.fs.path.join(alloc, &.{ root, "controller" });
    try files.writeNew(temp.dir, "product", "app fixture");
    try files.writeNew(temp.dir, "controller", "tool fixture");
    var suite: freeze_suite.Inputs = undefined;
    suite.pins.harness_sha256 = files.hex(files.digest("tool fixture"));
    for (freeze_suite.steps, &suite.paths, &suite.pins.runners_sha256) |step, *path, *sha| {
        try files.writeNew(temp.dir, step.image, step.name);
        path.* = try std.fs.path.join(alloc, &.{ root, step.image });
        sha.* = files.hex(files.digest(step.name));
    }
    try hostFreeze(alloc, app, harness, try std.fs.path.join(alloc, &.{ root, "prepared" }), true, suite);
    var mounted = try temp.dir.openDir("prepared/input", .{});
    defer mounted.close();
    const selected = try readSelection(alloc, mounted);
    try std.testing.expectEqualDeep(suite.pins, selected.freeze.?);
    try std.testing.expectEqual(@as(usize, 1), selected.args.len);
    try std.testing.expectEqualStrings("--smoke", selected.args[0]);
    for (freeze_suite.steps, suite.pins.runners_sha256) |step, digest| try freeze_suite.verify(mounted, step.image, digest);
    try std.testing.expectError(error.FileNotFound, temp.dir.access("prepared/results/audio.json", .{}));
    try std.testing.expectError(error.FileNotFound, temp.dir.access("prepared/results/unit-app/result.json", .{}));
    try std.testing.expectError(error.FileNotFound, temp.dir.access("prepared/results/result.json", .{}));
    suite.pins.runners_sha256[1] = files.hex(files.digest("another build"));
    try std.testing.expectError(error.SandboxFreezeInputChanged, hostFreeze(alloc, app, harness, try std.fs.path.join(alloc, &.{ root, "wrong" }), true, suite));
    try std.testing.expectError(error.FileNotFound, temp.dir.access("wrong/tests.wsb", .{}));
}
