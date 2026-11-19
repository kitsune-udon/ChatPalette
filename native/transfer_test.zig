const std = @import("std");
const windows = @import("desktop/win.zig");
const management = @import("desktop/management.zig");
const win = windows.api;
const ui = @import("clean_install_scenario.zig");
const files = @import("tools/files.zig");
const process = @import("tools/process.zig");
const storage = @import("storage/store.zig");
const sqlite = @import("storage/sqlite.zig");

const allocator = std.heap.page_allocator;
const app_name = "ChatPalette.exe";
const db_path = "data/settings.db";
const backup_prefix = "settings.db.before-import-";
const export_stem = "日本語の書出し 🎉";
const export_name = export_stem ++ ".json";
const replacement_name = "別の合成データ.json";
const invalid_name = "形式エラー.json";
const created_name = "GUIで確定した弾幕🎉";
const draft_name = "破棄確認専用の合成名🌙";
const search_marker = "取込前の検索";
const app_timeout_ms = 90000;
const step_timeout_ms = 8000;
const shortcut_title = windows.wide("ショートカットを管理");
const duplicate_shortcut_warning = "キーの割当が重複しています。";
const shortcut_scope_id = 200;
const shortcut_first_slot_id = 201;
const shortcut_second_slot_id = 202;
const shortcut_save_items_id = 203;
const shortcut_key_status_id = 204;
const shortcut_item_status_id = 205;
const ShortcutKeys = [storage.action_count][]const u8;
const WindowSize = struct { width: i32, height: i32 };
const TrackObservation = struct {
    window_dpi: u32,
    getminmaxinfo_px: WindowSize,
    constrained_resize_px: WindowSize,
};

const PaletteKey = enum(u16) {
    initial = win.VK_F11,
    retry = win.VK_F12,

    fn setting(self: PaletteKey) []const u8 {
        return switch (self) {
            .initial => "^+F11",
            .retry => "^+F12",
        };
    }
};

const ProductMenu = enum(u16) {
    shortcuts = 5,
    import_data = 8,
    export_data = 9,
};

const Report = struct {
    passed: bool = false,
    failure: ?[]const u8 = null,
    stage: []const u8 = "setup",
    executable_sha256: ?files.HexDigest = null,
    app_process: ?process.Result = null,
    first_app_pid: ?u32 = null,
    shortcut_restart_process: ?process.Result = null,
    shortcut_restart_pid: ?u32 = null,
    shortcut_duplicate_rejected: bool = false,
    shortcut_required_rejected: bool = false,
    shortcut_discard_no_preserved_draft: bool = false,
    shortcut_discard_yes_preserved_database: bool = false,
    shortcut_chord_captured: bool = false,
    shortcut_saved_and_reopened: bool = false,
    shortcut_live_palette_uses_new_key: bool = false,
    shortcut_rejected_draft_kept_live_key: bool = false,
    shortcut_restarted_palette_uses_new_key: bool = false,
    shortcut_keys_after_restart: bool = false,
    shortcut_db_sha256: ?files.HexDigest = null,
    shortcut_commit_failure_count: u8 = 0,
    shortcut_commit_failure_notification: ?[]const u8 = null,
    shortcut_commit_failure_kept_draft_and_db: bool = false,
    shortcut_commit_failure_kept_live_key: bool = false,
    shortcut_commit_retry_saved_retained_draft: bool = false,
    shortcut_commit_retry_live_key: bool = false,
    shortcut_equivalent_spelling_preserved: bool = false,
    shortcut_key_save_left_item_draft: bool = false,
    shortcut_item_save_left_conflicting_keys: bool = false,
    shortcut_slots_swapped_and_unassigned: bool = false,
    shortcut_item_only_discard_and_scope_cancelled: bool = false,
    shortcut_slots_after_restart: bool = false,
    editor_rejection_preserved_draft: bool = false,
    editor_commit_reloaded_once: bool = false,
    editor_long_text_utf16_units: ?usize = null,
    editor_long_text_reopened: bool = false,
    editor_discard_no_preserved_draft_and_disabled_parent: bool = false,
    editor_discard_yes_restored_parent: bool = false,
    editor_long_change_saved_and_reopened: bool = false,
    editor_undo_restored_long_text: bool = false,
    editor_long_text_reloaded_after_exit: bool = false,
    narrow_palette_reveals_tab_focus: bool = false,
    narrow_management_scrolls_to_actions: bool = false,
    management_native_typeahead_selected_identity: bool = false,
    link_without_browser_explains_failure: bool = false,
    palette_window_dpi: ?u32 = null,
    palette_minimum_track: ?TrackObservation = null,
    management_minimum_track: ?TrackObservation = null,
    shortcut_minimum_track: ?TrackObservation = null,
    shortcut_wheel_pixels_per_notch: ?i32 = null,
    shortcut_focused_key_field_wheel_scrolled: bool = false,
    shortcut_wheel_reached_save_button: bool = false,
    complete_export: bool = false,
    existing_export_refused: bool = false,
    picker_cancel_preserved: bool = false,
    invalid_json_refused: bool = false,
    declined_replacement_preserved: bool = false,
    import_confirmation_rejects_nested_transfer: bool = false,
    undo_remained_enabled_after_decline: ?bool = null,
    import_commit_failure_preserved_state: bool = false,
    import_commit_failure_backup_sha256: ?files.HexDigest = null,
    imported_database_verified: bool = false,
    import_reset_search_and_scope: bool = false,
    search_length_after_import: ?isize = null,
    editing_scope_after_import: ?isize = null,
    selected_row_before_import: ?i32 = null,
    selected_row_after_import: ?i32 = null,
    automatic_backup_verified: bool = false,
    restored_using_import: bool = false,
    source_json_unchanged: bool = false,
    db_before_cancel: ?files.HexDigest = null,
    db_after_cancel: ?files.HexDigest = null,
    export_sha256: ?files.HexDigest = null,
    backup_name: ?[]const u8 = null,
};

const LegacyCheck = struct { file: []const u8, lines: []const u8, exercise: []const u8 };
const checked_legacy = [_]LegacyCheck{
    .{ .file = "tests/test-user-data-transfer.ps1", .lines = "13-23,149-150,164-167", .exercise = "Real Save As, Unicode path/contents, JSON2 categories and exact registration, existing export unchanged" },
    .{ .file = "tests/test-user-data-transfer.ps1", .lines = "162,171-182", .exercise = "Real picker cancellation and No on whole replacement keep original DB/live values and create no backup" },
    .{ .file = "tests/test-user-data-transfer.ps1", .lines = "129-133,193-197", .exercise = "Import and export requests received by the main window during the real import confirmation return without opening another dialog; declining preserves the DB and no backup is created." },
    .{ .file = "tests/test-user-data-transfer.ps1", .lines = "43-54,177-188", .exercise = "Real successful import updates visible values, clears search/scope/Undo, backs up every original category and restores it via the same UI" },
    .{ .file = "tests/test-user-data-transfer.ps1", .lines = "75-91", .exercise = "A separate SQLite reader blocks the import COMMIT. The product reports the error, retains the backup and old DB, and keeps search, scope, Undo and published keys until an unlocked retry succeeds." },
    .{ .file = "tests/test-user-data-transfer.ps1", .lines = "191,209-239", .exercise = "Representative malformed JSON shows rejection without changing source or target" },
    .{ .file = "tests/test-editor-commit.ps1", .lines = "29-32,82,86-95", .exercise = "Normal commit boundary only: rejected draft remains and successful save closes; reopening management observes one new row" },
    .{ .file = "tests/test-app-layout.ps1", .lines = "206-239", .exercise = "Owned product windows keep management and palette actions reachable in a small client area, with the palette moving its viewport to Tab focus" },
    .{ .file = "tests/test-management-virtual.ps1", .lines = "13,20-23", .exercise = "The product shows a virtual ListView and native keyboard prefix search opens the corresponding committed row" },
    .{ .file = "tests/test-shortcut-bindings.ps1", .lines = "31-35,80-97", .exercise = "Product settings reject normalized duplicates and missing required keys, save an atomic swap and unassigned optional action, and install the remapped palette key in the running and restarted app" },
    .{ .file = "tests/test-shortcut-bindings.ps1", .lines = "99-109", .exercise = "A separate reader blocks COMMIT. The product reports DatabaseLocked and retains the committed DB and live key; the same pending draft saves after releasing the lock." },
    .{ .file = "tests/test-shortcut-manager.ps1", .lines = "14,22,25,32-42,51-62", .exercise = "All shortcut fields are inspected; physical key capture, validation warnings, unchanged DB on rejection and discard, and successful save are exercised in the real dialog" },
    .{ .file = "tests/test-shortcut-manager.ps1", .lines = "43-47", .exercise = "Actual COMMIT failure is reported in the product dialog and preserves the unsaved settings for retry." },
    .{ .file = "tests/test-shortcut-manager.ps1", .lines = "9-20,28-42,57-75", .exercise = "The same product dialog independently stages and saves equivalent keys and item slots, swaps and unassigns item IDs, rejects duplicate slots, and retains item-only drafts on scope switch and close cancellation." },
};
const uncovered_legacy = [_]LegacyCheck{
    .{ .file = "tests/test-user-data-transfer.ps1", .lines = "25-27,55-136,183-188,209-355", .exercise = "Read-only bit, same-file/empty input, backup failure, individual insert and legacy native binding faults, worker registration cache, post-commit paint failure, nested transfer gate, exhaustive malformed input and size corpus" },
    .{ .file = "tests/test-user-data-transfer.ps1", .lines = "45-51", .exercise = "Physical browser shortcuts using imported values and live worker registration after transfer" },
    .{ .file = "tests/test-editor-commit.ps1", .lines = "29-123", .exercise = "Post-commit rendering fault injection, stale-row mutation refusal after that fault, channel linkage, and late reentrant shortcut/slot edits" },
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const args = try std.process.argsAlloc(scratch);
    if (args.len != 3) {
        std.debug.print("chatpalette-transfer-test <ChatPalette.exe> <新規の結果フォルダー>\n", .{});
        std.process.exit(2);
    }
    const cwd = std.fs.cwd();
    const candidate = try cwd.realpathAlloc(scratch, args[1]);
    if (!std.ascii.eqlIgnoreCase(std.fs.path.basename(candidate), app_name)) return error.UnexpectedExecutableName;
    try cwd.makeDir(args[2]);
    const output = try cwd.realpathAlloc(scratch, args[2]);
    var root = try cwd.openDir(output, .{});
    defer root.close();
    var report: Report = .{};
    verify(scratch, candidate, output, root, &report) catch |failure| {
        report.failure = @errorName(failure);
    };
    report.passed = report.failure == null;
    try process.saveResult(allocator, output, .{
        .passed = report.passed,
        .checks = report,
        .legacy_contracts_for_this_scenario = checked_legacy,
        .outside_this_desktop_test = uncovered_legacy,
    });
    if (report.failure) |failure| {
        std.debug.print("データ移行試験に失敗しました。{s} {s}\n", .{ report.stage, failure });
        std.process.exit(1);
    }
    std.debug.print("データ移行試験に合格しました。\n", .{});
}

