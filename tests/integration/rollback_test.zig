const std = @import("std");
const windows = @import("chatpalette").windows;
const win = windows.api;
const storage = @import("chatpalette").storage;
const max_file_bytes = @import("chatpalette").max_file_bytes;
const process = @import("tool_support").process;
const files = @import("tool_support").files;

const fixed_zip_sha = "7e071f90a371964fe8cdf244d4730eaae9473430caad2392024dded5afd56b19";
const app_name = "ChatPalette.exe";
const old_fixture = "rollback-fixture.ahk";
const changed_name = "更新後の弾幕🎉";
const changed_body = "更新後も残る本文📝";
const added_profile_name = "候補版で追加した配信者";
const limit_ms = 30000;
const allocator = std.heap.page_allocator;

const Trial = struct { name: []const u8, result: process.Result };
const Entry = struct { path: []const u8, sha256: files.HexDigest, size: u64 };
const Report = struct {
    failure: ?[]const u8 = null,
    legacy_zip_sha256: ?files.HexDigest = null,
    legacy_ahk_sha256: ?files.HexDigest = null,
    candidate_sha256: ?files.HexDigest = null,
    original_data: ?[]const Entry = null,
    changed_data: ?[]const Entry = null,
    unchanged_data: ?[]const Entry = null,
    rolled_back_data: ?[]const Entry = null,
    candidate_ui_saved: bool = false,
    original_data_preserved: bool = false,
    changed_values_read_by_legacy: bool = false,
    unchanged_values_read_by_legacy: bool = false,
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const args = try std.process.argsAlloc(scratch);
    if (args.len != 5) {
        std.debug.print("chatpalette-rollback-test <0.8.0 ZIP> <AutoHotkey64.exe> <ChatPalette.exe> <新規の結果フォルダー>\n", .{});
        std.process.exit(2);
    }
    const cwd = std.fs.cwd();
    const legacy_zip = try cwd.realpathAlloc(scratch, args[1]);
    const ahk = try cwd.realpathAlloc(scratch, args[2]);
    const candidate = try cwd.realpathAlloc(scratch, args[3]);
    if (!std.ascii.eqlIgnoreCase(std.fs.path.basename(ahk), "AutoHotkey64.exe") or
        !std.ascii.eqlIgnoreCase(std.fs.path.basename(candidate), app_name)) return error.UnexpectedExecutableName;
    try cwd.makeDir(args[4]);
    const output = try cwd.realpathAlloc(scratch, args[4]);
    var dest = try cwd.openDir(output, .{});
    defer dest.close();

    var report: Report = .{};
    var trials: std.ArrayList(Trial) = .empty;
    verify(scratch, legacy_zip, ahk, candidate, output, dest, &report, &trials) catch |failure| {
        report.failure = @errorName(failure);
    };
    try process.saveResult(allocator, output, .{
        .passed = report.failure == null,
        .scope = "0.8.0 recovery and update compatibility",
        .checks = report,
        .trials = trials.items,
    });
    if (report.failure) |failure| {
        std.debug.print("更新・切り戻し試験に失敗しました。{s}\n", .{failure});
        std.process.exit(1);
    }
    std.debug.print("更新・切り戻しの互換試験に合格しました。\n", .{});
}

