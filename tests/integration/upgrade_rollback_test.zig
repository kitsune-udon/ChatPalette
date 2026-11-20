const std = @import("std");
const product = @import("chatpalette");
const storage = product.storage;
const windows = product.windows;
const win = windows.api;
const support = @import("tool_support");
const files = support.files;
const process = support.process;
const zip = support.zip;
const transfer = @import("transfer_test.zig");
const ui = @import("clean_install_scenario.zig");

const allocator = std.heap.page_allocator;
const app_name = "ChatPalette.exe";
const db_path = "data/settings.db";
const original_name = "更新前の共通弾幕";
const original_text = "更新前の本文👏";
const migrated_name = "更新後の共通弾幕";
const migrated_text = "更新・切り戻しの合成本文";
const fixture_profile = "更新試験用の配信者";
const profile_item = "配信者別の合成弾幕";
const profile_text_value = "配信者向けの本文🌙";
const archive_limit = 64 * 1024 * 1024;

const Phase = enum {
    verify_baseline,
    verify_candidate,
    baseline_registration,
    back_up_baseline,
    candidate_save,
    candidate_restart,
    restore_backup,
    restored_baseline_start,
    verify_preservation,
    cleanup,
    complete,
};

const Archive = struct {
    version: ?[]const u8 = null,
    expected_sha256: ?files.HexDigest = null,
    sha256: ?files.HexDigest = null,
    executable_sha256: ?files.HexDigest = null,
};

const Trial = struct { phase: Phase, result: process.Result };

const Report = struct {
    phase: Phase = .verify_baseline,
    failure: ?[]const u8 = null,
    baseline: Archive = .{},
    candidate: Archive = .{},
    trials: std.ArrayList(Trial) = .empty,
    baseline_database_sha256: ?files.HexDigest = null,
    updated_database_sha256: ?files.HexDigest = null,
    restored_database_sha256: ?files.HexDigest = null,
    original_and_backup_preserved: bool = false,
    updated_data_preserved: bool = false,
};

const Validation = struct {
    Version: []const u8,
    ArchiveSHA256: []const u8,
    ArchiveManifestSHA256: []const u8,
    ExecutableSHA256: []const u8,
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const args = try std.process.argsAlloc(scratch);
    if (args.len != 4) return error.ExpectedBaselineCandidateAndNewResultDirectory;
    const cwd = std.fs.cwd();
    try cwd.makeDir(args[3]);
    const output = try cwd.realpathAlloc(scratch, args[3]);
    var destination = try cwd.openDir(output, .{ .no_follow = true });
    defer destination.close();
    var report: Report = .{};
    verify(scratch, args[1], args[2], output, destination, &report) catch |failure| {
        report.failure = @errorName(failure);
    };
    try process.saveResult(allocator, output, .{
        .passed = report.failure == null,
        .phase = report.phase,
        .failure = report.failure,
        .baseline = report.baseline,
        .candidate = report.candidate,
        .trials = report.trials.items,
        .baseline_database_sha256 = report.baseline_database_sha256,
        .updated_database_sha256 = report.updated_database_sha256,
        .restored_database_sha256 = report.restored_database_sha256,
        .original_and_backup_preserved = report.original_and_backup_preserved,
        .updated_data_preserved = report.updated_data_preserved,
    });
    if (report.failure) |failure| {
        std.debug.print("更新・切り戻し試験に失敗しました。{s}: {s}\n", .{ @tagName(report.phase), failure });
        std.process.exit(1);
    }
    try std.fs.File.stdout().writeAll("更新・切り戻し試験に合格しました。\n");
}

fn subdirectory(parent: std.fs.Dir, name: []const u8) !std.fs.Dir {
    try parent.makeDir(name);
    return parent.openDir(name, .{ .iterate = true, .no_follow = true });
}

