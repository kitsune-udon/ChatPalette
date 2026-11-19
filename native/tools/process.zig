const std = @import("std");
const files = @import("files.zig");
const win = std.os.windows;

extern "kernel32" fn CreateJobObjectW(?*win.SECURITY_ATTRIBUTES, ?win.LPCWSTR) callconv(.winapi) ?win.HANDLE;
extern "kernel32" fn SetInformationJobObject(win.HANDLE, u32, *const anyopaque, u32) callconv(.winapi) win.BOOL;
extern "kernel32" fn QueryInformationJobObject(win.HANDLE, u32, *anyopaque, u32, ?*u32) callconv(.winapi) win.BOOL;
extern "kernel32" fn AssignProcessToJobObject(win.HANDLE, win.HANDLE) callconv(.winapi) win.BOOL;
extern "kernel32" fn TerminateJobObject(win.HANDLE, u32) callconv(.winapi) win.BOOL;
extern "kernel32" fn ResumeThread(win.HANDLE) callconv(.winapi) u32;

const ExtendedLimits = extern struct {
    process_user_time: i64,
    job_user_time: i64,
    limit_flags: u32,
    min_working_set: usize,
    max_working_set: usize,
    active_process_limit: u32,
    affinity: usize,
    priority: u32,
    scheduling: u32,
    io_counters: [6]u64,
    process_memory_limit: usize,
    job_memory_limit: usize,
    peak_process_memory: usize,
    peak_job_memory: usize,
};

const Accounting = extern struct {
    user_time: i64,
    kernel_time: i64,
    period_user_time: i64,
    period_kernel_time: i64,
    page_fault_count: u32,
    total_processes: u32,
    active_processes: u32,
    terminated_processes: u32,
};

pub const Result = struct {
    exit_code: u32,
    timed_out: bool,
    stderr_bytes: u64,
    elapsed_ms: u64,

    pub fn passed(self: Result) bool {
        return self.exit_code == 0 and !self.timed_out and self.stderr_bytes == 0;
    }
};

pub const Observation = struct {
    result: ?Result = null,
    failure: ?anyerror = null,
    cleanup_failure: ?anyerror = null,
};

pub fn commandLine(allocator: std.mem.Allocator, argv: []const []const u8) ![:0]u16 {
    var buf = std.Io.Writer.Allocating.init(allocator);
    defer buf.deinit();
    for (argv, 0..) |word, index| {
        if (index != 0) try buf.writer.writeByte(' ');
        try buf.writer.writeByte('"');
        var backslashes: usize = 0;
        for (word) |ch| {
            if (ch == 0) return error.InvalidProcessArgument;
            if (ch == '\\') {
                backslashes += 1;
                continue;
            }
            if (ch == '"') backslashes = backslashes * 2 + 1;
            try buf.writer.splatByteAll('\\', backslashes);
            backslashes = 0;
            try buf.writer.writeByte(ch);
        }
        try buf.writer.splatByteAll('\\', backslashes * 2);
        try buf.writer.writeByte('"');
    }
    return std.unicode.utf8ToUtf16LeAllocZ(allocator, buf.written());
}

fn jobCount(job: win.HANDLE) !u32 {
    var account: Accounting = undefined;
    if (QueryInformationJobObject(job, 1, &account, @sizeOf(Accounting), null) == 0) {
        return error.CouldNotQueryTestJob;
    }
    return account.active_processes;
}

fn stopJob(job: win.HANDLE) !void {
    if (try jobCount(job) == 0) return;
    if (TerminateJobObject(job, 124) == 0) return error.CouldNotTerminateTestJob;
    var timer = try std.time.Timer.start();
    while (try jobCount(job) != 0) {
        if (timer.read() >= 5000 * std.time.ns_per_ms) return error.TestJobDidNotExit;
        std.Thread.sleep(20 * std.time.ns_per_ms);
    }
}

fn newKillOnCloseJob() !win.HANDLE {
    const job = CreateJobObjectW(null, null) orelse return error.CouldNotCreateTestJob;
    errdefer win.CloseHandle(job);
    var limits = std.mem.zeroes(ExtendedLimits);
    limits.limit_flags = 0x2000; // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
    if (SetInformationJobObject(job, 9, &limits, @sizeOf(ExtendedLimits)) == 0)
        return error.CouldNotSetTestJobLimits;
    return job;
}