fn verify(scratch: std.mem.Allocator, legacy_zip: []const u8, ahk: []const u8, candidate: []const u8, output: []const u8, dest: std.fs.Dir, report: *Report, trials: *std.ArrayList(Trial)) !void {
    const zip_file = try files.openImmutable(scratch, legacy_zip);
    defer zip_file.close();
    report.legacy_zip_sha256 = files.hex(try files.fileDigest(zip_file));
    if (!std.mem.eql(u8, &report.legacy_zip_sha256.?, fixed_zip_sha)) return error.LegacyArchiveDigestMismatch;
    const ahk_file = try files.openImmutable(scratch, ahk);
    defer ahk_file.close();
    report.legacy_ahk_sha256 = files.hex(try files.fileDigest(ahk_file));
    const candidate_file = try files.openImmutable(scratch, candidate);
    defer candidate_file.close();
    const candidate_bytes = try candidate_file.readToEndAlloc(scratch, 64 * 1024 * 1024);
    report.candidate_sha256 = files.hex(files.digest(candidate_bytes));

    var logs = try makeDir(dest, "logs");
    defer logs.close();
    var original = try Folder.open(scratch, dest, output, "original");
    defer original.dir.close();
    try unpackLegacy(zip_file, original.dir);
    try assertAbsent(original.dir, "data");
    const before_path = try join(scratch, output, "legacy-before.json");
    try runLegacy(scratch, logs, trials, ahk, original, "01-legacy-seed", "seed", before_path);
    var before = try storage.readJson(scratch, before_path);
    defer before.deinit();
    try verifySeed(before.data);

    var changed = try Folder.open(scratch, dest, output, "changed");
    defer changed.dir.close();
    var unchanged = try Folder.open(scratch, dest, output, "unchanged");
    defer unchanged.dir.close();
    for ([_]Folder{ changed, unchanged }) |folder| {
        try files.writeNew(folder.dir, app_name, candidate_bytes);
        if (!std.mem.eql(u8, &report.candidate_sha256.?, &files.hex(try files.readDigest(folder.dir, app_name)))) return error.ExecutablesDiffer;
    }
    var original_data = try original.dir.openDir("data", .{ .iterate = true, .no_follow = true });
    defer original_data.close();
    var changed_data = try makeDir(changed.dir, "data");
    defer changed_data.close();
    var unchanged_data = try makeDir(unchanged.dir, "data");
    defer unchanged_data.close();
    report.original_data = try manifest(scratch, original_data, changed_data, unchanged_data);
    if (!entriesEqual(report.original_data.?, try manifest(scratch, changed_data, null, null)) or
        !entriesEqual(report.original_data.?, try manifest(scratch, unchanged_data, null, null))) return error.DataCopyMismatch;

    const unchanged_exe = try join(scratch, unchanged.path, app_name);
    try run(scratch, logs, trials, "02-zig-unchanged", unchanged, &.{ unchanged_exe, "--smoke" });
    report.unchanged_data = try manifest(scratch, unchanged_data, null, null);
    if (!entriesEqual(report.original_data.?, report.unchanged_data.?)) return error.UnchangedDataWasWritten;

    try driveCandidate(scratch, logs, trials, changed);
    report.changed_data = try manifest(scratch, changed_data, null, null);
    if (entriesEqual(report.original_data.?, report.changed_data.?)) return error.CandidateDidNotSave;
    report.candidate_ui_saved = true;
    report.original_data_preserved = entriesEqual(report.original_data.?, try manifest(scratch, original_data, null, null));
    if (!report.original_data_preserved) return error.OriginalDataWasWritten;

    // Open the exact directories written by the candidate with the unmodified legacy entry.
    try unpackLegacy(zip_file, changed.dir);
    try unpackLegacy(zip_file, unchanged.dir);
    for ([_]Folder{ changed, unchanged }, [_][]const u8{ "04-old-open-changed", "05-old-open-unchanged" }) |folder, name| {
        try run(scratch, logs, trials, name, folder, &.{ ahk, "/ErrorStdOut=UTF-8", try join(scratch, folder.path, "main.ahk"), "--smoke" });
    }
    const after_path = try join(scratch, output, "legacy-after-change.json");
    const still_path = try join(scratch, output, "legacy-after-no-change.json");
    try runLegacy(scratch, logs, trials, ahk, changed, "06-old-read-changed", "read", after_path);
    try runLegacy(scratch, logs, trials, ahk, unchanged, "07-old-read-unchanged", "read", still_path);
    var after = try storage.readJson(scratch, after_path);
    defer after.deinit();
    var still = try storage.readJson(scratch, still_path);
    defer still.deinit();
    try verifyChanged(before.data, after.data);
    report.changed_values_read_by_legacy = true;
    if (!before.data.eql(still.data)) return error.UnchangedValuesDiffer;
    report.unchanged_values_read_by_legacy = true;
    report.rolled_back_data = try manifest(scratch, changed_data, null, null);
    if (!entriesEqual(report.changed_data.?, report.rolled_back_data.?) or
        !entriesEqual(report.unchanged_data.?, try manifest(scratch, unchanged_data, null, null))) return error.LegacyReadChangedDatabase;
}

