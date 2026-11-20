const std = @import("std");
const files = @import("files.zig");
const process = @import("process.zig");
const freeze = @import("freeze.zig");

const Allocator = std.mem.Allocator;
const registry = @import("test_registry.zig");
const Session = registry.Session;
const Case = registry.Case;
const cases = registry.cases;
const source_gate: Case = .{ .name = "source-check", .session = null, .executable = "chatpalette-tools.exe", .kind = .source, .timeout_ms = 30_000 };
const evidence_limit = 4 * 1024 * 1024;

fn match(args: []const []const u8, default_session: ?Session) ![cases.len]bool {
    return parseSelection(args, default_session, null);
}

fn parseSelection(args: []const []const u8, default_session: ?Session, browser_exe: ?*?[]const u8) ![cases.len]bool {
    var requested = @as([cases.len]bool, @splat(false));
    var named = false;
    var session: ?Session = null;
    if (args.len % 2 != 0) return error.InvalidTestSelection;
    var index: usize = 0;
    while (index < args.len) : (index += 2) {
        const flag = args[index];
        const value = args[index + 1];
        if (std.mem.eql(u8, flag, "--session")) {
            if (session != null) return error.InvalidTestSelection;
            session = std.meta.stringToEnum(Session, value) orelse return error.InvalidTestSession;
        } else if (std.mem.eql(u8, flag, "--name")) {
            const selected = registry.indexOf(value) orelse return error.UnknownTestName;
            requested[selected] = true;
            named = true;
        } else if (std.mem.eql(u8, flag, "--browser-exe")) {
            const path = browser_exe orelse return error.InvalidTestSelection;
            if (path.* != null or value.len == 0) return error.InvalidTestSelection;
            path.* = value;
        } else {
            return error.InvalidTestSelection;
        }
    }
    const effective_session = session orelse default_session;
    var selected = @as([cases.len]bool, @splat(false));
    for (cases, requested, &selected) |entry, explicit, *include| {
        const belongs = effective_session == null or effective_session == entry.session;
        if (explicit and !belongs)
            return if (session == null) error.DesktopSessionRequired else error.TestOutsideSelectedSession;
        include.* = belongs and (!named or explicit);
    }
    return selected;
}

pub fn list(alloc: Allocator, args: []const []const u8) ![]u8 {
    const selected = try match(args, null);
    var out = std.Io.Writer.Allocating.init(alloc);
    errdefer out.deinit();
    for (cases, selected) |entry, include| {
        if (include) try out.writer.print("{s}\n", .{entry.name});
    }
    return out.toOwnedSlice();
}

const Image = struct {
    path: []const u8,
    file: std.fs.File,
    digest: files.Digest,

    fn open(alloc: Allocator, location: []const u8) !Image {
        const path = try std.fs.cwd().realpathAlloc(alloc, location);
        const file = try files.openImmutable(alloc, path);
        errdefer file.close();
        return .{ .path = path, .file = file, .digest = try files.fileDigest(file) };
    }

    fn check(self: Image) !void {
        try self.file.seekTo(0);
        const after = try files.fileDigest(self.file);
        if (!std.mem.eql(u8, &after, &self.digest)) return error.TestImageChanged;
    }
};

const Group = struct {
    name: []const u8,
    session: ?Session,
    passed: bool = false,
    executable_sha256: files.HexDigest,
    result: ?process.Result = null,
    failure: ?[]const u8 = null,
    child_cleanup_failure: ?[]const u8 = null,
    work_cleanup_failure: ?[]const u8 = null,
    unit_names: ?[]const []const u8 = null,
};

fn observeFailure(observed: process.Observation) ?anyerror {
    if (observed.failure) |failure| return failure;
    const result = observed.result.?;
    if (result.timed_out) return error.TestDeadlineExpired;
    if (result.exit_code != 0) return error.TestExitedUnsuccessfully;
    return null;
}

fn readStartupReport(alloc: Allocator, group_dir: std.fs.Dir, absolute_work: []const u8, application: Image) !void {
    const path = try std.fs.path.join(alloc, &.{ absolute_work, "startup-observations", "result.json" });
    const data = try std.fs.cwd().readFileAlloc(alloc, path, evidence_limit);
    try files.writeNew(group_dir, "startup-observations.json", data);
    const info = try std.json.parseFromSliceLeaky(struct { passed: bool, executable_sha256: []const u8 }, alloc, data, .{ .ignore_unknown_fields = true });
    if (!info.passed or !std.mem.eql(u8, info.executable_sha256, &files.hex(application.digest))) return error.StartupEvidenceMismatch;
}