fn verify(scratch: std.mem.Allocator, candidate: []const u8, output: []const u8, root: std.fs.Dir, report: *Report) !void {
    var installation = try newDirectory(root, "installation");
    defer installation.close();
    try installation.makeDir("data");
    const installation_path = try join(scratch, output, "installation");
    const db_absolute = try join(scratch, installation_path, db_path);
    const executable = try join(scratch, installation_path, app_name);
    const source = try files.openImmutable(scratch, candidate);
    defer source.close();
    const executable_bytes = try source.readToEndAlloc(scratch, 64 * 1024 * 1024);
    report.executable_sha256 = files.hex(files.digest(executable_bytes));
    try files.writeNew(installation, app_name, executable_bytes);
    if (!std.mem.eql(u8, &report.executable_sha256.?, &files.hex(try files.readDigest(installation, app_name))))
        return error.ExecutableCopyMismatch;

    const before = baseline();
    const incoming = replacement();
    try seedDatabase(db_absolute, before);
    const synthetic_db = try join(scratch, output, "synthetic-source.db");
    const incoming_path = try join(scratch, output, replacement_name);
    {
        var source_db = try storage.Store.open(allocator, synthetic_db);
        defer source_db.close();
        try source_db.save(incoming);
        try source_db.exportJson(incoming_path);
    }
    const invalid_path = try join(scratch, output, invalid_name);
    try files.writeNew(root, invalid_name, "{\"format\":\"ChatPalette\",");

    var logs = try newDirectory(root, "app");
    defer logs.close();
    var trial: AppTrial = .{ .exe = executable, .cwd = installation_path, .output = logs };
    const thread = try std.Thread.spawn(.{}, AppTrial.run, .{&trial});
    const scenarios = drive(scratch, output, root, installation, installation_path, db_absolute, executable, before, incoming, incoming_path, invalid_path, report);
    thread.join();
    report.app_process = try trial.result;
    try scenarios;
    if (!report.app_process.?.passed()) return error.ProductDidNotExitCleanly;

    var restart_logs = try newDirectory(root, "shortcut-restart-app");
    defer restart_logs.close();
    trial = .{ .exe = executable, .cwd = installation_path, .output = restart_logs };
    const restarted = try std.Thread.spawn(.{}, AppTrial.run, .{&trial});
    const shortcut_restart = observeShortcutRestart(scratch, installation, installation_path, executable, report);
    restarted.join();
    report.shortcut_restart_process = try trial.result;
    try shortcut_restart;
    if (!report.shortcut_restart_process.?.passed()) return error.RestartedProductDidNotExitCleanly;
    report.stage = "complete";
}

const AppTrial = struct {
    exe: []const u8,
    cwd: []const u8,
    output: std.fs.Dir,
    result: anyerror!process.Result = error.DesktopNotLaunched,

    fn run(self: *AppTrial) void {
        self.result = process.run(allocator, &.{ self.exe, "--quiet" }, self.cwd, self.output, app_timeout_ms);
    }
};

const OwnedProduct = struct {
    host: win.HWND,
    pid: u32,
    handle: win.HANDLE,

    fn wait(scratch: std.mem.Allocator, installation_path: []const u8, exe: []const u8) !OwnedProduct {
        const host = try ui.waitWindow(windows.wide("ChatPalette.Host"), try ui.hostTitle(scratch, installation_path), null);
        const pid = ui.windowPid(host);
        if (pid == 0) return error.HostPidMissing;
        const handle = win.OpenProcess(win.PROCESS_QUERY_LIMITED_INFORMATION | win.SYNCHRONIZE, 0, pid) orelse return error.CannotVerifyProductProcess;
        errdefer _ = win.CloseHandle(handle);
        if (!std.ascii.eqlIgnoreCase(exe, try ui.processImage(scratch, handle))) return error.ForeignProductProcess;
        const app: OwnedProduct = .{ .host = host, .pid = pid, .handle = handle };
        try app.checkWindow(host);
        return app;
    }

    fn checkWindow(self: OwnedProduct, window: win.HWND) !void {
        if (ui.windowPid(window) != self.pid or win.WaitForSingleObject(self.handle, 0) != win.WAIT_TIMEOUT)
            return error.ForeignProductProcess;
    }

    fn requestClose(self: OwnedProduct) !void {
        try self.checkWindow(self.host);
        if (win.PostMessageW(self.host, win.WM_CLOSE, 0, 0) == 0) return error.HostQuitFailed;
    }

    fn quit(self: OwnedProduct) !void {
        try self.requestClose();
        if (win.WaitForSingleObject(self.handle, step_timeout_ms) != win.WAIT_OBJECT_0) return error.ProductDidNotQuit;
    }
};

fn drive(scratch: std.mem.Allocator, output: []const u8, root: std.fs.Dir, installation: std.fs.Dir, installation_path: []const u8, db_absolute: []const u8, exe: []const u8, before: storage.Data, incoming: storage.Data, incoming_path: []const u8, invalid_path: []const u8, report: *Report) !void {
    report.stage = "wait-for-owned-app";
    const app = try OwnedProduct.wait(scratch, installation_path, exe);
    defer _ = win.CloseHandle(app.handle);
    errdefer app.requestClose() catch {};
    const host = app.host;
    const pid = app.pid;
    report.first_app_pid = pid;
    _ = try ui.message(host, management.wm_back, 0, 0);
    const palette = try ui.waitWindow(windows.wide("ChatPalette.Palette"), null, pid);
    report.stage = "narrow-palette";
    report.palette_window_dpi = win.GetDpiForWindow(palette);
    report.palette_minimum_track = try observeMinimumTrack(palette);
    try verifyNarrowPalette(palette);
    report.narrow_palette_reveals_tab_focus = true;
    report.stage = "channel-link-without-browser";
    const before_link = try files.readDigest(installation, db_path);
    try ui.click(palette, 115);
    var manager = try ui.waitWindow(windows.wide("ChatPalette.Management"), null, pid);
    _ = try ui.message(manager, win.WM_NULL, 0, 0);
    const notice = win.FindWindowExW(manager, null, windows.wide("STATIC"), windows.wide("YouTubeを前面にし、Ctrl+Alt+Q でパレットを開いて連携してください。"));
    if (notice == null or ui.windowPid(notice) != pid or win.IsWindowVisible(palette) != 0) return error.MissingChannelLinkNotice;
    try expectDigest(installation, db_path, before_link);
    report.link_without_browser_explains_failure = true;
    report.stage = "narrow-management";
    report.management_minimum_track = try observeMinimumTrack(manager);
    try verifyNarrowManagement(manager);
    report.narrow_management_scrolls_to_actions = true;
    try chooseShared(manager);
    report.stage = "editor-commit";
    var draft = try addFixtureRow(scratch, installation, db_absolute, manager, pid, before, report);
    defer draft.deinit();
    try checkEditorHistory(scratch, installation, db_absolute, manager, pid, draft.data, report);
    if (win.PostMessageW(manager, win.WM_CLOSE, 0, 0) == 0) return error.ManagementDidNotClose;
    try ui.waitClosed(manager, pid);
    manager = try ui.management(host, pid);
    try chooseShared(manager);
    try countRows(manager, 2);
    const original = draft.data;
    const db_digest = try files.readDigest(installation, db_path);
    const source_digest = try files.readDigest(root, replacement_name);
    const invalid_digest = try files.readDigest(root, invalid_name);

    report.stage = "export";
    const export_path = try join(scratch, output, export_name);
    const export_path_without_extension = try join(scratch, output, export_stem);
    try transfer(scratch, host, pid, .{ .export_file = export_path_without_extension });
    try waitForFile(root, export_name);
    try expectJson(export_path, original);
    try assertJsonEnvelope(scratch, root, export_name, original.shared_items[1].text);
    const exported = try files.readDigest(root, export_name);
    report.export_sha256 = files.hex(exported);
    report.complete_export = true;

    report.stage = "existing-export";
    try transfer(scratch, host, pid, .{ .export_existing = export_path });
    try expectDigest(root, export_name, exported);
    report.existing_export_refused = true;

    const scope = try ui.control(manager, 223);
    _ = try ui.message(scope, win.CB_SETCURSEL, 1, 0);
    _ = try ui.message(manager, win.WM_COMMAND, 223 | (win.CBN_SELCHANGE << 16), @bitCast(windows.number(scope)));
    if ((try ui.message(scope, win.CB_GETCURSEL, 0, 0)) != 1) return error.EditingProfileNotSelected;
    const search = try ui.control(palette, 101);
    try ui.setText(search, search_marker);
    const undo = try ui.control(manager, 235);
    if (win.IsWindowEnabled(undo) == 0) return error.FormerEditDidNotCreateUndo;

    var data_dir = try installation.openDir("data", .{ .iterate = true, .no_follow = true });
    defer data_dir.close();
    report.stage = "cancel-picker";
    try transfer(scratch, host, pid, .cancel_picker);
    try expectPreserved(scratch, installation, db_absolute, data_dir, &.{}, db_digest, original, search, scope);
    report.picker_cancel_preserved = true;

    report.stage = "invalid-json";
    try transfer(scratch, host, pid, .{ .import_invalid = invalid_path });
    try expectPreserved(scratch, installation, db_absolute, data_dir, &.{}, db_digest, original, search, scope);
    try expectDigest(root, invalid_name, invalid_digest);
    report.invalid_json_refused = true;

    report.stage = "decline-replacement";
    report.db_before_cancel = files.hex(db_digest);
    try transfer(scratch, host, pid, .{ .import_no = incoming_path });
    report.import_confirmation_rejects_nested_transfer = true;
    try expectPreserved(scratch, installation, db_absolute, data_dir, &.{}, db_digest, original, search, scope);
    report.db_after_cancel = files.hex(try files.readDigest(installation, db_path));
    report.undo_remained_enabled_after_decline = waitUntilEnabled(undo, pid);
    if (!report.undo_remained_enabled_after_decline.?) {
        // Separate a control left disabled by the modal dialog from lost history.
        manager = try ui.management(host, pid);
        if (win.IsWindowEnabled(try ui.control(manager, 235)) == 0) return error.CancelClearedUndo;
    }
    report.declined_replacement_preserved = true;

    report.stage = "import-commit-failure";
    {
        var reader = try holdShortcutReadLock(db_absolute);
        defer reader.close();
        defer reader.rollback();
        try proveShortcutCommitBlocked(db_absolute, PaletteKey.retry.setting());
        try transfer(scratch, host, pid, .{ .import_locked = incoming_path });
        try reader.exec("ROLLBACK");
    }
    const data_path = try join(scratch, installation_path, "data");
    const failed_backup = try onlyBackup(scratch, data_dir, &.{});
    try expectJson(try join(scratch, data_path, failed_backup), original);
    const failed_backup_digest = try files.readDigest(data_dir, failed_backup);
    report.import_commit_failure_backup_sha256 = files.hex(failed_backup_digest);
    try expectPreserved(scratch, installation, db_absolute, data_dir, &.{failed_backup}, db_digest, original, search, scope);
    if (!waitUntilEnabled(undo, pid)) return error.FailedImportClearedUndo;
    try expectPublishedShortcuts(scratch, app, manager, original.preferences.shortcut_keys);
    try expectDigest(root, replacement_name, source_digest);
    report.import_commit_failure_preserved_state = true;

    report.stage = "confirm-import";
    const before_list = try ui.control(manager, 224);
    _ = try ui.message(before_list, win.WM_KEYDOWN, win.VK_END, 0);
    _ = try ui.message(before_list, win.WM_KEYUP, win.VK_END, 0);
    report.selected_row_before_import = try selectedRow(manager);
    if (report.selected_row_before_import.? != 1) return error.CannotSelectPreImportRow;
    try transfer(scratch, host, pid, .{ .import_yes = incoming_path });
    try expectDb(db_absolute, incoming);
    report.imported_database_verified = true;

    report.stage = "automatic-backup";
    const backup = try onlyBackup(scratch, data_dir, &.{failed_backup});
    const backup_absolute = try join(scratch, data_path, backup);
    try expectJson(backup_absolute, original);
    const backup_digest = try files.readDigest(data_dir, backup);
    report.backup_name = backup;
    report.automatic_backup_verified = true;

    report.stage = "import-ui-refresh";
    report.search_length_after_import = try ui.message(search, win.WM_GETTEXTLENGTH, 0, 0);
    report.editing_scope_after_import = try ui.message(try ui.control(manager, 223), win.CB_GETCURSEL, 0, 0);
    report.selected_row_after_import = try selectedRow(manager);
    if (report.search_length_after_import.? != 0 or report.editing_scope_after_import.? != 0 or
        report.selected_row_after_import.? != -1)
        return error.ImportKeptStaleSelection;
    try countRows(manager, 1);
    if (win.IsWindowEnabled(try ui.control(manager, 235)) != 0) return error.ImportKeptUndo;
    if ((try ui.message(try ui.control(palette, 111), win.CB_GETCURSEL, 0, 0)) != 2) return error.ReactionDefaultsNotRefreshed;
    try expectPublishedShortcuts(scratch, app, manager, incoming.preferences.shortcut_keys);
    report.import_reset_search_and_scope = true;

    report.stage = "restore";
    try transfer(scratch, host, pid, .{ .import_yes = backup_absolute });
    try expectDb(db_absolute, original);
    manager = try ui.management(host, pid);
    try countRows(manager, 2);
    try expectPublishedShortcuts(scratch, app, manager, original.preferences.shortcut_keys);
    if ((try ui.message(try ui.control(palette, 111), win.CB_GETCURSEL, 0, 0)) != 1) return error.RestoredDefaultsNotRefreshed;
    const restore_backup = try onlyBackup(scratch, data_dir, &.{ failed_backup, backup });
    try expectJson(try join(scratch, data_path, restore_backup), incoming);
    try expectDigest(data_dir, failed_backup, failed_backup_digest);
    try expectDigest(data_dir, backup, backup_digest);
    try expectDigest(root, replacement_name, source_digest);
    try expectDigest(root, export_name, exported);
    report.restored_using_import = true;
    report.source_json_unchanged = true;

    report.stage = "management-native-typeahead";
    try expectNativeManagementSelection(scratch, app, manager, original.shared_items[1]);
    report.management_native_typeahead_selected_identity = true;

    const final = try exerciseShortcutEditor(scratch, installation, db_absolute, app, manager, palette, original, report);
    report.stage = "quit";
    try app.quit();
    try expectDb(db_absolute, final);
    report.shortcut_db_sha256 = files.hex(try files.readDigest(installation, db_path));
    report.editor_long_text_reloaded_after_exit = true;
    if (!report.undo_remained_enabled_after_decline.?) {
        report.stage = "decline-replacement-controls";
        return error.DeclinedTransferLeftUndoDisabled;
    }
}

