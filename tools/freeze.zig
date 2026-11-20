const std = @import("std");
const files = @import("files.zig");
const process = @import("process.zig");
const release = @import("release.zig");
const sandbox = @import("sandbox.zig");
const source_check = @import("source_check.zig");
const zip = @import("zip.zig");
const worker_client = @import("chatpalette").worker_client;

const Allocator = std.mem.Allocator;
const compiler_version = "0.15.2";
const compiler_sha256 = "d408dd38eed3e5204af841bcebf70502a4dbbb8399a3a3262be55059370bc018";
const build_timeout_ms = 300_000;
const test_timeout_ms = 180_000;
const max_evidence_file_size = 4 * 1024 * 1024;
const startup_trials = [_]struct { name: []const u8, exit_code: u32, folder: []const u8, must_be_ready: bool = false }{
    .{ .name = "01-invalid-arguments", .exit_code = 1, .folder = "a" },
    .{ .name = "02-worker-mode", .exit_code = 1, .folder = "a", .must_be_ready = true },
    .{ .name = "03-smoke-a", .exit_code = 0, .folder = "a" },
    .{ .name = "04-smoke-b", .exit_code = 0, .folder = "b" },
    .{ .name = "05-quiet-a", .exit_code = 0, .folder = "a", .must_be_ready = true },
    .{ .name = "06-quiet-b", .exit_code = 0, .folder = "b", .must_be_ready = true },
    .{ .name = "07-check-rejection", .exit_code = 1, .folder = "a" },
    .{ .name = "08-smoke-takeover", .exit_code = 0, .folder = "a" },
    .{ .name = "09-corrupt-db-smoke", .exit_code = 1, .folder = "b" },
};

const StartupReport = struct {
    passed: bool,
    failure: ?[]const u8,
    executable_sha256: []const u8,
    database_a_sha256_before: ?[]const u8,
    database_a_sha256_after: ?[]const u8,
    database_b_sha256_before: ?[]const u8,
    database_b_sha256_after: ?[]const u8,
    invalid_database_sha256_before: ?[]const u8,
    invalid_database_sha256_after: ?[]const u8,
    invalid_arguments_leave_no_data: bool,
    worker_leaves_no_data: bool,
    quiet_instances_are_independent: bool,
    rejected_check_leaves_both_hosts_running: bool,
    takeover_leaves_other_host_running: bool,
    trials: []const Trial,

    const Trial = struct {
        name: []const u8,
        folder: []const u8,
        pid: ?u32,
        exit_code: ?u32,
        timed_out: bool,
        ready_ms: ?u64,
        cleanup_error: ?[]const u8,
    };
};

fn validDigest(value: []const u8) bool {
    if (value.len != 64) return false;
    for (value) |byte| if (!std.ascii.isHex(byte)) return false;
    return true;
}

fn unchangedDigest(before: ?[]const u8, after: ?[]const u8) bool {
    const left = before orelse return false;
    const right = after orelse return false;
    return validDigest(left) and std.mem.eql(u8, left, right);
}

fn validateStartup(report: StartupReport, app_sha: files.HexDigest) !void {
    if (!std.mem.eql(u8, report.executable_sha256, &app_sha)) return error.StartupTestExecutableMismatch;
    if (!report.passed or report.failure != null or !report.invalid_arguments_leave_no_data or
        !report.worker_leaves_no_data or !report.quiet_instances_are_independent or
        !report.rejected_check_leaves_both_hosts_running or !report.takeover_leaves_other_host_running or
        !unchangedDigest(report.database_a_sha256_before, report.database_a_sha256_after) or
        !unchangedDigest(report.database_b_sha256_before, report.database_b_sha256_after) or
        !unchangedDigest(report.invalid_database_sha256_before, report.invalid_database_sha256_after) or
        report.trials.len != startup_trials.len) return error.StartupTestsIncomplete;

    for (report.trials, startup_trials) |trial, expected| {
        if (!std.mem.eql(u8, trial.name, expected.name) or !std.mem.eql(u8, trial.folder, expected.folder) or
            (trial.pid orelse 0) == 0 or (trial.exit_code orelse return error.StartupTestsIncomplete) != expected.exit_code or
            trial.timed_out or trial.cleanup_error != null) return error.StartupTestsIncomplete;
        if (expected.must_be_ready and trial.ready_ms == null) return error.StartupTestsIncomplete;
    }
}

