const std = @import("std");
const files = @import("files.zig");
const process = @import("process.zig");
const sandbox = @import("sandbox.zig");

const Allocator = std.mem.Allocator;
const archive_name = "Candidate.zip";
const harness_name = "ChatPaletteCleanInstall.exe";
const guest_timeout_ms = 120_000;
const max_report_bytes = 4 * 1024 * 1024;
const scenario_logs = .{ "stdout.txt", "stderr.txt", "diagnostics.txt" };

const FailureStage = enum { prepare, execute, collect, validate };
const CollectionOperation = enum { open_source, create_destination, open_destination, read_file, write_file };
const CollectionFailure = struct {
    member: []const u8,
    cause: []const u8,
    operation: ?CollectionOperation = null,
};
const CollectionFailures = std.ArrayList(CollectionFailure);

const Report = struct {
    passed: bool = false,
    result: ?process.Result = null,
    archive_sha256: ?files.HexDigest = null,
    harness_sha256: ?files.HexDigest = null,
    controller_sha256: ?files.HexDigest = null,
    executable_sha256: ?files.HexDigest = null,
    clean_install_report_sha256: ?files.HexDigest = null,
    scenario_report_sha256: ?files.HexDigest = null,
    failure: ?[]const u8 = null,
    failure_stage: ?FailureStage = null,
    child_cleanup_failure: ?[]const u8 = null,
    collection_failure: ?CollectionFailure = null,
    collection_failures: []const CollectionFailure = &.{},
};

const InstallReport = struct {
    passed: bool,
    archive_sha256: ?[]const u8,
    executable_sha256: ?[]const u8,
};

const ScenarioReport = struct {
    passed: bool,
    checks: struct { diagnostic_clipboard_sha256: ?files.HexDigest },
};

fn digestArgument(text: []const u8) !files.Digest {
    if (text.len != 64) return error.InvalidPackageDigest;
    var digest: files.Digest = undefined;
    _ = std.fmt.hexToBytes(&digest, text) catch return error.InvalidPackageDigest;
    return digest;
}

const Sealed = struct {
    path: []const u8,
    handle: std.fs.File,
    digest: files.Digest,

    fn open(alloc: Allocator, path: []const u8) !Sealed {
        const absolute = try std.fs.cwd().realpathAlloc(alloc, path);
        const handle = try files.openImmutable(alloc, absolute);
        errdefer handle.close();
        return .{ .path = absolute, .handle = handle, .digest = try files.fileDigest(handle) };
    }

    fn require(self: Sealed, expected: files.Digest, mismatch: anyerror) !void {
        if (!std.mem.eql(u8, &self.digest, &expected)) return mismatch;
    }

    fn copy(self: Sealed, dir: std.fs.Dir, name: []const u8) !void {
        {
            const target = try dir.createFile(name, .{ .exclusive = true });
            defer target.close();
            try self.handle.seekTo(0);
            var buffer: [64 * 1024]u8 = undefined;
            while (true) {
                const n = try self.handle.read(&buffer);
                if (n == 0) break;
                try target.writeAll(buffer[0..n]);
            }
            try target.sync();
        }
        const copied = try files.readDigest(dir, name);
        if (!std.mem.eql(u8, &copied, &self.digest)) return error.SandboxPackageCopyChanged;
    }
};