fn resizeOwned(window: win.HWND, width: i32, height: i32) !void {
    const flags = win.SWP_NOACTIVATE | win.SWP_NOZORDER | win.SWP_NOMOVE | win.SWP_NOSENDCHANGING;
    if (win.SetWindowPos(window, null, 0, 0, width, height, flags) == 0) return error.CannotResizeProductWindow;
    // Fence the owned UI thread after SetWindowPos sourced its WM_SIZE.
    _ = try ui.message(window, win.WM_NULL, 0, 0);
}

fn windowExtent(window: win.HWND) !WindowSize {
    var bounds: win.RECT = undefined;
    if (win.GetWindowRect(window, &bounds) == 0) return error.CannotReadProductWindowBounds;
    return .{ .width = bounds.right - bounds.left, .height = bounds.bottom - bounds.top };
}

fn resizeWithTrackLimits(window: win.HWND, size: WindowSize) !void {
    const flags = win.SWP_NOACTIVATE | win.SWP_NOZORDER | win.SWP_NOMOVE;
    if (win.SetWindowPos(window, null, 0, 0, size.width, size.height, flags) == 0) return error.CannotResizeProductWindow;
    _ = try ui.message(window, win.WM_NULL, 0, 0);
}

fn observeMinimumTrack(window: win.HWND) !TrackObservation {
    const dpi = win.GetDpiForWindow(window);
    if (dpi == 0) return error.ProductWindowDpiMissing;
    const previous = win.SetThreadDpiAwarenessContext(win.GetWindowDpiAwarenessContext(window)) orelse
        return error.CannotMatchProductDpiCoordinates;
    defer _ = win.SetThreadDpiAwarenessContext(previous);
    const original = try windowExtent(window);
    errdefer resizeWithTrackLimits(window, original) catch {};
    const style: u32 = @bitCast(win.GetWindowLongW(window, win.GWL_STYLE));
    if (style & win.WS_THICKFRAME == 0) return error.ProductWindowHasNoResizeFrame;
    const ex_style: u32 = @bitCast(win.GetWindowLongW(window, win.GWL_EXSTYLE));
    const system_min: win.POINT = .{
        .x = win.GetSystemMetricsForDpi(win.SM_CXMINTRACK, dpi),
        .y = win.GetSystemMetricsForDpi(win.SM_CYMINTRACK, dpi),
    };
    var limits = std.mem.zeroes(win.MINMAXINFO);
    limits.ptMinTrackSize = system_min;
    limits.ptMaxTrackSize = .{
        .x = win.GetSystemMetricsForDpi(win.SM_CXMAXTRACK, dpi),
        .y = win.GetSystemMetricsForDpi(win.SM_CYMAXTRACK, dpi),
    };
    _ = try ui.message(window, win.WM_GETMINMAXINFO, 0, @bitCast(@intFromPtr(&limits)));

    const client = win.MulDiv(160, @intCast(dpi), 96);
    var frame = win.RECT{ .left = 0, .top = 0, .right = client, .bottom = client };
    if (win.AdjustWindowRectExForDpi(&frame, style & ~@as(u32, win.WS_VSCROLL | win.WS_HSCROLL), 0, ex_style, dpi) == 0)
        return error.CannotCalculateExpectedTrackFrame;
    const measured: WindowSize = .{ .width = limits.ptMinTrackSize.x, .height = limits.ptMinTrackSize.y };
    if (measured.width != @max(system_min.x, frame.right - frame.left) or
        measured.height != @max(system_min.y, frame.bottom - frame.top)) return error.ProductMinimumTrackMismatch;
    const requested: WindowSize = .{ .width = 1, .height = 1 };
    // Use normal window positioning so DefWindowProc applies WM_GETMINMAXINFO.
    try resizeWithTrackLimits(window, requested);
    const actual = try windowExtent(window);
    try resizeWithTrackLimits(window, original);
    if (!std.meta.eql(measured, actual)) return error.ProductResizeDidNotApplyMinimumTrack;
    return .{ .window_dpi = dpi, .getminmaxinfo_px = measured, .constrained_resize_px = actual };
}

fn clientContains(window: win.HWND, child: win.HWND, allow_oversized: bool) !bool {
    var rect: win.RECT = undefined;
    var client: win.RECT = undefined;
    if (win.GetWindowRect(child, &rect) == 0 or win.GetClientRect(window, &client) == 0) return error.CannotReadProductWindowBounds;
    _ = win.MapWindowPoints(null, window, @ptrCast(&rect), 2);
    return axisVisible(rect.left, rect.right, client.right, allow_oversized) and axisVisible(rect.top, rect.bottom, client.bottom, allow_oversized);
}

fn axisVisible(start: i32, end: i32, client: i32, allow_oversized: bool) bool {
    if (allow_oversized and end - start > client) return start == 0;
    return start >= 0 and end <= client;
}

fn verifyNarrowPalette(palette: win.HWND) !void {
    const find_focus = struct {
        fn get(window: win.HWND) !win.HWND {
            const thread = win.GetWindowThreadProcessId(window, null);
            var gui = std.mem.zeroes(win.GUITHREADINFO);
            gui.cbSize = @sizeOf(win.GUITHREADINFO);
            if (thread == 0 or win.GetGUIThreadInfo(thread, &gui) == 0 or gui.hwndFocus == null or win.IsChild(window, gui.hwndFocus) == 0)
                return error.ProductPaletteHasNoKeyboardFocus;
            return gui.hwndFocus;
        }
    }.get;
    try resizeOwned(palette, 292, 248);
    const defaults = try ui.control(palette, 114);
    if (try clientContains(palette, defaults, false)) return error.PaletteViewportWasNotNarrowed;
    var touched: usize = 0;
    for (0..14) |_| {
        const from = try find_focus(palette);
        if (from == defaults) break;
        if (win.PostMessageW(from, win.WM_KEYDOWN, win.VK_TAB, 1) == 0) return error.CannotQueuePaletteTab;
        const start = win.GetTickCount64();
        while (try find_focus(palette) == from) {
            if (win.GetTickCount64() - start >= 1200) return error.PaletteTabDidNotAdvance;
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }
        _ = try ui.message(palette, win.WM_NULL, 0, 0);
        if (!try clientContains(palette, try find_focus(palette), true)) return error.PaletteTabStoppedOutsideViewport;
        touched += 1;
    }
    if (touched < 3 or try find_focus(palette) != defaults or !try clientContains(palette, defaults, false)) return error.PaletteDidNotRevealTabFocus;
    try resizeOwned(palette, 580, 665);
    try resizeOwned(palette, 292, 248);
    if (try find_focus(palette) != defaults or !try clientContains(palette, defaults, false)) return error.PaletteResizeLostFocusVisibility;
    try resizeOwned(palette, 580, 665);
}

fn verifyNarrowManagement(manager: win.HWND) !void {
    try resizeOwned(manager, 310, 278);
    const support = try ui.control(manager, 236);
    if (try clientContains(manager, support, false)) return error.ManagementViewportWasNotNarrowed;
    _ = try ui.message(manager, win.WM_VSCROLL, win.SB_BOTTOM, 0);
    _ = try ui.message(manager, win.WM_HSCROLL, win.SB_RIGHT, 0);
    if (!try clientContains(manager, support, false)) return error.ManagementActionsOutsideViewport;
    try resizeOwned(manager, 760, 620);
}

fn waitUntilEnabled(window: win.HWND, pid: u32) bool {
    const started = win.GetTickCount64();
    while (ui.windowPid(window) == pid and win.GetTickCount64() - started < 800) {
        if (win.IsWindowEnabled(window) != 0) return true;
        std.Thread.sleep(20 * std.time.ns_per_ms);
    }
    return false;
}

fn chooseShared(manager: win.HWND) !void {
    const scope = try ui.control(manager, 223);
    _ = try ui.message(scope, win.CB_SETCURSEL, 0, 0);
    _ = try ui.message(manager, win.WM_COMMAND, 223 | (win.CBN_SELCHANGE << 16), @bitCast(windows.number(scope)));
}

fn countRows(manager: win.HWND, expected: win.LRESULT) !void {
    if ((try ui.message(try ui.control(manager, 224), win.LVM_GETITEMCOUNT, 0, 0)) != expected)
        return error.UnexpectedManagementItems;
}

fn selectedRow(manager: win.HWND) !i32 {
    // ListView_GetNextItem returns int even when SendMessage has a 64-bit result.
    const result = try ui.message(try ui.control(manager, 224), win.LVM_GETNEXTITEM, std.math.maxInt(win.WPARAM), win.LVNI_SELECTED);
    return @truncate(result);
}

fn expectNativeManagementSelection(scratch: std.mem.Allocator, app: OwnedProduct, manager: win.HWND, expected: storage.Item) !void {
    try chooseShared(manager);
    try countRows(manager, 2);
    const list = try ui.control(manager, 224);
    if (win.GetWindowLongW(list, win.GWL_STYLE) & win.LVS_OWNERDATA == 0) return error.ManagementListNotVirtual;
    _ = try ui.message(list, win.WM_KEYDOWN, win.VK_HOME, 0);
    _ = try ui.message(list, win.WM_KEYUP, win.VK_HOME, 0);
    if (try selectedRow(manager) != 0) return error.CannotChooseFirstManagementRow;
    _ = try ui.message(list, win.WM_CHAR, 'g', 1);
    if (try selectedRow(manager) != 1) return error.ManagementTypeaheadDidNotSelectExpectedRow;
    try ui.click(manager, 228);
    const editor = try ui.waitWindow(windows.wide("ChatPalette.LibraryEditor"), windows.wide("弾幕を編集"), app.pid);
    try expectEditorValues(scratch, editor, expected.name, expected.text);
    try closeCleanEditor(editor, manager, app.pid);
}