// This is the Zig 0.15.2 terminal runner's non-TTY format. Keep the raw log for audit.
pub fn unitTestNames(alloc: Allocator, log: []const u8) ![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    errdefer names.deinit(alloc);
    var unique: std.StringHashMapUnmanaged(void) = .empty;
    defer unique.deinit(alloc);
    var total: usize = 0;
    var summary = false;
    var awaiting_ok = false;
    var lines = std.mem.splitScalar(u8, log, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) continue;
        if (summary) return error.InvalidUnitTestLog;
        if (std.mem.startsWith(u8, line, "All ") and std.mem.endsWith(u8, line, " tests passed.")) {
            const count = std.fmt.parseInt(usize, line["All ".len .. line.len - " tests passed.".len], 10) catch
                return error.InvalidUnitTestLog;
            if (awaiting_ok or count == 0 or count != names.items.len or count != total) return error.InvalidUnitTestLog;
            summary = true;
            continue;
        }
        if (awaiting_ok) {
            if (std.mem.eql(u8, line, "OK")) awaiting_ok = false;
            continue;
        }
        const space = std.mem.indexOfScalar(u8, line, ' ') orelse return error.InvalidUnitTestLog;
        const slash = std.mem.indexOfScalar(u8, line[0..space], '/') orelse return error.InvalidUnitTestLog;
        const number = std.fmt.parseInt(usize, line[0..slash], 10) catch return error.InvalidUnitTestLog;
        const size = std.fmt.parseInt(usize, line[slash + 1 .. space], 10) catch return error.InvalidUnitTestLog;
        if (total == 0) total = size;
        if (size != total or number != names.items.len + 1 or number > total) return error.InvalidUnitTestLog;
        const printed = line[space + 1 ..];
        const separator = std.mem.indexOf(u8, printed, "...") orelse return error.InvalidUnitTestLog;
        const name = printed[0..separator];
        const tail = printed[separator + 3 ..];
        if (name.len == 0 or std.mem.startsWith(u8, tail, "SKIP") or std.mem.startsWith(u8, tail, "FAIL"))
            return error.InvalidUnitTestLog;
        const key = try unique.getOrPut(alloc, name);
        if (key.found_existing) return error.InvalidUnitTestLog;
        try names.append(alloc, name);
        awaiting_ok = !std.mem.eql(u8, tail, "OK");
    }
    if (!summary) return error.InvalidUnitTestLog;
    return names.toOwnedSlice(alloc);
}

const LockedExecutable = struct {
    path: []const u8,
    handle: std.fs.File,
    sha: files.Digest,

    fn open(alloc: Allocator, path: []const u8) !LockedExecutable {
        const absolute = try std.fs.cwd().realpathAlloc(alloc, path);
        const file = try files.openImmutable(alloc, absolute);
        errdefer file.close();
        return .{ .path = absolute, .handle = file, .sha = try files.fileDigest(file) };
    }

    fn check(self: LockedExecutable) !void {
        try self.handle.seekTo(0);
        const after = try files.fileDigest(self.handle);
        if (!std.mem.eql(u8, &self.sha, &after)) return error.ExecutableChangedDuringTest;
    }
};

const WorkerLifecycleReport = struct {
    passed: bool,
    executable_sha256: []const u8,
    executable_sha256_after: []const u8,
    acquisition_failures_checked: u32,
    registration_rejected_without_publication: bool,
    registration_recovered_on_same_process: bool,
    registration_reapplied_after_restart: bool,
    no_data_directory: bool,
};

