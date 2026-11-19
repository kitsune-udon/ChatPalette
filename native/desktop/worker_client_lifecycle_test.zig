const std = @import("std");
const transport = @import("worker_client.zig");
const win = @import("win.zig").api;
const Probe = transport.LifecycleProbe;
const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;
const Digest = [Sha256.digest_length]u8;
const HexDigest = [Sha256.digest_length * 2]u8;

const Candidate = struct {
    launch: transport.Launch,
    digest: Digest,
};

const Report = struct {
    passed: bool = false,
    failure: ?[]const u8 = null,
    executable_sha256: ?HexDigest = null,
    executable_sha256_after: ?HexDigest = null,
    acquisition_failures_checked: usize = 0,
    missing_pipe_exit: ?u32 = null,
    missing_event_exit: ?u32 = null,
    startup_failure: ?[]const u8 = null,
    failed_start_sequence: ?u64 = null,
    first_worker_pid: ?u32 = null,
    replacement_worker_pid: ?u32 = null,
    stopped_worker_exit: ?u32 = null,
    restart_cleanup: ?[]const u8 = null,
    oversized_request_cause: ?[]const u8 = null,
    oversized_request_cleanup: ?[]const u8 = null,
    timeout_cause: ?[]const u8 = null,
    timeout_cleanup: ?[]const u8 = null,
    timeout_ms: ?u64 = null,
    timeout_tick_count_ms: ?u64 = null,
    timeout_request_count: ?u64 = null,
    timeout_write_attempted: ?bool = null,
    in_flight_cause: ?[]const u8 = null,
    in_flight_cleanup: ?[]const u8 = null,
    recovery_sequence: ?u64 = null,
    registration_rejected_without_publication: bool = false,
    registration_recovered_on_same_process: bool = false,
    registration_reapplied_after_restart: bool = false,
    no_data_directory: bool = false,
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const args = try std.process.argsAlloc(alloc);
    if (args.len == 4 and std.mem.eql(u8, args[2], "-PipeName")) {
        if (std.mem.eql(u8, args[1], "--fixture-stall")) return fixture(alloc, args[3], false);
        if (std.mem.eql(u8, args[1], "--fixture-crash")) return fixture(alloc, args[3], true);
    }
    if (args.len != 3) return error.ExpectedApplicationAndNewResultsDirectory;
    const application = try std.fs.cwd().realpathAlloc(alloc, args[1]);
    const local = try std.fs.selfExePathAlloc(alloc);
    try std.fs.cwd().makeDir(args[2]);
    const work = try std.fs.cwd().realpathAlloc(alloc, args[2]);
    var result_dir = try std.fs.cwd().openDir(work, .{ .no_follow = true });
    defer result_dir.close();
    const cwd_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, work);
    const launch: transport.Launch = .{
        .executable = try std.unicode.utf8ToUtf16LeAllocZ(alloc, application),
        .working_directory = cwd_w,
    };
    const application_file = try lockImage(launch.executable);
    defer application_file.close();
    const candidate = Candidate{ .launch = launch, .digest = try imageDigest(application_file) };
    const fixture_executable: transport.Launch = .{
        .executable = try std.unicode.utf8ToUtf16LeAllocZ(alloc, local),
        .working_directory = cwd_w,
    };
    const missing: transport.Launch = .{
        .executable = try std.unicode.utf8ToUtf16LeAllocZ(alloc, try std.fs.path.join(alloc, &.{ work, "absent-worker.exe" })),
        .working_directory = cwd_w,
    };

    var report: Report = .{ .executable_sha256 = std.fmt.bytesToHex(candidate.digest, .lower) };
    verify(alloc, result_dir, candidate, fixture_executable, missing, &report) catch |failure| {
        report.failure = @errorName(failure);
    };
    if (imageDigest(application_file)) |after| {
        report.executable_sha256_after = std.fmt.bytesToHex(after, .lower);
        if (!std.mem.eql(u8, &candidate.digest, &after) and report.failure == null) report.failure = "ProductWorkerImageChanged";
    } else |failure| {
        if (report.failure == null) report.failure = @errorName(failure);
    }
    report.passed = report.failure == null;
    const json = try std.json.Stringify.valueAlloc(alloc, report, .{ .whitespace = .indent_2 });
    const output = try result_dir.createFile("result.json", .{ .exclusive = true });
    defer output.close();
    try output.writeAll(json);
    try output.sync();
    if (!report.passed) return error.WorkerLifecycleChecksFailed;
}