fn longEditorBody(scratch: std.mem.Allocator, ending: []const u8) ![]const u8 {
    const head = "合成本文の先頭🌸：";
    const fragment = "長い日本語の本文／👏👩‍🚀／絵文字🌙と仮名。";
    const repeats = 30_000 / try std.unicode.calcUtf16LeLen(fragment);
    const tail_start = head.len + repeats * fragment.len;
    const body = try scratch.alloc(u8, tail_start + ending.len);
    @memcpy(body[0..head.len], head);
    for (0..repeats) |i| {
        const start = head.len + i * fragment.len;
        @memcpy(body[start..][0..fragment.len], fragment);
    }
    @memcpy(body[tail_start..], ending);
    return body;
}

fn addFixtureRow(scratch: std.mem.Allocator, installation: std.fs.Dir, db_absolute: []const u8, manager: win.HWND, pid: u32, before: storage.Data, report: *Report) !storage.Snapshot {
    try countRows(manager, 1);
    const before_edit = try files.readDigest(installation, db_path);
    try ui.click(manager, 227);
    const editor = try ui.waitWindow(windows.wide("ChatPalette.LibraryEditor"), null, pid);
    const name = try ui.control(editor, 220);
    const text = try ui.control(editor, 221);
    try ui.setText(name, created_name);
    try ui.click(editor, win.IDOK);
    if (win.IsWindowVisible(editor) == 0 or !std.mem.eql(u8, try ui.readText(scratch, name), created_name))
        return error.RejectedEditLostDraft;
    try expectDigest(installation, db_path, before_edit);
    report.editor_rejection_preserved_draft = true;

    report.stage = "editor-long-save";
    const created_text = try longEditorBody(scratch, "原文の末尾🎉");
    report.editor_long_text_utf16_units = try std.unicode.calcUtf16LeLen(created_text);
    try ui.setText(text, created_text);
    try expectEditorValues(scratch, editor, created_name, created_text);
    try ui.click(editor, win.IDOK);
    try ui.waitClosed(editor, pid);
    try countRows(manager, 2);
    var saved = try readDatabase(db_absolute);
    errdefer saved.deinit();
    if (saved.data.shared_items.len != 2) return error.ItemCommitWasNotSingular;
    const added = saved.data.shared_items[1];
    if (added.id.len == 0 or std.mem.eql(u8, added.id, before.shared_items[0].id) or
        !std.mem.eql(u8, added.name, created_name) or !std.mem.eql(u8, added.text, created_text) or added.slot != 0)
        return error.SavedItemMismatch;
    var preserved = saved.data;
    preserved.shared_items = preserved.shared_items[0..1];
    if (!before.eql(preserved)) return error.EditChangedOtherValues;
    report.editor_commit_reloaded_once = true;
    return saved;
}

fn checkEditorHistory(scratch: std.mem.Allocator, installation: std.fs.Dir, path: []const u8, manager: win.HWND, pid: u32, original: storage.Data, report: *Report) !void {
    report.stage = "editor-long-reopen";
    const initial = original.shared_items[1];
    var editor = try openLastEditor(manager, pid);
    try expectEditorValues(scratch, editor, initial.name, initial.text);
    report.editor_long_text_reopened = true;

    const committed_digest = try files.readDigest(installation, db_path);
    const draft_body = try longEditorBody(scratch, "保存しない下書きの末尾🙈");
    try ui.setText(try ui.control(editor, 220), draft_name);
    try ui.setText(try ui.control(editor, 221), draft_body);
    try expectEditorValues(scratch, editor, draft_name, draft_body);

    report.stage = "editor-discard-no";
    try answerEditorDiscard(scratch, editor, pid, win.IDNO);
    if (!waitUntilEnabled(editor, pid) or win.IsWindowVisible(editor) == 0 or
        win.IsWindowEnabled(manager) != 0)
        return error.DeclinedDiscardLostEditorModality;
    try expectEditorValues(scratch, editor, draft_name, draft_body);
    try expectDigest(installation, db_path, committed_digest);
    report.editor_discard_no_preserved_draft_and_disabled_parent = true;

    report.stage = "editor-discard-yes";
    try answerEditorDiscard(scratch, editor, pid, win.IDYES);
    try ui.waitClosed(editor, pid);
    if (!waitUntilEnabled(manager, pid)) return error.DiscardDidNotEnableManagement;
    try expectDigest(installation, db_path, committed_digest);
    try expectDb(path, original);
    report.editor_discard_yes_restored_parent = true;

    report.stage = "editor-long-change";
    editor = try openLastEditor(manager, pid);
    try expectEditorValues(scratch, editor, initial.name, initial.text);
    const changed_body = try longEditorBody(scratch, "保存した変更の末尾🧪");
    try ui.setText(try ui.control(editor, 221), changed_body);
    try expectEditorValues(scratch, editor, initial.name, changed_body);
    try ui.click(editor, win.IDOK);
    try ui.waitClosed(editor, pid);
    var edited_items = [2]storage.Item{ original.shared_items[0], initial };
    edited_items[1].text = changed_body;
    var edited = original;
    edited.shared_items = &edited_items;
    try expectDb(path, edited);
    editor = try openLastEditor(manager, pid);
    try expectEditorValues(scratch, editor, initial.name, changed_body);
    try closeCleanEditor(editor, manager, pid);
    report.editor_long_change_saved_and_reopened = true;

    report.stage = "editor-long-undo";
    if (win.IsWindowEnabled(try ui.control(manager, 235)) == 0) return error.LongEditDidNotCreateUndo;
    try ui.click(manager, 235);
    try expectDb(path, original);
    editor = try openLastEditor(manager, pid);
    try expectEditorValues(scratch, editor, initial.name, initial.text);
    try closeCleanEditor(editor, manager, pid);
    report.editor_undo_restored_long_text = true;
}

fn openLastEditor(manager: win.HWND, pid: u32) !win.HWND {
    try countRows(manager, 2);
    const list = try ui.control(manager, 224);
    _ = try ui.message(list, win.WM_KEYDOWN, win.VK_END, 0);
    _ = try ui.message(list, win.WM_KEYUP, win.VK_END, 0);
    if (try selectedRow(manager) != 1 or win.IsWindowEnabled(try ui.control(manager, 228)) == 0)
        return error.CannotEditSavedRow;
    try ui.click(manager, 228);
    const editor = try ui.waitWindow(windows.wide("ChatPalette.LibraryEditor"), windows.wide("弾幕を編集"), pid);
    if (win.GetWindow(editor, win.GW_OWNER) != manager or win.IsWindowEnabled(manager) != 0)
        return error.EditorDidNotDisableOwnedManager;
    return editor;
}

fn expectEditorValues(scratch: std.mem.Allocator, editor: win.HWND, name: []const u8, body: []const u8) !void {
    if (!std.mem.eql(u8, try ui.readText(scratch, try ui.control(editor, 220)), name))
        return error.EditorNameMismatch;
    if (!std.mem.eql(u8, try ui.readText(scratch, try ui.control(editor, 221)), body))
        return error.EditorBodyMismatch;
}

fn answerEditorDiscard(scratch: std.mem.Allocator, editor: win.HWND, pid: u32, answer: c_int) !void {
    try postDialogCommand(editor, pid, win.IDCANCEL);
    const prompt = try ui.waitWindow(windows.wide("#32770"), windows.wide("未保存の変更"), pid);
    errdefer if (ui.windowPid(prompt) == pid) clickDialog(prompt, win.IDYES) catch {};
    if (win.GetWindow(prompt, win.GW_OWNER) != editor or
        !includes(try modalText(scratch, prompt), "保存せずに閉じますか？"))
        return error.UnexpectedEditorDiscardPrompt;
    try clickDialog(prompt, answer);
    try ui.waitClosed(prompt, pid);
}

fn closeCleanEditor(editor: win.HWND, manager: win.HWND, pid: u32) !void {
    try postDialogCommand(editor, pid, win.IDCANCEL);
    try ui.waitClosed(editor, pid);
    if (!waitUntilEnabled(manager, pid)) return error.ClosingEditorDidNotEnableManagement;
}

fn postDialogCommand(dialog: win.HWND, pid: u32, id: u16) !void {
    if (ui.windowPid(dialog) != pid) return error.ForeignProductProcess;
    const button = try ui.control(dialog, id);
    // A dirty draft opens a nested modal loop, so send the button command asynchronously.
    if (win.PostMessageW(dialog, win.WM_COMMAND, id, @bitCast(windows.number(button))) == 0)
        return error.CannotPostProductDialogCommand;
}

fn remappedKeys(original: ShortcutKeys) ShortcutKeys {
    var keys = original;
    keys[@intFromEnum(storage.Action.palette)] = PaletteKey.initial.setting();
    keys[@intFromEnum(storage.Action.profile1)] = "";
    keys[@intFromEnum(storage.Action.stop)] = "^+F10";
    std.mem.swap([]const u8, &keys[@intFromEnum(storage.Action.chat_focus)], &keys[@intFromEnum(storage.Action.chat_clear)]);
    return keys;
}

fn retriedKeys(committed: ShortcutKeys) ShortcutKeys {
    var keys = committed;
    keys[@intFromEnum(storage.Action.palette)] = PaletteKey.retry.setting();
    keys[@intFromEnum(storage.Action.stop)] = "^+F9";
    return keys;
}