pub fn validateWorkerLifecycle(alloc: Allocator, data: []const u8, expected: files.HexDigest) !void {
    const observed = try std.json.parseFromSliceLeaky(WorkerLifecycleReport, alloc, data, .{ .ignore_unknown_fields = true });
    if (!observed.passed or observed.acquisition_failures_checked != std.meta.tags(worker_client.LifecycleProbe.Acquisition).len or !observed.no_data_directory or
        !observed.registration_rejected_without_publication or !observed.registration_recovered_on_same_process or
        !observed.registration_reapplied_after_restart or
        !std.mem.eql(u8, observed.executable_sha256, &expected) or
        !std.mem.eql(u8, observed.executable_sha256_after, &expected)) return error.WorkerLifecycleEvidenceMismatch;
}

const Stage = struct {
    alloc: Allocator,
    root: []const u8,
    evidence: std.ArrayList(zip.Entry) = .empty,

    fn path(self: Stage, rel: []const u8) ![]const u8 {
        return std.fs.path.join(self.alloc, &.{ self.root, rel });
    }

    fn read(self: Stage, rel: []const u8) ![]const u8 {
        return std.fs.cwd().readFileAlloc(self.alloc, try self.path(rel), max_evidence_file_size);
    }

    fn record(self: *Stage, name: []const u8, bytes: []const u8) !void {
        try self.evidence.append(self.alloc, .{ .name = name, .bytes = bytes });
    }

    fn recordFile(self: *Stage, name: []const u8, rel: []const u8) !void {
        try self.record(name, try self.read(rel));
    }

    fn runStep(self: *Stage, name: []const u8, argv: []const []const u8, cwd: []const u8, timeout_ms: u32) !process.Result {
        std.debug.print("配布候補の検査 {s}\n", .{name});
        const directory = try self.path(name);
        try std.fs.cwd().makeDir(directory);
        var logs = try std.fs.cwd().openDir(directory, .{ .no_follow = true });
        defer logs.close();
        const result = try process.run(self.alloc, argv, cwd, logs, timeout_ms);
        try process.saveResult(self.alloc, directory, result);
        if (result.timed_out or result.exit_code != 0) return error.FreezeTestCommandFailed;
        for ([_][]const u8{ "stdout.txt", "stderr.txt", "result.json" }) |file| {
            try self.recordFile(
                try std.fmt.allocPrint(self.alloc, "{s}-{s}", .{ name, file }),
                try std.fs.path.join(self.alloc, &.{ name, file }),
            );
        }
        return result;
    }

    fn testList(self: *Stage, name: []const u8, exe: LockedExecutable) ![]const []const u8 {
        _ = try self.runStep(name, &.{exe.path}, self.root, test_timeout_ms);
        try exe.check();
        const log_path = try std.fs.path.join(self.alloc, &.{ name, "stderr.txt" });
        return unitTestNames(self.alloc, try self.read(log_path));
    }

    fn recordGuestStep(self: *Stage, name: []const u8, allow_stderr: bool) ![]const u8 {
        const dir = try std.fs.path.join(self.alloc, &.{ "sandbox/results", name });
        const stdout = try self.read(try std.fs.path.join(self.alloc, &.{ dir, "stdout.txt" }));
        const stderr = try self.read(try std.fs.path.join(self.alloc, &.{ dir, "stderr.txt" }));
        const metadata = try self.read(try std.fs.path.join(self.alloc, &.{ dir, "result.json" }));
        const result = try std.json.parseFromSliceLeaky(process.Result, self.alloc, metadata, .{});
        if (result.timed_out or result.exit_code != 0 or result.stderr_bytes != stderr.len) return error.FreezeTestCommandFailed;
        if (!allow_stderr and stderr.len != 0) return error.UnexpectedTestStderr;
        for ([_][]const u8{ "stdout.txt", "stderr.txt", "result.json" }, [_][]const u8{ stdout, stderr, metadata }) |file, bytes|
            try self.record(try std.fmt.allocPrint(self.alloc, "{s}-{s}", .{ name, file }), bytes);
        return stderr;
    }
};