fn verify(
    alloc: Allocator,
    directory: std.fs.Dir,
    candidate: Candidate,
    fixture_executable: transport.Launch,
    missing: transport.Launch,
    report: *Report,
) !void {
    for (std.meta.tags(Probe.Acquisition)) |point| {
        try Probe.checkAcquisition(alloc, missing, point);
        report.acquisition_failures_checked += 1;
    }
    report.missing_pipe_exit = try Probe.checkMissingEndpoint(alloc, candidate.launch, .pipe);
    report.missing_event_exit = try Probe.checkMissingEndpoint(alloc, candidate.launch, .ready_event);

    var client: transport.Client = .{};
    defer client.stop() catch {};
    const initial = (try captureFailure(client.requestWithLaunch(alloc, missing, true, .browser_context, 0, "", &.{}, pump))).cause;
    if (initial != error.StartWorker or client.sequence != 0 or client.cleanup_failure != null or client.request_may_have_arrived)
        return error.WorkerLaunchFailureDidNotReleaseRequest;
    try emptyClient(client);
    report.startup_failure = @errorName(initial);
    report.failed_start_sequence = client.sequence;

    const first = try request(&client, alloc, candidate);
    report.first_worker_pid = first;
    try checkRegistrationRecovery(&client, alloc, candidate, first, report);
    const old = Owned.capture(client);
    const old_sequence = client.sequence;
    if (win.TerminateProcess(old.process, 31) == 0 or win.WaitForSingleObject(old.process, 2000) != win.WAIT_OBJECT_0)
        return error.FixtureCouldNotExitOwnedWorker;
    if (client.registrationsReady()) return error.ExitedWorkerAppearedRegistered;
    const denied = (try captureFailure(client.requestWithLaunch(alloc, candidate.launch, false, .browser_context, 0, "", &.{}, pump))).cause;
    if (denied != error.WorkerExited or client.sequence != old_sequence or client.process != old.process)
        return error.ContinuationReplayedExitedWorker;
    const restart = (try captureFailure(Probe.requestWithUnconfirmedExit(&client, alloc, candidate.launch, .browser_context, &.{}, pump))).cause;
    if (restart != error.WorkerDidNotExit or client.sequence != old_sequence or client.process != old.process or client.request_may_have_arrived)
        return error.RestartLostUnconfirmedOwnership;
    try old.requireHalfClosed(client);
    report.restart_cleanup = @errorName(restart);
    try client.stop();
    try old.requireClosed();

    const replacement = try request(&client, alloc, candidate);
    if (replacement == first or client.sequence != old_sequence + 1 or client.registrations_current)
        return error.RestartReusedProcessOrRegistrations;
    report.replacement_worker_pid = replacement;
    try configureRegistration(&client, alloc, candidate, replacement);
    report.registration_reapplied_after_restart = true;
    try checkOversizedFrame(&client, alloc, candidate, report);
    _ = try request(&client, alloc, candidate);
    report.stopped_worker_exit = try checkDisconnect(&client);

    var stall = fixture_executable;
    stall.arguments_before_pipe = "--fixture-stall";
    const before_stall = client.sequence;
    var timer = try std.time.Timer.start();
    const ticks_before = win.GetTickCount64();
    const deadline = (try captureFailure(Probe.requestWithUnconfirmedExit(&client, alloc, stall, .verify_input, &.{}, pump))).cause;
    const elapsed_ms = timer.read() / std.time.ns_per_ms;
    report.timeout_cause = @errorName(deadline);
    report.timeout_cleanup = if (client.cleanup_failure) |failure| @errorName(failure) else null;
    report.timeout_ms = elapsed_ms;
    report.timeout_tick_count_ms = win.GetTickCount64() - ticks_before;
    report.timeout_request_count = client.sequence - before_stall;
    report.timeout_write_attempted = client.request_may_have_arrived;
    if (deadline != error.WorkerTimeout or elapsed_ms < transport.Mode.verify_input.deadlineMs() or client.sequence != before_stall + 1 or !client.request_may_have_arrived)
        return error.FixtureFailedToProveSingleRequestDeadline;
    try requireFailedWait(client);
    try confirmSingleFixtureRequest(directory, "stall-received.txt");
    const stalled = client.process;
    try client.stop();
    try requireInvalid(stalled);

    var crash = fixture_executable;
    crash.arguments_before_pipe = "--fixture-crash";
    const before_crash = client.sequence;
    const in_flight = (try captureFailure(Probe.requestWithUnconfirmedExit(&client, alloc, crash, .verify_input, &.{}, pump))).cause;
    if ((in_flight != error.WorkerExited and in_flight != error.WorkerPipeClosed) or client.sequence != before_crash + 1 or !client.request_may_have_arrived)
        return error.FixtureFailedToProveSingleInFlightFailure;
    try requireFailedWait(client);
    try confirmSingleFixtureRequest(directory, "crash-received.txt");
    report.in_flight_cause = @errorName(in_flight);
    report.in_flight_cleanup = @errorName(client.cleanup_failure.?);
    const stopped = client.process;
    try client.stop();
    try requireInvalid(stopped);

    _ = try request(&client, alloc, candidate);
    report.recovery_sequence = client.sequence;
    try client.stop();
    try client.stop();
    try emptyClient(client);
    if (directory.access("data", .{})) |_| {
        return error.WorkerModeCreatedUserData;
    } else |failure| if (failure != error.FileNotFound) {
        return failure;
    }
    report.no_data_directory = true;
}

