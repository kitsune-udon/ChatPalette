const std = @import("std");
const files = @import("tools/files.zig");
const process = @import("tools/process.zig");
const windows = @import("desktop/win.zig");
const win = windows.api;
const kernel = std.os.windows;

const allocator = std.heap.page_allocator;
const deadline_ms = 15000;
const db_path = "data/settings.db";
const executable = "ChatPalette.exe";
const host_class = windows.wide("ChatPalette.Host");
const invalid_arguments = "起動引数が不正です";

const Trial = struct {
    name: []const u8,
    folder: []const u8,
    args: []const []const u8,
    pid: ?u32 = null,
    exit_code: ?u32 = null,
    timed_out: bool = false,
    elapsed_ms: ?u64 = null,
    stdout_bytes: ?u64 = null,
    stderr_bytes: ?u64 = null,
    ready_ms: ?u64 = null,
    cleanup_error: ?[]const u8 = null,
};

const Report = struct {
    arena: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(allocator),
    failure: ?[]const u8 = null,
    exe: ?files.HexDigest = null,
    a_before: ?files.HexDigest = null,
    a_after: ?files.HexDigest = null,
    b_before: ?files.HexDigest = null,
    b_after: ?files.HexDigest = null,
    invalid_db_before: ?files.HexDigest = null,
    invalid_db_after: ?files.HexDigest = null,
    invalid_arguments_leave_no_data: bool = false,
    worker_leaves_no_data: bool = false,
    quiet_instances_are_independent: bool = false,
    rejected_check_leaves_both_hosts_running: bool = false,
    takeover_leaves_other_host_running: bool = false,
    trials: [9]Trial = undefined,
    trial_count: usize = 0,
};

pub fn main() !void {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len != 3) {
        std.debug.print("chatpalette-startup-test <ChatPalette.exe> <新規結果フォルダー>\n", .{});
        std.process.exit(2);
    }
    const cwd = std.fs.cwd();
    const input = try cwd.realpathAlloc(allocator, args[1]);
    defer allocator.free(input);
    if (!std.ascii.eqlIgnoreCase(std.fs.path.extension(input), ".exe")) return error.ExpectedExecutable;
    try cwd.makeDir(args[2]);
    const output = try cwd.realpathAlloc(allocator, args[2]);
    defer allocator.free(output);
    var dir = try cwd.openDir(output, .{});
    defer dir.close();

    var report: Report = .{};
    defer report.arena.deinit();
    verify(input, output, dir, &report) catch |failure| {
        report.failure = @errorName(failure);
    };
    for (report.trials[0..report.trial_count]) |trial| {
        if (report.failure == null and trial.cleanup_error != null) report.failure = trial.cleanup_error;
    }
    const summary = .{
        .passed = report.failure == null,
        .failure = report.failure,
        .executable_sha256 = report.exe,
        .database_a_sha256_before = report.a_before,
        .database_a_sha256_after = report.a_after,
        .database_b_sha256_before = report.b_before,
        .database_b_sha256_after = report.b_after,
        .invalid_database_sha256_before = report.invalid_db_before,
        .invalid_database_sha256_after = report.invalid_db_after,
        .invalid_arguments_leave_no_data = report.invalid_arguments_leave_no_data,
        .worker_leaves_no_data = report.worker_leaves_no_data,
        .quiet_instances_are_independent = report.quiet_instances_are_independent,
        .rejected_check_leaves_both_hosts_running = report.rejected_check_leaves_both_hosts_running,
        .takeover_leaves_other_host_running = report.takeover_leaves_other_host_running,
        .trials = report.trials[0..report.trial_count],
    };
    try process.saveResult(allocator, output, summary);
    if (report.failure) |name| {
        std.debug.print("起動試験に失敗しました。{s}\n", .{name});
        std.process.exit(1);
    }
    std.debug.print("起動試験に合格しました。\n", .{});
}