pub fn run(
    allocator: Allocator,
    project_root: []const u8,
    compiler_path: []const u8,
    output: []const u8,
    prepare_only: bool,
) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const output_absolute = try std.fs.path.resolve(alloc, &.{ try std.process.getCwdAlloc(alloc), output });
    if (std.fs.cwd().access(output_absolute, .{})) |_| {
        return error.OutputExists;
    } else |err| if (err != error.FileNotFound) {
        return err;
    }
    const parent = std.fs.path.dirname(output_absolute) orelse return error.InvalidOutputDirectory;
    const project_absolute = try std.fs.cwd().realpathAlloc(alloc, project_root);
    const compiler = try LockedExecutable.open(alloc, compiler_path);
    defer compiler.handle.close();
    if (!std.mem.eql(u8, &files.hex(compiler.sha), compiler_sha256)) return error.UnexpectedZigCompilerDigest;
    try source_check.run(alloc, project_absolute);

    try std.fs.cwd().makePath(parent);
    var stage = Stage{ .alloc = alloc, .root = try files.newDirectory(alloc, parent, "freeze-") };
    std.debug.print("配布候補の作業記録 {s}\n", .{stage.root});
    const snapshot_path = try stage.path("source");
    try std.fs.cwd().makeDir(snapshot_path);
    var project = try std.fs.cwd().openDir(project_absolute, .{});
    defer project.close();
    var snapshot = try std.fs.cwd().openDir(snapshot_path, .{ .no_follow = true });
    defer snapshot.close();
    const source_manifest = try release.captureSources(alloc, project, snapshot);
    try files.writeNew(std.fs.cwd(), try stage.path("SOURCE-SHA256SUMS"), source_manifest);
    try release.requireSources(alloc, project, source_manifest);
    try source_check.run(alloc, snapshot_path);

    _ = try stage.runStep("zig-version", &.{ compiler.path, "version" }, stage.root, 10_000);
    const version = std.mem.trim(u8, try stage.read("zig-version/stdout.txt"), " \r\n\t");
    if (!std.mem.eql(u8, version, compiler_version)) return error.UnexpectedZigVersion;
    const prefix = try stage.path("built");
    _ = try stage.runStep("build", &.{
        compiler.path, "build", "install",     "tools",                 "test-artifacts",     "-Doptimize=ReleaseSafe",
        "--prefix",    prefix,  "--cache-dir", try stage.path("cache"), "--global-cache-dir", try stage.path("global"),
        "--summary",   "all",
    }, snapshot_path, build_timeout_ms);
    try compiler.check();
    try release.requireSources(alloc, snapshot, source_manifest);
    try release.requireSources(alloc, project, source_manifest);

    const app = try LockedExecutable.open(alloc, try stage.path("built/bin/ChatPalette.exe"));
    defer app.handle.close();
    const app_tests = try LockedExecutable.open(alloc, try stage.path("built/bin/chatpalette-app-tests.exe"));
    defer app_tests.handle.close();
    const shortcut_tests = try LockedExecutable.open(alloc, try stage.path("built/bin/chatpalette-shortcut-tests.exe"));
    defer shortcut_tests.handle.close();
    const tools_tests = try LockedExecutable.open(alloc, try stage.path("built/bin/chatpalette-tools-tests.exe"));
    defer tools_tests.handle.close();
    const startup_test = try LockedExecutable.open(alloc, try stage.path("built/bin/chatpalette-startup-test.exe"));
    defer startup_test.handle.close();
    const worker_test = try LockedExecutable.open(alloc, try stage.path("built/bin/chatpalette-worker-lifecycle-test.exe"));
    defer worker_test.handle.close();
    const sandbox_harness = try LockedExecutable.open(alloc, try stage.path("built/bin/chatpalette-tools.exe"));
    defer sandbox_harness.handle.close();

    const shortcut_names = try stage.testList("unit-shortcuts", shortcut_tests);
    const tool_names = try stage.testList("unit-tools", tools_tests);
    const app_sha = files.hex(app.sha);

    try release.requireSources(alloc, snapshot, source_manifest);
    try release.requireSources(alloc, project, source_manifest);
    std.debug.print("配布候補の検査 Windows Sandbox{s}\n", .{if (prepare_only) " の準備" else ""});
    try sandbox.hostFreeze(alloc, app.path, sandbox_harness.path, try stage.path("sandbox"), prepare_only, .{
        .paths = .{ app_tests.path, startup_test.path, worker_test.path },
        .pins = .{
            .harness_sha256 = files.hex(sandbox_harness.sha),
            .runners_sha256 = .{ files.hex(app_tests.sha), files.hex(startup_test.sha), files.hex(worker_test.sha) },
        },
    });
    try checkDigest(try stage.path("sandbox/input/ChatPaletteTest.exe"), app.sha);
    const mounted_harness_sha = try files.readDigest(std.fs.cwd(), try stage.path("sandbox/input/ChatPaletteTools.exe"));
    if (!std.mem.eql(u8, &mounted_harness_sha, &sandbox_harness.sha)) return error.SandboxHarnessChanged;
    try app.check();
    try app_tests.check();
    try startup_test.check();
    try worker_test.check();
    try sandbox_harness.check();
    try release.requireSources(alloc, snapshot, source_manifest);
    try release.requireSources(alloc, project, source_manifest);

    if (!prepare_only) {
        const app_names = try unitTestNames(alloc, try stage.recordGuestStep("unit-app", true));
        _ = try stage.recordGuestStep("startup", false);
        const startup_report = try stage.read("sandbox/results/startup-result/result.json");
        try validateStartup(try std.json.parseFromSliceLeaky(StartupReport, alloc, startup_report, .{
            .ignore_unknown_fields = true,
        }), app_sha);
        try stage.record("startup-report.json", startup_report);
        _ = try stage.recordGuestStep("worker-lifecycle", false);
        const worker_report = try stage.read("sandbox/results/worker-result/result.json");
        try validateWorkerLifecycle(alloc, worker_report, app_sha);
        try stage.record("worker-lifecycle-report.json", worker_report);
        const test_names = try std.json.Stringify.valueAlloc(alloc, .{
            .app = .{ .count = app_names.len, .names = app_names },
            .shortcuts = .{ .count = shortcut_names.len, .names = shortcut_names },
            .tools = .{ .count = tool_names.len, .names = tool_names },
            .startup = startup_trials,
            .worker = "worker-lifecycle",
            .sandbox = [_][]const u8{"--smoke"},
        }, .{ .whitespace = .indent_2 });
        try files.writeNew(std.fs.cwd(), try stage.path("test-list.json"), test_names);
        try stage.record("test-list.json", test_names);
        const audio = try stage.read("sandbox/results/audio.json");
        const volume = try std.json.parseFromSliceLeaky(struct { muted_outputs: u32 }, alloc, audio, .{});
        if (volume.muted_outputs == 0) return error.SandboxAudioMuteUnverified;
        try stage.record("sandbox-audio.json", audio);
        const outcome = try stage.read("sandbox/results/result.json");
        try validateSandbox(alloc, outcome, app_sha);
        try stage.record("sandbox-report.json", outcome);
        try stage.recordFile("sandbox-stdout.txt", "sandbox/results/stdout.txt");
        try stage.recordFile("sandbox-stderr.txt", "sandbox/results/stderr.txt");
        try stage.recordFile("sandbox-selection.json", "sandbox/input/selection.json");
        const launcher_data = try stage.read("sandbox/launcher.json");
        const launch = try std.json.parseFromSliceLeaky(struct { session_id: ?[]const u8 }, alloc, launcher_data, .{ .ignore_unknown_fields = true });
        const session_id = launch.session_id orelse return error.SandboxSessionOwnershipUnverified;
        try stage.record("sandbox-launcher.json", launcher_data);
        const cleanup = try stage.read("sandbox/session-cleanup.json");
        try stage.record("sandbox-cleanup.json", cleanup);
        try stage.recordFile("sandbox-config.wsb", "sandbox/tests.wsb");
        const lifecycle: sandbox.LifecycleEvidence = .{
            .request = try stage.read("sandbox/session-start/request.json"),
            .start = try stage.read("sandbox/session-start/stdout.txt"),
            .preflight = try stage.read("sandbox/session-preflight/stdout.txt"),
            .before_cleanup = try stage.read("sandbox/session-before-cleanup/stdout.txt"),
            .after_cleanup = try stage.read("sandbox/session-after-cleanup/stdout.txt"),
        };
        try sandbox.validateCleanupEvidence(alloc, session_id, cleanup, lifecycle);
        try stage.record("sandbox-session-request.json", lifecycle.request);
        try stage.record("sandbox-session-start.json", lifecycle.start);
        try stage.record("sandbox-session-preflight.json", lifecycle.preflight);
        try stage.record("sandbox-session-before-cleanup.json", lifecycle.before_cleanup);
        try stage.record("sandbox-session-after-cleanup.json", lifecycle.after_cleanup);
    }
    const receipt = try std.json.Stringify.valueAlloc(alloc, .{
        .format = 1,
        .checks = if (prepare_only) "SandboxPrepared" else "FrozenSourceAutomatedChecks",
        .source_manifest_sha256 = files.hex(files.digest(source_manifest)),
        .candidate_executable_sha256 = app_sha,
        .zig_executable_sha256 = files.hex(compiler.sha),
        .zig_version = compiler_version,
        .target = "x86_64-windows-gnu",
        .optimize = "ReleaseSafe",
        .app_test_executable_sha256 = files.hex(app_tests.sha),
        .shortcut_test_executable_sha256 = files.hex(shortcut_tests.sha),
        .tools_test_executable_sha256 = files.hex(tools_tests.sha),
        .startup_test_executable_sha256 = files.hex(startup_test.sha),
        .worker_test_executable_sha256 = files.hex(worker_test.sha),
        .sandbox_harness_executable_sha256 = files.hex(sandbox_harness.sha),
        .sandbox_mounted_harness_sha256 = files.hex(mounted_harness_sha),
    }, .{ .whitespace = .indent_2 });
    try files.writeNew(std.fs.cwd(), try stage.path("freeze-run.json"), receipt);
    if (prepare_only) return allocator.dupe(u8, stage.root);

    try stage.record("freeze-run.json", receipt);
    try release.makeVerifiedCandidate(alloc, app.path, app.sha, snapshot_path, output_absolute, .{
        .source_manifest = source_manifest,
        .original_source = project,
        .files = stage.evidence.items,
        .clean_output = try stage.path("clean-extract"),
    });
    return allocator.dupe(u8, output_absolute);
}