pub fn host(
    allocator: Allocator,
    archive_path: []const u8,
    expected_archive: []const u8,
    harness_path: []const u8,
    output: []const u8,
    prepare_only: bool,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const expected = try digestArgument(expected_archive);
    const archive = try Sealed.open(alloc, archive_path);
    defer archive.handle.close();
    try archive.require(expected, error.SandboxPackageArchiveDigestMismatch);
    const harness = try Sealed.open(alloc, harness_path);
    defer harness.handle.close();
    if (!std.ascii.eqlIgnoreCase(std.fs.path.extension(harness.path), ".exe")) return error.ExpectedExecutable;
    const controller = try Sealed.open(alloc, try std.fs.selfExePathAlloc(alloc));
    defer controller.handle.close();
    const pins: sandbox.PackagePins = .{ .archive = expected, .harness = harness.digest, .controller = controller.digest };

    const session = try sandbox.Host.open(alloc, prepare_only);
    defer session.close();
    const layout = try sandbox.Layout.create(alloc, output);
    var input = try std.fs.cwd().openDir(layout.input, .{ .no_follow = true });
    defer input.close();
    try archive.copy(input, archive_name);
    try harness.copy(input, harness_name);
    try controller.copy(input, sandbox.tool_name);

    const mounted_archive = try openMember(alloc, layout.input, archive_name, pins.archive, error.SandboxPackageArchiveDigestMismatch);
    defer mounted_archive.handle.close();
    const mounted_harness = try openMember(alloc, layout.input, harness_name, pins.harness, error.SandboxPackageHarnessDigestMismatch);
    defer mounted_harness.handle.close();
    const mounted_tool = try openMember(alloc, layout.input, sandbox.tool_name, pins.controller, error.SandboxPackageControllerDigestMismatch);
    defer mounted_tool.handle.close();

    const receipt = try std.json.Stringify.valueAlloc(alloc, .{
        .archive_sha256 = files.hex(pins.archive),
        .harness_sha256 = files.hex(pins.harness),
        .controller_sha256 = files.hex(pins.controller),
        .prepare_only = prepare_only,
    }, .{ .whitespace = .indent_2 });
    try files.writeNew(std.fs.cwd(), try std.fs.path.join(alloc, &.{ layout.root, "package-inputs.json" }), receipt);
    try layout.configure(alloc, .{ .package = pins });
    if (try session.run(Report, alloc, layout, guest_timeout_ms)) |report| {
        try requirePassed(report, pins);
        var evidence = try std.fs.cwd().openDir(layout.evidence, .{ .no_follow = true });
        defer evidence.close();
        const observed_install = try files.readDigest(evidence, "clean-install/result.json");
        const scenario_text = try evidence.readFileAlloc(alloc, "clean-install/scenario/result.json", max_report_bytes);
        const observed_scenario = files.digest(scenario_text);
        if (!agrees(report.clean_install_report_sha256, observed_install) or
            !agrees(report.scenario_report_sha256, observed_scenario)) return error.SandboxPackageEvidenceChanged;
        const scenario = try std.json.parseFromSliceLeaky(ScenarioReport, alloc, scenario_text, .{ .ignore_unknown_fields = true });
        const observed_diagnostics = try files.readDigest(evidence, "clean-install/scenario/diagnostics.txt");
        if (!agrees(scenario.checks.diagnostic_clipboard_sha256, observed_diagnostics)) return error.SandboxClipboardEvidenceChanged;
    }
}

fn openMember(alloc: Allocator, root: []const u8, name: []const u8, expected: files.Digest, mismatch: anyerror) !Sealed {
    const file = try Sealed.open(alloc, try std.fs.path.join(alloc, &.{ root, name }));
    errdefer file.handle.close();
    try file.require(expected, mismatch);
    return file;
}

fn agrees(observed: ?files.HexDigest, expected: files.Digest) bool {
    const actual = observed orelse return false;
    return std.mem.eql(u8, &actual, &files.hex(expected));
}

fn requirePassed(report: Report, pins: sandbox.PackagePins) !void {
    const result = report.result orelse return error.SandboxPackageTestsFailed;
    if (!report.passed or report.failure != null or report.failure_stage != null or
        report.child_cleanup_failure != null or report.collection_failure != null or report.collection_failures.len != 0 or
        result.exit_code != 0 or result.timed_out)
        return error.SandboxPackageTestsFailed;
    if (!agrees(report.archive_sha256, pins.archive)) return error.SandboxPackageArchiveDigestMismatch;
    if (!agrees(report.harness_sha256, pins.harness)) return error.SandboxPackageHarnessDigestMismatch;
    if (!agrees(report.controller_sha256, pins.controller)) return error.SandboxPackageControllerDigestMismatch;
    _ = try digestArgument(&(report.executable_sha256 orelse return error.SandboxPackageTestsFailed));
}

fn noteCollectionFailure(failures: *CollectionFailures, member: []const u8, operation: CollectionOperation, err: anyerror) void {
    failures.appendAssumeCapacity(.{ .member = member, .operation = operation, .cause = @errorName(err) });
}