fn checkRegistrationRecovery(client: *transport.Client, alloc: Allocator, candidate: Candidate, pid: u32, report: *Report) !void {
    const prior_sequence = client.sequence;
    const invalid = try client.requestWithLaunch(alloc, candidate.launch, false, .reaction_configure, 0, "", &.{.{
        .name = "Payload",
        .value = "{\"version\":2,\"profiles\":[]}",
    }}, pump);
    defer invalid.deinit();
    if (!invalid.is("unavailable") or !std.mem.eql(u8, invalid.field("Detail"), "InvalidRegistrationSnapshot")) return error.WorkerAcceptedInvalidRegistration;
    client.acceptRegistrationReply(invalid) catch |failure| {
        if (failure != error.WorkerRegistrationSyncFailed or client.registrationsReady() or client.sequence != prior_sequence + 1 or
            win.GetProcessId(client.process) != pid) return error.WorkerPublishedRejectedRegistration;
        report.registration_rejected_without_publication = true;
    };
    if (!report.registration_rejected_without_publication) return error.WorkerPublishedRejectedRegistration;
    try configureRegistration(client, alloc, candidate, pid);
    report.registration_recovered_on_same_process = true;
}

fn configureRegistration(client: *transport.Client, alloc: Allocator, candidate: Candidate, pid: u32) !void {
    const payload =
        \\{"version":1,"profiles":[{"browser":"brave","tokens":[{"name":"Heart","id":"heart","class":"btn","type":50000},{"name":"Smile","id":"smile","class":"btn","type":50000},{"name":"Party","id":"party","class":"btn","type":50000},{"name":"Surprise","id":"surprise","class":"btn","type":50000},{"name":"100 points","id":"100","class":"btn","type":50000}]}]}
    ;
    const prior_sequence = client.sequence;
    const reply = try client.requestWithLaunch(alloc, candidate.launch, false, .reaction_configure, 0, "", &.{.{ .name = "Payload", .value = payload }}, pump);
    defer reply.deinit();
    try client.acceptRegistrationReply(reply);
    if (!client.registrationsReady() or client.sequence != prior_sequence + 1 or win.GetProcessId(client.process) != pid)
        return error.WorkerRegistrationDidNotRecover;
}