const Folder = struct {
    dir: std.fs.Dir,
    path: []const u8,
    exe: []const u8,
    db: []const u8,

    fn create(scratch: std.mem.Allocator, parent: std.fs.Dir, path: []const u8, name: []const u8) !Folder {
        const absolute = try std.fs.path.join(scratch, &.{ path, name });
        const exe = try std.fs.path.join(scratch, &.{ absolute, app_name });
        const db = try std.fs.path.join(scratch, &.{ absolute, db_path });
        return .{ .dir = try subdirectory(parent, name), .path = absolute, .exe = exe, .db = db };
    }
};

fn verify(scratch: std.mem.Allocator, baseline_zip: []const u8, candidate_zip: []const u8, output: []const u8, destination: std.fs.Dir, report: *Report) !void {
    var work = try subdirectory(destination, "work");
    {
        defer work.close();
        const path = try std.fs.path.join(scratch, &.{ output, "work" });
        var baseline = try Folder.create(scratch, work, path, "baseline");
        defer baseline.dir.close();
        try extract(scratch, baseline_zip, baseline.dir, &report.baseline);
        report.phase = .verify_candidate;
        var candidate = try Folder.create(scratch, work, path, "candidate");
        defer candidate.dir.close();
        try extract(scratch, candidate_zip, candidate.dir, &report.candidate);
        try verifyInstallations(scratch, destination, work, path, baseline, candidate, report);
    }

    report.phase = .cleanup;
    try destination.deleteTree("work");
    report.phase = .complete;
}

fn extract(scratch: std.mem.Allocator, path: []const u8, directory: std.fs.Dir, report: *Archive) !void {
    if (!std.ascii.eqlIgnoreCase(std.fs.path.extension(path), ".zip")) return error.InvalidArchiveExtension;
    const sidecar = try std.fmt.allocPrint(scratch, "{s}.validation.json", .{path[0 .. path.len - 4]});
    const data = try std.fs.cwd().readFileAlloc(scratch, sidecar, 64 * 1024);
    const validation = try std.json.parseFromSliceLeaky(Validation, scratch, data, .{ .ignore_unknown_fields = true });
    report.version = validation.Version;
    var expected: files.Digest = undefined;
    _ = try std.fmt.hexToBytes(&expected, validation.ArchiveSHA256);
    report.expected_sha256 = files.hex(expected);

    const absolute = try std.fs.cwd().realpathAlloc(scratch, path);
    const archive = try files.openImmutable(scratch, absolute);
    defer archive.close();
    if (try archive.getEndPos() > archive_limit) return error.ArchiveTooLarge;
    const observed = try files.fileDigest(archive);
    report.sha256 = files.hex(observed);
    if (!std.mem.eql(u8, &expected, &observed)) return error.ArchiveDigestMismatch;

    try archive.seekTo(0);
    var buffer: [8192]u8 = undefined;
    var reader = archive.reader(&buffer);
    try std.zip.extract(directory, &reader, .{});
    const manifest = try directory.readFileAlloc(scratch, zip.manifest_name, 4 * 1024 * 1024);
    if (!std.ascii.eqlIgnoreCase(&files.hex(files.digest(manifest)), validation.ArchiveManifestSHA256))
        return error.ArchiveManifestDigestMismatch;
    _ = try zip.verify(scratch, archive, manifest);
    try zip.verifyTree(scratch, directory, manifest);
    if (directory.access("data", .{})) |_| return error.ArchiveContainsSettings else |failure| {
        if (failure != error.FileNotFound) return failure;
    }
    const version = std.mem.trim(u8, try directory.readFileAlloc(scratch, "VERSION", 256), "\r\n\t ");
    if (version.len == 0 or !std.mem.eql(u8, version, validation.Version)) return error.ArchiveVersionMismatch;
    report.executable_sha256 = files.hex(try files.readDigest(directory, app_name));
    if (!std.ascii.eqlIgnoreCase(&report.executable_sha256.?, validation.ExecutableSHA256))
        return error.ArchiveExecutableDigestMismatch;
}