fn readBrowserReport(alloc: Allocator, group_dir: std.fs.Dir, absolute_work: []const u8, application: Image) !void {
    const path = try std.fs.path.join(alloc, &.{ absolute_work, "browser-observations", "result.json" });
    const data = try std.fs.cwd().readFileAlloc(alloc, path, evidence_limit);
    try files.writeNew(group_dir, "browser-observations.json", data);
    try validateBrowserReport(alloc, data, files.hex(application.digest));
}

const reaction_timing_case_name = "all reaction intervals and the random choice send exactly ten operations";
const browser_case_count = 22;
const BrowserCaseResult = struct { name: []const u8, passed: bool };

pub fn validateBrowserReport(alloc: Allocator, data: []const u8, expected_app: files.HexDigest) !void {
    const info = try std.json.parseFromSliceLeaky(struct {
        passed: bool,
        sha256: []const u8,
        browser_exit: u32,
        second_browser_exit: u32,
        app_exit: u32,
        restarted_app_exit: u32,
        previous_worker_exit: u32,
        run: []const BrowserCaseResult,
    }, alloc, data, .{ .ignore_unknown_fields = true });
    if (!info.passed or info.browser_exit != 0 or info.second_browser_exit != 0 or info.app_exit != 0 or
        info.restarted_app_exit != 0 or info.previous_worker_exit != 1 or info.run.len != browser_case_count or
        !std.mem.eql(u8, info.sha256, &expected_app)) return error.BrowserFixtureEvidenceMismatch;
    var names = std.StringHashMap(void).init(alloc);
    defer names.deinit();
    for (info.run) |item| {
        if (!item.passed or item.name.len == 0 or (try names.getOrPut(item.name)).found_existing)
            return error.BrowserFixtureEvidenceMismatch;
    }
    if (!names.contains(reaction_timing_case_name))
        return error.BrowserFixtureEvidenceMismatch;
}

fn readWorkerReport(alloc: Allocator, group_dir: std.fs.Dir, absolute_work: []const u8, application: Image) !void {
    const path = try std.fs.path.join(alloc, &.{ absolute_work, "worker-observations", "result.json" });
    const data = try std.fs.cwd().readFileAlloc(alloc, path, evidence_limit);
    try files.writeNew(group_dir, "worker-observations.json", data);
    try freeze.validateWorkerLifecycle(alloc, data, files.hex(application.digest));
}

const MinimumTrack = struct {
    const Size = struct { width: i32, height: i32 };

    window_dpi: u32,
    getminmaxinfo_px: Size,
    constrained_resize_px: Size,

    fn passed(self: MinimumTrack) bool {
        return self.window_dpi > 0 and self.getminmaxinfo_px.width > 0 and
            self.getminmaxinfo_px.height > 0 and std.meta.eql(self.getminmaxinfo_px, self.constrained_resize_px);
    }
};