fn collectFile(alloc: Allocator, source: std.fs.Dir, output: std.fs.Dir, name: []const u8, member: []const u8, failures: *CollectionFailures) ?[]const u8 {
    const text = source.readFileAlloc(alloc, name, max_report_bytes) catch |err| {
        noteCollectionFailure(failures, member, .read_file, err);
        return null;
    };
    files.writeNew(output, name, text) catch |err| {
        noteCollectionFailure(failures, member, .write_file, err);
        return null;
    };
    return text;
}

const Evidence = struct {
    install: ?[]const u8 = null,
    scenario: ?[]const u8 = null,
};

fn harvest(alloc: Allocator, work_path: []const u8, output: std.fs.Dir, expect_output: bool, failures: *CollectionFailures) Evidence {
    var evidence: Evidence = .{};
    var work = std.fs.cwd().openDir(work_path, .{ .no_follow = true }) catch |err| {
        if (err != error.FileNotFound or expect_output) noteCollectionFailure(failures, "clean-install", .open_source, err);
        return evidence;
    };
    defer work.close();
    output.makeDir("clean-install") catch |err| {
        noteCollectionFailure(failures, "clean-install", .create_destination, err);
        return evidence;
    };
    var destination = output.openDir("clean-install", .{ .no_follow = true }) catch |err| {
        noteCollectionFailure(failures, "clean-install", .open_destination, err);
        return evidence;
    };
    defer destination.close();
    evidence.install = collectFile(alloc, work, destination, "result.json", "clean-install/result.json", failures);
    var scenario = work.openDir("scenario", .{ .no_follow = true }) catch |err| {
        noteCollectionFailure(failures, "clean-install/scenario", .open_source, err);
        return evidence;
    };
    defer scenario.close();
    destination.makeDir("scenario") catch |err| {
        noteCollectionFailure(failures, "clean-install/scenario", .create_destination, err);
        return evidence;
    };
    var scenario_evidence = destination.openDir("scenario", .{ .no_follow = true }) catch |err| {
        noteCollectionFailure(failures, "clean-install/scenario", .open_destination, err);
        return evidence;
    };
    defer scenario_evidence.close();
    evidence.scenario = collectFile(alloc, scenario, scenario_evidence, "result.json", "clean-install/scenario/result.json", failures);
    inline for (scenario_logs) |name| {
        _ = collectFile(alloc, scenario, scenario_evidence, name, "clean-install/scenario/" ++ name, failures);
    }
    return evidence;
}

fn runStagedHarness(alloc: Allocator, work_path: []const u8, install_output: []const u8, output: std.fs.Dir, pins: sandbox.PackagePins, archive: Sealed, harness: Sealed) !process.Observation {
    var work = try std.fs.cwd().openDir(work_path, .{ .no_follow = true });
    defer work.close();
    try archive.copy(work, archive_name);
    try harness.copy(work, harness_name);
    const local_archive = try openMember(alloc, work_path, archive_name, pins.archive, error.SandboxPackageArchiveDigestMismatch);
    defer local_archive.handle.close();
    const local_harness = try openMember(alloc, work_path, harness_name, pins.harness, error.SandboxPackageHarnessDigestMismatch);
    defer local_harness.handle.close();
    const archive_sha = files.hex(pins.archive);
    return process.observe(alloc, &.{ local_harness.path, local_archive.path, &archive_sha, install_output, "--sandbox-clipboard" }, work_path, output, guest_timeout_ms);
}

fn rememberChild(report: *Report, observed: process.Observation) void {
    report.result = observed.result;
    report.child_cleanup_failure = if (observed.cleanup_failure) |err| @errorName(err) else null;
    report.failure = failure: {
        if (observed.failure) |err| break :failure @errorName(err);
        if (observed.result) |child| {
            if (child.timed_out) break :failure "SandboxPackageHarnessDeadlineExpired";
            if (child.exit_code != 0) break :failure "SandboxPackageHarnessFailed";
        }
        break :failure report.child_cleanup_failure;
    };
    if (report.failure != null) report.failure_stage = .execute;
}