fn verifyInstallations(scratch: std.mem.Allocator, destination: std.fs.Dir, work: std.fs.Dir, path: []const u8, baseline: Folder, candidate: Folder, report: *Report) !void {
    var logs = try subdirectory(destination, "logs");
    defer logs.close();
    var keys = storage.default_shortcut_keys;
    keys[@intFromEnum(storage.Action.palette)] = "^+q";
    keys[@intFromEnum(storage.Action.profile2)] = "";

    report.phase = .baseline_registration;
    try runTrial(scratch, baseline, logs, keys, report);
    report.baseline_database_sha256 = files.hex(try files.readDigest(baseline.dir, db_path));
    report.phase = .back_up_baseline;
    var backup = try Folder.create(scratch, work, path, "backup");
    defer backup.dir.close();
    const before = try snapshot(scratch, baseline.dir, backup.dir);
    if (!equalSnapshots(before, try snapshot(scratch, backup.dir, null))) return error.BackupCopyMismatch;

    var baseline_data = try backup.dir.openDir("data", .{ .iterate = true, .no_follow = true });
    defer baseline_data.close();
    var candidate_data = try subdirectory(candidate.dir, "data");
    defer candidate_data.close();
    const data_before = try snapshot(scratch, baseline_data, candidate_data);
    if (!equalSnapshots(data_before, try snapshot(scratch, candidate_data, null))) return error.SettingsCopyMismatch;

    report.phase = .candidate_save;
    try runTrial(scratch, candidate, logs, keys, report);
    report.phase = .candidate_restart;
    try runTrial(scratch, candidate, logs, keys, report);
    const data_after = try snapshot(scratch, candidate_data, null);
    report.updated_database_sha256 = files.hex(try files.readDigest(candidate.dir, db_path));
    if (std.mem.eql(u8, &report.baseline_database_sha256.?, &report.updated_database_sha256.?))
        return error.CandidateDidNotPersistEdit;

    report.phase = .restore_backup;
    var restored = try Folder.create(scratch, work, path, "restored");
    defer restored.dir.close();
    if (!equalSnapshots(before, try snapshot(scratch, backup.dir, restored.dir)) or
        !equalSnapshots(before, try snapshot(scratch, restored.dir, null))) return error.BackupRestoreMismatch;
    report.phase = .restored_baseline_start;
    try runTrial(scratch, restored, logs, keys, report);
    report.restored_database_sha256 = files.hex(try files.readDigest(restored.dir, db_path));

    report.phase = .verify_preservation;
    report.original_and_backup_preserved =
        equalSnapshots(before, try snapshot(scratch, baseline.dir, null)) and
        equalSnapshots(before, try snapshot(scratch, backup.dir, null)) and
        equalSnapshots(before, try snapshot(scratch, restored.dir, null));
    report.updated_data_preserved = equalSnapshots(data_after, try snapshot(scratch, candidate_data, null));
    if (!report.original_and_backup_preserved or !report.updated_data_preserved) return error.RollbackChangedSavedData;
}

const Entry = struct { path: []const u8, digest: files.Digest };

fn snapshot(scratch: std.mem.Allocator, origin: std.fs.Dir, copy: ?std.fs.Dir) ![]Entry {
    var walk = try origin.walk(scratch);
    defer walk.deinit();
    var entries: std.ArrayList(Entry) = .empty;
    while (try walk.next()) |entry| {
        switch (entry.kind) {
            .directory => if (copy) |dest| try dest.makeDir(entry.path),
            .file => {
                const digest = try files.readDigest(origin, entry.path);
                if (copy) |dest| try origin.copyFile(entry.path, dest, entry.path, .{});
                try entries.append(scratch, .{ .path = try scratch.dupe(u8, entry.path), .digest = digest });
            },
            else => return error.UnexpectedBackupEntry,
        }
    }
    std.mem.sort(Entry, entries.items, {}, struct {
        fn less(_: void, first: Entry, second: Entry) bool {
            return std.mem.lessThan(u8, first.path, second.path);
        }
    }.less);
    return entries.items;
}