fn readTransferReport(alloc: Allocator, group_dir: std.fs.Dir, absolute_work: []const u8, application: Image) !void {
    const path = try std.fs.path.join(alloc, &.{ absolute_work, "transfer-observations", "result.json" });
    const data = try std.fs.cwd().readFileAlloc(alloc, path, evidence_limit);
    try files.writeNew(group_dir, "transfer-observations.json", data);
    const info = try std.json.parseFromSliceLeaky(struct {
        passed: bool,
        checks: struct {
            executable_sha256: []const u8,
            narrow_palette_reveals_tab_focus: bool,
            narrow_management_scrolls_to_actions: bool,
            management_native_typeahead_selected_identity: bool,
            palette_minimum_track: MinimumTrack,
            management_minimum_track: MinimumTrack,
            shortcut_minimum_track: MinimumTrack,
            shortcut_wheel_pixels_per_notch: i32,
            shortcut_focused_key_field_wheel_scrolled: bool,
            shortcut_wheel_reached_save_button: bool,
            link_without_browser_explains_failure: bool,
            editor_discard_no_preserved_draft_and_disabled_parent: bool,
            editor_discard_yes_restored_parent: bool,
            editor_long_text_reloaded_after_exit: bool,
            restored_using_import: bool,
            shortcut_duplicate_rejected: bool,
            shortcut_required_rejected: bool,
            shortcut_discard_no_preserved_draft: bool,
            shortcut_discard_yes_preserved_database: bool,
            shortcut_chord_captured: bool,
            shortcut_saved_and_reopened: bool,
            shortcut_live_palette_uses_new_key: bool,
            shortcut_rejected_draft_kept_live_key: bool,
            shortcut_restarted_palette_uses_new_key: bool,
            shortcut_keys_after_restart: bool,
            shortcut_restart_process: process.Result,
            shortcut_commit_failure_count: u32,
            shortcut_commit_failure_notification: []const u8,
            shortcut_commit_failure_kept_draft_and_db: bool,
            shortcut_commit_failure_kept_live_key: bool,
            shortcut_commit_retry_saved_retained_draft: bool,
            shortcut_commit_retry_live_key: bool,
            shortcut_equivalent_spelling_preserved: bool,
            shortcut_key_save_left_item_draft: bool,
            shortcut_item_save_left_conflicting_keys: bool,
            shortcut_slots_swapped_and_unassigned: bool,
            shortcut_item_only_discard_and_scope_cancelled: bool,
            shortcut_slots_after_restart: bool,
        },
    }, alloc, data, .{ .ignore_unknown_fields = true });
    const checks = info.checks;
    const transferred = checks.narrow_palette_reveals_tab_focus and checks.narrow_management_scrolls_to_actions and
        checks.link_without_browser_explains_failure and checks.editor_discard_no_preserved_draft_and_disabled_parent and
        checks.editor_discard_yes_restored_parent and checks.editor_long_text_reloaded_after_exit and checks.restored_using_import;
    const viewports_verified = checks.management_native_typeahead_selected_identity and
        checks.palette_minimum_track.passed() and checks.management_minimum_track.passed() and
        checks.shortcut_minimum_track.passed() and checks.shortcut_wheel_pixels_per_notch > 0 and
        checks.shortcut_focused_key_field_wheel_scrolled and checks.shortcut_wheel_reached_save_button;
    const keys_verified = checks.shortcut_duplicate_rejected and checks.shortcut_required_rejected and
        checks.shortcut_discard_no_preserved_draft and checks.shortcut_discard_yes_preserved_database and
        checks.shortcut_chord_captured and checks.shortcut_saved_and_reopened and checks.shortcut_live_palette_uses_new_key and
        checks.shortcut_rejected_draft_kept_live_key and checks.shortcut_restarted_palette_uses_new_key and
        checks.shortcut_keys_after_restart and checks.shortcut_restart_process.passed();
    const commit_retry_verified = checks.shortcut_commit_failure_count == 2 and
        std.mem.eql(u8, checks.shortcut_commit_failure_notification, "DatabaseLocked") and
        checks.shortcut_commit_failure_kept_draft_and_db and checks.shortcut_commit_failure_kept_live_key and
        checks.shortcut_commit_retry_saved_retained_draft and checks.shortcut_commit_retry_live_key;
    const independent_drafts_verified = checks.shortcut_equivalent_spelling_preserved and
        checks.shortcut_key_save_left_item_draft and checks.shortcut_item_save_left_conflicting_keys and
        checks.shortcut_slots_swapped_and_unassigned and checks.shortcut_item_only_discard_and_scope_cancelled and
        checks.shortcut_slots_after_restart;
    if (!info.passed or !transferred or !viewports_verified or !keys_verified or !commit_retry_verified or
        !independent_drafts_verified or !std.mem.eql(u8, checks.executable_sha256, &files.hex(application.digest)))
        return error.TransferEvidenceMismatch;
}