fn runGuest(alloc: Allocator, input: []const u8, output: std.fs.Dir, pins: sandbox.PackagePins, report: *Report) !void {
    report.failure_stage = .prepare;
    // Each report and log can contribute one failure. A directory failure prevents those member reads.
    var failures = try CollectionFailures.initCapacity(alloc, 2 + scenario_logs.len);
    const archive = try openMember(alloc, input, archive_name, pins.archive, error.SandboxPackageArchiveDigestMismatch);
    defer archive.handle.close();
    report.archive_sha256 = files.hex(archive.digest);
    const harness = try openMember(alloc, input, harness_name, pins.harness, error.SandboxPackageHarnessDigestMismatch);
    defer harness.handle.close();
    report.harness_sha256 = files.hex(harness.digest);
    const controller = try Sealed.open(alloc, try std.fs.selfExePathAlloc(alloc));
    defer controller.handle.close();
    try controller.require(pins.controller, error.SandboxPackageControllerDigestMismatch);
    report.controller_sha256 = files.hex(controller.digest);

    const temporary = try std.process.getEnvVarOwned(alloc, "TEMP");
    const work_path = try files.newDirectory(alloc, temporary, "ChatPalettePackage-");
    const install_output = try std.fs.path.join(alloc, &.{ work_path, "clean-install" });
    if (runStagedHarness(alloc, work_path, install_output, output, pins, archive, harness)) |observed| {
        rememberChild(report, observed);
    } else |err| {
        report.failure = @errorName(err);
    }
    const evidence = harvest(alloc, install_output, output, report.failure == null, &failures);
    report.collection_failures = failures.items;
    if (failures.items.len != 0) report.collection_failure = failures.items[0];
    if (evidence.install) |text| report.clean_install_report_sha256 = files.hex(files.digest(text));
    if (evidence.scenario) |text| report.scenario_report_sha256 = files.hex(files.digest(text));
    if (report.failure != null) return;
    if (report.collection_failure) |failure| {
        report.failure_stage = .collect;
        report.failure = if (std.mem.eql(u8, failure.cause, "FileNotFound"))
            if (evidence.install == null) "SandboxPackageResultMissing" else "SandboxPackageScenarioMissing"
        else
            failure.cause;
        return;
    }
    report.failure_stage = .validate;
    const archive_sha = files.hex(pins.archive);
    const text = evidence.install orelse return error.SandboxPackageResultMissing;
    const scenario_result = evidence.scenario orelse return error.SandboxPackageScenarioMissing;
    const install = try std.json.parseFromSliceLeaky(InstallReport, alloc, text, .{ .ignore_unknown_fields = true });
    if (!install.passed) return error.SandboxPackageTestsFailed;
    if (!std.mem.eql(u8, install.archive_sha256 orelse "", &archive_sha)) return error.SandboxPackageArchiveDigestMismatch;
    const scenario = try std.json.parseFromSliceLeaky(ScenarioReport, alloc, scenario_result, .{ .ignore_unknown_fields = true });
    if (!scenario.passed or scenario.checks.diagnostic_clipboard_sha256 == null) return error.SandboxPackageTestsFailed;
    const installed_digest = try digestArgument(install.executable_sha256 orelse "");
    report.executable_sha256 = files.hex(installed_digest);
    report.failure_stage = null;
    report.passed = true;
}

pub fn guest(
    allocator: Allocator,
    input: []const u8,
    output: []const u8,
    archive_pin: []const u8,
    harness_pin: []const u8,
    controller_pin: []const u8,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const input_path = try std.fs.cwd().realpathAlloc(alloc, input);
    const output_path = try std.fs.cwd().realpathAlloc(alloc, output);
    if (sameOrChild(input_path, output_path) or sameOrChild(output_path, input_path)) return error.SandboxPackageInputOutputOverlap;
    var evidence = try std.fs.cwd().openDir(output_path, .{ .no_follow = true });
    defer evidence.close();
    const pins: sandbox.PackagePins = .{
        .archive = try digestArgument(archive_pin),
        .harness = try digestArgument(harness_pin),
        .controller = try digestArgument(controller_pin),
    };
    for ([_][]const u8{ "result.json", "result.pending.json", "stdout.txt", "stderr.txt", "clean-install" }) |existing| {
        if (evidence.access(existing, .{})) |_| {
            return error.SandboxPackageEvidenceExists;
        } else |err| if (err != error.FileNotFound) {
            return err;
        }
    }
    // A second invocation must not race the logs or publish its failure over the first guest.
    try files.writeNew(evidence, "package-guest.started", "");
    var report: Report = .{};
    runGuest(alloc, input_path, evidence, pins, &report) catch |err| {
        report.failure = @errorName(err);
    };
    try process.saveResult(alloc, output_path, report);
    if (!report.passed) return error.SandboxPackageTestsFailed;
}