fn equalSnapshots(first: []const Entry, second: []const Entry) bool {
    if (first.len != second.len) return false;
    for (first, second) |a, b|
        if (!std.mem.eql(u8, a.path, b.path) or !std.mem.eql(u8, &a.digest, &b.digest)) return false;
    return true;
}

fn runTrial(scratch: std.mem.Allocator, folder: Folder, logs: std.fs.Dir, keys: transfer.ShortcutKeys, report: *Report) !void {
    var output = try subdirectory(logs, @tagName(report.phase));
    defer output.close();
    var trial: transfer.AppTrial = .{ .exe = folder.exe, .cwd = folder.path, .output = output };
    const thread = try std.Thread.spawn(.{}, transfer.AppTrial.run, .{&trial});
    const seed = report.phase == .baseline_registration;
    const edit = report.phase == .candidate_save;
    const changed = report.phase == .candidate_restart;
    const scenario = verifyCompatibilityControls(scratch, folder.path, folder.exe, keys, seed, edit, changed);
    thread.join();
    const result = try trial.result;
    try report.trials.append(scratch, .{ .phase = report.phase, .result = result });
    try scenario;
    if (!result.passed()) return error.ProductDidNotExitCleanly;
    try checkDatabase(folder.db, keys, edit or changed);
}

fn checkDatabase(db: []const u8, keys: transfer.ShortcutKeys, updated: bool) !void {
    var saved = try transfer.readDatabase(db);
    defer saved.deinit();
    const data = saved.data;
    if (data.profiles.len != 1 or data.shared_items.len != 1 or data.profiles[0].items.len != 1)
        return error.DatabaseFixtureMissing;
    const shared = data.shared_items[0];
    const scoped = data.profiles[0].items[0];
    if (!std.mem.eql(u8, data.profiles[0].name, fixture_profile) or
        !std.mem.eql(u8, scoped.name, profile_item) or !std.mem.eql(u8, scoped.text, profile_text_value) or
        !std.mem.eql(u8, shared.name, if (updated) migrated_name else original_name) or
        !std.mem.eql(u8, shared.text, if (updated) migrated_text else original_text)) return error.DatabaseTextMismatch;
    for (keys, data.preferences.shortcut_keys) |want, actual|
        if (!std.mem.eql(u8, want, actual)) return error.DatabaseBindingMismatch;
}

fn selectCompatibilityScope(manager: win.HWND, index: usize) !void {
    const scope = try ui.control(manager, 223);
    if (try ui.message(scope, win.CB_SETCURSEL, index, 0) != @as(win.LRESULT, @intCast(index)))
        return error.CannotSelectExpectedScope;
    _ = try ui.message(manager, win.WM_COMMAND, 223 | (@as(win.WPARAM, win.CBN_SELCHANGE) << 16), @bitCast(windows.number(scope)));
}

fn compatibilityEditor(app: transfer.OwnedProduct, manager: win.HWND, add: bool) !win.HWND {
    if (!add) {
        const list = try ui.control(manager, 224);
        if (try ui.message(list, win.LVM_GETITEMCOUNT, 0, 0) != 1) return error.SavedItemCountMismatch;
        _ = try ui.message(list, win.WM_KEYDOWN, win.VK_HOME, 0);
        _ = try ui.message(list, win.WM_KEYUP, win.VK_HOME, 0);
        if (try ui.message(list, win.LVM_GETNEXTITEM, std.math.maxInt(win.WPARAM), win.LVNI_SELECTED) != 0)
            return error.CannotSelectSavedItem;
    }
    try ui.click(manager, if (add) 227 else 228);
    return ui.waitWindow(windows.wide("ChatPalette.LibraryEditor"), null, app.pid);
}