fn verify(input: []const u8, output: []const u8, dir: std.fs.Dir, report: *Report) !void {
    const source = try files.openImmutable(allocator, input);
    defer source.close();
    const bytes = try source.readToEndAlloc(allocator, 64 * 1024 * 1024);
    defer allocator.free(bytes);
    const digest = files.digest(bytes);
    report.exe = files.hex(digest);
    var a = try Folder.init(dir, output, "a", bytes, digest);
    defer a.deinit();
    var b = try Folder.init(dir, output, "b", bytes, digest);
    defer b.deinit();
    try dir.makeDir("logs");
    var logs = try dir.openDir("logs", .{});
    defer logs.close();

    try finite(logs, report, a, "01-invalid-arguments", &.{ "--quiet", "--smoke" }, 1, invalid_arguments);
    try expectMissing(a.dir, "data");
    report.invalid_arguments_leave_no_data = true;

    try workerMode(logs, report, a);
    try expectMissing(a.dir, "data");
    report.worker_leaves_no_data = true;

    try finite(logs, report, a, "03-smoke-a", &.{"--smoke"}, 0, "");
    try finite(logs, report, b, "04-smoke-b", &.{"--smoke"}, 0, "");
    report.a_before = try a.databaseDigest();
    report.b_before = try b.databaseDigest();

    var quiet_a = try Child.init(logs, report, a, "05-quiet-a", &.{"--quiet"});
    defer quiet_a.deinit();
    _ = try quiet_a.waitHost(a);
    var quiet_b = try Child.init(logs, report, b, "06-quiet-b", &.{"--quiet"});
    defer quiet_b.deinit();
    _ = try quiet_b.waitHost(b);
    if (quiet_a.pid == quiet_b.pid) return error.QuietHostsShareProcess;
    _ = try quiet_a.ownedHost(a);
    _ = try quiet_b.ownedHost(b);
    report.quiet_instances_are_independent = true;

    try finite(logs, report, a, "07-check-rejection", &.{"--check"}, 1, invalid_arguments);
    _ = try quiet_a.ownedHost(a);
    _ = try quiet_b.ownedHost(b);
    report.rejected_check_leaves_both_hosts_running = true;

    try finite(logs, report, a, "08-smoke-takeover", &.{"--smoke"}, 0, "");
    try quiet_a.expectExit(0, "");
    if (a.host() != null) return error.SmokeHostStillRunning;
    const b_host = try quiet_b.ownedHost(b);
    report.takeover_leaves_other_host_running = true;
    if (win.PostMessageW(b_host, win.WM_CLOSE, 0, 0) == 0) return error.CannotCloseQuietHost;
    try quiet_b.expectExit(0, "");

    report.a_after = try a.databaseDigest();
    report.b_after = try b.databaseDigest();
    if (!std.mem.eql(u8, &report.a_before.?, &report.a_after.?) or
        !std.mem.eql(u8, &report.b_before.?, &report.b_after.?)) return error.ExistingDatabaseChanged;

    try b.dir.rename(db_path, "data/settings.valid.db");
    try files.writeNew(b.dir, db_path, "ChatPalette startup test: intentionally invalid SQLite database\n");
    report.invalid_db_before = files.hex(try files.readDigest(b.dir, db_path));
    try finite(logs, report, b, "09-corrupt-db-smoke", &.{"--smoke"}, 1, "ChatPalette: InvalidDatabase");
    report.invalid_db_after = files.hex(try files.readDigest(b.dir, db_path));
    if (!std.mem.eql(u8, &report.invalid_db_before.?, &report.invalid_db_after.?)) return error.CorruptDatabaseChanged;
    if (!std.mem.eql(u8, &report.b_before.?, &files.hex(try files.readDigest(b.dir, "data/settings.valid.db"))))
        return error.SavedDatabaseChanged;
}

fn expectMissing(dir: std.fs.Dir, path: []const u8) !void {
    dir.access(path, .{}) catch |failure| {
        if (failure == error.FileNotFound) return;
        return failure;
    };
    return error.UnexpectedStartupData;
}