fn sameOrChild(parent: []const u8, child: []const u8) bool {
    if (!std.ascii.startsWithIgnoreCase(child, parent)) return false;
    return child.len == parent.len or std.fs.path.isSep(parent[parent.len - 1]) or std.fs.path.isSep(child[parent.len]);
}

test "package staging pins all inputs in the Sandbox command and keeps the app inside the ZIP" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try temporary.dir.realpathAlloc(alloc, ".");
    const archive = try std.fs.path.join(alloc, &.{ root, "Original.zip" });
    const harness = try std.fs.path.join(alloc, &.{ root, "Synthetic.exe" });
    const output = try std.fs.path.join(alloc, &.{ root, "staged" });
    try files.writeNew(temporary.dir, "Original.zip", "candidate fixture");
    try files.writeNew(temporary.dir, "Synthetic.exe", "harness fixture");
    const archive_pin = files.hex(files.digest("candidate fixture"));
    const bad_pin = files.hex(files.digest("another package"));
    try std.testing.expectError(error.SandboxPackageArchiveDigestMismatch, host(alloc, archive, &bad_pin, harness, output, true));
    try std.testing.expectError(error.FileNotFound, temporary.dir.access("staged", .{}));
    try host(alloc, archive, &archive_pin, harness, output, true);

    const bytes = try temporary.dir.readFileAlloc(alloc, "staged/tests.wsb", 8192);
    const harness_pin = files.hex(files.digest("harness fixture"));
    const controller_pin = files.hex(try files.readDigest(temporary.dir, "staged/input/ChatPaletteTools.exe"));
    const command = try std.fmt.allocPrint(alloc, "sandbox-package-guest C:\\ChatPaletteInput C:\\ChatPaletteEvidence {s} {s} {s}</Command>", .{ archive_pin, harness_pin, controller_pin });
    try std.testing.expect(std.mem.indexOf(u8, bytes, command) != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "<ReadOnly>true</ReadOnly>") != null);
    try std.testing.expectEqual(files.digest("candidate fixture"), try files.readDigest(temporary.dir, "staged/input/Candidate.zip"));
    try std.testing.expectEqual(files.digest("harness fixture"), try files.readDigest(temporary.dir, "staged/input/ChatPaletteCleanInstall.exe"));
    try std.testing.expectError(error.FileNotFound, temporary.dir.access("staged/input/ChatPalette.exe", .{}));
    try std.testing.expectError(error.FileNotFound, temporary.dir.access("staged/results/result.json", .{}));

    const input = try std.fs.path.join(alloc, &.{ output, "input" });
    const results = try std.fs.path.join(alloc, &.{ output, "results" });
    try std.testing.expectError(error.SandboxPackageInputOutputOverlap, guest(alloc, input, input, &archive_pin, &harness_pin, &controller_pin));
    {
        const changed = try temporary.dir.createFile("staged/input/Candidate.zip", .{ .truncate = true });
        defer changed.close();
        try changed.writeAll("changed candidate");
    }
    try std.testing.expectError(error.SandboxPackageTestsFailed, guest(alloc, input, results, &archive_pin, &harness_pin, &controller_pin));
    const report = try std.json.parseFromSliceLeaky(Report, alloc, try temporary.dir.readFileAlloc(alloc, "staged/results/result.json", 4096), .{});
    try std.testing.expect(!report.passed and report.result == null);
    try std.testing.expectEqualStrings("SandboxPackageArchiveDigestMismatch", report.failure.?);
    try std.testing.expectEqual(@as(?FailureStage, .prepare), report.failure_stage);
    try std.testing.expectEqual(@as(usize, 0), report.collection_failures.len);
    try std.testing.expectError(error.FileNotFound, temporary.dir.access("staged/results/stdout.txt", .{}));
    try std.testing.expectError(error.SandboxPackageEvidenceExists, guest(alloc, input, results, &archive_pin, &harness_pin, &controller_pin));
}