fn exerciseShortcutEditor(scratch: std.mem.Allocator, installation: std.fs.Dir, path: []const u8, app: OwnedProduct, manager: win.HWND, palette: win.HWND, original: storage.Data, report: *Report) !storage.Data {
    report.stage = "shortcut-open";
    const baseline_keys = original.preferences.shortcut_keys;
    const db_digest = try files.readDigest(installation, db_path);
    var editor = try openShortcutEditor(app, manager);
    errdefer cleanupShortcutEditor(app, editor);
    try expectShortcutFields(scratch, editor, baseline_keys);
    report.stage = "shortcut-narrow-wheel";
    try verifyShortcutViewport(app, manager, editor, report);
    report.stage = "shortcut-equivalent";
    try waitShortcutButton(editor, win.IDOK, false);
    try waitShortcutButton(editor, shortcut_save_items_id, false);
    const focus_field = try shortcutField(editor, .chat_focus);
    try ui.setText(focus_field, "!^F");
    try postDialogCommand(editor, app.pid, win.IDOK);
    try waitShortcutButton(editor, win.IDOK, false);
    try waitShortcutStatus(scratch, editor, shortcut_key_status_id, "未保存の変更はありません");
    if (try ui.message(try ui.control(editor, 300 + @as(c_int, @intFromEnum(storage.Action.chat_focus))), win.WM_GETTEXTLENGTH, 0, 0) != 0)
        return error.EquivalentShortcutMarkedDirty;
    try expectDigest(installation, db_path, db_digest);
    try expectShortcutEditorActive(app, manager, editor);
    try ui.setText(focus_field, baseline_keys[@intFromEnum(storage.Action.chat_focus)]);

    report.stage = "shortcut-duplicate";
    var draft = baseline_keys;
    const clear = @intFromEnum(storage.Action.chat_clear);
    const stop = @intFromEnum(storage.Action.stop);
    draft[clear] = "!^Q";
    try ui.setText(try shortcutField(editor, .chat_clear), draft[clear]);
    try rejectShortcutSave(scratch, app, manager, editor, duplicate_shortcut_warning);
    try expectShortcutFields(scratch, editor, draft);
    try expectDigest(installation, db_path, db_digest);
    report.shortcut_duplicate_rejected = true;

    report.stage = "shortcut-required";
    draft[clear] = baseline_keys[clear];
    draft[stop] = "";
    try ui.setText(try shortcutField(editor, .chat_clear), draft[clear]);
    try ui.setText(try shortcutField(editor, .stop), draft[stop]);
    try rejectShortcutSave(scratch, app, manager, editor, "停止にはキーが必要です。");
    try expectShortcutFields(scratch, editor, draft);
    try expectDigest(installation, db_path, db_digest);
    report.shortcut_required_rejected = true;

    report.stage = "shortcut-discard-no";
    try postDialogCommand(editor, app.pid, win.IDCANCEL);
    try answerShortcutDiscard(scratch, editor, app.pid, win.IDNO);
    try expectShortcutEditorActive(app, manager, editor);
    try expectShortcutFields(scratch, editor, draft);
    try expectDigest(installation, db_path, db_digest);
    report.shortcut_discard_no_preserved_draft = true;

    report.stage = "shortcut-discard-yes";
    try postDialogCommand(editor, app.pid, win.IDCANCEL);
    try answerShortcutDiscard(scratch, editor, app.pid, win.IDYES);
    try expectShortcutEditorClosed(app, manager, editor);
    try expectDigest(installation, db_path, db_digest);
    try expectDb(path, original);
    report.shortcut_discard_yes_preserved_database = true;

    report.stage = "shortcut-capture";
    editor = try openShortcutEditor(app, manager);
    try expectShortcutFields(scratch, editor, baseline_keys);
    const capture_field = try shortcutField(editor, .palette);
    try injectPaletteChord(app, editor, capture_field, .initial);
    try waitForShortcutField(scratch, capture_field, PaletteKey.initial.setting());
    report.shortcut_chord_captured = true;

    report.stage = "shortcut-save";
    var expected = original;
    expected.preferences.shortcut_keys = remappedKeys(baseline_keys);
    for (expected.preferences.shortcut_keys[1..], baseline_keys[1..], 1..) |key, prior, i| {
        if (!std.mem.eql(u8, prior, key)) try ui.setText(try shortcutField(editor, @enumFromInt(i)), key);
    }
    try expectShortcutFields(scratch, editor, expected.preferences.shortcut_keys);
    const equivalent = try shortcutField(editor, .reactions_show);
    try ui.setText(equivalent, "!^R");
    try selectShortcutCombo(app, editor, shortcut_scope_id, 1);
    try waitShortcutChoice(editor, shortcut_second_slot_id, 1);
    try waitShortcutChoice(editor, shortcut_first_slot_id, 2);
    try selectShortcutCombo(app, editor, shortcut_first_slot_id, 1);
    try selectShortcutCombo(app, editor, shortcut_second_slot_id, 2);
    try waitShortcutButton(editor, shortcut_save_items_id, true);
    try postDialogCommand(editor, app.pid, win.IDOK);
    try waitShortcutStatus(scratch, editor, shortcut_key_status_id, "キー設定を保存し");
    try expectShortcutEditorActive(app, manager, editor);
    try expectShortcutFields(scratch, editor, expected.preferences.shortcut_keys);
    try expectDb(path, expected);
    report.shortcut_equivalent_spelling_preserved = true;
    try waitShortcutChoice(editor, shortcut_first_slot_id, 1);
    try waitShortcutChoice(editor, shortcut_second_slot_id, 2);
    try waitShortcutButton(editor, shortcut_save_items_id, true);
    try waitShortcutButton(editor, win.IDOK, false);
    report.shortcut_key_save_left_item_draft = true;

    report.stage = "shortcut-save-slots";
    const conflict = try shortcutField(editor, .chat_clear);
    try ui.setText(conflict, "+^f11");
    try waitShortcutStatus(scratch, editor, shortcut_key_status_id, duplicate_shortcut_warning);
    try waitShortcutStatus(scratch, editor, 300 + @as(c_int, @intFromEnum(storage.Action.palette)), "重複");
    try postDialogCommand(editor, app.pid, shortcut_save_items_id);
    try waitShortcutStatus(scratch, editor, shortcut_item_status_id, "弾幕の割当を保存しました");
    try waitShortcutStatus(scratch, editor, shortcut_key_status_id, duplicate_shortcut_warning);
    if (!std.mem.eql(u8, try ui.readText(scratch, conflict), "+^f11")) return error.ItemSaveOverwroteKeyDraft;
    try waitShortcutButton(editor, win.IDOK, false);
    try waitShortcutButton(editor, shortcut_save_items_id, false);
    report.shortcut_item_save_left_conflicting_keys = true;
    const profiles = try scratch.dupe(storage.Profile, expected.profiles);
    const items = try scratch.dupe(storage.Item, profiles[0].items);
    profiles[0].items = items;
    expected.profiles = profiles;
    items[0].slot = 1;
    items[1].slot = 2;
    try expectDb(path, expected);
    try ui.setText(conflict, expected.preferences.shortcut_keys[clear]);
    try waitShortcutStatus(scratch, editor, shortcut_key_status_id, "未保存の変更はありません");
    try selectShortcutCombo(app, editor, shortcut_first_slot_id, 0);
    try waitShortcutButton(editor, shortcut_save_items_id, true);
    try postDialogCommand(editor, app.pid, shortcut_save_items_id);
    try waitShortcutStatus(scratch, editor, shortcut_item_status_id, "弾幕の割当を保存しました");
    items[0].slot = 0;
    try expectDb(path, expected);
    report.shortcut_slots_swapped_and_unassigned = true;

    report.stage = "shortcut-item-discard";
    try selectShortcutCombo(app, editor, shortcut_first_slot_id, 2);
    try waitShortcutStatus(scratch, editor, shortcut_item_status_id, "同じ弾幕を両方のキーには割り当てられません");
    try waitShortcutButton(editor, shortcut_save_items_id, false);
    try selectShortcutCombo(app, editor, shortcut_scope_id, 0);
    try answerShortcutConfirmation(scratch, editor, app.pid, "未保存の弾幕割当を破棄して対象を変更しますか？", win.IDNO);
    try waitShortcutChoice(editor, shortcut_scope_id, 1);
    try waitShortcutChoice(editor, shortcut_first_slot_id, 2);
    if (win.PostMessageW(editor, win.WM_CLOSE, 0, 0) == 0) return error.CannotCloseShortcutEditor;
    try answerShortcutDiscard(scratch, editor, app.pid, win.IDNO);
    try expectShortcutEditorActive(app, manager, editor);
    try waitShortcutChoice(editor, shortcut_first_slot_id, 2);
    try postDialogCommand(editor, app.pid, win.IDCANCEL);
    try answerShortcutDiscard(scratch, editor, app.pid, win.IDYES);
    try expectShortcutEditorClosed(app, manager, editor);
    try expectDb(path, expected);
    report.shortcut_item_only_discard_and_scope_cancelled = true;
    editor = try openShortcutEditor(app, manager);
    try expectShortcutFields(scratch, editor, expected.preferences.shortcut_keys);
    report.shortcut_saved_and_reopened = true;

    report.stage = "shortcut-reject-after-save";
    const saved_digest = try files.readDigest(installation, db_path);
    const clear_field = try shortcutField(editor, .chat_clear);
    try ui.setText(clear_field, "+^f11");
    try rejectShortcutSave(scratch, app, manager, editor, duplicate_shortcut_warning);
    try ui.setText(clear_field, expected.preferences.shortcut_keys[clear]);
    try postDialogCommand(editor, app.pid, win.IDCANCEL);
    try expectShortcutEditorClosed(app, manager, editor);
    try expectDigest(installation, db_path, saved_digest);

    report.stage = "shortcut-live-binding";
    const shown = try showPaletteWithShortcut(app, manager, .initial);
    if (shown != palette) return error.PaletteWindowReplacedDuringShortcut;
    report.shortcut_live_palette_uses_new_key = true;
    report.shortcut_rejected_draft_kept_live_key = true;
    try hidePalette(app, palette);
    return exerciseShortcutCommitFailure(scratch, installation, path, app, manager, palette, expected, report);
}

fn exerciseShortcutCommitFailure(scratch: std.mem.Allocator, installation: std.fs.Dir, path: []const u8, app: OwnedProduct, manager: win.HWND, palette: win.HWND, committed: storage.Data, report: *Report) !storage.Data {
    const previous = committed.preferences.shortcut_keys;
    var expected = committed;
    const draft = retriedKeys(previous);
    expected.preferences.shortcut_keys = draft;
    const digest = try files.readDigest(installation, db_path);
    var editor: win.HWND = null;
    errdefer cleanupShortcutEditor(app, editor);

    // Once the old binding is observed outside the modal editor, reproduce the
    // same error again so retry can use the unchanged, still-open draft.
    for (0..2) |iteration| {
        report.stage = if (iteration == 0) "shortcut-commit-failure" else "shortcut-commit-failure-for-retry";
        editor = try openShortcutEditor(app, manager);
        try expectShortcutFields(scratch, editor, previous);
        try ui.setText(try shortcutField(editor, .palette), PaletteKey.retry.setting());
        try ui.setText(try shortcutField(editor, .stop), draft[@intFromEnum(storage.Action.stop)]);
        try expectShortcutFields(scratch, editor, draft);

        {
            var reader = try holdShortcutReadLock(path);
            defer reader.close();
            defer reader.rollback();
            try proveShortcutCommitBlocked(path, PaletteKey.retry.setting());
            try postDialogCommand(editor, app.pid, win.IDOK);
            const notice = try ui.waitWindow(windows.wide("#32770"), windows.wide("操作に失敗しました"), app.pid);
            errdefer _ = win.PostMessageW(notice, win.WM_CLOSE, 0, 0);
            const message = try modalText(scratch, notice);
            if (win.GetWindow(notice, win.GW_OWNER) != editor or
                !std.mem.eql(u8, message, @errorName(error.DatabaseLocked)))
                return error.UnexpectedShortcutCommitFailure;
            report.shortcut_commit_failure_notification = message;
            try closeOk(notice, app.pid);
            try expectShortcutEditorActive(app, manager, editor);
            try expectShortcutFields(scratch, editor, draft);
            try expectDigest(installation, db_path, digest);
            try reader.exec("ROLLBACK");
        }
        try expectDb(path, committed);
        report.shortcut_commit_failure_count += 1;
        report.shortcut_commit_failure_kept_draft_and_db = true;
        if (iteration != 0) break;

        report.stage = "shortcut-commit-failure-live-key";
        try postDialogCommand(editor, app.pid, win.IDCANCEL);
        try answerShortcutDiscard(scratch, editor, app.pid, win.IDYES);
        try expectShortcutEditorClosed(app, manager, editor);
        if (try showPaletteWithShortcut(app, manager, .initial) != palette)
            return error.FailedCommitChangedLivePaletteBinding;
        try hidePalette(app, palette);
        report.shortcut_commit_failure_kept_live_key = true;
    }

    report.stage = "shortcut-commit-retry";
    try postDialogCommand(editor, app.pid, win.IDOK);
    try waitShortcutStatus(scratch, editor, shortcut_key_status_id, "キー設定を保存し");
    try expectShortcutEditorActive(app, manager, editor);
    try expectShortcutFields(scratch, editor, draft);
    try postDialogCommand(editor, app.pid, win.IDCANCEL);
    try expectShortcutEditorClosed(app, manager, editor);
    try expectDb(path, expected);
    editor = try openShortcutEditor(app, manager);
    try expectShortcutFields(scratch, editor, draft);
    try postDialogCommand(editor, app.pid, win.IDCANCEL);
    try expectShortcutEditorClosed(app, manager, editor);
    report.shortcut_commit_retry_saved_retained_draft = true;
    if (try showPaletteWithShortcut(app, manager, .retry) != palette)
        return error.ShortcutRetryDidNotPublishLivePaletteBinding;
    report.shortcut_commit_retry_live_key = true;
    return expected;
}