fn checkDigest(path: []const u8, expected: files.Digest) !void {
    const digest = try files.readDigest(std.fs.cwd(), path);
    if (!std.mem.eql(u8, &digest, &expected)) return error.FreezeTestExecutableMismatch;
}

fn validateSandbox(alloc: Allocator, bytes: []const u8, expected: files.HexDigest) !void {
    const Report = struct {
        passed: bool,
        result: ?process.Result,
        input_matches: bool,
        executable_sha256: ?[]const u8,
        failure: ?[]const u8,
    };
    const report = try std.json.parseFromSliceLeaky(Report, alloc, bytes, .{});
    if (!std.mem.eql(u8, report.executable_sha256 orelse "", &expected)) return error.SandboxTestExecutableMismatch;
    if (!report.input_matches or !report.passed or report.failure != null or
        !(report.result orelse return error.SandboxTestsIncomplete).passed()) return error.SandboxTestsIncomplete;
}

test "Zig release test evidence requires every named test and its all-pass summary" {
    const alloc = std.testing.allocator;
    const names = try unitTestNames(alloc, "1/2 main.test_0...OK\r\n2/2 unit.test.example...[test] log\r\nmore text\r\nOK\r\nAll 2 tests passed.\r\n");
    defer alloc.free(names);
    try std.testing.expectEqual(@as(usize, 2), names.len);
    try std.testing.expectEqualStrings("unit.test.example", names[1]);
    for ([_][]const u8{
        "All 0 tests passed.\n",
        "1/1 main.test_0...SKIP\nAll 1 tests passed.\n",
        "1/2 main.test_0...OK\nAll 1 tests passed.\n",
        "1/1 main.test_0...\nAll 1 tests passed.\n",
        "1/1 main.test_0...OK\nAll 1 tests passed.\n1 tests leaked memory.\n",
        "1/2 main.test_0...OK\n2/2 main.test_0...OK\nAll 2 tests passed.\n",
    }) |invalid| try std.testing.expectError(error.InvalidUnitTestLog, unitTestNames(alloc, invalid));
}