fn checkOversizedFrame(client: *transport.Client, alloc: Allocator, candidate: Candidate, report: *Report) !void {
    const oversized = [_]u8{'x'} ** 32768;
    const fields = &.{transport.Field{ .name = "Payload", .value = &oversized }};
    const owned = Owned.capture(client.*);
    const before = client.sequence;
    const failure = (try captureFailure(Probe.requestWithUnconfirmedExit(client, alloc, candidate.launch, .verify_input, fields, pump))).cause;
    if (failure != error.InvalidWorkerRequestSize or client.sequence != before + 1 or client.request_may_have_arrived) return error.WorkerFrameFailureLost;
    try requireFailedWait(client.*);
    try owned.requireHalfClosed(client.*);
    report.oversized_request_cause = @errorName(failure);
    report.oversized_request_cleanup = @errorName(client.cleanup_failure.?);
    try client.stop();
    try owned.requireClosed();

    _ = try request(client, alloc, candidate);
    const normal = Owned.capture(client.*);
    const rejected = (try captureFailure(client.requestWithLaunch(alloc, candidate.launch, true, .verify_input, 0, "", fields, pump))).cause;
    if (rejected != error.InvalidWorkerRequestSize or client.cleanup_failure != null) return error.NormalFrameCleanupFailed;
    try emptyClient(client.*);
    try normal.requireClosed();
}

const Owned = struct {
    pipe: win.HANDLE,
    signal: win.HANDLE,
    process: win.HANDLE,

    fn capture(client: transport.Client) Owned {
        return .{ .pipe = client.pipe, .signal = client.signal, .process = client.process };
    }

    fn requireHalfClosed(self: Owned, client: transport.Client) !void {
        if (client.pipe != null or client.signal != null or client.process != self.process or client.active)
            return error.WorkerRetainedWrongResources;
        try requireInvalid(self.pipe);
        try requireInvalid(self.signal);
        var flags: win.DWORD = 0;
        if (win.GetHandleInformation(self.process, &flags) == 0) return error.UnconfirmedProcessOwnershipWasLost;
    }

    fn requireClosed(self: Owned) !void {
        try requireInvalid(self.pipe);
        try requireInvalid(self.signal);
        try requireInvalid(self.process);
    }
};

fn checkDisconnect(client: *transport.Client) !u32 {
    const owned = Owned.capture(client.*);
    const pid = win.GetProcessId(owned.process);
    const monitor = win.OpenProcess(win.SYNCHRONIZE | win.PROCESS_QUERY_LIMITED_INFORMATION, 0, pid) orelse
        return error.CouldNotObserveOwnedWorkerExit;
    defer _ = win.CloseHandle(monitor);
    try client.stop();
    try owned.requireClosed();
    if (win.WaitForSingleObject(monitor, 0) != win.WAIT_OBJECT_0) return error.DisconnectedWorkerStayedLive;
    var exit: win.DWORD = 0;
    if (win.GetExitCodeProcess(monitor, &exit) == 0 or exit != 1) return error.UnexpectedDisconnectExit;
    return exit;
}

fn requireFailedWait(client: transport.Client) !void {
    const cleanup = client.cleanup_failure orelse return error.WorkerCleanupFailureLost;
    if (cleanup != error.WorkerDidNotExit or client.active or client.pipe != null or client.signal != null or
        client.process == null or client.registrations_current) return error.WorkerCleanupFailureLost;
}

fn emptyClient(client: transport.Client) !void {
    if (client.active or client.pipe != null or client.signal != null or client.process != null or
        client.registrations_current) return error.WorkerStillOwnedResources;
}

fn requireInvalid(handle: win.HANDLE) !void {
    var flags: win.DWORD = 0;
    if (handle == null or win.GetHandleInformation(handle, &flags) != 0 or win.GetLastError() != win.ERROR_INVALID_HANDLE)
        return error.WorkerHandleWasNotReleased;
}

fn confirmSingleFixtureRequest(directory: std.fs.Dir, name: []const u8) !void {
    var buf: [32]u8 = undefined;
    const contents = try directory.readFile(name, &buf);
    if (!std.mem.eql(u8, contents, "received\n")) return error.FixtureObservedWrongRequestCount;
}