fn holdShortcutReadLock(path: []const u8) !sqlite.Connection {
    var reader = try sqlite.Connection.open(allocator, path, .read_only);
    errdefer reader.close();
    const journal = try reader.scalarText(allocator, "PRAGMA journal_mode", &.{});
    defer allocator.free(journal);
    if (!std.mem.eql(u8, journal, "delete")) return error.ShortcutCommitFixtureRequiresDeleteJournal;
    try reader.exec("BEGIN");
    // Reading the actual table acquires the SHARED lock for the whole transaction.
    if (try reader.scalarInt("SELECT COUNT(*) FROM shortcut_bindings", &.{}) != storage.action_count)
        return error.ShortcutCommitFixtureDidNotReadBindings;
    return reader;
}

fn proveShortcutCommitBlocked(path: []const u8, attempted_key: []const u8) !void {
    var probe = try sqlite.Connection.open(allocator, path, .read_write);
    defer probe.close();
    try probe.exec("PRAGMA busy_timeout=0");
    // A SHARED read transaction lets this writer acquire RESERVED and update.
    // Only the COMMIT's promotion to an exclusive lock must refuse it.
    try probe.exec("BEGIN IMMEDIATE");
    defer probe.rollback();
    try probe.run("UPDATE shortcut_bindings SET key=? WHERE action='palette' AND key IS NOT ?", &.{ .{ .text = attempted_key }, .{ .text = attempted_key } });
    if (try probe.scalarInt("SELECT changes()", &.{}) != 1) return error.ShortcutCommitProbeDidNotStageWrite;
    if (probe.exec("COMMIT")) |_| {
        return error.ShortcutCommitProbeUnexpectedlyCommitted;
    } else |failure| {
        if (failure != error.DatabaseLocked or probe.last_code & 0xff != 5) return failure;
    }
}

fn hidePalette(app: OwnedProduct, palette: win.HWND) !void {
    try app.checkWindow(palette);
    _ = try ui.message(palette, win.WM_CLOSE, 0, 0);
    try ui.waitClosed(palette, app.pid);
}

fn observeShortcutRestart(scratch: std.mem.Allocator, installation: std.fs.Dir, installation_path: []const u8, exe: []const u8, report: *Report) !void {
    report.stage = "shortcut-restart";
    const app = try OwnedProduct.wait(scratch, installation_path, exe);
    defer _ = win.CloseHandle(app.handle);
    errdefer app.requestClose() catch {};
    if (app.pid == report.first_app_pid.?) return error.RestartReusedOriginalProcess;
    report.shortcut_restart_pid = app.pid;
    const manager = try ui.management(app.host, app.pid);
    const editor = try openShortcutEditor(app, manager);
    errdefer cleanupShortcutEditor(app, editor);
    try expectShortcutFields(scratch, editor, retriedKeys(remappedKeys(baseline().preferences.shortcut_keys)));
    try selectShortcutCombo(app, editor, shortcut_scope_id, 1);
    try waitShortcutChoice(editor, shortcut_first_slot_id, 0);
    try waitShortcutChoice(editor, shortcut_second_slot_id, 2);
    try waitShortcutButton(editor, shortcut_save_items_id, false);
    report.shortcut_slots_after_restart = true;
    try postDialogCommand(editor, app.pid, win.IDCANCEL);
    try expectShortcutEditorClosed(app, manager, editor);
    report.shortcut_keys_after_restart = true;
    report.stage = "shortcut-restart-binding";
    _ = try showPaletteWithShortcut(app, manager, .retry);
    report.shortcut_restarted_palette_uses_new_key = true;
    try app.quit();
    const digest = files.hex(try files.readDigest(installation, db_path));
    if (!std.mem.eql(u8, &digest, &report.shortcut_db_sha256.?)) return error.RestartChangedSavedValues;
}

fn openShortcutEditor(app: OwnedProduct, parent: win.HWND) !win.HWND {
    try app.checkWindow(parent);
    if (win.IsWindowEnabled(parent) == 0 or win.IsWindowVisible(parent) == 0) return error.ShortcutEditorParentNotReady;
    try postMenuCommand(app.host, app.pid, .shortcuts);
    const editor = try ui.waitWindow(windows.wide("ChatPalette.Support"), shortcut_title, app.pid);
    errdefer cleanupShortcutEditor(app, editor);
    try expectShortcutEditorActive(app, parent, editor);
    return editor;
}

fn expectShortcutEditorActive(app: OwnedProduct, parent: win.HWND, editor: win.HWND) !void {
    try app.checkWindow(editor);
    if (win.GetWindow(editor, win.GW_OWNER) != parent or win.IsWindowVisible(editor) == 0 or win.IsWindowEnabled(parent) != 0)
        return error.ShortcutEditorLostParentModality;
    if (!waitUntilEnabled(editor, app.pid)) return error.ShortcutEditorStillDisabled;
}

fn expectShortcutEditorClosed(app: OwnedProduct, parent: win.HWND, editor: win.HWND) !void {
    try ui.waitClosed(editor, app.pid);
    try synchronizeHost(app.host, app.pid);
    if (!waitUntilEnabled(parent, app.pid)) return error.ShortcutEditorDidNotReleaseParent;
}

fn verifyShortcutViewport(app: OwnedProduct, manager: win.HWND, editor: win.HWND, report: *Report) !void {
    report.shortcut_minimum_track = try observeMinimumTrack(editor);
    const previous = win.SetThreadDpiAwarenessContext(win.GetWindowDpiAwarenessContext(editor)) orelse
        return error.CannotMatchProductDpiCoordinates;
    defer _ = win.SetThreadDpiAwarenessContext(previous);
    const restore = try windowExtent(editor);
    errdefer resizeWithTrackLimits(editor, restore) catch {};
    const dpi: windows.Dpi = .{ .value = report.shortcut_minimum_track.?.window_dpi };
    try resizeWithTrackLimits(editor, .{ .width = dpi.pixels(380), .height = dpi.pixels(220) });
    const save = try ui.control(editor, win.IDOK);
    _ = try ui.message(editor, win.WM_VSCROLL, win.SB_TOP, 0);
    if (try clientContains(editor, save, false)) return error.ShortcutViewportWasNotNarrowed;
    const start = try shortcutScrollInfo(editor);
    const last = start.nMax + 1 - @as(i32, @intCast(start.nPage));
    if (start.nPos != 0 or last < 96) return error.ShortcutViewportHasNoWheelRange;

    try postShortcutWheel(try shortcutField(editor, .palette), app, -win.WHEEL_DELTA);
    try waitShortcutScroll(editor, 96);
    report.shortcut_focused_key_field_wheel_scrolled = true;
    report.shortcut_wheel_pixels_per_notch = 96;
    try postShortcutWheel(editor, app, -3 * win.WHEEL_DELTA);
    try waitShortcutScroll(editor, 384);
    if (!try clientContains(editor, save, false)) return error.ShortcutWheelDidNotRevealSave;
    try postShortcutWheel(editor, app, -8 * win.WHEEL_DELTA);
    try waitShortcutScroll(editor, last);
    if (!try clientContains(editor, try ui.control(editor, shortcut_save_items_id), false)) return error.ShortcutWheelDidNotRevealItemSave;
    try resizeWithTrackLimits(editor, restore);
    _ = try ui.message(editor, win.WM_VSCROLL, win.SB_TOP, 0);
    try expectShortcutEditorActive(app, manager, editor);
    report.shortcut_wheel_reached_save_button = true;
}

fn shortcutScrollInfo(editor: win.HWND) !win.SCROLLINFO {
    var info = std.mem.zeroes(win.SCROLLINFO);
    info.cbSize = @sizeOf(win.SCROLLINFO);
    info.fMask = win.SIF_POS | win.SIF_PAGE | win.SIF_RANGE;
    if (win.GetScrollInfo(editor, win.SB_VERT, &info) == 0) return error.ShortcutViewportScrollInformationMissing;
    return info;
}

fn postShortcutWheel(target: win.HWND, app: OwnedProduct, delta: i16) !void {
    try app.checkWindow(target);
    const unsigned: u16 = @bitCast(delta);
    if (win.PostMessageW(target, win.WM_MOUSEWHEEL, @as(usize, unsigned) << 16, 0) == 0)
        return error.CannotPostShortcutWheel;
}

fn waitShortcutScroll(editor: win.HWND, expected: i32) !void {
    const started = win.GetTickCount64();
    while (win.GetTickCount64() - started < 1500) {
        if ((try shortcutScrollInfo(editor)).nPos == expected) {
            // The UI thread publishes scroll info before moving the child windows.
            _ = try ui.message(editor, win.WM_NULL, 0, 0);
            if ((try shortcutScrollInfo(editor)).nPos == expected) return;
        }
        std.Thread.sleep(15 * std.time.ns_per_ms);
    }
    return error.ShortcutWheelDidNotMoveViewport;
}

fn cleanupShortcutEditor(app: OwnedProduct, editor: win.HWND) void {
    app.checkWindow(editor) catch return;
    const started = win.GetTickCount64();
    var posted_cancel = false;
    while (win.GetTickCount64() - started < 1200 and ui.windowPid(editor) == app.pid and win.IsWindowVisible(editor) != 0) {
        var previous: win.HWND = null;
        var owned_prompt: win.HWND = null;
        while (win.FindWindowExW(null, previous, windows.wide("#32770"), null)) |prompt| {
            previous = prompt;
            if (ui.windowPid(prompt) != app.pid or win.GetWindow(prompt, win.GW_OWNER) != editor or win.IsWindowVisible(prompt) == 0) continue;
            owned_prompt = prompt;
            break;
        }
        if (owned_prompt) |prompt| {
            if (win.GetDlgItem(prompt, win.IDYES) != null) {
                clickDialog(prompt, win.IDYES) catch {};
            } else {
                _ = win.PostMessageW(prompt, win.WM_CLOSE, 0, 0);
            }
        } else if (!posted_cancel) {
            postDialogCommand(editor, app.pid, win.IDCANCEL) catch return;
            posted_cancel = true;
        }
        std.Thread.sleep(30 * std.time.ns_per_ms);
    }
}

fn shortcutField(editor: win.HWND, action: storage.Action) !win.HWND {
    const index: c_int = @intFromEnum(action);
    return ui.control(editor, 100 + index);
}

fn expectShortcutFields(scratch: std.mem.Allocator, editor: win.HWND, keys: ShortcutKeys) !void {
    for (std.enums.values(storage.Action), keys) |action, key| {
        const field = try shortcutField(editor, action);
        if (key.len == 0) {
            if (try ui.message(field, win.WM_GETTEXTLENGTH, 0, 0) != 0) return error.ShortcutFieldNotEmpty;
        } else if (!std.mem.eql(u8, try ui.readText(scratch, field), key)) {
            return error.ShortcutFieldMismatch;
        }
    }
}

fn rejectShortcutSave(scratch: std.mem.Allocator, app: OwnedProduct, parent: win.HWND, editor: win.HWND, expected: []const u8) !void {
    try postDialogCommand(editor, app.pid, win.IDOK);
    try waitShortcutStatus(scratch, editor, shortcut_key_status_id, expected);
    try waitShortcutButton(editor, win.IDOK, false);
    try expectShortcutEditorActive(app, parent, editor);
}

fn answerShortcutDiscard(scratch: std.mem.Allocator, editor: win.HWND, pid: u32, answer: c_int) !void {
    try answerShortcutConfirmation(scratch, editor, pid, "未保存の変更を破棄して閉じますか？", answer);
}