fn verifySeed(data: storage.Data) !void {
    const prefs = data.preferences;
    if (!equal(prefs.input_profile_id, "Caster") or prefs.auto_mode or prefs.reaction_kind != 1 or
        prefs.reaction_count != 10 or prefs.reaction_interval_ms != 250) return error.UnexpectedSeedPreferences;
    var keys = storage.default_shortcut_keys;
    keys[0] = "^+q";
    for (keys, prefs.shortcut_keys) |want, found| if (!equal(want, found)) return error.UnexpectedSeedKeys;
    if (data.profiles.len != 1 or data.shared_items.len != 2 or data.registrations.len != 1) return error.UnexpectedSeedCounts;
    const profile = data.profiles[0];
    if (!equal(profile.id, "Caster") or !equal(profile.name, "合成配信者") or !equal(profile.channel, "/@synthetic") or
        profile.items.len != 1 or !itemEqual(profile.items[0], "scoped", "配信者の弾幕", "既存の配信者本文👏", 2))
        return error.UnexpectedSeedProfile;
    if (!itemEqual(data.shared_items[0], "A", "変更前の名前", "変更前の本文🌐", 1) or
        !itemEqual(data.shared_items[1], "a", "無変更の弾幕", "そのまま残す本文🌙", 0)) return error.UnexpectedSeedItems;
    const registration = data.registrations[0];
    if (!equal(registration.browser, "edge") or std.mem.indexOf(u8, registration.payload_json, "\"extra\":1.2500") == null or
        std.mem.indexOf(u8, registration.payload_json, "\"synthetic\":true") == null) return error.UnexpectedSeedRegistration;
}

fn verifyChanged(before: storage.Data, after: storage.Data) !void {
    if (after.shared_items.len != 2 or after.profiles.len != 2) return error.UnexpectedEditedCounts;
    if (!itemEqual(after.shared_items[0], "A", changed_name, changed_body, 1)) return error.LegacyDidNotReadItemEdit;
    const added = after.profiles[1];
    if (added.id.len == 0 or equal(added.id, before.profiles[0].id) or !equal(added.name, added_profile_name) or
        added.items.len != 0 or added.channel.len != 0) return error.LegacyDidNotReadNewProfile;
    const keep = [_]storage.Item{ before.shared_items[0], after.shared_items[1] };
    var unchanged = after;
    unchanged.shared_items = &keep;
    unchanged.profiles = after.profiles[0..1];
    if (!before.eql(unchanged)) return error.LegacyDidNotPreserveExistingValues;
}

fn itemEqual(item: storage.Item, id: []const u8, name: []const u8, text: []const u8, slot: u8) bool {
    return equal(item.id, id) and equal(item.name, name) and equal(item.text, text) and item.slot == slot;
}