fn request(client: *transport.Client, alloc: Allocator, candidate: Candidate) !u32 {
    const reply = try client.requestWithLaunch(alloc, candidate.launch, true, .browser_context, 0, "", &.{}, pump);
    defer reply.deinit();
    if (!reply.is("unavailable") or client.active) return error.UnexpectedLocalWorkerReply;
    const identity = win.GetProcessId(client.process);
    if (identity == 0) return error.WorkerProcessIdentityUnavailable;
    var image: [32768:0]u16 = undefined;
    var length: win.DWORD = image.len;
    if (win.QueryFullProcessImageNameW(client.process, 0, &image, &length) == 0 or length >= image.len) return error.WorkerProcessImageUnavailable;
    image[length] = 0;
    if (!std.os.windows.eqlIgnoreCaseWTF16(candidate.launch.executable, image[0..length])) return error.UnexpectedWorkerProcessImage;
    const actual = try lockImage(image[0..length :0]);
    defer actual.close();
    const observed = try imageDigest(actual);
    if (!std.mem.eql(u8, &observed, &candidate.digest)) return error.WorkerProcessImageDigestMismatch;
    return identity;
}

fn lockImage(path: [:0]const u16) !std.fs.File {
    const handle = win.CreateFileW(path, win.GENERIC_READ, win.FILE_SHARE_READ, null, win.OPEN_EXISTING, 0, null) orelse
        return error.WorkerImageLockFailed;
    if (handle == std.os.windows.INVALID_HANDLE_VALUE) return error.WorkerImageLockFailed;
    return .{ .handle = handle };
}

fn imageDigest(file: std.fs.File) !Digest {
    try file.seekTo(0);
    var sha = Sha256.init(.{});
    var buffer: [64 * 1024]u8 = undefined;
    while (true) {
        const count = try file.read(&buffer);
        if (count == 0) break;
        sha.update(buffer[0..count]);
    }
    return sha.finalResult();
}

fn captureFailure(reply: anyerror!transport.Reply) !struct { cause: anyerror } {
    if (reply) |success| {
        success.deinit();
        return error.WorkerOperationUnexpectedlySucceeded;
    } else |failure| return .{ .cause = failure };
}

fn pump(signal: win.HANDLE, milliseconds: u32) !void {
    switch (win.WaitForSingleObject(signal, milliseconds)) {
        win.WAIT_OBJECT_0, win.WAIT_TIMEOUT => {},
        else => return error.WorkerSignalWaitFailed,
    }
}

fn fixture(alloc: Allocator, name: []const u8, crash: bool) !void {
    const pipe_path = try std.fmt.allocPrint(alloc, "\\\\.\\pipe\\{s}", .{name});
    const pipe_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, pipe_path);
    const handle = win.CreateFileW(pipe_w, win.GENERIC_READ | win.GENERIC_WRITE, 0, null, win.OPEN_EXISTING, 0, null) orelse
        return error.FixtureFailedToOpenPipe;
    if (handle == std.os.windows.INVALID_HANDLE_VALUE) return error.FixtureFailedToOpenPipe;
    const pipe = std.fs.File{ .handle = handle };
    defer pipe.close();
    const ready_path = try std.fmt.allocPrint(alloc, "{s}-ready", .{name});
    const ready_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, ready_path);
    const signal = win.OpenEventW(win.EVENT_MODIFY_STATE, 0, ready_w) orelse return error.FixtureFailedToOpenReadyEvent;
    defer _ = win.CloseHandle(signal);
    if (win.SetEvent(signal) == 0) return error.FixtureCouldNotSignal;
    var header: [4]u8 = undefined;
    if (try pipe.readAll(&header) != header.len) return error.FixtureRequestMissing;
    const size = std.mem.readInt(u32, &header, .little);
    var body: [32768]u8 = undefined;
    if (size == 0 or size > body.len or try pipe.readAll(body[0..size]) != size) return error.FixtureInvalidRequest;
    const marker = try std.fs.cwd().createFile(if (crash) "crash-received.txt" else "stall-received.txt", .{ .exclusive = true });
    try marker.writeAll("received\n");
    try marker.sync();
    marker.close();
    if (crash) return error.FixtureInFlightExit;
    var extra: [1]u8 = undefined;
    if ((pipe.read(&extra) catch return) != 0) return error.RetryReachedStalledFixture;
}