fn answerShortcutConfirmation(scratch: std.mem.Allocator, editor: win.HWND, pid: u32, expected: []const u8, answer: c_int) !void {
    const prompt = try ui.waitWindow(windows.wide("#32770"), shortcut_title, pid);
    errdefer if (ui.windowPid(prompt) == pid) clickDialog(prompt, win.IDYES) catch {};
    if (win.GetWindow(prompt, win.GW_OWNER) != editor or
        !includes(try modalText(scratch, prompt), expected))
        return error.UnexpectedShortcutDiscardPrompt;
    try clickDialog(prompt, answer);
    try ui.waitClosed(prompt, pid);
}

fn selectShortcutCombo(app: OwnedProduct, editor: win.HWND, id: u16, value: usize) !void {
    const control = try ui.control(editor, id);
    try app.checkWindow(control);
    if (try ui.message(control, win.CB_SETCURSEL, value, 0) != value) return error.ShortcutChoiceUnavailable;
    const selection = (@as(usize, win.CBN_SELCHANGE) << 16) | id;
    if (win.PostMessageW(editor, win.WM_COMMAND, selection, @bitCast(@intFromPtr(control))) == 0)
        return error.CannotPostShortcutSelection;
}

fn waitShortcutStatus(scratch: std.mem.Allocator, editor: win.HWND, id: c_int, expected: []const u8) !void {
    const status = try ui.control(editor, id);
    const start = win.GetTickCount64();
    while (win.GetTickCount64() - start < step_timeout_ms) {
        if (try ui.message(status, win.WM_GETTEXTLENGTH, 0, 0) > 0 and
            includes(try ui.readText(scratch, status), expected)) return;
        std.Thread.sleep(20 * std.time.ns_per_ms);
    }
    return error.UnexpectedShortcutStatus;
}

fn waitShortcutButton(editor: win.HWND, id: c_int, enabled: bool) !void {
    const button = try ui.control(editor, id);
    const start = win.GetTickCount64();
    while (win.GetTickCount64() - start < step_timeout_ms) {
        if ((win.IsWindowEnabled(button) != 0) == enabled) return;
        std.Thread.sleep(20 * std.time.ns_per_ms);
    }
    return error.UnexpectedShortcutButtonState;
}

fn waitShortcutChoice(editor: win.HWND, id: c_int, expected: usize) !void {
    const choice = try ui.control(editor, id);
    const start = win.GetTickCount64();
    while (win.GetTickCount64() - start < step_timeout_ms) {
        if (try ui.message(choice, win.CB_GETCURSEL, 0, 0) == expected) return;
        std.Thread.sleep(20 * std.time.ns_per_ms);
    }
    return error.UnexpectedShortcutChoice;
}

fn waitForShortcutField(scratch: std.mem.Allocator, field: win.HWND, expected: []const u8) !void {
    const start = win.GetTickCount64();
    while (win.GetTickCount64() - start < step_timeout_ms) {
        if (std.mem.eql(u8, try ui.readText(scratch, field), expected)) return;
        std.Thread.sleep(20 * std.time.ns_per_ms);
    }
    return error.PaletteChordWasNotCaptured;
}

fn showPaletteWithShortcut(app: OwnedProduct, parent: win.HWND, key: PaletteKey) !win.HWND {
    var before: win.HWND = null;
    while (win.FindWindowExW(null, before, windows.wide("ChatPalette.Palette"), null)) |window| {
        before = window;
        if (ui.windowPid(window) == app.pid and win.IsWindowVisible(window) != 0)
            return error.PaletteAlreadyVisibleBeforeShortcut;
    }
    try injectPaletteChord(app, parent, null, key);
    return ui.waitWindow(windows.wide("ChatPalette.Palette"), null, app.pid);
}

fn injectPaletteChord(app: OwnedProduct, window: win.HWND, capture_field: win.HWND, key: PaletteKey) !void {
    try noInterferingKeys(key);
    try activateShortcutTarget(app, window);
    try noInterferingKeys(key);
    try app.checkWindow(window);
    if (capture_field != null) {
        try app.checkWindow(capture_field);
        const thread = win.GetWindowThreadProcessId(window, null);
        var info = std.mem.zeroes(win.GUITHREADINFO);
        info.cbSize = @sizeOf(win.GUITHREADINFO);
        if (win.GetGUIThreadInfo(thread, &info) == 0 or info.hwndFocus != capture_field) return error.ShortcutFieldNotFocused;
    }
    const vk = @intFromEnum(key);
    const keys = [_]u16{ win.VK_LCONTROL, win.VK_LSHIFT, vk, vk, win.VK_LSHIFT, win.VK_LCONTROL };
    var events: [keys.len]win.INPUT = @splat(std.mem.zeroes(win.INPUT));
    const released_start = keys.len / 2;
    for (keys, &events, 0..) |virtual_key, *event, index| {
        event.type = win.INPUT_KEYBOARD;
        event.u.ki.wVk = virtual_key;
        event.u.ki.dwFlags = if (index >= released_start) win.KEYEVENTF_KEYUP else 0;
    }
    try app.checkWindow(window);
    if (win.GetForegroundWindow() != window) return error.ShortcutTargetNotForeground;
    const sent = win.SendInput(events.len, &events, @sizeOf(win.INPUT));
    if (sent == events.len) return;
    // Release only the keys that this trial pressed and did not already release.
    const remaining = if (sent <= released_start) events[events.len - sent ..] else events[sent..];
    if (remaining.len != 0) _ = win.SendInput(@intCast(remaining.len), remaining.ptr, @sizeOf(win.INPUT));
    return error.ShortcutInputWasIncomplete;
}

fn noInterferingKeys(key: PaletteKey) !void {
    for ([_]c_int{ win.VK_CONTROL, win.VK_SHIFT, win.VK_MENU, win.VK_LWIN, win.VK_RWIN, @intFromEnum(key) }) |virtual_key| {
        if (win.GetAsyncKeyState(virtual_key) < 0) return error.ShortcutTestKeyAlreadyHeld;
    }
}