fn storeCompatibilityItem(app: transfer.OwnedProduct, editor: win.HWND, name: []const u8, body: []const u8) !void {
    try ui.setText(try ui.control(editor, 220), name);
    try ui.setText(try ui.control(editor, 221), body);
    try ui.click(editor, win.IDOK);
    try ui.waitClosed(editor, app.pid);
}

fn checkCompatibilityItem(scratch: std.mem.Allocator, editor: win.HWND, name: []const u8, body: []const u8) !void {
    if (!std.mem.eql(u8, try ui.readText(scratch, try ui.control(editor, 220)), name) or
        !std.mem.eql(u8, try ui.readText(scratch, try ui.control(editor, 221)), body)) return error.ProductItemTextMismatch;
}

fn verifyCompatibilityControls(scratch: std.mem.Allocator, install: []const u8, executable: []const u8, expected_keys: transfer.ShortcutKeys, seed: bool, edit: bool, changed: bool) !void {
    const app = try transfer.OwnedProduct.wait(scratch, install, executable);
    defer _ = win.CloseHandle(app.handle);
    errdefer app.requestClose() catch {};
    const manager = try ui.management(app.host, app.pid);
    try selectCompatibilityScope(manager, 0);
    if (seed) {
        const shared = try compatibilityEditor(app, manager, true);
        try storeCompatibilityItem(app, shared, original_name, original_text);
        try ui.click(manager, 225);
        const profile = try ui.waitWindow(windows.wide("ChatPalette.LibraryEditor"), null, app.pid);
        try ui.setText(try ui.control(profile, 220), fixture_profile);
        try ui.click(profile, win.IDOK);
        try ui.waitClosed(profile, app.pid);
        try selectCompatibilityScope(manager, 1);
        const scoped = try compatibilityEditor(app, manager, true);
        try storeCompatibilityItem(app, scoped, profile_item, profile_text_value);
    } else {
        const shared = try compatibilityEditor(app, manager, false);
        try checkCompatibilityItem(scratch, shared, if (changed) migrated_name else original_name, if (changed) migrated_text else original_text);
        if (edit) {
            try storeCompatibilityItem(app, shared, migrated_name, migrated_text);
        } else {
            try ui.click(shared, win.IDCANCEL);
            try ui.waitClosed(shared, app.pid);
        }
        try selectCompatibilityScope(manager, 1);
        const shown_profile = try ui.readText(scratch, try ui.control(manager, 223));
        if (!std.mem.eql(u8, shown_profile, fixture_profile)) return error.ProductProfileMismatch;
        const scoped = try compatibilityEditor(app, manager, false);
        try checkCompatibilityItem(scratch, scoped, profile_item, profile_text_value);
        try ui.click(scoped, win.IDCANCEL);
        try ui.waitClosed(scoped, app.pid);
    }

    const key_editor = try transfer.openShortcutEditor(app, manager);
    errdefer transfer.cleanupShortcutEditor(app, key_editor);
    if (seed) {
        try ui.setText(try transfer.shortcutField(key_editor, .palette), expected_keys[@intFromEnum(storage.Action.palette)]);
        try ui.setText(try transfer.shortcutField(key_editor, .profile2), "");
        try transfer.postDialogCommand(key_editor, app.pid, win.IDOK);
        try transfer.synchronizeHost(app.host, app.pid);
        if (win.IsWindowVisible(key_editor) != 0) {
            try transfer.waitShortcutStatus(scratch, key_editor, transfer.shortcut_key_status_id, "キー設定を保存し");
            try transfer.expectShortcutFields(scratch, key_editor, expected_keys);
        }
    } else {
        try transfer.expectShortcutFields(scratch, key_editor, expected_keys);
    }
    if (win.IsWindowVisible(key_editor) != 0) {
        try transfer.postDialogCommand(key_editor, app.pid, win.IDCANCEL);
        try transfer.expectShortcutEditorClosed(app, manager, key_editor);
    }
    try app.quit();
}