fn equal(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn entriesEqual(a: []const Entry, b: []const Entry) bool {
    if (a.len != b.len) return false;
    for (a, b) |first, second| {
        if (!equal(first.path, second.path) or first.size != second.size or !equal(&first.sha256, &second.sha256)) return false;
    }
    return true;
}

fn manifest(scratch: std.mem.Allocator, origin: std.fs.Dir, first: ?std.fs.Dir, second: ?std.fs.Dir) ![]const Entry {
    var walk = try origin.walk(scratch);
    defer walk.deinit();
    var entries: std.ArrayList(Entry) = .empty;
    while (try walk.next()) |entry| {
        if (entry.kind == .directory) {
            if (first) |dir| try dir.makeDir(entry.path);
            if (second) |dir| try dir.makeDir(entry.path);
            continue;
        }
        if (entry.kind != .file) return error.UnexpectedDataEntry;
        const path = try scratch.dupe(u8, entry.path);
        const bytes = try origin.readFileAlloc(scratch, path, max_file_bytes);
        defer scratch.free(bytes);
        if (first) |dir| try files.writeNew(dir, path, bytes);
        if (second) |dir| try files.writeNew(dir, path, bytes);
        try entries.append(scratch, .{ .path = path, .sha256 = files.hex(files.digest(bytes)), .size = bytes.len });
    }
    std.mem.sort(Entry, entries.items, {}, struct {
        fn less(_: void, a: Entry, b: Entry) bool {
            return std.mem.lessThan(u8, a.path, b.path);
        }
    }.less);
    for (entries.items) |entry| if (equal(entry.path, "settings.db")) return entries.items;
    return error.SettingsDatabaseMissing;
}

const Folder = struct {
    dir: std.fs.Dir,
    path: []const u8,

    fn open(scratch: std.mem.Allocator, parent: std.fs.Dir, output: []const u8, name: []const u8) !Folder {
        const path = try join(scratch, output, name);
        return .{ .dir = try makeDir(parent, name), .path = path };
    }
};

fn join(scratch: std.mem.Allocator, directory: []const u8, name: []const u8) ![]const u8 {
    return std.fs.path.join(scratch, &.{ directory, name });
}

fn makeDir(parent: std.fs.Dir, name: []const u8) !std.fs.Dir {
    try parent.makeDir(name);
    return parent.openDir(name, .{ .iterate = true, .no_follow = true });
}

fn assertAbsent(dir: std.fs.Dir, name: []const u8) !void {
    dir.access(name, .{}) catch |failure| if (failure == error.FileNotFound) return else return failure;
    return error.SyntheticDirectoryNotEmpty;
}

fn unpackLegacy(archive: std.fs.File, dest: std.fs.Dir) !void {
    try archive.seekTo(0);
    var scratch: [64 * 1024]u8 = undefined;
    var reader = archive.reader(&scratch);
    // The pinned Windows release archive contains backslashes in entry names.
    try std.zip.extract(dest, &reader, .{ .allow_backslashes = true });
    const version = try dest.readFileAlloc(allocator, "VERSION", 64);
    defer allocator.free(version);
    if (!equal(std.mem.trim(u8, version, " \t\r\n"), "0.8.0")) return error.UnexpectedLegacyVersion;
    try files.writeNew(dest, old_fixture, legacy_ahk);
}

fn runLegacy(scratch: std.mem.Allocator, logs: std.fs.Dir, trials: *std.ArrayList(Trial), ahk: []const u8, folder: Folder, name: []const u8, phase: []const u8, export_path: []const u8) !void {
    try run(scratch, logs, trials, name, folder, &.{ ahk, "/ErrorStdOut=UTF-8", try join(scratch, folder.path, old_fixture), phase, export_path });
}

fn run(scratch: std.mem.Allocator, logs: std.fs.Dir, trials: *std.ArrayList(Trial), name: []const u8, folder: Folder, argv: []const []const u8) !void {
    var log = try makeDir(logs, name);
    defer log.close();
    const result = try process.run(allocator, argv, folder.path, log, limit_ms);
    try trials.append(scratch, .{ .name = name, .result = result });
    if (!result.passed()) return error.ProcessTrialFailed;
}

const UiTrial = struct {
    path: []const u8,
    exe: []const u8,
    log: std.fs.Dir,
    result: anyerror!process.Result = error.NotStarted,

    fn runApp(self: *UiTrial) void {
        self.result = process.run(allocator, &.{ self.exe, "--quiet" }, self.path, self.log, limit_ms);
    }
};

fn driveCandidate(scratch: std.mem.Allocator, logs: std.fs.Dir, trials: *std.ArrayList(Trial), folder: Folder) !void {
    const name = "03-zig-editor";
    var log = try makeDir(logs, name);
    defer log.close();
    var trial: UiTrial = .{ .path = folder.path, .exe = try join(scratch, folder.path, app_name), .log = log };
    const thread = try std.Thread.spawn(.{}, UiTrial.runApp, .{&trial});
    const edited = editCandidate(scratch, trial.exe, folder.path);
    thread.join();
    const result = try trial.result;
    try trials.append(scratch, .{ .name = name, .result = result });
    try edited;
    if (!result.passed()) return error.CandidateEditorExitFailed;
}

fn editCandidate(scratch: std.mem.Allocator, exe: []const u8, directory: []const u8) !void {
    const lower_directory = try std.ascii.allocLowerString(scratch, directory);
    const host_name = try std.fmt.allocPrint(scratch, "ChatPalette.{s}", .{files.hex(files.digest(lower_directory))});
    const title = try std.unicode.utf8ToUtf16LeAllocZ(scratch, host_name);
    const host = try waitWindow(windows.wide("ChatPalette.Host"), title, 0, false);
    const owner = try matchProcessImage(host, exe);
    defer _ = win.CloseHandle(owner.process);
    errdefer if (windowPid(host) == owner.pid) {
        _ = win.PostMessageW(host, win.WM_CLOSE, 0, 0);
    };

    _ = try send(host, win.WM_APP + 12, 0, 0);
    const management = try waitWindow(windows.wide("ChatPalette.Management"), null, owner.pid, true);
    const scope_id = 223;
    const scope = try control(management, scope_id);
    if (try send(scope, win.CB_SETCURSEL, 0, 0) != 0) return error.CannotSelectSharedLibrary;
    _ = try send(management, win.WM_COMMAND, scope_id | (@as(win.WPARAM, win.CBN_SELCHANGE) << 16), childParameter(scope));
    const list = try control(management, 224);
    if (try send(list, win.LVM_GETITEMCOUNT, 0, 0) != 2) return error.CandidateSharedLibraryMissing;
    _ = try send(list, win.WM_KEYDOWN, win.VK_HOME, 0);
    _ = try send(list, win.WM_KEYUP, win.VK_HOME, 0);
    if ((try send(list, win.LVM_GETNEXTITEM, std.math.maxInt(win.WPARAM), win.LVNI_SELECTED)) != 0)
        return error.CannotSelectFirstLegacyItem;
    _ = try send(management, win.WM_COMMAND, 228, childParameter(try control(management, 228)));
    const details = try waitWindow(windows.wide("ChatPalette.LibraryEditor"), null, owner.pid, true);
    try setText(try control(details, 220), changed_name);
    try setText(try control(details, 221), changed_body);
    _ = try send(details, win.WM_COMMAND, win.IDOK, childParameter(try control(details, win.IDOK)));
    try waitClosed(details, owner.pid);

    _ = try send(management, win.WM_COMMAND, 225, childParameter(try control(management, 225)));
    const profile = try waitWindow(windows.wide("ChatPalette.LibraryEditor"), null, owner.pid, true);
    try setText(try control(profile, 220), added_profile_name);
    _ = try send(profile, win.WM_COMMAND, win.IDOK, childParameter(try control(profile, win.IDOK)));
    try waitClosed(profile, owner.pid);

    if (windowPid(host) != owner.pid or win.PostMessageW(host, win.WM_CLOSE, 0, 0) == 0) return error.OwnerWindowChanged;
}

const ProcessIdentity = struct { process: win.HANDLE, pid: win.DWORD };

fn matchProcessImage(hwnd: win.HWND, expected: []const u8) !ProcessIdentity {
    const pid = windowPid(hwnd);
    if (pid == 0) return error.WindowHasNoProcess;
    const owner = win.OpenProcess(win.PROCESS_QUERY_LIMITED_INFORMATION | win.SYNCHRONIZE, 0, pid) orelse return error.CannotOpenTestProcess;
    errdefer _ = win.CloseHandle(owner);
    var path: [32768]u16 = undefined;
    var length: win.DWORD = path.len;
    if (win.QueryFullProcessImageNameW(owner, 0, &path, &length) == 0) return error.CannotVerifyTestProcessImage;
    const bytes = try std.unicode.utf16LeToUtf8Alloc(allocator, path[0..length]);
    defer allocator.free(bytes);
    const actual = try std.fs.cwd().realpathAlloc(allocator, bytes);
    defer allocator.free(actual);
    if (!std.ascii.eqlIgnoreCase(expected, actual) or windowPid(hwnd) != pid or win.WaitForSingleObject(owner, 0) != win.WAIT_TIMEOUT)
        return error.WindowNotOwnedByCandidate;
    return .{ .process = owner, .pid = pid };
}

fn windowPid(hwnd: win.HWND) win.DWORD {
    var pid: win.DWORD = 0;
    _ = win.GetWindowThreadProcessId(hwnd, &pid);
    return pid;
}

fn waitWindow(class: [:0]const u16, name: ?[:0]const u16, pid: win.DWORD, visible: bool) !win.HWND {
    const started = win.GetTickCount64();
    while (win.GetTickCount64() - started < 5000) {
        var previous: win.HWND = null;
        while (win.FindWindowExW(null, previous, class, if (name) |value| value.ptr else null)) |hwnd| {
            if ((pid == 0 or windowPid(hwnd) == pid) and (!visible or win.IsWindowVisible(hwnd) != 0)) return hwnd;
            previous = hwnd;
        }
        std.Thread.sleep(20 * std.time.ns_per_ms);
    }
    return error.CandidateWindowNotFound;
}

fn waitClosed(hwnd: win.HWND, pid: win.DWORD) !void {
    const started = win.GetTickCount64();
    while (win.GetTickCount64() - started < 5000) {
        if (windowPid(hwnd) != pid or win.IsWindowVisible(hwnd) == 0) return;
        std.Thread.sleep(20 * std.time.ns_per_ms);
    }
    return error.CandidateEditorDidNotClose;
}

fn control(parent: win.HWND, id: c_int) !win.HWND {
    const hwnd = win.GetDlgItem(parent, id) orelse return error.CandidateControlNotFound;
    if (windowPid(hwnd) != windowPid(parent)) return error.ForeignCandidateControl;
    return hwnd;
}

fn childParameter(hwnd: win.HWND) win.LPARAM {
    return @bitCast(windows.number(hwnd));
}

fn setText(hwnd: win.HWND, value: []const u8) !void {
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(allocator, value);
    defer allocator.free(wide);
    if ((try send(hwnd, win.WM_SETTEXT, 0, @bitCast(@intFromPtr(wide.ptr)))) == 0) return error.CandidateCannotSetText;
}

fn send(hwnd: win.HWND, message: win.UINT, wparam: win.WPARAM, lparam: win.LPARAM) !win.LRESULT {
    var result: win.DWORD_PTR = 0;
    if (win.SendMessageTimeoutW(hwnd, message, wparam, lparam, win.SMTO_ABORTIFHUNG | win.SMTO_BLOCK, 3000, &result) == 0)
        return error.CandidateUiMessageFailed;
    return @bitCast(result);
}

// This fixture runs only against the pinned AHK distribution. The Zig product,
// its build, and its release package do not use these legacy adapters.
const legacy_ahk =
    \\#Requires AutoHotkey v2.0
    \\#NoTrayIcon
    \\#SingleInstance Off
    \\#Include %A_ScriptDir%\src\app\app_modules.ahk
    \\
    \\try {
    \\    if A_Args.Length != 2
    \\        throw Error("Expected seed or read and an unused JSON path")
    \\    InitializeApplication(false)
    \\    if A_Args[1] == "seed" {
    \\        repository := OpenSettingsRepository(SettingsDatabasePath)
    \\        state := repository.Load()
    \\        if state.Profiles.Length || state.SharedDanmakuItems.Length
    \\            throw Error("Seed settings are not empty")
    \\        state.Profiles.Push({Id:"Caster",Name:"合成配信者",Channel:"/@synthetic",
    \\            Items:[{Id:"scoped",Name:"配信者の弾幕",Text:"既存の配信者本文👏",Slot:2}]})
    \\        state.SharedDanmakuItems.Push({Id:"A",Name:"変更前の名前",Text:"変更前の本文🌐",Slot:1})
    \\        state.SharedDanmakuItems.Push({Id:"a",Name:"無変更の弾幕",Text:"そのまま残す本文🌙",Slot:0})
    \\        state.InputProfileId := "Caster"
    \\        state.AutoMode := false
    \\        state.DefaultReactionCount := 10
    \\        state.DefaultReactionIntervalMs := 250
    \\        state.ShortcutKeys["palette"] := "^+q"
    \\        repository.SaveAll(state)
    \\        payload := '{"browser":"edge","tokens":[{"name":"👏","id":"one","class":"button","type":50000,"extra":1.2500},{"name":"a","id":"two","class":"button","type":50000},{"name":"b","id":"three","class":"button","type":50000},{"name":"c","id":"four","class":"button","type":50000},{"name":"d","id":"five","class":"button","type":50000}],"extra":{"synthetic":true}}'
    \\        SaveReactionRegistration(payload)
    \\    } else if A_Args[1] != "read"
    \\        throw Error("Invalid rollback fixture phase")
    \\    CloseSettingsStore()
    \\    WriteUserData(ReadStoredUserData(SettingsDatabasePath), A_Args[2])
    \\    FileAppend("PASS 0.8.0 " A_Args[1] " using application settings" Chr(10), "*", "UTF-8-RAW")
    \\    ExitApp(0)
    \\} catch as failure {
    \\    FileAppend("FAIL " failure.Message Chr(10) failure.Stack Chr(10), "**", "UTF-8-RAW")
    \\    ExitApp(1)
    \\}
;