test "Sandbox release evidence requires the exact executable and successful guest result" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const app = files.hex(files.digest("candidate"));
    const data = try std.json.Stringify.valueAlloc(alloc, .{
        .passed = true,
        .result = process.Result{ .exit_code = 0, .timed_out = false, .stderr_bytes = 0, .elapsed_ms = 31 },
        .input_matches = true,
        .executable_sha256 = app,
        .failure = null,
    }, .{});
    try validateSandbox(alloc, data, app);
    try std.testing.expectError(error.SandboxTestExecutableMismatch, validateSandbox(alloc, data, files.hex(files.digest("different app"))));
    const incomplete = try std.json.Stringify.valueAlloc(alloc, .{
        .passed = true,
        .result = null,
        .input_matches = true,
        .executable_sha256 = app,
        .failure = null,
    }, .{});
    try std.testing.expectError(error.SandboxTestsIncomplete, validateSandbox(alloc, incomplete, app));
}

test "worker lifecycle release evidence requires every acquisition failure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const app = files.hex(files.digest("candidate"));
    const required = std.meta.tags(worker_client.LifecycleProbe.Acquisition).len;
    var report: WorkerLifecycleReport = .{
        .passed = true,
        .executable_sha256 = &app,
        .executable_sha256_after = &app,
        .acquisition_failures_checked = required - 1,
        .registration_rejected_without_publication = true,
        .registration_recovered_on_same_process = true,
        .registration_reapplied_after_restart = true,
        .no_data_directory = true,
    };
    const incomplete = try std.json.Stringify.valueAlloc(alloc, report, .{});
    try std.testing.expectError(error.WorkerLifecycleEvidenceMismatch, validateWorkerLifecycle(alloc, incomplete, app));
    report.acquisition_failures_checked = required;
    const complete = try std.json.Stringify.valueAlloc(alloc, report, .{});
    try validateWorkerLifecycle(alloc, complete, app);
}