pub const SandboxConnector = struct {
    handle: win.HANDLE,
    job: win.HANDLE,

    pub fn start(alloc: std.mem.Allocator, argv: []const []const u8) !SandboxConnector {
        const job = try newKillOnCloseJob();
        errdefer win.CloseHandle(job);
        var child = std.process.Child.init(argv, alloc);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
        child.start_suspended = true;
        try child.spawn();
        defer win.CloseHandle(child.thread_handle);
        errdefer {
            cleanupUnassigned(child.id) catch |err| std.debug.print("Sandbox接続プロセスの後始末 {s}\n", .{@errorName(err)});
            win.CloseHandle(child.id);
        }
        if (AssignProcessToJobObject(job, child.id) == 0) return error.CouldNotAssignSandboxConnector;
        if (ResumeThread(child.thread_handle) == std.math.maxInt(u32)) return error.CouldNotResumeSandboxConnector;
        return .{ .handle = child.id, .job = job };
    }

    pub fn stop(self: SandboxConnector) !void {
        try stopJob(self.job);
    }

    pub fn close(self: SandboxConnector) void {
        win.CloseHandle(self.job);
        win.CloseHandle(self.handle);
    }
};

fn nullInput() !win.HANDLE {
    var attributes = win.SECURITY_ATTRIBUTES{
        .nLength = @sizeOf(win.SECURITY_ATTRIBUTES),
        .lpSecurityDescriptor = null,
        .bInheritHandle = win.TRUE,
    };
    const handle = win.kernel32.CreateFileW(
        std.unicode.utf8ToUtf16LeStringLiteral("NUL"),
        win.GENERIC_READ,
        win.FILE_SHARE_READ | win.FILE_SHARE_WRITE,
        &attributes,
        win.OPEN_EXISTING,
        0,
        null,
    );
    if (handle == win.INVALID_HANDLE_VALUE) return error.CouldNotOpenNullInput;
    return handle;
}

/// Run a test in a new Job Object. The child thread starts only after assignment so its
/// descendants cannot escape the deadline and cleanup between spawn and assignment.
pub fn run(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    cwd: []const u8,
    output: std.fs.Dir,
    timeout_ms: u32,
) !Result {
    return requireResult(observe(allocator, argv, cwd, output, timeout_ms));
}

/// App Execution Aliases are Windows reparse points and are resolved by CreateProcessW.
pub fn runAppExecutionAlias(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    cwd: []const u8,
    output: std.fs.Dir,
    timeout_ms: u32,
) !Result {
    return requireResult(observeWithStop(allocator, argv, cwd, output, timeout_ms, .app_execution_alias, stopJob));
}

/// The Sandbox broker can be started by the CLI and must outlive that command.
pub fn runSandboxStart(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    cwd: []const u8,
    output: std.fs.Dir,
    timeout_ms: u32,
) !Result {
    return requireResult(observeWithStop(allocator, argv, cwd, output, timeout_ms, .sandbox_start, stopJob));
}

fn requireResult(observation: Observation) !Result {
    if (observation.failure) |failure| {
        if (observation.cleanup_failure) |cleanup| {
            std.debug.print("子プロセスの後始末 {s}\n", .{@errorName(cleanup)});
        }
        return failure;
    }
    if (observation.cleanup_failure) |failure| return failure;
    return observation.result.?;
}

pub fn observe(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    cwd: []const u8,
    output: std.fs.Dir,
    timeout_ms: u32,
) Observation {
    return observeWithStop(allocator, argv, cwd, output, timeout_ms, .canonical, stopJob);
}

const Stop = *const fn (win.HANDLE) anyerror!void;
const ImagePath = enum { canonical, app_execution_alias, sandbox_start };

fn observeWithStop(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    cwd: []const u8,
    output: std.fs.Dir,
    timeout_ms: u32,
    image_path: ImagePath,
    stop: Stop,
) Observation {
    var observation: Observation = .{};
    observation.result = execute(allocator, argv, cwd, output, timeout_ms, image_path, stop, &observation.cleanup_failure) catch |failure| {
        observation.failure = failure;
        return observation;
    };
    return observation;
}

fn cleanupUnassigned(handle: win.HANDLE) !void {
    try win.TerminateProcess(handle, 125);
    try win.WaitForSingleObject(handle, 5000);
}