fn activateShortcutTarget(app: OwnedProduct, window: win.HWND) !void {
    try app.checkWindow(window);
    if (win.IsWindowVisible(window) == 0 or win.IsWindowEnabled(window) == 0) return error.ShortcutTargetNotReady;
    if (win.GetForegroundWindow() == window) return;
    _ = win.SetForegroundWindow(window);
    if (win.GetForegroundWindow() == window) return;

    // Use the same focused activation fallback as the browser and IME scenarios.
    var pending: win.MSG = undefined;
    _ = win.PeekMessageW(&pending, null, 0, 0, win.PM_NOREMOVE);
    const caller = win.GetCurrentThreadId();
    const foreground = win.GetWindowThreadProcessId(win.GetForegroundWindow(), null);
    const attached = foreground != 0 and foreground != caller and win.AttachThreadInput(caller, foreground, 1) != 0;
    defer if (attached) {
        _ = win.AttachThreadInput(caller, foreground, 0);
    };
    try app.checkWindow(window);
    _ = win.BringWindowToTop(window);
    _ = win.SetForegroundWindow(window);
    const started = win.GetTickCount64();
    while (win.GetForegroundWindow() != window) {
        if (win.GetTickCount64() - started >= 600) return error.ShortcutTargetNotForeground;
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
}

const Transfer = union(enum) {
    export_file: []const u8,
    export_existing: []const u8,
    cancel_picker,
    import_invalid: []const u8,
    import_no: []const u8,
    import_locked: []const u8,
    import_yes: []const u8,
};

fn transfer(scratch: std.mem.Allocator, host: win.HWND, pid: u32, step: Transfer) !void {
    const command: ProductMenu = switch (step) {
        .export_file, .export_existing => .export_data,
        else => .import_data,
    };
    try postMenuCommand(host, pid, command);
    try driveTransfer(scratch, host, pid, step);
    try synchronizeHost(host, pid);
}

fn postMenuCommand(host: win.HWND, pid: u32, command: ProductMenu) !void {
    if (pid == 0 or ui.windowPid(host) != pid) return error.ForeignProductProcess;
    // The popup menu normally submits the same WM_COMMAND to the host, with
    // the command ID in LOWORD(wParam) and both HIWORD(wParam) and lParam zero.
    if (win.PostMessageW(host, win.WM_COMMAND, @intFromEnum(command), 0) == 0)
        return error.CannotPostProductMenuCommand;
}

fn synchronizeHost(host: win.HWND, pid: u32) !void {
    if (pid == 0 or ui.windowPid(host) != pid) return error.ForeignProductProcess;
    _ = try ui.message(host, win.WM_NULL, 0, 0);
}

fn driveTransfer(scratch: std.mem.Allocator, host: win.HWND, pid: u32, step: Transfer) !void {
    const picker = try waitForPicker(pid);
    errdefer _ = win.PostMessageW(picker.window, win.WM_CLOSE, 0, 0);
    if (step == .cancel_picker) {
        try clickDialog(picker.window, win.IDCANCEL);
        return ui.waitClosed(picker.window, pid);
    }
    const path = switch (step) {
        .export_file, .export_existing, .import_invalid, .import_no, .import_locked, .import_yes => |value| value,
        .cancel_picker => unreachable,
    };
    try ui.setText(picker.filename, path);
    try clickDialog(picker.window, win.IDOK);
    try ui.waitClosed(picker.window, pid);
    switch (step) {
        .export_file => {},
        .export_existing => try acceptError(scratch, pid, "PathAlreadyExists"),
        .import_invalid => try acceptError(scratch, pid, "InvalidJson"),
        .import_yes, .import_locked, .import_no => {
            const title = windows.wide("ユーザーデータのインポート");
            const confirm = try ui.waitWindow(windows.wide("#32770"), title, pid);
            errdefer _ = win.PostMessageW(confirm, win.WM_CLOSE, 0, 0);
            const prompt = try modalText(scratch, confirm);
            if (!includes(prompt, std.fs.path.basename(path)) or !includes(prompt, "全データを置き換えます") or
                !includes(prompt, "弾幕 ") or !includes(prompt, "配信者 ") or !includes(prompt, "登録 "))
                return error.ImportConfirmationOmittedData;
            if (step == .import_no) {
                if (ui.windowPid(host) != pid) return error.ForeignProductProcess;
                for ([_]ProductMenu{ .import_data, .export_data }) |command|
                    _ = try ui.message(host, win.WM_COMMAND, @intFromEnum(command), 0);
                if (ui.windowPid(confirm) != pid or win.IsWindowVisible(confirm) == 0 or win.IsWindowEnabled(confirm) == 0)
                    return error.NestedTransferChangedConfirmation;
            }
            try clickDialog(confirm, if (step == .import_no) win.IDNO else win.IDYES);
            try ui.waitClosed(confirm, pid);
            if (step == .import_locked) return acceptError(scratch, pid, "DatabaseLocked");
            if (step == .import_yes) {
                const completed = try ui.waitWindow(windows.wide("#32770"), title, pid);
                errdefer _ = win.PostMessageW(completed, win.WM_CLOSE, 0, 0);
                const response = try modalText(scratch, completed);
                if (!includes(response, "取込前のバックアップ") or !includes(response, backup_prefix) or
                    !(includes(response, "ユーザーデータを取り込みました") or includes(response, "ユーザーデータを保存しました")))
                    return error.ImportCompletionOmittedBackup;
                try closeOk(completed, pid);
            }
        },
        .cancel_picker => unreachable,
    }
}

const Picker = struct { window: win.HWND, filename: win.HWND };

fn waitForPicker(pid: u32) !Picker {
    const started = win.GetTickCount64();
    var owned_dialog: win.HWND = null;
    while (win.GetTickCount64() - started < step_timeout_ms) {
        var previous: win.HWND = null;
        while (win.FindWindowExW(null, previous, windows.wide("#32770"), null)) |dialog| {
            previous = dialog;
            if (ui.windowPid(dialog) != pid or win.IsWindowVisible(dialog) == 0 or win.GetDlgItem(dialog, win.IDOK) == null)
                continue;
            owned_dialog = dialog;
            if (findFileEntry(dialog, 0)) |entry| return .{ .window = dialog, .filename = entry };
        }
        std.Thread.sleep(20 * std.time.ns_per_ms);
    }
    if (owned_dialog != null and ui.windowPid(owned_dialog) == pid) _ = win.PostMessageW(owned_dialog, win.WM_CLOSE, 0, 0);
    return error.ProductFilePickerNotFound;
}

fn findFileEntry(parent: win.HWND, depth: usize) ?win.HWND {
    if (depth >= 8) return null;
    var previous: win.HWND = null;
    while (win.FindWindowExW(parent, previous, null, null)) |child| {
        previous = child;
        // The shell's Explorer view uses a native Edit with ID 1001. The
        // breadcrumb toolbar can have the same ID, so require the Edit class.
        const id = win.GetDlgCtrlID(child);
        if (id == 1001 and isEdit(child)) return child;
        // Older OPENFILENAME templates use edt1 or the cmb13 container.
        if (id == 0x480 or id == 0x47c) {
            if (isEdit(child)) return child;
            if (firstEdit(child, 0)) |entry| return entry;
        }
        if (findFileEntry(child, depth + 1)) |entry| return entry;
    }
    return null;
}

fn firstEdit(parent: win.HWND, depth: usize) ?win.HWND {
    if (depth >= 5) return null;
    if (win.FindWindowExW(parent, null, windows.wide("Edit"), null)) |edit| return edit;
    var previous: win.HWND = null;
    while (win.FindWindowExW(parent, previous, null, null)) |child| {
        previous = child;
        if (firstEdit(child, depth + 1)) |edit| return edit;
    }
    return null;
}

fn isEdit(window: win.HWND) bool {
    var class: [16]u16 = undefined;
    const length = win.GetClassNameW(window, &class, class.len);
    return length > 0 and std.mem.eql(u16, class[0..@intCast(length)], windows.wide("Edit"));
}

fn clickDialog(dialog: win.HWND, id: c_int) !void {
    const button = try ui.control(dialog, id);
    if (win.PostMessageW(button, win.BM_CLICK, 0, 0) == 0) return error.CannotClickProductDialog;
}

fn acceptError(scratch: std.mem.Allocator, pid: u32, expected: []const u8) !void {
    const dialog = try ui.waitWindow(windows.wide("#32770"), windows.wide("操作に失敗しました"), pid);
    errdefer _ = win.PostMessageW(dialog, win.WM_CLOSE, 0, 0);
    if (!includes(try modalText(scratch, dialog), expected)) return error.UnexpectedTransferError;
    try closeOk(dialog, pid);
}

fn closeOk(dialog: win.HWND, pid: u32) !void {
    // Some Windows builds use IDCANCEL for the single OK button in a MessageBox.
    try clickDialog(dialog, if (win.GetDlgItem(dialog, win.IDOK) != null) win.IDOK else win.IDCANCEL);
    try ui.waitClosed(dialog, pid);
}

fn modalText(scratch: std.mem.Allocator, dialog: win.HWND) ![]const u8 {
    var previous: win.HWND = null;
    while (win.FindWindowExW(dialog, previous, windows.wide("Static"), null)) |label| {
        previous = label;
        if ((try ui.message(label, win.WM_GETTEXTLENGTH, 0, 0)) > 0) return ui.readText(scratch, label);
    }
    return error.ProductModalTextMissing;
}

fn expectPublishedShortcuts(scratch: std.mem.Allocator, app: OwnedProduct, parent: win.HWND, expected: ShortcutKeys) !void {
    const editor = try openShortcutEditor(app, parent);
    errdefer cleanupShortcutEditor(app, editor);
    try expectShortcutFields(scratch, editor, expected);
    try postDialogCommand(editor, app.pid, win.IDCANCEL);
    try expectShortcutEditorClosed(app, parent, editor);
}

fn expectPreserved(scratch: std.mem.Allocator, installed: std.fs.Dir, absolute_db: []const u8, data_dir: std.fs.Dir, existing_backups: []const []const u8, digest: files.Digest, expected: storage.Data, search: win.HWND, scope: win.HWND) !void {
    try expectDigest(installed, db_path, digest);
    try expectDb(absolute_db, expected);
    if (onlyBackup(scratch, data_dir, existing_backups)) |_| return error.RejectedTransferCreatedBackup else |failure| {
        if (failure != error.MissingAutomaticBackup) return failure;
    }
    if (!std.mem.eql(u8, try ui.readText(scratch, search), search_marker) or
        (try ui.message(scope, win.CB_GETCURSEL, 0, 0)) != 1)
        return error.RejectedTransferChangedVisibleValues;
}

fn isBackup(name: []const u8) bool {
    return std.mem.startsWith(u8, name, backup_prefix) and std.mem.endsWith(u8, name, ".json");
}

fn onlyBackup(scratch: std.mem.Allocator, dir: std.fs.Dir, existing_backups: []const []const u8) ![]const u8 {
    var it = dir.iterate();
    var found: ?[]const u8 = null;
    entries: while (try it.next()) |entry| {
        if (entry.kind != .file or !isBackup(entry.name)) continue;
        for (existing_backups) |name| {
            if (std.mem.eql(u8, entry.name, name)) continue :entries;
        }
        if (found != null) return error.MultipleAutomaticBackups;
        found = try scratch.dupe(u8, entry.name);
    }
    return found orelse error.MissingAutomaticBackup;
}

fn assertJsonEnvelope(scratch: std.mem.Allocator, root: std.fs.Dir, path: []const u8, saved_text: []const u8) !void {
    const bytes = try root.readFileAlloc(scratch, path, 4 * 1024 * 1024);
    const schema = try std.json.parseFromSliceLeaky(struct {
        format: []const u8,
        version: u8,
        sharedItems: []struct { text: []const u8 },
    }, scratch, bytes, .{ .ignore_unknown_fields = true });
    if (!std.mem.eql(u8, schema.format, "ChatPalette") or schema.version != 2 or schema.sharedItems.len != 2 or
        !std.mem.eql(u8, schema.sharedItems[0].text, baseline().shared_items[0].text) or
        !std.mem.eql(u8, schema.sharedItems[1].text, saved_text)) return error.ExportedJsonIncompatible;
}

fn includes(value: []const u8, piece: []const u8) bool {
    return std.mem.indexOf(u8, value, piece) != null;
}

fn expectDigest(dir: std.fs.Dir, name: []const u8, expected: files.Digest) !void {
    if (!std.mem.eql(u8, &(try files.readDigest(dir, name)), &expected)) return error.FileContentsChanged;
}

fn waitForFile(dir: std.fs.Dir, name: []const u8) !void {
    const started = win.GetTickCount64();
    while (win.GetTickCount64() - started < step_timeout_ms) {
        if (dir.access(name, .{})) |_| return else |failure| {
            if (failure != error.FileNotFound) return failure;
        }
        std.Thread.sleep(20 * std.time.ns_per_ms);
    }
    return error.ExportNotPublished;
}

fn readDatabase(path: []const u8) !storage.Snapshot {
    var db = try storage.Store.open(allocator, path);
    defer db.close();
    return db.load(allocator);
}

fn seedDatabase(path: []const u8, data: storage.Data) !void {
    var db = try storage.Store.open(allocator, path);
    defer db.close();
    try db.save(data);
}

fn expectDb(path: []const u8, expected: storage.Data) !void {
    var actual = try readDatabase(path);
    defer actual.deinit();
    if (!expected.eql(actual.data)) return error.DatabaseValuesDiffer;
}

fn expectJson(path: []const u8, expected: storage.Data) !void {
    var actual = try storage.readJson(allocator, path);
    defer actual.deinit();
    if (!expected.eql(actual.data)) return error.JsonValuesDiffer;
}

fn newDirectory(parent: std.fs.Dir, name: []const u8) !std.fs.Dir {
    try parent.makeDir(name);
    return parent.openDir(name, .{ .no_follow = true });
}

fn join(scratch: std.mem.Allocator, directory: []const u8, name: []const u8) ![]const u8 {
    return std.fs.path.join(scratch, &.{ directory, name });
}

fn baseline() storage.Data {
    return .{
        .preferences = .{ .input_profile_id = "fixture-profile", .auto_mode = false, .reaction_count = 10, .reaction_interval_ms = 250 },
        .profiles = &.{.{
            .id = "fixture-profile",
            .name = "元の合成配信者",
            .channel = "/@fixtureOriginal",
            .items = &.{
                .{ .id = "profile-row", .name = "配信者別文章", .text = "配信者向け🙌", .slot = 2 },
                .{ .id = "profile-row-two", .name = "取込前に選ぶ行", .text = "別の配信者別文章", .slot = 1 },
            },
        }},
        .shared_items = &.{.{ .id = "legacy", .name = "元の共通弾幕", .text = "引用 \" と \\ と 👏", .slot = 1 }},
        .registrations = &.{.{
            .browser = "edge",
            .payload_json =
            \\{"tokens":[{"name":"👏","id":"one","class":"button","type":50000,"extra":1.2500},{"name":"b","id":"two","class":"button","type":50000},{"name":"c","id":"three","class":"button","type":50000},{"name":"d","id":"four","class":"button","type":50000},{"name":"e","id":"five","class":"button","type":50000}],"extension":"保持","browser":"edge"}
            ,
        }},
    };
}

fn replacement() storage.Data {
    var keys = storage.default_shortcut_keys;
    keys[@intFromEnum(storage.Action.reaction)] = "+^r";
    keys[@intFromEnum(storage.Action.profile2)] = "";
    return .{
        .preferences = .{ .input_profile_id = "fixture-profile", .auto_mode = true, .reaction_kind = 3, .reaction_count = 100, .reaction_interval_ms = 0, .shortcut_keys = keys },
        .profiles = &.{.{ .id = "fixture-profile", .name = "置換後の配信者", .channel = "/channel/replacement" }},
        .shared_items = &.{.{ .id = "replacement", .name = "置換用の共通弾幕", .text = "取り込んだ値🌙", .slot = 2 }},
    };
}

test "transfer fixture baselines roundtrip as independent DB5 and JSON2 data" {
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const root = try directory.dir.realpathAlloc(scratch, ".");
    const fixtures = [_]storage.Data{ baseline(), replacement() };
    for (fixtures, [_][]const u8{ "initial", "incoming" }) |data, name| {
        const db = try join(scratch, root, try std.fmt.allocPrint(scratch, "{s}.db", .{name}));
        const json = try join(scratch, root, try std.fmt.allocPrint(scratch, "{s}.json", .{name}));
        var connection = try storage.Store.open(allocator, db);
        defer connection.close();
        try connection.save(data);
        try connection.exportJson(json);
        try expectDb(db, data);
        try expectJson(json, data);
    }
    try std.testing.expect(!fixtures[0].eql(fixtures[1]));
}

test "shortcut commit fixture blocks only when the requested writes try to commit" {
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const root = try directory.dir.realpathAlloc(scratch, ".");
    const path = try join(scratch, root, "settings.db");
    var db = try storage.Store.open(scratch, path);
    defer db.close();
    var committed = baseline();
    committed.preferences.shortcut_keys = remappedKeys(committed.preferences.shortcut_keys);
    try db.save(committed);
    var draft = committed;
    draft.preferences.shortcut_keys = retriedKeys(committed.preferences.shortcut_keys);
    const digest = try files.readDigest(directory.dir, "settings.db");
    {
        var reader = try holdShortcutReadLock(path);
        defer reader.close();
        defer reader.rollback();
        try proveShortcutCommitBlocked(path, PaletteKey.retry.setting());
        try std.testing.expectError(error.DatabaseLocked, db.savePreferences(draft.preferences));
        try expectDigest(directory.dir, "settings.db", digest);
        try reader.exec("ROLLBACK");
    }
    try expectDb(path, committed);
    try db.savePreferences(draft.preferences);
    try expectDb(path, draft);
}