fn readImeReport(alloc: Allocator, group_dir: std.fs.Dir, absolute_work: []const u8) !void {
    const path = try std.fs.path.join(alloc, &.{ absolute_work, "ime-observations", "result.json" });
    const data = try std.fs.cwd().readFileAlloc(alloc, path, evidence_limit);
    try files.writeNew(group_dir, "ime-observations.json", data);
    const info = try std.json.parseFromSliceLeaky(struct {
        passed: bool,
        restored_open: bool,
        restored_profile: bool,
        restored_original_open: bool,
    }, alloc, data, .{ .ignore_unknown_fields = true });
    if (!info.passed or !info.restored_open or !info.restored_profile or !info.restored_original_open)
        return error.ImeEvidenceMismatch;
}

fn checkOutcome(
    alloc: Allocator,
    group_dir: std.fs.Dir,
    work: []const u8,
    entry: Case,
    application: ?Image,
    report: *Group,
) !void {
    switch (entry.kind) {
        .source => {
            if (report.result.?.stderr_bytes != 0) return error.SourceCheckWroteStandardError;
            const log = try group_dir.readFileAlloc(alloc, "stdout.txt", evidence_limit);
            if (!std.mem.eql(u8, std.mem.trim(u8, log, " \r\n\t"), "PASS")) return error.SourceCheckResultMissing;
        },
        .unit => {
            const log = try group_dir.readFileAlloc(alloc, "stderr.txt", evidence_limit);
            report.unit_names = try freeze.unitTestNames(alloc, log);
            return;
        },
        .browser => try readBrowserReport(alloc, group_dir, work, application.?),
        .ime => try readImeReport(alloc, group_dir, work),
        .startup => try readStartupReport(alloc, group_dir, work, application.?),
        .transfer => try readTransferReport(alloc, group_dir, work, application.?),
        .worker_lifecycle => try readWorkerReport(alloc, group_dir, work, application.?),
    }
    if (report.result.?.stderr_bytes != 0) return error.UnexpectedTestStderr;
}

fn runOne(alloc: Allocator, output: []const u8, project: []const u8, entry: Case, image: Image, application: ?Image, browser_exe: ?[]const u8) !Group {
    const path = try std.fs.path.join(alloc, &.{ output, entry.name });
    try std.fs.cwd().makeDir(path);
    var group_dir = try std.fs.cwd().openDir(path, .{ .no_follow = true });
    defer group_dir.close();
    try group_dir.makeDir("work");
    const work = try std.fs.path.join(alloc, &.{ path, "work" });

    const argv: []const []const u8 = switch (entry.kind) {
        .source => &.{ image.path, "source-check", project },
        .unit => &.{image.path},
        .browser => args: {
            const observations = try std.fs.path.join(alloc, &.{ work, "browser-observations" });
            break :args if (browser_exe) |executable| try alloc.dupe([]const u8, &.{ image.path, application.?.path, observations, executable }) else try alloc.dupe([]const u8, &.{ image.path, application.?.path, observations });
        },
        .ime => &.{ image.path, try std.fs.path.join(alloc, &.{ work, "ime-observations" }) },
        .startup => &.{ image.path, application.?.path, try std.fs.path.join(alloc, &.{ work, "startup-observations" }) },
        .transfer => &.{ image.path, application.?.path, try std.fs.path.join(alloc, &.{ work, "transfer-observations" }) },
        .worker_lifecycle => &.{ image.path, application.?.path, try std.fs.path.join(alloc, &.{ work, "worker-observations" }) },
    };
    const observed = process.observe(alloc, argv, work, group_dir, entry.timeout_ms);
    var report = Group{
        .name = entry.name,
        .session = entry.session,
        .executable_sha256 = files.hex(image.digest),
        .result = observed.result,
        .failure = if (observeFailure(observed)) |failure| @errorName(failure) else null,
        .child_cleanup_failure = if (observed.cleanup_failure) |failure| @errorName(failure) else null,
    };
    if (report.failure == null) checkOutcome(alloc, group_dir, work, entry, application, &report) catch |failure| {
        report.failure = @errorName(failure);
    };
    if (report.failure == null) image.check() catch |failure| {
        report.failure = @errorName(failure);
    };
    if (report.failure == null and entry.kind.usesApplication()) {
        application.?.check() catch |failure| {
            report.failure = @errorName(failure);
        };
    }
    if (report.failure == null and report.child_cleanup_failure == null) group_dir.deleteTree("work") catch |failure| {
        report.work_cleanup_failure = @errorName(failure);
    };
    report.failure = report.failure orelse report.child_cleanup_failure orelse report.work_cleanup_failure;
    report.passed = report.failure == null;
    try process.saveResult(alloc, path, report);
    return report;
}