fn execute(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    cwd: []const u8,
    output: std.fs.Dir,
    timeout_ms: u32,
    image_path: ImagePath,
    stop: Stop,
    cleanup_failure: *?anyerror,
) !Result {
    if (argv.len == 0 or timeout_ms == 0 or timeout_ms == win.INFINITE) return error.InvalidProcessArgument;
    const exe = switch (image_path) {
        .canonical => try std.fs.cwd().realpathAlloc(allocator, argv[0]),
        .app_execution_alias, .sandbox_start => if (std.fs.path.isAbsolute(argv[0])) argv[0] else return error.ExpectedAbsoluteAppExecutionAlias,
    };
    defer if (image_path == .canonical) allocator.free(exe);
    if (!std.ascii.eqlIgnoreCase(std.fs.path.extension(exe), ".exe")) return error.ExpectedExecutable;
    const exe_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, exe);
    defer allocator.free(exe_w);
    const cwd_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, cwd);
    defer allocator.free(cwd_w);
    const command = try commandLine(allocator, argv);
    defer allocator.free(command);

    const stdout = try output.createFile("stdout.txt", .{ .exclusive = true, .read = true });
    defer stdout.close();
    try win.SetHandleInformation(stdout.handle, win.HANDLE_FLAG_INHERIT, win.HANDLE_FLAG_INHERIT);
    const stderr = try output.createFile("stderr.txt", .{ .exclusive = true, .read = true });
    defer stderr.close();
    try win.SetHandleInformation(stderr.handle, win.HANDLE_FLAG_INHERIT, win.HANDLE_FLAG_INHERIT);
    const stdin = try nullInput();
    defer win.CloseHandle(stdin);

    const job: ?win.HANDLE = if (image_path == .sandbox_start) null else try newKillOnCloseJob();
    defer if (job) |handle| win.CloseHandle(handle);

    var startup = std.mem.zeroes(win.STARTUPINFOW);
    startup.cb = @sizeOf(win.STARTUPINFOW);
    startup.dwFlags = win.STARTF_USESTDHANDLES;
    startup.hStdInput = stdin;
    startup.hStdOutput = stdout.handle;
    startup.hStdError = stderr.handle;
    var info: win.PROCESS_INFORMATION = undefined;
    var timer = try std.time.Timer.start();
    try win.CreateProcessW(exe_w.ptr, command.ptr, null, null, win.TRUE, .{
        .create_suspended = true,
        .create_no_window = true,
    }, null, cwd_w.ptr, &startup, &info);
    defer win.CloseHandle(info.hThread);
    defer win.CloseHandle(info.hProcess);
    var assigned = false;
    var stop_attempted = false;
    defer if (!stop_attempted) {
        const cleanup = if (assigned) stop(job.?) else cleanupUnassigned(info.hProcess);
        cleanup catch |failure| {
            cleanup_failure.* = failure;
        };
    };

    if (job) |handle| {
        if (AssignProcessToJobObject(handle, info.hProcess) == 0) return error.CouldNotAssignTestJob;
        assigned = true;
    }
    if (ResumeThread(info.hThread) == std.math.maxInt(u32)) return error.CouldNotResumeTest;
    const timed_out = wait: {
        win.WaitForSingleObject(info.hProcess, timeout_ms) catch |err| {
            if (err == error.WaitTimeOut) break :wait true;
            return err;
        };
        break :wait false;
    };
    var exit_code: u32 = 124;
    if (!timed_out and win.kernel32.GetExitCodeProcess(info.hProcess, &exit_code) == 0)
        return error.CouldNotReadTestExitCode;
    stop_attempted = true;
    const cleanup = if (job) |handle| stop(handle) else if (timed_out) cleanupUnassigned(info.hProcess) else {};
    cleanup catch |failure| {
        cleanup_failure.* = failure;
    };
    return .{
        .exit_code = exit_code,
        .timed_out = timed_out,
        .stderr_bytes = try stderr.getEndPos(),
        .elapsed_ms = timer.read() / std.time.ns_per_ms,
    };
}

pub fn saveResult(allocator: std.mem.Allocator, output: []const u8, result: anytype) !void {
    const pending = try std.fs.path.join(allocator, &.{ output, "result.pending.json" });
    defer allocator.free(pending);
    const final = try std.fs.path.join(allocator, &.{ output, "result.json" });
    defer allocator.free(final);
    const bytes = try std.json.Stringify.valueAlloc(allocator, result, .{ .whitespace = .indent_2 });
    defer allocator.free(bytes);
    const cwd = std.fs.cwd();
    const file = try cwd.createFile(pending, .{ .exclusive = true });
    errdefer cwd.deleteFile(pending) catch |err| {
        std.debug.print("Could not remove the incomplete test result at {s}: {s}\n", .{ pending, @errorName(err) });
    };
    {
        defer file.close();
        try file.writeAll(bytes);
        try file.sync();
    }
    try files.publish(allocator, pending, final);
}

test "result publication preserves both a competing final result and another writer's pending file" {
    const alloc = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const path = try temp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(path);

    try files.writeNew(temp.dir, "result.pending.json", "another writer");
    if (saveResult(alloc, path, .{ .passed = false })) |_| {
        return error.ReplacedPendingResult;
    } else |_| {}
    try std.testing.expectEqual(files.digest("another writer"), try files.readDigest(temp.dir, "result.pending.json"));
    try std.testing.expectError(error.FileNotFound, temp.dir.access("result.json", .{}));

    try temp.dir.deleteFile("result.pending.json");
    try files.writeNew(temp.dir, "result.json", "published winner");
    try std.testing.expectError(error.OutputExists, saveResult(alloc, path, .{ .passed = false }));
    try std.testing.expectEqual(files.digest("published winner"), try files.readDigest(temp.dir, "result.json"));
    try std.testing.expectError(error.FileNotFound, temp.dir.access("result.pending.json", .{}));
}