test "startup release evidence requires unchanged databases and every expected trial" {
    const app = files.hex(files.digest("candidate"));
    const db_sha = files.hex(files.digest("settings"));
    var trials: [startup_trials.len]StartupReport.Trial = undefined;
    for (&trials, startup_trials, 1..) |*trial, expected, index| trial.* = .{
        .name = expected.name,
        .folder = expected.folder,
        .pid = @intCast(index),
        .exit_code = expected.exit_code,
        .timed_out = false,
        .ready_ms = if (expected.must_be_ready) 20 else null,
        .cleanup_error = null,
    };
    var report = StartupReport{
        .passed = true,
        .failure = null,
        .executable_sha256 = &app,
        .database_a_sha256_before = &db_sha,
        .database_a_sha256_after = &db_sha,
        .database_b_sha256_before = &db_sha,
        .database_b_sha256_after = &db_sha,
        .invalid_database_sha256_before = &db_sha,
        .invalid_database_sha256_after = &db_sha,
        .invalid_arguments_leave_no_data = true,
        .worker_leaves_no_data = true,
        .quiet_instances_are_independent = true,
        .rejected_check_leaves_both_hosts_running = true,
        .takeover_leaves_other_host_running = true,
        .trials = &trials,
    };
    try validateStartup(report, app);
    try std.testing.expectError(error.StartupTestExecutableMismatch, validateStartup(report, db_sha));
    report.database_b_sha256_after = &app;
    try std.testing.expectError(error.StartupTestsIncomplete, validateStartup(report, app));
    report.database_b_sha256_after = &db_sha;
    trials[4].ready_ms = null;
    try std.testing.expectError(error.StartupTestsIncomplete, validateStartup(report, app));
    report.trials = report.trials[0 .. trials.len - 1];
    try std.testing.expectError(error.StartupTestsIncomplete, validateStartup(report, app));
}