test "package success requires the expected inventory of executed input bytes" {
    const pins: sandbox.PackagePins = .{
        .archive = files.digest("archive"),
        .harness = files.digest("harness"),
        .controller = files.digest("controller"),
    };
    var report: Report = .{
        .passed = true,
        .result = .{ .exit_code = 0, .timed_out = false, .elapsed_ms = 7, .stderr_bytes = 0 },
        .archive_sha256 = files.hex(pins.archive),
        .harness_sha256 = files.hex(pins.harness),
        .controller_sha256 = files.hex(pins.controller),
        .executable_sha256 = files.hex(files.digest("extracted app")),
    };
    try requirePassed(report, pins);
    report.harness_sha256 = files.hex(files.digest("different harness"));
    try std.testing.expectError(error.SandboxPackageHarnessDigestMismatch, requirePassed(report, pins));
    report.harness_sha256 = files.hex(pins.harness);
    report.result.?.exit_code = 1;
    try std.testing.expectError(error.SandboxPackageTestsFailed, requirePassed(report, pins));
    report.result.?.exit_code = 0;
    report.collection_failure = .{ .member = "clean-install/scenario/stderr.txt", .cause = "FileTooBig" };
    try std.testing.expectError(error.SandboxPackageTestsFailed, requirePassed(report, pins));
    report.collection_failures = &.{report.collection_failure.?};
    report.collection_failure = null;
    try std.testing.expectError(error.SandboxPackageTestsFailed, requirePassed(report, pins));
}

test "package collection records every failed member and still recovers later files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.makePath("private/clean-install/scenario");
    try temporary.dir.makeDir("published");
    try files.writeNew(temporary.dir, "private/clean-install/result.json", "install report");
    try files.writeNew(temporary.dir, "private/clean-install/scenario/result.json", "scenario report");
    try files.writeNew(temporary.dir, "private/clean-install/scenario/diagnostics.txt", "retained diagnostics");
    for ([_][]const u8{
        "private/clean-install/scenario/stdout.txt",
        "private/clean-install/scenario/stderr.txt",
    }) |name| {
        const oversized = try temporary.dir.createFile(name, .{ .exclusive = true });
        defer oversized.close();
        try oversized.setEndPos(max_report_bytes + 1);
    }
    const path = try temporary.dir.realpathAlloc(alloc, "private/clean-install");
    var published = try temporary.dir.openDir("published", .{});
    defer published.close();
    var report: Report = .{};
    rememberChild(&report, .{
        .result = .{ .exit_code = 17, .timed_out = false, .elapsed_ms = 12, .stderr_bytes = 0 },
        .cleanup_failure = error.CouldNotTerminateTestJob,
    });
    var failures = try CollectionFailures.initCapacity(alloc, 2 + scenario_logs.len);
    const evidence = harvest(alloc, path, published, false, &failures);
    try std.testing.expectEqual(@as(?FailureStage, .execute), report.failure_stage);
    try std.testing.expectEqualStrings("SandboxPackageHarnessFailed", report.failure.?);
    try std.testing.expectEqualStrings("CouldNotTerminateTestJob", report.child_cleanup_failure.?);
    try std.testing.expectEqual(@as(usize, 2), failures.items.len);
    for (failures.items, [_][]const u8{ "clean-install/scenario/stdout.txt", "clean-install/scenario/stderr.txt" }) |failure, member| {
        try std.testing.expectEqualStrings(member, failure.member);
        try std.testing.expectEqualStrings("FileTooBig", failure.cause);
        try std.testing.expectEqual(@as(?CollectionOperation, .read_file), failure.operation);
    }
    try std.testing.expectEqual(@as(u32, 17), report.result.?.exit_code);
    try std.testing.expect(!report.passed);
    try std.testing.expectEqualStrings("install report", evidence.install.?);
    try std.testing.expectEqualStrings("scenario report", evidence.scenario.?);
    try std.testing.expectEqual(files.digest("retained diagnostics"), try files.readDigest(published, "clean-install/scenario/diagnostics.txt"));
}