const Folder = struct {
    dir: std.fs.Dir,
    name: []const u8,
    path: []const u8,
    exe: []const u8,
    title: [:0]u16,

    fn init(dir: std.fs.Dir, output: []const u8, name: []const u8, bytes: []const u8, digest: files.Digest) !Folder {
        try dir.makeDir(name);
        var isolated = try dir.openDir(name, .{});
        errdefer isolated.close();
        try files.writeNew(isolated, executable, bytes);
        if (!std.mem.eql(u8, &digest, &(try files.readDigest(isolated, executable))))
            return error.ExecutableCopyMismatch;
        const path = try std.fs.path.join(allocator, &.{ output, name });
        errdefer allocator.free(path);
        const exe = try std.fs.path.join(allocator, &.{ path, executable });
        errdefer allocator.free(exe);
        const lower = try std.ascii.allocLowerString(allocator, path);
        defer allocator.free(lower);
        const title = try std.fmt.allocPrint(allocator, "ChatPalette.{s}", .{files.hex(files.digest(lower))});
        defer allocator.free(title);
        return .{
            .dir = isolated,
            .name = name,
            .path = path,
            .exe = exe,
            .title = try std.unicode.utf8ToUtf16LeAllocZ(allocator, title),
        };
    }

    fn deinit(self: *Folder) void {
        self.dir.close();
        allocator.free(self.path);
        allocator.free(self.exe);
        allocator.free(self.title);
    }

    fn host(self: Folder) win.HWND {
        return win.FindWindowW(host_class, self.title);
    }

    fn databaseDigest(self: Folder) !files.HexDigest {
        const file = try self.dir.openFile(db_path, .{});
        defer file.close();
        var header: [16]u8 = undefined;
        if ((try file.readAll(&header)) != header.len or !std.mem.eql(u8, &header, "SQLite format 3\x00"))
            return error.MissingSqliteHeader;
        try file.seekTo(0);
        return files.hex(try files.fileDigest(file));
    }
};

fn finite(logs: std.fs.Dir, report: *Report, folder: Folder, name: []const u8, args: []const []const u8, exit_code: u32, stderr: []const u8) !void {
    var child = try Child.init(logs, report, folder, name, args);
    defer child.deinit();
    try child.expectExit(exit_code, stderr);
}

fn workerMode(logs: std.fs.Dir, report: *Report, folder: Folder) !void {
    var entropy: [16]u8 = undefined;
    std.crypto.random.bytes(&entropy);
    const name = try std.fmt.allocPrint(allocator, "chatpalette-startup-{s}", .{std.fmt.bytesToHex(entropy, .lower)});
    defer allocator.free(name);
    const pipe_w = try wideName("\\\\.\\pipe\\{s}", name);
    defer allocator.free(pipe_w);
    const new_pipe = win.CreateNamedPipeW(
        pipe_w,
        win.PIPE_ACCESS_DUPLEX | win.FILE_FLAG_FIRST_PIPE_INSTANCE,
        win.PIPE_NOWAIT | win.PIPE_REJECT_REMOTE_CLIENTS,
        1,
        65536,
        65536,
        0,
        null,
    );
    if (new_pipe == null or new_pipe == kernel.INVALID_HANDLE_VALUE) return error.CreateStartupPipe;
    var pipe: win.HANDLE = new_pipe;
    defer if (pipe != null) {
        _ = win.CloseHandle(pipe);
    };
    if (win.ConnectNamedPipe(pipe, null) == 0 and win.GetLastError() != win.ERROR_PIPE_LISTENING)
        return error.ListenStartupPipe;
    const event_w = try wideName("{s}-ready", name);
    defer allocator.free(event_w);
    win.SetLastError(0);
    const ready = win.CreateEventW(null, 0, 0, event_w) orelse return error.CreateStartupEvent;
    defer _ = win.CloseHandle(ready);
    if (win.GetLastError() == win.ERROR_ALREADY_EXISTS) return error.StartupEventExists;

    var child = try Child.init(logs, report, folder, "02-worker-mode", &.{ "-PipeName", name });
    defer child.deinit();
    const handles = [_]win.HANDLE{ ready, child.handle };
    switch (win.WaitForMultipleObjects(handles.len, &handles, 0, deadline_ms)) {
        win.WAIT_OBJECT_0 => {},
        win.WAIT_OBJECT_0 + 1 => return error.WorkerExitedBeforeReady,
        win.WAIT_TIMEOUT => {
            child.trial.timed_out = true;
            return error.WorkerReadinessTimedOut;
        },
        else => return error.WaitForStartupWorker,
    }
    child.trial.ready_ms = child.timer.read() / std.time.ns_per_ms;
    try expectMissing(folder.dir, "data");
    if (win.CloseHandle(pipe) == 0) return error.CloseStartupPipe;
    pipe = null;
    try child.expectExit(1, "ChatPalette: EndOfStream");
}

fn wideName(comptime format: []const u8, name: []const u8) ![:0]u16 {
    const bytes = try std.fmt.allocPrint(allocator, format, .{name});
    defer allocator.free(bytes);
    return std.unicode.utf8ToUtf16LeAllocZ(allocator, bytes);
}