fn copyLog(dir: std.fs.Dir, name: []const u8, destination: std.fs.File) !void {
    const source = dir.openFile(name, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer source.close();
    var buffer: [8192]u8 = undefined;
    while (true) {
        const count = try source.read(&buffer);
        if (count == 0) break;
        try destination.writeAll(buffer[0..count]);
    }
}

fn replayFailure(alloc: Allocator, output: []const u8, entry: Case, report: Group) !void {
    const path = try std.fs.path.join(alloc, &.{ output, entry.name });
    var dir = try std.fs.cwd().openDir(path, .{ .no_follow = true });
    defer dir.close();
    copyLog(dir, "stdout.txt", std.fs.File.stdout()) catch |err| {
        std.debug.print("{s}: stdout replay failed ({s})\n", .{ entry.name, @errorName(err) });
    };
    copyLog(dir, "stderr.txt", std.fs.File.stderr()) catch |err| {
        std.debug.print("{s}: stderr replay failed ({s})\n", .{ entry.name, @errorName(err) });
    };
    std.debug.print("\n{s}: {s} (deadline {d} ms)\n", .{ entry.name, report.failure.?, entry.timeout_ms });
    if (report.child_cleanup_failure) |failure|
        std.debug.print("{s}: child cleanup failed ({s})\n", .{ entry.name, failure });
    if (report.work_cleanup_failure) |failure|
        std.debug.print("{s}: work directory cleanup failed ({s})\n", .{ entry.name, failure });
}

pub fn run(allocator: Allocator, project_path: []const u8, bin_path: []const u8, output_path: []const u8, args: []const []const u8) !bool {
    var browser_argument: ?[]const u8 = null;
    const selected = try parseSelection(args, .headless, &browser_argument);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const cwd = std.fs.cwd();
    const browser_exe = if (browser_argument) |path| resolved: {
        if (!selected[registry.indexOf("browser-fixture").?]) return error.InvalidTestSelection;
        const absolute = try cwd.realpathAlloc(alloc, path);
        _ = try @import("fixture_browser.zig").Browser.fromPath(absolute);
        break :resolved absolute;
    } else null;
    const project = try cwd.realpathAlloc(alloc, project_path);
    const bin = try cwd.realpathAlloc(alloc, bin_path);
    const tool = try Image.open(alloc, try std.fs.selfExePathAlloc(alloc));
    defer tool.file.close();
    var images: [cases.len]?Image = @splat(null);
    defer for (images) |image| if (image) |loaded| loaded.file.close();
    var application: ?Image = null;
    defer if (application) |image| image.file.close();
    var names: std.ArrayList([]const u8) = .empty;
    for (cases, selected, &images) |entry, include, *image| {
        if (!include) continue;
        image.* = try Image.open(alloc, try std.fs.path.join(alloc, &.{ bin, entry.executable }));
        if (application == null and entry.kind.usesApplication())
            application = try Image.open(alloc, try std.fs.path.join(alloc, &.{ bin, "ChatPalette.exe" }));
        try names.append(alloc, entry.name);
    }

    try cwd.makeDir(output_path);
    const output = try cwd.realpathAlloc(alloc, output_path);
    var results: std.ArrayList(Group) = .empty;
    const gate = try runOne(alloc, output, project, source_gate, tool, null, null);
    try results.append(alloc, gate);
    var failed: ?Case = if (gate.passed) null else source_gate;
    for (cases, images) |entry, image| {
        if (failed != null) break;
        const image_to_run = image orelse continue;
        const group = try runOne(alloc, output, project, entry, image_to_run, application, browser_exe);
        try results.append(alloc, group);
        if (!group.passed) failed = entry;
    }
    try process.saveResult(alloc, output, .{
        .passed = failed == null,
        .coverage = "RegisteredNativeCases",
        .selected = names.items,
        .attempted = results.items,
    });
    if (failed) |entry| replayFailure(alloc, output, entry, results.items[results.items.len - 1]) catch |err| {
        std.debug.print("{s}: log replay failed ({s})\n", .{ entry.name, @errorName(err) });
    };
    return failed == null;
}

test "test inventory validates names and sessions and deduplicates in inventory order" {
    const allocator = std.testing.allocator;
    const named = try list(allocator, &.{ "--name", "tools-unit", "--name", "app-unit", "--name", "tools-unit" });
    defer allocator.free(named);
    try std.testing.expectEqualStrings("app-unit\ntools-unit\n", named);
    const desktop = try list(allocator, &.{ "--session", "desktop" });
    defer allocator.free(desktop);
    try std.testing.expectEqualStrings("browser-fixture\nime-input\nstartup\ntransfer\n", desktop);
    try std.testing.expectEqual(try match(&.{ "--name", "browser-fixture" }, null), try match(&.{ "--name", "brave-fixture" }, null));
    var browser_exe: ?[]const u8 = null;
    const explicit = try parseSelection(&.{ "--name", "browser-fixture", "--session", "desktop", "--browser-exe", "msedge.exe" }, .headless, &browser_exe);
    try std.testing.expect(explicit[registry.indexOf("browser-fixture").?]);
    try std.testing.expectEqualStrings("msedge.exe", browser_exe.?);
    try std.testing.expectError(error.UnknownTestName, list(allocator, &.{ "--name", "not-a-test" }));
    try std.testing.expectError(error.TestOutsideSelectedSession, list(allocator, &.{ "--name", "startup", "--session", "headless" }));
    try std.testing.expectError(error.InvalidTestSelection, list(allocator, &.{ "--session", "headless", "--session", "desktop" }));
}

test "test runs default to headless and desktop cases require explicit selection" {
    const selected = try match(&.{}, .headless);
    for (cases, selected) |entry, include| {
        try std.testing.expectEqual(entry.session == .headless, include);
        if (entry.session == .desktop)
            try std.testing.expectError(error.DesktopSessionRequired, match(&.{ "--name", entry.name }, .headless));
    }
    try std.testing.expectEqual(
        try match(&.{ "--name", "browser-fixture" }, null),
        try match(&.{ "--name", "browser-fixture", "--session", "desktop" }, .headless),
    );
}

test "browser evidence requires distinct passed cases including reaction timing" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const hash = files.hex(files.digest("candidate"));
    var browser_cases: [browser_case_count]BrowserCaseResult = undefined;
    for (&browser_cases, 0..) |*entry, i| entry.* = .{ .name = try std.fmt.allocPrint(alloc, "case {d}", .{i}), .passed = true };
    const report = .{
        .passed = true,
        .sha256 = &hash,
        .browser_exit = @as(u32, 0),
        .second_browser_exit = @as(u32, 0),
        .app_exit = @as(u32, 0),
        .restarted_app_exit = @as(u32, 0),
        .previous_worker_exit = @as(u32, 1),
        .run = &browser_cases,
    };
    var data = try std.json.Stringify.valueAlloc(alloc, report, .{});
    try testing.expectError(error.BrowserFixtureEvidenceMismatch, validateBrowserReport(alloc, data, hash));
    browser_cases[0].name = reaction_timing_case_name;
    data = try std.json.Stringify.valueAlloc(alloc, report, .{});
    try validateBrowserReport(alloc, data, hash);
    browser_cases[1].name = reaction_timing_case_name;
    data = try std.json.Stringify.valueAlloc(alloc, report, .{});
    try testing.expectError(error.BrowserFixtureEvidenceMismatch, validateBrowserReport(alloc, data, hash));
}

test "a child cleanup failure does not displace a timeout or test exit" {
    var observed: process.Observation = .{
        .result = .{ .exit_code = 124, .timed_out = true, .elapsed_ms = 11, .stderr_bytes = 15 },
        .cleanup_failure = error.CouldNotTerminateTestJob,
    };
    try std.testing.expectEqual(error.TestDeadlineExpired, observeFailure(observed).?);
    observed.result.?.timed_out = false;
    observed.result.?.exit_code = 17;
    try std.testing.expectEqual(error.TestExitedUnsuccessfully, observeFailure(observed).?);
    try std.testing.expectEqual(error.CouldNotTerminateTestJob, observed.cleanup_failure.?);
    observed.failure = error.WaitFailed;
    try std.testing.expectEqual(error.WaitFailed, observeFailure(observed).?);
}