const Child = struct {
    handle: kernel.HANDLE,
    pid: u32,
    job: kernel.HANDLE,
    output: std.fs.Dir,
    timer: std.time.Timer,
    trial: *Trial,

    fn init(parent: std.fs.Dir, report: *Report, folder: Folder, name: []const u8, args: []const []const u8) !Child {
        const arena = report.arena.allocator();
        const recorded_args = try arena.alloc([]const u8, args.len);
        for (recorded_args, args) |*recorded, argument| recorded.* = try arena.dupe(u8, argument);
        const trial = &report.trials[report.trial_count];
        report.trial_count += 1;
        trial.* = .{ .name = name, .folder = folder.name, .args = recorded_args };
        // The fixed test options and the generated pipe name contain only safe ASCII.
        const suffix = try std.mem.join(allocator, " ", args);
        defer allocator.free(suffix);
        const command_line = try std.fmt.allocPrint(allocator, "\"{s}\" {s}", .{ folder.exe, suffix });
        defer allocator.free(command_line);
        const command = try std.unicode.utf8ToUtf16LeAllocZ(allocator, command_line);
        defer allocator.free(command);
        const exe = try std.unicode.utf8ToUtf16LeAllocZ(allocator, folder.exe);
        defer allocator.free(exe);
        const cwd = try std.unicode.utf8ToUtf16LeAllocZ(allocator, folder.path);
        defer allocator.free(cwd);
        try parent.makeDir(name);
        var output = try parent.openDir(name, .{});
        errdefer output.close();
        const stdout = try capturedFile(output, "stdout.txt");
        defer stdout.close();
        const stderr = try capturedFile(output, "stderr.txt");
        defer stderr.close();
        var inherit = kernel.SECURITY_ATTRIBUTES{
            .nLength = @sizeOf(kernel.SECURITY_ATTRIBUTES),
            .lpSecurityDescriptor = null,
            .bInheritHandle = kernel.TRUE,
        };
        const stdin = kernel.kernel32.CreateFileW(
            windows.wide("NUL"),
            kernel.GENERIC_READ,
            kernel.FILE_SHARE_READ | kernel.FILE_SHARE_WRITE,
            &inherit,
            kernel.OPEN_EXISTING,
            0,
            null,
        );
        if (stdin == kernel.INVALID_HANDLE_VALUE) return error.OpenNullInput;
        defer kernel.CloseHandle(stdin);

        const job = win.CreateJobObjectW(null, null) orelse return error.CreateStartupJob;
        errdefer kernel.CloseHandle(job);
        var limits = std.mem.zeroes(win.JOBOBJECT_EXTENDED_LIMIT_INFORMATION);
        limits.BasicLimitInformation.LimitFlags = win.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        if (win.SetInformationJobObject(job, win.JobObjectExtendedLimitInformation, &limits, @sizeOf(@TypeOf(limits))) == 0)
            return error.ConfigureStartupJob;
        var startup = std.mem.zeroes(kernel.STARTUPINFOW);
        startup.cb = @sizeOf(kernel.STARTUPINFOW);
        startup.dwFlags = kernel.STARTF_USESTDHANDLES;
        startup.hStdInput = stdin;
        startup.hStdOutput = stdout.handle;
        startup.hStdError = stderr.handle;
        var info: kernel.PROCESS_INFORMATION = undefined;
        const timer = try std.time.Timer.start();
        try kernel.CreateProcessW(exe, command, null, null, kernel.TRUE, .{
            .create_suspended = true,
            .create_no_window = true,
        }, null, cwd, &startup, &info);
        defer kernel.CloseHandle(info.hThread);
        errdefer {
            kernel.TerminateProcess(info.hProcess, 125) catch {};
            kernel.WaitForSingleObject(info.hProcess, 5000) catch {};
            kernel.CloseHandle(info.hProcess);
        }
        trial.pid = info.dwProcessId;
        if (win.AssignProcessToJobObject(job, info.hProcess) == 0) return error.AssignStartupJob;
        if (win.ResumeThread(info.hThread) == std.math.maxInt(u32)) return error.ResumeStartupProcess;
        return .{
            .handle = info.hProcess,
            .pid = info.dwProcessId,
            .job = job,
            .output = output,
            .timer = timer,
            .trial = trial,
        };
    }

    fn deinit(self: *Child) void {
        reapJob(self.job) catch |failure| {
            self.trial.cleanup_error = @errorName(failure);
        };
        kernel.CloseHandle(self.job);
        if (self.trial.exit_code == null) {
            self.collect(5000) catch |failure| {
                if (self.trial.cleanup_error == null) self.trial.cleanup_error = @errorName(failure);
            };
        }
        kernel.CloseHandle(self.handle);
        self.output.close();
    }

    fn collect(self: *Child, timeout_ms: u32) !void {
        kernel.WaitForSingleObject(self.handle, timeout_ms) catch |failure| {
            if (failure == error.WaitTimeOut) self.trial.timed_out = true;
            return failure;
        };
        var exit_code: u32 = undefined;
        if (kernel.kernel32.GetExitCodeProcess(self.handle, &exit_code) == 0) return error.ReadStartupExitCode;
        self.trial.exit_code = exit_code;
        self.trial.elapsed_ms = self.timer.read() / std.time.ns_per_ms;
        self.trial.stdout_bytes = (try self.output.statFile("stdout.txt")).size;
        self.trial.stderr_bytes = (try self.output.statFile("stderr.txt")).size;
    }

    fn expectExit(self: *Child, exit_code: u32, stderr: []const u8) !void {
        try self.collect(deadline_ms);
        if (self.trial.exit_code.? != exit_code) return error.UnexpectedStartupExitCode;
        if (self.trial.stdout_bytes.? != 0) return error.UnexpectedStartupStdout;
        if (stderr.len == 0) {
            if (self.trial.stderr_bytes.? != 0) return error.UnexpectedStartupStderr;
        } else {
            const message = try self.output.readFileAlloc(allocator, "stderr.txt", 64 * 1024);
            defer allocator.free(message);
            if (std.mem.indexOf(u8, message, stderr) == null) return error.MissingStartupStderr;
        }
    }

    fn ownedHost(self: Child, folder: Folder) !win.HWND {
        const host = folder.host() orelse return error.QuietHostNotFound;
        var pid: win.DWORD = 0;
        if (win.GetWindowThreadProcessId(host, &pid) == 0 or pid != self.pid)
            return error.HostNotOwnedByStartupProcess;
        kernel.WaitForSingleObject(self.handle, 0) catch |failure| {
            if (failure == error.WaitTimeOut) return host;
            return failure;
        };
        return error.QuietProcessExitedEarly;
    }

    fn waitHost(self: *Child, folder: Folder) !win.HWND {
        while (self.timer.read() < deadline_ms * std.time.ns_per_ms) {
            kernel.WaitForSingleObject(self.handle, 0) catch |failure| {
                if (failure != error.WaitTimeOut) return failure;
                if (folder.host() != null) {
                    const host = try self.ownedHost(folder);
                    self.trial.ready_ms = self.timer.read() / std.time.ns_per_ms;
                    return host;
                }
                std.Thread.sleep(20 * std.time.ns_per_ms);
                continue;
            };
            return error.QuietProcessExitedEarly;
        }
        self.trial.timed_out = true;
        return error.QuietReadinessTimedOut;
    }
};

fn activeProcesses(job: kernel.HANDLE) !u32 {
    var info: win.JOBOBJECT_BASIC_ACCOUNTING_INFORMATION = undefined;
    if (win.QueryInformationJobObject(job, win.JobObjectBasicAccountingInformation, &info, @sizeOf(@TypeOf(info)), null) == 0)
        return error.QueryStartupJob;
    return info.ActiveProcesses;
}

fn reapJob(job: kernel.HANDLE) !void {
    if (try activeProcesses(job) == 0) return;
    if (win.TerminateJobObject(job, 124) == 0) return error.TerminateStartupJob;
    var timer = try std.time.Timer.start();
    while (try activeProcesses(job) != 0) {
        if (timer.read() >= 5000 * std.time.ns_per_ms) return error.StartupJobDidNotExit;
        std.Thread.sleep(20 * std.time.ns_per_ms);
    }
}

fn capturedFile(dir: std.fs.Dir, path: []const u8) !std.fs.File {
    const file = try dir.createFile(path, .{ .exclusive = true, .read = true });
    errdefer file.close();
    try kernel.SetHandleInformation(file.handle, kernel.HANDLE_FLAG_INHERIT, kernel.HANDLE_FLAG_INHERIT);
    return file;
}
